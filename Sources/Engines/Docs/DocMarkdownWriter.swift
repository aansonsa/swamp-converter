import Foundation

// DocModel -> Markdown. `gfm: true` writes pipe tables, ~~strike~~ and task lists; `gfm: false` (CommonMark) writes tables and strikethrough as HTML, which every
// CommonMark parser accepts. Text is escaped so that parsing the result gives the same structure back (the round trip is a self-test).

struct DocMarkdownWriter {
    var gfm = true
    /// Folder (relative to the .md file) that holds the extracted pictures; nil leaves pictures out and keeps only their alt text.
    var mediaFolder: String?
    var frontMatter = false

    private(set) var usedMedia: [String] = []
    private var model = DocModel()

    init(gfm: Bool = true, mediaFolder: String? = nil, frontMatter: Bool = false) {
        self.gfm = gfm; self.mediaFolder = mediaFolder; self.frontMatter = frontMatter
    }

    /// The Markdown text plus the media keys (in `model.media`) that are referenced from it.
    static func write(_ model: DocModel, gfm: Bool = true, mediaFolder: String? = nil, frontMatter: Bool = false) -> (markdown: String, usedMedia: [String]) {
        var w = DocMarkdownWriter(gfm: gfm, mediaFolder: mediaFolder, frontMatter: frontMatter)
        w.model = model
        var out = ""
        if frontMatter, !model.meta.isEmpty {
            var fm = ["---"]
            if let t = model.meta.title, !t.isEmpty { fm.append("title: \(yamlString(t))") }
            if let a = model.meta.author, !a.isEmpty { fm.append("author: \(yamlString(a))") }
            if let l = model.meta.language, !l.isEmpty { fm.append("lang: \(yamlString(l))") }
            fm.append("---")
            if fm.count > 2 { out += fm.joined(separator: "\n") + "\n\n" }
        }
        let lines = w.blocks(model.blocks, tight: false, indentFirstList: 0)
        out += lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return (out, w.usedMedia)
    }

    private static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    // MARK: Blocks

    /// Lines of the blocks, separated by blank lines (or directly, for tight list items).
    private mutating func blocks(_ bs: [DocBlock], tight: Bool, indentFirstList: Int) -> [String] {
        var out: [String] = []
        var previousList: DocList?
        for (k, b) in bs.enumerated() {
            var chunk: [String]
            switch b {
            case .heading(let level, let c):
                var text = inline(c, atLineStart: false).replacingOccurrences(of: "\n", with: " ")
                // A trailing run of # (alone or after a space) would be read as the optional closing sequence of the heading and dropped: escape its first #.
                if let r = text.range(of: "(^|[ \\t])#+[ \\t]*$", options: .regularExpression), let hash = text[r].firstIndex(of: "#") { text.insert("\\", at: hash) }
                chunk = ["\(String(repeating: "#", count: max(1, min(6, level)))) \(text)".trimmingCharacters(in: .whitespaces)]
                previousList = nil
            case .paragraph(let c):
                let text = inline(c, atLineStart: true)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                chunk = text.components(separatedBy: "\n").map { escapeLineStart($0) }
                previousList = nil
            case .list(let l):
                var ll = l
                // Two lists in a row would merge when parsed again: alternate the marker.
                let alternate = previousList.map { $0.ordered == l.ordered } ?? false
                chunk = list(&ll, alternate: alternate)
                previousList = l
            case .quote(let inner):
                let lines = blocks(inner, tight: false, indentFirstList: 0)
                chunk = lines.map { $0.isEmpty ? ">" : "> " + $0 }
                previousList = nil
            case .code(let lang, let text):
                var fence = "```"
                while text.contains(fence) { fence += "`" }
                chunk = [fence + (lang ?? "")] + text.components(separatedBy: "\n") + [fence]
                previousList = nil
            case .table(let t):
                chunk = table(t)
                previousList = nil
            case .rule:
                chunk = ["---"]; previousList = nil
            case .pageBreak:
                continue
            }
            // An ordered list that does not start at 1 cannot interrupt a paragraph (CommonMark): it needs a blank line even inside a tight item.
            var interrupts = false
            if k > 0, case .paragraph = bs[k - 1], case .list(let l) = b, l.ordered, l.start != 1 { interrupts = true }
            if !out.isEmpty, !(tight && k > 0) || interrupts { out.append("") }
            out += chunk
        }
        return out
    }

    private mutating func list(_ l: inout DocList, alternate: Bool) -> [String] {
        var out: [String] = []
        for (i, item) in l.items.enumerated() {
            let marker: String
            if l.ordered { marker = "\(l.start + i)\(alternate ? ")" : ".") " } else { marker = (alternate ? "* " : "- ") }
            let pad = String(repeating: " ", count: marker.count)
            var prefix = marker
            if let c = item.checked, gfm { prefix += c ? "[x] " : "[ ] " }
            var inner = blocks(item.blocks, tight: l.tight, indentFirstList: 0)
            if inner.isEmpty { inner = [""] }
            var lines: [String] = []
            for (j, line) in inner.enumerated() {
                if j == 0 { lines.append((prefix + line).trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty ? marker.trimmingCharacters(in: .whitespaces) : prefix + line) }
                else { lines.append(line.isEmpty ? "" : pad + line) }
            }
            if !l.tight, i > 0 { out.append("") }
            out += lines
        }
        return out
    }

    private mutating func table(_ t: DocTable) -> [String] {
        let cols = max(1, t.columnCount)
        var header = t.header
        var rows = t.rows
        if header == nil, !rows.isEmpty { header = rows.removeFirst() }
        let head = header ?? Array(repeating: [], count: cols)
        if !gfm { return htmlTable(t, header: head, rows: rows, cols: cols) }
        func cell(_ c: [DocInline]) -> String {
            inline(c, atLineStart: false).replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|")
        }
        func row(_ r: [[DocInline]]) -> String {
            let cells = (0..<cols).map { $0 < r.count ? cell(r[$0]) : "" }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        let delim = (0..<cols).map { i -> String in
            switch i < t.align.count ? t.align[i] : .none {
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            case .none: return "---"
            }
        }
        return [row(head), "| " + delim.joined(separator: " | ") + " |"] + rows.map(row)
    }

    private func htmlTable(_ t: DocTable, header: [[DocInline]], rows: [[[DocInline]]], cols: Int) -> [String] {
        func cells(_ r: [[DocInline]], tag: String) -> String {
            (0..<cols).map { i in
                let al = i < t.align.count ? t.align[i] : DocAlign.none
                let attr = al == .none ? "" : " align=\"\(al.rawValue)\""
                return "<\(tag)\(attr)>\(DocHTMLWriter.inlineHTML(i < r.count ? r[i] : [], model: model))</\(tag)>"
            }.joined()
        }
        var out = ["<table>", "<thead>", "<tr>\(cells(header, tag: "th"))</tr>", "</thead>"]
        if !rows.isEmpty { out.append("<tbody>"); out += rows.map { "<tr>\(cells($0, tag: "td"))</tr>" }; out.append("</tbody>") }
        out.append("</table>")
        return out
    }

    // MARK: Inlines

    private mutating func inline(_ items: [DocInline], atLineStart: Bool) -> String {
        var out = ""
        for (k, i) in items.enumerated() {
            switch i {
            case .text(let t): out += escapeText(t, previous: out.last, next: nextCharacter(items, after: k))
            case .code(let c):
                var fence = "`"
                while c.contains(fence) { fence += "`" }
                let pad = (c.hasPrefix("`") || c.hasSuffix("`") || (c.hasPrefix(" ") && c.hasSuffix(" ") && !c.trimmingCharacters(in: .whitespaces).isEmpty)) ? " " : ""
                out += fence + pad + c.replacingOccurrences(of: "\n", with: " ") + pad + fence
            case .emphasis(let c): out += wrap(inline(c, atLineStart: false), "*")
            case .strong(let c): out += wrap(inline(c, atLineStart: false), "**")
            case .strike(let c):
                let inner = inline(c, atLineStart: false)
                out += gfm ? wrap(inner, "~~") : "<del>\(inner)</del>"
            case .underline(let c): out += "<u>\(inline(c, atLineStart: false))</u>"
            case .link(let url, let title, let c):
                let text = inline(c, atLineStart: false)
                if gfm, title == nil, c.count == 1, case .text(let t) = c[0], t == url, !url.contains(" ") { out += "<\(url)>"; continue }
                out += "[\(text)](\(destination(url))\(title.map { " \"\(Self.escapeTitle($0))\"" } ?? ""))"
            case .image(let src, let alt, let title):
                if model.media[src] != nil {
                    guard let folder = mediaFolder, let m = model.media[src] else { out += alt.isEmpty ? "" : "[\(escapeText(alt, previous: nil, next: nil))]"; continue }
                    if !usedMedia.contains(src) { usedMedia.append(src) }
                    let path = folder.isEmpty ? m.name : folder + "/" + m.name
                    out += "![\(escapeText(alt, previous: nil, next: nil))](\(destination(path))\(title.map { " \"\(Self.escapeTitle($0))\"" } ?? ""))"
                } else if src.lowercased().hasPrefix("http://") || src.lowercased().hasPrefix("https://") {
                    out += "![\(escapeText(alt, previous: nil, next: nil))](\(destination(src))\(title.map { " \"\(Self.escapeTitle($0))\"" } ?? ""))"
                } else if !alt.isEmpty {
                    out += "[\(escapeText(alt, previous: nil, next: nil))]"
                }
            case .lineBreak: out += "\\\n"
            case .softBreak: out += "\n"
            }
        }
        return out
    }

    private func nextCharacter(_ items: [DocInline], after k: Int) -> Character? {
        guard k + 1 < items.count else { return nil }
        switch items[k + 1] {
        case .text(let t): return t.first
        case .code, .emphasis, .strong, .strike, .underline, .link, .image: return "*"   // a delimiter-like neighbour: keep underscores escaped
        default: return nil
        }
    }

    /// Delimiters hug the text: spaces at the edges of the content go outside (`** a **` would not parse as strong).
    private func wrap(_ s: String, _ mark: String) -> String {
        let lead = s.prefix { $0 == " " }
        let trail = s.reversed().prefix { $0 == " " }
        let core = s.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if core.isEmpty { return s }
        return String(lead) + mark + core + mark + String(trail)
    }

    /// A link destination that every Markdown reader takes literally: spaces, parentheses and angle brackets are percent-encoded, so no <...> wrapper is needed.
    private func destination(_ u: String) -> String {
        var out = ""
        for ch in u.unicodeScalars {
            switch ch {
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "<": out += "%3C"
            case ">": out += "%3E"
            default: if ch.value < 0x20 { out += String(format: "%%%02X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    private static func escapeTitle(_ t: String) -> String { t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    // MARK: Escaping

    private func escapeText(_ t: String, previous: Character?, next: Character?) -> String {
        var out = ""
        let chars = Array(t)
        for (i, c) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : previous
            let nxt = i + 1 < chars.count ? chars[i + 1] : next
            switch c {
            case "\\", "`", "*", "[", "]": out += "\\" + String(c)
            case "_":
                let intraword = (prev?.isLetter ?? false || prev?.isNumber ?? false) && (nxt?.isLetter ?? false || nxt?.isNumber ?? false)
                out += intraword ? "_" : "\\_"
            case "<": out += (nxt.map { $0.isLetter || $0 == "/" || $0 == "!" || $0 == "?" } ?? false) ? "\\<" : "<"
            case "&": out += (nxt.map { $0.isLetter || $0 == "#" } ?? false) ? "\\&" : "&"
            case "~": out += gfm ? "\\~" : "~"      // the reader takes a single ~ as strikethrough too
            case "\n": out += "\n"
            default: out.append(c)
            }
        }
        // http(s):// text would turn into a link in GFM.
        return out
    }

    /// Escapes constructs that would change the block type when a line starts with them.
    private func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "#>".contains(first) { return "\\" + line }
        if "-+".contains(first), line.dropFirst().first == " " || line.count == 1 { return "\\" + line }
        if first == "=" || (first == "-" && line.allSatisfy { $0 == "-" || $0 == " " }) { return "\\" + line }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if (rest.first == "." || rest.first == ")") && (rest.dropFirst().first == " " || rest.count == 1) { return String(digits) + "\\" + rest }
        }
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return "\u{00A0}" + line.drop { $0 == " " || $0 == "\t" } }
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.count >= 3, let c = t.first, "*_".contains(c), t.allSatisfy({ $0 == c || $0 == " " }) { return "\\" + line }
        if t.hasPrefix("```") || t.hasPrefix("~~~") { return "\\" + line }
        return line
    }
}
