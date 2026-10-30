import Foundation

/// What a CLI run works with. The real process uses the defaults (the shared registry, settings and preset store, a private non-persistent job queue);
/// the self-tests inject private ones so nothing leaks between tests.
@MainActor
struct CLIEnvironment {
    var registry: OperationRegistry = .shared
    var settings: AppSettings = .shared
    var presets: PresetStore = .shared
    /// nil: a private runner that never touches `queue.json` / `history.json` (the app's own queue is not the CLI's business).
    var runner: JobRunner? = nil
    /// Register the real engines (idempotent). Tests with a private registry switch it off.
    var bootstrap = true
    var tools: ToolLocator = .shared
}

/// The jobs a run has started, so SIGINT (or a test) can cancel them.
@MainActor
enum CLIRuntime {
    static var environment = CLIEnvironment()
    private(set) static var cancelRequested = false
    private static var active: [(job: Job, runner: JobRunner)] = []
    private static var interrupts = 0
    private static var cachedRunner: JobRunner?

    static func reset() { cancelRequested = false; active = []; interrupts = 0; cachedRunner = nil }

    /// The queue of this run: the injected one, else a private runner without persistence and with a private non-saving copy of the settings,
    /// so a CLI run never rewrites the app's `queue.json`, `history.json` or `settings.json` ("repeat last" included).
    static func runner() -> JobRunner {
        if let r = environment.runner { return r }
        if let r = cachedRunner { return r }
        let settings = environment.settings === AppSettings.shared ? AppSettings(fileURL: nil, autosave: false) : environment.settings
        let r = JobRunner(persistence: false, registry: environment.registry, settings: settings)
        cachedRunner = r
        return r
    }

    static func track(_ job: Job, runner: JobRunner) {
        active.append((job, runner))
        if cancelRequested { runner.cancel(job) }
    }

    static func untrack(_ job: Job) { active.removeAll { $0.job.id == job.id } }

    /// Cancels every running job of this run (no partial files are left: the engines clean up). A second request while cancelling ends the process at once.
    static func requestCancel(forceExitOnRepeat: Bool = false) {
        interrupts += 1
        if forceExitOnRepeat && interrupts >= 2 { exit(CLIExitCode.cancelled.rawValue) }
        cancelRequested = true
        for (job, runner) in active { runner.cancel(job) }
    }
}

/// What happened to one job, in the words of the exit codes.
struct CLIJobOutcome: Sendable {
    var state: JobState
    var outputs: [URL]
    var failures: [String]
    var note: String?
    var error: String?
    var elapsed: TimeInterval
    /// The job failed because a required program is not installed.
    var toolMissing = false

    /// 0 ok, 1 failed, 3 a required program is not installed, 4 partial (some failed, some made), 130 cancelled. A job that finished with nothing to do (everything already in the target format) is ok.
    var exitCode: CLIExitCode {
        switch state {
        case .cancelled: return .cancelled
        case .failed: return toolMissing ? .unavailable : .failed
        case .done:
            if failures.isEmpty { return .ok }
            return outputs.isEmpty ? .failed : .partial
        case .skipped: return .ok
        case .waiting, .running, .paused: return .failed
        }
    }
}

/// Streams a job's progress (JSON events or a human line), waits for the end and reports the outcome.
@MainActor
enum CLIJobWatcher {
    /// Poll interval of the watcher. The CLI is short-lived and waits for one job, so a 10 Hz poll is simpler and cheaper than another observer.
    static let interval: UInt64 = 100_000_000

    static func wait(for job: Job, runner: JobRunner, out: CLIOutput) async -> CLIJobOutcome {
        CLIRuntime.track(job, runner: runner)
        defer { CLIRuntime.untrack(job) }
        let id = job.id.uuidString.lowercased()
        var last: (fraction: Double?, stage: String?, message: String?, eta: Int?)?
        var lastStep = -1
        var lastStage: String?
        var logged = 0
        let started = Date()
        func emit(force: Bool) {
            let stage = job.stages.first { $0.state == .running }?.spec.id
            let stageTitle = job.currentStageTitle
            let fraction = job.progress
            let message = job.statusText.isEmpty ? nil : job.statusText
            let eta = job.eta.map { Int($0.rounded()) }
            let now = (fraction, stage, message, eta)
            if !force, let l = last, l.fraction == now.0, l.stage == now.1, l.message == now.2, l.eta == now.3 { return }
            last = now
            let stageChanged = stage != lastStage
            lastStage = stage
            if out.json {
                out.progress(job: id, fraction: fraction, stage: stage, eta: job.eta, message: message)
            } else if out.interactive {
                out.progress(job: id, fraction: fraction, stage: stageTitle, eta: job.eta, message: message)
            } else {
                // Not a terminal: a plain line at stage changes and every 10 percent, never a flood.
                let step = Int(((fraction ?? 0) * 10).rounded(.down))
                if force || step != lastStep || stageChanged {
                    lastStep = step
                    out.progress(job: id, fraction: fraction, stage: stageTitle, eta: job.eta, message: message)
                }
            }
        }
        emit(force: true)
        while !job.state.isFinished {
            if Task.isCancelled && !CLIRuntime.cancelRequested { CLIRuntime.requestCancel() }
            if out.verbose, job.logLines.count > logged {
                for l in job.logLines[logged...] { out.log(l) }
                logged = job.logLines.count
            }
            emit(force: false)
            try? await Task.sleep(nanoseconds: interval)
        }
        if out.verbose, job.logLines.count > logged { for l in job.logLines[logged...] { out.log(l) } }
        return CLIJobOutcome(state: job.state, outputs: job.outputs, failures: job.failures, note: job.note?.text, error: job.errorMessage,
                             elapsed: Date().timeIntervalSince(started), toolMissing: job.missingTool != nil)
    }
}
