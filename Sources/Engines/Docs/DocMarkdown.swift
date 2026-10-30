import Foundation

// Markdown reader: CommonMark blocks (ATX / setext headings, fenced and indented code, block quotes, bullet and ordered lists with nesting and lazy continuation,
// thematic breaks, HTML blocks, link reference definitions) plus the GFM extensions (pipe tables, task lists, strikethrough, autolinks) when `gfm` is true.
// Inline parsing lives in DocMarkdownInline.swift. YAML front matter (title / author / lang / date) fills `DocModel.meta`.

enum DocMarkdown {
    struct Reference { var url: String; var title: String? }

    /// `gfm: false` is the CommonMark flavour: no tables, no strikethrough, no task lists, no bare-URL links.
    static func parse(_ text: String, gfm: Bool = true) -> DocModel {
        var src = DocTextCodec.normalizeLineEndings(text, to: "lf")
        if src.hasPrefix("\u{FEFF}") { src.removeFirst() }
        var lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let meta = extractFrontMatter(&lines)
        lines = lines.map(expandLeadingTabs)
        let parser = BlockParser(gfm: gfm)
        parser.collectReferences(lines)
        var loose = false
        var model = DocModel()
        model.blocks = parser.parseBlocks(lines, looseBetweenBlocks: &loose)
        model.meta = meta
        return model
    }

    // MARK: Front matter

    private static func extractFrontMatter(_ lines: inout [String]) -> DocMeta {
        var meta = DocMeta()
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return meta }
        guard let end = lines.indices.dropFirst().prefix(60).first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) else { return meta }
        let body = lines[1..<end]
        let yamlish = try! NSRegularExpression(pattern: "^([A-Za-z_][\\w .-]*:.*|\\s+.*|-\\s.*|#.*)$")
        let ok = body.allSatisfy { l in l.isEmpty || yamlish.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil }
        guard ok, body.contains(where: { $0.contains(":") }) else { return meta }
        for l in body {
            guard !l.hasPrefix(" "), let colon = l.firstIndex(of: ":") else { continue }
            let key = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            if value.hasPrefix("[") && value.hasSuffix("]") { value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\"", with: "") }
            guard !value.isEmpty else { continue }
            switch key {
            case "title": meta.title = value
            case "author", "authors": meta.author = value
            case "lang", "language": meta.language = value
            case "date": meta.created = DocXML.parseISODate(value)
            default: break
            }
        }
        lines.removeSubrange(0...end)
        return meta
    }

    private static func expandLeadingTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.contains("\t") else { return line }
        var col = 0
        var out = ""
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if c == " " { out.append(" "); col += 1 }
            else if c == "\t" { let n = 4 - col % 4; out += String(repeating: " ", count: n); col += n }
            else { break }
            idx = line.index(after: idx)
        }
        return out + line[idx...]
    }
}

// MARK: - Block parser

final class BlockParser {
    let gfm: Bool
    private(set) var references: [String: DocMarkdown.Reference] = [:]
    private lazy var inlineParser = InlineParser(gfm: gfm, references: references)

    init(gfm: Bool) { self.gfm = gfm }

    static let refRegex = try! NSRegularExpression(pattern: "^ {0,3}\\[((?:[^\\]\\\\]|\\\\.)+)\\]:\\s*<?([^\\s>]+)>?(?:\\s+(?:\"([^\"]*)\"|'([^']*)'|\\(([^)]*)\\)))?\\s*$")
    private static let blockTags: Set<String> = ["address", "article", "aside", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "main", "menu", "nav", "ol", "p", "section",
        "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "ul", "img"]

    static func normalizeLabel(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func collectReferences(_ lines: [String]) {
        var fence: String?
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") { fence = "```"; continue }
            if t.hasPrefix("~~~") { fence = "~~~"; continue }
            let ns = l as NSString
            if let m = Self.refRegex.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                let label = Self.normalizeLabel(ns.substring(with: m.range(at: 1)))
                var title: String?
                for g in 3...5 where m.range(at: g).location != NSNotFound { title = ns.substring(with: m.range(at: g)) }
                if references[label] == nil { references[label] = DocMarkdown.Reference(url: ns.substring(with: m.range(at: 2)), title: title) }
            }
        }
    }

    // MARK: Line classification

    private func isBlank(_ l: String) -> Bool { l.allSatisfy { $0 == " " || $0 == "\t" } }
    private func indent(_ l: String) -> Int { l.prefix { $0 == " " }.count }
    private func strip(_ l: String, _ n: Int) -> String { String(l.dropFirst(min(n, indent(l)))) }

    private func fenceOpening(_ l: String) -> (char: Character, count: Int, info: String, indent: Int)? {
        let ind = indent(l)
        guard ind < 4 else { return nil }
        let t = l.dropFirst(ind)
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let run = t.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        let info = t.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if c == "`" && info.contains("`") { return nil }
        return (c, run, info, ind)
    }

    private func atxHeading(_ l: String) -> (Int, String)? {
        let ind = indent(l)
        guard ind < 4 else { return nil }
        let t = l.dropFirst(ind)
        let level = t.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing sequence: trailing #s preceded by a space.
        if let r = text.range(of: "\\s+#+\\s*$", options: .regularExpression) { text.removeSubrange(r) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (level, text)
    }

    private func isThematicBreak(_ l: String) -> Bool {
        guard indent(l) < 4 else { return false }
        let t = l.filter { $0 != " " }
        guard t.count >= 3, let c = t.first, "-*_".contains(c) else { return false }
        return t.allSatisfy { $0 == c }
    }

    private func setextLevel(_ l: String) -> Int? {
        guard indent(l) < 4 else { return nil }
        let t = l.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private struct Marker { var indent: Int; var ordered: Bool; var number: Int; var char: Character; var content: Int; var rest: String }

    private func listMarker(_ l: String) -> Marker? {
        let ind = indent(l)
        guard ind < 4 else { return nil }
        let t = Array(l.dropFirst(ind))
        guard let first = t.first else { return nil }
        var i = 0
        var ordered = false
        var number = 1
        var ch = first
        if "-+*".contains(first) { i = 1 }
        else if first.isASCII, first.isNumber {
            var j = 0
            while j < t.count, t[j].isASCII, t[j].isNumber, j < 9 { j += 1 }
            guard j < t.count, t[j] == "." || t[j] == ")" else { return nil }
            number = Int(String(t[0..<j])) ?? 1
            ordered = true; ch = t[j]; i = j + 1
        } else { return nil }
        guard i == t.count || t[i] == " " else { return nil }
        var spaces = 0
        while i + spaces < t.count, t[i + spaces] == " " { spaces += 1 }
        let restStart = i + spaces
        let empty = restStart >= t.count
        let offset: Int
        if empty { offset = ind + i + 1 } else if spaces > 4 { offset = ind + i + 1 } else { offset = ind + i + spaces }
        let rest = empty ? "" : (spaces > 4 ? String(repeating: " ", count: spaces - 1) + String(t[restStart...]) : String(t[restStart...]))
        return Marker(indent: ind, ordered: ordered, number: number, char: ch, content: offset, rest: rest)
    }

    private func htmlBlockStart(_ l: String) -> Bool {
        let ind = indent(l)
        guard ind < 4 else { return false }
        let t = l.dropFirst(ind)
        if t.hasPrefix("<!--") || t.hasPrefix("<?") || t.hasPrefix("<!") { return true }
        guard t.hasPrefix("<") else { return false }
        var name = ""
        for c in t.dropFirst().drop(while: { $0 == "/" }) { if c.isLetter || c.isNumber || c == "-" { name.append(c) } else { break } }
        return Self.blockTags.contains(name.lowercased())
    }

    private func splitRow(_ l: String) -> [String] {
        var t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for c in t {
            if escaped { if c != "|" { cur.append("\\") }; cur.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "|" { cells.append(cur); cur = ""; continue }
            cur.append(c)
        }
        if escaped { cur.append("\\") }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty || !(t.hasSuffix("|") && !t.hasSuffix("\\|")) { cells.append(cur) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func delimiterRow(_ l: String) -> [DocAlign]? {
        guard l.contains("-"), indent(l) < 4 else { return nil }
        let cells = splitRow(l)
        guard !cells.isEmpty else { return nil }
        var out: [DocAlign] = []
        for c in cells {
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            let core = c.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(left && right ? .center : (left ? .left : (right ? .right : .none)))
        }
        return out
    }

    private func tableStarts(_ lines: [String], _ i: Int) -> Bool {
        guard gfm, i + 1 < lines.count, lines[i].contains("|"), let al = delimiterRow(lines[i + 1]) else { return false }
        return splitRow(lines[i]).count == al.count
    }

    private func startsNewBlock(_ l: String, afterParagraph: Bool) -> Bool {
        if fenceOpening(l) != nil || atxHeading(l) != nil || isThematicBreak(l) { return true }
        let ind = indent(l)
        if ind < 4, l.dropFirst(ind).hasPrefix(">") { return true }
        if let m = listMarker(l), !(m.rest.isEmpty) , !m.ordered || m.number == 1 { return true }
        if htmlBlockStart(l), !l.dropFirst(ind).hasPrefix("<img") { return true }
        return false
    }

    // MARK: Parsing

    /// `looseBetweenBlocks` is set when this level skipped a blank line between two of its own blocks (decides list looseness).
    func parseBlocks(_ lines: [String], looseBetweenBlocks: inout Bool) -> [DocBlock] {
        var blocks: [DocBlock] = []
        var i = 0
        let n = lines.count
        var pendingBlank = false
        func emit(_ b: DocBlock) {
            if pendingBlank, !blocks.isEmpty { looseBetweenBlocks = true }
            pendingBlank = false
            blocks.append(b)
        }
        while i < n {
            let line = lines[i]
            if isBlank(line) { pendingBlank = true; i += 1; continue }
            let ind = indent(line)

            if ind >= 4 {
                var code: [String] = []
                while i < n, indent(lines[i]) >= 4 || isBlank(lines[i]) { code.append(isBlank(lines[i]) ? "" : String(lines[i].dropFirst(4))); i += 1 }
                while code.last == "" { code.removeLast() }
                emit(.code(language: nil, text: code.joined(separator: "\n")))
                continue
            }
            if let f = fenceOpening(line) {
                var body: [String] = []
                i += 1
                while i < n {
                    let t = lines[i]
                    let ti = indent(t)
                    let tt = t.dropFirst(ti)
                    if ti < 4, tt.hasPrefix(String(repeating: f.char, count: f.count)), tt.allSatisfy({ $0 == f.char || $0 == " " }) { i += 1; break }
                    body.append(strip(t, f.indent))
                    i += 1
                }
                let lang = f.info.split(separator: " ").first.map(String.init)
                emit(.code(language: (lang?.isEmpty ?? true) ? nil : lang, text: body.joined(separator: "\n")))
                continue
            }
            if let (level, text) = atxHeading(line) {
                emit(.heading(level: level, content: inlineParser.parse(text)))
                i += 1
                continue
            }
            if isThematicBreak(line) { emit(.rule); i += 1; continue }
            if line.dropFirst(ind).hasPrefix(">") {
                var inner: [String] = []
                while i < n {
                    let t = lines[i]
                    let ti = indent(t)
                    if ti < 4, t.dropFirst(ti).hasPrefix(">") {
                        var rest = t.dropFirst(ti + 1)
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !isBlank(t), let last = inner.last, !isBlank(last), !startsNewBlock(t, afterParagraph: true), !(gfm && tableStarts(lines, i)) {
                        inner.append(t)   // lazy continuation of a paragraph
                    } else { break }
                    i += 1
                }
                var l = false
                emit(.quote(parseBlocks(inner, looseBetweenBlocks: &l)))
                continue
            }
            if let m = listMarker(line) {
                let (block, next) = parseList(lines, from: i, first: m)
                emit(block)
                i = next
                continue
            }
            if htmlBlockStart(line) {
                var html: [String] = []
                if line.dropFirst(ind).hasPrefix("<!--") {
                    while i < n { html.append(lines[i]); i += 1; if html.last!.contains("-->") { break } }
                } else {
                    while i < n, !isBlank(lines[i]) { html.append(lines[i]); i += 1 }
                }
                for b in DocHTMLReader.read(html.joined(separator: "\n")).blocks { emit(b) }
                continue
            }
            if BlockParser.refRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                i += 1       // a reference definition produces no block
                continue
            }
            if tableStarts(lines, i) {
                let aligns = delimiterRow(lines[i + 1])!
                let header = splitRow(lines[i])
                var rows: [[[DocInline]]] = []
                i += 2
                while i < n, !isBlank(lines[i]), !(fenceOpening(lines[i]) != nil), !(lines[i].dropFirst(indent(lines[i])).hasPrefix(">")), atxHeading(lines[i]) == nil {
                    var cells = splitRow(lines[i])
                    if cells.count > aligns.count { cells = Array(cells[0..<aligns.count]) }
                    while cells.count < aligns.count { cells.append("") }
                    rows.append(cells.map { inlineParser.parse($0) })
                    i += 1
                }
                emit(.table(DocTable(align: aligns, header: header.map { inlineParser.parse($0) }, rows: rows)))
                continue
            }
            // Paragraph (possibly a setext heading).
            var para: [String] = [line]
            i += 1
            var setext: Int?
            while i < n {
                let t = lines[i]
                if isBlank(t) { break }
                if let lvl = setextLevel(t) { setext = lvl; i += 1; break }
                if startsNewBlock(t, afterParagraph: true) || tableStarts(lines, i) { break }
                para.append(t)
                i += 1
            }
            let text = para.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) == "" ? "" : String($0.drop { $0 == " " }) }
            if let lvl = setext {
                emit(.heading(level: lvl, content: inlineParser.parse(text.joined(separator: " ").trimmingCharacters(in: .whitespaces))))
            } else {
                emit(.paragraph(inlineParser.parse(text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))))
            }
        }
        return blocks
    }

    private func parseList(_ lines: [String], from start: Int, first: Marker) -> (DocBlock, Int) {
        var i = start
        let n = lines.count
        var items: [DocListItem] = []
        var loose = false
        var blankBeforeNext = false
        while i < n, let m = listMarker(lines[i]), m.ordered == first.ordered, m.char == first.char {
            if blankBeforeNext { loose = true; blankBeforeNext = false }
            var itemLines = [m.rest]
            i += 1
            while i < n {
                let l = lines[i]
                if isBlank(l) {
                    var j = i
                    while j < n, isBlank(lines[j]) { j += 1 }
                    if j < n, indent(lines[j]) >= m.content { for _ in i..<j { itemLines.append("") }; i = j; continue }
                    break
                }
                if indent(l) >= m.content { itemLines.append(strip(l, m.content)); i += 1; continue }
                if let last = itemLines.last, !isBlank(last), !startsNewBlock(l, afterParagraph: true), listMarker(l) == nil, !(gfm && tableStarts(lines, i)) {
                    itemLines.append(l.trimmingCharacters(in: .whitespaces)); i += 1; continue   // lazy continuation
                }
                break
            }
            var checked: Bool?
            if gfm, let r = itemLines[0].range(of: "^\\[( |x|X)\\]\\s", options: .regularExpression) {
                checked = itemLines[0][r].contains("x") || itemLines[0][r].contains("X")
                itemLines[0] = String(itemLines[0][r.upperBound...])
            }
            var innerLoose = false
            let blocks = parseBlocks(itemLines, looseBetweenBlocks: &innerLoose)
            if innerLoose { loose = true }
            items.append(DocListItem(blocks: blocks, checked: checked))
            // Is the next non-blank line a sibling item?
            var j = i
            while j < n, isBlank(lines[j]) { j += 1 }
            if j < n, j > i, let nm = listMarker(lines[j]), nm.ordered == first.ordered, nm.char == first.char { blankBeforeNext = true; i = j }
            else if j < n, j == i { continue }
            else { break }
        }
        return (.list(DocList(ordered: first.ordered, start: first.number, tight: !loose, items: items)), i)
    }
}
