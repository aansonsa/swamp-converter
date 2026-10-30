import Foundation

// Archive read-back for the conformance checks: list and extract with the system's bsdtar / unzip (not the engines' writers and readers), then compare
// trees byte for byte. Also the zip-slip check: no member may name a path outside the folder it is extracted into.

struct TreeEntry: Equatable {
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: Int64
    var mode: UInt16
    var sha256: String?
}

enum ArchiveFidelity {
    /// Every entry below `root` (relative paths, sorted), with size, permission bits and content hash for regular files.
    static func tree(_ root: URL) -> [TreeEntry] {
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        var out: [TreeEntry] = []
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return out }
        for case let u as URL in e {
            let full = u.standardizedFileURL.path
            let rel = String(full.dropFirst(base.count + 1))
            guard let attrs = try? fm.attributesOfItem(atPath: u.path) else { continue }
            let type = attrs[.type] as? FileAttributeType
            let isDir = type == .typeDirectory, isLink = type == .typeSymbolicLink
            let mode = UInt16(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777)
            out.append(TreeEntry(path: rel + (isDir ? "/" : ""), isDirectory: isDir, isSymlink: isLink, size: isDir ? 0 : ((attrs[.size] as? NSNumber)?.int64Value ?? 0),
                                 mode: mode, sha256: (!isDir && !isLink) ? FileHash.sha256(u) : nil))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Extracts `archive` with bsdtar into a fresh folder under the temp root and returns the tree (nil when it cannot be extracted).
    static func extractedTree(_ archive: URL) -> (root: URL, entries: [TreeEntry])? {
        let dir = AppPaths.makeTempDirectory(purpose: "arc")
        guard ExternalProbe.extractWithTar(archive, into: dir) != nil else { AppPaths.removeTemp(dir); return nil }
        return (dir, tree(dir))
    }

    /// Differences between an expected tree and an extracted one: missing and extra members, changed bytes and (optionally) permission bits.
    static func differences(expected: [TreeEntry], actual: [TreeEntry], comparePermissions: Bool = true, ignoreDirectories: Bool = true) -> [String] {
        func keep(_ e: TreeEntry) -> Bool { !(ignoreDirectories && e.isDirectory) }
        let exp = Dictionary(uniqueKeysWithValues: expected.filter(keep).map { ($0.path, $0) })
        let act = Dictionary(actual.filter(keep).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for (p, e) in exp.sorted(by: { $0.key < $1.key }) {
            guard let a = act[p] else { out.append("missing: \(p)"); continue }
            if e.sha256 != a.sha256 { out.append("bytes differ: \(p)") }
            if comparePermissions, e.mode != a.mode, !e.isSymlink { out.append(String(format: "permissions differ: %@ %o vs %o", p, e.mode, a.mode)) }
        }
        for p in act.keys.sorted() where exp[p] == nil { out.append("unexpected: \(p)") }
        return out
    }

    /// Member names that would escape the extraction folder: absolute paths, "..", or a backslash-separated "..". Reads the names with the system tools
    /// and, for ZIP files, from the central directory as well.
    static func unsafeMemberNames(_ archive: URL) -> [String] {
        var names = Set(ExternalProbe.archiveMembers(archive) ?? [])
        if let z = ZipProbe.entries(archive) { names.formUnion(z.map(\.name)) }
        return names.filter { isUnsafe($0) }.sorted()
    }

    static func isUnsafe(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.hasPrefix("~") { return true }
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        return parts.contains("..")
    }

    // MARK: Hostile fixtures

    /// A stored (uncompressed) ZIP built by hand with arbitrary member names, including ones that try to leave the extraction folder.
    static func zipData(members: [(name: String, content: Data, mode: UInt16)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for m in members {
            let name = Data(m.name.utf8)
            let crc = crc32(m.content)
            let offset = UInt32(out.count)
            u32(0x04034b50, &out); u16(20, &out); u16(0x800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(m.content.count), &out); u32(UInt32(m.content.count), &out); u16(name.count, &out); u16(0, &out)
            out.append(name); out.append(m.content)
            u32(0x02014b50, &central); u16(0x031E, &central); u16(20, &central); u16(0x800, &central); u16(0, &central); u16(0, &central); u16(0x21, &central)
            u32(crc, &central); u32(UInt32(m.content.count), &central); u32(UInt32(m.content.count), &central); u16(name.count, &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(UInt32(0o100000 | Int(m.mode)) << 16, &central); u32(offset, &central)
            central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(members.count, &out); u16(members.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }

    /// CRC-32 (IEEE), table-free so the fixtures do not depend on zlib.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
