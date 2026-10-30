import Foundation

/// Settle detection as a pure state machine (testable without a file system): feed (path, size, mtime, now); `ready(now)` returns the paths whose size and mtime
/// were unchanged for `settleMilliseconds`, which are not empty and not temp / partial names. There is NO polling in here: the caller asks `nextDeadline` and arms
/// ONE one-shot timer for it, only while something is pending; when the timer fires it re-reads the files it is waiting for and feeds them back through `observe`.
struct SettleDetector: Sendable {
    var settleMilliseconds = 1500
    /// A file that never settles (or stays empty) is dropped after this long (the original app gave up after 30 minutes).
    var giveUpSeconds: TimeInterval = 1800

    /// What was last seen of a path.
    struct Stamp: Equatable, Sendable {
        var path: String
        var size: Int64
        var modified: Date
    }

    private struct Entry {
        var size: Int64
        var modified: Date
        /// The moment size or mtime last differed from the previous observation.
        var changedAt: Date
        var firstSeen: Date
    }
    private var entries: [String: Entry] = [:]

    init(settleMilliseconds: Int = 1500, giveUpSeconds: TimeInterval = 1800) {
        self.settleMilliseconds = settleMilliseconds
        self.giveUpSeconds = giveUpSeconds
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    /// Paths being waited for, sorted (stable for tests and for the re-read after a timer fired).
    var pendingPaths: [String] { entries.keys.sorted() }
    func isTracking(_ path: String) -> Bool { entries[path] != nil }
    func lastStamp(of path: String) -> Stamp? { entries[path].map { Stamp(path: path, size: $0.size, modified: $0.modified) } }

    private var settle: TimeInterval { Double(max(settleMilliseconds, 0)) / 1000 }

    /// Records what the file looks like now. A different size or mtime restarts the quiet period. A partial / temp name is never tracked (and a tracked path
    /// that turns into one, because the writer renames it away, is forgotten).
    mutating func observe(path: String, size: Int64, modified: Date, now: Date) {
        if WatchCandidate.isTransientName((path as NSString).lastPathComponent) { entries[path] = nil; return }
        if var e = entries[path] {
            if e.size != size || e.modified != modified { e.size = size; e.modified = modified; e.changedAt = now }
            entries[path] = e
        } else {
            entries[path] = Entry(size: size, modified: modified, changedAt: now, firstSeen: now)
        }
    }

    /// Paths that have been quiet for the settle time, with the values they were last seen with; they leave the detector. Empty files wait (they are usually
    /// a download that just started) and expire after `giveUpSeconds`, like anything that keeps changing for that long.
    mutating func readyStamps(now: Date) -> [Stamp] {
        var out: [Stamp] = []
        var expired: [String] = []
        for (path, e) in entries {
            if now.timeIntervalSince(e.firstSeen) >= giveUpSeconds { expired.append(path); continue }
            if e.size > 0 && now.timeIntervalSince(e.changedAt) >= settle { out.append(Stamp(path: path, size: e.size, modified: e.modified)) }
        }
        for p in expired { entries[p] = nil }
        for s in out { entries[s.path] = nil }
        return out.sorted { $0.path < $1.path }
    }

    mutating func ready(now: Date) -> [String] { readyStamps(now: now).map(\.path) }

    /// The next time `ready` can return something (to arm ONE one-shot timer); nil when nothing is pending. Never earlier than `now`.
    func nextDeadline(now: Date) -> Date? {
        var best: Date?
        for e in entries.values {
            let d = e.size > 0 ? e.changedAt.addingTimeInterval(settle) : e.firstSeen.addingTimeInterval(giveUpSeconds)
            let capped = min(d, e.firstSeen.addingTimeInterval(giveUpSeconds))
            if best == nil || capped < best! { best = capped }
        }
        return best.map { max($0, now) }
    }

    mutating func forget(path: String) { entries[path] = nil }
    mutating func removeAll() { entries.removeAll() }
}
