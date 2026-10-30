import SwiftUI
import Combine

/// What the aggregation needs to know about one unfinished job.
struct JobProgressInput: Equatable, Sendable {
    var state: JobState
    var held: Bool
    var progress: Double?
    var isDownload: Bool
}

/// The menu-bar numbers for a set of unfinished jobs plus the number that finished since the queue last woke up (pure; tested).
struct MenuBarAggregate: Equatable {
    var fraction: Double?
    var running: Int
    var waiting: Int
    var paused: Int
    var statusLine: String
    var isIdle: Bool { running + waiting + paused == 0 }

    static let idle = MenuBarAggregate(fraction: nil, running: 0, waiting: 0, paused: 0, statusLine: "")

    /// `active`: jobs that are not finished. Held jobs ("Add to Queue" without Start) are not work in progress and do not light the menu bar.
    /// The fraction counts the jobs that finished in this session as complete, so it never falls back when a job ends. nil = nothing to show or no number yet.
    static func make(active: [JobProgressInput], finishedInSession: Int, queuePaused: Bool) -> MenuBarAggregate {
        let live = active.filter { !$0.state.isFinished && !($0.state == .waiting && $0.held) }
        let running = live.filter { $0.state == .running }
        let paused = live.filter { $0.state == .paused }.count
        let waiting = live.filter { $0.state == .waiting }.count
        guard !live.isEmpty else { return .idle }

        let total = live.count + max(finishedInSession, 0)
        let working = live.filter { $0.state == .running || $0.state == .paused }
        let determinate = working.contains { $0.progress != nil }
        var fraction: Double?
        if determinate || finishedInSession > 0 {
            let sum = Double(finishedInSession) + working.reduce(0.0) { $0 + min(max($1.progress ?? 0, 0), 1) }
            fraction = min(max(sum / Double(total), 0), 1)
        }
        let position = min(finishedInSession + 1, total)
        let allDownloads = !running.isEmpty && running.allSatisfy(\.isDownload)
        let verb = allDownloads ? L("Downloading", "Загрузка") : L("Converting", "Конвертация")
        var line: String
        if running.isEmpty && (paused > 0 || queuePaused) {
            line = total > 1 ? L("Paused \u{2013} \(finishedInSession) of \(total) done", "Приостановлено \u{2013} готово \(finishedInSession) из \(total)") : L("Paused", "Приостановлено")
        } else if running.isEmpty {
            line = L("\(Loc.items(waiting)) waiting", "Ожидает: \(Loc.items(waiting))")
        } else {
            line = total > 1 ? L("\(verb) \(position) of \(total)", "\(verb) \(position) из \(total)") : verb
            if let f = fraction { line += " \u{2013} " + Loc.percent(Int((f * 100).rounded(.down))) }
        }
        return MenuBarAggregate(fraction: fraction, running: running.count + paused, waiting: waiting, paused: paused, statusLine: line)
    }
}

/// What the status item shows. The APP module draws the NSStatusItem icon (a monochrome TEMPLATE image) and observes this model; the pink only appears as a small status dot / progress
/// ring while jobs run. Updated from job events only, at most 10 times a second (`JobsCoordinator` throttles; this class never schedules anything itself).
@MainActor
final class MenuBarProgressModel: ObservableObject {
    static let shared = MenuBarProgressModel()
    /// nil = idle or indeterminate.
    @Published private(set) var fraction: Double?
    /// Jobs doing work now (running or paused).
    @Published private(set) var running = 0
    /// Jobs that wait for their turn (held jobs are not counted).
    @Published private(set) var waiting = 0
    /// Paused jobs (a subset of `running`).
    @Published private(set) var paused = 0
    /// The last finished batch had a failure and the user has not looked yet (dot in the notch).
    @Published private(set) var hasUnseenError = false
    /// One-line status for the menu's live row ("Converting 3 of 5 - 42%").
    @Published private(set) var statusLine: String = ""
    /// The last five results for the menu (title + first output URL).
    @Published private(set) var recentResults: [(title: String, url: URL)] = []
    var isIdle: Bool { running + waiting == 0 }

    /// How many results the menu lists.
    static let recentLimit = 5

    func markErrorsSeen() { if hasUnseenError { hasUnseenError = false } }

    // MARK: Updates (called by `JobsCoordinator`)

    /// Publishes only what changed, so an unchanged tick costs the observers nothing.
    func apply(_ a: MenuBarAggregate) {
        if fraction != a.fraction { fraction = a.fraction }
        if running != a.running { running = a.running }
        if waiting != a.waiting { waiting = a.waiting }
        if paused != a.paused { paused = a.paused }
        if statusLine != a.statusLine { statusLine = a.statusLine }
    }

    func noteFailure() { if !hasUnseenError { hasUnseenError = true } }

    /// A successful job joins the top of the recent list (its first output); the same file is not listed twice.
    func noteFinished(title: String, outputs: [URL]) {
        guard let first = outputs.first else { return }
        var list = recentResults.filter { $0.url != first }
        list.insert((title, first), at: 0)
        if list.count > Self.recentLimit { list.removeLast(list.count - Self.recentLimit) }
        recentResults = list
    }

    /// Fills the list from the persisted history (newest first) when the app starts.
    func seed(from history: [JobRecord]) {
        guard recentResults.isEmpty else { return }
        for r in history where r.state == .done {
            guard let path = r.outputs.first else { continue }
            recentResults.append((r.title, URL(fileURLWithPath: path)))
            if recentResults.count >= Self.recentLimit { break }
        }
    }

    /// Back to the empty state (tests).
    func reset() {
        apply(.idle)
        hasUnseenError = false
        recentResults = []
    }
}
