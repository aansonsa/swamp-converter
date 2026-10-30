import Foundation

// Source probe of the sheet family: facts `table.kind`, `table.rows`, `table.columns`, `table.sheets`, `table.delimiter`, `table.estimated`, `text.encoding` and chips
// ("3 sheets", "UTF-8", "delimiter ;"). Cheap by construction: CSV looks at the first rows only on big files (rows are then ESTIMATED from the average row size and the
// fact says so), XLSX reads the sheet list and the declared dimension, the other formats are parsed only when small.

struct SheetSourceProbe: SourceProbe {
    static let fullParseLimit: Int64 = 8 * 1024 * 1024

    func probe(_ item: FileItem) async -> SourceInfo {
        var info = SourceInfo(url: item.url, kind: item.kind)
        guard let kind = SheetFileKind.detect(item.url) else { return info }
        let size = item.size ?? ((try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        switch kind {
        case .csv, .tsv: Self.probeDelimited(item.url, kind: kind, size: size, into: &info)
        case .xlsx: Self.probeXLSX(item.url, into: &info)
        case .ods, .xls:
            if size <= Self.fullParseLimit, let wb = try? SheetReader.read(item.url, options: SheetReadOptions()) { Self.fill(&info, workbook: wb, kind: kind) }
            else { info.facts["table.kind"] = .string(kind == .ods ? "ods" : "xls") }
        }
        return info
    }

    // MARK: Delimited text

    private static func probeDelimited(_ url: URL, kind: SheetFileKind, size: Int64, into info: inout SourceInfo) {
        var ro = CSVReadOptions()
        ro.preferTab = kind == .tsv
        var rows = 0, columns = 0
        let small = size <= fullParseLimit
        let sampleRows = 20_000
        var meta: CSVFileInfo?
        do {
            meta = try CSVFile.stream(url, options: ro) { row in
                rows += 1
                columns = max(columns, row.count)
                if !small, rows >= sampleRows { return false }
                return true
            }
        } catch { return }
        guard let meta else { return }
        var estimated = false
        if !small, rows >= sampleRows, let est = estimateRows(url, size: size) {
            rows = est
            estimated = true
        }
        info.facts["table.kind"] = .string(kind == .tsv ? "tsv" : "csv")
        info.facts["table.rows"] = .int(rows)
        info.facts["table.columns"] = .int(columns)
        info.facts["table.sheets"] = .int(1)
        info.facts["table.estimated"] = .bool(estimated)
        info.facts["table.delimiter"] = .string(CSVSniffer.name(of: meta.delimiter))
        info.facts["text.encoding"] = .string(meta.encoding.displayName)
        info.chips.append(SourceChip(symbol: "text.alignleft", text: meta.encoding.displayName + (meta.hadBOM ? " BOM" : "")))
        info.chips.append(SourceChip(symbol: "tablecells", text: SheetSchemas.delimiterLabel(CSVSniffer.name(of: meta.delimiter))))
        info.chips.append(SourceChip(symbol: "list.number", text: (estimated ? "~" : "") + rowsText(rows)))
    }

    /// Rows of a big text file from the average line length of its first and last megabyte (quoted line breaks make this approximate, hence "~" in the chip).
    private static func estimateRows(_ url: URL, size: Int64) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func lines(in data: Data) -> Int { data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }
        let chunk = 1 << 20
        guard let head = try? h.read(upToCount: chunk), (try? h.seek(toOffset: UInt64(max(0, size - Int64(chunk))))) != nil, let tail = try? h.read(upToCount: chunk) else { return nil }
        let hl = lines(in: head), tl = lines(in: tail)
        guard hl > 0, tl > 0 else { return nil }
        let average = (Double(head.count) / Double(hl) + Double(tail.count) / Double(tl)) / 2
        return Int(Double(size) / average)
    }

    // MARK: Workbooks

    private static func probeXLSX(_ url: URL, into info: inout SourceInfo) {
        guard let names = XLSXProbe.sheetNames(url) else { return }
        info.facts["table.kind"] = .string("xlsx")
        info.facts["table.sheets"] = .int(names.count)
        if let first = XLSXProbe.firstSheetDimension(url) {
            info.facts["table.rows"] = .int(first.rows)
            info.facts["table.columns"] = .int(first.columns)
            info.chips.append(SourceChip(symbol: "list.number", text: rowsText(first.rows)))
        }
        if names.count > 1 { info.chips.insert(SourceChip(symbol: "square.stack", text: sheetsText(names.count)), at: 0) }
        for (i, n) in names.prefix(20).enumerated() { info.facts["table.sheet.\(i).name"] = .string(n) }
    }

    private static func fill(_ info: inout SourceInfo, workbook wb: SheetWorkbook, kind: SheetFileKind) {
        info.facts["table.kind"] = .string(kind == .ods ? "ods" : "xls")
        info.facts["table.sheets"] = .int(wb.sheets.count)
        if let first = wb.sheets.first {
            info.facts["table.rows"] = .int(first.rows.count)
            info.facts["table.columns"] = .int(first.columnCount)
            info.chips.append(SourceChip(symbol: "list.number", text: rowsText(first.rows.count)))
        }
        if wb.sheets.count > 1 { info.chips.insert(SourceChip(symbol: "square.stack", text: sheetsText(wb.sheets.count)), at: 0) }
        for (i, t) in wb.sheets.prefix(20).enumerated() { info.facts["table.sheet.\(i).name"] = .string(t.name) }
    }

    static func rowsText(_ n: Int) -> String {
        Loc.plural(n, enOne: "\(n) row", enOther: "\(n) rows", ruOne: "\(n) строка", ruFew: "\(n) строки", ruMany: "\(n) строк")
    }
    static func sheetsText(_ n: Int) -> String {
        Loc.plural(n, enOne: "\(n) sheet", enOther: "\(n) sheets", ruOne: "\(n) лист", ruFew: "\(n) листа", ruMany: "\(n) листов")
    }
}

/// Reads only what the probe needs from an XLSX: the sheet names of workbook.xml and the declared `<dimension>` of the first sheet (first 8 KB of its XML).
enum XLSXProbe {
    static func sheetNames(_ url: URL) -> [String]? {
        guard let data = try? ZipKit.read(url, entry: "xl/workbook.xml", limit: 4_000_000) else { return nil }
        final class D: NSObject, XMLParserDelegate {
            var names: [String] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                if name == "sheet" { names.append(a["name"] ?? "Sheet") }
            }
        }
        let d = D()
        let p = XMLParser(data: data); p.shouldResolveExternalEntities = false; p.delegate = d; p.parse()
        return d.names
    }

    static func firstSheetDimension(_ url: URL) -> (rows: Int, columns: Int)? {
        guard let file = try? RandomAccessFile(url: url), let entries = try? ZipParser.parse(file),
              let entry = ZipKit.find("xl/worksheets/sheet1.xml", in: entries) ?? entries.first(where: { $0.name.hasPrefix("xl/worksheets/sheet") && $0.name.hasSuffix(".xml") }) else { return nil }
        var head = Data()
        struct Stop: Error {}
        do { try ZipEntryStream.stream(file, entry: entry) { chunk in head.append(contentsOf: chunk); if head.count > 8192 { throw Stop() } } } catch is Stop {} catch { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let r = text.range(of: "<dimension ref=\""), let end = text[r.upperBound...].firstIndex(of: "\"") else { return nil }
        let ref = String(text[r.upperBound..<end])
        let parts = ref.split(separator: ":").map(String.init)
        guard let last = parts.last, let lastCell = SheetValues.cellReference(last) else { return nil }
        let firstCell: (col: Int, row: Int) = parts.count > 1 ? (SheetValues.cellReference(parts[0]) ?? (col: 0, row: 0)) : (col: 0, row: 0)
        return (lastCell.row - firstCell.row + 1, lastCell.col - firstCell.col + 1)
    }
}
