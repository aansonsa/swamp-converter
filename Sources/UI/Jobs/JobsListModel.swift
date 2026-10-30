import SwiftUI
import Combine

/// The three sections of the Jobs window and the reordering rule, as plain data (tested without a window).
@MainActor
final class JobsListModel: ObservableObject {
    /// Bumps when a job changes state, appears or goes: the sections are recomputed. Progress does not bump it (the rows watch their own jobs).
    @Published private(set) var revision = 0
    /// The job whose log sheet is open.
    @Published var logJob: Job?

    let runner: JobRunner
    /// Snapshots and tests show a fixed set of jobs instead of the runner's.
    private let fixedJobs: [Job]?
    private var task: Task<Void, Never>?

    init(runner: JobRunner? = nil, jobs: [Job]? = nil) {
        self.runner = runner ?? JobRunner.shared
        self.fixedJobs = jobs
    }

    var allJobs: [Job] { fixedJobs ?? runner.jobs }

    /// Subscribes to the runner's events while the window is open. Idempotent.
    func start() {
        guard task == nil else { return }
        let stream = runner.events()
        task = Task { @MainActor [weak self] in
            for await event in stream { self?.consume(event) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func consume(_ event: JobEvent) {
        if case .progress = event { return }
        revision &+= 1
    }

    // MARK: Sections

    static func running(_ jobs: [Job]) -> [Job] { jobs.filter { $0.state.isActive } }
    static func queued(_ jobs: [Job]) -> [Job] { jobs.filter { $0.state == .waiting } }
    /// Newest first.
    static func finished(_ jobs: [Job]) -> [Job] {
        jobs.filter { $0.state.isFinished }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var running: [Job] { Self.running(allJobs) }
    var queued: [Job] { Self.queued(allJobs) }
    var finished: [Job] { Self.finished(allJobs) }
    var isEmpty: Bool { allJobs.isEmpty }

    var canClearFinished: Bool { allJobs.contains { $0.state.isFinished } }
    var hasWork: Bool { allJobs.contains { !$0.state.isFinished && !($0.state == .waiting && $0.held) } }

    // MARK: Actions

    func clearFinished() { runner.removeFinished() }

    func toggleQueuePause() {
        if runner.queuePaused { runner.resumeQueue() } else { runner.pauseQueue() }
    }

    /// Translates a move inside the "Queued" section into the runner's indices (`move(fromOffsets:toOffset:)` works on all jobs): `from` and `to` are offsets within the queued list.
    static func moveArguments(all: [UUID], queued: [UUID], from: IndexSet, to: Int) -> (source: IndexSet, destination: Int)? {
        guard !queued.isEmpty, from.allSatisfy({ queued.indices.contains($0) }) else { return nil }
        var source = IndexSet()
        for i in from {
            guard let at = all.firstIndex(of: queued[i]) else { return nil }
            source.insert(at)
        }
        let destination: Int
        if to < queued.count {
            guard let at = all.firstIndex(of: queued[to]) else { return nil }
            destination = at
        } else {
            guard let last = all.lastIndex(of: queued[queued.count - 1]) else { return nil }
            destination = last + 1
        }
        return (source, destination)
    }

    func moveQueued(from: IndexSet, to: Int) {
        let queuedJobs = queued
        guard let args = Self.moveArguments(all: allJobs.map(\.id), queued: queuedJobs.map(\.id), from: from, to: to) else { return }
        runner.move(fromOffsets: args.source, toOffset: args.destination)
    }
}
