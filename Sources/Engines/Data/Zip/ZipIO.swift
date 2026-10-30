import Foundation
import zlib

// Low-level building blocks of the zip / gzip / tar code: positional file reads, bounds-checked little-endian parsing, streaming inflate / deflate (zlib) and DOS dates.
// Nothing here knows about archives; everything is streaming and cancellable by the caller.

/// Read-only random access to a file (pread: no shared seek position).
final class RandomAccessFile: @unchecked Sendable {
    let fd: Int32
    let size: Int64
    let url: URL

    init(url: URL) throws {
        let f = open(url.path, O_RDONLY)
        guard f >= 0 else { throw ConversionError.fileUnreadable(url) }
        var st = stat()
        guard fstat(f, &st) == 0 else { close(f); throw ConversionError.fileUnreadable(url) }
        self.fd = f; self.size = Int64(st.st_size); self.url = url
    }
    deinit { close(fd) }

    /// Up to `count` bytes at `offset` (fewer at the end of the file). Throws `fileUnreadable` on I/O errors.
    func read(at offset: Int64, count: Int) throws -> Data {
        if count <= 0 || offset < 0 || offset >= size { return Data() }
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        if got < 0 { throw ConversionError.fileUnreadable(url) }
        if got < count { data.removeSubrange(got..<count) }
        return data
    }
}

/// Bounds-checked little-endian reader over a byte array. Reads past the end throw instead of trapping (damaged archives must never crash the app).
struct ByteCursor {
    let bytes: [UInt8]
    var pos: Int = 0
    init(_ bytes: [UInt8], at pos: Int = 0) { self.bytes = bytes; self.pos = pos }

    var remaining: Int { bytes.count - pos }

    private func need(_ n: Int) throws { if n < 0 || pos + n > bytes.count { throw ZipError.truncated } }

    mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return bytes[pos] }
    mutating func u16() throws -> UInt16 { try need(2); defer { pos += 2 }; return UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8 }
    mutating func u32() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        return UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
    }
    mutating func u64() throws -> UInt64 { let lo = UInt64(try u32()); let hi = UInt64(try u32()); return lo | hi << 32 }
    mutating func data(_ n: Int) throws -> Data { try need(n); defer { pos += n }; return Data(bytes[pos..<(pos + n)]) }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { o + 1 < b.count ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : 0 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        o + 3 < b.count ? UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 : 0
    }
}

/// Internal parse failure; surfaced to the user as a calm "damaged archive" message.
enum ZipError: Error {
    case truncated
    case notAZip
    case damaged(String)

    var conversionError: ConversionError {
        switch self {
        case .truncated, .damaged:
            return .message(L10n("The archive is damaged or incomplete.", "Архив повреждён или неполный."))
        case .notAZip:
            return .message(L10n("This is not a ZIP archive.", "Это не ZIP-архив."))
        }
    }
}

enum Checksum {
    static func crc32(_ crc: UInt32, _ p: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = p.baseAddress, p.count > 0 else { return crc }
        return UInt32(zlib.crc32(uLong(crc), base.assumingMemoryBound(to: Bytef.self), uInt(p.count)))
    }
    static func crc32(_ data: Data) -> UInt32 { data.withUnsafeBytes { crc32(0, $0) } }
}

/// Streaming inflate: raw deflate (zip entries, window -15) or zlib / gzip auto-detect (window 47).
final class StreamInflater {
    private var s = z_stream()
    private var out = [UInt8](repeating: 0, count: 128 * 1024)
    private(set) var finished = false
    private var inited = false
    private let window: Int32

    init(window: Int32 = -15) {
        self.window = window
        inited = inflateInit2_(&s, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }
    deinit { if inited { inflateEnd(&s) } }

    /// Feeds `input`; `sink` receives the produced bytes (possibly several calls). Returns how many input bytes were consumed:
    /// fewer than `input.count` only when the deflate stream ended inside this chunk.
    func feed(_ input: UnsafeRawBufferPointer, sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        guard inited else { throw ZipError.damaged("inflate init") }
        if finished || input.count == 0 { return 0 }
        s.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self))
        s.avail_in = uInt(input.count)
        while true {
            let rc: Int32 = out.withUnsafeMutableBufferPointer { buf in
                s.next_out = buf.baseAddress
                s.avail_out = uInt(buf.count)
                return inflate(&s, Z_NO_FLUSH)
            }
            let produced = out.count - Int(s.avail_out)
            if produced > 0 { try out.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) } }
            if rc == Z_STREAM_END { finished = true; break }
            if rc == Z_BUF_ERROR { break }
            if rc != Z_OK { throw ZipError.damaged("inflate \(rc)") }
            if s.avail_in == 0 && s.avail_out != 0 { break }
        }
        return input.count - Int(s.avail_in)
    }

    /// Starts over for the next gzip member (concatenated .gz files).
    func reset() { inflateReset(&s); finished = false }
}

/// Streaming deflate: raw (zip entries, window -15) or gzip (window 31).
final class StreamDeflater {
    private var s = z_stream()
    private var out = [UInt8](repeating: 0, count: 128 * 1024)
    private var inited = false

    init(level: Int, window: Int32 = -15) {
        let lvl = Int32(max(0, min(9, level)))
        inited = deflateInit2_(&s, lvl, Z_DEFLATED, window, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }
    deinit { if inited { deflateEnd(&s) } }

    func write(_ input: UnsafeRawBufferPointer, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        try run(input, flush: Z_NO_FLUSH, sink: sink)
    }
    func finish(sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        try run(UnsafeRawBufferPointer(start: nil, count: 0), flush: Z_FINISH, sink: sink)
    }

    private func run(_ input: UnsafeRawBufferPointer, flush: Int32, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard inited else { throw ZipError.damaged("deflate init") }
        s.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
        s.avail_in = uInt(input.count)
        while true {
            let rc: Int32 = out.withUnsafeMutableBufferPointer { buf in
                s.next_out = buf.baseAddress
                s.avail_out = uInt(buf.count)
                return deflate(&s, flush)
            }
            let produced = out.count - Int(s.avail_out)
            if produced > 0 { try out.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) } }
            if rc == Z_STREAM_END { break }
            if rc != Z_OK && rc != Z_BUF_ERROR { throw ZipError.damaged("deflate \(rc)") }
            if flush != Z_FINISH && s.avail_in == 0 && s.avail_out != 0 { break }
        }
    }
}

/// MS-DOS date and time (local time, 2 s resolution, 1980 ... 2107) as stored in zip headers.
enum DOSDate {
    static func encode(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1980
        if year < 1980 { return (0, UInt16(1 << 5 | 1)) }              // 1980-01-01 00:00:00
        if year > 2107 { return (UInt16(23 << 11 | 59 << 5 | 29), UInt16(127 << 9 | 12 << 5 | 31)) }
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let d = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (t, d)
    }

    static func decode(time: UInt16, date: UInt16) -> Date? {
        if date == 0 { return nil }
        var c = DateComponents()
        c.year = 1980 + Int(date >> 9)
        c.month = Int((date >> 5) & 0xF)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        return Calendar.current.date(from: c)
    }
}

/// Buffered sequential file writer that counts the bytes written (zip offsets, tar sizes). `flush` / `close` surface disk-full errors as calm messages.
final class FDWriter {
    private var fd: Int32
    private let path: String
    private var buffer: [UInt8] = []
    private let capacity = 256 * 1024
    private(set) var position: Int64 = 0

    init(url: URL) throws {
        path = url.path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        if fd < 0 { throw FSErrors.map(errno, path: path) }
        buffer.reserveCapacity(capacity)
    }
    deinit { if fd >= 0 { Foundation.close(fd) } }

    func write(_ p: UnsafeRawBufferPointer) throws {
        position += Int64(p.count)
        if p.count >= capacity {
            try flush()
            try raw(p)
        } else {
            if buffer.count + p.count > capacity { try flush() }
            buffer.append(contentsOf: p)
        }
    }
    func write(_ d: Data) throws { try d.withUnsafeBytes { try write($0) } }
    func write(_ b: [UInt8]) throws { try b.withUnsafeBytes { try write($0) } }

    func flush() throws {
        if buffer.isEmpty { return }
        try buffer.withUnsafeBytes { try raw($0) }
        buffer.removeAll(keepingCapacity: true)
    }

    private func raw(_ p: UnsafeRawBufferPointer) throws {
        var off = 0
        while off < p.count {
            let n = Foundation.write(fd, p.baseAddress! + off, p.count - off)
            if n < 0 { if errno == EINTR { continue }; throw FSErrors.map(errno, path: path) }
            off += n
        }
    }

    func close() throws {
        try flush()
        if fd >= 0 { let rc = Foundation.close(fd); fd = -1; if rc != 0 { throw FSErrors.map(errno, path: path) } }
    }
}

/// Little-endian byte builder for headers.
struct ByteBuilder {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func append(_ d: Data) { bytes.append(contentsOf: d) }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}
