import Foundation

/// Streaming zip writer: deflate with a chosen level, UTF-8 names (flag set), stored mode for already-compressed data, zip64 when needed, deterministic order.
///
/// Entries appear in the order they are added (callers sort). Files are streamed with a data descriptor, in-memory entries get complete local headers (so EPUB's
/// `mimetype` and ODF's `mimetype` are plain stored entries without descriptors or extra fields). Zip64 records are written when an entry or the archive exceeds the
/// 4 GiB / 65535-entry limits, or when `forceZip64` is set (tests).
final class ZipWriter {
    enum Method { case stored, deflate }

    /// Entries at or above this size use zip64 headers from the start (the size of a streamed file is known, the compressed size is not).
    static let zip64EntryThreshold: Int64 = 0xF000_0000
    static let zip64Marker32: UInt32 = 0xFFFF_FFFF

    var forceZip64 = false
    private let writer: FDWriter
    private let level: Int
    private var records: [Record] = []
    private var finished = false

    private struct Record {
        var name: Data
        var flags: UInt16
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var csize: Int64
        var usize: Int64
        var offset: Int64
        var external: UInt32
        var mtime: UInt32?
        var zip64Entry: Bool
    }

    init(url: URL, level: Int = 6) throws {
        self.writer = try FDWriter(url: url)
        self.level = max(0, min(9, level))
    }

    // MARK: Adding entries

    /// Adds a file from disk (streamed) or from memory. `storedFirst` entries (EPUB `mimetype`) must be added stored and first.
    func add(file: URL, as name: String, method: Method = .deflate, modified: Date? = nil) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = modified ?? (attrs[.modificationDate] as? Date) ?? Date()
        let posix = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let useDeflate = method == .deflate && level > 0
        let zip64 = forceZip64 || size >= Self.zip64EntryThreshold
        let nameBytes = Data(name.utf8)
        let (dt, dd) = DOSDate.encode(mtime)
        let flags: UInt16 = 0x0008 | (nameBytes.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0)
        let offset = writer.position
        try writeLocalHeader(name: nameBytes, flags: flags, method: useDeflate ? 8 : 0, time: dt, date: dd, crc: 0, csize: 0, usize: 0, zip64: zip64, mtime: mtime, descriptor: true)

        guard let input = InputStream(url: file) else { throw ConversionError.fileUnreadable(file) }
        input.open()
        defer { input.close() }
        let deflater = useDeflate ? StreamDeflater(level: level) : nil
        var crc: UInt32 = 0
        var usize: Int64 = 0
        var csize: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        let out = writer
        while true {
            try Task.checkCancellation()
            let n = buffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, maxLength: $0.count) }
            if n < 0 { throw ConversionError.fileUnreadable(file) }
            if n == 0 { break }
            try buffer.withUnsafeBytes { raw in
                let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                crc = Checksum.crc32(crc, chunk)
                usize += Int64(n)
                if let deflater {
                    try deflater.write(chunk) { csize += Int64($0.count); try out.write($0) }
                } else {
                    csize += Int64(n); try out.write(chunk)
                }
            }
        }
        if let deflater { try deflater.finish { csize += Int64($0.count); try out.write($0) } }
        let isZip64 = zip64 || usize >= 0xFFFF_FFFF || csize >= 0xFFFF_FFFF
        try writeDescriptor(crc: crc, csize: csize, usize: usize, zip64: zip64)
        let external = UInt32(0o100000 | (posix & 0o7777)) << 16
        records.append(Record(name: nameBytes, flags: flags, method: useDeflate ? 8 : 0, time: dt, date: dd, crc: crc, csize: csize, usize: usize, offset: offset,
                              external: external, mtime: Self.unixTime(mtime), zip64Entry: isZip64))
    }

    func add(data: Data, as name: String, method: Method = .deflate, modified: Date? = nil) throws {
        let nameBytes = Data(name.utf8)
        let mtime = modified ?? Date()
        let (dt, dd) = DOSDate.encode(mtime)
        var payload = data
        var m: UInt16 = 0
        if method == .deflate && level > 0 && data.count > 0 {
            var compressed = Data()
            let deflater = StreamDeflater(level: level)
            try data.withUnsafeBytes { try deflater.write($0) { compressed.append(contentsOf: $0) } }
            try deflater.finish { compressed.append(contentsOf: $0) }
            if compressed.count < data.count { payload = compressed; m = 8 }
        }
        let crc = Checksum.crc32(data)
        let flags: UInt16 = nameBytes.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
        let zip64 = forceZip64 || data.count >= Int(Self.zip64EntryThreshold)
        let offset = writer.position
        let withTime = name != "mimetype"      // EPUB / ODF: the mimetype entry carries no extra field
        try writeLocalHeader(name: nameBytes, flags: flags, method: m, time: dt, date: dd, crc: crc, csize: Int64(payload.count), usize: Int64(data.count),
                             zip64: zip64, mtime: withTime ? mtime : nil, descriptor: false)
        try writer.write(payload)
        records.append(Record(name: nameBytes, flags: flags, method: m, time: dt, date: dd, crc: crc, csize: Int64(payload.count), usize: Int64(data.count), offset: offset,
                              external: UInt32(0o100644) << 16, mtime: withTime ? Self.unixTime(mtime) : nil, zip64Entry: zip64))
    }

    func addDirectory(_ name: String) throws { try addDirectory(name, modified: nil) }

    func addDirectory(_ name: String, modified: Date?) throws {
        var n = name
        if !n.hasSuffix("/") { n += "/" }
        let nameBytes = Data(n.utf8)
        let mtime = modified ?? Date()
        let (dt, dd) = DOSDate.encode(mtime)
        let flags: UInt16 = nameBytes.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
        let offset = writer.position
        try writeLocalHeader(name: nameBytes, flags: flags, method: 0, time: dt, date: dd, crc: 0, csize: 0, usize: 0, zip64: false, mtime: mtime, descriptor: false)
        records.append(Record(name: nameBytes, flags: flags, method: 0, time: dt, date: dd, crc: 0, csize: 0, usize: 0, offset: offset,
                              external: UInt32(0o040755) << 16 | 0x10, mtime: Self.unixTime(mtime), zip64Entry: false))
    }

    /// A symbolic link entry: the target path is the entry's data, the Unix file type marks it as a link.
    func addSymlink(target: String, as name: String, modified: Date? = nil) throws {
        let nameBytes = Data(name.utf8)
        let payload = Data(target.utf8)
        let mtime = modified ?? Date()
        let (dt, dd) = DOSDate.encode(mtime)
        let flags: UInt16 = nameBytes.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
        let offset = writer.position
        let crc = Checksum.crc32(payload)
        try writeLocalHeader(name: nameBytes, flags: flags, method: 0, time: dt, date: dd, crc: crc, csize: Int64(payload.count), usize: Int64(payload.count), zip64: false, mtime: mtime, descriptor: false)
        try writer.write(payload)
        records.append(Record(name: nameBytes, flags: flags, method: 0, time: dt, date: dd, crc: crc, csize: Int64(payload.count), usize: Int64(payload.count), offset: offset,
                              external: UInt32(0o120755) << 16, mtime: Self.unixTime(mtime), zip64Entry: false))
    }

    // MARK: Finishing

    /// Writes the central directory and closes. After an error the partial file must be removed by the caller (`ctx.produceFile` does it).
    func finish() throws {
        guard !finished else { return }
        finished = true
        let cdStart = writer.position
        for r in records { try writeCentral(r) }
        let cdSize = writer.position - cdStart
        let needs64 = forceZip64 || records.count >= 0xFFFF || cdStart >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF || records.contains { $0.zip64Entry }
        if needs64 {
            let eocd64Offset = writer.position
            var b = ByteBuilder()
            b.u32(0x0606_4B50); b.u64(44); b.u16(0x031E); b.u16(45); b.u32(0); b.u32(0)
            b.u64(UInt64(records.count)); b.u64(UInt64(records.count)); b.u64(UInt64(cdSize)); b.u64(UInt64(cdStart))
            b.u32(0x0706_4B50); b.u32(0); b.u64(UInt64(eocd64Offset)); b.u32(1)
            try writer.write(b.bytes)
        }
        var e = ByteBuilder()
        e.u32(0x0605_4B50); e.u16(0); e.u16(0)
        let count16 = needs64 ? UInt16(0xFFFF) : UInt16(records.count)
        e.u16(count16); e.u16(count16)
        e.u32(needs64 ? Self.zip64Marker32 : UInt32(cdSize))
        e.u32(needs64 ? Self.zip64Marker32 : UInt32(cdStart))
        e.u16(0)
        try writer.write(e.bytes)
        try writer.close()
    }

    // MARK: Records

    private static func unixTime(_ d: Date) -> UInt32? {
        let t = d.timeIntervalSince1970
        return t >= 0 && t < 4_294_967_295 ? UInt32(t) : nil
    }

    private func writeLocalHeader(name: Data, flags: UInt16, method: UInt16, time: UInt16, date: UInt16, crc: UInt32, csize: Int64, usize: Int64,
                                  zip64: Bool, mtime: Date?, descriptor: Bool) throws {
        var extra = ByteBuilder()
        if zip64 { extra.u16(0x0001); extra.u16(16); extra.u64(UInt64(usize)); extra.u64(UInt64(csize)) }
        if let mtime, let ut = Self.unixTime(mtime) { extra.u16(0x5455); extra.u16(5); extra.u8(1); extra.u32(ut) }
        var b = ByteBuilder()
        b.u32(0x0403_4B50)
        b.u16(zip64 ? 45 : (method == 8 ? 20 : 10))
        b.u16(flags); b.u16(method); b.u16(time); b.u16(date)
        b.u32(crc)
        b.u32(zip64 ? Self.zip64Marker32 : UInt32(truncatingIfNeeded: csize))
        b.u32(zip64 ? Self.zip64Marker32 : UInt32(truncatingIfNeeded: usize))
        b.u16(UInt16(name.count)); b.u16(UInt16(extra.bytes.count))
        b.append(name); b.append(extra.bytes)
        try writer.write(b.bytes)
    }

    private func writeDescriptor(crc: UInt32, csize: Int64, usize: Int64, zip64: Bool) throws {
        var b = ByteBuilder()
        b.u32(0x0807_4B50); b.u32(crc)
        if zip64 { b.u64(UInt64(csize)); b.u64(UInt64(usize)) } else { b.u32(UInt32(truncatingIfNeeded: csize)); b.u32(UInt32(truncatingIfNeeded: usize)) }
        try writer.write(b.bytes)
    }

    private func writeCentral(_ r: Record) throws {
        var extra = ByteBuilder()
        let bigSizes = r.zip64Entry
        let bigOffset = r.offset >= 0xFFFF_FFFF
        if bigSizes || bigOffset {
            var z = ByteBuilder()
            if bigSizes { z.u64(UInt64(r.usize)); z.u64(UInt64(r.csize)) }
            if bigOffset { z.u64(UInt64(r.offset)) }
            extra.u16(0x0001); extra.u16(UInt16(z.bytes.count)); extra.append(z.bytes)
        }
        if let ut = r.mtime { extra.u16(0x5455); extra.u16(5); extra.u8(1); extra.u32(ut) }
        var b = ByteBuilder()
        b.u32(0x0201_4B50)
        b.u16(0x031E)                                   // made by: Unix, spec 3.0
        b.u16(bigSizes || bigOffset ? 45 : (r.method == 8 ? 20 : 10))
        b.u16(r.flags); b.u16(r.method); b.u16(r.time); b.u16(r.date); b.u32(r.crc)
        b.u32(bigSizes ? Self.zip64Marker32 : UInt32(r.csize))
        b.u32(bigSizes ? Self.zip64Marker32 : UInt32(r.usize))
        b.u16(UInt16(r.name.count)); b.u16(UInt16(extra.bytes.count)); b.u16(0); b.u16(0); b.u16(0)
        b.u32(r.external)
        b.u32(bigOffset ? Self.zip64Marker32 : UInt32(r.offset))
        b.append(r.name); b.append(extra.bytes)
        try writer.write(b.bytes)
    }
}
