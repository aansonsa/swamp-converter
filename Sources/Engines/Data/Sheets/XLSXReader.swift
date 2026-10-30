import Foundation

// XLSX / XLSM reader: zip parts through ZipKit, XMLParser (SAX) for the workbook, relationships, shared strings, styles and every worksheet. Sheets are extracted to a
// temp file and parsed from a stream, so a sheet of hundreds of MB is never held as one string. Cells come out as the display strings Excel shows (number formats applied,
// dates as ISO 8601); `SheetReadOptions.formatted = false` returns the stored values instead.

enum XLSXReader {
    static func read(_ url: URL, options: SheetReadOptions) throws -> SheetWorkbook {
        let file: RandomAccessFile
        let entries: [ZipEntry]
        do { file = try RandomAccessFile(url: url); entries = try ZipParser.parse(file) }
        catch let e as ZipError { throw e.conversionError }
        func part(_ name: String) throws -> Data? {
            guard let e = ZipKit.find(name, in: entries) else { return nil }
            do { return try ZipKit.readData(file, entry: e, limit: 512_000_000) } catch let z as ZipError { throw z.conversionError }
        }
        guard let wbData = try part("xl/workbook.xml") else {
            throw ConversionError.message(L10n("This file is not a valid XLSX workbook.", "Этот файл не является корректной книгой XLSX."))
        }
        let wb = WorkbookXML.parse(wbData)
        let rels = RelsXML.parse(try part("xl/_rels/workbook.xml.rels") ?? Data())
        let shared = try part("xl/sharedStrings.xml").map { SharedStringsXML.parse($0) } ?? []
        let styles = try part("xl/styles.xml").map { StylesXML.parse($0) } ?? StylesXML.Result()

        var sheets: [SheetTable] = []
        let ordered = options.firstSheetOnly ? (wb.sheets.first(where: { !$0.hidden }).map { [$0] } ?? Array(wb.sheets.prefix(1))) : wb.sheets
        for s in ordered {
            try Task.checkCancellation()
            guard var target = rels[s.rid] else { continue }
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            target = normalize(target)
            guard let entry = ZipKit.find(target, in: entries), entry.name.contains("worksheets") || entry.name.contains("sheet") else { continue }
            let temp = AppPaths.makeTempDirectory(purpose: "xlsxr")
            defer { AppPaths.removeTemp(temp) }
            let f = temp.appendingPathComponent("sheet.xml")
            do {
                FileManager.default.createFile(atPath: f.path, contents: nil)
                let h = try FileHandle(forWritingTo: f)
                defer { try? h.close() }
                try ZipEntryStream.stream(file, entry: entry) { try h.write(contentsOf: Data($0)) }
            } catch let z as ZipError { throw z.conversionError }
            var rows = try parseSheet(f, shared: shared, styles: styles, date1904: wb.date1904, formatted: options.formatted, maxRows: options.maxRows)
            // The grid is rectangular like Excel shows it; formatting-only rows at the end are dropped.
            while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
            let width = rows.map(\.count).max() ?? 0
            for i in rows.indices where rows[i].count < width { rows[i] += [String](repeating: "", count: width - rows[i].count) }
            sheets.append(SheetTable(name: s.name, rows: rows, hidden: s.hidden))
        }
        return SheetWorkbook(sheets: sheets, detectedEncoding: nil, detectedDelimiter: nil)
    }

    private static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for p in path.split(separator: "/") { if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(String(p)) } }
        return parts.joined(separator: "/")
    }

    private static func parseSheet(_ file: URL, shared: [String], styles: StylesXML.Result, date1904: Bool, formatted: Bool, maxRows: Int?) throws -> [[String]] {
        guard let stream = InputStream(url: file) else { throw ConversionError.fileUnreadable(file) }
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        let d = SheetXMLDelegate(shared: shared, styles: styles, date1904: date1904, formatted: formatted, maxRows: maxRows)
        parser.delegate = d
        if !parser.parse(), !d.stoppedEarly {
            throw ConversionError.message(L10n("The worksheet is damaged and cannot be read.", "Лист повреждён и не может быть прочитан."))
        }
        return d.rows
    }
}

// MARK: - Small XML helpers

private func decodeExcelEscapes(_ s: String) -> String {
    guard s.contains("_x") else { return s }
    var out = ""
    let chars = Array(s.unicodeScalars)
    var i = 0
    while i < chars.count {
        if chars[i] == "_", i + 6 < chars.count, chars[i + 1] == "x", chars[i + 6] == "_" {
            let hex = String(String.UnicodeScalarView(chars[(i + 2)...(i + 5)]))
            if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u); i += 7; continue }
        }
        out.unicodeScalars.append(chars[i]); i += 1
    }
    return out
}

private final class WorkbookXML: NSObject, XMLParserDelegate {
    struct Sheet { var name: String; var rid: String; var hidden: Bool }
    var sheets: [Sheet] = []
    var date1904 = false

    static func parse(_ data: Data) -> WorkbookXML {
        let d = WorkbookXML()
        let p = XMLParser(data: data); p.shouldResolveExternalEntities = false; p.delegate = d; p.parse()
        return d
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if name == "sheet" {
            let state = a["state"] ?? "visible"
            sheets.append(Sheet(name: a["name"] ?? "Sheet", rid: a["r:id"] ?? a["id"] ?? "", hidden: state != "visible"))
        } else if name == "workbookPr" { date1904 = a["date1904"] == "1" || a["date1904"] == "true" }
    }
}

private enum RelsXML {
    static func parse(_ data: Data) -> [String: String] {
        final class D: NSObject, XMLParserDelegate {
            var map: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                if name == "Relationship", let id = a["Id"], let t = a["Target"] { map[id] = t }
            }
        }
        let d = D()
        let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d.map
    }
}

private enum SharedStringsXML {
    static func parse(_ data: Data) -> [String] {
        final class D: NSObject, XMLParserDelegate {
            var list: [String] = []
            var current = ""
            var inT = false
            var phonetic = 0
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                switch name {
                case "si": current = ""
                case "rPh": phonetic += 1
                case "t": if phonetic == 0 { inT = true }
                default: break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters s: String) { if inT { current += s } }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch name {
                case "t": inT = false
                case "rPh": phonetic -= 1
                case "si": list.append(decodeExcelEscapes(current))
                default: break
                }
            }
        }
        let d = D()
        let p = XMLParser(data: data); p.shouldResolveExternalEntities = false; p.delegate = d; p.parse()
        return d.list
    }
}

private enum StylesXML {
    struct Result {
        /// Number format code per cell style index (xf), nil for General.
        var codeForStyle: [Int: String] = [:]
    }
    static func parse(_ data: Data) -> Result {
        final class D: NSObject, XMLParserDelegate {
            var custom: [Int: String] = [:]
            var xfFormatIDs: [Int] = []
            var inCellXfs = false
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                switch name {
                case "numFmt": if let id = a["numFmtId"].flatMap({ Int($0) }), let code = a["formatCode"] { custom[id] = code }
                case "cellXfs": inCellXfs = true
                case "xf": if inCellXfs { xfFormatIDs.append(a["numFmtId"].flatMap { Int($0) } ?? 0) }
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "cellXfs" { inCellXfs = false } }
        }
        let d = D()
        let p = XMLParser(data: data); p.shouldResolveExternalEntities = false; p.delegate = d; p.parse()
        var r = Result()
        for (i, id) in d.xfFormatIDs.enumerated() {
            if id == 0 { continue }
            if let c = d.custom[id] ?? XLSXNumberFormat.builtinCodes[id] { r.codeForStyle[i] = c }
        }
        return r
    }
}

private final class SheetXMLDelegate: NSObject, XMLParserDelegate {
    let shared: [String]
    let styles: StylesXML.Result
    let date1904: Bool
    let formatted: Bool
    let maxRows: Int?
    var rows: [[String]] = []
    var stoppedEarly = false

    private var rowIndex = 0
    private var current: [String] = []
    private var colIndex = 0
    private var cellType = ""
    private var cellStyle = -1
    private var text = ""
    private var capture = false
    private var inInline = false
    private var phonetic = 0

    init(shared: [String], styles: StylesXML.Result, date1904: Bool, formatted: Bool, maxRows: Int?) {
        self.shared = shared; self.styles = styles; self.date1904 = date1904; self.formatted = formatted; self.maxRows = maxRows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "row":
            let r = (a["r"].flatMap { Int($0) } ?? (rowIndex + 1)) - 1
            while rows.count < r { rows.append([]) }
            rowIndex = r
            current = []
            colIndex = 0
        case "c":
            if let ref = a["r"], let pos = SheetValues.cellReference(ref) { colIndex = pos.col }
            cellType = a["t"] ?? "n"
            cellStyle = a["s"].flatMap { Int($0) } ?? -1
            text = ""
        case "v": capture = true; text = ""
        case "is": inInline = true; text = ""
        case "rPh": phonetic += 1
        case "t": if inInline && phonetic == 0 { capture = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": capture = false
        case "rPh": phonetic -= 1
        case "is": inInline = false
        case "c":
            let value = cellString()
            if !value.isEmpty || colIndex < current.count {
                while current.count < colIndex { current.append("") }
                if colIndex < current.count { current[colIndex] = value } else { current.append(value) }
            }
            colIndex += 1
        case "row":
            rows.append(current)
            if let m = maxRows, rows.count >= m { stoppedEarly = true; (parser as XMLParser).abortParsing() }
        default: break
        }
    }

    private func cellString() -> String {
        let raw = text
        switch cellType {
        case "s": return Int(raw.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil } ?? ""
        case "str": return decodeExcelEscapes(raw)
        case "inlineStr": return decodeExcelEscapes(raw)
        case "b": return raw == "1" ? "TRUE" : "FALSE"
        case "e": return raw
        case "d": return raw.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        default:
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "" }
            guard formatted, let v = Double(t) else { return t }
            return XLSXNumberFormat.display(v, code: styles.codeForStyle[cellStyle], date1904: date1904)
        }
    }
}
