import AppKit
import Darwin

/// One running instance per support folder (`LSMultipleInstancesProhibited` covers launches through LaunchServices; this covers a second direct launch of the executable and `open -n`).
/// A second launch with files / URLs forwards them to the first through a distributed notification and exits; without arguments it just brings the first one forward. The lock is a
/// `flock` on `<support folder>/instance.lock` held for the whole process lifetime (the system drops it when the process dies, so a crash never leaves a stale lock). A test or measurement
/// run with its own `SWAMP_CONVERTER_HOME` has its own lock and runs next to the real app.
///
/// Security: the notification can be posted by any local process, so the receiver treats it exactly like a URL opened through the system: only existing local files, `swampconverter://`
/// download requests and http(s) links lead anywhere (`URLRouter.route`); nothing is executed and no flags or paths inside strings are interpreted.
@MainActor
enum SingleInstance {
    static let notificationName = Notification.Name("app.swampconverter.forward")
    private static var lockDescriptor: Int32 = -1
    private static var observer: NSObjectProtocol?

    // MARK: Pure helpers (tested)

    /// The launch arguments worth forwarding: existing files / folders (resolved against the working directory, sent as `file://` strings) and absolute http(s) / `swampconverter://`
    /// URLs. Flags (`-psn_...`, `-NSDocumentRevisionsDebugMode`) and everything else are dropped.
    nonisolated static func payload(from arguments: [String], currentDirectory: String = FileManager.default.currentDirectoryPath) -> [String] {
        var out: [String] = []
        for arg in arguments {
            if arg.hasPrefix("-") || arg.isEmpty { continue }
            if let url = URL(string: arg), let scheme = url.scheme?.lowercased(), ["http", "https", DownloadURLScheme.scheme].contains(scheme) { out.append(url.absoluteString); continue }
            let path = arg.hasPrefix("/") ? arg : currentDirectory + "/" + arg
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { out.append(url.absoluteString) }
        }
        return out
    }

    /// The URLs of a received notification; strings that are not URLs or have another scheme are dropped.
    nonisolated static func urls(fromUserInfo info: [AnyHashable: Any]?) -> [URL] {
        guard let strings = info?["urls"] as? [String] else { return [] }
        return strings.prefix(5000).compactMap { URL(string: $0) }.filter { ["file", "http", "https", DownloadURLScheme.scheme].contains($0.scheme?.lowercased() ?? "") }
    }

    // MARK: Lock

    private static var lockURL: URL { AppPaths.supportDir.appendingPathComponent("instance.lock") }

    /// Takes the lock; false when another process holds it. The pid of the owner is written into the file for the second launch to activate it.
    static func acquireLock(at url: URL? = nil) -> Bool {
        let path = (url ?? lockURL).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }   // cannot create the lock (read-only volume): never block the launch
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        _ = ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        lockDescriptor = fd
        return true
    }

    /// Gives the lock back (tests; the real process keeps it until it exits).
    static func releaseLock() {
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    static func ownerPID(at url: URL? = nil) -> pid_t? {
        guard let text = try? String(contentsOf: url ?? lockURL, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    // MARK: Launch

    /// Called by `main.swift` before any UI exists. Returns normally when this is the only instance (the lock is then held for the process lifetime).
    static func forwardAndExitIfAnotherInstanceRuns(arguments: [String]) {
        if ProcessInfo.processInfo.environment["SC_ALLOW_MULTIPLE"] == "1" { return }
        if acquireLock() { return }
        let urls = payload(from: arguments)
        DistributedNotificationCenter.default().postNotificationName(notificationName, object: nil, userInfo: ["urls": urls], deliverImmediately: true)
        if let pid = ownerPID(), let running = NSRunningApplication(processIdentifier: pid) { running.activate() }
        // Give the notification a moment to leave the process before it ends.
        usleep(150_000)
        exit(0)
    }

    /// The running instance listens for forwarded launches. `handler(urls)`: an empty list means "just bring the app forward".
    static func startListening(_ handler: @escaping @MainActor ([URL]) -> Void) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: .main) { note in
            let urls = urls(fromUserInfo: note.userInfo)
            MainActor.assumeIsolated { handler(urls) }
        }
    }
}
