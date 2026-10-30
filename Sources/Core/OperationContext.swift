import Foundation

// Everything an engine needs while running one job: resolved options, output helpers, progress, log, cancellation,
// pause, process control. Created by JobRunner (and by tests via OperationContext.testing).
//
// Concurrency convention: engines are `async`. Cancellation is Swift's Task cancellation: call `try ctx.checkCancelled()`
// in loops and let `CancellationError` propagate (ProcessRunner and OutputPaths already do). Pause is cooperative:
// `try await ctx.waitIfPaused()` between work units; child processes are suspended automatically (SIGSTOP).

/// Maps the progress of item `index` of `count` into the job's overall fraction.
struct ProgressSlice: Sendable {
    let ctx: OperationContext
    let index: Int
    let count: Int
    /// `fraction` is the progress WITHIN this item (0...1).
    func report(_ fraction: Double, message: String? = nil, eta: TimeInterval? = nil) {
        let f = Util.clamp(fraction, 0, 1)
        ctx.report((Double(index) + f) / Double(max(count, 1)), message: message, eta: eta)
    }
}

/// Cooperative pause gate shared by a job: `wait()` returns immediately unless paused.
final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() {
        lock.lock(); paused = false; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
    func wait() async {
        guard isPaused else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if !enqueue(c) { c.resume() }
        }
    }

    private func enqueue(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard paused else { return false }
        waiters.append(c)
        return true
    }
}

final class OperationContext: @unchecked Sendable {
    let jobID: UUID
    let operationID: String
    let mode: RunMode
    /// Fully resolved options (defaults = the quick recipe). Never nil, never partial.
    let resolved: ResolvedOptions
    let outputRules: OutputRules
    /// Settings snapshot taken when the job started.
    let settings: SettingsData
    let tools: ToolLocator
    /// Probe of the first item when available (Studio always has it; quick runs usually not).
    var source: SourceInfo?
    let processes: ProcessSet
    let pauseGate: PauseGate
    /// Unattended work (watched folders, chains): child processes run niced at utility QoS, UI never interrupted.
    let isBackground: Bool
    /// Hardware encoders preferred (Low Power Mode, battery, warm Mac) -- engines that have a choice should honour it.
    let preferHardware: Bool
    private let stageLock = NSLock()
    private var tracker: StageTracker
    /// Called when the stage list changes (begin/finish/progress of a multi-stage job). Core throttles nothing here: the Job does.
    var onStages: (@Sendable ([StageProgress]) -> Void)?

    var onProgress: (@Sendable (Double?, String?, TimeInterval?) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onCurrentItem: (@Sendable (FileItem, Int, Int) -> Void)?

    private let tempLock = NSLock()
    private var _tempDir: URL?

    init(jobID: UUID = UUID(), operationID: String, mode: RunMode, resolved: ResolvedOptions, outputRules: OutputRules,
         settings: SettingsData, tools: ToolLocator = .shared, stagePlan: [StageSpec] = [], isBackground: Bool = false,
         preferHardware: Bool = false, parent: OperationContext? = nil) {
        self.processes = parent?.processes ?? ProcessSet()
        self.pauseGate = parent?.pauseGate ?? PauseGate()
        self.jobID = jobID; self.operationID = operationID; self.mode = mode; self.resolved = resolved
        self.outputRules = outputRules; self.settings = settings; self.tools = tools
        self.isBackground = isBackground; self.preferHardware = preferHardware
        self.tracker = StageTracker(stagePlan)
    }

    /// For unit tests and engine self-tests: resolve `op`'s quick recipe (plus `extra` layers) for `items`.
    static func testing(_ op: Operation, items: [FileItem], extra: OptionValues = OptionValues(), mode: RunMode = .quick,
                        rules: OutputRules = OutputRules(), settings: SettingsData = SettingsData()) -> OperationContext {
        let schema = op.optionSchema(for: items)
        let resolved = schema.resolve(layers: [op.quickOverrides(settings: settings), extra])
        return OperationContext(operationID: op.meta.id, mode: mode, resolved: resolved, outputRules: rules, settings: settings)
    }

    // MARK: Nested operations

    /// Runs another operation INSIDE the current job (a download's convert stage, a chain step, a multi-output pack): same job, same
    /// pause / cancel / process set, progress forwarded to the current stage, same output rules unless `outputRules` is given.
    /// `overrides` are layered over the nested operation's quick recipe. The nested run never creates a Job of its own.
    @discardableResult
    func runNested(_ op: Operation, items: [FileItem], overrides: OptionValues = OptionValues(), outputRules: OutputRules? = nil,
                   mode: RunMode? = nil) async throws -> OperationResult {
        try checkCancelled()
        let resolved = QuickRecipes.resolve(op, items: items, source: nil, settings: settings, extra: [overrides], mode: mode ?? self.mode)
        let child = OperationContext(jobID: jobID, operationID: op.meta.id, mode: mode ?? self.mode, resolved: resolved,
                                     outputRules: outputRules ?? self.outputRules, settings: settings, tools: tools,
                                     isBackground: isBackground, preferHardware: preferHardware, parent: self)
        child.onProgress = { [weak self] f, m, e in self?.report(f, message: m, eta: e) }
        child.onLog = { [weak self] line in self?.log(line) }
        child.onCurrentItem = onCurrentItem
        defer { child.cleanupTemp() }
        return try await op.execute(items: items, ctx: child)
    }

    /// Same, looked up by operation id in the shared registry (e.g. "smart.best", "video.compress").
    @discardableResult
    func runNested(operationID: String, items: [FileItem], overrides: OptionValues = OptionValues(), outputRules: OutputRules? = nil) async throws -> OperationResult {
        guard let op = OperationRegistry.shared.operation(id: operationID) else {
            throw ConversionError.message(L10n("The step \(operationID) does not exist.", "Шаг \(operationID) не существует."))
        }
        return try await runNested(op, items: items, overrides: overrides, outputRules: outputRules)
    }

    // MARK: Options

    var options: OptionValues { resolved.values }
    /// False for fields that were disabled / hidden / missing a capability. Engines ignore inactive fields.
    func isActive(_ key: String) -> Bool { resolved.isActive(key) }

    // MARK: Progress, log, cancellation

    /// Progress 0...1 of the CURRENT stage (nil = indeterminate); for operations without a stage plan that is the whole job.
    /// Core combines the stages into the overall progress and ETA. Throttling is done by the Job.
    func report(_ fraction: Double?, message: String? = nil, eta: TimeInterval? = nil) {
        stageLock.lock()
        guard tracker.isMultiStage else { stageLock.unlock(); onProgress?(fraction, message, eta); return }
        tracker.update(fraction: fraction, eta: eta, message: message)
        let overall = tracker.overallFraction, total = tracker.overallETA(), stages = tracker.stages
        stageLock.unlock()
        onProgress?(overall, message, total)
        onStages?(stages)
    }

    // MARK: Stages (multi-stage operations: download then convert ...)

    /// The declared plan with the live state of every stage.
    var stages: [StageProgress] { stageLock.lock(); defer { stageLock.unlock() }; return tracker.stages }
    /// Starts stage `id` (an unfinished earlier stage is closed). Unknown ids are ignored.
    func beginStage(_ id: String) {
        stageLock.lock(); tracker.begin(id); let s = tracker.stages, multi = tracker.isMultiStage; stageLock.unlock()
        if multi { onStages?(s) }
    }
    func finishStage(_ id: String? = nil) {
        stageLock.lock(); tracker.finish(id); let s = tracker.stages, multi = tracker.isMultiStage
        let overall = tracker.overallFraction, total = tracker.overallETA(); stageLock.unlock()
        if multi { onStages?(s); onProgress?(overall, nil, total) }
    }
    /// A stage that turned out to be unnecessary (a remux needs no transcode): it drops out of the weighting.
    func skipStage(_ id: String) {
        stageLock.lock(); tracker.skip(id); let s = tracker.stages, multi = tracker.isMultiStage
        let overall = tracker.overallFraction; stageLock.unlock()
        if multi { onStages?(s); if overall != nil { onProgress?(overall, nil, nil) } }
    }
    func log(_ line: String) { onLog?(line) }
    func slice(index: Int, count: Int) -> ProgressSlice { ProgressSlice(ctx: self, index: index, count: count) }
    func setCurrentItem(_ item: FileItem, index: Int, count: Int) { onCurrentItem?(item, index, count) }

    func checkCancelled() throws { try Task.checkCancellation() }
    func waitIfPaused() async throws { await pauseGate.wait(); try Task.checkCancellation() }

    // MARK: Temp

    /// The job's private scratch folder (created on first use, removed by JobRunner when the job ends).
    var tempDir: URL {
        tempLock.lock(); defer { tempLock.unlock() }
        if let t = _tempDir { return t }
        let t = AppPaths.makeTempDirectory(purpose: "job")
        _tempDir = t
        return t
    }

    func cleanupTemp() {
        tempLock.lock(); let t = _tempDir; _tempDir = nil; tempLock.unlock()
        if let t { AppPaths.removeTemp(t) }
    }

    // MARK: Child processes

    /// Runs a tool: registers it with the job (pause/cancel reach it), logs the command line, streams stderr/stdout lines.
    /// The child leads its own process group; cancelling sends SIGTERM to the group and SIGKILL after 2 s, or SIGKILL at once with `killImmediately`.
    @discardableResult
    func runProcess(_ executable: URL, _ arguments: [String], workingDirectory: URL? = nil, captureStdout: Bool = false,
                    onStdoutLine: (@Sendable (String) -> Void)? = nil, onStderrLine: (@Sendable (String) -> Void)? = nil,
                    allowNonZeroExit: Bool = false, killImmediately: Bool = false) async throws -> ProcessOutput {
        let background = isBackground
        let control = ProcessControl(killImmediately: killImmediately)
        processes.add(control)
        defer { processes.remove(control) }
        log("$ " + ([executable.path] + arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        let logLine: @Sendable (String) -> Void = { [weak self] l in self?.log(l) }
        return try await ProcessRunner.run(executable, arguments, workingDirectory: workingDirectory, captureStdout: captureStdout,
                                           onStdoutLine: onStdoutLine ?? (captureStdout ? nil : logLine),
                                           onStderrLine: { l in logLine(l); onStderrLine?(l) },
                                           control: control, toolName: executable.lastPathComponent, allowNonZeroExit: allowNonZeroExit,
                                           background: background, killImmediately: killImmediately)
    }

    /// Convenience: runs an installed tool by enum, throwing `toolMissing` when absent.
    @discardableResult
    func runTool(_ tool: Tool, _ arguments: [String], workingDirectory: URL? = nil, captureStdout: Bool = false,
                 onStdoutLine: (@Sendable (String) -> Void)? = nil, onStderrLine: (@Sendable (String) -> Void)? = nil,
                 allowNonZeroExit: Bool = false, killImmediately: Bool = false) async throws -> ProcessOutput {
        let url = try tools.require(tool)
        return try await runProcess(url, arguments, workingDirectory: workingDirectory, captureStdout: captureStdout,
                                    onStdoutLine: onStdoutLine, onStderrLine: onStderrLine, allowNonZeroExit: allowNonZeroExit, killImmediately: killImmediately)
    }

    // MARK: Output

    /// Output folder for results of `item` according to the job's output rules (created on demand).
    func outputDirectory(for item: FileItem) throws -> URL {
        try OutputPaths.outputDirectory(for: item, rules: outputRules)
    }

    /// File name (without extension) for the result of `item`: template expansion with suffix/tokens.
    /// Default template is `{name}`; operations with a `suffix` use `{name} ({suffix})` unless the user set their own template.
    func outputBaseName(for item: FileItem, suffix: L10n? = nil, tokens: [String: String] = [:]) -> String {
        var template = outputRules.nameTemplate
        if template == "{name}" && suffix != nil { template = "{name} ({suffix})" }
        var t = tokens
        t["name"] = item.base
        t["suffix"] = suffix?.text ?? t["suffix"] ?? ""
        if t["preset"] == nil { t["preset"] = "" }
        return OutputPaths.expandTemplate(template, tokens: t)
    }

    /// Writes ONE file atomically: `body` receives a hidden temp URL (real extension at the end); the file is moved to a
    /// collision-free name afterwards. Partial output never survives an error or cancellation. Returns the final URL.
    /// `base` overrides the name (batch outputs named after the first item, page files ...).
    func produceFile(for item: FileItem, suffix: L10n? = nil, ext: String, base: String? = nil, tokens: [String: String] = [:],
                     _ body: (URL) async throws -> Void) async throws -> URL {
        let dir = try outputDirectory(for: item)
        let name = base ?? outputBaseName(for: item, suffix: suffix, tokens: tokens)
        OwnOutputs.shared.beginWriting(to: dir)
        defer { OwnOutputs.shared.endWriting(to: dir) }
        let url = try await OutputPaths.produceFile(dir: dir, base: name, ext: ext, collision: outputRules.collision, body)
        applyPostProcessing(output: url, source: item)
        return url
    }

    /// Writes a FOLDER result (pages, extracted archive) atomically into the output directory.
    func produceFolder(for item: FileItem, suffix: L10n? = nil, name: String? = nil, tokens: [String: String] = [:],
                       _ body: (URL) async throws -> Void) async throws -> URL {
        let dir = try outputDirectory(for: item)
        let folderName = name ?? outputBaseName(for: item, suffix: suffix, tokens: tokens)
        OwnOutputs.shared.beginWriting(to: dir)
        defer { OwnOutputs.shared.endWriting(to: dir) }
        let url = try await OutputPaths.produceFolder(dir: dir, name: folderName, collision: outputRules.collision, body)
        applyPostProcessing(output: url, source: item)
        return url
    }

    /// Keeps the original dates when the rules ask for it (modification + creation date).
    func applyPostProcessing(output: URL, source: FileItem) {
        guard outputRules.keepDates else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.url.path)
        var set: [FileAttributeKey: Any] = [:]
        if let m = attrs?[.modificationDate] { set[.modificationDate] = m }
        if let c = attrs?[.creationDate] { set[.creationDate] = c }
        if !set.isEmpty { try? FileManager.default.setAttributes(set, ofItemAtPath: output.path) }
    }
}
