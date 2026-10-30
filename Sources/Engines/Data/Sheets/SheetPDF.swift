import Foundation
import CoreGraphics
import CoreText

// Native "table printout" PDF of a spreadsheet: CoreText text (selectable and searchable in the PDF), a bold shaded header row repeated on every page, thin grid lines,
// columns sized to their content and shrunk fairly to the page, long cells wrapped, numbers right-aligned, page numbers. It prints VALUES in a plain table; the look of an
// XLSX (fonts, colours, merged cells) is only kept by the LibreOffice route (SheetOffice). Cells longer than 2000 characters are shortened with an ellipsis.

struct SheetPDFOptions {
    var paperKey = "a4"
    /// auto, portrait, landscape
    var orientation = "auto"
    var fontSize: CGFloat = 9
    var repeatHeader = true
    var title = ""
}

enum SheetPDF {
    static let margin: CGFloat = 36
    static let maxCellCharacters = 2000

    /// Portrait size of a paper key in points.
    static func paperSize(_ key: String) -> CGSize {
        switch key {
        case "a3": return CGSize(width: 841.89, height: 1190.55)
        case "a5": return CGSize(width: 419.53, height: 595.28)
        case "letter": return CGSize(width: 612, height: 792)
        case "legal": return CGSize(width: 612, height: 1008)
        default: return CGSize(width: 595.28, height: 841.89)
        }
    }

    static func write(_ tables: [SheetTable], to url: URL, options: SheetPDFOptions) throws {
        let painter = try Painter(url: url, options: options)
        let list = tables.isEmpty ? [SheetTable(name: "", rows: [])] : tables
        for t in list {
            try Task.checkCancellation()
            try painter.draw(t, showName: list.count > 1)
        }
        painter.close()
    }

    // MARK: Painter

    private final class Painter {
        let ctx: CGContext
        let options: SheetPDFOptions
        let font: CTFont
        let bold: CTFont
        let footerFont: CTFont
        let lineHeight: CGFloat
        var pageSize: CGSize
        var pageNumber = 0
        var open = false
        var cursorY: CGFloat = 0
        var sheetName = ""

        init(url: URL, options: SheetPDFOptions) throws {
            self.options = options
            let size = SheetPDF.paperSize(options.paperKey)
            pageSize = size
            var box = CGRect(origin: .zero, size: size)
            let aux: [String: Any] = [kCGPDFContextCreator as String: "Swamp Converter", kCGPDFContextTitle as String: options.title]
            guard let c = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
            ctx = c
            let base = CTFontCreateUIFontForLanguage(.system, options.fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, options.fontSize, nil)
            font = base
            bold = CTFontCreateCopyWithSymbolicTraits(base, options.fontSize, nil, .boldTrait, .boldTrait) ?? base
            footerFont = CTFontCreateUIFontForLanguage(.system, 7, nil) ?? base
            lineHeight = ceil(CTFontGetAscent(base) + CTFontGetDescent(base) + CTFontGetLeading(base))
        }

        func close() {
            if open { ctx.endPDFPage() }
            ctx.closePDF()
        }

        // MARK: Pages

        func newPage(size: CGSize) {
            if open { footer(); ctx.endPDFPage() }
            pageSize = size
            var box = CGRect(origin: .zero, size: size)
            let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
            open = true
            pageNumber += 1
            cursorY = size.height - SheetPDF.margin
        }

        private func footer() {
            let label = (sheetName.isEmpty ? "" : sheetName + "  -  ") + String(pageNumber)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): footerFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1)]))
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (pageSize.width - CGFloat(w)) / 2, y: 18)
            CTLineDraw(line, ctx)
        }

        // MARK: Measuring

        private static func makeStyle(right: Bool) -> CTParagraphStyle {
            var alignment: CTTextAlignment = right ? .right : .left
            var breakMode: CTLineBreakMode = .byWordWrapping
            return withUnsafePointer(to: &alignment) { a in
                withUnsafePointer(to: &breakMode) { b in
                    let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: b)]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        private let leftStyle = Painter.makeStyle(right: false)
        private let rightStyle = Painter.makeStyle(right: true)

        private func attributed(_ text: String, font f: CTFont, right: Bool) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): right ? rightStyle : leftStyle])
        }

        private func lineWidth(_ text: String, font f: CTFont) -> CGFloat {
            let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: first, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        private func textHeight(_ text: String, width: CGFloat, font f: CTFont) -> CGFloat {
            if !text.contains("\n") && CGFloat(text.utf16.count) * options.fontSize * 0.95 <= width { return lineHeight }
            if !text.contains("\n") && lineWidth(text, font: f) <= width { return lineHeight }
            let fs = CTFramesetterCreateWithAttributedString(attributed(text, font: f, right: false))
            let s = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: 100_000), nil)
            return max(lineHeight, ceil(s.height))
        }

        private static func looksNumeric(_ s: String) -> Bool {
            guard s.utf8.count <= 24, s.unicodeScalars.contains(where: { $0.value >= 0x30 && $0.value <= 0x39 }) else { return false }
            return s.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || " .,-+%$\u{20AC}\u{00A0}".unicodeScalars.contains($0) }
        }

        /// Max-min fair column widths: narrow columns keep their natural width, wide ones share what is left.
        private func fit(_ natural: [CGFloat], usable: CGFloat) -> [CGFloat] {
            if natural.reduce(0, +) <= usable { return natural }
            let minWidth: CGFloat = 26
            var result = natural
            let order = natural.indices.sorted { natural[$0] < natural[$1] }
            var remaining = usable
            var left = natural.count
            for i in order {
                let share = remaining / CGFloat(left)
                result[i] = max(minWidth, min(natural[i], share))
                remaining -= result[i]
                left -= 1
            }
            return result
        }

        // MARK: Drawing

        func draw(_ table: SheetTable, showName: Bool) throws {
            let cols = max(table.columnCount, 1)
            let rows = table.rows
            let pad: CGFloat = 4
            // Natural widths from the first rows.
            var natural = [CGFloat](repeating: 0, count: cols)
            for (r, row) in rows.prefix(300).enumerated() {
                let f = (r == 0 && options.repeatHeader) ? bold : font
                for (c, v) in row.enumerated() where c < cols && !v.isEmpty { natural[c] = max(natural[c], min(360, lineWidth(v, font: f))) }
            }
            natural = natural.map { max(26, ceil($0) + pad * 2) }
            let base = SheetPDF.paperSize(options.paperKey)
            let portraitUsable = base.width - 2 * SheetPDF.margin
            var landscape = options.orientation == "landscape"
            if options.orientation == "auto" { landscape = natural.reduce(0, +) > portraitUsable }
            let size = landscape ? CGSize(width: base.height, height: base.width) : base
            let usable = size.width - 2 * SheetPDF.margin
            let widths = fit(natural, usable: usable)
            let contentHeight = size.height - 2 * SheetPDF.margin - 14
            sheetName = table.name
            newPage(size: size)
            if showName && !table.name.isEmpty {
                drawText(table.name, font: bold, in: CGRect(x: SheetPDF.margin, y: cursorY - lineHeight - 4, width: usable, height: lineHeight + 4), right: false)
                cursorY -= lineHeight + 10
            }
            for (r, row) in rows.enumerated() {
                if r % 128 == 0 { try Task.checkCancellation() }
                let isHeader = r == 0 && options.repeatHeader && rows.count > 1
                let f = isHeader ? bold : font
                var heights: [CGFloat] = []
                var texts: [String] = []
                var h = lineHeight
                for c in 0..<cols {
                    var t = c < row.count ? row[c] : ""
                    if t.count > SheetPDF.maxCellCharacters { t = String(t.prefix(SheetPDF.maxCellCharacters)) + "\u{2026}" }
                    texts.append(t)
                    let th = t.isEmpty ? lineHeight : textHeight(t, width: widths[c] - pad * 2, font: f)
                    heights.append(th)
                    h = max(h, th)
                }
                let rowHeight = min(h + 4, contentHeight)
                if cursorY - rowHeight < SheetPDF.margin + 14 {
                    newPage(size: size)
                    if options.repeatHeader && rows.count > 1 && r > 0, let header = rows.first {
                        drawRow(header, widths: widths, header: true, pad: pad)        // the header is repeated on every page
                    }
                }
                drawRow(texts, widths: widths, header: isHeader, pad: pad, precomputedHeight: rowHeight)
            }
        }

        /// Draws one row at the cursor and moves the cursor down. Returns the row height.
        @discardableResult
        private func drawRow(_ row: [String], widths: [CGFloat], header: Bool, pad: CGFloat, precomputedHeight: CGFloat? = nil) -> CGFloat {
            let f = header ? bold : font
            let texts = widths.indices.map { c -> String in
                var t = c < row.count ? row[c] : ""
                if t.count > SheetPDF.maxCellCharacters { t = String(t.prefix(SheetPDF.maxCellCharacters)) + "\u{2026}" }
                return t
            }
            var h = precomputedHeight ?? lineHeight
            if precomputedHeight == nil {
                for (c, t) in texts.enumerated() where !t.isEmpty { h = max(h, textHeight(t, width: widths[c] - pad * 2, font: f)) }
                h = min(h + 4, pageSize.height - 2 * SheetPDF.margin - 14)
            }
            var x = SheetPDF.margin
            let top = cursorY
            if header {
                ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
                ctx.fill(CGRect(x: x, y: top - h, width: widths.reduce(0, +), height: h))
            }
            ctx.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
            ctx.setLineWidth(0.4)
            for (c, w) in widths.enumerated() {
                let cell = CGRect(x: x, y: top - h, width: w, height: h)
                ctx.stroke(cell)
                if !texts[c].isEmpty {
                    drawText(texts[c], font: f, in: cell.insetBy(dx: pad, dy: 2), right: !header && Self.looksNumeric(texts[c]))
                }
                x += w
            }
            cursorY -= h
            return h
        }

        private func drawText(_ text: String, font f: CTFont, in rect: CGRect, right: Bool) {
            ctx.saveGState()
            ctx.clip(to: rect.insetBy(dx: -1, dy: -1))
            let fs = CTFramesetterCreateWithAttributedString(attributed(text, font: f, right: right))
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
    }
}
