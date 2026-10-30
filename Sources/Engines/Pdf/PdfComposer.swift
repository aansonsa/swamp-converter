import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import PDFKit

/// Builds a new PDF page by page with Core Graphics: copies pages (rotation applied, optional paper size / fit / margins), adds picture pages
/// (JPEG passes through untouched) and lays an INVISIBLE text layer over them so scans become searchable (spec/platform.md 4).
final class PdfComposer {
    enum Fit { case fit, fill, none }

    private let context: CGContext
    private var closed = false

    init(url: URL, title: String? = nil, author: String? = nil) throws {
        var aux: [CFString: Any] = [:]
        if let title, !title.isEmpty { aux[kCGPDFContextTitle] = title }
        if let author, !author.isEmpty { aux[kCGPDFContextAuthor] = author }
        guard let c = CGContext(url as CFURL, mediaBox: nil, aux.isEmpty ? nil : aux as CFDictionary) else {
            throw ConversionError.outputNotWritable(url.deletingLastPathComponent())
        }
        context = c
    }

    func close() {
        guard !closed else { return }
        closed = true
        context.closePDF()
    }

    deinit { close() }

    // MARK: Geometry

    /// Size as a viewer shows the page: crop box, swapped for /Rotate 90 and 270.
    static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let b = page.getBoxRect(.cropBox)
        let r = ((page.rotationAngle % 360) + 360) % 360
        return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b.size
    }

    private func begin(_ size: CGSize) {
        var rect = CGRect(origin: .zero, size: size)
        let box = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
    }

    // MARK: Pages

    /// Copies `page`. `target` nil keeps the page's own displayed size; otherwise the page is placed on a sheet of that size (inside `margin` points).
    /// `text` is laid over the page as invisible text (boxes are normalised to the whole sheet).
    func addPage(_ page: CGPDFPage, target: CGSize? = nil, fit: Fit = .fit, margin: CGFloat = 0, text: [OcrLine] = []) {
        let shown = Self.displayedSize(page)
        let sheet = target ?? shown
        begin(sheet)
        let inner = CGRect(origin: .zero, size: sheet).insetBy(dx: min(margin, sheet.width / 3), dy: min(margin, sheet.height / 3))
        let scale: CGFloat
        switch fit {
        case .fit: scale = min(inner.width / shown.width, inner.height / shown.height)
        case .fill: scale = max(inner.width / shown.width, inner.height / shown.height)
        case .none: scale = 1
        }
        let w = shown.width * scale, h = shown.height * scale
        let rect = CGRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h)
        context.saveGState()
        context.clip(to: margin > 0 ? inner : CGRect(origin: .zero, size: sheet))
        // getDrawingTransform only ever scales DOWN to a rect, so it maps the page onto its own size (rotation and crop offset) and the scale is applied here.
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
        if !text.isEmpty { drawInvisibleText(text, pageSize: sheet) }
        context.endPDFPage()
    }

    /// A page that is one picture covering the whole sheet (`size` in points) plus optional invisible text.
    func addImagePage(_ image: CGImage, size: CGSize, text: [OcrLine] = []) {
        begin(size)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        if !text.isEmpty { drawInvisibleText(text, pageSize: size) }
        context.endPDFPage()
    }

    /// Text render mode "invisible": selectable and searchable, never drawn. Each line is scaled to the width of its recognised box.
    private func drawInvisibleText(_ lines: [OcrLine], pageSize: CGSize) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for l in lines {
            let rect = CGRect(x: l.box.minX * pageSize.width, y: l.box.minY * pageSize.height,
                              width: l.box.width * pageSize.width, height: l.box.height * pageSize.height)
            guard rect.width > 0.5, rect.height > 0.5, !l.text.isEmpty else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height * 0.85), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: [.font: font]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard width > 0 else { continue }
            context.textMatrix = CGAffineTransform(a: rect.width / width, b: 0, c: 0, d: 1, tx: rect.minX, ty: rect.minY + rect.height * 0.2)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    // MARK: JPEG helpers

    /// JPEG bytes of a bitmap (quality 1...100).
    static func jpegData(_ image: CGImage, quality: Int) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.message(L10n("This Mac cannot write JPEG images.", "Этот Mac не может записывать JPEG."))
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: Util.clamp(Double(quality), 1, 100) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.message(L10n("Could not compress the page.", "Не удалось сжать страницу.")) }
        return data as Data
    }

    /// A CGImage backed by the JPEG bytes themselves: the PDF context embeds them as they are (no second compression).
    static func jpegBackedImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
