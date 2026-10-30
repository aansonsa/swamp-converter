import Foundation
import AppKit
import Combine

/// Watches the folders of `settings.watchRules` and runs each rule's `Recipe` on new files as an AUTOMATIC job (never remembered, never revealed, loop-safe).
/// Semantics (spec/appfeatures.md 5): candidate filter (no hidden, no `._*`, no in-flight `.part`, no temp suffixes `.crdownload`, `.download`, `.tmp`, no directories),
/// settle detection (size + mtime unchanged for N ms, one one-shot timer per folder, only while a file is changing), loop prevention (`OwnOutputs`, the rule's output
/// folder excluded from its own watch), re-scan after unmount / remount of external volumes and after wake, ALL matching rules run (not first-only), a per-rule output
/// folder, pause with the "pause folders" switch. Nothing is watched, no observer is installed and no timer exists while there are no enabled rules.
@MainActor
final class WatchFolderService: ObservableObject {
    static let shared = WatchFolderService()

    /// Live state per rule for the Settings page ("watching", "waiting for volume", "folder missing", "paused").
    enum RuleStatus: Equatable, Sendable { case watching, folderMissing, volumeUnavailable, paused, disabled }
    @Published private(set) var statuses: [UUID: RuleStatus] = [:]

    /// Timing knobs (tests shorten them).
    struct Tuning: Sendable {
        var latency: TimeInterval = 0.5
        var settleMilliseconds = 1500
        var giveUpSeconds: TimeInterval = 1800
    }

    private struct Runtime {
        var rule: WatchRule
        var watcher: FolderWatcher
        var session: WatchSession
        var ignored: [String]
    }

    private let settings: AppSettings
    private let quickRunProvider: @MainActor () -> QuickRun
    private let registry: OperationRegistry
    private let tuning: Tuning
    private let notificationCenterOverride: NotificationCenter?

    private var runtimes: [UUID: Runtime] = [:]
    private var scanSessions: [WatchSession] = []
    private var started = false
    private var manuallyPaused = false
    private var settingsSink: AnyCancellable?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var warned: Set<String> = []
    private var lastAppliedRules: [WatchRule] = []
    private var lastAppliedPaused = false

    init(settings: AppSettings = .shared, quickRun: (@MainActor () -> QuickRun)? = nil, registry: OperationRegistry = .shared,
         tuning: Tuning = Tuning(), notificationCenter: NotificationCenter? = nil) {
        self.settings = settings
        self.quickRunProvider = quickRun ?? { QuickRun.shared }
        self.registry = registry
        self.tuning = tuning
        self.notificationCenterOverride = notificationCenter
    }

    // MARK: Lifecycle

    /// Reads `AppSettings.shared.data.watchRules` and (re)builds the watchers. Idempotent; call after the rules change (the service also follows the settings itself).
    func start() {
        if !started {
            started = true
            settingsSink = settings.$revision.dropFirst().sink { [weak self] _ in
                Task { @MainActor in self?.settingsChanged() }
            }
        }
        rebuild()
    }

    func reload() { rebuild(force: true) }

    func stop() {
        started = false
        settingsSink = nil
        for id in Array(runtimes.keys) { tearDown(id) }
        for s in scanSessions { s.cancel() }
        scanSessions.removeAll()
        removeObservers()
        statuses = [:]
        lastAppliedRules = []
    }

    /// Pauses every rule (the "Pause gestures / folders" switch); jobs already running finish. Files that arrive while paused are not processed later.
    func setPaused(_ paused: Bool) {
        manuallyPaused = paused
        rebuild()
    }

    var isPaused: Bool { manuallyPaused || settings.data.gesturesPaused }

    /// Number of folders with a live FSEvents stream (diagnostics, tests).
    var activeWatcherCount: Int { runtimes.count }
    /// True while any folder waits for a file to settle (a one-shot timer is armed). False when idle.
    var hasArmedTimer: Bool { runtimes.values.contains { $0.session.hasArmedTimer } }
    /// True when nothing is installed at all: no stream, no timer, no notification observer.
    var isFullyIdle: Bool { runtimes.isEmpty && observers.isEmpty && !hasArmedTimer }

    // MARK: Rebuilding

    private func settingsChanged() {
        guard started else { return }
        let rules = settings.data.watchRules
        if rules == lastAppliedRules && isPaused == lastAppliedPaused { return }
        rebuild()
    }

    private func rebuild(force: Bool = false) {
        let rules = settings.data.watchRules
        let paused = isPaused
        lastAppliedRules = rules
        lastAppliedPaused = paused
        let ids = Set(rules.map(\.id))
        for id in Array(runtimes.keys) where !ids.contains(id) { tearDown(id) }

        var next: [UUID: RuleStatus] = [:]
        for rule in rules {
            var status = Self.initialStatus(of: rule, paused: paused)
            if status == .watching {
                if let rt = runtimes[rule.id], rt.rule == rule, rt.watcher.isRunning, !force, rt.ignored == Self.ignoredPaths(rule, settings.data) {
                    // unchanged and alive
                } else {
                    tearDown(rule.id)
                    if !attach(rule) { status = Self.missingStatus(of: rule) ; warnOnce("watch:\(rule.id)", L("Cannot watch the folder \(rule.path).", "Не удалось отслеживать папку \(rule.path).")) }
                }
            } else {
                tearDown(rule.id)
            }
            next[rule.id] = status
        }
        if statuses != next { statuses = next }
        updateObservers(active: rules.contains { $0.enabled })
    }

    private func attach(_ rule: WatchRule) -> Bool {
        let session = WatchSession(config: WatchSession.Config(rule: rule, settleMilliseconds: tuning.settleMilliseconds, giveUpSeconds: tuning.giveUpSeconds,
                                                              registry: registry, settings: { [settings] in settings.data })) { [weak self] urls in
            Task { @MainActor in await self?.dispatch(urls, ruleID: rule.id) }
        }
        let ignoring = WatchCandidate.ignoredFolders(for: rule, settings: settings.data)
        let id = rule.id
        let watcher = FolderWatcher(url: URL(fileURLWithPath: rule.path, isDirectory: true), includeSubfolders: rule.includeSubfolders, latency: tuning.latency,
                                    ignoring: ignoring, queue: session.queue, onRootChange: { [weak self] in
            Task { @MainActor in self?.rootChanged(id) }
        }, onEvents: { [weak session] events in session?.handle(events) })
        guard watcher.start() else { session.cancel(); return false }
        runtimes[rule.id] = Runtime(rule: rule, watcher: watcher, session: session, ignored: ignoring.map { FolderWatcher.realPath($0) })
        return true
    }

    private static func ignoredPaths(_ rule: WatchRule, _ data: SettingsData) -> [String] {
        WatchCandidate.ignoredFolders(for: rule, settings: data).map { FolderWatcher.realPath($0) }
    }

    private func tearDown(_ id: UUID) {
        guard let rt = runtimes.removeValue(forKey: id) else { return }
        rt.watcher.stop()
        rt.session.cancel()
    }

    /// The folder (or its volume) went away or was replaced: re-evaluate every rule (a re-created folder starts a new stream).
    private func rootChanged(_ id: UUID) {
        guard runtimes[id] != nil else { return }
        tearDown(id)
        rebuild()
    }

    // MARK: Statuses

    nonisolated static func initialStatus(of rule: WatchRule, paused: Bool) -> RuleStatus {
        if !rule.enabled || rule.recipe.operationID.isEmpty { return .disabled }
        if paused { return .paused }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: rule.path, isDirectory: &isDir), isDir.boolValue { return .watching }
        return missingStatus(of: rule)
    }

    /// "/Volumes/Photos/Incoming" with no "/Volumes/Photos": the drive is unplugged (waiting for it), not the folder deleted.
    nonisolated static func missingStatus(of rule: WatchRule) -> RuleStatus {
        let comps = URL(fileURLWithPath: rule.path).standardizedFileURL.pathComponents
        if comps.count > 2, comps[1] == "Volumes" {
            let volume = "/Volumes/" + comps[2]
            if !FileManager.default.fileExists(atPath: volume) { return .volumeUnavailable }
        }
        return .folderMissing
    }

    // MARK: Volumes and wake

    private func updateObservers(active: Bool) {
        guard active else { removeObservers(); return }
        guard observers.isEmpty else { return }
        let center = notificationCenterOverride ?? NSWorkspace.shared.notificationCenter
        func add(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
            observers.append((center, token))
        }
        // The stream of a volume that is about to go away is released first, so the unmount is never held up by us.
        add(NSWorkspace.willUnmountNotification) { [weak self] note in self?.volumeWillUnmount(note) }
        add(NSWorkspace.didUnmountNotification) { [weak self] _ in self?.reload() }
        add(NSWorkspace.didMountNotification) { [weak self] _ in self?.reload() }
        add(NSWorkspace.didWakeNotification) { [weak self] _ in self?.reload() }
    }

    private func removeObservers() {
        for o in observers { o.center.removeObserver(o.token) }
        observers.removeAll()
    }

    private func volumeWillUnmount(_ note: Notification) {
        guard let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else { return }
        for (id, rt) in runtimes where rt.watcher.rootPath.hasPrefix(volume + "/") || rt.watcher.rootPath == volume { tearDown(id) }
        rebuild()
    }

    // MARK: Running rules

    /// Runs a rule once over the files currently in its folder (the "Run now" button), respecting the same filters. Files that are still being written wait for
    /// the settle time like any new file. Works for a disabled or paused rule too (the person asked), but not for a folder that does not exist.
    func runNow(rule: WatchRule) async {
        guard FileManager.default.fileExists(atPath: rule.path) else {
            MessageCenter.shared.post(L("The folder \(rule.path) is not available.", "Папка \(rule.path) недоступна."), severity: .warning, symbol: "folder.badge.questionmark")
            return
        }
        let current = settings.data.watchRules.first { $0.id == rule.id } ?? rule
        let id = current.id
        pruneScanSessions()
        let session: WatchSession
        if let live = runtimes[id]?.session {
            session = live
        } else {
            // A rule that is not being watched (disabled, paused): a short-lived session does the settle waiting for files that are still arriving.
            session = WatchSession(config: WatchSession.Config(rule: current, settleMilliseconds: tuning.settleMilliseconds, giveUpSeconds: tuning.giveUpSeconds,
                                                               registry: registry, settings: { [settings] in settings.data })) { [weak self] urls in
                Task { @MainActor in
                    await self?.dispatch(urls, ruleID: id, fallback: current, explicit: true)
                    self?.pruneScanSessions()
                }
            }
            scanSessions.append(session)
        }
        let urls: [URL] = await withCheckedContinuation { cont in session.scanExisting { cont.resume(returning: $0) } }
        pruneScanSessions()
        guard !urls.isEmpty else { return }
        await dispatch(urls, ruleID: id, fallback: current, explicit: true)
    }

    /// Short-lived "Run now" sessions go away once nothing is waiting in them (their queues hold no timer by then).
    private func pruneScanSessions() {
        scanSessions.removeAll { s in
            guard s.pendingCount == 0, !s.hasArmedTimer else { return false }
            s.cancel()
            return true
        }
    }

    /// Files are ready: every file becomes its own automatic job (one batch, so one notification) with the rule's recipe.
    private func dispatch(_ urls: [URL], ruleID: UUID, fallback: WatchRule? = nil, explicit: Bool = false) async {
        guard let rule = settings.data.watchRules.first(where: { $0.id == ruleID }) ?? fallback else { return }
        if !explicit && (isPaused || !rule.enabled) { return }
        let folder = URL(fileURLWithPath: rule.path).lastPathComponent
        guard let op = WatchCandidate.operation(for: rule, registry: registry) else {
            warnOnce("missing:\(rule.id)", L("The action for \(folder) no longer exists (deleted preset?). Change it in Settings > Folders.",
                                             "Действие для папки «\(folder)» больше не существует (шаблон удалён?). Измените его в настройках: «Папки»."))
            return
        }
        guard !op.meta.isAppAction else { return }
        let items = urls.map { FileItem(url: $0) }
        if case .unavailable(let reason, let missing) = op.availability(for: items, tools: ToolLocator.shared) {
            let names = missing.map(\.displayName).joined(separator: ", ")
            warnOnce("unavailable:\(rule.id)", L("The action for \(folder) is not available: \(reason.en)", "Действие для папки «\(folder)» недоступно: \(reason.ru)") + (names.isEmpty ? "" : " (\(names))"))
            return
        }
        let quick = quickRunProvider()
        let batch = UUID()
        let rules = rule.outputDir != nil || rule.recipe.output != nil ? WatchCandidate.effectiveOutput(of: rule, settings: settings.data) : nil
        for item in items {
            await quick.run(op, items: [item], origin: .watch, mode: .automatic, overrides: rule.recipe.values, outputRules: rules, batchID: batch)
        }
    }

    /// One warning per rule per app run ("a missing tool, a deleted preset, a folder we cannot watch").
    private func warnOnce(_ key: String, _ text: String) {
        guard warned.insert(key).inserted else { return }
        MessageCenter.shared.post(text, severity: .warning, symbol: "exclamationmark.triangle")
    }
}
