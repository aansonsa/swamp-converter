import SwiftUI
import AppKit
import Combine

/// The one place that listens. It subscribes ONCE to `JobRunner.events()` and `MessageCenter.events()` (AsyncStreams, no polling) and routes:
///   * messages (errors, "Path copied", info)                  -> `ToastCenter`
///   * a quick-run job                                          -> `JobHUDController` (a card)
///   * running / waiting / paused jobs, results, failures       -> `MenuBarProgressModel` (at most 10 Hz) and the Dock badge
///   * a finished batch                                         -> `NotificationService` (one per batch; the policy decides)
/// While nothing happens it does nothing: the only scheduled work is one trailing block of the 10 Hz throttle, armed by a change and gone a tenth of a second later.
@MainActor
final class JobsCoordinator {
    static let shared = JobsCoordinator()

    let runner: JobRunner
    private let messages: MessageCenter
    let model: MenuBarProgressModel
    private let toasts: ToastCenter
    private let notifications: NotificationService
    private let hud: JobHUDController
    /// Where the Dock badge text goes (tests record it).
    var setDockBadge: (String?) -> Void = { label in (NSApp as NSApplication?)?.dockTile.badgeLabel = label }
    /// Is the Jobs window open? A failure the person is looking at needs no "unseen" dot.
    var jobsWindowVisible: () -> Bool = { JobsWindowController.shared.isVisible }

    private var known: [UUID: Job] = [:]
    private var progressWatch: [UUID: AnyCancellable] = [:]
    private var sessionFinished = 0
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var lastBadge: String?
    private var throttle: ThrottledAction?
    /// How many times the model was recomputed (tests: the throttle bounds it).
    private(set) var refreshCount = 0

    /// True while a throttled refresh is waiting to run (nothing else is ever pending).
    var hasPendingWork: Bool { throttle?.isPending ?? false }

    init(runner: JobRunner? = nil, messages: MessageCenter? = nil, model: MenuBarProgressModel? = nil, toasts: ToastCenter? = nil,
         notifications: NotificationService? = nil, hud: JobHUDController? = nil) {
        self.runner = runner ?? JobRunner.shared
        self.messages = messages ?? MessageCenter.shared
        self.model = model ?? MenuBarProgressModel.shared
        self.toasts = toasts ?? ToastCenter.shared
        self.notifications = notifications ?? NotificationService.shared
        self.hud = hud ?? JobHUDController.shared
    }

    /// Subscribes to the streams. Idempotent. Messages posted just before (the runner reports dropped queue entries while it is created) are replayed once.
    func start() {
        guard !started else { return }
        started = true
        notifications.attach()

        let messageStream = messages.events()
        let jobStream = runner.events()
        for m in messages.recent where Date().timeIntervalSince(m.date) < 10 { toasts.show(m) }
        for job in runner.jobs where !job.state.isFinished {
            known[job.id] = job
            if job.state == .running { watchProgress(job) }
        }
        model.seed(from: runner.history)
        refreshNow()

        tasks = [
            Task { @MainActor [weak self] in
                for await message in messageStream { self?.toasts.show(message) }
            },
            Task { @MainActor [weak self] in
                for await event in jobStream { self?.handle(event) }
            }
        ]
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        progressWatch.removeAll()
        started = false
    }

    /// A quick run (wheel, Services, hotkey, Dock drop) gets a card; Studio jobs live in the Studio queue and the Jobs window, unattended ones stay silent.
    static func isHUDEligible(_ job: Job) -> Bool { job.mode == .quick }

    // MARK: Events

    func handle(_ event: JobEvent) {
        switch event {
        case .added(let job):
            known[job.id] = job
            if Self.isHUDEligible(job) { hud.add(job) }
            scheduleRefresh()
        case .started(let job):
            known[job.id] = job
            watchProgress(job)
            scheduleRefresh()
        case .progress, .paused, .resumed, .queueStateChanged:
            scheduleRefresh()
        case .removed(let id):
            known[id] = nil
            progressWatch[id] = nil
            scheduleRefresh()
        case .finished(let job):
            ended(job)
            model.noteFinished(title: job.title, outputs: job.outputs)
        case .failed(let job):
            ended(job)
            noteFailure()
        case .cancelled(let job):
            ended(job)
        case .batchFinished(let summary):
            notifications.post(batch: summary, handledByHUD: hud.handled(batch: summary.batchID))
            CompletionSound.batchFinished(summary)
            hud.forget(batch: summary.batchID)
            if summary.failed > 0 { noteFailure() }
        }
    }

    private func ended(_ job: Job) {
        progressWatch[job.id] = nil
        if known.removeValue(forKey: job.id) != nil { sessionFinished += 1 }
        hud.jobEnded(job)
        scheduleRefresh()
    }

    private func noteFailure() {
        if !jobsWindowVisible() { model.noteFailure() }
    }

    /// A running job publishes its progress; each change asks for a (throttled) refresh. `receive(on:)` makes the sink run after the value is stored.
    private func watchProgress(_ job: Job) {
        progressWatch[job.id] = job.$progress.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }
    }

    // MARK: Refresh (at most 10 Hz)

    func scheduleRefresh() {
        if throttle == nil { throttle = ThrottledAction { [weak self] in self?.refreshNow() } }
        throttle?.request()
    }

    func refreshNow() {
        refreshCount += 1
        let inputs = known.values.map { JobProgressInput(state: $0.state, held: $0.held, progress: $0.progress, isDownload: $0.isLinkJob) }
        let aggregate = MenuBarAggregate.make(active: inputs, finishedInSession: sessionFinished, queuePaused: runner.queuePaused)
        model.apply(aggregate)
        if aggregate.isIdle { sessionFinished = 0 }
        let count = aggregate.running + aggregate.waiting
        let badge = count > 0 ? String(count) : nil
        if badge != lastBadge {
            lastBadge = badge
            setDockBadge(badge)
        }
    }
}
