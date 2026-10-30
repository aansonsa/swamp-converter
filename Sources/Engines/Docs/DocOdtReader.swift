import Foundation

// ODT -> DocModel. Reads content.xml (headings, paragraphs, nested lists with their list styles, tables with header rows and spans, pictures, links) and the named and
// automatic styles that decide bold / italic / underline / strike / monospace, code and quote paragraphs and cell alignment. Headers, footers, notes and frames
// other than pictures are left out.

enum DocOdtReader {
    static func read(_ url: URL) throws -> DocModel {
        let pkg = try DocPackage.Reader(url: url)
        guard let content = try pkg.xml("content.xml") else {
            throw ConversionError.message(L10n("This is not an OpenDocument text file (no content part).", "Это не текстовый файл OpenDocument (нет части content)."))
        }
        let state = State(pkg: pkg)
        state.loadStyles(try pkg.xml("styles.xml"))
        state.loadStyles(content)
        var model = DocModel()
        if let text = content.child("office:body")?.child("office:text") { model.blocks = state.blocks(text.elements) }
        model.media = state.media.items
        if let meta = try pkg.xml("meta.xml")?.child("office:meta") {
            model.meta.title = meta.child("dc:title")?.textContent.nonEmpty
            model.meta.author = (meta.child("dc:creator") ?? meta.child("meta:initial-creator"))?.textContent.nonEmpty
            model.meta.language = meta.child("dc:language")?.textContent.nonEmpty
            model.meta.created = DocXML.parseISODate(meta.child("meta:creation-date")?.textContent)
            model.meta.modified = DocXML.parseISODate(meta.child("dc:date")?.textContent)
        }
        return model
    }

    struct Style {
        var parent: String?
        var bold = false, italic = false, underline = false, strike = false, mono = false
        var align: DocAlign?
        var displayName = ""
    }

    final class State {
        let pkg: DocPackage.Reader
        var media = DocMediaStore()
        var styles: [String: Style] = [:]
        /// list style name -> level (1-based) -> (ordered, start)
        var listStyles: [String: [Int: (ordered: Bool, start: Int)]] = [:]
        private var imageCache: [String: String] = [:]

        init(pkg: DocPackage.Reader) { self.pkg = pkg }

        // MARK: Styles

        func loadStyles(_ root: DocXMLNode?) {
            guard let root else { return }
            for group in ["office:styles", "office:automatic-styles"] {
                guard let g = root.child(group) else { continue }
                for s in g.children("style:style") {
                    guard let name = s["style:name"] else { continue }
                    var st = Style(parent: s["style:parent-style-name"])
                    st.displayName = s["style:display-name"] ?? name
                    if let tp = s.child("style:text-properties") {
                        let weight = tp["fo:font-weight"] ?? ""
                        st.bold = weight == "bold" || (Int(weight) ?? 0) >= 600
                        st.italic = ["italic", "oblique"].contains(tp["fo:font-style"] ?? "")
                        st.underline = (tp["style:text-underline-style"] ?? "none") != "none"
                        st.strike = (tp["style:text-line-through-style"] ?? "none") != "none"
                        let family = ((tp["fo:font-family"] ?? "") + " " + (tp["style:font-name"] ?? "")).lowercased()
                        st.mono = DocDocxReader.Reader.monoFonts.contains { family.contains($0) } || family.contains("monospace")
                    }
                    if let pp = s.child("style:paragraph-properties"), let a = pp["fo:text-align"] {
                        st.align = a == "end" || a == "right" ? .right : (a == "center" ? .center : (a == "start" || a == "left" ? .left : nil))
                    }
                    styles[name] = st
                }
                for ls in g.children("text:list-style") {
                    guard let name = ls["style:name"] else { continue }
                    var levels: [Int: (Bool, Int)] = [:]
                    for l in ls.elements {
                        guard let lvl = l["text:level"].flatMap(Int.init) else { continue }
                        if l.name == "text:list-level-style-number" { levels[lvl] = (true, l["text:start-value"].flatMap(Int.init) ?? 1) }
                        else if l.name == "text:list-level-style-bullet" || l.name == "text:list-level-style-image" { levels[lvl] = (false, 1) }
                    }
                    listStyles[name] = levels
                }
            }
        }

        private func chain(_ name: String?) -> [Style] {
            var out: [Style] = []
            var cur = name
            var n = 0
            while let c = cur, let s = styles[c], n < 12 { out.append(s); cur = s.parent; n += 1 }
            return out
        }

        func isCodeStyle(_ name: String?) -> Bool {
            chain(name).contains { s in
                let n = s.displayName.lowercased()
                return n.contains("preformatted") || n.contains("source code") || n == "code" || n.contains("code block")
            }
        }

        func isQuoteStyle(_ name: String?) -> Bool {
            chain(name).contains { s in let n = s.displayName.lowercased(); return n == "quotations" || n == "quote" || n == "block quotation" || n == "intense quote" }
        }

        func headingLevel(fromStyle name: String?) -> Int? {
            for s in chain(name) {
                let n = s.displayName.lowercased()
                if n == "title" { return 1 }
                if n.hasPrefix("heading "), let l = Int(n.dropFirst(8)) { return min(max(l, 1), 6) }
            }
            return nil
        }

        // MARK: Blocks

        func blocks(_ nodes: [DocXMLNode]) -> [DocBlock] {
            var out: [DocBlock] = []
            var code: [String] = []
            func flushCode() {
                guard !code.isEmpty else { return }
                while code.last == "" { code.removeLast() }
                if !code.isEmpty { out.append(.code(language: nil, text: code.joined(separator: "\n"))) }
                code = []
            }
            for n in nodes {
                switch n.name {
                case "text:h":
                    flushCode()
                    let c = inlines(n.content)
                    let level = min(max(n["text:outline-level"].flatMap(Int.init) ?? 1, 1), 6)
                    if !c.isBlank { out.append(.heading(level: level, content: c)) }
                case "text:p":
                    let style = n["text:style-name"]
                    if isCodeStyle(style) {
                        code.append(inlines(n.content).plainText)
                        continue
                    }
                    flushCode()
                    let c = inlines(n.content)
                    if let level = headingLevel(fromStyle: style), !c.isBlank { out.append(.heading(level: level, content: c)); continue }
                    if c.isBlank { continue }
                    if isQuoteStyle(style) {
                        if case .quote(let prev)? = out.last { out[out.count - 1] = .quote(prev + [.paragraph(c)]) } else { out.append(.quote([.paragraph(c)])) }
                    } else { out.append(.paragraph(c)) }
                case "text:list":
                    flushCode()
                    out.append(list(n, level: 1, inherited: nil))
                case "table:table":
                    flushCode()
                    if let t = table(n) { out.append(.table(t)) }
                case "text:section", "text:table-of-content", "text:index-body", "text:alphabetical-index", "text:bibliography":
                    flushCode()
                    out += blocks(n.elements.filter { $0.name != "text:index-title" })
                default: break
                }
            }
            flushCode()
            return out
        }

        private func list(_ n: DocXMLNode, level: Int, inherited: String?) -> DocBlock {
            let styleName = n["text:style-name"] ?? inherited
            let spec = styleName.flatMap { listStyles[$0]?[level] }
            var items: [DocListItem] = []
            var start = spec?.start ?? 1
            for (idx, li) in n.elements.enumerated() where li.name == "text:list-item" || li.name == "text:list-header" {
                if idx == 0, let sv = li["text:start-value"].flatMap(Int.init) { start = sv }
                var blocks: [DocBlock] = []
                for child in li.elements {
                    switch child.name {
                    case "text:list": blocks.append(list(child, level: level + 1, inherited: styleName))
                    default: blocks += self.blocks([child])
                    }
                }
                items.append(DocListItem(blocks: blocks))
            }
            return .list(DocList(ordered: spec?.ordered ?? false, start: start, items: items))
        }

        private func table(_ t: DocXMLNode) -> DocTable? {
            var headerRows: [[[DocInline]]] = []
            var bodyRows: [[[DocInline]]] = []
            var aligns: [DocAlign] = []
            func rowCells(_ tr: DocXMLNode, collectAlign: Bool) -> [[DocInline]] {
                var cells: [[DocInline]] = []
                for c in tr.elements where c.name == "table:table-cell" || c.name == "table:covered-table-cell" {
                    var content: [DocInline] = []
                    var align = DocAlign.none
                    for p in c.elements {
                        if p.name == "text:p" || p.name == "text:h" {
                            let inl = inlines(p.content)
                            if inl.isBlank { continue }
                            if align == .none, let a = chain(p["text:style-name"]).compactMap(\.align).first { align = a }
                            if !content.isEmpty { content.append(.lineBreak) }
                            content += inl
                        } else if p.name == "text:list" {
                            for item in p.descendants("text:p") {
                                let inl = inlines(item.content)
                                if inl.isBlank { continue }
                                if !content.isEmpty { content.append(.lineBreak) }
                                content.append(.text("• ")); content += inl
                            }
                        }
                    }
                    let repeated = min(c["table:number-columns-repeated"].flatMap(Int.init) ?? 1, 64)
                    let spanned = min(c["table:number-columns-spanned"].flatMap(Int.init) ?? 1, 64)
                    cells.append(content.normalized())
                    if collectAlign { aligns.append(align) }
                    for _ in 1..<max(1, repeated) { cells.append(content.normalized()); if collectAlign { aligns.append(align) } }
                    if spanned > 1 && c.name == "table:table-cell" { for _ in 1..<spanned { cells.append([]); if collectAlign { aligns.append(.none) } } }
                }
                return cells
            }
            func visit(_ node: DocXMLNode, header: Bool) {
                for r in node.elements {
                    switch r.name {
                    case "table:table-row":
                        let repeats = min(r["table:number-rows-repeated"].flatMap(Int.init) ?? 1, 200)
                        let cells = rowCells(r, collectAlign: !header && bodyRows.isEmpty)
                        if cells.allSatisfy({ $0.isEmpty }), repeats > 20 { continue }       // trailing blank rows of a spreadsheet-like table
                        for _ in 0..<repeats { if header { headerRows.append(cells) } else { bodyRows.append(cells) } }
                    case "table:table-header-rows": visit(r, header: true)
                    case "table:table-row-group", "table:table-rows": visit(r, header: header)
                    default: break
                    }
                }
            }
            visit(t, header: false)
            let all = headerRows + bodyRows
            guard !all.isEmpty else { return nil }
            let cols = all.map(\.count).max() ?? 1
            func pad(_ r: [[DocInline]]) -> [[DocInline]] { r.count >= cols ? r : r + Array(repeating: [], count: cols - r.count) }
            while aligns.count < cols { aligns.append(.none) }
            return DocTable(align: Array(aligns.prefix(cols)), header: headerRows.first.map(pad)?.map { $0.unbolded() ?? $0 }, rows: (headerRows.dropFirst() + bodyRows).map(pad))
        }

        // MARK: Inlines

        func inlines(_ content: [DocXMLChild]) -> [DocInline] {
            var out: [DocInline] = []
            for c in content {
                switch c {
                case .text(let t):
                    let collapsed = t.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
                    if !collapsed.isEmpty { out.append(.text(collapsed)) }
                case .element(let e):
                    switch e.name {
                    case "text:span":
                        let st = chain(e["text:style-name"])
                        var inner = inlines(e.content)
                        if inner.isEmpty { continue }
                        if st.contains(where: \.mono) { inner = [.code(inner.plainText)] }
                        if st.contains(where: \.bold) { inner = [.strong(inner)] }
                        if st.contains(where: \.italic) { inner = [.emphasis(inner)] }
                        if st.contains(where: \.strike) { inner = [.strike(inner)] }
                        if st.contains(where: \.underline) { inner = [.underline(inner)] }
                        out += inner
                    case "text:a":
                        let inner = inlines(e.content)
                        let href = e["xlink:href"] ?? ""
                        if href.isEmpty || inner.isBlank { out += inner } else { out.append(.link(url: href, title: e["office:title"], content: inner)) }
                    case "text:s": out.append(.text(String(repeating: " ", count: min(e["text:c"].flatMap(Int.init) ?? 1, 1000))))
                    case "text:tab": out.append(.text("\t"))
                    case "text:line-break": out.append(.lineBreak)
                    case "draw:frame":
                        if let img = e.child("draw:image"), let href = img["xlink:href"], let key = picture(href) {
                            out.append(.image(src: key, alt: e.child("svg:desc")?.textContent ?? e.child("svg:title")?.textContent ?? "", title: nil))
                        }
                    case "text:note", "text:bookmark", "text:bookmark-start", "text:bookmark-end", "text:soft-page-break", "office:annotation", "text:tracked-changes": break
                    case "text:change-start", "text:change-end", "text:change": break
                    default: out += inlines(e.content)
                    }
                }
            }
            return out.normalized()
        }

        private func picture(_ href: String) -> String? {
            if let k = imageCache[href] { return k }
            let path = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
            guard !path.hasPrefix("http"), let data = try? pkg.data(path, limit: 200_000_000), !data.isEmpty else { return nil }
            let key = media.add(data, suggestedName: (path as NSString).lastPathComponent)
            imageCache[href] = key
            return key
        }
    }
}
