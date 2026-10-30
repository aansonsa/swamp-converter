import Foundation
import Combine

// The queue. One JobRunner.shared serves the wheel, Services, watched folders AND the Studio queue.
//
//  submit(...)       create a job and (by default) let the scheduler start it
//  enqueue(...)      create a job but hold it ("Add to Queue"); startQueue() releases every held job
//  pauseQueue()      stop starting new jobs and pause running ones (SIGSTOP on child processes); resumeQueue() undoes it
//  pause/resume/cancel/retry/remove/move   per job
//  updateOverrides   per-job option override while the job is waiting
//  events            AsyncStream of JobEvent for notifications / HUD / menu-bar progress
//
// Scheduling: at most `maxConcurrent` jobs run at once; `.video` class jobs run one at a time; `.exclusive` runs alone.
// Safety: originals are never modified; trashing the original after success is opt-in (OutputRules.trashSource).

@MainActor
final class JobRunner: ObservableObject {
    static let shared = JobRunner(persistence: true)

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var history: [JobRecord] = []
    @Published private(set) var queuePaused = false

    /// (read by JobRunner+Persistence.swift: secrets are dropped from the saved queue by the operation's schema)
    let registry: OperationRegistry
    private let settings: AppSettings
    /// (read by JobRunner+Persistence.swift)
    let persistence: Bool
    /// Where queue.json, history.json and the job logs live; nil = the standard Application Support folder (`AppPaths`). Tests pass a temp folder.
    /// (read by JobRunner+Persistence.swift)
    let stateDirectory: URL?
    private var subscribers: [UUID: AsyncStream<JobEvent>.Continuation] = [:]
    var saveWork: DispatchWorkItem?
    var historyWork: DispatchWorkItem?
    private var settingsObserver: AnyCancellable?
    /// Overrides the scheduler's concurrency (tests); nil = settings.maxConcurrentJobs.
    var maxConcurrentOverride: Int?

    init(persistence: Bool, registry: OperationRegistry = .shared, settings: AppSettings = .shared, stateDirectory: URL? = nil) {
        self.persistence = persistence
        self.stateDirectory = stateDirectory
        self.registry = registry
        self.settings = settings
        if persistence { restore() }
        // Several runners may exist (the shared one, test runners): each registers its own handler, which drops itself when the runner is gone.
        SystemEnvironmentMonitor.shared.addHandler { [weak self] in
            guard let self else { return false }
            self.environmentChanged()
            return true
        }
        // A setting that decides whether waiting jobs may start (pause background work on battery, concurrency) re-runs the scheduler at once.
        settingsObserver = settings.$revision.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.pump() } }
    }

    /// Parallel jobs allowed now: the user's setting lowered by the environment (Low Power Mode, heat, core count).
    var maxConcurrent: Int {
        if let o = maxConcurrentOverride { return max(1, o) }
        return ResourcePolicy.maxConcurrent(requested: settings.data.maxConcurrentJobs, env: SystemEnvironment.current())
    }

    /// Thermal state, Low Power Mode or power source changed: waiting background jobs may start (or must keep waiting).
    private func environmentChanged() { pump() }

    // MARK: Events

    /// A new stream of events. Cancel the consuming task to unsubscribe. The buffer is bounded (the newest 100 events): a subscriber that stops reading
    /// can never make the app hold on to jobs; UI refreshes from `jobs` and `history`, the events only say that something changed.
    func events() -> AsyncStream<JobEvent> {
        let token = UUID()
        return AsyncStream(JobEvent.self, bufferingPolicy: .bufferingNewest(100)) { cont in
            subscribers[token] = cont
            cont.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[token] = nil } }
        }
    }

    private func emit(_ e: JobEvent) { subscribers.values.forEach { $0.yield(e) } }

    // MARK: Queries

    var summary: RunnerSummary {
        let active = jobs.filter { !$0.state.isFinished }
        let running = active.filter { $0.state == .running }.count
        let paused = active.filter { $0.state == .paused }.count
        let waiting = active.filter { $0.state == .waiting }.count
        let ps = active.compactMap { $0.progress }
        let progress = ps.isEmpty ? nil : ps.reduce(0, +) / Double(active.count)
        return RunnerSummary(running: running, waiting: waiting, paused: paused, progress: progress)
    }

    func job(id: UUID) -> Job? { jobs.first { $0.id == id } }

    // MARK: Submitting

    /// Creates a job for `operation` and lets the scheduler start it.
    @discardableResult
    func submit(operation: Operation, items: [FileItem], overrides: OptionValues = OptionValues(), origin: JobOrigin = .wheel,
                mode: RunMode = .quick, outputRules: OutputRules? = nil, held: Bool = false, batchID: UUID = UUID()) -> Job {
        let job = Job(batchID: batchID, operationID: operation.meta.id, title: operation.jobTitle, items: items, overrides: overrides,
                      outputRules: outputRules, origin: origin, mode: mode, held: held)
        jobs.append(job)
        if mode != .automatic { remember(operation: operation, overrides: overrides) }
        emit(.added(job))
        persistQueue()
        pump()
        return job
    }

    /// Link jobs (downloads): same as `submit(operation:items:...)` for operations with `meta.acceptsLinks`.
    @discardableResult
    func submit(operation: Operation, links: [LinkItem], overrides: OptionValues = OptionValues(), origin: JobOrigin = .wheel,
                mode: RunMode = .quick, outputRules: OutputRules? = nil, held: Bool = false, batchID: UUID = UUID()) -> Job {
        let title = links.count == 1 ? "\(operation.meta.label.text): \(links[0].displayTitle)" : operation.meta.label.text
        let job = Job(batchID: batchID, operationID: operation.meta.id, title: title, items: [], links: links, overrides: overrides,
                      outputRules: outputRules, origin: origin, mode: mode, held: held)
        jobs.append(job)
        if mode != .automatic { remember(operation: operation, overrides: overrides) }
        emit(.added(job))
        persistQueue()
        pump()
        return job
    }

    /// Runs a Recipe on links (the Studio's Download target, a preset applied to a link). nil when the operation no longer exists.
    @discardableResult
    func submit(recipe: Recipe, links: [LinkItem], origin: JobOrigin = .studio, mode: RunMode = .studio, held: Bool = false, batchID: UUID = UUID()) -> Job? {
        guard let op = registry.operation(id: recipe.operationID) ?? registry.primaryOperation(forTarget: recipe.operationID), op.meta.acceptsLinks else { return nil }
        return submit(operation: op, links: links, overrides: recipe.values, origin: origin, mode: mode, outputRules: recipe.output, held: held, batchID: batchID)
    }

    /// "Add to Queue" for links.
    @discardableResult
    func enqueue(operation: Operation, links: [LinkItem], overrides: OptionValues = OptionValues(), origin: JobOrigin = .studio, mode: RunMode = .studio,
                 outputRules: OutputRules? = nil, batchID: UUID = UUID()) -> Job {
        submit(operation: operation, links: links, overrides: overrides, origin: origin, mode: mode, outputRules: outputRules, held: true, batchID: batchID)
    }

    /// "Add to Queue": same as submit but held until `startQueue()` / `start(job)`.
    @discardableResult
    func enqueue(operation: Operation, items: [FileItem], overrides: OptionValues = OptionValues(), origin: JobOrigin = .studio,
                 mode: RunMode = .studio, outputRules: OutputRules? = nil, batchID: UUID = UUID()) -> Job {
        submit(operation: operation, items: items, overrides: overrides, origin: origin, mode: mode, outputRules: outputRules, held: true, batchID: batchID)
    }

    /// Runs a Recipe. Returns nil when the operation no longer exists (deleted preset).
    @discardableResult
    func submit(recipe: Recipe, items: [FileItem], origin: JobOrigin = .studio, mode: RunMode = .studio, held: Bool = false, batchID: UUID = UUID()) -> Job? {
        guard let op = registry.operation(id: recipe.operationID) ?? registry.primaryOperation(forTarget: recipe.operationID) else { return nil }
        return submit(operation: op, items: items, overrides: recipe.values, origin: origin, mode: mode, outputRules: recipe.output, held: held, batchID: batchID)
    }

    private func remember(operation: Operation, overrides: OptionValues) {
        settings.update { $0.lastRecipe = Recipe(operationID: operation.meta.id, values: overrides) }
    }

    // MARK: Control

    /// Releases every held job and lets the scheduler run them in order ("Start Queue").
    func startQueue() {
        for j in jobs where j.state == .waiting && j.held { j.held = false }
        queuePaused = false
        emit(.queueStateChanged)
        persistQueue()
        pump()
    }

    func start(_ job: Job) {
        guard job.state == .waiting else { return }
        job.held = false
        persistQueue()
        pump()
    }

    func pauseQueue() {
        queuePaused = true
        for j in jobs where j.state == .running { pause(j) }
        emit(.queueStateChanged)
    }

    func resumeQueue() {
        queuePaused = false
        for j in jobs where j.state == .paused { resume(j) }
        emit(.queueStateChanged)
        pump()
    }

    func pause(_ job: Job) {
        switch job.state {
        case .running:
            job.context?.pauseGate.pause()
            job.context?.processes.suspendAll()
            job.markPaused(true)
            emit(.paused(job))
        case .waiting:
            job.held = true
            persistQueue()
        default: break
        }
    }

    func resume(_ job: Job) {
        switch job.state {
        case .paused:
            job.context?.pauseGate.resume()
            job.context?.processes.resumeAll()
            job.markPaused(false)
            emit(.resumed(job))
        case .waiting:
            job.held = false
            pump()
        default: break
        }
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .waiting:
            job.finish(.cancelled)
            emit(.cancelled(job))
            afterFinish(job)
        case .running, .paused:
            job.markCancelRequested()
            job.context?.pauseGate.resume()
            job.context?.processes.cancelAll()
            job.task?.cancel()
        default: break
        }
    }

    func cancelAll() { for j in jobs where !j.state.isFinished { cancel(j) } }

    func retry(_ job: Job) {
        guard job.state == .failed || job.state == .cancelled || job.state == .skipped else { return }
        job.reset(for: true)
        persistQueue()
        pump()
    }

    func remove(_ job: Job) {
        if !job.state.isFinished { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        emit(.removed(job.id))
        persistQueue()
    }

    func removeFinished() {
        let gone = jobs.filter { $0.state.isFinished }
        jobs.removeAll { $0.state.isFinished }
        gone.forEach { emit(.removed($0.id)) }
    }

    /// Reorders WAITING jobs only (indices refer to `jobs`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = jobs
        let moving = source.sorted().map { list[$0] }
        guard moving.allSatisfy({ $0.state == .waiting }) else { return }
        for i in source.sorted().reversed() { list.remove(at: i) }
        let shift = source.filter { $0 < destination }.count
        list.insert(contentsOf: moving, at: max(0, min(list.count, destination - shift)))
        jobs = list
        persistQueue()
        pump()
    }

    /// Per-job option override (Studio inspector on a selected queue row). Only while waiting.
    @discardableResult
    func updateOverrides(_ job: Job, _ values: OptionValues, outputRules: OutputRules? = nil) -> Bool {
        guard job.state == .waiting else { return false }
        job.overrides = values
        if let r = outputRules { job.outputRules = r }
        persistQueue()
        return true
    }

    // MARK: Scheduling

    private func canStart(_ job: Job, running: [Job]) -> Bool {
        guard let op = registry.operation(id: job.operationID) else { return true }   // will fail fast
        if running.count >= maxConcurrent { return false }
        let runningOps = running.compactMap { registry.operation(id: $0.operationID) }
        if runningOps.contains(where: { $0.meta.concurrency == .exclusive }) { return false }
        switch op.meta.concurrency {
        case .exclusive: return running.isEmpty
        case .video: return !runningOps.contains { $0.meta.concurrency == .video }
        case .light: return true
        }
    }

    private func pump() {
        defer { updateSleepGuard() }
        guard !queuePaused else { return }
        let env = SystemEnvironment.current()
        let hold = ResourcePolicy.holdsBackgroundWork(env: env, pauseOnBattery: settings.data.pauseBackgroundOnBattery)
        for job in jobs where job.state == .waiting && !job.held {
            if hold && ResourcePolicy.isBackground(origin: job.origin, mode: job.mode) { continue }
            let running = jobs.filter { $0.state.isActive }
            if canStart(job, running: running) { run(job) }
        }
    }

    /// The Mac may not idle-sleep while a job runs; released the moment nothing runs.
    private func updateSleepGuard() {
        if jobs.contains(where: { $0.state == .running }) { SleepGuard.shared.hold() } else { SleepGuard.shared.release() }
    }

    private func run(_ job: Job) {
        guard let op = registry.operation(id: job.operationID) else {
            job.finish(.failed, error: L("The action no longer exists (deleted preset?).", "Действие больше не существует (шаблон удалён?)."))
            emit(.failed(job)); afterFinish(job); return
        }
        let snap = settings.data
        let items = job.items
        let links = job.links
        var resolved = QuickRecipes.resolve(op, items: items, settings: snap, extra: [job.overrides], mode: job.mode)
        // Source-dependent defaults need a probe; Studio passes complete overrides, quick runs rarely need it.
        var rules = OutputRules(options: job.overrides, base: job.outputRules ?? snap.output)
        if job.mode == .quick, snap.revealResult, rules.after == .nothing { rules.after = .reveal }
        if job.mode == .automatic { rules.after = .nothing }
        if resolved.hasErrors, let first = resolved.messages.first(where: { $0.severity == .error }) {
            job.finish(.failed, error: first.text.text)
            emit(.failed(job)); afterFinish(job); return
        }
        resolved.messages = resolved.messages.filter { $0.severity != .error }
        // Preflight: refuse early when the output cannot fit (file jobs; the downloader checks after its info fetch).
        if snap.freeSpaceGuard, !items.isEmpty, let bytes = op.estimate(options: resolved.values, items: items, source: nil)?.bytes,
           let dir = try? OutputPaths.outputDirectory(for: items[0], rules: rules) {
            let verdict = DiskSpaceGuard.check(estimatedOutput: bytes, outputDir: dir)
            if verdict.level == .insufficient {
                job.finish(.failed, error: verdict.message?.text ?? "")
                emit(.failed(job)); afterFinish(job); return
            }
            if let m = verdict.message { job.appendLog("WARNING: " + m.en) }
        }
        let background = ResourcePolicy.isBackground(origin: job.origin, mode: job.mode)
        let env = SystemEnvironment.current()
        let ctx = OperationContext(jobID: job.id, operationID: op.meta.id, mode: job.mode, resolved: resolved, outputRules: rules,
                                   settings: snap, tools: ToolLocator.shared, stagePlan: op.stagePlan(options: resolved.values),
                                   isBackground: background, preferHardware: ResourcePolicy.preferHardwareEncoders(env: env))
        ctx.onStages = { [weak job] stages in Task { @MainActor in job?.setStages(stages) } }
        ctx.onProgress = { [weak job] p, m, eta in Task { @MainActor in job?.update(progress: p, message: m, etaHint: eta) } }
        ctx.onLog = { [weak job] line in Task { @MainActor in job?.appendLog(line) } }
        ctx.onCurrentItem = { [weak job] item, i, n in Task { @MainActor in job?.setCurrent(item: item, index: i, count: n) } }
        job.context = ctx
        job.markStarted(finishAction: rules.after)
        job.setStages(ctx.stages)
        job.appendLog("[\(ISO8601DateFormatter().string(from: Date()))] \(op.meta.id) on \(links.isEmpty ? "\(items.count) item(s)" : "\(links.count) link(s)")" + (op.meta.usesNetwork ? " (uses the network)" : ""))
        emit(.started(job))
        persistQueue()
        job.task = Task.detached(priority: ResourcePolicy.taskPriority(origin: job.origin, mode: job.mode)) { [weak self] in
            do {
                let result = links.isEmpty ? try await op.execute(items: items, ctx: ctx) : try await op.executeLinks(links, ctx: ctx)
                try Task.checkCancellation()
                await self?.complete(job, result: result, rules: rules)
            } catch is CancellationError {
                await self?.completeCancelled(job)
            } catch {
                await self?.completeFailed(job, error: error)
            }
            ctx.cleanupTemp()
        }
    }

    private func complete(_ job: Job, result: OperationResult, rules: OutputRules) {
        job.finish(.done, result: result)
        job.appendLog("Done: \(result.outputs.map(\.lastPathComponent).joined(separator: ", "))")
        if rules.trashSource && !result.outputs.isEmpty { trashOriginals(of: job) }
        job.context = nil
        writeJobLog(job)
        emit(.finished(job))
        afterFinish(job)
    }

    private func completeCancelled(_ job: Job) {
        job.finish(.cancelled)
        job.appendLog("Canceled")
        job.context = nil
        emit(.cancelled(job))
        afterFinish(job)
    }

    private func completeFailed(_ job: Job, error: Error) {
        let msg = ConversionError.describe(error)
        if case ConversionError.toolMissing(let tool) = error { job.noteMissingTool(tool) }
        job.finish(.failed, error: msg)
        job.appendLog("ERROR: \(msg)")
        job.context = nil
        writeJobLog(job)
        emit(.failed(job))
        afterFinish(job)
    }

    private func trashOriginals(of job: Job) {
        guard !job.isLinkJob else { return }
        for item in job.items { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
    }

    /// Finished jobs stay visible for a while (Jobs window), but the in-memory list is capped: the persisted history keeps the rest.
    static let finishedJobsKept = 40
    /// Records kept in the history list (and history.json).
    static let historyKept = 200

    private func trimFinished() {
        let finished = jobs.filter { $0.state.isFinished }
        guard finished.count > Self.finishedJobsKept else { return }
        let drop = Set(finished.prefix(finished.count - Self.finishedJobsKept).map(\.id))
        jobs.removeAll { drop.contains($0.id) }
        drop.forEach { emit(.removed($0)) }
    }

    private func afterFinish(_ job: Job) {
        job.task = nil
        addToHistory(job)
        trimFinished()
        persistQueue()
        pump()
        checkBatch(job.batchID)
    }

    private func checkBatch(_ batchID: UUID) {
        let batch = jobs.filter { $0.batchID == batchID }
        guard !batch.isEmpty, batch.allSatisfy({ $0.state.isFinished }) else { return }
        let ok = batch.filter { $0.state == .done }
        emit(.batchFinished(BatchSummary(
            batchID: batchID, total: batch.count, succeeded: ok.count,
            failed: batch.filter { $0.state == .failed }.count, cancelled: batch.filter { $0.state == .cancelled }.count,
            outputs: ok.flatMap(\.outputs), firstTitle: batch[0].title,
            firstError: batch.first(where: { $0.state == .failed })?.errorMessage,
            finishAction: batch[0].finishAction, automatic: batch[0].isAutomatic)))
    }

    /// Suspends until nothing is waiting or running (tests, scripted use).
    func waitUntilIdle(timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while jobs.contains(where: { !$0.state.isFinished && !($0.held && $0.state == .waiting) }) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: History (the files are in JobRunner+Persistence.swift)

    private func addToHistory(_ job: Job) {
        let rec = JobRecord(id: job.id, title: job.title, operationID: job.operationID, state: job.state, origin: job.origin,
                            itemNames: job.inputNames, linkURLs: job.isLinkJob ? job.links.map(\.url.absoluteString) : nil, outputs: job.outputs.map(\.path), errorMessage: job.errorMessage, note: job.note,
                            startedAt: job.startedAt, finishedAt: job.finishedAt, bytesIn: job.totalInputBytes)
        history.insert(rec, at: 0)
        if history.count > Self.historyKept { history.removeLast(history.count - Self.historyKept) }
        persistHistory()
    }

    func clearHistory() {
        history = []
        historyWork?.cancel(); historyWork = nil
        if persistence { try? FileManager.default.removeItem(at: historyFileURL) }
    }

    /// Reloads history and the unfinished queue. Restored jobs are HELD: the user presses Start Queue.
    /// A job whose input files are all gone (an unplugged drive, a deleted folder) is dropped with one calm notice; a job with some files left keeps those.
    private func restore() {
        if let d = try? Data(contentsOf: historyFileURL), let h = try? JSONDecoder().decode([JobRecord].self, from: d) { history = Array(h.prefix(Self.historyKept)) }
        guard let d = try? Data(contentsOf: queueFileURL), let recs = try? JSONDecoder().decode([QueuedJobRecord].self, from: d) else { return }
        var dropped = 0
        for r in recs {
            let items = r.itemPaths.map { FileItem(url: URL(fileURLWithPath: $0)) }.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            var links: [LinkItem] = []
            for (i, raw) in (r.linkURLs ?? []).enumerated() {
                guard let url = URL(string: raw), LinkParsing.isDownloadable(url) else { continue }
                let known = r.linkTitles?[safe: i]
                links.append(LinkItem(url: url, title: known?.isEmpty == false ? known : nil))
            }
            guard !items.isEmpty || !links.isEmpty else { dropped += 1; continue }
            jobs.append(Job(id: r.id, batchID: r.batchID, operationID: r.operationID, title: r.title, items: items, links: links, overrides: r.overrides,
                            outputRules: r.outputRules, origin: r.origin, mode: r.mode, held: true))
        }
        if dropped > 0 {
            MessageCenter.shared.post(L("\(dropped) queued job(s) were removed because their files are no longer there.",
                                        "Задач удалено из очереди: \(dropped), их файлов больше нет."), severity: .info, symbol: "tray.full")
        }
    }
}
