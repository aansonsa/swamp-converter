import Foundation

// Safe extraction shared by zip and tar: every entry name is resolved against the destination BEFORE anything is written (zip slip), no write ever goes through a
// symbolic link, symlinks that point outside the destination are not created, files are written with O_NOFOLLOW, dates and permissions are restored (directories last).

struct ExtractionPolicy: Sendable {
    /// Skip `__MACOSX/`, AppleDouble `._*` and `.DS_Store` entries.
    var skipMacJunk = false
    /// Drop folders: every file lands directly in the destination (name clashes get " (2)").
    var flatten = false
    var restoreDates = true
    var restorePermissions = true
    /// Refuse to write more than this many bytes in total (zip bomb guard); nil = limited by free space only.
    var maxTotalBytes: Int64? = nil
}

struct ZipExtractOptions {
    var nameEncoding: ZipNameEncoding = .auto
    var entries: [ZipEntry]? = nil
    var policy = ExtractionPolicy()
}

struct ExtractionReport: Sendable {
    /// First path components of everything that was created, in archive order.
    var topLevel: [String] = []
    var files = 0
    var directories = 0
    var bytes: Int64 = 0
    /// Entries that were left out on purpose ("name: reason"), e.g. links pointing outside the destination, Mac junk.
    var skipped: [String] = []
}

/// Maps POSIX errors of extraction to calm messages.
enum FSErrors {
    static func map(_ code: Int32, path: String) -> ConversionError {
        switch code {
        case ENOSPC: return .message(L10n("There is not enough free space to finish. Free up space and try again.", "Не хватает места на диске. Освободите место и повторите."))
        case EACCES, EPERM, EROFS: return .outputNotWritable(URL(fileURLWithPath: path).deletingLastPathComponent())
        case ENAMETOOLONG: return .message(L10n("A file name in the archive is too long for this disk: \((path as NSString).lastPathComponent)",
                                                "Слишком длинное имя файла для этого диска: \((path as NSString).lastPathComponent)"))
        default: return .message(L10n("File error (\(String(cString: strerror(code)))): \((path as NSString).lastPathComponent)",
                                      "Ошибка файла (\(String(cString: strerror(code)))): \((path as NSString).lastPathComponent)"))
        }
    }
}

/// One output file written through a file descriptor (O_NOFOLLOW; times set before closing).
final class ExtractedFile {
    private var fd: Int32
    let path: String
    init(path: String, mode: mode_t) throws {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, mode)
        self.path = path
        if fd < 0 { throw FSErrors.map(errno, path: path) }
    }
    deinit { if fd >= 0 { Foundation.close(fd) } }

    func write(_ p: UnsafeRawBufferPointer) throws {
        var off = 0
        while off < p.count {
            let n = Foundation.write(fd, p.baseAddress! + off, p.count - off)
            if n < 0 { if errno == EINTR { continue }; throw FSErrors.map(errno, path: path) }
            off += n
        }
    }

    func close(modified: Date?, mode: mode_t?) {
        guard fd >= 0 else { return }
        if let secs = ArchiveMath.seconds(modified) {
            var times = [timespec(tv_sec: secs, tv_nsec: 0), timespec(tv_sec: secs, tv_nsec: 0)]
            futimens(fd, &times)
        }
        if let mode { fchmod(fd, mode) }
        Foundation.close(fd); fd = -1
    }
}

final class ExtractSink {
    let root: URL
    private let rootPath: String
    let policy: ExtractionPolicy
    private(set) var report = ExtractionReport()
    private var verifiedDirs: Set<String> = [""]
    private var usedFlatNames: Set<String> = []
    private var deferredDirs: [(path: String, modified: Date?, mode: UInt32?)] = []
    private var topSeen: Set<String> = []
    private var createdFiles: Set<String> = []

    /// True when the cap on the written bytes was not asked for but derived from the free space of the volume (a bomb guard).
    private let capIsFromFreeSpace: Bool

    init(root: URL, policy: ExtractionPolicy) {
        var p = policy
        // No cap asked for: the extraction may use the free space except a reserve, so a bomb that lies about its sizes ends with a calm message, not a full disk.
        if p.maxTotalBytes == nil, root.path != "/dev/null", let allowance = DiskReserve.allowance(at: root) { p.maxTotalBytes = allowance; capIsFromFreeSpace = true }
        else { capIsFromFreeSpace = false }
        self.root = root
        self.rootPath = root.standardizedFileURL.path
        self.policy = p
    }

    // MARK: Names

    /// The safe relative path (components joined by "/") for an archive entry name, or nil when the entry is to be skipped.
    /// Throws `unsafeArchivePath` for absolute names, drive letters, "..", NUL bytes.
    func relativePath(for rawName: String) throws -> String? {
        let name = rawName.replacingOccurrences(of: "\\", with: "/")
        if name.contains("\0") { throw ConversionError.unsafeArchivePath(rawName) }
        if name.hasPrefix("/") { throw ConversionError.unsafeArchivePath(rawName) }
        let chars = Array(name.unicodeScalars)
        if chars.count >= 2, chars[1] == ":", chars[0].properties.isAlphabetic { throw ConversionError.unsafeArchivePath(rawName) }
        var parts: [String] = []
        for p in name.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { throw ConversionError.unsafeArchivePath(rawName) }
            parts.append(String(p))
        }
        if parts.isEmpty { return nil }
        if policy.skipMacJunk && parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix("._") || $0 == ".DS_Store" }) {
            report.skipped.append("\(rawName): Mac metadata")
            return nil
        }
        return parts.joined(separator: "/")
    }

    // MARK: Creating things

    private func absolute(_ relative: String) -> String { rootPath + "/" + relative }

    /// Makes sure every ancestor of `relative` is a real directory (never a symlink) and creates the missing ones.
    private func ensureParents(of relative: String) throws {
        let comps = relative.split(separator: "/").map(String.init)
        if comps.count < 2 { return }
        var acc = ""
        for c in comps.dropLast() {
            acc = acc.isEmpty ? c : acc + "/" + c
            if verifiedDirs.contains(acc) { continue }
            var st = stat()
            let path = absolute(acc)
            if lstat(path, &st) == 0 {
                if (st.st_mode & S_IFMT) != S_IFDIR { throw ConversionError.unsafeArchivePath(acc) }   // symlink or file in the way
            } else {
                if mkdir(path, 0o755) != 0 && errno != EEXIST { throw FSErrors.map(errno, path: path) }
                report.directories += 1
            }
            verifiedDirs.insert(acc)
        }
    }

    private func noteTop(_ relative: String) {
        let top = relative.split(separator: "/").first.map(String.init) ?? relative
        if topSeen.insert(top).inserted { report.topLevel.append(top) }
    }

    /// Where a file entry goes after flatten / numbering rules.
    private func flatName(_ relative: String) -> String {
        let leaf = (relative as NSString).lastPathComponent
        var candidate = leaf
        var n = 2
        let base = (leaf as NSString).deletingPathExtension, ext = (leaf as NSString).pathExtension
        while usedFlatNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            n += 1
        }
        usedFlatNames.insert(candidate.lowercased())
        return candidate
    }

    func makeDirectory(_ rawName: String, modified: Date?, mode: UInt32?) throws {
        guard !policy.flatten, let rel = try relativePath(for: rawName) else { return }
        try ensureParents(of: rel)
        let path = absolute(rel)
        var st = stat()
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) != S_IFDIR { throw ConversionError.unsafeArchivePath(rel) }
        } else {
            if mkdir(path, 0o755) != 0 && errno != EEXIST { throw FSErrors.map(errno, path: path) }
            report.directories += 1
        }
        verifiedDirs.insert(rel)
        noteTop(rel)
        deferredDirs.append((path, modified, mode))
    }

    /// A second entry with the same name (or a name that differs only by case, which macOS treats as the same file) gets " (2)" instead of overwriting the first.
    private func uniqueName(_ rel: String) -> String {
        var candidate = rel, n = 2
        let ns = rel as NSString
        while !createdFiles.insert(candidate.lowercased()).inserted {
            let ext = ns.pathExtension
            candidate = ext.isEmpty ? "\(rel) (\(n))" : "\(ns.deletingPathExtension) (\(n)).\(ext)"
            n += 1
        }
        return candidate
    }

    /// Opens the output file for an entry (nil = skipped). The caller writes into it and calls `closeFile`.
    func beginFile(_ rawName: String, mode: UInt32?) throws -> ExtractedFile? {
        guard var rel = try relativePath(for: rawName) else { return nil }
        if policy.flatten { rel = flatName(rel) }
        rel = uniqueName(rel)
        try ensureParents(of: rel)
        noteTop(rel)
        let perm = policy.restorePermissions ? mode_t((mode ?? 0o644) & 0o777) : 0o644        // exact bits, like tar and unzip (a read-only file stays read-only)
        return try ExtractedFile(path: absolute(rel), mode: perm)
    }

    func closeFile(_ f: ExtractedFile, modified: Date?, mode: UInt32?) {
        let perm: mode_t? = policy.restorePermissions && mode != nil ? mode_t(mode! & 0o777) : nil
        f.close(modified: policy.restoreDates ? modified : nil, mode: perm)
        report.files += 1
    }

    /// Creates a symbolic link when its target stays inside the destination; others are skipped (and reported).
    func makeSymlink(_ rawName: String, target: String, modified: Date?) throws {
        guard !policy.flatten, let rel = try relativePath(for: rawName) else { return }
        if !target.hasPrefix("/") && !target.contains("\0") {
            var depth = rel.split(separator: "/").count - 1
            var inside = true
            for p in target.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
                if p == "." || p.isEmpty { continue }
                if p == ".." { depth -= 1; if depth < 0 { inside = false; break } } else { depth += 1 }
            }
            // Textually inside is not enough: an earlier link ("x -> .") changes what "x/.." means. Walk the target through the links that exist now.
            if inside && ConfinedPath.resolvesInside(root: rootPath, linkRelative: rel, target: target) {
                try ensureParents(of: rel)
                let path = absolute(rel)
                unlink(path)
                if symlink(target, path) != 0 { throw FSErrors.map(errno, path: path) }
                noteTop(rel)
                report.files += 1
                if policy.restoreDates, let secs = ArchiveMath.seconds(modified) {
                    var t = [timespec(tv_sec: secs, tv_nsec: 0), timespec(tv_sec: secs, tv_nsec: 0)]
                    utimensat(AT_FDCWD, path, &t, AT_SYMLINK_NOFOLLOW)
                }
                return
            }
        }
        report.skipped.append("\(rawName): link outside the destination")
    }

    /// A hard link in a tar file: becomes a copy of the file it points to when that file was extracted already (its name is checked like every other name).
    func makeLinkCopy(_ rawName: String, target: String, modified: Date?) throws {
        guard let source = try relativePath(for: target), let rel = try relativePath(for: rawName) else { return }
        let from = absolute(source)
        var st = stat()
        // The source must be a regular file reached through real folders only: a link on the way ("y -> /") would make the copy read a file from anywhere.
        var acc = ""
        for c in source.split(separator: "/").dropLast() {
            acc = acc.isEmpty ? String(c) : acc + "/" + c
            var ds = stat()
            guard lstat(absolute(acc), &ds) == 0, (ds.st_mode & S_IFMT) == S_IFDIR else { report.skipped.append("\(rawName): hard link through a link"); return }
        }
        guard lstat(from, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { report.skipped.append("\(rawName): hard link to a file that is not in the archive"); return }
        let name = uniqueName(policy.flatten ? flatName(rel) : rel)
        try ensureParents(of: name)
        noteTop(name)
        do { try FileManager.default.copyItem(atPath: from, toPath: absolute(name)) } catch { throw FSErrors.map(errno == 0 ? EIO : errno, path: absolute(name)) }
        report.files += 1
    }

    func addBytes(_ n: Int) throws {
        report.bytes = ArchiveMath.add(report.bytes, Int64(n))
        if let cap = policy.maxTotalBytes, report.bytes > cap {
            if capIsFromFreeSpace { throw ConversionError.message(DiskReserve.message) }
            throw ConversionError.message(L10n("The archive expands to more data than allowed and was stopped.", "Архив распаковывается в слишком большой объём данных, распаковка остановлена."))
        }
    }

    /// Applies directory dates and permissions, deepest first (after all children exist).
    func finish() {
        // Last line of defence over what was written: links resolving outside, aliases of outside files, special files, set-id bits.
        if root.path != "/dev/null" {
            for item in ArchiveSafety.sanitizeTree(at: root) { report.skipped.append(item) }
        }
        for d in deferredDirs.sorted(by: { $0.path.count > $1.path.count }) {
            if policy.restoreDates, let secs = ArchiveMath.seconds(d.modified) {
                var t = [timespec(tv_sec: secs, tv_nsec: 0), timespec(tv_sec: secs, tv_nsec: 0)]
                utimensat(AT_FDCWD, d.path, &t, 0)
            }
            if policy.restorePermissions, let mode = d.mode { chmod(d.path, mode_t((mode & 0o777) | 0o700)) }
        }
        deferredDirs = []
    }
}

extension ZipKit {
    /// Full-featured extraction. Order of events: list -> refuse encrypted entries -> resolve every name (unsafe ones abort) -> check free space -> write.
    /// Nothing is written before all checks pass.
    @discardableResult
    static func unpack(_ url: URL, to directory: URL, options: ZipExtractOptions, progress: ((Double) -> Void)? = nil) async throws -> ExtractionReport {
        let file = try RandomAccessFile(url: url)
        let sink = ExtractSink(root: directory, policy: options.policy)
        do {
            let all = try ZipParser.parse(file, encoding: options.nameEncoding)
            let selected = options.entries ?? all
            if selected.contains(where: { $0.isEncrypted }) { throw ConversionError.encryptedArchive }
            if let bad = selected.first(where: { !$0.isDirectory && $0.method != 0 && $0.method != 8 }) {
                throw ConversionError.unsupported(L10n("This ZIP uses a compression method the app cannot read (\(bad.method)).",
                                                       "Этот ZIP использует метод сжатия, который приложение не читает (\(bad.method))."))
            }
            for e in selected { _ = try sink.relativePath(for: e.name) }                      // zip slip: every name, before the first write
            let total = ArchiveMath.sum(selected.map(\.uncompressedSize))
            try ensureSpace(total, at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let weight = Double(max(total, 1)) + Double(selected.count) * 1024
            var done = 0.0
            var lastReport = Date.distantPast
            for e in selected {
                try Task.checkCancellation()
                if e.isDirectory {
                    try sink.makeDirectory(e.name, modified: e.modified, mode: e.unixMode == 0 ? nil : e.unixMode)
                } else if e.isSymlink {
                    let target = String(decoding: try readData(file, entry: e, limit: 8192), as: UTF8.self)
                    try sink.makeSymlink(e.name, target: target, modified: e.modified)
                } else if let out = try sink.beginFile(e.name, mode: e.unixMode == 0 ? nil : e.unixMode) {
                    do {
                        try ZipEntryStream.stream(file, entry: e) { chunk in
                            try out.write(chunk)
                            try sink.addBytes(chunk.count)
                        }
                    } catch { out.close(modified: nil, mode: nil); throw error }
                    sink.closeFile(out, modified: e.modified, mode: e.unixMode == 0 ? nil : e.unixMode)
                }
                done += Double(e.uncompressedSize) + 1024
                if let progress, Date().timeIntervalSince(lastReport) > 0.08 { lastReport = Date(); progress(min(done / weight, 1)) }
            }
            sink.finish()
            progress?(1)
            return sink.report
        } catch let e as ZipError {
            throw e.conversionError
        }
    }

    /// Throws a calm error when `bytes` cannot fit on the volume holding `directory` (or its nearest existing parent).
    static func ensureSpace(_ bytes: Int64, at directory: URL) throws {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        if let free, free > 0, bytes > free {
            throw ConversionError.message(L10n("Not enough free space: about \(Util.formatBytes(bytes)) needed, \(Util.formatBytes(free)) free.",
                                               "Не хватает места: нужно около \(Util.formatBytes(bytes)), свободно \(Util.formatBytes(free))."))
        }
    }
}
