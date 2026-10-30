import Foundation

// The body of a DOCX: paragraphs, headings, lists (numbering.xml), tables, hyperlinks (including field codes), pictures and run formatting.
// `BlockCollector` turns the flat paragraph stream into nested lists, merged code blocks and merged quotes.

/// Collects blocks while the reader walks the body. List paragraphs are kept flat until a non-list block arrives and are then nested by level.
final class BlockCollector {
    struct ListEntry { var numId: Int; var level: Int; var ordered: Bool; var start: Int; var content: [DocInline] }

    private let reader: DocDocxReader.Reader
    private(set) var blocks: [DocBlock] = []
    private var listRun: [ListEntry] = []
    private var codeLines: [String] = []
    private var quoteRun: [DocBlock] = []

    init(reader: DocDocxReader.Reader) { self.reader = reader }

    func add(_ block: DocBlock) { flushPending(); blocks.append(block) }

    func addList(_ entry: ListEntry) { flushCode(); flushQuote(); listRun.append(entry) }

    func addCodeLine(_ line: String) { flushList(); flushQuote(); codeLines.append(line) }

    func addQuote(_ block: DocBlock) { flushList(); flushCode(); quoteRun.append(block) }

    func finish() -> [DocBlock] { flushPending(); return blocks }

    private func flushPending() { flushList(); flushCode(); flushQuote() }

    private func flushCode() {
        guard !codeLines.isEmpty else { return }
        while codeLines.last?.isEmpty == true { codeLines.removeLast() }
        if !codeLines.isEmpty { blocks.append(.code(language: nil, text: codeLines.joined(separator: "\n"))) }
        codeLines = []
    }

    private func flushQuote() {
        guard !quoteRun.isEmpty else { return }
        blocks.append(.quote(quoteRun))
        quoteRun = []
    }

    private func flushList() {
        guard !listRun.isEmpty else { return }
        let entries = listRun
        listRun = []
        var i = 0
        while i < entries.count { blocks.append(.list(Self.build(entries, &i, level: entries[i].level))) }
    }

    /// Nests flat entries: a deeper level becomes a list inside the previous item; a change of list type or of list id at the same level ends the list.
    private static func build(_ entries: [ListEntry], _ i: inout Int, level: Int) -> DocList {
        let first = entries[i]
        var list = DocList(ordered: first.ordered, start: first.start, items: [])
        while i < entries.count {
            let e = entries[i]
            if e.level < level { break }
            if e.level > level {
                let nested = build(entries, &i, level: e.level)
                if list.items.isEmpty { list.items.append(DocListItem(blocks: [])) }
                list.items[list.items.count - 1].blocks.append(.list(nested))
                continue
            }
            if e.ordered != list.ordered || (e.numId != first.numId && !list.items.isEmpty) { break }
            list.items.append(DocListItem(blocks: [.paragraph(e.content)]))
            i += 1
        }
        return list
    }
}

/// Inline output with a stack for complex fields (`fldChar` begin / separate / end), so a HYPERLINK field wraps the runs between separate and end.
private final class InlineSink {
    struct Field { var instruction = ""; var separated = false }
    var layers: [[DocInline]] = [[]]
    var fields: [Field] = []

    func add(_ i: DocInline) { layers[layers.count - 1].append(i) }
    func begin() { fields.append(Field()); layers.append([]) }
    func instruction(_ t: String) { if !fields.isEmpty, !fields[fields.count - 1].separated { fields[fields.count - 1].instruction += t } }
    func separate() { if !fields.isEmpty { fields[fields.count - 1].separated = true } }
    func end() {
        guard let f = fields.popLast(), layers.count > 1 else { return }
        let content = layers.removeLast()
        let instr = f.instruction.trimmingCharacters(in: .whitespaces)
        if instr.uppercased().hasPrefix("HYPERLINK"), let url = Self.target(of: instr), !content.isBlank {
            add(.link(url: url, title: nil, content: content))
        } else {
            layers[layers.count - 1] += content
        }
    }
    var result: [DocInline] {
        while layers.count > 1 { end() }
        return layers[0]
    }
    private static func target(of instr: String) -> String? {
        if let r = instr.range(of: "\"[^\"]+\"", options: .regularExpression) { return String(instr[r].dropFirst().dropLast()) }
        let parts = instr.split(separator: " ")
        if parts.count >= 2, parts[1] != "\\l" { return String(parts[1]) }
        return nil
    }
}

extension DocDocxReader.Reader {
    func attribute(_ n: DocXMLNode, ending suffix: String) -> String? {
        n.attributes.first { $0.key == suffix || $0.key.hasSuffix(":" + suffix) }?.value
    }

    // MARK: Walking

    func collect(_ container: DocXMLNode, into c: BlockCollector) throws {
        for child in container.elements {
            try Task.checkCancellation()
            switch child.name {
            case "w:p": paragraph(child, into: c)
            case "w:tbl": if let t = table(child) { c.add(.table(t)) }
            case "w:sdt": if let content = child.child("w:sdtContent") { try collect(content, into: c) }
            case "w:ins", "w:customXml", "w:smartTag", "w:moveTo": try collect(child, into: c)
            default: break
            }
        }
    }

    // MARK: Paragraphs

    private func paragraph(_ p: DocXMLNode, into c: BlockCollector) {
        let ppr = p.child("w:pPr")
        let styleID = ppr?.child("w:pStyle")?["w:val"]
        let sink = InlineSink()
        var pageBreak = false
        var allMono = true, anyText = false
        para = DocDocxReader.ParaStats()
        paragraphHalfPoints = styleChain(styleID).compactMap(\.halfPoints).first
        runs(of: p, sink: sink, style: RunContext(), pageBreak: &pageBreak, allMono: &allMono, anyText: &anyText)
        let stats = para
        let content = sink.result.normalized()
        if ppr?.child("w:pageBreakBefore") != nil { c.add(.pageBreak) }
        if pageBreak && content.isBlank { c.add(.pageBreak); return }
        let kind = styleKind(styleID)
        // Headings (style name or outline level).
        let outline = ppr?.child("w:outlineLvl")?["w:val"].flatMap(Int.init)
        if let level = headingLevel(styleID: styleID, outline: outline) {
            if !content.isBlank { c.add(.heading(level: level, content: content.stripped(of: .strong))) }
            return
        }
        // Lists (direct numPr, numbering inherited from the style, or the List Bullet / List Number styles).
        var numId: Int?, level = 0
        if let np = ppr?.child("w:numPr") {
            numId = np.child("w:numId")?["w:val"].flatMap(Int.init)
            level = np.child("w:ilvl")?["w:val"].flatMap(Int.init) ?? 0
        } else if let inherited = inheritedNumbering(styleID) { numId = inherited.0; level = inherited.1 }
        // Direct formatting: a short, fully bold line that is clearly larger than the body text is a heading even without a heading style.
        if numId == nil || numId == 0, stats.anyText, stats.allBold, stats.maxHalfPoints > 0, !content.isBlank, ppr?.child("w:numPr") == nil,
           Double(stats.maxHalfPoints) >= Double(bodyHalfPoints) * 1.08, content.plainText.count <= 120, !content.plainText.hasSuffix(".") {
            let ratio = Double(stats.maxHalfPoints) / Double(bodyHalfPoints)
            c.add(.heading(level: ratio >= 1.75 ? 1 : (ratio >= 1.33 ? 2 : 3), content: content.stripped(of: .strong)))
            return
        }
        if let n = numId, n != 0, !content.isBlank {
            let info = listInfo(numId: n, level: level)
            c.addList(.init(numId: n, level: level, ordered: info.ordered, start: info.start, content: content))
            return
        }
        if numId == nil, let lb = kind.listBullet, !content.isBlank { c.addList(.init(numId: -1, level: lb, ordered: false, start: 1, content: content)); return }
        if numId == nil, let ln = kind.listNumber, !content.isBlank { c.addList(.init(numId: -2, level: ln, ordered: true, start: 1, content: content)); return }
        // Code: a code style, or every run in a monospaced font.
        if kind.code || (anyText && allMono && !content.isBlank) {
            c.addCodeLine(content.plainText)
            return
        }
        if content.isBlank {
            if kind.code { c.addCodeLine("") }
            return
        }
        if kind.quote { c.addQuote(.paragraph(content)); return }
        c.add(.paragraph(content))
    }

    // MARK: Runs

    struct RunContext { var inHyperlinkStyle = false }

    private func runs(of container: DocXMLNode, sink: InlineSink, style ctx: RunContext, pageBreak: inout Bool, allMono: inout Bool, anyText: inout Bool) {
        for node in container.elements {
            switch node.name {
            case "w:r": run(node, sink: sink, pageBreak: &pageBreak, allMono: &allMono, anyText: &anyText)
            case "w:hyperlink":
                let sub = InlineSink()
                runs(of: node, sink: sub, style: ctx, pageBreak: &pageBreak, allMono: &allMono, anyText: &anyText)
                let inner = sub.result
                var url: String?
                if let rid = attribute(node, ending: "id"), let rel = rels[rid] { url = rel.target }
                else if let anchor = node["w:anchor"] { url = "#" + anchor }
                if let u = url, !inner.isBlank { sink.add(.link(url: u, title: nil, content: inner)) } else { inner.forEach { sink.add($0) } }
            case "w:fldSimple":
                let sub = InlineSink()
                runs(of: node, sink: sub, style: ctx, pageBreak: &pageBreak, allMono: &allMono, anyText: &anyText)
                let inner = sub.result
                let instr = (node["w:instr"] ?? "").trimmingCharacters(in: .whitespaces)
                if instr.uppercased().hasPrefix("HYPERLINK"), let r = instr.range(of: "\"[^\"]+\"", options: .regularExpression), !inner.isBlank {
                    sink.add(.link(url: String(instr[r].dropFirst().dropLast()), title: nil, content: inner))
                } else { inner.forEach { sink.add($0) } }
            case "w:ins", "w:smartTag", "w:sdt", "w:sdtContent", "w:customXml", "w:moveTo":
                runs(of: node, sink: sink, style: ctx, pageBreak: &pageBreak, allMono: &allMono, anyText: &anyText)
            default: break      // w:del, w:moveFrom, bookmarks, proofing marks, comments ...
            }
        }
    }

    private func run(_ r: DocXMLNode, sink: InlineSink, pageBreak: inout Bool, allMono: inout Bool, anyText: inout Bool) {
        let props = runProps(r.child("w:rPr"))
        if props.hidden { return }
        let isHyperlinkStyle = (r.child("w:rPr")?.child("w:rStyle")?["w:val"] ?? "").lowercased().contains("hyperlink")
        var text = ""
        func flushText() {
            guard !text.isEmpty else { return }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                anyText = true; if !props.mono { allMono = false }
                para.anyText = true
                if !props.bold { para.allBold = false }
                para.maxHalfPoints = max(para.maxHalfPoints, props.halfPoints ?? paragraphHalfPoints ?? bodyHalfPoints)
            }
            sink.add(styled(text, props, isHyperlinkStyle: isHyperlinkStyle))
            text = ""
        }
        for n in r.elements {
            switch n.name {
            case "w:t": text += n.textContent
            case "w:tab": text += "\t"
            case "w:noBreakHyphen": text += "-"
            case "w:softHyphen": break
            case "w:sym": if let c = n["w:char"], let v = UInt32(c, radix: 16), let u = Unicode.Scalar(v & 0xFFFF) { text.unicodeScalars.append(u) }
            case "w:br", "w:cr":
                if n["w:type"] == "page" { flushText(); pageBreak = true } else { flushText(); sink.add(.lineBreak) }
            case "w:fldChar":
                flushText()
                switch n["w:fldCharType"] ?? "" {
                case "begin": sink.begin()
                case "separate": sink.separate()
                case "end": sink.end()
                default: break
                }
            case "w:instrText": sink.instruction(n.textContent)
            case "w:drawing", "w:pict", "w:object":
                flushText()
                if let img = image(in: n) { sink.add(img); allMono = false }
            case "mc:AlternateContent":
                flushText()
                if let choice = n.child("mc:Choice") ?? n.child("mc:Fallback"), let img = image(in: choice) { sink.add(img); allMono = false }
            default: break
            }
        }
        flushText()
    }

    private func styled(_ text: String, _ p: RunProps, isHyperlinkStyle: Bool) -> DocInline {
        var node: DocInline = p.mono ? .code(text) : .text(text)
        if p.bold { node = .strong([node]) }
        if p.italic { node = .emphasis([node]) }
        if p.strike { node = .strike([node]) }
        if p.underline && !isHyperlinkStyle { node = .underline([node]) }
        return node
    }

    /// The first picture below a drawing / pict element: `a:blip r:embed` (DrawingML) or `v:imagedata r:id` (VML).
    private func image(in node: DocXMLNode) -> DocInline? {
        var alt = ""
        if let pr = node.descendants("wp:docPr").first { alt = pr["descr"] ?? pr["title"] ?? pr["name"] ?? "" }
        if let blip = node.descendants("a:blip").first, let rid = attribute(blip, ending: "embed") ?? attribute(blip, ending: "link"), let key = picture(rid: rid) {
            return .image(src: key, alt: alt, title: nil)
        }
        if let vml = node.descendants("v:imagedata").first, let rid = attribute(vml, ending: "id"), let key = picture(rid: rid) {
            return .image(src: key, alt: vml["o:title"] ?? alt, title: nil)
        }
        return nil
    }

    // MARK: Tables

    private func table(_ t: DocXMLNode) -> DocTable? {
        var rows: [(cells: [[DocInline]], header: Bool, aligns: [DocAlign])] = []
        for tr in t.children("w:tr") {
            var cells: [[DocInline]] = [], aligns: [DocAlign] = []
            for tc in tr.children("w:tc") {
                let (inl, al) = cell(tc)
                cells.append(inl); aligns.append(al)
                if let span = tc.child("w:tcPr")?.child("w:gridSpan")?["w:val"].flatMap(Int.init), span > 1 {
                    for _ in 1..<min(span, 64) { cells.append([]); aligns.append(.none) }
                }
            }
            if cells.isEmpty { continue }
            rows.append((cells, tr.child("w:trPr")?.child("w:tblHeader") != nil, aligns))
        }
        guard !rows.isEmpty else { return nil }
        let cols = rows.map { $0.cells.count }.max() ?? 1
        func pad(_ r: [[DocInline]]) -> [[DocInline]] { r.count >= cols ? r : r + Array(repeating: [], count: cols - r.count) }
        var header: [[DocInline]]?
        var body = rows
        if rows[0].header { header = pad(rows[0].cells).map { $0.unbolded() ?? $0 }; body.removeFirst() }
        var aligns = (body.first ?? rows[0]).aligns
        while aligns.count < cols { aligns.append(.none) }
        return DocTable(align: Array(aligns.prefix(cols)), header: header, rows: body.map { pad($0.cells) })
    }

    /// A table cell flattened to inlines: paragraphs are separated by line breaks, nested tables contribute their text.
    private func cell(_ tc: DocXMLNode) -> ([DocInline], DocAlign) {
        var out: [DocInline] = []
        var align = DocAlign.none
        func addParagraphs(_ container: DocXMLNode) {
            for n in container.elements {
                switch n.name {
                case "w:p":
                    let sink = InlineSink()
                    var pb = false, mono = true, any = false
                    runs(of: n, sink: sink, style: RunContext(), pageBreak: &pb, allMono: &mono, anyText: &any)
                    let inl = sink.result.normalized()
                    if inl.isBlank { continue }
                    if align == .none, let jc = n.child("w:pPr")?.child("w:jc")?["w:val"] {
                        align = jc == "center" ? .center : (jc == "right" || jc == "end" ? .right : (jc == "left" || jc == "start" ? .left : .none))
                    }
                    if !out.isEmpty { out.append(.lineBreak) }
                    out += inl
                case "w:tbl":
                    for row in n.children("w:tr") { for c in row.children("w:tc") { addParagraphs(c) } }
                case "w:sdt": if let content = n.child("w:sdtContent") { addParagraphs(content) }
                default: break
                }
            }
        }
        addParagraphs(tc)
        return (out.normalized(), align)
    }
}

extension Array where Element == DocInline {
    /// Headings are bold by style in many documents: the bold wrapper adds nothing in Markdown / HTML (the heading already is strong), so it is removed when it covers everything.
    func stripped(of kind: Strippable) -> [DocInline] {
        guard count == 1 else { return self }
        switch (self[0], kind) {
        case (.strong(let inner), .strong): return inner
        default: return self
        }
    }
    enum Strippable { case strong }
}
