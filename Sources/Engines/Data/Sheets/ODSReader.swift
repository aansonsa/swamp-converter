import Foundation

// ODS reader: content.xml through ZipKit + XMLParser (SAX, streamed from a temp file). Handles repeated rows / columns (a sheet that ends with a million blank rows
// costs nothing), covered cells of merged ranges, text:s / text:tab / text:line-break, several paragraphs per cell, and the value types float, percentage, currency,
// date, time, boolean and string. Cells come out as the display strings the user sees (`formatted`), dates and times as ISO 8601; `formatted = false` returns the
// stored values instead.

enum ODSReader {
    static func read(_ url: URL, options: SheetReadOptions) throws -> SheetWorkbook {
        let file: RandomAccessFile
        let entries: [ZipEntry]
        do { file = try RandomAccessFile(url: url); entries = try ZipParser.parse(file) }
        catch let e as ZipError { throw e.conversionError }
        guard let entry = ZipKit.find("content.xml", in: entries) else {
            throw ConversionError.message(L10n("This file is not a valid ODS spreadsheet.", "Этот файл не является корректной таблицей ODS."))
        }
        if entry.isEncrypted { throw ConversionError.encryptedArchive }
        let temp = AppPaths.makeTempDirectory(purpose: "odsr")
        defer { AppPaths.removeTemp(temp) }
        let f = temp.appendingPathComponent("content.xml")
        do {
            FileManager.default.createFile(atPath: f.path, contents: nil)
            let h = try FileHandle(forWritingTo: f)
            defer { try? h.close() }
            try ZipEntryStream.stream(file, entry: entry) { try h.write(contentsOf: Data($0)) }
        } catch let z as ZipError { throw z.conversionError }
        guard let stream = InputStream(url: f) else { throw ConversionError.fileUnreadable(f) }
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        let d = ODSDelegate(formatted: options.formatted, maxRows: options.maxRows, firstOnly: options.firstSheetOnly)
        parser.delegate = d
        if !parser.parse(), !d.stoppedEarly {
            throw ConversionError.message(L10n("The spreadsheet is damaged and cannot be read.", "Таблица повреждена и не может быть прочитана."))
        }
        var sheets = d.sheets
        if options.firstSheetOnly, sheets.count > 1 { sheets = [sheets.first(where: { !$0.hidden }) ?? sheets[0]] }
        for i in sheets.indices {
            var rows = sheets[i].rows
            while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
            let width = rows.map(\.count).max() ?? 0
            for r in rows.indices where rows[r].count < width { rows[r] += [String](repeating: "", count: width - rows[r].count) }
            sheets[i].rows = rows
        }
        return SheetWorkbook(sheets: sheets, detectedEncoding: nil, detectedDelimiter: nil)
    }
}

private final class ODSDelegate: NSObject, XMLParserDelegate {
    let formatted: Bool
    let maxRows: Int?
    let firstOnly: Bool
    var sheets: [SheetTable] = []
    var stoppedEarly = false

    // current sheet
    private var rows: [[String]] = []
    private var sheetName = ""
    private var sheetDepth = 0
    private var pendingEmptyRows = 0

    // current row / cell
    private var row: [String] = []
    private var rowRepeat = 1
    private var rowHasContent = false
    private var cellRepeat = 1
    private var cellAttrs: [String: String] = [:]
    private var inCell = false
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var inParagraph = false
    private var annotationDepth = 0
    private var hiddenStyles = Set<String>()
    private var currentStyle = ""
    private var currentSheetHidden = false

    init(formatted: Bool, maxRows: Int?, firstOnly: Bool) { self.formatted = formatted; self.maxRows = maxRows; self.firstOnly = firstOnly }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "style:style":
            currentStyle = a["style:name"] ?? ""
        case "style:table-properties":
            if a["table:display"] == "false", !currentStyle.isEmpty { hiddenStyles.insert(currentStyle) }
        case "table:table":
            if sheetDepth == 0 {
                sheetName = a["table:name"] ?? "Sheet"; rows = []; pendingEmptyRows = 0
                currentSheetHidden = a["table:style-name"].map { hiddenStyles.contains($0) } ?? false
            }
            sheetDepth += 1
        case "table:table-row":
            row = []; rowRepeat = Int(a["table:number-rows-repeated"] ?? "1") ?? 1; rowHasContent = false
        case "table:table-cell", "table:covered-table-cell":
            inCell = true
            cellAttrs = a
            cellRepeat = max(1, Int(a["table:number-columns-repeated"] ?? "1") ?? 1)
            paragraphs = []
            currentParagraph = ""
            if name == "table:covered-table-cell" { cellAttrs["covered"] = "1" }
        case "office:annotation", "office:annotation-end":
            if name == "office:annotation" { annotationDepth += 1 }
        case "text:p", "text:h":
            if inCell && annotationDepth == 0 { inParagraph = true; currentParagraph = "" }
        case "text:s":
            if inParagraph { currentParagraph += String(repeating: " ", count: max(1, Int(a["text:c"] ?? "1") ?? 1)) }
        case "text:tab":
            if inParagraph { currentParagraph += "\t" }
        case "text:line-break":
            if inParagraph { currentParagraph += "\n" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inParagraph { currentParagraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "office:annotation":
            annotationDepth = max(0, annotationDepth - 1)
        case "text:p", "text:h":
            if inParagraph { paragraphs.append(currentParagraph); inParagraph = false }
        case "table:table-cell", "table:covered-table-cell":
            let value = cellValue()
            inCell = false
            if value.isEmpty {
                // Empty cells are kept only when something non-empty follows in the row; they are appended lazily.
                row.append(contentsOf: [String](repeating: "", count: min(cellRepeat, 16_384)))
            } else {
                rowHasContent = true
                row.append(contentsOf: [String](repeating: value, count: min(cellRepeat, 16_384)))
            }
        case "table:table-row":
            // drop trailing empty cells
            while let last = row.last, last.isEmpty { row.removeLast() }
            if row.isEmpty && !rowHasContent {
                pendingEmptyRows += rowRepeat
            } else {
                if pendingEmptyRows > 0 { rows.append(contentsOf: [[String]](repeating: [], count: min(pendingEmptyRows, 1_048_576))); pendingEmptyRows = 0 }
                for _ in 0..<min(rowRepeat, 65_536) { rows.append(row) }
            }
            row = []
            if let m = maxRows, rows.count >= m, sheets.isEmpty || firstOnly {
                // enough rows for a preview of the first sheet
                sheets.append(SheetTable(name: sheetName, rows: Array(rows.prefix(m)), hidden: currentSheetHidden))
                stoppedEarly = true
                parser.abortParsing()
            }
        case "table:table":
            sheetDepth -= 1
            if sheetDepth == 0 {
                sheets.append(SheetTable(name: sheetName, rows: rows, hidden: currentSheetHidden))
                rows = []
                if firstOnly { stoppedEarly = true; parser.abortParsing() }
            }
        default: break
        }
    }

    private func cellValue() -> String {
        let a = cellAttrs
        if a["covered"] == "1" { return "" }
        let type = a["office:value-type"] ?? ""
        let display = paragraphs.joined(separator: "\n")
        switch type {
        case "float", "percentage", "currency":
            if formatted, !display.isEmpty { return display }
            return a["office:value"] ?? display
        case "date":
            return Self.isoDate(a["office:date-value"] ?? "")
        case "time":
            return Self.isoTime(a["office:time-value"] ?? "") ?? display
        case "boolean":
            let v = a["office:boolean-value"] ?? ""
            return v == "true" ? "TRUE" : (v == "false" ? "FALSE" : display)
        case "string":
            if let s = a["office:string-value"], paragraphs.isEmpty { return s }
            return display
        default:
            return display
        }
    }

    /// "2024-01-05" stays, "2024-01-05T13:45:09" becomes "2024-01-05 13:45:09" (fractions of seconds dropped).
    static func isoDate(_ s: String) -> String {
        guard s.contains("T") else { return s }
        var t = s.replacingOccurrences(of: "T", with: " ")
        if let dot = t.firstIndex(of: ".") { t = String(t[t.startIndex..<dot]) }
        if t.hasSuffix(" 00:00:00") { t = String(t.dropLast(9)) }
        return t
    }

    /// "PT13H45M09S" -> "13:45:09".
    static func isoTime(_ s: String) -> String? {
        guard s.hasPrefix("PT") else { return nil }
        var h = 0, m = 0, sec = 0.0
        var num = ""
        for ch in s.dropFirst(2) {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            let v = Double(num) ?? 0
            num = ""
            switch ch { case "H": h = Int(v); case "M": m = Int(v); case "S": sec = v; default: break }
        }
        return String(format: "%02d:%02d:%02d", h, m, Int(sec.rounded(.down)))
    }
}
