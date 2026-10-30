import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PdfRasterOptions: Sendable {
    var dpi = 300
    var format = "png"            // png, jpeg, heic, tiff
    var quality = 90
    var background = RGBA.white
    var grayscale = false
    var annotations = true
    var pages: [Int]? = nil       // nil = all pages (0-based indices)
    /// No background fill: PNG / TIFF / HEIC keep the alpha channel (JPEG cannot, it falls back to `background`).
    var transparent = false
}

/// Rendering service shared with the docs module (slides.to.png / slides.to.jpg render the LibreOffice PDF through it) and with OCR.
enum PdfRasterizer {
    /// Largest picture the renderer will create (pixels). Bigger requests render at a lower DPI instead of exhausting memory.
    static let maxPixels = 120_000_000
    static let maxSide = 24_000

    // MARK: Rendering

    /// One page as a bitmap at `dpi` (rotation-aware: PDFKit's bounds ignore /Rotate, swap the canvas for 90/270 - spec trap 14).
    static func renderPage(pdf: URL, pageIndex: Int, dpi: Int, background: RGBA = .white, annotations: Bool = true) throws -> CGImage {
        let doc = try PdfDoc.open(pdf)
        guard let page = doc.page(at: pageIndex) else {
            throw ConversionError.message(L10n("The PDF has no page \(pageIndex + 1).", "В PDF нет страницы \(pageIndex + 1)."))
        }
        return try render(page, dpi: Double(dpi), background: background, annotations: annotations)
    }

    /// Pixel size of a page rendered at `dpi` (after the safety limits).
    static func pixelSize(of page: PDFPage, dpi: Double) -> (width: Int, height: Int) {
        let size = PdfGeometry.displayedSize(page)
        let scale = effectiveScale(size: size, dpi: dpi)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    private static func effectiveScale(size: CGSize, dpi: Double) -> CGFloat {
        var s = CGFloat(max(dpi, 1)) / 72
        let w = size.width * s, h = size.height * s
        if max(w, h) > CGFloat(maxSide) { s *= CGFloat(maxSide) / max(w, h) }
        let px = (size.width * s) * (size.height * s)
        if px > CGFloat(maxPixels) { s *= (CGFloat(maxPixels) / px).squareRoot() }
        return s
    }

    /// Renders an open page. `background` nil = transparent. `maxLongSide` caps the picture (OCR, previews) by lowering the DPI.
    static func render(_ page: PDFPage, dpi: Double, background: RGBA? = .white, annotations: Bool = true, grayscale: Bool = false,
                       maxLongSide: Int? = nil) throws -> CGImage {
        let size = PdfGeometry.displayedSize(page)
        guard size.width > 0, size.height > 0 else {
            throw ConversionError.message(L10n("A page of this PDF has no size.", "У страницы этого PDF нет размера."))
        }
        var scale = effectiveScale(size: size, dpi: dpi)
        if let cap = maxLongSide, max(size.width, size.height) * scale > CGFloat(cap) { scale = CGFloat(cap) / max(size.width, size.height) }
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        let context: CGContext?
        if grayscale {
            context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            let alpha: CGImageAlphaInfo = background == nil ? .premultipliedLast : .noneSkipLast
            context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: alpha.rawValue)
        }
        guard let ctx = context else {
            throw ConversionError.message(L10n("Not enough memory to draw the page at \(Int(dpi)) dpi.", "Не хватает памяти, чтобы отрисовать страницу в \(Int(dpi)) dpi."))
        }
        if let bg = background {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        let previous = page.displaysAnnotations
        page.displaysAnnotations = annotations
        page.draw(with: .cropBox, to: ctx)
        page.displaysAnnotations = previous
        guard let image = ctx.makeImage() else {
            throw ConversionError.message(L10n("Could not draw the page.", "Не удалось отрисовать страницу."))
        }
        return image
    }

    // MARK: Encoding

    /// File extension for an image format key (jpeg -> jpg).
    static func fileExtension(for format: String) -> String {
        switch format.lowercased() {
        case "jpeg", "jpg": return "jpg"
        case "tif", "tiff": return "tiff"
        case "heic", "heif": return "heic"
        default: return "png"
        }
    }

    static func utType(for format: String) -> UTType {
        switch fileExtension(for: format) {
        case "jpg": return .jpeg
        case "tiff": return .tiff
        case "heic": return .heic
        default: return .png
        }
    }

    /// Writes `image` with ImageIO. The DPI tag makes the picture print at the physical page size.
    static func encode(_ image: CGImage, format: String, quality: Int, dpi: Int, to url: URL) throws {
        let type = utType(for: format)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.message(L10n("This Mac cannot write \(format.uppercased()) images.", "Этот Mac не может записывать изображения \(format.uppercased())."))
        }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg || type == .heic { props[kCGImageDestinationLossyCompressionQuality] = Util.clamp(Double(quality), 1, 100) / 100 }
        if type == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }   // LZW
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.message(L10n("Could not write the image.", "Не удалось записать изображение."))
        }
    }

    // MARK: Pages to files

    /// All pages -> a file (1 page) or a folder `{base} (pages)` with `{base} - NN.ext` (spec/catalog.md 3.4); returns the produced URL(s).
    /// Used by pdf.to.jpg/png and by slides.to.png/jpg (docs module passes the temporary PDF).
    static func rasterize(pdf: URL, source: FileItem, options: PdfRasterOptions, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let doc = try PdfDoc.open(pdf)
        let total = doc.pageCount
        let indices = (options.pages ?? Array(0..<total)).filter { $0 >= 0 && $0 < total }
        guard !indices.isEmpty else {
            throw ConversionError.invalidOption(key: PdfKeys.pages, reason: L10n("No pages selected.", "Страницы не выбраны."))
        }
        let ext = fileExtension(for: options.format)
        let keepsAlpha = options.transparent && utType(for: options.format) != .jpeg
        let background: RGBA? = keepsAlpha ? nil : options.background

        func renderAndWrite(_ index: Int, to url: URL) throws {
            try autoreleasepool {
                guard let page = doc.page(at: index) else { return }
                let image = try render(page, dpi: Double(options.dpi), background: background, annotations: options.annotations, grayscale: options.grayscale)
                try encode(image, format: options.format, quality: options.quality, dpi: options.dpi, to: url)
            }
        }

        if indices.count == 1 {
            let n = indices[0]
            let base = total == 1 ? ctx.outputBaseName(for: source) : "\(ctx.outputBaseName(for: source)) - \(PdfGeometry.padded(n + 1, total: total))"
            let url = try await ctx.produceFile(for: source, ext: ext, base: base) { tmp in try renderAndWrite(n, to: tmp) }
            progress.report(1)
            return [url]
        }
        let folder = try await ctx.produceFolder(for: source, suffix: L10n("pages", "страницы")) { dir in
            for (i, n) in indices.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                let name = "\(source.base) - \(PdfGeometry.padded(n + 1, total: total)).\(ext)"
                try renderAndWrite(n, to: dir.appendingPathComponent(name))
                progress.report(Double(i + 1) / Double(indices.count))
            }
        }
        return [folder]
    }

    // MARK: Text

    static let scanMessage = L10n("The PDF contains no text (probably a scan). Try converting it to JPG/PNG or use text recognition.",
                                  "В PDF нет текста (вероятно, это скан). Попробуйте конвертацию в JPG/PNG или распознавание текста.")

    /// Reading-order text of the pages (empty pages skipped). Throws the scan message when nothing is found.
    static func extractText(pdf: URL, pages: [Int]? = nil) throws -> [String] {
        let doc = try PdfDoc.open(pdf)
        let list = pages ?? Array(0..<doc.pageCount)
        let texts = list.compactMap { doc.page(at: $0) }.map { PdfGeometry.text(of: $0) }.filter { !$0.isEmpty }
        if texts.isEmpty { throw ConversionError.message(scanMessage) }
        return texts
    }
}
