import Foundation

// What a document CONTAINS, read back from the file with parsers written for the conformance checks (not the engines' writers): body text in order,
// headings with their level, list items, tables, bold runs. Works on DOCX, ODT, HTML, EPUB, Markdown and plain text, decided by the sniffed format.

struct DocStructure {
    var blocks: [String] = []
    var headings: [(level: Int, text: String)] = []
    var listItems: [String] = []
    var tables: [[[String]]] = []
    var boldRuns = 0
    var paragraphs = 0

    /// Body text in document order, one block per line.
    var text: String { blocks.joined(separator: "\n") }
    var tableCellCount: Int { tables.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } }

    var summary: String { "\(headings.count) headings, \(listItems.count) list items, \(tables.count) tables (\(tableCellCount) cells), \(boldRuns) bold runs, \(blocks.count) blocks" }

    mutating func add(_ text: String, heading: Int? = nil, listItem: Bool = false) {
        let t = TextCompare.normalize(text)
        guard !t.isEmpty else { return }
        blocks.append(t)
        if let level = heading { headings.append((level, t)) } else if listItem { listItems.append(t) } else { paragraphs += 1 }
    }

    // MARK: Entry point

    static func read(_ url: URL) -> DocStructure? {
        guard let sniffed = FormatSniffer.sniff(url) else { return nil }
        switch sniffed.key {
        case "docx": return readDocx(url)
        case "odt": return readODT(url)
        case "html": return readHTML(String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self))
        case "epub": return readEPUB(url)
        case "md": return readMarkdown(String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self))
        case "txt", "csv", "tsv", "srt", "vtt":
            var d = DocStructure()
            for line in String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline) { d.add(String(line)) }
            return d
        case "rtf": return TextCompare.textutilText(url).map { text in var d = DocStructure(); text.split(whereSeparator: \.isNewline).forEach { d.add(String($0)) }; return d }
        default: return nil
        }
    }

    // MARK: DOCX / ODT (XML)

    static func readDocx(_ url: URL) -> DocStructure? {
        guard let list = ZipProbe.entries(url), let doc = list.first(where: { $0.name == "word/document.xml" }), let data = ZipProbe.read(doc, from: url) else { return nil }
        var styles: [String: String] = [:]
        if let s = list.first(where: { $0.name == "word/styles.xml" }), let sd = ZipProbe.read(s, from: url) {
            let d = StyleNameParser(); let p = XMLParser(data: sd); p.delegate = d; p.parse(); styles = d.names
        }
        let d = StructureParser(odf: false, styleNames: styles)
        let p = XMLParser(data: data); p.delegate = d
        return p.parse() ? d.result : nil
    }

    static func readODT(_ url: URL) -> DocStructure? {
        guard let list = ZipProbe.entries(url), let c = list.first(where: { $0.name == "content.xml" }), let data = ZipProbe.read(c, from: url) else { return nil }
        let d = StructureParser(odf: true, styleNames: [:])
        let p = XMLParser(data: data); p.delegate = d
        return p.parse() ? d.result : nil
    }

    static func readEPUB(_ url: URL) -> DocStructure? {
        guard let list = ZipProbe.entries(url) else { return nil }
        var all = DocStructure()
        for e in list.sorted(by: { Util.naturalCompare($0.name, $1.name) == .orderedAscending }) where e.name.hasSuffix(".xhtml") || e.name.hasSuffix(".html") {
            guard let data = ZipProbe.read(e, from: url) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            if html.contains("epub:type=\"toc\"") { continue }
            let part = readHTML(html)
            all.blocks += part.blocks; all.headings += part.headings; all.listItems += part.listItems; all.tables += part.tables
            all.boldRuns += part.boldRuns; all.paragraphs += part.paragraphs
        }
        return all
    }

    // MARK: HTML

    static func readHTML(_ html: String) -> DocStructure {
        enum Kind { case paragraph, heading(Int), item }
        var d = DocStructure()
        var buffer = ""
        var kind: Kind = .paragraph
        var kinds: [Kind] = []
        var tableStack: [[[String]]] = []
        var row: [String] = []
        var cell = ""
        var inCell = 0
        var skip = 0
        func flush() {
            let t = buffer; buffer = ""
            switch kind {
            case .heading(let l): d.add(t, heading: l)
            case .item: d.add(t, listItem: true)
            case .paragraph: d.add(t)
            }
        }
        let tag = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|<!--.*?-->"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        var last = 0
        for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            if skip == 0 { let t = decodeEntities(text); if inCell > 0 { cell += t } else { buffer += t } }
            guard m.range(at: 2).location != NSNotFound else { continue }
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            if name == "script" || name == "style" || name == "head" { skip += closing ? -1 : 1; skip = max(skip, 0); continue }
            if skip > 0 { continue }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if closing { flush(); kind = kinds.popLast() ?? .paragraph } else { flush(); kinds.append(kind); kind = .heading(Int(name.dropFirst()) ?? 1) }
            case "li":
                if closing { flush(); kind = kinds.popLast() ?? .paragraph } else { flush(); kinds.append(kind); kind = .item }
            case "p", "div", "br", "blockquote", "pre", "ul", "ol", "section", "article", "hr":
                if inCell == 0 { flush() } else if name == "br" || name == "p" { cell += " " }
            case "table": if closing { if let t = tableStack.popLast() { d.tables.append(t) } } else { tableStack.append([]) }
            case "tr":
                if closing { if !row.isEmpty, !tableStack.isEmpty { tableStack[tableStack.count - 1].append(row) }; row = [] } else { row = [] }
            case "td", "th":
                if closing { row.append(TextCompare.normalize(cell)); d.add(cell); cell = ""; inCell = max(0, inCell - 1) } else { flush(); inCell += 1; cell = "" }
            case "b", "strong": if !closing { d.boldRuns += 1 }
            default: break
            }
        }
        if skip == 0 { buffer += decodeEntities(ns.substring(from: last)) }
        flush()
        return d
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&amp;": "&"] { out = out.replacingOccurrences(of: k, with: v) }
        let numeric = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#)
        let ns = out as NSString
        var result = "", last = 0
        for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let code = ns.substring(with: m.range(at: 1))
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let v = value, let u = Unicode.Scalar(v) { result.unicodeScalars.append(u) }
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }

    // MARK: Markdown

    /// Inline Markdown removed: `**bold**`, `*em*`, `` `code` ``, `[text](url)`, `![alt](src)`.
    static func stripInlineMarkdown(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w*])[*_](\S.*?\S|\S)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        return t
    }

    static func readMarkdown(_ md: String) -> DocStructure {
        var d = DocStructure()
        var table: [[String]] = []
        func closeTable() { if !table.isEmpty { d.tables.append(table); table = [] } }
        for raw in md.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            d.boldRuns += line.components(separatedBy: "**").count / 2
            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                closeTable()
                let level = line[m].filter { $0 == "#" }.count
                d.add(stripInlineMarkdown(String(line[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))), heading: level)
            } else if let m = line.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                closeTable(); d.add(stripInlineMarkdown(String(line[m.upperBound...])), listItem: true)
            } else if line.range(of: #"^\s*\|.*\|\s*$"#, options: .regularExpression) != nil {
                let cells = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { TextCompare.normalize($0) }
                if cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { continue }
                let clean = cells.map(stripInlineMarkdown); table.append(clean); clean.forEach { d.add($0) }
            } else {
                closeTable(); d.add(stripInlineMarkdown(line))
            }
        }
        closeTable()
        return d
    }
}

// MARK: - XML parsers

private final class StyleNameParser: NSObject, XMLParserDelegate {
    var names: [String: String] = [:]
    private var currentID: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if name == "w:style" { currentID = a["w:styleId"] }
        if name == "w:name", let id = currentID, let v = a["w:val"] { names[id] = v }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "w:style" { currentID = nil } }
}

/// One SAX pass over word/document.xml (`odf: false`) or content.xml (`odf: true`).
private final class StructureParser: NSObject, XMLParserDelegate {
    var result = DocStructure()
    private let odf: Bool
    private let styleNames: [String: String]
    private var text = ""
    private var inText = false
    private var style: String?
    private var heading: Int?
    private var isList = false
    private var listDepth = 0
    private var inParagraph = false
    private var runBold = false
    private var tables: [[[String]]] = []
    private var row: [String] = []
    private var cellParts: [String] = []
    private var cellDepth = 0

    init(odf: Bool, styleNames: [String: String]) { self.odf = odf; self.styleNames = styleNames }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if odf { startODF(name, a) } else { startOOXML(name, a) }
    }

    private func startOOXML(_ name: String, _ a: [String: String]) {
        switch name {
        case "w:p": inParagraph = true; text = ""; style = nil; isList = false
        case "w:pStyle": style = a["w:val"]
        case "w:numPr": if inParagraph { isList = true }
        case "w:r": runBold = false
        case "w:b": if a["w:val"] != "0" && a["w:val"] != "false" { runBold = true }
        case "w:t": inText = true
        case "w:tab": if inParagraph { text += "\t" }
        case "w:br", "w:cr": if inParagraph { text += "\n" }
        case "w:tbl": tables.append([])
        case "w:tr": row = []
        case "w:tc": cellParts = []; cellDepth += 1
        default: break
        }
    }

    private func startODF(_ name: String, _ a: [String: String]) {
        switch name {
        case "text:h": inParagraph = true; text = ""; heading = Int(a["text:outline-level"] ?? "1") ?? 1
        case "text:p": inParagraph = true; text = ""; heading = nil
        case "text:list": listDepth += 1
        case "text:s": text += String(repeating: " ", count: Int(a["text:c"] ?? "1") ?? 1)
        case "text:tab": text += "\t"
        case "text:line-break": text += "\n"
        case "table:table": tables.append([])
        case "table:table-row": row = []
        case "table:table-cell": cellParts = []; cellDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if odf { if inParagraph { text += string } } else if inText { text += string; if runBold { result.boldRuns += 1; runBold = false } }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "w:t": inText = false
        case "w:p": endParagraph(headingLevel: headingLevelOOXML())
        case "text:h", "text:p": endParagraph(headingLevel: name == "text:h" ? heading : nil, list: listDepth > 0)
        case "text:list": listDepth -= 1
        case "w:tc", "table:table-cell":
            row.append(TextCompare.normalize(cellParts.joined(separator: " "))); cellDepth = max(0, cellDepth - 1)
        case "w:tr", "table:table-row":
            if !tables.isEmpty, !row.isEmpty || !odf { tables[tables.count - 1].append(row) }
            row = []
        case "w:tbl", "table:table": if let t = tables.popLast() { result.tables.append(t.filter { !$0.allSatisfy { $0.isEmpty } }) }
        default: break
        }
    }

    private func headingLevelOOXML() -> Int? {
        guard let id = style else { return nil }
        let name = (styleNames[id] ?? id).lowercased().replacingOccurrences(of: " ", with: "")
        if name == "title" { return 1 }
        if name.hasPrefix("heading"), let n = Int(name.dropFirst(7)) { return n }
        return nil
    }

    private func endParagraph(headingLevel: Int?, list: Bool? = nil) {
        guard inParagraph else { return }
        inParagraph = false
        let t = text; text = ""
        if cellDepth > 0 { cellParts.append(t); result.blocks.append(contentsOf: TextCompare.normalize(t).isEmpty ? [] : [TextCompare.normalize(t)]); return }
        let styled = (style.map { (styleNames[$0] ?? $0).lowercased().contains("list") } ?? false)
        result.add(t, heading: headingLevel, listItem: list ?? (isList || styled))
    }
}
