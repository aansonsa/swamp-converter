import Foundation

/// A plain-value copy of everything a job row shows. The views never read a `Job` directly: they read a snapshot, and the mapping below is a pure function
/// (state -> phase, texts, buttons), so the tests cover every state without a window.
struct JobSnapshot: Equatable {
    var id = UUID()
    var title = ""
    /// The operation's own SF Symbol (nil: the symbol comes from the kind of the first input).
    var operationSymbol: String?
    var state: JobState = .waiting
    var held = false
    var cancelRequested = false
    var queuePaused = false
    var progress: Double?
    var eta: TimeInterval?
    var statusText = ""
    var errorMessage: String?
    var failures: [String] = []
    var outputs: [URL] = []
    var stages: [StageProgress] = []
    var inputNames: [String] = []
    var isLinkJob = false
    var elapsed: TimeInterval = 0
    var inputBytes: Int64 = 0
    var note: String?
}

/// One step of a multi-stage job ("Downloading 62% > Converting").
struct StageSegment: Equatable, Identifiable {
    var id: String
    var title: String
    var state: StageState
    /// Whole percent of a running determinate stage.
    var percent: Int?
}

struct JobRowModel: Equatable {
    enum Phase: Equatable {
        case queued, held, running, cancelling, paused, done, doneWithWarnings, failed, cancelled, skipped

        var isFinished: Bool {
            switch self {
            case .done, .doneWithWarnings, .failed, .cancelled, .skipped: return true
            default: return false
            }
        }
    }

    var phase: Phase
    var title: String
    var symbol: String
    var inputLine: String
    /// The calm one-line state ("Waiting", "Paused", "Done in 12 s"); empty while the progress block says everything.
    var statusLine: String
    var progress: Double?
    var showsBar: Bool
    /// The bar turns Swamp Blue in the second and later stages of a multi-stage job.
    var barIsSecondary: Bool
    var percentText: String?
    var etaText: String?
    var speedText: String?
    var stages: [StageSegment]
    /// The human-readable reason of a failure (or the failed files of a partial success).
    var errorText: String?
    var outputs: [URL]
    var canCancel: Bool
    var canPause: Bool
    var canResume: Bool
    var canRetry: Bool
    var canRemove: Bool
    var hasResult: Bool
    var statusKind: StatusKind
    var accessibilityLabel: String

    /// "Downloading 62% > Converting", for tests and VoiceOver.
    var stageLine: String {
        stages.map { s in s.percent.map { "\(s.title) \(Loc.percent($0))" } ?? s.title }.joined(separator: " \u{2192} ")
    }

    static func make(_ s: JobSnapshot) -> JobRowModel {
        let phase = Self.phase(of: s)
        let inputLine = Self.inputLine(s)
        let segments = Self.segments(s)
        let live = phase == .running || phase == .paused || phase == .cancelling
        let percent = live ? JobsFormat.percentText(s.progress) : nil
        let eta = phase == .running ? JobsFormat.etaText(s.eta) : nil
        let speed = phase == .running ? JobsFormat.speedText(progress: s.progress, inputBytes: s.inputBytes, elapsed: s.elapsed) : nil
        let secondStage = (s.stages.filter { $0.state != .skipped }.firstIndex { $0.state == .running } ?? 0) >= 1
        let error = Self.errorText(s, phase: phase)
        let status = Self.statusLine(s, phase: phase, segments: segments)

        var m = JobRowModel(
            phase: phase, title: s.title, symbol: Self.symbol(s), inputLine: inputLine, statusLine: status, progress: s.progress, showsBar: live,
            barIsSecondary: secondStage, percentText: percent, etaText: eta, speedText: speed, stages: segments, errorText: error, outputs: s.outputs,
            canCancel: [.queued, .held, .running, .paused].contains(phase), canPause: phase == .running, canResume: phase == .paused,
            canRetry: [.failed, .cancelled, .skipped].contains(phase), canRemove: phase.isFinished,
            hasResult: (phase == .done || phase == .doneWithWarnings) && !s.outputs.isEmpty,
            statusKind: Self.kind(phase), accessibilityLabel: "")
        m.accessibilityLabel = Self.spoken(m)
        return m
    }

    // MARK: Mapping

    static func phase(of s: JobSnapshot) -> Phase {
        switch s.state {
        case .waiting: return s.held ? .held : .queued
        case .running: return s.cancelRequested ? .cancelling : .running
        case .paused: return .paused
        case .done: return s.failures.isEmpty ? .done : .doneWithWarnings
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .skipped: return .skipped
        }
    }

    static func kind(_ phase: Phase) -> StatusKind {
        switch phase {
        case .queued, .held: return .waiting
        case .running, .cancelling: return .running
        case .paused: return .paused
        case .done: return .done
        case .doneWithWarnings: return .warning
        case .failed: return .failed
        case .cancelled, .skipped: return .idle
        }
    }

    static func symbol(_ s: JobSnapshot) -> String {
        if let sym = s.operationSymbol, !sym.isEmpty { return sym }
        if s.isLinkJob { return "arrow.down.circle" }
        if let first = s.inputNames.first { return Formats.kind(forKey: Formats.key(forName: first)).symbol }
        return "doc"
    }

    static func inputLine(_ s: JobSnapshot) -> String {
        if s.inputNames.count == 1 { return s.inputNames[0] }
        if s.inputNames.isEmpty { return s.isLinkJob ? L("Link", "Ссылка") : "" }
        return s.isLinkJob ? L("\(s.inputNames.count) links", "Ссылок: \(s.inputNames.count)") : Loc.files(s.inputNames.count)
    }

    static func segments(_ s: JobSnapshot) -> [StageSegment] {
        let shown = s.stages.filter { $0.state != .skipped }
        guard shown.count > 1 else { return [] }
        return shown.map { st in
            let pct = st.state == .running ? st.fraction.map { Int((min(max($0, 0), 1) * 100).rounded(.down)) } : nil
            return StageSegment(id: st.id, title: st.spec.title.text, state: st.state, percent: pct)
        }
    }

    static func errorText(_ s: JobSnapshot, phase: Phase) -> String? {
        switch phase {
        case .failed:
            let text = (s.errorMessage ?? s.statusText).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? L("The job did not finish.", "Задача не завершена.") : text
        case .doneWithWarnings:
            return s.failures.prefix(3).joined(separator: "\n") + (s.failures.count > 3 ? "\n" + L("and \(s.failures.count - 3) more", "и ещё \(s.failures.count - 3)") : "")
        default: return nil
        }
    }

    static func statusLine(_ s: JobSnapshot, phase: Phase, segments: [StageSegment]) -> String {
        switch phase {
        case .queued: return s.queuePaused ? L("Queue paused", "Очередь приостановлена") : L("Waiting", "Ожидает")
        case .held: return L("Added to the queue", "Добавлено в очередь")
        case .paused: return L("Paused", "Приостановлено")
        case .cancelling: return L("Canceling\u{2026}", "Отмена\u{2026}")
        case .running:
            // The stage chain already names the work; a plain job shows the runner's message ("File 2 of 5").
            let text = s.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
            if segments.isEmpty { return text }
            return text == (segments.first { $0.state == .running }?.title ?? "") ? "" : text
        case .done:
            var line = L("Done", "Готово")
            if let took = JobsFormat.tookText(s.elapsed) { line += L(" in \(took)", " за \(took)") }
            if let note = s.note, !note.isEmpty { line += " \u{00B7} " + note }
            return line
        case .doneWithWarnings: return L("Done, \(s.failures.count) failed", "Готово, с ошибками: \(s.failures.count)")
        case .failed: return L("Failed", "Не удалось")
        case .cancelled: return L("Canceled", "Отменено")
        case .skipped: return L("Skipped", "Пропущено")
        }
    }

    static func spoken(_ m: JobRowModel) -> String {
        var parts = [m.title]
        if !m.inputLine.isEmpty { parts.append(m.inputLine) }
        parts.append(m.statusKind.spokenName.text)
        if !m.statusLine.isEmpty, m.phase.isFinished || m.phase == .queued || m.phase == .held { parts.append(m.statusLine) }
        if let p = m.percentText { parts.append(p) }
        if let e = m.etaText { parts.append(e) }
        if !m.stages.isEmpty { parts.append(m.stageLine) }
        if let err = m.errorText { parts.append(err.replacingOccurrences(of: "\n", with: ". ")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: Building a snapshot from a live job

extension JobSnapshot {
    /// The operation's symbol, looked up once per row (a miss in the registry scans every provider, so it is never done per update).
    @MainActor
    static func symbol(for job: Job, registry: OperationRegistry = .shared) -> String? { registry.operation(id: job.operationID)?.meta.symbol }

    @MainActor
    init(job: Job, queuePaused: Bool, operationSymbol: String?) {
        self.init(id: job.id, title: job.title, operationSymbol: operationSymbol, state: job.state, held: job.held,
                  cancelRequested: job.cancelRequested, queuePaused: queuePaused, progress: job.progress, eta: job.eta, statusText: job.statusText,
                  errorMessage: job.errorMessage, failures: job.failures, outputs: job.outputs, stages: job.stages, inputNames: job.inputNames,
                  isLinkJob: job.isLinkJob, elapsed: job.elapsed, inputBytes: job.totalInputBytes, note: job.note?.text)
    }
}
