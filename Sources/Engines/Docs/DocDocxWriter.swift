import Foundation

// DocModel -> DOCX (WordprocessingML). Written by hand rather than through NSAttributedString because the system writer drops tables, lists, hyperlinks, pictures and
// heading styles (spec/platform.md 5.1). Headings use the real Heading1..6 styles, lists use numbering.xml (bullets and restartable decimals), tables use a grid style
// with a repeating header row, pictures are embedded as DrawingML.

enum DocDocxWriter {
    struct Options {
        var page = DocPageSetup(size: "a4", marginMillimetres: 25)
        var includeAuthorAndTitle = true
        var includeDates = true
        var font = "Calibri"
        var fontSize = 11.0
        var lineSpacing = 1.15
    }

    static func write(_ model: DocModel, options: Options = Options(), to url: URL) throws {
        var b = Builder(model: model, options: options)
        let body = try b.body()
        let parts = b.packageParts(body: body)
        try DocPackage.write(parts, to: url)
    }

    // MARK: Builder

    struct RunStyle {
        var bold = false, italic = false, underline = false, strike = false, code = false, link = false
    }

    struct Builder {
        let model: DocModel
        let o: Options
        var rels: [(id: String, type: String, target: String, external: Bool)] = []
        var mediaParts: [DocPackage.Part] = []
        var mediaIDs: [String: (rid: String, name: String)] = [:]
        var orderedLists: [(numId: Int, start: Int, level: Int)] = []
        var nextRel = 10
        var nextDocPr = 1
        var usedExtensions: Set<String> = []

        init(model: DocModel, options: Options) { self.model = model; self.o = options }

        mutating func rel(type: String, target: String, external: Bool) -> String {
            if let r = rels.first(where: { $0.type == type && $0.target == target && $0.external == external }) { return r.id }
            nextRel += 1
            let id = "rId\(nextRel)"
            rels.append((id, type, target, external))
            return id
        }

        // MARK: Body

        mutating func body() throws -> String {
            var xml = ""
            for b in model.blocks { try Task.checkCancellation(); xml += block(b, level: -1, quote: 0) }
            let p = o.page
            xml += "<w:sectPr><w:pgSz w:w=\"\(p.widthTwips)\" w:h=\"\(p.heightTwips)\"/><w:pgMar w:top=\"\(p.marginTwips)\" w:right=\"\(p.marginTwips)\" w:bottom=\"\(p.marginTwips)\" w:left=\"\(p.marginTwips)\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
            return xml
        }

        /// `level` >= 0 inside a list item (indent), `quote` = block-quote depth.
        mutating func block(_ b: DocBlock, level: Int, quote: Int, firstInItem: Bool = false) -> String {
            switch b {
            case .heading(let lv, let c):
                return para(style: "Heading\(max(1, min(6, lv)))", content: runs(c, RunStyle()), indent: level >= 0 ? (level + 1) * 720 : nil)
            case .paragraph(let c):
                if c.isBlank { return "" }
                var extra = ""
                let left = (level >= 0 ? (level + 1) * 720 : 0) + quote * 720
                if left > 0 { extra = "<w:ind w:left=\"\(left)\"/>" }
                return para(style: quote > 0 ? "Quote" : nil, content: runs(c, RunStyle()), extraPPr: extra)
            case .list(let l): return list(l, level: level + 1, quote: quote)
            case .quote(let inner):
                var out = ""
                for x in inner { out += block(x, level: level, quote: quote + 1) }
                return out
            case .code(_, let text):
                return text.components(separatedBy: "\n").map { line in
                    para(style: "CodeBlock", content: textRuns(line, RunStyle(code: true)))
                }.joined()
            case .table(let t): return table(t, quote: quote)
            case .rule:
                return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"999999\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"120\"/></w:pPr></w:p>"
            case .pageBreak: return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        func para(style: String?, content: String, extraPPr: String = "", indent: Int? = nil, numbering: (Int, Int)? = nil, align: DocAlign = .none, spacingAfter: Int? = nil) -> String {
            var ppr = ""
            if let s = style { ppr += "<w:pStyle w:val=\"\(s)\"/>" }
            if let (lvl, num) = numbering { ppr += "<w:numPr><w:ilvl w:val=\"\(lvl)\"/><w:numId w:val=\"\(num)\"/></w:numPr>" }
            if let a = spacingAfter { ppr += "<w:spacing w:after=\"\(a)\"/>" }
            if let i = indent { ppr += "<w:ind w:left=\"\(i)\"/>" }
            ppr += extraPPr
            switch align {
            case .center: ppr += "<w:jc w:val=\"center\"/>"
            case .right: ppr += "<w:jc w:val=\"right\"/>"
            case .left: ppr += "<w:jc w:val=\"left\"/>"
            case .none: break
            }
            return "<w:p>" + (ppr.isEmpty ? "" : "<w:pPr>\(ppr)</w:pPr>") + content + "</w:p>"
        }

        // MARK: Lists

        private mutating func list(_ l: DocList, level: Int, quote: Int) -> String {
            let lvl = min(level, 8)
            let numId: Int
            if l.ordered { numId = 100 + orderedLists.count; orderedLists.append((numId, l.start, lvl)) } else { numId = 1 }
            var out = ""
            for item in l.items {
                var first = true
                for b in item.blocks {
                    if first {
                        first = false
                        if case .paragraph(let c) = b {
                            var content = runs(c, RunStyle())
                            if let ch = item.checked { content = textRuns(ch ? "\u{2611} " : "\u{2610} ", RunStyle()) + content }
                            out += para(style: "ListParagraph", content: content, numbering: (lvl, numId))
                            continue
                        }
                        out += para(style: "ListParagraph", content: "", numbering: (lvl, numId))
                    }
                    out += block(b, level: lvl, quote: quote)
                }
                if first { out += para(style: "ListParagraph", content: "", numbering: (lvl, numId)) }
            }
            return out
        }

        // MARK: Tables

        private mutating func table(_ t: DocTable, quote: Int) -> String {
            let cols = max(1, t.columnCount)
            let width = Int(o.page.contentWidth * 20) - quote * 720
            let colW = max(400, width / cols)
            var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(colW * cols)\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>"
            xml += String(repeating: "<w:gridCol w:w=\"\(colW)\"/>", count: cols) + "</w:tblGrid>"
            func row(_ r: [[DocInline]], header: Bool) -> String {
                var s = "<w:tr>" + (header ? "<w:trPr><w:cantSplit/><w:tblHeader/></w:trPr>" : "<w:trPr><w:cantSplit/></w:trPr>")
                for i in 0..<cols {
                    let c = i < r.count ? r[i] : []
                    let al = i < t.align.count ? t.align[i] : DocAlign.none
                    s += "<w:tc><w:tcPr><w:tcW w:w=\"\(colW)\" w:type=\"dxa\"/>" + (header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" : "") + "</w:tcPr>"
                    s += para(style: nil, content: runs(c, RunStyle(bold: header)), align: al, spacingAfter: 0) + "</w:tc>"
                }
                return s + "</w:tr>"
            }
            if let h = t.header { xml += row(h, header: true) }
            for r in t.rows { xml += row(r, header: false) }
            // A table must be followed by a paragraph before the next table or the end of a cell.
            return xml + "</w:tbl>" + "<w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>"
        }

        // MARK: Runs

        private func rPr(_ st: RunStyle) -> String {
            var s = ""
            if st.link { s += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if st.code { s += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\" w:eastAsia=\"Menlo\"/><w:sz w:val=\"\(Int(o.fontSize * 2 * 0.9))\"/>" }
            if st.bold { s += "<w:b/><w:bCs/>" }
            if st.italic { s += "<w:i/><w:iCs/>" }
            if st.strike { s += "<w:strike/>" }
            if st.underline && !st.link { s += "<w:u w:val=\"single\"/>" }
            return s.isEmpty ? "" : "<w:rPr>\(s)</w:rPr>"
        }

        func textRuns(_ text: String, _ st: RunStyle) -> String {
            guard !text.isEmpty else { return "" }
            var out = ""
            let props = rPr(st)
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                out += "<w:r>\(props)<w:t xml:space=\"preserve\">\(DocXML.escape(current))</w:t></w:r>"
                current = ""
            }
            for ch in text {
                if ch == "\n" { flush(); out += "<w:r>\(props)<w:br/></w:r>" }
                else if ch == "\t" { flush(); out += "<w:r>\(props)<w:tab/></w:r>" }
                else { current.append(ch) }
            }
            flush()
            return out
        }

        mutating func runs(_ items: [DocInline], _ st: RunStyle) -> String {
            var out = ""
            for i in items {
                switch i {
                case .text(let t): out += textRuns(t, st)
                case .code(let c): var s = st; s.code = true; out += textRuns(c, s)
                case .emphasis(let c): var s = st; s.italic = true; out += runs(c, s)
                case .strong(let c): var s = st; s.bold = true; out += runs(c, s)
                case .strike(let c): var s = st; s.strike = true; out += runs(c, s)
                case .underline(let c): var s = st; s.underline = true; out += runs(c, s)
                case .link(let url, _, let c):
                    var s = st; s.link = true
                    let inner = runs(c, s)
                    if url.hasPrefix("#") || url.isEmpty { out += inner; continue }
                    let rid = rel(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: url, external: true)
                    out += "<w:hyperlink r:id=\"\(rid)\" w:history=\"1\">\(inner)</w:hyperlink>"
                case .image(let src, let alt, _):
                    if let drawing = drawing(src: src, alt: alt) { out += drawing }
                    else if !alt.isEmpty { out += textRuns("[\(alt)]", st) }
                case .lineBreak: out += "<w:r><w:br/></w:r>"
                case .softBreak: out += textRuns(" ", st)
                }
            }
            return out
        }

        private mutating func drawing(src: String, alt: String) -> String? {
            guard var m = model.media[src] else { return nil }
            // Word reads PNG, JPEG, GIF, BMP and TIFF; WebP / HEIC / SVG go through ImageIO to PNG.
            if !["image/png", "image/jpeg", "image/gif", "image/bmp", "image/tiff"].contains(m.mime) {
                guard let png = DocMediaKind.pngData(m.data) else { return nil }
                m = DocMedia(name: (m.name as NSString).deletingPathExtension + ".png", mime: "image/png", data: png)
            }
            let entry: (rid: String, name: String)
            if let e = mediaIDs[src] { entry = e } else {
                let name = "image\(mediaIDs.count + 1).\(m.fileExtension)"
                let rid = rel(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target: "media/\(name)", external: false)
                mediaParts.append(DocPackage.Part(name: "word/media/\(name)", data: m.data, stored: true))
                usedExtensions.insert(m.fileExtension)
                entry = (rid, name)
                mediaIDs[src] = entry
            }
            let px = DocMediaKind.pixelSize(m.data) ?? (400, 300)
            var cx = Double(px.width) * 9525, cy = Double(px.height) * 9525
            let maxW = o.page.contentWidth * 12700, maxH = o.page.contentHeight * 12700 * 0.9
            let scale = min(1, maxW / cx, maxH / cy)
            cx *= scale; cy *= scale
            let id = nextDocPr
            nextDocPr += 1
            let w = Int(cx), h = Int(cy)
            return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(w)\" cy=\"\(h)\"/><wp:docPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(DocXML.attr(alt))\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"\(DocXML.attr(entry.name))\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(entry.rid)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        }
    }
}
