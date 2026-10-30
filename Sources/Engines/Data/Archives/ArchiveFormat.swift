import Foundation

// Archive formats of the data module: detection by content (magic bytes) and by name, display names, and which engine handles them.
//   zip                 ZipKit (own reader and writer)
//   tar, tar.gz, gz     TarKit + zlib (own)
//   tar.bz2, tar.xz, tar.zst, bz2, xz, zst, 7z, rar    bsdtar / libarchive (macOS), bunzip2, compression_tool, zstd

enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, tar
    case tarGz = "tar.gz", gz
    case tarBz2 = "tar.bz2", bz2
    case tarXz = "tar.xz", xz
    case tarZst = "tar.zst", zst
    case sevenZip = "7z", rar

    /// By file name (double extensions and aliases like .tgz / .tbz2 / .txz come from `Formats.key`).
    init?(key: String) { self.init(rawValue: key) }
    init?(url: URL) { self.init(rawValue: Formats.key(of: url)) }

    /// Formats this app can WRITE.
    static let writable: [ArchiveFormat] = [.zip, .tar, .tarGz, .tarBz2, .tarXz, .tarZst, .sevenZip]

    var fileExtension: String { rawValue }
    var displayName: String { Formats.displayName(rawValue) }
    var isTarFamily: Bool { [.tar, .tarGz, .tarBz2, .tarXz, .tarZst].contains(self) }

    /// Content sniffing: the format of the bytes, whatever the name says. Compressed streams report their compression ("gz", "bz2", "xz", "zst"); the caller decides whether a tar is inside.
    static func sniff(_ url: URL) -> ArchiveFormat? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = [UInt8]((try? h.read(upToCount: 512)) ?? Data())
        return sniff(head)
    }

    static func sniff(_ b: [UInt8]) -> ArchiveFormat? {
        func starts(_ p: [UInt8]) -> Bool { b.count >= p.count && Array(b[0..<p.count]) == p }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if starts([0x1F, 0x8B]) { return .gz }
        if starts([0x42, 0x5A, 0x68]) { return .bz2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .zst }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if TarHeader.looksLikeTar(b) { return .tar }
        return nil
    }

    /// The format to use: the content wins over the name (a ".zip" that is really a tar.gz still extracts); the name decides when the content is not recognised.
    /// A gzip stream is a tar.gz when a tar header follows (checked, a few KB); bz2 / xz / zstd streams are tar.* when the name says so (libarchive finds out at extraction).
    static func resolve(_ url: URL) -> ArchiveFormat? {
        guard let sniffed = sniff(url) else { return ArchiveFormat(url: url) }
        let named = ArchiveFormat(url: url)
        switch sniffed {
        case .gz: return ((try? ArchiveExtractor.gzipHoldsTar(url)) ?? false) ? .tarGz : .gz
        case .bz2: return named == .tarBz2 ? .tarBz2 : .bz2
        case .xz: return named == .tarXz ? .tarXz : .xz
        case .zst: return named == .tarZst ? .tarZst : .zst
        default: return sniffed
        }
    }

    /// The bare compression of a tar.* format.
    var bare: ArchiveFormat? {
        switch self { case .tarGz: return .gz; case .tarBz2: return .bz2; case .tarXz: return .xz; case .tarZst: return .zst; default: return nil }
    }

    /// A compressed stream without a tar inside is a single compressed file.
    var wrapsSingleFile: Bool { [.gz, .bz2, .xz, .zst].contains(self) }
}
