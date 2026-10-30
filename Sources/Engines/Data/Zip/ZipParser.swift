import Foundation

// Reads the central directory of a zip file (classic and zip64, junk before the archive, comments) and decodes entry names.
// Names without the UTF-8 flag are decoded per ARCHIVE (all non-ASCII names are scored together) as CP866 / CP1251 / CP437, which is what Windows-Russian tools write
// and what bsdtar, ditto and unzip turn into mojibake (spec/backends.md fact 7).

/// Name decoding choice for entries whose UTF-8 flag is not set.
enum ZipNameEncoding: String, CaseIterable, Sendable {
    case auto, utf8, cp866, cp1251, cp437

    init(key: String) {
        switch key.lowercased() {
        case "utf-8", "utf8": self = .utf8
        case "cp866", "866", "dos": self = .cp866
        case "cp1251", "windows-1251", "1251": self = .cp1251
        case "cp437", "437": self = .cp437
        default: self = .auto
        }
    }
    var dataEncoding: DataEncoding? {
        switch self { case .auto: return nil; case .utf8: return .utf8; case .cp866: return .cp866; case .cp1251: return .windows1251; case .cp437: return .cp437 }
    }
}

enum ZipNames {
    /// The code page to use for the non-flagged names of an archive.
    static func decideEncoding(_ raws: [Data]) -> DataEncoding {
        let interesting = raws.filter { $0.contains(where: { $0 >= 0x80 }) }
        if interesting.isEmpty { return .utf8 }
        if interesting.allSatisfy({ TextEncodingKit.isValidUTF8([UInt8]($0)) }) { return .utf8 }
        var sample: [UInt8] = []
        for r in interesting.prefix(400) { sample.append(contentsOf: r); sample.append(0x2F) }
        return TextEncodingKit.detectSingleByte(sample, candidates: [.cp866, .cp437, .windows1251])
    }

    static func decode(_ raw: Data, flaggedUTF8: Bool, unicodePath: String?, mode: ZipNameEncoding, guess: DataEncoding) -> String {
        if flaggedUTF8 { return String(decoding: raw, as: UTF8.self) }
        if let u = unicodePath, mode == .auto { return u }
        if !raw.contains(where: { $0 >= 0x80 }) { return String(decoding: raw, as: UTF8.self) }
        let enc = mode.dataEncoding ?? guess
        if enc == .utf8 { return String(decoding: raw, as: UTF8.self) }
        return TextEncodingKit.decodeSingleByte(raw, enc)
    }
}

struct ZipRawEntry {
    var rawName: Data
    var flags: UInt16
    var method: UInt16
    var dosTime: UInt16
    var dosDate: UInt16
    var crc: UInt32
    var compressedSize: Int64
    var uncompressedSize: Int64
    var localOffset: Int64
    var externalAttrs: UInt32
    var madeByHost: UInt8
    var unicodePath: String?
    var unixTime: Date?
}

enum ZipParser {
    static let maxDirectoryBytes: Int64 = 512 * 1024 * 1024

    static func parse(_ file: RandomAccessFile, encoding: ZipNameEncoding = .auto) throws -> [ZipEntry] {
        let raws = try parseRaw(file)
        let flagged = raws.map { $0.flags & 0x0800 != 0 }
        let unflaggedNames = zip(raws, flagged).filter { !$0.1 }.map(\.0.rawName)
        let guess = encoding == .auto ? ZipNames.decideEncoding(unflaggedNames) : (encoding.dataEncoding ?? .utf8)
        var out: [ZipEntry] = []
        out.reserveCapacity(raws.count)
        for (i, r) in raws.enumerated() {
            let name = ZipNames.decode(r.rawName, flaggedUTF8: flagged[i], unicodePath: r.unicodePath, mode: encoding, guess: guess)
            let unixMode: UInt32 = r.madeByHost == 3 ? r.externalAttrs >> 16 : 0
            let dosDir = r.madeByHost != 3 && r.externalAttrs & 0x10 != 0 && r.uncompressedSize == 0
            let isDir = name.hasSuffix("/") || name.hasSuffix("\\") || dosDir || (unixMode & 0o170000) == 0o040000
            let isLink = (unixMode & 0o170000) == 0o120000
            out.append(ZipEntry(name: name, rawName: r.rawName, isDirectory: isDir, compressedSize: r.compressedSize, uncompressedSize: r.uncompressedSize,
                                modified: r.unixTime ?? DOSDate.decode(time: r.dosTime, date: r.dosDate), isEncrypted: r.flags & 0x0001 != 0, crc32: r.crc,
                                method: r.method, flags: r.flags, localHeaderOffset: r.localOffset, unixMode: unixMode, isSymlink: isLink))
        }
        return out
    }

    // MARK: Central directory

    static func parseRaw(_ file: RandomAccessFile) throws -> [ZipRawEntry] {
        guard file.size >= 22 else { throw ZipError.notAZip }
        let tailCount = Int(min(file.size, 65_557))
        let tailStart = file.size - Int64(tailCount)
        let tail = [UInt8](try file.read(at: tailStart, count: tailCount))
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                let commentLen = Int(ByteCursor.u16(tail, i + 20))
                if i + 22 + commentLen <= tail.count { eocd = i; break }
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let eocdAbs = tailStart + Int64(eocd)
        var cur = ByteCursor(tail, at: eocd + 4)
        _ = try cur.u16(); _ = try cur.u16(); _ = try cur.u16()
        var total = Int64(try cur.u16())
        var cdSize = Int64(try cur.u32())
        var cdOffset = Int64(try cur.u32())
        var structEnd = eocdAbs                     // where the central directory (or the zip64 end record) ends
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // zip64: the locator sits right before the EOCD
            if eocdAbs >= 20 {
                let loc = [UInt8](try file.read(at: eocdAbs - 20, count: 20))
                if loc.count == 20, ByteCursor.u32(loc, 0) == 0x0706_4B50 {
                    var lc = ByteCursor(loc, at: 8)
                    let eocd64 = Int64(bitPattern: try lc.u64())
                    let rec = [UInt8](try file.read(at: eocd64, count: 56))
                    guard rec.count == 56, ByteCursor.u32(rec, 0) == 0x0606_4B50 else { throw ZipError.damaged("zip64 end record") }
                    var rc = ByteCursor(rec, at: 24)
                    _ = try rc.u64()
                    total = Int64(bitPattern: try rc.u64())
                    cdSize = Int64(bitPattern: try rc.u64())
                    cdOffset = Int64(bitPattern: try rc.u64())
                    structEnd = eocd64
                }
            }
        }
        guard cdSize >= 0, cdSize <= maxDirectoryBytes, cdOffset >= 0, total >= 0 else { throw ZipError.damaged("directory size") }
        // Self-extracting archives and zips with junk in front: offsets are relative to the start of the zip data.
        var base: Int64 = 0
        var cdStart = cdOffset
        func hasSignature(at pos: Int64) -> Bool {
            guard pos >= 0, let d = try? file.read(at: pos, count: 4), d.count == 4 else { return false }
            return d[d.startIndex] == 0x50 && d[d.startIndex + 1] == 0x4B && d[d.startIndex + 2] == 0x01 && d[d.startIndex + 3] == 0x02
        }
        if cdSize > 0 && !hasSignature(at: cdStart) {
            let alt = structEnd - cdSize
            if hasSignature(at: alt) { base = alt - cdOffset; cdStart = alt } else { throw ZipError.damaged("central directory not found") }
        }
        let cd = [UInt8](try file.read(at: cdStart, count: Int(cdSize)))
        guard cd.count == Int(cdSize) else { throw ZipError.truncated }
        var entries: [ZipRawEntry] = []
        entries.reserveCapacity(Int(min(total, 1 << 20)))
        var c = ByteCursor(cd)
        while c.remaining >= 46 {
            guard try c.u32() == 0x0201_4B50 else { throw ZipError.damaged("central header") }
            let madeBy = try c.u16()
            _ = try c.u16()
            let flags = try c.u16(), method = try c.u16(), time = try c.u16(), date = try c.u16()
            let crc = try c.u32()
            var csize = Int64(try c.u32()), usize = Int64(try c.u32())
            let nameLen = Int(try c.u16()), extraLen = Int(try c.u16()), commentLen = Int(try c.u16())
            _ = try c.u16(); _ = try c.u16()
            let external = try c.u32()
            var offset = Int64(try c.u32())
            let name = try c.data(nameLen)
            let extra = [UInt8](try c.data(extraLen))
            try c.skip(commentLen)
            var unicodePath: String?
            var unixTime: Date?
            var x = ByteCursor(extra)
            while x.remaining >= 4 {
                let id = try x.u16(), size = Int(try x.u16())
                guard size <= x.remaining else { break }
                let next = x.pos + size
                switch id {
                case 0x0001:   // zip64: only the fields that were 0xFFFFFFFF, in this order
                    if usize == 0xFFFF_FFFF, x.pos + 8 <= next { usize = Int64(bitPattern: try x.u64()) }
                    if csize == 0xFFFF_FFFF, x.pos + 8 <= next { csize = Int64(bitPattern: try x.u64()) }
                    if offset == 0xFFFF_FFFF, x.pos + 8 <= next { offset = Int64(bitPattern: try x.u64()) }
                case 0x7075:   // Info-ZIP Unicode path
                    if size > 5, extra[x.pos] == 1 {
                        let storedCRC = ByteCursor.u32(extra, x.pos + 1)
                        if storedCRC == Checksum.crc32(name) { unicodePath = String(decoding: extra[(x.pos + 5)..<next], as: UTF8.self) }
                    }
                case 0x5455:   // extended timestamp: flags, then mtime
                    if size >= 5, extra[x.pos] & 1 != 0 { unixTime = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: ByteCursor.u32(extra, x.pos + 1)))) }
                default: break
                }
                x.pos = next
            }
            // Sizes and offsets come from the file: a lie (negative, or bigger than any real file) is a damaged archive, never an arithmetic overflow later.
            guard ArchiveMath.sane(csize), ArchiveMath.sane(usize), offset >= 0, offset <= file.size else { throw ZipError.damaged("entry sizes") }
            entries.append(ZipRawEntry(rawName: name, flags: flags, method: method, dosTime: time, dosDate: date, crc: crc, compressedSize: csize, uncompressedSize: usize,
                                       localOffset: offset + base, externalAttrs: external, madeByHost: UInt8(madeBy >> 8), unicodePath: unicodePath, unixTime: unixTime))
            if entries.count > 5_000_000 { throw ZipError.damaged("too many entries") }
        }
        return entries
    }
}
