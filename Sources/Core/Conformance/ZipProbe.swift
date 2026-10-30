import Foundation
import zlib

// A small, independent ZIP reader for the conformance checks: central directory, member list, stored `mimetype` entries and raw member bytes.
// It shares no code with the engines' ZipKit. Honest limits: no encryption, no multi-disk archives; ZIP64 sizes are read from the extra field.

struct ZipMember: Equatable, Sendable {
    var name: String
    var method: Int
    var crc32: UInt32
    var compressedSize: UInt64
    var size: UInt64
    var localHeaderOffset: UInt64
    /// Unix permission bits when the archive was written on Unix (host 3), else nil.
    var unixMode: UInt16?
    var isDirectory: Bool { name.hasSuffix("/") }
    var isSymlink: Bool { (unixMode ?? 0) & 0o170000 == 0o120000 }
}

enum ZipProbe {
    /// The central directory of `url`, or nil when the file is not a well-formed ZIP.
    static func entries(_ url: URL) -> [ZipMember]? {
        guard let r = ByteReader(url: url) else { return nil }
        return entries(r)
    }

    static func entries(_ r: ByteReader) -> [ZipMember]? {
        let tailLen = Int(min(r.size, 66_000))
        let tailStart = r.size - UInt64(tailLen)
        let tail = r.read(at: tailStart, tailLen)
        guard let eocd = tail.lastIndex(where: { _ in true }).flatMap({ _ in lastSignature(in: tail, [0x50, 0x4B, 0x05, 0x06]) }) else { return nil }
        var count = UInt64(tail.u16le(at: eocd + 10) ?? 0)
        var cdSize = UInt64(tail.u32le(at: eocd + 12) ?? 0)
        var cdOffset = UInt64(tail.u32le(at: eocd + 16) ?? 0)
        if (count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF), eocd >= 20, tail.hasBytes([0x50, 0x4B, 0x06, 0x07], at: eocd - 20) {
            let z64At = UInt64(tail.u32le(at: eocd - 20 + 8) ?? 0) | (UInt64(tail.u32le(at: eocd - 20 + 12) ?? 0) << 32)
            let z = r.read(at: z64At, 56)
            if z.hasBytes([0x50, 0x4B, 0x06, 0x06]) {
                count = UInt64(z.u32le(at: 32) ?? 0) | (UInt64(z.u32le(at: 36) ?? 0) << 32)
                cdSize = UInt64(z.u32le(at: 40) ?? 0) | (UInt64(z.u32le(at: 44) ?? 0) << 32)
                cdOffset = UInt64(z.u32le(at: 48) ?? 0) | (UInt64(z.u32le(at: 52) ?? 0) << 32)
            }
        }
        guard cdOffset + cdSize <= r.size, cdSize < 256 << 20 else { return nil }
        let cd = r.read(at: cdOffset, Int(cdSize))
        var out: [ZipMember] = []
        var p = 0
        while p + 46 <= cd.count, cd.hasBytes([0x50, 0x4B, 0x01, 0x02], at: p) {
            let madeByHost = cd[p + 5]
            let flags = cd.u16le(at: p + 8) ?? 0
            let method = Int(cd.u16le(at: p + 10) ?? 0)
            let crc = cd.u32le(at: p + 16) ?? 0
            var csize = UInt64(cd.u32le(at: p + 20) ?? 0), usize = UInt64(cd.u32le(at: p + 24) ?? 0)
            let nameLen = Int(cd.u16le(at: p + 28) ?? 0), extraLen = Int(cd.u16le(at: p + 30) ?? 0), commentLen = Int(cd.u16le(at: p + 32) ?? 0)
            let external = cd.u32le(at: p + 38) ?? 0
            var offset = UInt64(cd.u32le(at: p + 42) ?? 0)
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { return nil }
            let nameBytes = Data(cd[(p + 46)..<(p + 46 + nameLen)])
            let name = (flags & 0x800 != 0 ? String(data: nameBytes, encoding: .utf8) : (String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1)))
                ?? String(decoding: nameBytes, as: UTF8.self)
            // ZIP64 extra field (id 0x0001) carries the values that overflowed.
            var q = p + 46 + nameLen
            let extraEnd = q + extraLen
            while q + 4 <= extraEnd {
                let id = cd.u16le(at: q) ?? 0, len = Int(cd.u16le(at: q + 2) ?? 0)
                if id == 1 {
                    var o = q + 4
                    func take() -> UInt64? {
                        guard o + 8 <= q + 4 + len else { return nil }
                        defer { o += 8 }
                        return UInt64(cd.u32le(at: o) ?? 0) | (UInt64(cd.u32le(at: o + 4) ?? 0) << 32)
                    }
                    if usize == 0xFFFF_FFFF, let v = take() { usize = v }
                    if csize == 0xFFFF_FFFF, let v = take() { csize = v }
                    if offset == 0xFFFF_FFFF, let v = take() { offset = v }
                }
                q += 4 + len
            }
            out.append(ZipMember(name: name, method: method, crc32: crc, compressedSize: csize, size: usize, localHeaderOffset: offset,
                                unixMode: madeByHost == 3 ? UInt16(truncatingIfNeeded: external >> 16) : nil))
            p += 46 + nameLen + extraLen + commentLen
        }
        if UInt64(out.count) != count && count != 0xFFFF { return nil }
        return out
    }

    private static func lastSignature(in bytes: [UInt8], _ sig: [UInt8]) -> Int? {
        guard bytes.count >= sig.count else { return nil }
        var i = bytes.count - sig.count
        while i >= 0 {
            if bytes[i] == sig[0], Array(bytes[i..<(i + sig.count)]) == sig { return i }
            i -= 1
        }
        return nil
    }

    /// Decompressed bytes of one member (stored or deflated), at most `limit` bytes. Verifies the CRC when the member was read completely.
    static func read(_ entry: ZipMember, from url: URL, limit: Int = 64 << 20) -> Data? {
        guard let r = ByteReader(url: url) else { return nil }
        let lh = r.read(at: entry.localHeaderOffset, 30)
        guard lh.hasBytes([0x50, 0x4B, 0x03, 0x04]) else { return nil }
        let start = entry.localHeaderOffset + 30 + UInt64(lh.u16le(at: 26) ?? 0) + UInt64(lh.u16le(at: 28) ?? 0)
        let want = Int(min(entry.compressedSize, UInt64(limit)))
        let raw = Data(r.read(at: start, want))
        guard raw.count == want else { return nil }
        let data: Data
        switch entry.method {
        case 0: data = raw
        case 8:
            guard let d = inflateRaw(raw, expected: Int(min(entry.size, UInt64(limit)))) else { return nil }
            data = d
        default: return nil
        }
        if UInt64(data.count) == entry.size {
            let crc = data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count))) }
            if crc != entry.crc32 { return nil }
        }
        return data
    }

    private static func inflateRaw(_ input: Data, expected: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(raw.count)
            repeat {
                buffer.withUnsafeMutableBytes { b in
                    stream.next_out = b.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = UInt32(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    out.append(b.bindMemory(to: UInt8.self).baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status == Z_OK && out.count < max(expected, 1) + chunk
        }
        return status == Z_STREAM_END || status == Z_OK ? out : nil
    }

    /// Decides what kind of ZIP this is: OOXML, OpenDocument, EPUB or a plain archive.
    static func classify(_ r: ByteReader) -> SniffedFormat {
        guard let list = entries(r) else { return SniffedFormat(key: "bin", detail: "starts like a ZIP but has no readable central directory") }
        let names = Set(list.map(\.name))
        if let first = list.first, first.name == "mimetype", first.method == 0, let url = r.url {
            let mime = ZipProbe.read(first, from: url, limit: 256).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let odf: [String: String] = ["application/vnd.oasis.opendocument.text": "odt", "application/vnd.oasis.opendocument.spreadsheet": "ods",
                                         "application/vnd.oasis.opendocument.presentation": "odp", "application/epub+zip": "epub"]
            if let key = odf[mime.trimmingCharacters(in: .whitespacesAndNewlines)] { return SniffedFormat(key: key, detail: mime) }
        }
        if names.contains("[Content_Types].xml") {
            if names.contains("word/document.xml") { return SniffedFormat(key: "docx", detail: "OOXML word/document.xml, \(list.count) parts") }
            if names.contains("xl/workbook.xml") { return SniffedFormat(key: "xlsx", detail: "OOXML xl/workbook.xml, \(list.count) parts") }
            if names.contains("ppt/presentation.xml") { return SniffedFormat(key: "pptx", detail: "OOXML ppt/presentation.xml, \(list.count) parts") }
        }
        return SniffedFormat(key: "zip", detail: "zip, \(list.count) entries")
    }
}

extension ByteReader {
    /// The file the reader was opened on (kept for helpers that need to re-open it).
    var url: URL? { _url }
}
