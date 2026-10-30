import Foundation
import zlib

// TAR reader and writer, own code. Reader: ustar, pax (path, linkpath, size, mtime), GNU long names (L / K), base-256 sizes, hard links and symlinks reported, streaming from a
// plain file or through gzip (multi-member streams included). Writer: ustar headers, pax records for long or non-ASCII names, deterministic (uid / gid 0, no user names).

struct TarEntry: Sendable {
    enum Kind: Sendable { case file, directory, symlink, hardlink, other }
    var name: String
    var kind: Kind
    var size: Int64
    var mode: UInt32
    var modified: Date?
    var linkTarget: String?
}

enum TarHeader {
    static let blockSize = 512

    /// True when `block` is a ustar / GNU header (magic "ustar") or a v7 header whose checksum fits.
    static func looksLikeTar(_ b: [UInt8]) -> Bool {
        guard b.count >= 512 else { return false }
        if Array(b[257..<262]) == Array("ustar".utf8) { return checksumOK(b) }
        return b[0] != 0 && checksumOK(b) && b[156] >= 0x30 && b[156] <= 0x37 && octal(b, 124, 12) != nil
    }

    static func checksumOK(_ b: [UInt8]) -> Bool {
        guard b.count >= 512, let stored = octal(b, 148, 8) else { return false }
        var sum = 0
        for i in 0..<512 { sum += (i >= 148 && i < 156) ? 0x20 : Int(b[i]) }
        return sum == stored
    }

    static func octal(_ b: [UInt8], _ offset: Int, _ length: Int) -> Int? {
        guard offset + length <= b.count else { return nil }
        if b[offset] & 0x80 != 0 {                                  // GNU base-256
            var v = Int(b[offset] & 0x7F)
            for i in 1..<length { v = v << 8 | Int(b[offset + i]) }
            return v
        }
        var v = 0, seen = false
        for i in offset..<(offset + length) {
            let c = b[i]
            if c == 0 || c == 0x20 { if seen { break } else { continue } }
            guard c >= 0x30, c <= 0x37 else { return nil }
            v = v << 3 | Int(c - 0x30); seen = true
        }
        return seen ? v : 0
    }

    static func string(_ b: [UInt8], _ offset: Int, _ length: Int) -> String {
        var end = offset
        while end < offset + length, b[end] != 0 { end += 1 }
        return String(decoding: b[offset..<end], as: UTF8.self)
    }
}

/// Pull-style byte source: a file, optionally through gzip.
final class TarByteSource {
    private let handle: FileHandle
    private let inflater: StreamInflater?
    private var pending: [UInt8] = []
    private var pendingPos = 0
    private var inputDone = false
    let totalCompressed: Int64
    private(set) var consumedCompressed: Int64 = 0

    init(url: URL, gzip: Bool) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ConversionError.fileUnreadable(url) }
        handle = h
        inflater = gzip ? StreamInflater(window: 47) : nil
        totalCompressed = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    deinit { try? handle.close() }

    /// Up to `count` bytes (fewer only at the end of the stream).
    func read(_ count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            if pendingPos < pending.count {
                let take = min(count - out.count, pending.count - pendingPos)
                out.append(contentsOf: pending[pendingPos..<(pendingPos + take)])
                pendingPos += take
                continue
            }
            if inputDone { break }
            try Task.checkCancellation()
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { inputDone = true; break }
            consumedCompressed += Int64(chunk.count)
            guard let inflater else { pending = [UInt8](chunk); pendingPos = 0; continue }
            var produced: [UInt8] = []
            var offset = 0
            let bytes = [UInt8](chunk)
            while offset < bytes.count {
                if inflater.finished { inflater.reset() }              // the next gzip member of a concatenated file
                let used = try bytes.withUnsafeBytes { raw -> Int in
                    try inflater.feed(UnsafeRawBufferPointer(rebasing: raw[offset...])) { produced.append(contentsOf: $0) }
                }
                if used == 0 { break }
                offset += used
            }
            pending = produced; pendingPos = 0
        }
        return out
    }

    func skip(_ count: Int64) throws {
        var left = count
        while left > 0 {
            let got = try read(Int(min(left, 1 << 20)))
            if got.isEmpty { throw ZipError.truncated }
            left -= Int64(got.count)
        }
    }
}

enum TarReader {
    /// Reads every entry. `body` receives the entry and a function that returns the next chunk of its data (empty at the end); unread data is skipped. Throws `damaged` errors as
    /// calm messages and `CancellationError` when the task is cancelled.
    static func stream(_ source: TarByteSource, onEntry: (TarEntry, _ readBody: (Int) throws -> [UInt8]) throws -> Void) throws {
        var pendingPath: String?, pendingLink: String?
        var paxPath: String?, paxLink: String?, paxSize: Int64?, paxMtime: Double?
        var zeroBlocks = 0
        while true {
            let header = try source.read(512)
            if header.isEmpty { return }
            guard header.count == 512 else { throw ConversionError.message(L10n("The TAR archive is cut short.", "Архив TAR оборван.")) }
            if header.allSatisfy({ $0 == 0 }) { zeroBlocks += 1; if zeroBlocks >= 2 { return }; continue }
            zeroBlocks = 0
            guard TarHeader.checksumOK(header) else { throw ConversionError.message(L10n("The TAR archive is damaged (bad header checksum).", "Архив TAR повреждён (неверная контрольная сумма заголовка).")) }
            let type = header[156]
            // A size is a claim from the file: negative or absurd means a damaged archive (and keeps `size + 511` from overflowing).
            guard var size = ArchiveMath.tarSize(TarHeader.octal(header, 124, 12)), ArchiveMath.sane(paxSize ?? 0) else {
                throw ConversionError.message(L10n("The TAR archive is damaged (impossible file size).", "Архив TAR повреждён (невозможный размер файла)."))
            }
            if let p = paxSize { size = p }
            let padded = (size + 511) / 512 * 512

            func readAll(_ limit: Int64) throws -> [UInt8] {
                guard limit <= 1 << 20 else { throw ConversionError.message(L10n("The TAR archive is damaged (oversized header record).", "Архив TAR повреждён (слишком большая запись заголовка).")) }
                let data = try source.read(Int(limit))
                if padded > size { try source.skip(padded - size) }
                return data
            }
            switch type {
            case UInt8(ascii: "x"):                                     // pax extended header for the next entry
                let data = try readAll(size)
                for (k, v) in parsePax(data) {
                    switch k { case "path": paxPath = v; case "linkpath": paxLink = v; case "size": paxSize = Int64(v); case "mtime": paxMtime = Double(v); default: break }
                }
                continue
            case UInt8(ascii: "g"): _ = try readAll(size); continue      // global pax header: ignored
            case UInt8(ascii: "L"): pendingPath = String(decoding: try readAll(size).prefix { $0 != 0 }, as: UTF8.self); continue
            case UInt8(ascii: "K"): pendingLink = String(decoding: try readAll(size).prefix { $0 != 0 }, as: UTF8.self); continue
            default: break
            }
            var name = paxPath ?? pendingPath ?? {
                let base = TarHeader.string(header, 0, 100), prefix = TarHeader.string(header, 345, 155)
                return prefix.isEmpty || Array(header[257..<262]) != Array("ustar".utf8) ? base : prefix + "/" + base
            }()
            let link = paxLink ?? pendingLink ?? TarHeader.string(header, 157, 100)
            let mtime = paxMtime ?? Double(TarHeader.octal(header, 136, 12) ?? 0)
            let modified = ArchiveMath.seconds(mtime > 0 ? Date(timeIntervalSince1970: mtime) : nil).map { Date(timeIntervalSince1970: Double($0)) }
            paxPath = nil; paxLink = nil; paxSize = nil; paxMtime = nil; pendingPath = nil; pendingLink = nil
            let kind: TarEntry.Kind
            switch type {
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): kind = name.hasSuffix("/") ? .directory : .file
            case UInt8(ascii: "5"): kind = .directory
            case UInt8(ascii: "2"): kind = .symlink
            case UInt8(ascii: "1"): kind = .hardlink
            default: kind = .other
            }
            if kind == .directory, !name.hasSuffix("/") { name += "/" }
            let entry = TarEntry(name: name, kind: kind, size: kind == .file ? size : 0, mode: UInt32(TarHeader.octal(header, 100, 8) ?? 0o644) & 0o7777,
                                 modified: modified, linkTarget: link.isEmpty ? nil : link)
            var remaining = kind == .file ? size : 0
            var readSoFar: Int64 = 0
            try onEntry(entry) { max in
                if remaining <= 0 { return [] }
                let chunk = try source.read(Int(min(Int64(max), remaining)))
                if chunk.isEmpty { throw ConversionError.message(L10n("The TAR archive is cut short.", "Архив TAR оборван.")) }
                remaining -= Int64(chunk.count); readSoFar += Int64(chunk.count)
                return chunk
            }
            // Skip whatever the callback did not read (every entry type: a header may carry data we do not use), then the padding up to the next block.
            if size - readSoFar > 0 { try source.skip(size - readSoFar) }
            if padded > size { try source.skip(padded - size) }
        }
    }

    private static func parsePax(_ data: [UInt8]) -> [(String, String)] {
        var out: [(String, String)] = []
        var i = 0
        while i < data.count {
            var j = i
            while j < data.count, data[j] != 0x20 { j += 1 }
            guard j < data.count, let len = Int(String(decoding: data[i..<j], as: UTF8.self)), len > j - i + 1, i + len <= data.count else { break }
            let record = data[(j + 1)..<(i + len - 1)]
            if let eq = record.firstIndex(of: UInt8(ascii: "=")) {
                out.append((String(decoding: record[record.startIndex..<eq], as: UTF8.self), String(decoding: record[(eq + 1)...], as: UTF8.self)))
            }
            i += len
        }
        return out
    }
}

/// Writes tar entries to any sink (a file, a gzip stream). Names that do not fit ustar (over 100 bytes without a usable split, or non-ASCII) get a pax header.
final class TarWriter {
    private let sink: (UnsafeRawBufferPointer) throws -> Void
    private(set) var bytesWritten: Int64 = 0

    init(sink: @escaping (UnsafeRawBufferPointer) throws -> Void) { self.sink = sink }

    private func emit(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try sink($0) }
        bytesWritten += Int64(bytes.count)
    }

    private static func put(_ block: inout [UInt8], _ offset: Int, _ s: String, max: Int) {
        let u = Array(s.utf8.prefix(max))
        for (i, c) in u.enumerated() { block[offset + i] = c }
    }
    private static func putOctal(_ block: inout [UInt8], _ offset: Int, _ value: Int64, width: Int) {
        let s = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
        put(&block, offset, padded, max: width - 1)
    }

    private func header(name: String, mode: UInt32, size: Int64, mtime: Int64, type: UInt8, link: String = "") -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        let bytes = Array(name.utf8)
        let (prefixBytes, baseBytes): (ArraySlice<UInt8>, ArraySlice<UInt8>) = Self.split(bytes) ?? (bytes[0..<0], bytes.prefix(100))   // pax carries the real name when this does not fit
        for (i, c) in baseBytes.enumerated() { b[i] = c }
        Self.putOctal(&b, 100, Int64(mode & 0o7777), width: 8)
        Self.putOctal(&b, 108, 0, width: 8); Self.putOctal(&b, 116, 0, width: 8)
        if size < 0o77777777777 { Self.putOctal(&b, 124, size, width: 12) }
        else { b[124] = 0x80; var v = size; for i in stride(from: 11, through: 4, by: -1) { b[124 + i] = UInt8(v & 0xFF); v >>= 8 } }
        Self.putOctal(&b, 136, max(0, mtime), width: 12)
        b[156] = type
        Self.put(&b, 157, link, max: 100)
        Self.put(&b, 257, "ustar", max: 5); b[262] = 0; b[263] = 0x30; b[264] = 0x30       // "ustar\0" version "00"
        for (i, c) in prefixBytes.enumerated() { b[345 + i] = c }
        for i in 148..<156 { b[i] = 0x20 }
        let sum = b.reduce(0) { $0 + Int($1) }
        let s = String(sum, radix: 8)
        Self.put(&b, 148, String(repeating: "0", count: max(0, 6 - s.count)) + s, max: 6); b[154] = 0; b[155] = 0x20
        return b
    }

    private func paxRecord(_ key: String, _ value: String) -> [UInt8] {
        let body = " \(key)=\(value)\n"
        var len = body.utf8.count + 1
        while String(len).utf8.count + body.utf8.count != len { len = String(len).utf8.count + body.utf8.count }
        return Array("\(len)\(body)".utf8)
    }

    /// ustar name / prefix split: nil when the name cannot be stored in the two fields (more than 100 bytes without a '/' that leaves <= 155 before and <= 100 after).
    static func split(_ bytes: [UInt8]) -> (ArraySlice<UInt8>, ArraySlice<UInt8>)? {
        if bytes.count <= 100 { return (bytes[0..<0], bytes[0...]) }
        for i in stride(from: bytes.count - 1, through: 1, by: -1) where bytes[i] == UInt8(ascii: "/") {
            let rest = bytes.count - i - 1
            if i <= 155, rest > 0, rest <= 100 { return (bytes[0..<i], bytes[(i + 1)...]) }
        }
        return nil
    }

    private func needsPax(_ name: String, link: String) -> Bool {
        if name.utf8.contains(where: { $0 >= 0x80 }) || link.utf8.contains(where: { $0 >= 0x80 }) { return true }
        if link.utf8.count > 100 { return true }
        return Self.split(Array(name.utf8)) == nil
    }

    private func writePax(for name: String, link: String, size: Int64) throws {
        var records: [UInt8] = []
        records += paxRecord("path", name)
        if !link.isEmpty { records += paxRecord("linkpath", link) }
        _ = size
        try emit(header(name: "PaxHeader/entry", mode: 0o644, size: Int64(records.count), mtime: 0, type: UInt8(ascii: "x")))
        try emit(records)
        let pad = (512 - records.count % 512) % 512
        if pad > 0 { try emit([UInt8](repeating: 0, count: pad)) }
    }

    func addDirectory(_ name: String, mode: UInt32 = 0o755, mtime: Int64) throws {
        let n = name.hasSuffix("/") ? name : name + "/"
        if needsPax(n, link: "") { try writePax(for: n, link: "", size: 0) }
        try emit(header(name: n, mode: mode, size: 0, mtime: mtime, type: UInt8(ascii: "5")))
    }

    func addSymlink(_ name: String, target: String, mtime: Int64) throws {
        if needsPax(name, link: target) { try writePax(for: name, link: target, size: 0) }
        try emit(header(name: name, mode: 0o755, size: 0, mtime: mtime, type: UInt8(ascii: "2"), link: target))
    }

    /// Streams a file's bytes. `size` is the size at the time of listing: the file is cut or zero-padded to it so a file that changes while packing cannot corrupt the archive.
    func addFile(_ name: String, from url: URL, size: Int64, mode: UInt32, mtime: Int64) throws {
        if needsPax(name, link: "") { try writePax(for: name, link: "", size: size) }
        try emit(header(name: name, mode: mode, size: size, mtime: mtime, type: UInt8(ascii: "0")))
        guard let input = InputStream(url: url) else { throw ConversionError.fileUnreadable(url) }
        input.open(); defer { input.close() }
        var left = size
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while left > 0 {
            try Task.checkCancellation()
            let want = Int(min(Int64(buffer.count), left))
            let n = buffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, maxLength: want) }
            if n < 0 { throw ConversionError.fileUnreadable(url) }
            if n == 0 { try emit([UInt8](repeating: 0, count: want)); left -= Int64(want); continue }      // the file shrank
            try buffer.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            bytesWritten += Int64(n); left -= Int64(n)
        }
        let pad = Int((512 - size % 512) % 512)
        if pad > 0 { try emit([UInt8](repeating: 0, count: pad)) }
    }

    func finish() throws { try emit([UInt8](repeating: 0, count: 1024)) }
}
