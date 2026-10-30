import Foundation

// Spreadsheet read-back for the conformance checks: an RFC 4180 reader for CSV / TSV, and XLSX / ODS readers on top of ZipProbe + XMLParser.
// The result is a plain grid of strings per sheet, so "the same table" is a question about numbers and text, not about files.

struct SheetGrid: Equatable {
    var name: String
    var rows: [[String]]

    /// Trailing empty cells and rows removed (writers disagree about the used range).
    var trimmed: [[String]] {
        var r = rows.map { row -> [String] in var x = row; while let l = x.last, l.isEmpty { x.removeLast() }; return x }
        while let l = r.last, l.isEmpty { r.removeLast() }
        return r
    }
}

enum TableFidelity {
    // MARK: CSV / TSV

    /// RFC 4180 parser: quoted fields, doubled quotes, delimiters and line breaks inside quotes, CRLF / LF / CR.
    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var pendingRow = false
        let chars = Array(text.unicodeScalars)
        let delim = delimiter.unicodeScalars.first!
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true; pendingRow = true
            } else if c == delim {
                row.append(field); field = ""; pendingRow = true
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); rows.append(row); row = []; field = ""; pendingRow = false
            } else { field.unicodeScalars.append(c); pendingRow = true }
            i += 1
        }
        if pendingRow || !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    struct DelimitedFile {
        var rows: [[String]]
        var hasBOM: Bool
        var lineEnding: String
        var delimiter: Character
        var encoding: String
    }

    /// Reads a CSV / TSV file: UTF-8 (BOM noted) or, failing that, Windows-1250; the delimiter is the tab for `.tsv`, else the most frequent of , ; tab | in the first line.
    static func readDelimited(_ url: URL, delimiter: Character? = nil) -> DelimitedFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? data.dropFirst(3) : data[...]
        let utf8 = String(data: body, encoding: .utf8)
        let text = utf8 ?? String(data: body, encoding: .windowsCP1250) ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let candidates: [Character] = [",", ";", "\t", "|"]
        let guessed = candidates.max { c1, c2 in firstLine.filter { $0 == c1 }.count < firstLine.filter { $0 == c2 }.count } ?? ","
        let d: Character = delimiter ?? (url.pathExtension.lowercased() == "tsv" ? "\t" : guessed)
        let ending = text.contains("\r\n") ? "\r\n" : (text.contains("\n") ? "\n" : (text.contains("\r") ? "\r" : ""))
        return DelimitedFile(rows: parseDelimited(text, delimiter: d), hasBOM: bom, lineEnding: ending, delimiter: d, encoding: utf8 != nil ? "UTF-8" : "Windows-1250")
    }

    // MARK: XLSX

    static func readXLSX(_ url: URL) -> [SheetGrid]? {
        guard let list = ZipProbe.entries(url) else { return nil }
        func part(_ name: String) -> Data? { list.first { $0.name == name }.flatMap { ZipProbe.read($0, from: url) } }
        guard let wb = part("xl/workbook.xml") else { return nil }
        let book = WorkbookParser(); let p = XMLParser(data: wb); p.delegate = book; p.parse()
        var targets: [String: String] = [:]
        if let rels = part("xl/_rels/workbook.xml.rels") { let r = RelsParser(); let q = XMLParser(data: rels); q.delegate = r; q.parse(); targets = r.targets }
        var shared: [String] = []
        if let ss = part("xl/sharedStrings.xml") { let s = SharedStringsParser(); let q = XMLParser(data: ss); q.delegate = s; q.parse(); shared = s.strings }
        var out: [SheetGrid] = []
        for (name, rid) in book.sheets {
            let target = targets[rid] ?? "worksheets/sheet\(out.count + 1).xml"
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = part(path) else { return nil }
            let sheet = SheetParser(shared: shared); let q = XMLParser(data: data); q.delegate = sheet; q.parse()
            out.append(SheetGrid(name: name, rows: sheet.rows))
        }
        return out
    }

    // MARK: ODS

    static func readODS(_ url: URL) -> [SheetGrid]? {
        guard let list = ZipProbe.entries(url), let c = list.first(where: { $0.name == "content.xml" }), let data = ZipProbe.read(c, from: url) else { return nil }
        let d = ODSParser(); let p = XMLParser(data: data); p.delegate = d
        return p.parse() ? d.sheets : nil
    }

    /// Reads whatever table format the sniffer says `url` is.
    static func read(_ url: URL) -> [SheetGrid]? {
        switch FormatSniffer.sniff(url)?.key {
        case "xlsx": return readXLSX(url)
        case "ods": return readODS(url)
        case "csv", "tsv", "txt": return readDelimited(url).map { [SheetGrid(name: url.deletingPathExtension().lastPathComponent, rows: $0.rows)] }
        default: return nil
        }
    }

    // MARK: Comparison

    /// First difference between two grids, or nil when they hold the same table. Numbers compare as numbers ("42" equals "42.0"), text exactly.
    static func difference(_ a: [[String]], _ b: [[String]], numericAware: Bool = true) -> String? {
        func trim(_ g: [[String]]) -> [[String]] { SheetGrid(name: "", rows: g).trimmed }
        let x = trim(a), y = trim(b)
        if x.count != y.count { return "row count \(x.count) vs \(y.count)" }
        for (r, (ra, rb)) in zip(x, y).enumerated() {
            let width = max(ra.count, rb.count)
            for c in 0..<width {
                let va = c < ra.count ? ra[c] : "", vb = c < rb.count ? rb[c] : ""
                if va == vb { continue }
                if numericAware, let da = number(va), let db = number(vb), abs(da - db) <= 1e-9 * max(1, abs(da)) { continue }
                return "cell R\(r + 1)C\(c + 1): \"\(va)\" vs \"\(vb)\""
            }
        }
        return nil
    }

    /// A cell that is a plain number (not text that merely looks like one: a leading zero such as "007" stays text).
    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count > 1, t.hasPrefix("0"), t.dropFirst().first?.isNumber == true { return nil }
        return Double(t)
    }
}

// MARK: - XML parsers

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(String, String)] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if name == "sheet", let n = a["name"], let id = a["r:id"] { sheets.append((n, id)) }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if name == "Relationship", let id = a["Id"], let t = a["Target"] { targets[id] = t }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inT = false
    private var inPhonetic = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if name == "si" { current = "" }
        if name == "t" { inT = true }
        if name == "rPh" { inPhonetic = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inT && !inPhonetic { current += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inT = false }
        if name == "rPh" { inPhonetic = false }
        if name == "si" { strings.append(current) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    private let shared: [String]
    private var cellRef = "", cellType = "", value = "", inline = ""
    private var inV = false, inT = false
    private var currentRow = -1
    init(shared: [String]) { self.shared = shared }

    private static func column(_ ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars where ch.value >= 65 && ch.value <= 90 { n = n * 26 + Int(ch.value - 64) }
        return max(0, n - 1)
    }
    private static func rowNumber(_ ref: String) -> Int { Int(ref.filter(\.isNumber)).map { $0 - 1 } ?? 0 }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "row": currentRow = a["r"].flatMap { Int($0) }.map { $0 - 1 } ?? (currentRow + 1)
        case "c": cellRef = a["r"] ?? ""; cellType = a["t"] ?? ""; value = ""; inline = ""
        case "v": inV = true
        case "t": inT = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inV { value += string } else if inT { inline += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inV = false
        case "t": inT = false
        case "c":
            let col = Self.column(cellRef), row = cellRef.isEmpty ? max(currentRow, 0) : Self.rowNumber(cellRef)
            var text: String
            switch cellType {
            case "s": text = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "inlineStr": text = inline
            case "b": text = value == "1" ? "TRUE" : "FALSE"
            default: text = value
            }
            if text.isEmpty { return }
            while rows.count <= row { rows.append([]) }
            while rows[row].count <= col { rows[row].append("") }
            rows[row][col] = text
        default: break
        }
    }
}

private final class ODSParser: NSObject, XMLParserDelegate {
    var sheets: [SheetGrid] = []
    private var rows: [[String]] = []
    private var row: [String] = []
    private var name = ""
    private var rowRepeat = 1, cellRepeat = 1
    private var cellValue: String?
    private var cellText = ""
    private var inP = false
    private var firstParagraphOfCell = true

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch element {
        case "table:table": name = a["table:name"] ?? "Sheet"; rows = []
        case "table:table-row": row = []; rowRepeat = Int(a["table:number-rows-repeated"] ?? "1") ?? 1
        case "table:table-cell", "table:covered-table-cell":
            cellRepeat = Int(a["table:number-columns-repeated"] ?? "1") ?? 1
            cellValue = a["office:value"] ?? a["office:string-value"]
            if a["office:value-type"] == "boolean" { cellValue = (a["office:boolean-value"] == "true") ? "TRUE" : "FALSE" }
            cellText = ""; firstParagraphOfCell = true
        case "text:p": inP = true; if !firstParagraphOfCell { cellText += "\n" }; firstParagraphOfCell = false
        case "text:s": if inP { cellText += String(repeating: " ", count: Int(a["text:c"] ?? "1") ?? 1) }
        case "text:tab": if inP { cellText += "\t" }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inP { cellText += string } }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "text:p": inP = false
        case "table:table-cell", "table:covered-table-cell":
            let text = cellValue ?? cellText
            for _ in 0..<min(cellRepeat, text.isEmpty ? 1 : 256) { row.append(text) }
        case "table:table-row":
            for _ in 0..<min(rowRepeat, row.allSatisfy(\.isEmpty) ? 1 : 256) { rows.append(row) }
        case "table:table": sheets.append(SheetGrid(name: name, rows: rows))
        default: break
        }
    }
}
