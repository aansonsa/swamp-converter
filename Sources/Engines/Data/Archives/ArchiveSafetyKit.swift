import Foundation
import Darwin

// The numbers and the walks that keep a hostile archive from crashing the app, escaping its folder or filling the disk. Pure and unit-tested with crafted data.

/// Arithmetic on sizes and dates that come out of an archive: they are attacker-controlled, so nothing here may trap (Swift traps on overflow and on `Int(Double.nan)`).
enum ArchiveMath {
    /// No real file is bigger (1 PiB): a size above this is a lie, and with it the sums of 5 million entries cannot overflow.
    static let maxEntryBytes: Int64 = 1 << 50

    static func sane(_ size: Int64) -> Bool { size >= 0 && size <= maxEntryBytes }

    static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (v, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b < 0 ? Int64.min : Int64.max) : v
    }

    static func sum<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 { values.reduce(Int64(0)) { add($0, $1) } }

    /// Whole seconds for `utimens`: NaN, infinity and absurd dates become "no date" (nil) instead of a crash.
    static func seconds(_ date: Date?) -> Int? {
        guard let t = date?.timeIntervalSince1970, t.isFinite, abs(t) < 4e10 else { return nil }
        return Int(t.rounded(.down))
    }

    /// A TAR size field (octal or GNU base-256) as a size, nil when it is negative or absurd.
    static func tarSize(_ raw: Int?) -> Int64? {
        guard let raw else { return 0 }
        let v = Int64(raw)
        return sane(v) ? v : nil
    }
}

/// Resolves a symbolic link's target the way the kernel will, but only inside `root`: follows the links that exist at this moment (an earlier "x -> ." changes what
/// "x/.." means, which a purely textual check misses), and answers false as soon as the walk leaves `root`.
enum ConfinedPath {
    static func resolvesInside(root: String, linkRelative: String, target: String, maxLinks: Int = 40) -> Bool {
        if target.isEmpty || target.contains("\0") || target.hasPrefix("/") { return false }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        // Components of the folder that holds the link; the folder chain is made of real directories (the sink refuses to write through links).
        var stack = linkRelative.split(separator: "/").dropLast().map(String.init)
        var queue = target.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        var followed = 0
        while !queue.isEmpty {
            let part = queue.removeFirst()
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if stack.isEmpty { return false }
                stack.removeLast()
                continue
            }
            stack.append(part)
            var st = stat()
            guard lstat(base + "/" + stack.joined(separator: "/"), &st) == 0 else { continue }          // nothing there (yet): no link can hide below it
            if (st.st_mode & S_IFMT) == S_IFLNK {
                followed += 1
                if followed > maxLinks { return false }
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(base + "/" + stack.joined(separator: "/"), &buf, buf.count - 1)
                guard n > 0 else { return false }
                let next = String(cString: buf)
                if next.hasPrefix("/") { return false }
                stack.removeLast()
                queue.insert(contentsOf: next.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init), at: 0)
            }
        }
        return true
    }
}

/// How much of the volume an extraction may use: everything except a reserve, so a decompression bomb ends with a calm message while the Mac still works.
enum DiskReserve {
    /// The larger of 512 MB and 2% of the volume's free space.
    static func reserve(forFree free: Int64) -> Int64 { max(512 << 20, free / 50) }

    static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    /// How many bytes an extraction into `directory` may write; nil when the free space cannot be read (then only the disk itself limits it).
    static func allowance(at directory: URL) -> Int64? {
        guard let free = freeBytes(at: directory), free > 0 else { return nil }
        return max(free - reserve(forFree: free), 0)
    }

    static let message = L10n("The archive expands to more data than the free space allows (the Mac keeps a reserve) and was stopped.",
                              "Архив распаковывается в больший объём, чем позволяет свободное место (запас остаётся для системы), распаковка остановлена.")
}

extension ArchiveSafety {
    /// Everything a hostile archive could leave behind that the app's own writer would never create. Run on a tree that bsdtar (libarchive) wrote, and as the last step of
    /// the app's own extraction: links that resolve outside `root` (including chains such as "x -> ." then "y -> x/../..") are removed; files that share their data with a
    /// name outside `root` (a hard link to somebody's file) are removed; devices, pipes and sockets are removed; set-user-id / set-group-id / sticky bits are cleared.
    /// Returns the relative paths that were removed, with the reason.
    @discardableResult
    static func sanitizeTree(at root: URL) -> [String] {
        let rootPath = root.standardizedFileURL.path
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: rootPath) else { return [] }
        var removed: [String] = []
        var links: [(rel: String, target: String)] = []
        var inodes: [UInt64: (nlink: Int, paths: [String])] = [:]
        for case let rel as String in e {
            var st = stat()
            guard lstat(rootPath + "/" + rel, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(rootPath + "/" + rel, &buf, buf.count - 1)
                links.append((rel, n > 0 ? String(cString: buf) : ""))
            case S_IFREG:
                if st.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0 { chmod(rootPath + "/" + rel, st.st_mode & 0o777) }
                if st.st_nlink > 1 { var entry = inodes[UInt64(st.st_ino)] ?? (Int(st.st_nlink), []); entry.paths.append(rel); inodes[UInt64(st.st_ino)] = entry }
            case S_IFDIR:
                if st.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0 { chmod(rootPath + "/" + rel, st.st_mode & 0o777) }
            default:                                                       // device, fifo, socket
                unlink(rootPath + "/" + rel); removed.append("\(rel): special file")
            }
        }
        // Removing a link can change what another one resolves to, so repeat until nothing more goes.
        var again = true
        while again {
            again = false
            for l in links where !removed.contains(where: { $0.hasPrefix(l.rel + ":") }) {
                if !ConfinedPath.resolvesInside(root: rootPath, linkRelative: l.rel, target: l.target) {
                    unlink(rootPath + "/" + l.rel); removed.append("\(l.rel): link outside the destination"); again = true
                }
            }
        }
        for (_, group) in inodes where group.nlink > group.paths.count {      // a name for this data exists outside the extracted tree
            for p in group.paths { unlink(rootPath + "/" + p); removed.append("\(p): hard link to a file outside the archive") }
        }
        return removed
    }

    // MARK: Quarantine

    static let quarantineAttribute = "com.apple.quarantine"

    static func quarantineValue(of url: URL) -> [UInt8]? {
        let size = getxattr(url.path, quarantineAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let n = getxattr(url.path, quarantineAttribute, &buf, size, 0, 0)
        return n > 0 ? Array(buf.prefix(n)) : nil
    }

    /// An archive that carries the "downloaded from the internet" mark hands it to what it contains, like Archive Utility does: every top-level item, every folder and every
    /// file in a normal-sized tree (in a huge tree only the top level and the executable files, which are what Gatekeeper judges). Links are never followed.
    static func propagateQuarantine(from archive: URL, to root: URL, fullLimit: Int = 20_000) {
        guard let value = quarantineValue(of: archive) else { return }
        let rootPath = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(atPath: rootPath) else { return }
        var count = 0
        for case let rel as String in e {
            count += 1
            let path = rootPath + "/" + rel
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
            let topLevel = !rel.contains("/")
            let executable = (st.st_mode & S_IFMT) == S_IFREG && st.st_mode & 0o111 != 0
            if count <= fullLimit || topLevel || executable { _ = setxattr(path, quarantineAttribute, value, value.count, 0, XATTR_NOFOLLOW) }
        }
    }
}
