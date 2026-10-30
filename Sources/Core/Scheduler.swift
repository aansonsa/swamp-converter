import Foundation
import IOKit.ps

// Resource-aware scheduling (feature I). Everything here is event-driven: no timers, no polling. The environment is read on demand
// and observed through system notifications (thermal state, Low Power Mode, power-source change) that re-run the queue pump.
//
//   SystemEnvironment      a snapshot: cores, thermal state, Low Power Mode, on battery
//   ResourcePolicy         pure functions: how many jobs in parallel, hardware encoders preferred, hold background jobs, QoS, nice
//   SleepGuard             keeps the Mac awake ONLY while jobs run (ProcessInfo activity), released the moment the queue is idle
//   DiskSpaceGuard         "estimated output + temp" against the free space of the volumes involved, BEFORE a job starts
//   SystemEnvironmentMonitor  notification observers (installed once by JobRunner)

struct SystemEnvironment: Equatable, Sendable {
    var cores: Int = 8
    /// Performance cores on Apple silicon (nil when unknown).
    var performanceCores: Int? = nil
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false
    var onBattery = false

    /// Tests set this to force a situation; nil in production.
    nonisolated(unsafe) static var override: SystemEnvironment?

    static func current() -> SystemEnvironment {
        if let o = override { return o }
        let info = ProcessInfo.processInfo
        var env = SystemEnvironment()
        env.cores = max(info.activeProcessorCount, 1)
        env.performanceCores = sysctlInt("hw.perflevel0.logicalcpu")
        env.thermal = info.thermalState
        env.lowPowerMode = info.isLowPowerModeEnabled
        env.onBattery = isOnBattery()
        return env
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : nil
    }

    /// True when the Mac runs on battery power (desktops: always false).
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}

enum ResourcePolicy {
    /// Parallel jobs allowed right now. `requested` is the user's setting; the environment can only lower it.
    ///   - never more than the performance cores (or half of all cores when unknown)
    ///   - Low Power Mode or thermal `.fair`: halve; `.serious` / `.critical`: one job at a time
    static func maxConcurrent(requested: Int, env: SystemEnvironment) -> Int {
        let ceiling = max(1, env.performanceCores ?? max(env.cores / 2, 1))
        var n = max(1, min(requested, ceiling))
        if env.thermal == .serious || env.thermal == .critical { return 1 }
        if env.lowPowerMode || env.thermal == .fair { n = max(1, (n + 1) / 2) }
        return n
    }

    /// Prefer VideoToolbox / hardware encoders over software ones (cooler and cheaper on battery) when conditions are tight.
    static func preferHardwareEncoders(env: SystemEnvironment) -> Bool {
        env.lowPowerMode || env.onBattery || env.thermal != .nominal
    }

    /// Automatic (watched-folder / chain) jobs wait while this is true: on battery with the setting on, or when the Mac is critically hot.
    static func holdsBackgroundWork(env: SystemEnvironment, pauseOnBattery: Bool) -> Bool {
        (pauseOnBattery && env.onBattery) || env.thermal == .critical
    }

    /// The job the user is waiting for runs at userInitiated, unattended work at utility.
    static func taskPriority(origin: JobOrigin, mode: RunMode) -> TaskPriority {
        if mode == .automatic || origin == .watch || origin == .chain { return .utility }
        return .userInitiated
    }

    static func isBackground(origin: JobOrigin, mode: RunMode) -> Bool { taskPriority(origin: origin, mode: mode) == .utility }

    /// `nice` increment for child processes (ffmpeg, yt-dlp ...) of background jobs; 0 for interactive ones.
    static func childNice(background: Bool) -> Int32 { background ? 10 : 0 }
}

/// Keeps the Mac from idle-sleeping while jobs run. `hold` is idempotent, `release` ends the activity immediately.
/// Display sleep is NOT prevented. The activity token is a ProcessInfo activity, so nothing leaks if the app dies.
final class SleepGuard: @unchecked Sendable {
    static let shared = SleepGuard()
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return token != nil }

    func hold(reason: String = "Swamp Converter is converting files") {
        lock.lock(); defer { lock.unlock() }
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: reason)
    }

    func release() {
        lock.lock(); let t = token; token = nil; lock.unlock()
        if let t { ProcessInfo.processInfo.endActivity(t) }
    }
}

struct DiskSpaceVerdict: Sendable, Equatable {
    enum Level: String, Sendable { case ok, tight, insufficient }
    var level: Level
    var neededBytes: Int64
    var availableBytes: Int64
    var volumeName: String
    var isOK: Bool { level != .insufficient }

    /// Calm sentence for the preflight warning; nil when everything is fine.
    var message: L10n? {
        switch level {
        case .ok: return nil
        case .tight:
            return L10n("Little free space left on \(volumeName): \(Util.formatBytes(availableBytes)) free, about \(Util.formatBytes(neededBytes)) needed.",
                        "На «\(volumeName)» мало места: свободно \(Util.formatBytes(availableBytes)), потребуется примерно \(Util.formatBytes(neededBytes)).")
        case .insufficient:
            return L10n("Not enough free space on \(volumeName): about \(Util.formatBytes(neededBytes)) needed, \(Util.formatBytes(availableBytes)) free. Free up space or choose another output folder.",
                        "Не хватает места на «\(volumeName)»: нужно примерно \(Util.formatBytes(neededBytes)), свободно \(Util.formatBytes(availableBytes)). Освободите место или выберите другую папку результатов.")
        }
    }
}

enum DiskSpaceGuard {
    /// Tests inject free-space numbers by path prefix.
    nonisolated(unsafe) static var availableOverride: (@Sendable (URL) -> Int64?)?

    static func availableBytes(at url: URL) -> Int64? {
        if let o = availableOverride, let v = o(url) { return v }
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe = probe.deletingLastPathComponent() }
        guard let rv = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = rv.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return rv.volumeAvailableCapacity.map(Int64.init)
    }

    static func volumeName(at url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.path
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let x = ka, let y = kb else { return false }
        return x.isEqual(y)
    }

    /// `estimatedOutput` lands in `outputDir`; `tempBytes` (2-pass logs, downloads before the convert stage, intermediate files) lands in `tempDir`.
    /// `reserve` is the margin below which the verdict is `.tight` (default 1 GB, 5% of a 20 GB estimate, whichever is larger).
    static func check(estimatedOutput: Int64, tempBytes: Int64 = 0, outputDir: URL, tempDir: URL = AppPaths.tempRoot, reserve: Int64? = nil) -> DiskSpaceVerdict {
        let margin = reserve ?? max(1_000_000_000, estimatedOutput / 20)
        let outFree = availableBytes(at: outputDir)
        let tmpFree = availableBytes(at: tempDir)
        let shared = sameVolume(outputDir, tempDir)
        let outNeeded = estimatedOutput + (shared ? tempBytes : 0)
        var worst = DiskSpaceVerdict(level: .ok, neededBytes: outNeeded, availableBytes: outFree ?? Int64.max, volumeName: volumeName(at: outputDir))
        func judge(needed: Int64, free: Int64?, name: String) {
            guard let free else { return }
            let level: DiskSpaceVerdict.Level = free < needed ? .insufficient : (free - needed < margin ? .tight : .ok)
            let rank: [DiskSpaceVerdict.Level: Int] = [.ok: 0, .tight: 1, .insufficient: 2]
            if rank[level]! > rank[worst.level]! { worst = DiskSpaceVerdict(level: level, neededBytes: needed, availableBytes: free, volumeName: name) }
        }
        judge(needed: outNeeded, free: outFree, name: volumeName(at: outputDir))
        if !shared, tempBytes > 0 { judge(needed: tempBytes, free: tmpFree, name: volumeName(at: tempDir)) }
        return worst
    }
}

/// Observes thermal state, Low Power Mode and power-source changes and calls the registered handlers (main actor). Idle cost: zero.
/// Several owners may listen (the shared JobRunner, a test runner): a handler returns `false` once its owner is gone and is dropped.
@MainActor
final class SystemEnvironmentMonitor {
    static let shared = SystemEnvironmentMonitor()
    private var observers: [NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?
    private var handlers: [(token: UUID, run: @MainActor () -> Bool)] = []
    /// The handler installed through the original `start(onChange:)` entry point (replaced on every call, as before).
    private var primaryToken: UUID?

    /// Number of live handlers (tests).
    var handlerCount: Int { handlers.count }

    /// Registers `onChange` as THE primary handler (a second call replaces the first) and starts observing.
    func start(onChange: @escaping @MainActor () -> Void) {
        if let t = primaryToken { handlers.removeAll { $0.token == t } }
        primaryToken = addHandler { onChange(); return true }
    }

    /// Adds a handler next to the others and starts observing. The handler returns false to unregister itself (its owner was deallocated).
    @discardableResult
    func addHandler(_ run: @escaping @MainActor () -> Bool) -> UUID {
        let token = UUID()
        handlers.append((token, run))
        beginObserving()
        return token
    }

    func removeHandler(_ token: UUID) { handlers.removeAll { $0.token == token } }

    /// Runs every handler once (what a system notification does; tests call it directly).
    func notifyChange() {
        var dead = Set<UUID>()
        for h in handlers where !h.run() { dead.insert(h.token) }
        if !dead.isEmpty { handlers.removeAll { dead.contains($0.token) } }
    }

    private func beginObserving() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemEnvironmentMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.notifyChange() }
        }, context)?.takeRetainedValue() {
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode); runLoopSource = nil }
        handlers = []
        primaryToken = nil
    }
}
