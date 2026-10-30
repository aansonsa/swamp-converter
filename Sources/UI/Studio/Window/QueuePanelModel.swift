import SwiftUI
import AppKit

// The behaviour of the queue panel, apart from its views, so tests can drive it against a runner of their own: selection, removal with undo, skip, retry, stop, reorder,
// duplicate with another preset, convert again, copy as command. Queue edits go through `JobRunner`; nothing here keeps a job alive that the runner dropped.

@MainActor
final class QueuePanelModel: ObservableObject {
    let runner: JobRunner
    let registry: OperationRegistry
    weak var host: StudioWindowModel?

    @Published var selection = Set<UUID>()
    @Published var logJob: Job?
    @Published var confirmStop = false
    @Published var bulkEditing = false
    /// The last removal, kept so it can be undone (waiting jobs only: there is nothing to restore of a finished one).
    @Published private(set) var lastRemoved: [RemovedJobSnapshot] = []

    init(runner: JobRunner, registry: OperationRegistry = .shared, host: StudioWindowModel? = nil) {
        self.runner = runner; self.registry = registry; self.host = host
    }

    var jobs: [Job] { runner.jobs }

    func selectedJobs() -> [Job] { runner.jobs.filter { selection.contains($0.id) } }
    func jobs(for ids: Set<UUID>) -> [Job] { runner.jobs.filter { ids.contains($0.id) } }

    // MARK: Header actions

    var snapshot: QueueSnapshot { QueueSnapshot.make(runner) }

    /// Start Queue when something waits to be started, Resume while the queue is paused.
    func startOrResume() {
        if runner.queuePaused { runner.resumeQueue() }
        if let host { host.startQueue() } else { runner.startQueue() }
    }

    func pauseOrResume() {
        if runner.queuePaused { runner.resumeQueue() } else { runner.pauseQueue() }
    }

    /// True when stopping would throw away more than about half a minute of work (calm: only then does the person get asked).
    var stopNeedsConfirmation: Bool {
        runner.jobs.contains { $0.state.isActive && $0.elapsed > 30 }
    }

    /// Stop: running jobs are cancelled, everything that waits is held again so the queue does not carry on by itself.
    func stop() {
        for j in runner.jobs {
            switch j.state {
            case .running, .paused: runner.cancel(j)
            case .waiting: runner.pause(j)
            default: break
            }
        }
        confirmStop = false
    }

    func requestStop() { if stopNeedsConfirmation { confirmStop = true } else { stop() } }

    func clearFinished() { runner.removeFinished(); selection = selection.filter { id in runner.jobs.contains { $0.id == id } } }

    func retryFailed() { for j in runner.jobs where j.state == .failed { runner.retry(j) } }

    // MARK: Row actions

    func remove(ids: Set<UUID>) {
        let victims = jobs(for: ids)
        var snaps: [RemovedJobSnapshot] = []
        for (i, j) in runner.jobs.enumerated() where ids.contains(j.id) && j.state == .waiting {
            snaps.append(RemovedJobSnapshot(operationID: j.operationID, items: j.items, links: j.links, overrides: j.overrides, outputRules: j.outputRules, index: i, title: j.title))
        }
        for j in victims { runner.remove(j) }
        selection.subtract(ids)
        lastRemoved = snaps
    }

    /// Puts the removed waiting jobs back, held, at their old places.
    func undoRemove() {
        let snaps = lastRemoved.sorted { $0.index < $1.index }
        lastRemoved = []
        for s in snaps {
            guard let op = registry.operation(id: s.operationID) else { continue }
            let job = s.links.isEmpty
                ? runner.enqueue(operation: op, items: s.items, overrides: s.overrides, outputRules: s.outputRules)
                : runner.enqueue(operation: op, links: s.links, overrides: s.overrides, outputRules: s.outputRules)
            if let from = runner.jobs.firstIndex(where: { $0.id == job.id }), from != s.index, s.index < runner.jobs.count {
                runner.move(fromOffsets: IndexSet(integer: from), toOffset: s.index)
            }
        }
    }

    func dismissUndo() { lastRemoved = [] }

    /// Skip: the job does not run (it is cancelled while it waits).
    func skip(ids: Set<UUID>) { for j in jobs(for: ids) where j.state == .waiting { runner.cancel(j) } }

    func retry(ids: Set<UUID>) { for j in jobs(for: ids) { runner.retry(j) } }

    func pause(ids: Set<UUID>) { for j in jobs(for: ids) { runner.pause(j) } }
    func resume(ids: Set<UUID>) { for j in jobs(for: ids) { runner.resume(j) } }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) { runner.move(fromOffsets: source, toOffset: destination) }

    // MARK: Derived jobs

    /// Presets of the job's target, for "Duplicate with a different preset".
    func presets(for job: Job) -> [Preset] {
        guard let op = registry.operation(id: job.operationID) else { return [] }
        return PresetStore.shared.presets(for: op.meta.schemaID)
    }

    /// Adds a held copy of the job that uses the preset's values instead of the job's own edits. Returns it (nil when its operation is gone).
    @discardableResult
    func duplicate(_ job: Job, with preset: Preset) -> Job? {
        guard let op = preset.operationID.flatMap({ registry.operation(id: $0) }) ?? registry.operation(id: job.operationID) ?? registry.primaryOperation(forTarget: preset.targetID) else { return nil }
        return job.links.isEmpty
            ? runner.enqueue(operation: op, items: job.items, overrides: preset.values, outputRules: job.outputRules)
            : runner.enqueue(operation: op, links: job.links, overrides: preset.values, outputRules: job.outputRules)
    }

    /// Other targets the job's files can be converted to ("Convert Again As...").
    func otherTargets(for job: Job) -> [StudioTarget] {
        guard !job.items.isEmpty else { return [] }
        let own = registry.operation(id: job.operationID)?.meta.schemaID
        return registry.studioTargets(for: job.items).filter { $0.id != own || $0.operations.count > 1 }
    }

    func convertAgain(_ job: Job, target: String) {
        StudioWindowController.shared.show(input: IncomingInput(files: job.items, links: job.links), target: target, reuseOpen: false)
    }

    /// "Edit Options": a waiting job goes back into a session. The window's own session takes it when it is empty, otherwise a new window opens.
    func editOptions(_ job: Job) {
        guard job.state == .waiting else { return }
        if let host, host.state.isEmpty { host.session.load(job: job); host.pane = .source; return }
        let model = StudioWindowController.shared.open(session: StudioSession(input: IncomingInput()))
        model.session.load(job: job)
    }

    func commandLine(for job: Job) -> String {
        let dir = job.outputRules?.dirMode == .custom ? job.outputRules?.customDir : nil
        return StudioCommandLine.command(operationID: job.operationID, files: job.items.map(\.url), values: job.overrides, outputDirectory: dir)
    }

    func copyCommand(_ job: Job) {
        let text = commandLine(for: job)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let skipped = StudioCommandLine.unsupportedKeys(in: job.overrides)
        MessageCenter.shared.post(skipped.isEmpty ? L("Command copied", "Команда скопирована")
                                  : L("Command copied; track lists are not part of it", "Команда скопирована; списки дорожек в неё не входят"), severity: .info, symbol: "terminal")
    }

    func reveal(_ job: Job) {
        guard !job.outputs.isEmpty else { return }
        ResultActions.reveal(job.outputs)
    }

    func open(_ job: Job) {
        guard !job.outputs.isEmpty else { return }
        ResultActions.open(job.outputs)
    }

    // MARK: Multi-selection editing

    /// Rows that wait and run the same target can be edited together.
    func canEditTogether(_ ids: Set<UUID>) -> Bool {
        let list = jobs(for: ids)
        guard list.count > 1, list.allSatisfy({ $0.state == .waiting }) else { return false }
        return QueueBulkEdit.canEditTogether(schemaIDs: list.compactMap { registry.operation(id: $0.operationID)?.meta.schemaID })
            && list.count == list.compactMap({ registry.operation(id: $0.operationID) }).count
    }

    /// Writes ONLY the touched fields into each selected job.
    func applyBulk(_ touched: OptionValues, to ids: Set<UUID>) {
        for j in jobs(for: ids) where j.state == .waiting {
            _ = runner.updateOverrides(j, QueueBulkEdit.apply(touched, to: j.overrides))
        }
    }

    /// The value every selected job would run with for `key` ("Mixed" when they differ).
    func effectiveValues(of jobs: [Job]) -> [OptionValues] {
        jobs.compactMap { j in
            guard let op = registry.operation(id: j.operationID) else { return nil }
            return QuickRecipes.resolve(op, items: j.items, settings: AppSettings.shared.data, extra: [j.overrides], mode: .studio).values
        }
    }
}
