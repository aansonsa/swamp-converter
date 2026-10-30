import Foundation

// HTML tree -> DocModel. Block elements become blocks, inline elements become styled inlines. Style comes from semantic tags (b, i, u, s, code ...), from `style=""` and
// from simple class / tag rules in <style> (what Word and textutil exports use: `span.s1 { font-weight: bold }`). Pictures given as data: URIs are decoded into the
// model's media; other `src` values are kept for the image resolver.

enum DocHTMLReader {
    static func read(_ html: String) -> DocModel {
        let root = DocHTMLParser.parse(html)
        let ctx = Context(root: root)
        let body = root.firstDescendant("body") ?? root
        var model = DocModel()
        model.blocks = ctx.blocks(from: body.children)
        model.media = ctx.media.items
        if let t = root.firstDescendant("title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { model.meta.title = t }
        for m in root.descendants("meta") {
            let name = (m.attributes["name"] ?? "").lowercased()
            if name == "author", let c = m.attributes["content"], !c.isEmpty { model.meta.author = c }
            if name == "dc.language" || name == "language", let c = m.attributes["content"], !c.isEmpty { model.meta.language = c }
        }
        if let lang = root.firstDescendant("html")?.attributes["lang"], !lang.isEmpty { model.meta.language = lang }
        return model
    }

    // MARK: CSS

    struct Style: Equatable {
        var bold: Bool?
        var italic: Bool?
        var underline: Bool?
        var strike: Bool?
        var mono: Bool?
        var align: DocAlign?
        /// Font size in CSS pixels (from `font-size` or the `font` shorthand): textutil and Word exports mark headings only by size and weight.
        var size: Double?
        mutating func merge(_ o: Style) {
            if let v = o.bold { bold = v }; if let v = o.italic { italic = v }; if let v = o.underline { underline = v }
            if let v = o.strike { strike = v }; if let v = o.mono { mono = v }; if let v = o.align { align = v }; if let v = o.size { size = v }
        }
    }

    static func style(fromDeclarations css: String) -> Style {
        var st = Style()
        for decl in css.split(separator: ";") {
            guard let colon = decl.firstIndex(of: ":") else { continue }
            let key = decl[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            switch key {
            case "font-weight": st.bold = value == "bold" || value == "bolder" || (Int(value) ?? 0) >= 600
            case "font-style": st.italic = value == "italic" || value == "oblique"
            case "text-decoration", "text-decoration-line":
                st.underline = value.contains("underline"); st.strike = value.contains("line-through")
            case "font-family": st.mono = value.contains("monospace") || value.contains("courier") || value.contains("menlo") || value.contains("consolas") || value.contains("monaco")
            case "text-align": st.align = DocAlign(rawValue: value == "start" ? "left" : value)
            case "font-size": st.size = cssPixels(value)
            case "font":   // shorthand written by textutil: "font: 12.0px Helvetica"
                if value.contains("bold") { st.bold = true }
                if value.contains("italic") { st.italic = true }
                if value.contains("monospace") || value.contains("courier") || value.contains("menlo") || value.contains("consolas") || value.contains("monaco") { st.mono = true }
                if let r = value.range(of: "[0-9.]+(px|pt)", options: .regularExpression) { st.size = cssPixels(String(value[r])) }
            default: break
            }
        }
        return st
    }

    /// "12.5px" / "11pt" -> CSS pixels (nil for relative or unknown units).
    static func cssPixels(_ v: String) -> Double? {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("px"), let d = Double(t.dropLast(2)) { return d }
        if t.hasSuffix("pt"), let d = Double(t.dropLast(2)) { return d * 4 / 3 }
        return nil
    }

    /// Simple selectors only: `tag`, `.class`, `tag.class`. Combinators and pseudo selectors are skipped.
    static func parseRules(_ css: String) -> [(selector: String, style: Style)] {
        var out: [(String, Style)] = []
        let cleaned = css.replacingOccurrences(of: "/\\*.*?\\*/", with: "", options: .regularExpression)
        var rest = Substring(cleaned)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let selectors = rest[..<open].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let body = String(rest[rest.index(after: open)..<close])
            let st = style(fromDeclarations: body)
            for s in selectors where !s.isEmpty && !s.contains(" ") && !s.contains(">") && !s.contains(":") && !s.contains("+") && !s.hasPrefix("@") { out.append((s, st)) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    // MARK: Conversion context

    final class Context {
        var media = DocMediaStore()
        let rules: [(selector: String, style: Style)]
        /// The dominant paragraph size of the document (by amount of text); paragraphs clearly larger than this and fully bold become headings.
        private(set) var bodySize: Double?

        init(root: DocHTMLNode) {
            rules = root.descendants("style").flatMap { DocHTMLReader.parseRules($0.textContent) }
            var weights: [Double: Int] = [:]
            for n in root.descendants("p") + root.descendants("li") {
                guard let sz = style(of: n).size else { continue }
                weights[sz, default: 0] += n.textContent.count
            }
            bodySize = weights.max { $0.value < $1.value }?.key
        }

        func style(of n: DocHTMLNode) -> Style {
            var st = Style()
            for r in rules where r.selector == n.tag { st.merge(r.style) }
            for c in n.classes {
                for r in rules where r.selector == "." + c.lowercased() || r.selector == n.tag + "." + c.lowercased() { st.merge(r.style) }
            }
            if let inline = n.attributes["style"] { st.merge(DocHTMLReader.style(fromDeclarations: inline)) }
            return st
        }

        static let skipTags: Set<String> = ["head", "script", "style", "title", "meta", "link", "noscript", "template", "svg", "canvas", "audio", "video", "iframe", "object", "select", "button", "textarea"]
        static let containerTags: Set<String> = ["body", "div", "section", "article", "main", "header", "footer", "nav", "aside", "form", "figure", "figcaption", "details", "summary", "center",
            "address", "fieldset", "html", "#root", "hgroup", "menu", "dir", "legend", "tbody", "thead", "tfoot", "caption", "colgroup"]
        static let blockTags: Set<String> = containerTags.union(["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre", "hr", "table", "tr", "td", "th"])

        func isBlock(_ n: DocHTMLNode) -> Bool { !n.isText && Self.blockTags.contains(n.tag) }

        // MARK: Blocks

        func blocks(from nodes: [DocHTMLNode]) -> [DocBlock] {
            var out: [DocBlock] = []
            var pending: [DocHTMLNode] = []
            func flush() {
                guard !pending.isEmpty else { return }
                let inl = inlines(from: pending)
                pending = []
                if !inl.isBlank { out.append(.paragraph(inl)) }
            }
            for n in nodes {
                if n.isText || !isBlock(n) {
                    if !n.isText, Self.skipTags.contains(n.tag) { continue }
                    if !n.isText, n.tag == "img", let src = n.attributes["src"], !src.isEmpty { pending.append(n); continue }
                    pending.append(n); continue
                }
                flush()
                out += block(n)
            }
            flush()
            return Self.mergeCodeParagraphs(out)
        }

        private static let codeParagraphMarker = "\u{1}p"

        /// Consecutive monospaced paragraphs (what Word and textutil write for code) become one code block.
        static func mergeCodeParagraphs(_ blocks: [DocBlock]) -> [DocBlock] {
            var out: [DocBlock] = []
            for b in blocks {
                if case .code(let lang, let text) = b, lang == codeParagraphMarker {
                    if case .code(let prevLang, let prev)? = out.last, prevLang == codeParagraphMarker { out[out.count - 1] = .code(language: codeParagraphMarker, text: prev + "\n" + text) }
                    else { out.append(b) }
                } else { out.append(b) }
            }
            return out.map { b in if case .code(let l, let t) = b, l == codeParagraphMarker { return .code(language: nil, text: t) }; return b }
        }

        private func block(_ n: DocHTMLNode) -> [DocBlock] {
            switch n.tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let c = inlines(from: n.children)
                return c.isBlank ? [] : [.heading(level: Int(String(n.tag.last!)) ?? 1, content: c)]
            case "p":
                if n.children.contains(where: { isBlock($0) }) { return blocks(from: n.children) }
                let plain = inlines(from: n.children)
                if plain.isBlank { return [] }
                let st = style(of: n)
                if st.mono == true { return [.code(language: Self.codeParagraphMarker, text: plain.plainText)] }
                // A class or style on the paragraph itself (`p.warn { font-weight: bold }`) styles all of its text.
                let c = wrapStyle(n, plain)
                // Word and textutil mark headings only by size and weight: a short, fully bold line that is clearly larger than the body text. The cut-offs sit halfway
                // between the browser defaults (h1 2.0, h2 1.5, h3 1.17 times the body size).
                if let body = bodySize, let size = st.size, size >= body * 1.08, c.count == 1, case .strong(let inner) = c[0],
                   inner.plainText.count <= 120, !inner.plainText.hasSuffix(".") {
                    let ratio = size / body
                    return [.heading(level: ratio >= 1.75 ? 1 : (ratio >= 1.33 ? 2 : 3), content: inner)]
                }
                return [.paragraph(c)]
            case "ul", "ol": return [list(n)]
            case "blockquote":
                let inner = blocks(from: n.children)
                return inner.isEmpty ? [] : [.quote(inner)]
            case "pre": return [code(n)]
            case "hr": return [.rule]
            case "table": return table(n).map { [$0] } ?? []
            case "dl":
                var out: [DocBlock] = []
                for c in n.children where !c.isText {
                    if c.tag == "dt" { let i = inlines(from: c.children); if !i.isBlank { out.append(.paragraph([.strong(i)])) } }
                    else if c.tag == "dd" { out += blocks(from: c.children) }
                }
                return out
            case "li", "dt", "dd", "tr", "td", "th": return blocks(from: n.children)
            default:
                if Self.skipTags.contains(n.tag) { return [] }
                return blocks(from: n.children)
            }
        }

        private func list(_ n: DocHTMLNode) -> DocBlock {
            var items: [DocListItem] = []
            var tight = true
            for c in n.children where !c.isText && c.tag == "li" {
                var inner = c.children
                var checked: Bool?
                if let first = inner.first(where: { !$0.isText || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), first.tag == "input", (first.attributes["type"] ?? "") == "checkbox" {
                    checked = first.attributes["checked"] != nil
                    inner.removeAll { $0 === first }
                }
                if inner.contains(where: { $0.tag == "p" }) { tight = false }
                items.append(DocListItem(blocks: blocks(from: inner), checked: checked))
            }
            let start = Int(n.attributes["start"] ?? "") ?? 1
            return .list(DocList(ordered: n.tag == "ol", start: start, tight: tight, items: items))
        }

        private func code(_ n: DocHTMLNode) -> DocBlock {
            var lang: String?
            if let c = n.firstDescendant("code") ?? (n.classes.isEmpty ? nil : n) {
                for cls in c.classes where cls.hasPrefix("language-") { lang = String(cls.dropFirst(9)) }
                if lang == nil, let l = c.classes.first(where: { $0 != "sourceCode" && $0 != "highlight" }), n.firstDescendant("code") != nil { lang = l }
            }
            var text = n.textContent
            if text.hasPrefix("\n") { text.removeFirst() }
            while text.hasSuffix("\n") { text.removeLast() }
            return .code(language: lang, text: text)
        }

        private func table(_ n: DocHTMLNode) -> DocBlock? {
            var rowNodes: [(DocHTMLNode, inHead: Bool)] = []
            func collect(_ node: DocHTMLNode, head: Bool) {
                for c in node.children where !c.isText {
                    switch c.tag {
                    case "tr": rowNodes.append((c, head))
                    case "thead": collect(c, head: true)
                    case "tbody", "tfoot": collect(c, head: false)
                    default: break
                    }
                }
            }
            collect(n, head: false)
            guard !rowNodes.isEmpty else { return nil }
            func cells(_ tr: DocHTMLNode) -> [(inlines: [DocInline], header: Bool, align: DocAlign)] {
                tr.children.filter { !$0.isText && ($0.tag == "td" || $0.tag == "th") }.map { c in
                    let st = style(of: c)
                    let al = DocAlign(rawValue: (c.attributes["align"] ?? "").lowercased()) ?? st.align ?? .none
                    return (cellInlines(c), c.tag == "th", al)
                }
            }
            let parsed = rowNodes.map { (cells($0.0), $0.inHead) }
            var header: [[DocInline]]?
            var body: [[[DocInline]]] = []
            var aligns: [DocAlign] = []
            for (k, (row, inHead)) in parsed.enumerated() {
                if row.isEmpty { continue }
                if k == 0, inHead || row.allSatisfy({ $0.header }) { header = row.map(\.inlines); aligns = row.map(\.align); continue }
                if header == nil, aligns.isEmpty { aligns = row.map(\.align) }
                body.append(row.map(\.inlines))
            }
            if header == nil && body.isEmpty { return nil }
            // A first row that is bold in every cell while the next row is not is a header row (textutil and Word write no <th>).
            if header == nil, body.count >= 2, let first = body.first, let plain = Self.unboldedRow(first), !body[1].allSatisfy({ Self.unboldedRow([$0]) != nil }) {
                header = plain
                body.removeFirst()
            }
            let cols = max(header?.count ?? 0, body.map(\.count).max() ?? 0)
            while aligns.count < cols { aligns.append(.none) }
            return .table(DocTable(align: aligns, header: header.map { pad($0, cols) }, rows: body.map { pad($0, cols) }))
        }

        /// The cells of a row with the bold removed, when every cell is nothing but bold text; nil otherwise.
        static func unboldedRow(_ row: [[DocInline]]) -> [[DocInline]]? {
            var out: [[DocInline]] = []
            for cell in row {
                guard !cell.isBlank else { return nil }
                guard let plain = cell.unbolded() else { return nil }
                out.append(plain)
            }
            return out
        }

        private func pad(_ r: [[DocInline]], _ n: Int) -> [[DocInline]] { r.count >= n ? r : r + Array(repeating: [], count: n - r.count) }

        /// Table cell content flattened to inlines (paragraphs inside become line breaks).
        private func cellInlines(_ c: DocHTMLNode) -> [DocInline] {
            var out: [DocInline] = []
            var run: [DocHTMLNode] = []
            func flush() { let i = inlines(from: run); run = []; if !i.isBlank { if !out.isEmpty { out.append(.lineBreak) }; out += i } }
            for ch in c.children {
                if isBlock(ch) && !ch.isText {
                    flush()
                    if ch.tag == "ul" || ch.tag == "ol" {
                        for li in ch.children where li.tag == "li" { let i = inlines(from: li.children); if !i.isBlank { if !out.isEmpty { out.append(.lineBreak) }; out.append(.text("• ")); out += i } }
                    } else { run = ch.children; flush() }
                } else { run.append(ch) }
            }
            flush()
            return out.normalized()
        }

        // MARK: Inlines

        private final class Builder {
            var lastWasSpace = true
        }

        func inlines(from nodes: [DocHTMLNode], preformatted: Bool = false) -> [DocInline] {
            let b = Builder()
            var out = convert(nodes, b, pre: preformatted)
            out = trim(out)
            return out.normalized()
        }

        private func trim(_ i: [DocInline]) -> [DocInline] {
            var out = i
            while case .text(let t)? = out.first, t.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty { out.removeFirst(); if out.isEmpty { break } }
            while case .text(let t)? = out.last, t.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty { out.removeLast(); if out.isEmpty { break } }
            if case .text(let t)? = out.first, t.hasPrefix(" ") { out[0] = .text(String(t.drop { $0 == " " })) }
            if case .text(let t)? = out.last, t.hasSuffix(" ") { out[out.count - 1] = .text(t.replacingOccurrences(of: " +$", with: "", options: .regularExpression)) }
            // Line breaks at the edges are noise.
            while case .lineBreak? = out.first { out.removeFirst() }
            while case .lineBreak? = out.last { out.removeLast() }
            return out
        }

        private func convert(_ nodes: [DocHTMLNode], _ b: Builder, pre: Bool) -> [DocInline] {
            var out: [DocInline] = []
            for n in nodes {
                if n.isText {
                    if pre { out.append(.text(n.text)); b.lastWasSpace = n.text.hasSuffix(" ") || n.text.hasSuffix("\n"); continue }
                    var t = n.text.replacingOccurrences(of: "[ \\t\\r\\n\\f]+", with: " ", options: .regularExpression)
                    if t.hasPrefix(" "), b.lastWasSpace { t.removeFirst() }
                    if t.isEmpty { continue }
                    b.lastWasSpace = t.hasSuffix(" ")
                    out.append(.text(t))
                    continue
                }
                if Self.skipTags.contains(n.tag) { continue }
                switch n.tag {
                case "br": out.append(.lineBreak); b.lastWasSpace = true
                case "wbr": break
                case "img":
                    let src = n.attributes["src"] ?? ""
                    guard !src.isEmpty else { break }
                    out.append(.image(src: resolveDataURI(src, name: n.attributes["alt"]), alt: n.attributes["alt"] ?? "", title: n.attributes["title"]))
                    b.lastWasSpace = false
                case "a":
                    let inner = wrapStyle(n, convert(n.children, b, pre: pre))
                    if let href = n.attributes["href"], !href.isEmpty, !inner.isBlank { out.append(.link(url: href, title: n.attributes["title"], content: inner)) } else { out += inner }
                case "input":
                    break
                case "code", "tt", "kbd", "samp":
                    out.append(.code(n.textContent)); b.lastWasSpace = false
                case "pre":
                    out += convert(n.children, b, pre: true)
                default:
                    var inner = convert(n.children, b, pre: pre)
                    switch n.tag {
                    case "b", "strong": inner = [.strong(inner)]
                    case "i", "em", "cite", "dfn", "var": inner = [.emphasis(inner)]
                    case "u", "ins": inner = [.underline(inner)]
                    case "s", "strike", "del": inner = [.strike(inner)]
                    default: break
                    }
                    out += wrapStyle(n, inner)
                    if isBlock(n) { out.append(.lineBreak) }
                }
            }
            return out
        }

        /// Applies CSS-derived emphasis (class rules / style attribute) on top of the semantic tag.
        private func wrapStyle(_ n: DocHTMLNode, _ inner: [DocInline]) -> [DocInline] {
            guard !inner.isEmpty else { return inner }
            let semantic: Set<String> = ["b", "strong", "i", "em", "u", "ins", "s", "strike", "del"]
            let st = style(of: n)
            var r = inner
            if st.mono == true, !(r.count == 1 && { if case .code = r[0] { return true } else { return false } }()) { r = [.code(r.plainText)] }
            if st.bold == true, !semantic.contains(n.tag) || (n.tag != "b" && n.tag != "strong") { r = [.strong(r)] }
            if st.italic == true, n.tag != "i", n.tag != "em" { r = [.emphasis(r)] }
            if st.underline == true, n.tag != "u", n.tag != "ins", n.tag != "a" { r = [.underline(r)] }
            if st.strike == true, !["s", "strike", "del"].contains(n.tag) { r = [.strike(r)] }
            return r
        }

        /// `data:image/png;base64,...` -> media key; anything else is returned unchanged.
        private func resolveDataURI(_ src: String, name: String?) -> String {
            guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return src }
            let header = src[src.startIndex..<comma]
            let payload = String(src[src.index(after: comma)...])
            let data: Data?
            if header.contains(";base64") { data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters) }
            else { data = payload.removingPercentEncoding.flatMap { $0.data(using: .utf8) } }
            guard let d = data, !d.isEmpty else { return src }
            return media.add(d, suggestedName: "image")
        }
    }
}
