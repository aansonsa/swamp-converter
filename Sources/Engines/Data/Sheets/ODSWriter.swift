import Foundation

// ODS writer (OpenDocument Spreadsheet 1.2), own code, no LibreOffice needed. A zip with `mimetype` stored FIRST (no extra field), META-INF/manifest.xml, meta.xml and
// content.xml. content.xml is streamed to a temp file, so a big table never becomes one string. Cell typing is the XLSX rule (SheetValues.numberLiteral / serial):
// real numbers, real dates, everything else (leading zeros, "+420...", NaN) stays text.

enum ODSWriter {
    static let mimeType = "application/vnd.oasis.opendocument.spreadsheet"

    private static let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" "
        + "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" "
        + "xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\" "
        + "xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\""
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

    @discardableResult
    static func write(_ workbook: SheetWorkbook, to url: URL, options: XLSXWriteOptions) throws -> SheetWriteReport {
        var report = SheetWriteReport()
        var sheets = workbook.sheets
        if sheets.isEmpty { sheets = [SheetTable(name: "Sheet1", rows: [])] }
        let names = SheetValues.sanitizedSheetNames(sheets.map(\.name))
        let temp = AppPaths.makeTempDirectory(purpose: "ods")
        defer { AppPaths.removeTemp(temp) }

        let content = temp.appendingPathComponent("content.xml")
        let xml = try XMLTextFile(url: content)
        // Column widths per sheet from the first 200 rows (same rule as the XLSX writer).
        var widths: [[Double]] = []
        for t in sheets {
            var w = [Double](repeating: 0, count: max(t.columnCount, 1))
            if options.autoFit { for row in t.rows.prefix(200) { for (c, v) in row.enumerated() where c < w.count { w[c] = max(w[c], SheetValues.displayWidth(v)) } } }
            widths.append(w)
        }
        try xml.append(header + "<office:document-content \(ns) office:version=\"1.2\"><office:automatic-styles>")
        try xml.append("<number:date-style style:name=\"Nd\"><number:year number:style=\"long\"/><number:text>-</number:text><number:month number:style=\"long\"/><number:text>-</number:text><number:day number:style=\"long\"/></number:date-style>")
        try xml.append("<number:date-style style:name=\"Ndt\"><number:year number:style=\"long\"/><number:text>-</number:text><number:month number:style=\"long\"/><number:text>-</number:text><number:day number:style=\"long\"/><number:text> </number:text><number:hours number:style=\"long\"/><number:text>:</number:text><number:minutes number:style=\"long\"/><number:text>:</number:text><number:seconds number:style=\"long\"/></number:date-style>")
        try xml.append("<style:style style:name=\"ceHead\" style:family=\"table-cell\"><style:text-properties fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"/></style:style>")
        try xml.append("<style:style style:name=\"ceDate\" style:family=\"table-cell\" style:data-style-name=\"Nd\"/>")
        try xml.append("<style:style style:name=\"ceDateTime\" style:family=\"table-cell\" style:data-style-name=\"Ndt\"/>")
        try xml.append("<style:style style:name=\"taHidden\" style:family=\"table\"><style:table-properties table:display=\"false\"/></style:style>")
        for (si, w) in widths.enumerated() where options.autoFit {
            for (ci, chars) in w.enumerated() {
                let cm = min(60, max(8, chars * 1.1 + 2)) * 0.19
                try xml.append("<style:style style:name=\"co\(si)_\(ci)\" style:family=\"table-column\"><style:table-column-properties fo:break-before=\"auto\" style:column-width=\"\(String(format: "%.3f", cm))cm\"/></style:style>")
            }
        }
        try xml.append("</office:automatic-styles><office:body><office:spreadsheet>")

        for (si, table) in sheets.enumerated() {
            try Task.checkCancellation()
            let cols = max(table.columnCount, 1)
            let hidden = table.hidden && si != (sheets.firstIndex { !$0.hidden } ?? 0)
            try xml.append("<table:table table:name=\"\(SheetValues.xmlEscape(names[si], attribute: true))\"\(hidden ? " table:style-name=\"taHidden\"" : "")>")
            for c in 0..<cols {
                try xml.append(options.autoFit ? "<table:table-column table:style-name=\"co\(si)_\(c)\"/>" : "<table:table-column/>")
            }
            for (r, row) in table.rows.enumerated() {
                if r % 2048 == 0 { try Task.checkCancellation() }
                let isHeader = options.boldHeader && r == 0
                try xml.append("<table:table-row>" + rowXML(row, header: isHeader, columns: cols, options: options, report: &report) + "</table:table-row>")
            }
            try xml.append("</table:table>")
            report.rows += table.rows.count
        }
        try xml.append("</office:spreadsheet></office:body></office:document-content>")
        try xml.close()

        let zip = try ZipWriter(url: url, level: 6)
        try zip.add(data: Data(mimeType.utf8), as: "mimetype", method: .stored)
        try zip.add(data: Data(manifest.utf8), as: "META-INF/manifest.xml")
        try zip.add(data: Data(metaXML.utf8), as: "meta.xml")
        try zip.add(file: content, as: "content.xml")
        try zip.finish()
        return report
    }

    // MARK: Cells

    private static func rowXML(_ row: [String], header: Bool, columns: Int, options: XLSXWriteOptions, report: inout SheetWriteReport) -> String {
        var out = ""
        var emptyRun = 0
        func flushEmpty() {
            if emptyRun == 0 { return }
            out += emptyRun == 1 ? "<table:table-cell/>" : "<table:table-cell table:number-columns-repeated=\"\(emptyRun)\"/>"
            emptyRun = 0
        }
        for c in 0..<columns {
            let raw = c < row.count ? row[c] : ""
            if raw.isEmpty { emptyRun += 1; continue }
            flushEmpty()
            var text = raw
            if text.count > XLSXWriter.maxCellCharacters { text = String(text.prefix(XLSXWriter.maxCellCharacters)); report.truncatedCells += 1 }
            let style = header ? " table:style-name=\"ceHead\"" : ""
            if options.allText {
                out += "<table:table-cell\(style) office:value-type=\"string\">\(paragraphs(text))</table:table-cell>"
            } else if let n = SheetValues.numberLiteral(text, commaDecimal: options.commaDecimal) {
                out += "<table:table-cell\(style) office:value-type=\"float\" office:value=\"\(n)\"><text:p>\(n)</text:p></table:table-cell>"
            } else if options.dates, let d = SheetValues.serial(fromISO: text), let iso = isoDateValue(text, hasTime: d.hasTime) {
                let st = header ? " table:style-name=\"ceHead\"" : (d.hasTime ? " table:style-name=\"ceDateTime\"" : " table:style-name=\"ceDate\"")
                out += "<table:table-cell\(st) office:value-type=\"date\" office:date-value=\"\(iso)\"><text:p>\(SheetValues.xmlEscape(text))</text:p></table:table-cell>"
            } else {
                out += "<table:table-cell\(style) office:value-type=\"string\">\(paragraphs(text))</table:table-cell>"
            }
        }
        // trailing empty cells are not written (the row is simply shorter); a row with no cell at all keeps one empty cell so the row exists
        return out.isEmpty ? "<table:table-cell/>" : out
    }

    /// "2024-01-05 13:45" -> "2024-01-05T13:45:00".
    private static func isoDateValue(_ s: String, hasTime: Bool) -> String? {
        if !hasTime { return s.count == 10 ? s : nil }
        var t = s.replacingOccurrences(of: " ", with: "T")
        if t.count == 16 { t += ":00" }
        return t.count == 19 ? t : nil
    }

    /// One `<text:p>` per line; runs of spaces, tabs and leading spaces use the ODF elements so nothing is lost.
    static func paragraphs(_ text: String) -> String {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalised.split(separator: "\n", omittingEmptySubsequences: false).map { "<text:p>\(paragraph(String($0)))</text:p>" }.joined()
    }

    private static func paragraph(_ line: String) -> String {
        var out = ""
        var spaces = 0
        var atStart = true
        func flush() {
            guard spaces > 0 else { return }
            if atStart { out += "<text:s text:c=\"\(spaces)\"/>" }
            else { out += " "; if spaces > 1 { out += "<text:s text:c=\"\(spaces - 1)\"/>" } }
            spaces = 0
        }
        var chunk = ""
        func flushChunk() { if !chunk.isEmpty { out += SheetValues.xmlEscape(chunk); chunk = "" } }
        for ch in line.unicodeScalars {
            if ch == " " { flushChunk(); spaces += 1; continue }
            if spaces > 0 { flush() }
            if ch == "\t" { flushChunk(); out += "<text:tab/>"; atStart = false; continue }
            chunk.unicodeScalars.append(ch)
            atStart = false
        }
        flushChunk()
        if spaces > 0 { out += "<text:s text:c=\"\(spaces)\"/>" }     // trailing spaces
        return out
    }

    // MARK: Parts

    private static let manifest = header + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\">"
        + "<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"\(mimeType)\"/>"
        + "<manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/>"
        + "<manifest:file-entry manifest:full-path=\"meta.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"

    private static let metaXML = header + "<office:document-meta xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" office:version=\"1.2\">"
        + "<office:meta><meta:generator>Swamp Converter</meta:generator></office:meta></office:document-meta>"
}
