import Foundation

/// Everything one watched folder needs between "the file system said something" and "this file is ready to be processed": the candidate filter, the settle
/// detector, ONE one-shot timer armed only while a file is still changing, and a short memory of what was already handed over. Confined to its own serial queue, so
/// no file is ever examined on the main thread. The service owns one session per active rule and turns `onReady` into automatic jobs.
final class WatchSession: @unchecked Sendable {
    struct Config: Sendable {
        var rule: WatchRule
        var settleMilliseconds = 1500
        var giveUpSeconds: TimeInterval = 1800
        var registry: OperationRegistry = .shared
        var settings: @Sendable () -> SettingsData = { AppSettings.shared.data }
        var outputs: OwnOutputs = .shared
    }

    let queue: DispatchQueue
    let rule: WatchRule
    let rootPath: String
    private let config: Config
    private let onReady: @Sendable ([URL]) -> Void

    // Queue-confined state.
    private var detector: SettleDetector
    private var timer: DispatchSourceTimer?
    private var processed: [String: Processed] = [:]
    private var cancelled = false

    private struct Processed { var size: Int64; var modified: Date; var at: Date }
    static let processedCapacity = 2_000
    static let processedLifetime: TimeInterval = 10 * 60
    /// Files found by a scan or a new subfolder are capped so a huge tree never floods the queue.
    static let scanLimit = 20_000

    init(config: Config, queue: DispatchQueue? = nil, onReady: @escaping @Sendable ([URL]) -> Void) {
        self.config = config
        self.rule = config.rule
        self.rootPath = FolderWatcher.realPath(URL(fileURLWithPath: config.rule.path, isDirectory: true))
        self.queue = queue ?? DispatchQueue(label: "app.swampconverter.watch.session", qos: .utility)
        self.detector = SettleDetector(settleMilliseconds: config.settleMilliseconds, giveUpSeconds: config.giveUpSeconds)
        self.onReady = onReady
    }

    // MARK: Entry points (any thread)

    func handle(_ events: [WatchEvent]) { queue.async { [self] in ingest(events) } }

    /// Stops everything: the timer is cancelled and nothing is delivered any more.
    func cancel() { queue.sync { cancelled = true; disarm(); detector.removeAll() } }

    /// Test and diagnostics: is a one-shot timer armed right now?
    var hasArmedTimer: Bool { queue.sync { timer != nil } }
    var pendingCount: Int { queue.sync { detector.count } }

    /// Looks at the files already in the folder (the "Run now" button). Files untouched for `minimumAge` seconds are returned at once through `completion`; younger
    /// ones go through the settle detector like any new file and arrive through `onReady`. Never runs on the main thread.
    func scanExisting(minimumAge: TimeInterval = 2, completion: @escaping @Sendable ([URL]) -> Void) {
        queue.async { [self] in
            var ready: [URL] = []
            let now = Date()
            enumerate(path: rootPath, recursive: rule.includeSubfolders) { url, size, modified in
                guard WatchCandidate.isCandidate(url, isDirectory: false, rule: rule, size: size, registry: config.registry, settings: config.settings(), outputs: config.outputs) else { return }
                if now.timeIntervalSince(modified) >= minimumAge {
                    ready.append(url)
                    remember(url.path, size: size, modified: modified, now: now)
                } else {
                    detector.observe(path: url.path, size: size, modified: modified, now: now)
                }
            }
            arm()
            completion(ready.sorted { $0.path < $1.path })
        }
    }

    // MARK: Ingestion (queue)

    private func ingest(_ events: [WatchEvent]) {
        guard !cancelled else { return }
        let now = Date()
        for ev in events {
            let path = ev.path
            if ev.isDirectory {
                // A whole folder moved or copied in: its files may not be reported one by one.
                if rule.includeSubfolders, ev.created || ev.renamed, WatchCandidate.isInside(path, root: rootPath, includeSubfolders: true),
                   !WatchCandidate.hasHiddenOrPackageAncestor(path + "/x", root: rootPath) {
                    enumerate(path: path, recursive: true) { url, size, modified in consider(url, size: size, modified: modified, now: now, tracked: false, viaScan: true) }
                }
                continue
            }
            guard WatchCandidate.isInside(path, root: rootPath, includeSubfolders: rule.includeSubfolders) else { continue }
            guard let st = Self.stat(path) else { detector.forget(path: path); continue }   // vanished, or renamed away
            if st.isDirectory || st.isSymlink { continue }
            let tracked = detector.isTracking(path)
            // An in-place edit of a file we never saw arrive is not a new file; growth of a file we are waiting for is.
            if !(ev.created || ev.renamed) && !tracked { continue }
            consider(URL(fileURLWithPath: path), size: st.size, modified: st.modified, now: now, tracked: tracked, viaScan: false)
        }
        arm()
    }

    private func consider(_ url: URL, size: Int64, modified: Date, now: Date, tracked: Bool, viaScan: Bool) {
        let path = url.path
        if alreadyProcessed(path, size: size, modified: modified, now: now) { return }
        guard WatchCandidate.isCandidate(url, isDirectory: false, rule: rule, size: nil, registry: config.registry, settings: config.settings(), outputs: config.outputs) else {
            detector.forget(path: path)
            return
        }
        detector.observe(path: path, size: size, modified: modified, now: now)
    }

    // MARK: Timer (queue)

    /// Arms ONE one-shot timer for the earliest deadline, or none when nothing is pending.
    private func arm() {
        guard !cancelled, let deadline = detector.nextDeadline(now: Date()) else { disarm(); return }
        let t: DispatchSourceTimer
        if let existing = timer { t = existing } else {
            t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.fire() }
            timer = t
            t.resume()
        }
        t.schedule(deadline: .now() + max(0.001, deadline.timeIntervalSinceNow), repeating: .never, leeway: .milliseconds(50))
    }

    private func disarm() {
        guard let t = timer else { return }
        timer = nil
        t.setEventHandler {}
        t.cancel()
    }

    /// The deadline passed: look at what is due, hand over what is really quiet, and re-arm for the rest.
    private func fire() {
        guard !cancelled else { return }
        let now = Date()
        var out: [URL] = []
        for stamp in detector.readyStamps(now: now) {
            guard let st = Self.stat(stamp.path), !st.isDirectory, !st.isSymlink else { continue }   // vanished while waiting
            if st.size != stamp.size || st.modified != stamp.modified {
                // It changed after the last event we saw (a writer that is quiet for a moment): the quiet period starts again.
                detector.observe(path: stamp.path, size: st.size, modified: st.modified, now: now)
                continue
            }
            let url = URL(fileURLWithPath: stamp.path)
            guard WatchCandidate.isCandidate(url, isDirectory: false, rule: rule, size: st.size, registry: config.registry, settings: config.settings(), outputs: config.outputs) else { continue }
            if alreadyProcessed(stamp.path, size: st.size, modified: st.modified, now: now) { continue }
            remember(stamp.path, size: st.size, modified: st.modified, now: now)
            out.append(url)
        }
        arm()
        if !out.isEmpty { onReady(out) }
    }

    // MARK: Memory of handed-over files (queue)

    private func alreadyProcessed(_ path: String, size: Int64, modified: Date, now: Date) -> Bool {
        guard let p = processed[path] else { return false }
        if now.timeIntervalSince(p.at) > Self.processedLifetime { processed[path] = nil; return false }
        return p.size == size && p.modified == modified
    }

    private func remember(_ path: String, size: Int64, modified: Date, now: Date) {
        processed[path] = Processed(size: size, modified: modified, at: now)
        guard processed.count > Self.processedCapacity else { return }
        let cutoff = now.addingTimeInterval(-Self.processedLifetime)
        processed = processed.filter { $0.value.at > cutoff }
        if processed.count > Self.processedCapacity {
            let keep = processed.sorted { $0.value.at > $1.value.at }.prefix(Self.processedCapacity / 2)
            processed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    // MARK: File system (streams, never lists a whole tree into memory first)

    struct FileStat { var size: Int64; var modified: Date; var isDirectory: Bool; var isSymlink: Bool }

    static func stat(_ path: String) -> FileStat? {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return nil }
        let fmt = st.st_mode & S_IFMT
        let m = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileStat(size: Int64(st.st_size), modified: m, isDirectory: fmt == S_IFDIR, isSymlink: fmt == S_IFLNK)
    }

    /// Streams the regular files below `path` (hidden files, packages and symlinks skipped) to `body`, at most `scanLimit` of them.
    private func enumerate(path: String, recursive: Bool, _ body: (URL, Int64, Date) -> Void) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: options) else { return }
        var n = 0
        for case let file as URL in e {
            if cancelled || n >= Self.scanLimit { break }
            guard let st = Self.stat(file.path), !st.isDirectory, !st.isSymlink else { continue }
            n += 1
            body(file, st.size, st.modified)
        }
    }
}
