import Foundation
import CoreText
import CoreGraphics
import ImageIO

// DocModel -> PDF with our own CoreText layout (the system has no document-to-PDF converter that is usable from a background process, spec/platform.md 5.2).
// Block flow: headings, paragraphs (split across pages line by line), lists with hanging markers, block quotes with a bar, code blocks with a tint, tables (equal-or-content
// weighted columns, repeated header row), pictures scaled to the page and horizontal rules. Text stays real text (selectable, searchable); links become PDF link
// annotations; headings become the PDF outline; page numbers are optional. The media box is exactly the chosen page size.

enum DocPdfWriter {
    struct Options {
        var page = DocPageSetup(size: "a4", marginMillimetres: 20)
        var font = "Helvetica Neue"
        var fontSize = 11.0
        var lineSpacing = 1.15
        var pageNumbers = false
        var includeAuthorAndTitle = true
        var title: String?
        var author: String?
    }

    /// Writes the PDF and returns the number of pages.
    @discardableResult
    static func write(_ model: DocModel, options: Options = Options(), to url: URL) throws -> Int {
        var box = CGRect(x: 0, y: 0, width: options.page.width, height: options.page.height)
        var aux: [CFString: Any] = [kCGPDFContextCreator: "Swamp Converter"]
        if options.includeAuthorAndTitle {
            if let t = options.title ?? model.meta.title, !t.isEmpty { aux[kCGPDFContextTitle] = t }
            if let a = options.author ?? model.meta.author, !a.isEmpty { aux[kCGPDFContextAuthor] = a }
        }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        let flow = PdfFlow(ctx: ctx, model: model, options: options)
        do { try flow.run() } catch { ctx.closePDF(); try? FileManager.default.removeItem(at: url); throw error }
        let pages = flow.finish()
        ctx.closePDF()
        return pages
    }
}

final class PdfFlow {
    struct Frame { var x: CGFloat; var width: CGFloat; var bars: [CGFloat] = []; var tint = false }

    let ctx: CGContext
    let model: DocModel
    let o: DocPdfWriter.Options
    let fonts: PdfFonts
    let margin: CGFloat
    let contentW: CGFloat
    let contentH: CGFloat
    let pageH: CGFloat
    var y: CGFloat = 0                 // distance from the top of the content area
    var pageNumber = 0
    var pageOpen = false
    var outline: [(level: Int, title: String, page: Int, top: CGFloat)] = []
    private var imageCache: [String: CGImage] = [:]
    private var gapPending: CGFloat = 0

    var size: CGFloat { CGFloat(o.fontSize) }
    var lhm: CGFloat { CGFloat(max(1.0, o.lineSpacing)) }

    init(ctx: CGContext, model: DocModel, options: DocPdfWriter.Options) {
        self.ctx = ctx; self.model = model; self.o = options
        fonts = PdfFonts(family: options.font)
        margin = CGFloat(options.page.margin)
        contentW = CGFloat(options.page.contentWidth)
        contentH = CGFloat(options.page.contentHeight)
        pageH = CGFloat(options.page.height)
    }

    func run() throws {
        for b in model.blocks {
            try Task.checkCancellation()
            try block(b, Frame(x: 0, width: contentW))
        }
    }

    /// Closes the last page, writes the outline and returns the page count (at least one page, even for an empty document).
    func finish() -> Int {
        ensurePage()
        endPage()
        if !outline.isEmpty { CGPDFContextSetOutline(ctx, Self.outlineTree(outline)) }
        return pageNumber
    }

    // MARK: Pages

    func ensurePage() {
        guard !pageOpen else { return }
        ctx.beginPDFPage(nil)
        pageOpen = true
        pageNumber += 1
        y = 0
    }

    func newPage() { endPage(); ensurePage() }

    private func endPage() {
        guard pageOpen else { return }
        if o.pageNumbers {
            let style = PdfTextStyle(size: max(7, size * 0.75), color: CGColor(gray: 0.35, alpha: 1), alignment: .center, lineHeightMultiple: 1)
            let line = CTLineCreateWithAttributedString(PdfText.plain(String(pageNumber), style: style, fonts: fonts))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (CGFloat(o.page.width) - w) / 2, y: max(6, margin / 2 - style.size / 2))
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        pageOpen = false
    }

    private func gap(_ pts: CGFloat) { gapPending = max(gapPending, pts) }

    /// Applies the pending vertical gap unless the page has just begun.
    private func settleGap() {
        if y > 0 { y += gapPending }
        gapPending = 0
    }

    // MARK: Blocks

    func block(_ b: DocBlock, _ f: Frame) throws {
        switch b {
        case .heading(let level, let c):
            let l = max(1, min(6, level))
            let scale: [CGFloat] = [1.9, 1.5, 1.28, 1.15, 1.05, 1.0]
            let st = PdfTextStyle(size: size * scale[l - 1], bold: true, lineHeightMultiple: 1.1)
            gap(size * (l == 1 ? 1.1 : 0.9))
            let segs = PdfText.segments(c, style: st, fonts: fonts) { self.model.media[$0] != nil }
            ensurePage(); settleGap()
            // Keep a heading with the first lines of what follows.
            if y > 0, contentH - y < st.size * 1.1 * 3 + size * 2 { newPage() }
            let pageBefore = pageNumber, top = y
            try paragraph(segs, f, afterGap: size * 0.45)
            outline.append((l, c.plainText.replacingOccurrences(of: "\n", with: " "), pageBefore, pageH - margin - top))
        case .paragraph(let c):
            if c.isBlank { return }
            let st = PdfTextStyle(size: size, color: f.tint ? CGColor(gray: 0.2, alpha: 1) : CGColor(gray: 0, alpha: 1), lineHeightMultiple: lhm)
            try paragraph(PdfText.segments(c, style: st, fonts: fonts) { self.model.media[$0] != nil }, f, afterGap: size * 0.7)
        case .list(let l): try list(l, f, depth: 0)
        case .quote(let inner):
            var q = f
            q.bars = f.bars + [f.x + 2]
            q.x = f.x + 14
            q.width = max(40, f.width - 14)
            for x in inner { try block(x, q) }
        case .code(_, let text):
            var st = PdfTextStyle(size: size * 0.92, lineHeightMultiple: 1.1)
            st.color = CGColor(gray: 0.1, alpha: 1)
            var tinted = f
            tinted.tint = true
            let attributed = PdfText.plain(text.isEmpty ? " " : text, style: st, fonts: fonts, mono: true)
            gap(size * 0.3)
            try drawText(attributed, tinted, tint: CGColor(gray: 0.95, alpha: 1))
            gap(size * 0.8)
        case .table(let t): try table(t, f)
        case .rule:
            ensurePage(); gap(size * 0.5); settleGap()
            if contentH - y < 6 { newPage() }
            let py = pageH - margin - y - 3
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); ctx.setLineWidth(0.6)
            ctx.move(to: CGPoint(x: margin + f.x, y: py)); ctx.addLine(to: CGPoint(x: margin + f.x + f.width, y: py)); ctx.strokePath()
            y += 6
            gap(size * 0.5)
        case .pageBreak:
            if pageOpen && y > 0 { newPage() }
        }
    }

    // MARK: Paragraphs and pictures

    private func paragraph(_ segs: [PdfSegment], _ f: Frame, afterGap: CGFloat) throws {
        for s in segs {
            try Task.checkCancellation()
            switch s {
            case .text(let t): try drawText(t, f)
            case .image(let key, let alt): try drawImage(key, alt: alt, f)
            }
        }
        gap(afterGap)
    }

    /// Draws attributed text from the current position, continuing on new pages line by line. `tint` fills a rectangle behind every page part (code blocks).
    func drawText(_ text: NSAttributedString, _ f: Frame, tint: CGColor? = nil) throws {
        guard text.length > 0 else { return }
        ensurePage(); settleGap()
        let setter = CTFramesetterCreateWithAttributedString(text)
        var start = 0
        let total = text.length
        while start < total {
            try Task.checkCancellation()
            let avail = contentH - y
            var fit = CFRange()
            var frameSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: start, length: total - start), nil, CGSize(width: f.width, height: max(1, avail)), &fit)
            if fit.length == 0 || avail < 4 {
                if y > 0 { newPage(); continue }
                frameSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: start, length: total - start), nil, CGSize(width: f.width, height: .greatestFiniteMagnitude), &fit)
                if fit.length == 0 { fit.length = total - start }
            }
            let h = ceil(frameSize.height)
            let rect = CGRect(x: margin + f.x, y: pageH - margin - y - h, width: f.width, height: h)
            if let tint {
                ctx.setFillColor(tint)
                ctx.fill(rect.insetBy(dx: -4, dy: -2))
            }
            ctx.setFillColor(CGColor(gray: 0.72, alpha: 1))
            for bx in f.bars { ctx.fill(CGRect(x: margin + bx, y: rect.minY, width: 2, height: h)) }
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: fit.length), CGPath(rect: rect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            decorate(frame, origin: rect.origin)
            y += h
            start += fit.length
            if start < total { newPage() }
        }
    }

    /// Strike-through lines and link annotations for the runs of a drawn frame.
    private func decorate(_ frame: CTFrame, origin: CGPoint) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (li, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let strike = attrs[NSAttributedString.Key.docStrike] != nil
                let link = attrs[NSAttributedString.Key.docLink] as? String
                guard strike || link != nil else { continue }
                let range = CTRunGetStringRange(run)
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
                let x = origin.x + origins[li].x + CTLineGetOffsetForStringIndex(line, range.location, nil)
                let base = origin.y + origins[li].y
                if strike {
                    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(max(0.5, size / 16))
                    ctx.move(to: CGPoint(x: x, y: base + ascent * 0.32)); ctx.addLine(to: CGPoint(x: x + width, y: base + ascent * 0.32)); ctx.strokePath()
                }
                if let link, let u = URL(string: link) {
                    ctx.setURL(u as CFURL, for: CGRect(x: x, y: base - descent, width: width, height: ascent + descent))
                }
            }
        }
    }

    private func image(_ key: String) -> CGImage? {
        if let c = imageCache[key] { return c }
        guard let m = model.media[key], let src = CGImageSourceCreateWithData(m.data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        imageCache[key] = img
        return img
    }

    private func drawImage(_ key: String, alt: String, _ f: Frame) throws {
        guard let img = image(key) else {
            if !alt.isEmpty { try drawText(PdfText.plain("[\(alt)]", style: PdfTextStyle(size: size, lineHeightMultiple: lhm), fonts: fonts), f) }
            return
        }
        ensurePage(); gap(size * 0.4); settleGap()
        var w = CGFloat(img.width) * 0.75, h = CGFloat(img.height) * 0.75      // 96 dpi pictures
        let scale = min(1, f.width / w, contentH / h)
        w *= scale; h *= scale
        if contentH - y < h && y > 0 { newPage() }
        ctx.draw(img, in: CGRect(x: margin + f.x, y: pageH - margin - y - h, width: w, height: h))
        y += h
        gap(size * 0.7)
    }

    // MARK: Lists

    private func list(_ l: DocList, _ f: Frame, depth: Int) throws {
        let step = size * 1.9
        for (i, item) in l.items.enumerated() {
            try Task.checkCancellation()
            var marker = l.ordered ? "\(l.start + i)." : ["\u{2022}", "\u{25E6}", "\u{25AA}"][depth % 3]
            if let c = item.checked { marker += c ? " \u{2611}" : " \u{2610}" }
            var firstDone = false
            for b in item.blocks {
                if !firstDone, case .paragraph(let c) = b {
                    var st = PdfTextStyle(size: size, lineHeightMultiple: lhm)
                    st.firstLineIndent = 0; st.headIndent = step; st.tabStop = step
                    let withMarker: [DocInline] = [.text(marker + "\t")] + c
                    try paragraph(PdfText.segments(withMarker, style: st, fonts: fonts) { self.model.media[$0] != nil }, f, afterGap: size * (l.tight ? 0.25 : 0.6))
                    firstDone = true
                    continue
                }
                if !firstDone {
                    var st = PdfTextStyle(size: size, lineHeightMultiple: lhm)
                    st.tabStop = step
                    try drawText(PdfText.plain(marker, style: st, fonts: fonts), f)
                    firstDone = true
                }
                var inner = f
                inner.x = f.x + step
                inner.width = max(40, f.width - step)
                if case .list(let nested) = b { try list(nested, inner, depth: depth + 1) } else { try block(b, inner) }
            }
            if !firstDone {
                var st = PdfTextStyle(size: size, lineHeightMultiple: lhm)
                st.tabStop = step
                try drawText(PdfText.plain(marker, style: st, fonts: fonts), f)
                gap(size * 0.25)
            }
        }
        gap(size * 0.6)
    }

    // MARK: Tables

    private func table(_ t: DocTable, _ f: Frame) throws {
        let cols = max(1, t.columnCount)
        let pad: CGFloat = 4
        let cellStyle = PdfTextStyle(size: size * 0.95, lineHeightMultiple: 1.05)
        var headStyle = cellStyle
        headStyle.bold = true
        func cellText(_ c: [DocInline], _ i: Int, _ st: PdfTextStyle) -> NSAttributedString {
            var s = st
            let al = i < t.align.count ? t.align[i] : DocAlign.none
            s.alignment = al == .center ? .center : (al == .right ? .right : .natural)
            let segs = PdfText.segments(c.map { x -> DocInline in if case .image(_, let alt, _) = x { return .text(alt.isEmpty ? "" : "[\(alt)]") }; return x }, style: s, fonts: fonts) { _ in false }
            let joined = NSMutableAttributedString()
            for seg in segs { if case .text(let a) = seg { joined.append(a) } }
            return joined
        }
        let header = t.header.map { h in (0..<cols).map { cellText($0 < h.count ? h[$0] : [], $0, headStyle) } }
        let rows = t.rows.map { r in (0..<cols).map { cellText($0 < r.count ? r[$0] : [], $0, cellStyle) } }
        // Column widths: natural width of the widest cell, scaled to the frame (never below a minimum).
        var natural = [CGFloat](repeating: 24, count: cols)
        for r in (header.map { [$0] } ?? []) + rows { for (i, c) in r.enumerated() { natural[i] = max(natural[i], PdfText.naturalWidth(c) + pad * 2 + 2) } }
        let sum = natural.reduce(0, +)
        var widths = natural
        if sum > f.width {
            // Shrink the widest columns first so short columns keep their words on one line.
            let minimum = f.width / CGFloat(cols) * 0.5
            let excess = sum - f.width
            let flexible = natural.map { max(0, $0 - minimum) }
            let flexSum = max(1, flexible.reduce(0, +))
            widths = zip(natural, flexible).map { max(minimum * 0.6, $0 - excess * ($1 / flexSum)) }
            let again = widths.reduce(0, +)
            if again > f.width { widths = widths.map { $0 * f.width / again } }
        } else if sum < f.width * 0.98 && cols > 1 {
            let extra = (f.width - sum) / CGFloat(cols)
            widths = natural.map { $0 + extra }
        }
        func rowHeight(_ r: [NSAttributedString]) -> CGFloat {
            var h: CGFloat = 0
            for (i, c) in r.enumerated() where c.length > 0 {
                let s = CTFramesetterCreateWithAttributedString(c)
                let sz = CTFramesetterSuggestFrameSizeWithConstraints(s, CFRange(location: 0, length: c.length), nil, CGSize(width: widths[i] - pad * 2, height: .greatestFiniteMagnitude), nil)
                h = max(h, ceil(sz.height))
            }
            return max(h, size * 1.2) + pad * 2
        }
        func drawRow(_ r: [NSAttributedString], height: CGFloat, head: Bool) {
            var x = margin + f.x
            let top = pageH - margin - y
            for (i, c) in r.enumerated() {
                let cell = CGRect(x: x, y: top - height, width: widths[i], height: height)
                if head { ctx.setFillColor(CGColor(gray: 0.94, alpha: 1)); ctx.fill(cell) }
                ctx.setStrokeColor(CGColor(gray: 0.65, alpha: 1)); ctx.setLineWidth(0.5); ctx.stroke(cell)
                if c.length > 0 {
                    let inner = cell.insetBy(dx: pad, dy: pad)
                    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(c), CFRange(location: 0, length: c.length), CGPath(rect: inner, transform: nil), nil)
                    CTFrameDraw(frame, ctx)
                    decorate(frame, origin: inner.origin)
                }
                x += widths[i]
            }
            y += height
        }
        ensurePage(); gap(size * 0.3); settleGap()
        let headHeight = header.map { rowHeight($0) } ?? 0
        if let h = header {
            if contentH - y < headHeight + (rows.first.map { rowHeight($0) } ?? 0) && y > 0 { newPage() }
            drawRow(h, height: headHeight, head: true)
        }
        for r in rows {
            try Task.checkCancellation()
            let h = min(rowHeight(r), contentH)
            if contentH - y < h {
                newPage()
                if let hd = header { drawRow(hd, height: headHeight, head: true) }
            }
            drawRow(r, height: h, head: false)
        }
        gap(size * 0.9)
    }

    // MARK: Outline

    /// Headings as a nested PDF outline (page numbers are 1-based, rectangles in page space).
    static func outlineTree(_ items: [(level: Int, title: String, page: Int, top: CGFloat)]) -> CFDictionary {
        final class Node { var dict: [CFString: Any]; var children: [Node] = []; let level: Int; init(_ d: [CFString: Any], _ l: Int) { dict = d; level = l } }
        func make(_ n: Node) -> [CFString: Any] {
            var d = n.dict
            if !n.children.isEmpty { d[kCGPDFOutlineChildren] = n.children.map(make) }
            return d
        }
        let root = Node([:], 0)
        var stack = [root]
        for it in items {
            let rect = CGRect(x: 0, y: it.top, width: 1, height: 1)
            let node = Node([kCGPDFOutlineTitle: it.title, kCGPDFOutlineDestination: it.page, kCGPDFOutlineDestinationRect: CGRectCreateDictionaryRepresentation(rect)], it.level)
            while let last = stack.last, last.level >= it.level, stack.count > 1 { stack.removeLast() }
            stack.last?.children.append(node)
            stack.append(node)
        }
        return make(root) as CFDictionary
    }
}
