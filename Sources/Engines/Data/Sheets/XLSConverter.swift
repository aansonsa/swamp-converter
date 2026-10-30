import Foundation

// Excel 97-2003 (.xls, BIFF8) reader. Own code: OLE2 container, shared string table with CONTINUE records, LABELSST / LABEL / NUMBER / RK / MULRK / BOOLERR / FORMULA
// (cached results) cells, number formats and date detection through the same formatter as the XLSX reader. BIFF5 files, password-protected workbooks and damaged files
// make the native reader give up; then LibreOffice converts the file to XLSX when it is installed (SheetOffice), else the user gets a calm message.

enum XLSConverter {
    static func read(_ url: URL, options: SheetReadOptions) throws -> SheetWorkbook {
        do {
            return try BIFF8Reader.read(url, options: options)
        } catch let native as ConversionError {
            if let converted = SheetOffice.convertSync(url, to: "xlsx") {
                defer { AppPaths.removeTemp(converted.deletingLastPathComponent().deletingLastPathComponent()) }
                return try XLSXReader.read(converted, options: options)
            }
            throw native
        }
    }
}

enum BIFF8Reader {
    static func read(_ url: URL, options: SheetReadOptions) throws -> SheetWorkbook {
        guard OLE2File.looksLikeOLE2(url) else { throw OLE2File.notOLE2 }
        let ole = try OLE2File(url: url)
        guard let stream = try ole.stream(named: "Workbook") else {
            throw ConversionError.unsupported(L10n("This workbook is older than Excel 97 and cannot be read natively.", "Эта книга старше Excel 97 и не читается встроенным модулем."))
        }
        var parser = BIFFParser(stream, options: options)
        return try parser.parse()
    }
}

/// Reads fields across a record and its CONTINUE records (strings may be split between them).
private struct BIFFChunks {
    let b: [UInt8]
    var chunks: [Range<Int>]
    var ci = 0
    var pos: Int

    init(_ b: [UInt8], _ chunks: [Range<Int>]) { self.b = b; self.chunks = chunks; self.pos = chunks.first?.lowerBound ?? 0 }

    var availableInChunk: Int { ci < chunks.count ? chunks[ci].upperBound - pos : 0 }
    var atEnd: Bool { ci >= chunks.count || (availableInChunk <= 0 && ci == chunks.count - 1) }

    mutating func nextChunk() -> Bool {
        guard ci + 1 < chunks.count else { return false }
        ci += 1; pos = chunks[ci].lowerBound
        return true
    }
    mutating func u8() -> UInt8? {
        if availableInChunk <= 0, !nextChunk() { return nil }
        defer { pos += 1 }
        return b[pos]
    }
    mutating func u16() -> UInt16? {
        guard let lo = u8(), let hi = u8() else { return nil }
        return UInt16(lo) | UInt16(hi) << 8
    }
    mutating func u32() -> UInt32? {
        guard let lo = u16(), let hi = u16() else { return nil }
        return UInt32(lo) | UInt32(hi) << 16
    }
    mutating func skip(_ n: Int) {
        var left = n
        while left > 0 {
            if availableInChunk <= 0, !nextChunk() { return }
            let take = min(left, availableInChunk)
            pos += take; left -= take
        }
    }

    /// An Excel unicode string: `lengthBytes` = 1 (sheet names) or 2 (everything else).
    mutating func string(lengthBytes: Int) -> String? {
        guard let cch = lengthBytes == 1 ? u8().map(Int.init) : u16().map(Int.init), let flags = u8() else { return nil }
        let rich = flags & 0x08 != 0 ? Int(u16() ?? 0) : 0
        let ext = flags & 0x04 != 0 ? Int(u32() ?? 0) : 0
        var wide = flags & 0x01 != 0
        var units: [UInt16] = []
        units.reserveCapacity(cch)
        var remaining = cch
        while remaining > 0 {
            if availableInChunk <= 0 {
                guard nextChunk(), let f = u8() else { break }
                wide = f & 0x01 != 0                      // every CONTINUE chunk restates the character width
                continue
            }
            let width = wide ? 2 : 1
            let n = min(remaining, availableInChunk / width)
            if n == 0 { _ = u8(); continue }
            for _ in 0..<n {
                if wide { units.append(UInt16(b[pos]) | UInt16(b[pos + 1]) << 8); pos += 2 } else { units.append(UInt16(b[pos])); pos += 1 }
            }
            remaining -= n
        }
        skip(rich * 4 + ext)
        return String(decoding: units, as: UTF16.self)
    }
}

private struct BIFFParser {
    let b: [UInt8]
    let options: SheetReadOptions
    var sst: [String] = []
    var xfFormat: [Int] = []
    var formats: [Int: String] = [:]
    var date1904 = false
    var sheets: [(name: String, offset: Int, hidden: Bool, isWorksheet: Bool)] = []

    init(_ b: [UInt8], options: SheetReadOptions) { self.b = b; self.options = options }

    /// Header of the record at `p`: (id, data range, position of the next record).
    private func record(at p: Int) -> (id: UInt16, data: Range<Int>, next: Int)? {
        guard p + 4 <= b.count else { return nil }
        let id = ByteCursor.u16(b, p), len = Int(ByteCursor.u16(b, p + 2))
        guard p + 4 + len <= b.count else { return nil }
        return (id, (p + 4)..<(p + 4 + len), p + 4 + len)
    }

    /// The record's data plus the data of the CONTINUE records that follow it.
    private func chunks(of r: (id: UInt16, data: Range<Int>, next: Int)) -> (BIFFChunks, next: Int) {
        var list = [r.data]
        var next = r.next
        while let c = record(at: next), c.id == 0x003C { list.append(c.data); next = c.next }
        return (BIFFChunks(b, list), next)
    }

    mutating func parse() throws -> SheetWorkbook {
        guard let first = record(at: 0), first.id == 0x0809 else { throw OLE2File.damaged }
        let version = ByteCursor.u16(b, first.data.lowerBound)
        guard version == 0x0600 else {
            throw ConversionError.unsupported(L10n("This workbook uses the Excel 5 format, which cannot be read natively.", "Эта книга в формате Excel 5, встроенный модуль её не читает."))
        }
        // Workbook globals.
        var p = 0
        var depth = 0
        while let r = record(at: p) {
            var next = r.next
            switch r.id {
            case 0x0809: depth += 1
            case 0x000A: depth -= 1
            case 0x002F: throw ConversionError.encryptedArchive
            case 0x0022: date1904 = ByteCursor.u16(b, r.data.lowerBound) == 1
            case 0x041E:                                                      // FORMAT
                var c = chunks(of: r); next = c.next
                if let idx = c.0.u16(), let s = c.0.string(lengthBytes: 2) { formats[Int(idx)] = s }
            case 0x00E0:                                                      // XF
                xfFormat.append(Int(ByteCursor.u16(b, r.data.lowerBound + 2)))
            case 0x00FC:                                                      // SST
                var c = chunks(of: r); next = c.next
                _ = c.0.u32()
                let unique = Int(c.0.u32() ?? 0)
                sst.reserveCapacity(min(unique, 1 << 20))
                while sst.count < unique, let s = c.0.string(lengthBytes: 2) { sst.append(s) }
            case 0x0085:                                                      // BOUNDSHEET
                var c = chunks(of: r); next = c.next
                let offset = Int(c.0.u32() ?? 0)
                let visibility = c.0.u8() ?? 0
                let type = c.0.u8() ?? 0
                let name = c.0.string(lengthBytes: 1) ?? "Sheet\(sheets.count + 1)"
                sheets.append((name, offset, visibility != 0, type == 0))
            default: break
            }
            p = next
            if depth <= 0 && r.id == 0x000A { break }
        }
        var tables: [SheetTable] = []
        let worksheets = sheets.filter(\.isWorksheet)
        let wanted = options.firstSheetOnly ? (worksheets.first(where: { !$0.hidden }).map { [$0] } ?? Array(worksheets.prefix(1))) : worksheets
        for s in wanted {
            try Task.checkCancellation()
            var rows = try parseSheet(at: s.offset)
            while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
            let width = rows.map(\.count).max() ?? 0
            for i in rows.indices where rows[i].count < width { rows[i] += [String](repeating: "", count: width - rows[i].count) }
            tables.append(SheetTable(name: s.name, rows: rows, hidden: s.hidden))
        }
        return SheetWorkbook(sheets: tables, detectedEncoding: nil, detectedDelimiter: nil)
    }

    // MARK: Worksheet

    private func code(forXF xf: Int) -> String? {
        guard xf >= 0, xf < xfFormat.count else { return nil }
        let id = xfFormat[xf]
        if id == 0 { return nil }
        return formats[id] ?? XLSXNumberFormat.builtinCodes[id]
    }

    private func number(_ v: Double, xf: Int) -> String {
        guard options.formatted else { return XLSXNumberFormat.general(v) }
        return XLSXNumberFormat.display(v, code: code(forXF: xf), date1904: date1904)
    }

    private static func rk(_ raw: UInt32) -> Double {
        var v: Double
        if raw & 0x02 != 0 { v = Double(Int32(bitPattern: raw) >> 2) }
        else { v = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32) }
        if raw & 0x01 != 0 { v /= 100 }
        return v
    }

    private static func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "#NULL!"
        case 0x07: return "#DIV/0!"
        case 0x0F: return "#VALUE!"
        case 0x17: return "#REF!"
        case 0x1D: return "#NAME?"
        case 0x24: return "#NUM!"
        case 0x2A: return "#N/A"
        default: return "#ERR"
        }
    }

    private func parseSheet(at offset: Int) throws -> [[String]] {
        guard let bof = record(at: offset), bof.id == 0x0809 else { throw OLE2File.damaged }
        var rows: [[String]] = []
        func put(_ row: Int, _ col: Int, _ value: String) {
            guard row < 65_536, col < 256 else { return }
            while rows.count <= row { rows.append([]) }
            if rows[row].count <= col { rows[row] += [String](repeating: "", count: col + 1 - rows[row].count) }
            rows[row][col] = value
        }
        var depth = 0
        var p = offset
        var pendingFormula: (row: Int, col: Int)?
        var count = 0
        while let r = record(at: p) {
            var next = r.next
            let d = r.data.lowerBound
            switch r.id {
            case 0x0809: depth += 1
            case 0x000A:
                depth -= 1
                if depth <= 0 { return rows }
            case 0x00FD where depth == 1:                                    // LABELSST
                let idx = Int(ByteCursor.u32(b, d + 6))
                if idx < sst.count { put(Int(ByteCursor.u16(b, d)), Int(ByteCursor.u16(b, d + 2)), sst[idx]) }
            case 0x0204 where depth == 1:                                    // LABEL
                var c = chunks(of: r); next = c.next
                if let row = c.0.u16(), let col = c.0.u16(), c.0.u16() != nil, let s = c.0.string(lengthBytes: 2) { put(Int(row), Int(col), s) }
            case 0x0203 where depth == 1:                                    // NUMBER
                let v = Double(bitPattern: UInt64(ByteCursor.u32(b, d + 6)) | UInt64(ByteCursor.u32(b, d + 10)) << 32)
                put(Int(ByteCursor.u16(b, d)), Int(ByteCursor.u16(b, d + 2)), number(v, xf: Int(ByteCursor.u16(b, d + 4))))
            case 0x027E where depth == 1:                                    // RK
                put(Int(ByteCursor.u16(b, d)), Int(ByteCursor.u16(b, d + 2)), number(Self.rk(ByteCursor.u32(b, d + 6)), xf: Int(ByteCursor.u16(b, d + 4))))
            case 0x00BD where depth == 1:                                    // MULRK
                let row = Int(ByteCursor.u16(b, d)), first = Int(ByteCursor.u16(b, d + 2))
                var q = d + 4
                var col = first
                while q + 6 <= r.data.upperBound - 2 {
                    put(row, col, number(Self.rk(ByteCursor.u32(b, q + 2)), xf: Int(ByteCursor.u16(b, q))))
                    col += 1; q += 6
                }
            case 0x0205 where depth == 1:                                    // BOOLERR
                let v = b[d + 6], isError = b[d + 7] != 0
                put(Int(ByteCursor.u16(b, d)), Int(ByteCursor.u16(b, d + 2)), isError ? Self.errorText(v) : (v != 0 ? "TRUE" : "FALSE"))
            case 0x0006 where depth == 1:                                    // FORMULA: the cached result
                let row = Int(ByteCursor.u16(b, d)), col = Int(ByteCursor.u16(b, d + 2)), xf = Int(ByteCursor.u16(b, d + 4))
                if b[d + 12] == 0xFF && b[d + 13] == 0xFF {
                    switch b[d + 6] {
                    case 0: pendingFormula = (row, col)                       // the text follows in a STRING record
                    case 1: put(row, col, b[d + 8] != 0 ? "TRUE" : "FALSE")
                    case 2: put(row, col, Self.errorText(b[d + 8]))
                    default: break
                    }
                } else {
                    let v = Double(bitPattern: UInt64(ByteCursor.u32(b, d + 6)) | UInt64(ByteCursor.u32(b, d + 10)) << 32)
                    put(row, col, number(v, xf: xf))
                }
            case 0x0207 where depth == 1:                                    // STRING (result of the previous formula)
                var c = chunks(of: r); next = c.next
                if let cell = pendingFormula, let s = c.0.string(lengthBytes: 2) { put(cell.row, cell.col, s) }
                pendingFormula = nil
            default: break
            }
            count += 1
            if count % 4096 == 0 { try Task.checkCancellation() }
            if let m = options.maxRows, rows.count > m + 64 { return rows }
            p = next
        }
        return rows
    }
}
