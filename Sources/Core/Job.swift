import Foundation
import Combine

// Queue item model. A Job is one Operation run over a list of items with per-job option overrides.
// Quick jobs (wheel/Services/hotkey) and Studio queue items are the SAME object: the HUD card and the Studio queue row
// both observe it.

enum JobState: String, Codable, Sendable {
    case waiting, running, paused, done, failed, cancelled, skipped
    var isFinished: Bool { self == .done || self == .failed || self == .cancelled || self == .skipped }
    var isActive: Bool { self == .running || self == .paused }
}

enum JobOrigin: String, Codable, Sendable {
    case wheel, studio, service, hotkey, dock, menubar, watch, chain, shelf, urlScheme, clipboard, cli, other
}

@MainActor
final class Job: ObservableObject, Identifiable {
    nonisolated let id: UUID
    /// All jobs created by one drop / one Studio "Start" share a batch id: one notification per batch.
    nonisolated let batchID: UUID
    nonisolated let operationID: String
    nonisolated let origin: JobOrigin
    nonisolated let mode: RunMode
    nonisolated let createdAt = Date()

    @Published var title: String
    @Published private(set) var items: [FileItem]
    /// Link inputs (download jobs). A job has files OR links, never both.
    @Published private(set) var links: [LinkItem]
    /// Sparse option overrides on top of the operation's quick recipe (per-job options; editable while waiting).
    @Published var overrides: OptionValues
    /// nil = rules from settings (+ `out.*` keys in overrides)
    @Published var outputRules: OutputRules?

    @Published private(set) var state: JobState = .waiting
    /// 0...1, nil = indeterminate
    @Published private(set) var progress: Double? = nil
    @Published private(set) var statusText: String = ""
    @Published private(set) var currentItemName: String? = nil
    @Published private(set) var eta: TimeInterval? = nil
    @Published private(set) var outputs: [URL] = []
    @Published private(set) var failures: [String] = []
    @Published private(set) var note: L10n? = nil
    @Published private(set) var errorMessage: String? = nil
    /// Set when the job failed because a required program is not installed (the CLI answers with exit code 3 instead of 1).
    private(set) var missingTool: Tool? = nil
    /// Added to the queue but not started ("Add to Queue" without "Start").
    @Published var held: Bool
    @Published private(set) var cancelRequested = false
    @Published private(set) var logLines: [String] = []
    /// Stage model (download -> convert ...). Empty for single-stage jobs.
    @Published private(set) var stages: [StageProgress] = []
    @Published private(set) var currentStageTitle: String? = nil

    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// What to do when the job finishes (derived from rules + settings when it starts).
    private(set) var finishAction: AfterFinish = .nothing

    // Runner internals
    var task: Task<Void, Never>?
    var context: OperationContext?
    private var lastProgressAt = Date.distantPast
    private var rateEMA: Double?
    private var lastSample: (t: Date, p: Double)?

    var logText: String { logLines.joined(separator: "\n") }
    var isAutomatic: Bool { mode == .automatic }
    var totalInputBytes: Int64 { items.compactMap(\.size).reduce(0, +) }
    var elapsed: TimeInterval { (startedAt.map { (finishedAt ?? Date()).timeIntervalSince($0) }) ?? 0 }

    var isLinkJob: Bool { !links.isEmpty }
    /// Display names of the inputs (file names or link titles).
    var inputNames: [String] { isLinkJob ? links.map(\.displayTitle) : items.map(\.name) }

    init(id: UUID = UUID(), batchID: UUID, operationID: String, title: String, items: [FileItem], links: [LinkItem] = [], overrides: OptionValues,
         outputRules: OutputRules?, origin: JobOrigin, mode: RunMode, held: Bool) {
        self.id = id; self.batchID = batchID; self.operationID = operationID; self.title = title; self.items = items; self.links = links
        self.overrides = overrides; self.outputRules = outputRules; self.origin = origin; self.mode = mode; self.held = held
    }

    // MARK: Runner-driven updates (internal)

    func markStarted(finishAction: AfterFinish) {
        state = .running; startedAt = Date(); progress = nil; eta = nil; errorMessage = nil; missingTool = nil; failures = []; outputs = []; stages = []
        statusText = L("Starting…", "Запуск…"); self.finishAction = finishAction
        lastSample = nil; rateEMA = nil
    }

    func update(progress p: Double?, message: String?, etaHint: TimeInterval?) {
        let now = Date()
        // Throttle UI churn to ~12 Hz but always accept completion.
        if let p, p < 0.999, now.timeIntervalSince(lastProgressAt) < 0.08 { return }
        lastProgressAt = now
        if let p {
            let monotonic = max(p, progress ?? 0)
            progress = min(monotonic, 1)
            if let hint = etaHint { eta = hint } else { updateETA(now: now, p: monotonic) }
        } else if state == .running { progress = nil }
        if let m = message { statusText = m }
    }

    private func updateETA(now: Date, p: Double) {
        guard let start = startedAt, p > 0.02 else { return }
        let elapsedTotal = now.timeIntervalSince(start)
        var rate = p / max(elapsedTotal, 0.001)
        if let last = lastSample, now.timeIntervalSince(last.t) > 0.5, p > last.p {
            let inst = (p - last.p) / now.timeIntervalSince(last.t)
            rateEMA = rateEMA.map { $0 * 0.7 + inst * 0.3 } ?? inst
            lastSample = (now, p)
        } else if lastSample == nil { lastSample = (now, p) }
        if let r = rateEMA { rate = (rate + r) / 2 }
        if rate > 0 { eta = (1 - p) / rate }
    }

    func setCurrent(item: FileItem, index: Int, count: Int) {
        currentItemName = item.name
        if count > 1 { statusText = L("File \(index + 1) of \(count)", "Файл \(index + 1) из \(count)") }
    }

    func setStages(_ new: [StageProgress]) {
        guard !state.isFinished, new != stages else { return }   // a late update never resurrects a finished job's stages
        stages = new
        currentStageTitle = new.first { $0.state == .running }?.spec.title.text
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 600 { logLines.removeFirst(logLines.count - 600) }
    }

    func markPaused(_ on: Bool) {
        guard state == .running || state == .paused else { return }
        state = on ? .paused : .running
    }

    func markCancelRequested() { cancelRequested = true; if state.isActive { statusText = L("Canceling…", "Отмена…") } }

    /// Remembers which program was missing when the failure was `ConversionError.toolMissing` (the text alone cannot be told apart from other failures).
    func noteMissingTool(_ tool: Tool) { missingTool = tool }

    func finish(_ s: JobState, result: OperationResult? = nil, error: String? = nil) {
        state = s
        finishedAt = Date()
        if let r = result { outputs = r.outputs; failures = r.failures; note = r.note }
        if s == .done {
            progress = 1; eta = nil
            // Success closes the stage list: the running stage is done, stages that never started were not needed.
            stages = stages.map { var st = $0; if st.state == .running { st.state = .done; st.fraction = 1 } else if st.state == .pending { st.state = .skipped }; return st }
        } else if s == .failed {
            stages = stages.map { var st = $0; if st.state == .running { st.state = .failed }; return st }
        }
        errorMessage = error
        if s == .failed { statusText = error ?? "" }
        if s == .done {
            statusText = failures.isEmpty ? doneStatus() : failures.joined(separator: "\n")
        }
    }

    private func doneStatus() -> String {
        if outputs.count == 1 { return L("Done: \(outputs[0].lastPathComponent)", "Готово: \(outputs[0].lastPathComponent)") }
        if outputs.count > 1 { return L("Done: \(outputs.count) files", "Готово: файлов — \(outputs.count)") }
        return note?.text ?? L("Done", "Готово")
    }

    func reset(for retry: Bool) {
        state = .waiting; progress = nil; eta = nil; errorMessage = nil; missingTool = nil; statusText = ""; outputs = []; failures = []; stages = []
        cancelRequested = false; finishedAt = nil; startedAt = nil
        if retry { held = false }
    }

    func replaceItems(_ new: [FileItem]) { items = new }
}

/// Codable snapshot of a finished job (history.json).
struct JobRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var operationID: String
    var state: JobState
    var origin: JobOrigin
    var itemNames: [String]
    /// Link jobs: the URLs (absolute strings).
    var linkURLs: [String]? = nil
    var outputs: [String]
    var errorMessage: String?
    var note: L10n?
    var startedAt: Date?
    var finishedAt: Date?
    var bytesIn: Int64
}

/// Codable snapshot of a queued job (queue.json) so the queue survives relaunch.
struct QueuedJobRecord: Codable, Equatable, Sendable {
    var id: UUID
    var batchID: UUID
    var operationID: String
    var title: String
    var itemPaths: [String]
    var linkURLs: [String]? = nil
    var overrides: OptionValues
    var outputRules: OutputRules?
    var origin: JobOrigin
    var mode: RunMode
    /// Link jobs: the known page titles aligned with `linkURLs` (empty string = unknown). Added after the first release of the file format; absent in old files.
    var linkTitles: [String]? = nil
}

struct BatchSummary: Sendable {
    var batchID: UUID
    var total: Int
    var succeeded: Int
    var failed: Int
    var cancelled: Int
    var outputs: [URL]
    var firstTitle: String
    var firstError: String?
    var finishAction: AfterFinish
    var automatic: Bool
}

@MainActor
enum JobEvent {
    case added(Job)
    case started(Job)
    case progress(Job)
    case paused(Job)
    case resumed(Job)
    case finished(Job)
    case failed(Job)
    case cancelled(Job)
    case removed(UUID)
    case queueStateChanged
    case batchFinished(BatchSummary)
}

struct RunnerSummary: Equatable, Sendable {
    var running: Int
    var waiting: Int
    var paused: Int
    /// Mean progress of unfinished jobs 0...1 (nil when idle or all indeterminate).
    var progress: Double?
    var isIdle: Bool { running + waiting + paused == 0 }
}
