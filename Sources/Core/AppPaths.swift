import Foundation
import os

// Where the app keeps things. Tests and --self-test redirect everything with `AppPaths.useIsolatedHome`.

enum AppPaths {
    private static let overrides = Locked<(home: URL?, temp: URL?)>((nil, nil))

    /// Application Support folder: `~/Library/Application Support/Swamp Converter` (or the override).
    static var supportDir: URL {
        let url: URL
        if let h = overrides.value.home { url = h }
        else if let env = ProcessInfo.processInfo.environment["SWAMP_CONVERTER_HOME"], !env.isEmpty { url = URL(fileURLWithPath: env, isDirectory: true) }
        else { url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Swamp Converter", isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var settingsFile: URL { supportDir.appendingPathComponent("settings.json") }
    static var presetsDir: URL { sub("Presets") }
    static var logsDir: URL { sub("Logs") }
    static var jobLogsDir: URL { sub("Logs/Jobs") }
    /// Folder for tools the user placed next to the app ("Settings > Tools > Show folder").
    static var userToolsDir: URL { sub("tools") }
    static var queueFile: URL { supportDir.appendingPathComponent("queue.json") }
    static var historyFile: URL { supportDir.appendingPathComponent("history.json") }
    static var layoutFile: URL { supportDir.appendingPathComponent("wheel-layout.json") }
    static var capabilitiesCacheFile: URL { supportDir.appendingPathComponent("caps.json") }

    private static func sub(_ name: String) -> URL {
        let url = supportDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Root for temporary work files. Always a folder we own; deleted subfolders never touch user data.
    static var tempRoot: URL {
        let url: URL
        if let t = overrides.value.temp { url = t }
        else if let env = ProcessInfo.processInfo.environment["SWAMP_CONVERTER_TMP"], !env.isEmpty { url = URL(fileURLWithPath: env, isDirectory: true) }
        else { url = FileManager.default.temporaryDirectory.appendingPathComponent("Swamp Converter", isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh unique empty directory under `tempRoot`. The caller removes it (`removeTemp`).
    static func makeTempDirectory(purpose: String = "work") -> URL {
        let url = tempRoot.appendingPathComponent("\(purpose)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Work folders a crashed or killed run left behind (a normal run removes its own). Only entries of `tempRoot` that nobody touched for `olderThan` go: a job of the
    /// command line that runs at the same moment keeps its folder, because it is younger. Returns how many were removed.
    @discardableResult
    static func sweepStaleTemp(olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let root = tempRoot
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(date) > age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes a directory created by `makeTempDirectory` (refuses anything outside `tempRoot`).
    static func removeTemp(_ url: URL) {
        let root = tempRoot.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Where files that are not files yet (browser drags, clipboard images) are saved: `~/Downloads/Swamp Converter`.
    static func incomingFolder(custom: String? = nil) -> URL {
        let url: URL
        if let c = custom, !c.isEmpty { url = URL(fileURLWithPath: c, isDirectory: true) }
        else if let t = overrides.value.temp { url = t.appendingPathComponent("Incoming", isDirectory: true) }
        else { url = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Swamp Converter", isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Redirects support dir and temp root into one isolated folder (used by --self-test and unit tests).
    /// Returns the folder; call `removeIsolatedHome` when done.
    @discardableResult
    static func useIsolatedHome(under base: URL? = nil) -> URL {
        let root = (base ?? defaultScratchBase).appendingPathComponent("selftest-\(getpid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        overrides.value = (home, tmp)
        return root
    }

    static func removeIsolatedHome(_ root: URL) {
        overrides.value = (nil, nil)
        if root.lastPathComponent.hasPrefix("selftest-") { try? FileManager.default.removeItem(at: root) }
    }

    /// `~/Library/Caches/SwampConverter/tmp` -- the only place development runs may write scratch data.
    static var defaultScratchBase: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("SwampConverter/tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Minimal logging: os.Logger for Console + an in-memory ring for "Copy diagnostics".
enum Log {
    private static let logger = Logger(subsystem: "app.swampconverter", category: "app")
    private static let ring = Locked<[String]>([])

    static func info(_ message: String) { logger.info("\(message, privacy: .public)"); keep("INFO  " + message) }
    static func warn(_ message: String) { logger.warning("\(message, privacy: .public)"); keep("WARN  " + message) }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)"); keep("ERROR " + message) }

    /// Last 300 log lines, newest last.
    static var recent: [String] { ring.value }

    private static func keep(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        ring.withLock { r in
            r.append("[\(stamp)] \(line)")
            if r.count > 300 { r.removeFirst(r.count - 300) }
        }
    }
}
