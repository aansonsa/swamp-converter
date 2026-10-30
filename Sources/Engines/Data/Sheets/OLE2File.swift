import Foundation

// Minimal reader of OLE2 / Compound File Binary containers (what .xls, .doc and .ppt are wrapped in): header, FAT / DIFAT / mini-FAT chains, directory, and whole-stream
// reads. Everything is bounds-checked: a damaged file throws instead of trapping. Used by the BIFF8 spreadsheet reader.

struct OLE2File {
    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var miniStream: [UInt8] = []

    struct DirectoryEntry {
        var name: String
        var type: UInt8
        var start: UInt32
        var size: Int
    }
    private(set) var entries: [DirectoryEntry] = []

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF

    static func looksLikeOLE2(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return [UInt8]((try? h.read(upToCount: 8)) ?? Data()) == signature
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.bytes = [UInt8](data)
        guard bytes.count >= 512, Array(bytes[0..<8]) == Self.signature else { throw OLE2File.notOLE2 }
        let shift = Int(ByteCursor.u16(bytes, 0x1E)), miniShift = Int(ByteCursor.u16(bytes, 0x20))
        guard shift == 9 || shift == 12, miniShift >= 4, miniShift <= 9 else { throw OLE2File.damaged }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(ByteCursor.u32(bytes, 0x38))
        let fatCount = Int(ByteCursor.u32(bytes, 0x2C))
        let dirStart = ByteCursor.u32(bytes, 0x30)
        let miniFatStart = ByteCursor.u32(bytes, 0x3C)
        let miniFatCount = Int(ByteCursor.u32(bytes, 0x40))
        var difatNext = ByteCursor.u32(bytes, 0x44)
        let difatCount = Int(ByteCursor.u32(bytes, 0x48))
        guard fatCount >= 0, fatCount < 1 << 20, difatCount >= 0, difatCount < 1 << 20 else { throw OLE2File.damaged }

        // DIFAT: 109 entries in the header, then a chain of DIFAT sectors.
        var fatSectors: [UInt32] = []
        for i in 0..<109 where fatSectors.count < fatCount {
            let s = ByteCursor.u32(bytes, 0x4C + i * 4)
            if s != Self.freeSector { fatSectors.append(s) }
        }
        var guardCount = 0
        while difatNext != Self.endOfChain, difatNext != Self.freeSector, fatSectors.count < fatCount, guardCount <= difatCount {
            guard let off = sectorOffset(difatNext) else { throw OLE2File.damaged }
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector where fatSectors.count < fatCount {
                let s = ByteCursor.u32(bytes, off + i * 4)
                if s != Self.freeSector { fatSectors.append(s) }
            }
            difatNext = ByteCursor.u32(bytes, off + perSector * 4)
            guardCount += 1
        }
        fat.reserveCapacity(fatSectors.count * sectorSize / 4)
        for s in fatSectors {
            guard let off = sectorOffset(s) else { throw OLE2File.damaged }
            for i in 0..<(sectorSize / 4) { fat.append(ByteCursor.u32(bytes, off + i * 4)) }
        }

        // Directory.
        let dir = try chain(start: dirStart, limit: Int.max)
        var e: [DirectoryEntry] = []
        var p = 0
        while p + 128 <= dir.count {
            let nameLen = Int(ByteCursor.u16(dir, p + 0x40))
            let type = dir[p + 0x42]
            if type != 0, nameLen >= 2, nameLen <= 64 {
                var units: [UInt16] = []
                var k = 0
                while k + 2 <= nameLen - 2 { units.append(UInt16(dir[p + k]) | UInt16(dir[p + k + 1]) << 8); k += 2 }     // nameLen counts the terminating NUL
                let name = String(decoding: units, as: UTF16.self)
                let start = ByteCursor.u32(dir, p + 0x74)
                let size = Int(ByteCursor.u32(dir, p + 0x78))      // the high 32 bits only matter for 4 GB streams
                e.append(DirectoryEntry(name: name, type: type, start: start, size: size))
            } else {
                e.append(DirectoryEntry(name: "", type: 0, start: 0, size: 0))
            }
            p += 128
        }
        entries = e

        // Mini stream (the root entry's data) and mini FAT.
        if let root = entries.first, root.type == 5, root.size > 0 {
            miniStream = (try? chain(start: root.start, limit: root.size)) ?? []
        }
        if miniFatCount > 0 {
            let raw = try chain(start: miniFatStart, limit: Int.max)
            for i in 0..<(raw.count / 4) { miniFat.append(ByteCursor.u32(raw, i * 4)) }
        }
    }

    static var notOLE2: ConversionError { .message(L10n("This is not an Excel 97-2003 workbook.", "Это не книга Excel 97-2003.")) }
    static var damaged: ConversionError { .message(L10n("The workbook is damaged and cannot be read.", "Книга повреждена и не может быть прочитана.")) }

    private func sectorOffset(_ s: UInt32) -> Int? {
        if s >= 0xFFFF_FFFA { return nil }
        let off = (Int(s) + 1) * sectorSize
        return off + sectorSize <= bytes.count ? off : nil
    }

    /// Follows a FAT chain and returns the concatenated sectors (cut to `limit` bytes).
    private func chain(start: UInt32, limit: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var s = start
        var steps = 0
        while s != Self.endOfChain, s != Self.freeSector, out.count < limit {
            guard let off = sectorOffset(s), Int(s) < fat.count else { throw OLE2File.damaged }
            out.append(contentsOf: bytes[off..<(off + sectorSize)])
            s = fat[Int(s)]
            steps += 1
            if steps > fat.count + 4 { throw OLE2File.damaged }          // loop in the chain
        }
        if out.count > limit { out.removeLast(out.count - limit) }
        return out
    }

    private func miniChain(start: UInt32, size: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var s = start
        var steps = 0
        while s != Self.endOfChain, s != Self.freeSector, out.count < size {
            let off = Int(s) * miniSectorSize
            guard off + miniSectorSize <= miniStream.count else { throw OLE2File.damaged }
            out.append(contentsOf: miniStream[off..<(off + miniSectorSize)])
            s = Int(s) < miniFat.count ? miniFat[Int(s)] : Self.endOfChain
            steps += 1
            if steps > miniFat.count + 4 { throw OLE2File.damaged }
        }
        if out.count > size { out.removeLast(out.count - size) }
        return out
    }

    /// The bytes of the first stream called `name` (case-insensitive).
    func stream(named name: String) throws -> [UInt8]? {
        guard let e = entries.first(where: { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        if e.size < miniCutoff { return try miniChain(start: e.start, size: e.size) }
        return try chain(start: e.start, limit: e.size)
    }
}
