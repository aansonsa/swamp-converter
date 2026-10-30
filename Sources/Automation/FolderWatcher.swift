import Foundation
import CoreServices

/// One file-system change as FSEvents reports it (one coalesced record per path; the flags of several incarnations of a path may be OR-ed together).
struct WatchEvent: Sendable, Equatable {
    var path: String
    var flags: UInt32

    private func has(_ flag: Int) -> Bool { flags & UInt32(truncatingIfNeeded: flag) != 0 }
    var isFile: Bool { has(kFSEventStreamEventFlagItemIsFile) }
    var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
    var isSymlink: Bool { has(kFSEventStreamEventFlagItemIsSymlink) }
    var created: Bool { has(kFSEventStreamEventFlagItemCreated) }
    var renamed: Bool { has(kFSEventStreamEventFlagItemRenamed) }
    var modified: Bool { has(kFSEventStreamEventFlagItemModified) }
    var removed: Bool { has(kFSEventStreamEventFlagItemRemoved) }
    /// The watched folder itself was moved, deleted or its volume went away.
    var rootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) || has(kFSEventStreamEventFlagUnmount) }
    /// True when something happened to the CONTENT or the name of the item (not just a tag, an xattr or Finder info).
    var isContentEvent: Bool { created || renamed || modified || removed }
}

/// One FSEvents stream with a callback of CHANGED PATHS, coalesced by the system (`latency`). No polling and no timers of our own: the stream is delivered on a
/// dispatch queue and costs nothing while nothing changes. FSEvents is recursive by nature; `includeSubfolders == false` drops events deeper than the folder itself.
final class FolderWatcher: @unchecked Sendable {
    let url: URL
    let includeSubfolders: Bool
    let latency: TimeInterval
    /// Real (symlink-free) path of the watched folder: FSEvents reports real paths, so `/var/...` and `/private/var/...` must be compared in one form.
    let rootPath: String

    private let ignoredPrefixes: [String]
    private let queue: DispatchQueue
    private let onEvents: @Sendable ([WatchEvent]) -> Void
    private let onRootChange: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?

    private final class Box {
        weak var owner: FolderWatcher?
        init(_ owner: FolderWatcher) { self.owner = owner }
    }

    /// `ignoring`: events inside these folders are dropped (a rule's own output folder). `queue`: where `onEvents` runs (serial).
    init(url: URL, includeSubfolders: Bool, latency: TimeInterval = 0.5, ignoring: [URL] = [], queue: DispatchQueue? = nil,
         onRootChange: (@Sendable () -> Void)? = nil, onEvents: @escaping @Sendable ([WatchEvent]) -> Void) {
        self.url = url
        self.includeSubfolders = includeSubfolders
        self.latency = latency
        self.rootPath = Self.realPath(url)
        self.ignoredPrefixes = ignoring.map { Self.realPath($0) + "/" }
        self.queue = queue ?? DispatchQueue(label: "app.swampconverter.folder-watcher", qos: .utility)
        self.onEvents = onEvents
        self.onRootChange = onRootChange
    }

    /// The simple form: a callback of changed file URLs (created, renamed in, modified; removed-only and directory-only events are left out).
    convenience init(url: URL, includeSubfolders: Bool, latency: TimeInterval = 0.5, ignoring: [URL] = [], onChange: @escaping @Sendable ([URL]) -> Void) {
        self.init(url: url, includeSubfolders: includeSubfolders, latency: latency, ignoring: ignoring, queue: nil, onRootChange: nil) { events in
            let urls = events.filter { $0.isContentEvent && !$0.isDirectory }.map { URL(fileURLWithPath: $0.path) }
            if !urls.isEmpty { onChange(urls) }
        }
    }

    deinit { stop() }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil }

    /// Starts the stream. False when the folder does not exist or the stream could not be started (the caller shows "cannot watch").
    @discardableResult
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return true }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else { return false }

        let box = Unmanaged.passRetained(Box(self))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info, count > 0 else { return }
            let owner = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().owner
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            var events: [WatchEvent] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, paths.count) { events.append(WatchEvent(path: paths[i], flags: rawFlags[i])) }
            owner?.deliver(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            box.release()
            return false
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            box.release()
            return false
        }
        stream = s
        self.box = box
        return true
    }

    func stop() {
        lock.lock()
        let s = stream, b = box
        stream = nil; box = nil
        lock.unlock()
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        b?.release()
    }

    /// Runs on `queue`.
    private func deliver(_ events: [WatchEvent]) {
        var kept: [WatchEvent] = []
        var rootChanged = false
        for e in events {
            if e.rootChanged { rootChanged = true; continue }
            if isIgnored(e.path) { continue }
            if !includeSubfolders && !isDirectChild(e.path) { continue }
            kept.append(e)
        }
        if !kept.isEmpty { onEvents(kept) }
        if rootChanged { onRootChange?() }
    }

    private func isIgnored(_ path: String) -> Bool {
        for p in ignoredPrefixes where path.hasPrefix(p) || path + "/" == p { return true }
        return false
    }

    private func isDirectChild(_ path: String) -> Bool {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return false }
        return !path.dropFirst(prefix.count).contains("/")
    }

    /// Symlink-free absolute path without a trailing slash.
    static func realPath(_ url: URL) -> String {
        var p = url.resolvingSymlinksInPath().standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
