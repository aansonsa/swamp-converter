import Foundation

// `yt-dlp -J` as an operation: build the argv, run it through whatever runner the caller has (a job context or a plain process), turn the answer
// into a DownloadInfo or a calm error. Also the small cache that lets the info card, the Studio estimate and the job share one fetch.

/// How a caller runs a process: a job passes `ctx.runProcess` (pause / cancel reach the child), the info card passes `ProcessRunner`.
typealias DownloadProcessRunner = @Sendable (_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput

enum DownloadInfoFetcher {
    /// Longest an info fetch may take before it is given up with a calm message (slow sites, a hung network).
    static let timeout: TimeInterval = 90

    struct Query: Sendable {
        var url: URL
        /// List entries cheaply; a single video still returns everything.
        var flat = true
        /// The list behind a "video in a list" link (default: only that video).
        var wholePlaylist = false
        var cookies: CookieBrowser = .none
        var jsRuntime: JSRuntime?
        var supportsJSRuntimes = true
    }

    static func fetch(_ q: Query, executable: URL, run: @escaping DownloadProcessRunner, useCache: Bool = true) async throws -> DownloadInfo {
        let key = cacheKey(q)
        if useCache, let hit = DownloadInfoCache.shared.get(key) { return hit }
        let args = YtDlpArguments.infoArguments(url: q.url, flatPlaylist: q.flat, cookies: q.cookies, jsRuntime: q.jsRuntime,
                                                wholePlaylist: q.wholePlaylist, supportsJSRuntimes: q.supportsJSRuntimes)
        let out = try await withTimeout(timeout) { try await run(executable, args) }
        guard out.exitCode == 0 else {
            throw ConversionError.message(YtDlpInfoParser.friendlyMessage(forStderr: out.stderrTail.joined(separator: "\n")))
        }
        let info = try YtDlpInfoParser.parse(json: Data(out.stdout.utf8))
        DownloadInfoCache.shared.put(key, info)
        return info
    }

    static func cacheKey(_ q: Query) -> String {
        LinkParsing.canonicalKey(of: q.url) + (q.flat ? "|flat" : "|full") + (q.wholePlaylist ? "|list" : "|one") + "|" + q.cookies.rawValue
    }

    /// Runs `body`; when it is still running after `seconds` the task is cancelled and a calm error is thrown. A cancel from the caller still
    /// propagates as `CancellationError`.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let timedOut = Locked(false)
        let work = Task { try await body() }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            timedOut.value = true
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError {
            if timedOut.value && !Task.isCancelled {
                throw ConversionError.message(L10n("The site took too long to answer. Try again in a moment.", "Сайт слишком долго отвечает. Повторите чуть позже."))
            }
            throw CancellationError()
        }
    }
}

/// Information about links fetched in the last minute (at most 8 entries). Thread-safe; no persistence, nothing sensitive beyond titles.
final class DownloadInfoCache: @unchecked Sendable {
    static let shared = DownloadInfoCache()
    var lifetime: TimeInterval = 60
    private let lock = NSLock()
    private var entries: [String: (date: Date, info: DownloadInfo)] = [:]

    func get(_ key: String, now: Date = Date()) -> DownloadInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key], now.timeIntervalSince(e.date) < lifetime else { entries[key] = nil; return nil }
        return e.info
    }

    func put(_ key: String, _ info: DownloadInfo, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = (now, info)
        if entries.count > 8, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key { entries[oldest] = nil }
    }

    /// The freshest info for a link whatever the query was (the Studio estimate does not care how it was fetched).
    func latest(forKey canonical: String, now: Date = Date()) -> DownloadInfo? {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.key.hasPrefix(canonical + "|") && now.timeIntervalSince($0.value.date) < lifetime }.max { $0.value.date < $1.value.date }?.value.info
    }

    func clear() { lock.lock(); entries = [:]; lock.unlock() }
}
