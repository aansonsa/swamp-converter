import Foundation

// Multi-stage jobs (a download followed by a smart transcode, a transcription followed by a burn-in, a chain step).
// An operation declares its stages up front (`Operation.stagePlan`), runs them in order with `ctx.beginStage(id)` and reports
// progress of the CURRENT stage with `ctx.report(fraction)`; Core combines them into one progress value and one ETA for the UI.
// Single-stage operations declare nothing and `report` keeps meaning "fraction of the whole job".

struct StageSpec: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: L10n
    /// Relative share of the whole job (download 0.6, convert 0.4). Only ratios matter.
    var weight: Double
    var symbol: String? = nil

    init(id: String, title: L10n, weight: Double = 1, symbol: String? = nil) {
        self.id = id; self.title = title; self.weight = max(weight, 0.0001); self.symbol = symbol
    }

    // Well-known ids so the UI can pick icons and wording.
    static func download(weight: Double = 0.6) -> StageSpec { StageSpec(id: "download", title: L10n("Downloading", "Загрузка"), weight: weight, symbol: "arrow.down.circle") }
    static func convert(weight: Double = 0.4) -> StageSpec { StageSpec(id: "convert", title: L10n("Converting", "Конвертация"), weight: weight, symbol: "arrow.triangle.2.circlepath") }
    static func transcribe(weight: Double = 0.7) -> StageSpec { StageSpec(id: "transcribe", title: L10n("Recognizing speech", "Распознавание речи"), weight: weight, symbol: "waveform") }
    static func finalize(weight: Double = 0.05) -> StageSpec { StageSpec(id: "finalize", title: L10n("Finishing", "Завершение"), weight: weight, symbol: "checkmark") }
}

enum StageState: String, Codable, Sendable { case pending, running, done, skipped, failed }

struct StageProgress: Identifiable, Equatable, Sendable {
    var spec: StageSpec
    var state: StageState = .pending
    /// 0...1 within the stage; nil = indeterminate.
    var fraction: Double? = nil
    var eta: TimeInterval? = nil
    var message: String? = nil
    var startedAt: Date? = nil
    var id: String { spec.id }
}

/// Pure state machine behind the stage model. All times are injected (`now`) so it is deterministic in tests.
struct StageTracker: Equatable, Sendable {
    private(set) var stages: [StageProgress]

    init(_ specs: [StageSpec]) { stages = specs.map { StageProgress(spec: $0) } }

    var isMultiStage: Bool { stages.count > 1 }
    var current: StageProgress? { stages.first { $0.state == .running } }
    var currentID: String? { current?.id }
    var isEmpty: Bool { stages.isEmpty }

    /// Starts stage `id`: a still-running earlier stage is marked done, skipped stages stay skipped.
    mutating func begin(_ id: String, now: Date = Date()) {
        guard let i = stages.firstIndex(where: { $0.id == id }) else { return }
        for j in stages.indices where stages[j].state == .running && j != i { stages[j].state = .done; stages[j].fraction = 1; stages[j].eta = 0 }
        for j in 0..<i where stages[j].state == .pending { stages[j].state = .skipped }
        stages[i].state = .running
        stages[i].startedAt = now
        stages[i].fraction = nil
        stages[i].eta = nil
    }

    /// Progress of the running stage (or of `id` if given and running).
    mutating func update(_ id: String? = nil, fraction: Double?, eta: TimeInterval? = nil, message: String? = nil) {
        guard let i = id.flatMap({ key in stages.firstIndex { $0.id == key } }) ?? stages.firstIndex(where: { $0.state == .running }) else { return }
        stages[i].fraction = fraction.map { Util.clamp($0, 0, 1) }
        if let eta { stages[i].eta = eta }
        if let message { stages[i].message = message }
    }

    mutating func finish(_ id: String? = nil) {
        guard let i = id.flatMap({ key in stages.firstIndex { $0.id == key } }) ?? stages.firstIndex(where: { $0.state == .running }) else { return }
        stages[i].state = .done; stages[i].fraction = 1; stages[i].eta = 0
    }

    mutating func skip(_ id: String) {
        guard let i = stages.firstIndex(where: { $0.id == id }), stages[i].state == .pending else { return }
        stages[i].state = .skipped
    }

    mutating func fail() {
        if let i = stages.firstIndex(where: { $0.state == .running }) { stages[i].state = .failed }
    }

    /// Weighted progress over all stages that are not skipped. nil while the running stage is indeterminate AND nothing is done.
    var overallFraction: Double? {
        let live = stages.filter { $0.state != .skipped }
        let total = live.reduce(0) { $0 + $1.spec.weight }
        guard total > 0 else { return nil }
        var done = 0.0
        var indeterminate = false
        for s in live {
            switch s.state {
            case .done: done += s.spec.weight
            case .running:
                if let f = s.fraction { done += s.spec.weight * f } else { indeterminate = true }
            default: break
            }
        }
        if indeterminate && done == 0 { return nil }
        return Util.clamp(done / total, 0, 1)
    }

    /// ETA of the rest: the running stage's own ETA (or elapsed/fraction) plus the pending stages scaled by weight against it.
    func overallETA(now: Date = Date()) -> TimeInterval? {
        guard let cur = current else { return nil }
        var currentRemaining = cur.eta
        var currentTotal: Double?
        if let f = cur.fraction, f > 0.02, let start = cur.startedAt {
            let elapsed = now.timeIntervalSince(start)
            currentTotal = elapsed / f
            if currentRemaining == nil { currentRemaining = max(0, currentTotal! - elapsed) }
        }
        guard let remaining = currentRemaining else { return nil }
        let pendingWeight = stages.filter { $0.state == .pending }.reduce(0) { $0 + $1.spec.weight }
        guard pendingWeight > 0 else { return remaining }
        guard let total = currentTotal else { return nil }
        return remaining + total * pendingWeight / cur.spec.weight
    }
}
