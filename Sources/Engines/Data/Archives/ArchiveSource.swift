import Foundation

// What goes into an archive: the dropped files and folders turned into a flat, deterministic, deduplicated list of entries. Mac junk (.DS_Store, AppleDouble ._* sidecars -
// the exFAT drive makes one for EVERY file -, __MACOSX, Spotlight / Trash folders), hidden files, user patterns and the app's own in-flight ".part" files are filtered here,
// once, for every archive format.

struct ArchivePackOptions: Sendable {
    var excludeJunk = true
    var includeHidden = true
    var patterns: [String] = []
    /// keep (dropped items at the root), add (everything inside a folder named `archiveName`), strip (the contents of dropped folders at the root).
    var root = "keep"
    var archiveName = "Archive"
    var keepDates = true
    var normaliseNames = true

    static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct ArchivePackEntry: Sendable {
    enum Kind: Sendable { case file, directory, symlink }
    var name: String            // "/"-separated, no leading or trailing slash
    var kind: Kind
    var url: URL?
    var size: Int64 = 0
    var modified: Date
    var mode: UInt32
    var linkTarget: String?
}

enum ArchiveSource {
    static let junkNames: Set<String> = [".DS_Store", ".AppleDouble", ".LSOverride", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
                                         ".apdisk", "__MACOSX", "Thumbs.db", "desktop.ini"]
    /// 1980-01-01 00:00:00 UTC: the date written when dates are not kept (reproducible archives, no timestamps leaking).
    static let fixedDate = Date(timeIntervalSince1970: 315_532_800)

    static func isJunk(_ name: String) -> Bool { junkNames.contains(name) || name.hasPrefix("._") }

    /// `relativePath` is the path inside the dropped folder ("img/photo.jpg"); patterns match the name, that path, or the path with the folder's own name in front.
    static func isExcluded(name: String, relativePath: String, rootName: String = "", options o: ArchivePackOptions) -> Bool {
        if OutputPaths.isInFlightName(name) { return true }
        if o.excludeJunk && isJunk(name) { return true }
        if !o.includeHidden && name.hasPrefix(".") { return true }
        for p in o.patterns where fnmatch(p, name, 0) == 0 || fnmatch(p, relativePath, 0) == 0 || (!rootName.isEmpty && fnmatch(p, rootName + "/" + relativePath, 0) == 0) { return true }
        return false
    }

    /// Entries for `urls` in dropped order (children of folders sorted by name). Throws on cancellation and when a dropped item cannot be read.
    static func collect(_ urls: [URL], options o: ArchivePackOptions) throws -> [ArchivePackEntry] {
        var out: [ArchivePackEntry] = []
        var used = Set<String>()
        func norm(_ s: String) -> String { o.normaliseNames ? s.precomposedStringWithCanonicalMapping : s }
        func unique(_ name: String) -> String {
            var candidate = name, n = 2
            while used.contains(candidate.lowercased()) {
                let ns = name as NSString
                let ext = ns.pathExtension
                candidate = ext.isEmpty ? "\(name) (\(n))" : "\(ns.deletingPathExtension) (\(n)).\(ext)"
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
        var wrapperPrefix = ""
        // A single dropped folder already is "one folder around everything": no second one is added.
        let singleFolder = urls.count == 1 && make(urls[0], name: "x", options: o)?.kind == .directory
        if o.root == "add" && !singleFolder {
            let w = norm(Util.safeFileName(o.archiveName, fallback: "Archive"))
            out.append(ArchivePackEntry(name: w, kind: .directory, url: nil, modified: o.keepDates ? Date() : fixedDate, mode: 0o755))
            used.insert(w.lowercased())
            wrapperPrefix = w + "/"
        }

        func walk(_ dir: URL, entryPrefix: String, relPrefix: String, rootName: String) throws {
            try Task.checkCancellation()
            let names = DirectoryListing.names(dir.path).sorted { norm($0).utf8.lexicographicallyPrecedes(norm($1).utf8) }
            for n in names {
                let rel = relPrefix + n
                if isExcluded(name: n, relativePath: rel, rootName: rootName, options: o) { continue }
                let child = dir.appendingPathComponent(n)
                guard let entry = make(child, name: unique(entryPrefix + norm(n)), options: o) else { continue }
                out.append(entry)
                if entry.kind == .directory { try walk(child, entryPrefix: entry.name + "/", relPrefix: rel + "/", rootName: rootName) }
            }
        }

        for url in urls {
            try Task.checkCancellation()
            guard let probe = make(url, name: "x", options: o) else { throw ConversionError.fileUnreadable(url) }
            if probe.kind == .directory && o.root == "strip" {
                try walk(url, entryPrefix: wrapperPrefix, relPrefix: "", rootName: url.lastPathComponent)
                continue
            }
            guard let entry = make(url, name: unique(wrapperPrefix + norm(url.lastPathComponent)), options: o) else { continue }
            out.append(entry)
            if entry.kind == .directory { try walk(url, entryPrefix: entry.name + "/", relPrefix: "", rootName: url.lastPathComponent) }
        }
        return out
    }

    /// One entry from the file system without following symlinks; nil for sockets, devices and other special files.
    private static func make(_ url: URL, name: String, options o: ArchivePackOptions) -> ArchivePackEntry? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let type = attrs[.type] as? FileAttributeType else { return nil }
        let modified = o.keepDates ? ((attrs[.modificationDate] as? Date) ?? fixedDate) : fixedDate
        let mode = ((attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644) & 0o7777
        switch type {
        case .typeDirectory: return ArchivePackEntry(name: name, kind: .directory, url: url, modified: modified, mode: mode | 0o700)
        case .typeSymbolicLink:
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return ArchivePackEntry(name: name, kind: .symlink, url: url, modified: modified, mode: 0o755, linkTarget: o.normaliseNames ? target.precomposedStringWithCanonicalMapping : target)
        case .typeRegular: return ArchivePackEntry(name: name, kind: .file, url: url, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: modified, mode: mode)
        default: return nil
        }
    }

    static func totalBytes(_ entries: [ArchivePackEntry]) -> Int64 { entries.reduce(0) { $0 + $1.size } }
}

enum DirectoryListing {
    /// The names in a directory exactly as the file system has them. `FileManager.contentsOfDirectory` hides AppleDouble `._name` companions of existing files, which would make
    /// "include Mac system files" and the extracted-tree walks lie.
    static func names(_ path: String) -> [String] {
        guard let d = opendir(path) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: &e.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            out.append(name)
        }
        return out
    }
}
