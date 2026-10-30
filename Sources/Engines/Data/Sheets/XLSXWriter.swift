import Foundation

// XLSX writer (spec/backends.md 3.6.2): shared strings, styles (default, bold header, text, date, date-time), sheet XML streamed to temp files (big tables never become
// one giant string), column widths from the first 200 rows, optional frozen header row and auto filter. Typing rule: see SheetValues.numberLiteral.

/// Buffered UTF-8 text file for generated XML.
final class XMLTextFile {
    let url: URL
    private let handle: FileHandle
    private var buffer = ""

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        handle = h
        buffer.reserveCapacity(300_000)
    }

    func append(_ s: String) throws {
        buffer += s
        if buffer.utf8.count > 256 * 1024 { try flush() }
    }

    func flush() throws {
        if buffer.isEmpty { return }
        do { try handle.write(contentsOf: Data(buffer.utf8)) } catch { throw FSErrors.map(ENOSPC, path: url.path) }
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws { try flush(); try handle.close() }
}

enum XLSXWriter {
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCellCharacters = 32_767

    private final class SharedStrings {
        var index: [String: Int] = [:]
        var list: [String] = []
        var references = 0
        func id(_ s: String) -> Int {
            references += 1
            if let i = index[s] { return i }
            let i = list.count
            list.append(s); index[s] = i
            return i
        }
    }

    @discardableResult
    static func write(_ workbook: SheetWorkbook, to url: URL, options: XLSXWriteOptions) throws -> SheetWriteReport {
        var report = SheetWriteReport()
        var sheets = workbook.sheets
        if sheets.isEmpty { sheets = [SheetTable(name: "Sheet1", rows: [])] }
        let names = SheetValues.sanitizedSheetNames(sheets.map(\.name))
        let temp = AppPaths.makeTempDirectory(purpose: "xlsx")
        defer { AppPaths.removeTemp(temp) }
        let sst = SharedStrings()
        var sheetFiles: [URL] = []
        for (i, table) in sheets.enumerated() {
            try Task.checkCancellation()
            guard table.rows.count <= maxRows else {
                throw ConversionError.message(L10n("XLSX holds up to 1 048 576 rows per sheet; \(names[i]) has \(table.rows.count). Use CSV, or split the table.",
                                                   "В листе XLSX не больше 1 048 576 строк, а в «\(names[i])» их \(table.rows.count). Используйте CSV или разделите таблицу."))
            }
            guard table.columnCount <= maxColumns else {
                throw ConversionError.message(L10n("XLSX holds up to 16 384 columns; \(names[i]) has \(table.columnCount).", "В XLSX не больше 16 384 столбцов, а в «\(names[i])» их \(table.columnCount)."))
            }
            let f = temp.appendingPathComponent("sheet\(i + 1).xml")
            try writeSheet(table, to: f, sst: sst, options: options, selected: i == 0, report: &report)
            sheetFiles.append(f)
            report.rows += table.rows.count
        }
        let zip = try ZipWriter(url: url, level: 6)
        try zip.add(data: Data(contentTypes(sheetCount: sheets.count).utf8), as: "[Content_Types].xml")
        try zip.add(data: Data(rootRels.utf8), as: "_rels/.rels")
        try zip.add(data: Data(workbookXML(names: names, tables: sheets, options: options).utf8), as: "xl/workbook.xml")
        try zip.add(data: Data(workbookRels(sheetCount: sheets.count).utf8), as: "xl/_rels/workbook.xml.rels")
        try zip.add(data: Data(stylesXML.utf8), as: "xl/styles.xml")
        try zip.add(data: Data(sharedStringsXML(sst).utf8), as: "xl/sharedStrings.xml")
        for (i, f) in sheetFiles.enumerated() { try zip.add(file: f, as: "xl/worksheets/sheet\(i + 1).xml") }
        try zip.finish()
        return report
    }

    // MARK: Sheet

    private static func writeSheet(_ table: SheetTable, to file: URL, sst: SharedStrings, options: XLSXWriteOptions, selected: Bool, report: inout SheetWriteReport) throws {
        let out = try XLSXTextHolder(file)
        defer { try? out.file.close() }
        let cols = max(table.columnCount, 1)
        let rowsCount = max(table.rows.count, 1)
        let dimension = "A1:\(SheetValues.columnLetters(cols - 1))\(rowsCount)"
        try out.file.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">")
        try out.file.append("<dimension ref=\"\(dimension)\"/>")
        let freeze = options.freezeHeader && table.rows.count > 1
        try out.file.append("<sheetViews><sheetView workbookViewId=\"0\"\(selected ? " tabSelected=\"1\"" : "")>")
        if freeze { try out.file.append("<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>") }
        try out.file.append("</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>")
        if options.autoFit && table.columnCount > 0 {
            var widths = [Double](repeating: 0, count: cols)
            for row in table.rows.prefix(200) { for (c, v) in row.enumerated() where c < cols { widths[c] = max(widths[c], SheetValues.displayWidth(v)) } }
            try out.file.append("<cols>")
            for c in 0..<cols {
                let w = min(60, max(8, widths[c] * 1.1 + 2))
                try out.file.append("<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.2f", w))\" customWidth=\"1\"/>")
            }
            try out.file.append("</cols>")
        }
        try out.file.append("<sheetData>")
        for (r, row) in table.rows.enumerated() {
            if r % 2048 == 0 { try Task.checkCancellation() }
            if row.isEmpty { continue }
            let isHeader = options.boldHeader && r == 0
            var xml = "<row r=\"\(r + 1)\">"
            for (c, raw) in row.enumerated() {
                if raw.isEmpty { continue }
                var text = raw
                if text.count > maxCellCharacters { text = String(text.prefix(maxCellCharacters)); report.truncatedCells += 1 }
                let ref = SheetValues.columnLetters(c) + String(r + 1)
                if options.allText {
                    xml += "<c r=\"\(ref)\" s=\"2\" t=\"s\"><v>\(sst.id(text))</v></c>"
                } else if let n = SheetValues.numberLiteral(text, commaDecimal: options.commaDecimal) {
                    xml += "<c r=\"\(ref)\"\(isHeader ? " s=\"1\"" : "")><v>\(n)</v></c>"
                } else if options.dates, let d = SheetValues.serial(fromISO: text) {
                    xml += "<c r=\"\(ref)\" s=\"\(d.hasTime ? 4 : 3)\"><v>\(formatSerial(d.value))</v></c>"
                } else {
                    let style = isHeader ? 1 : (looksNumeric(text) ? 2 : 0)
                    xml += "<c r=\"\(ref)\"\(style == 0 ? "" : " s=\"\(style)\"") t=\"s\"><v>\(sst.id(text))</v></c>"
                }
            }
            xml += "</row>"
            try out.file.append(xml)
        }
        try out.file.append("</sheetData>")
        if options.autoFilter && table.rows.count > 0 && table.columnCount > 0 { try out.file.append("<autoFilter ref=\"\(dimension)\"/>") }
        try out.file.append("</worksheet>")
        try out.file.close()
    }

    private final class XLSXTextHolder {
        let file: XMLTextFile
        init(_ url: URL) throws { file = try XMLTextFile(url: url) }
    }

    private static func formatSerial(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.10f", v).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    /// Text that would be mistaken for a number (so the cell gets the Text format and Excel keeps it as typed).
    private static func looksNumeric(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, s.count <= 24 else { return false }
        if !(f == "+" || f == "-" || f == "." || (f.value >= 0x30 && f.value <= 0x39)) { return false }
        return s.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || "+-.,eE ".unicodeScalars.contains($0) }
    }

    // MARK: Parts

    private static let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static func contentTypes(sheetCount: Int) -> String {
        var s = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        s += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 1...sheetCount { s += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }
        s += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        s += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/></Types>"
        return s
    }

    private static let rootRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"

    private static func workbookXML(names: [String], tables: [SheetTable], options: XLSXWriteOptions) -> String {
        var s = header + "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rns)\"><bookViews><workbookView xWindow=\"0\" yWindow=\"0\" windowWidth=\"28800\" windowHeight=\"17000\"/></bookViews><sheets>"
        let firstVisible = tables.firstIndex { !$0.hidden } ?? 0       // a workbook needs one visible sheet
        for (i, n) in names.enumerated() {
            let hidden = tables[i].hidden && i != firstVisible
            s += "<sheet name=\"\(SheetValues.xmlEscape(n, attribute: true))\" sheetId=\"\(i + 1)\"\(hidden ? " state=\"hidden\"" : "") r:id=\"rId\(i + 1)\"/>"
        }
        s += "</sheets>"
        if options.autoFilter {
            var defs = ""
            for (i, t) in tables.enumerated() where t.rows.count > 0 && t.columnCount > 0 {
                let quoted = "'" + names[i].replacingOccurrences(of: "'", with: "''") + "'"
                defs += "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">\(SheetValues.xmlEscape(quoted))!$A$1:$\(SheetValues.columnLetters(t.columnCount - 1))$\(t.rows.count)</definedName>"
            }
            if !defs.isEmpty { s += "<definedNames>\(defs)</definedNames>" }
        }
        return s + "</workbook>"
    }

    private static func workbookRels(sheetCount: Int) -> String {
        var s = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...sheetCount { s += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>" }
        s += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        s += "<Relationship Id=\"rId\(sheetCount + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>"
        return s
    }

    private static let stylesXML = header + "<styleSheet xmlns=\"\(ns)\">" +
        "<numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"yyyy\\-mm\\-dd\"/><numFmt numFmtId=\"165\" formatCode=\"yyyy\\-mm\\-dd\\ hh:mm:ss\"/></numFmts>" +
        "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font></fonts>" +
        "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>" +
        "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
        "<cellXfs count=\"5\">" +
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" +
        "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>" +
        "<xf numFmtId=\"49\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
        "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
        "<xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
        "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"

    private static func sharedStringsXML(_ sst: SharedStrings) -> String {
        var s = header + "<sst xmlns=\"\(ns)\" count=\"\(sst.references)\" uniqueCount=\"\(sst.list.count)\">"
        for t in sst.list { s += "<si><t xml:space=\"preserve\">\(SheetValues.xmlEscape(t))</t></si>" }
        return s + "</sst>"
    }
}
