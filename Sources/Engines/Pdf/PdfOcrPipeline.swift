import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import AppKit

/// What the OCR options of a job say. Read from `ctx.options`; the render resolution is independent of the DPI setting of the image export (spec: 300 dpi).
struct PdfOcrSettings: Sendable {
    var languages: [String]
    var autoDetect = true
    var skipText = true
    var dpi = 300

    init(languages: [String] = [], autoDetect: Bool = true, skipText: Bool = true, dpi: Int = 300) {
        self.languages = languages; self.autoDetect = autoDetect; self.skipText = skipText; self.dpi = dpi
    }

    init(options o: OptionValues) {
        let langs = o.rows(PdfKeys.ocrLanguages).compactMap { $0["lang"]?.asString }.filter { !$0.isEmpty }
        self.init(languages: langs.isEmpty ? OcrService.defaultLanguages() : langs, autoDetect: o.bool(PdfKeys.ocrAuto, true),
                  skipText: o.bool(PdfKeys.ocrSkipText, true), dpi: Util.clamp(o.int(PdfKeys.ocrDPI, 300), 100, 600))
    }

    var ocrOptions: OcrOptions { OcrOptions(languages: languages, accurate: true, autoDetect: autoDetect, languageCorrection: true) }
}

/// Recognised text of one page (or of one picture).
struct OcrPageText: Sendable {
    var number: Int
    var lines: [OcrLine]
    /// Reading-order rows (one string per row).
    var rows: [String]
    /// False when the page's own text was used instead of recognising it.
    var recognised: Bool
    var confidence: Double
    var text: String { rows.joined(separator: "\n") }
}

enum PdfImageLoader {
    /// Decodes a picture for recognition with the EXIF orientation applied and the long side capped. SVG (ImageIO cannot read it) goes through NSImage.
    static func load(_ url: URL, maxSide: Int = 10_000) throws -> (image: CGImage, dpi: Double?) {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let dpi = props[kCGImagePropertyDPIWidth] as? Double
            if w > 0, h > 0 {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(w, h)), kCGImageSourceShouldCacheImmediately: true]
                if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) { return (img, dpi) }
            }
        }
        if let ns = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: CGSize(width: max(ns.size.width, 1) * 2, height: max(ns.size.height, 1) * 2))
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return (cg, nil) }
        }
        throw ConversionError.message(L10n("Unsupported image format: \(url.lastPathComponent)", "Неподдерживаемый формат изображения: \(url.lastPathComponent)"))
    }
}

enum PdfOcrPipeline {
    /// Longest side handed to Vision (pixels).
    static let maxRecognitionSide = 9_000

    /// Recognises one open page (rendered at `settings.dpi`, capped).
    static func recognize(page: PDFPage, number: Int, settings: PdfOcrSettings, ctx: OperationContext? = nil) async throws -> OcrPageText {
        let image = try PdfRasterizer.render(page, dpi: Double(settings.dpi), background: .white, annotations: true, maxLongSide: maxRecognitionSide)
        let r = try await OcrService.recognize(image, options: settings.ocrOptions)
        ctx?.log("Recognised page \(number): \(image.width)x\(image.height) px at \(settings.dpi) dpi, \(r.lines.count) line(s), confidence \(Int(r.confidence * 100)) percent")
        return OcrPageText(number: number, lines: r.observations, rows: r.lines, recognised: true, confidence: r.confidence)
    }

    /// Text of the selected pages: the page's own text when it has some and `skipText` is on, otherwise recognised.
    static func pageTexts(doc: PDFDocument, indices: [Int], settings: PdfOcrSettings, ctx: OperationContext, progress: ProgressSlice) async throws -> [OcrPageText] {
        var out: [OcrPageText] = []
        for (i, n) in indices.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            guard let page = doc.page(at: n) else { continue }
            if settings.skipText && PdfGeometry.hasText(page) {
                ctx.log("Page \(n + 1) already has text: used as it is")
                let t = PdfGeometry.text(of: page)
                out.append(OcrPageText(number: n + 1, lines: [], rows: t.components(separatedBy: "\n"), recognised: false, confidence: 1))
            } else {
                out.append(try await recognize(page: page, number: n + 1, settings: settings, ctx: ctx))
            }
            progress.report(Double(i + 1) / Double(indices.count))
        }
        return out
    }

    /// Recognises a picture file.
    static func recognize(imageAt url: URL, settings: PdfOcrSettings) async throws -> (page: OcrPageText, image: CGImage, dpi: Double?) {
        let (image, dpi) = try PdfImageLoader.load(url, maxSide: maxRecognitionSide)
        let r = try await OcrService.recognize(image, options: settings.ocrOptions)
        return (OcrPageText(number: 1, lines: r.observations, rows: r.lines, recognised: true, confidence: r.confidence), image, dpi)
    }

    // MARK: Searchable PDF

    /// Writes `output`: the pages of `source` with an invisible text layer where they had none. Pages that already have text stay as they are
    /// (`skipText`: copied by PDFKit, so an existing hidden text layer survives); with `skipText` off such pages are re-made from a picture so the
    /// recognised layer replaces the old text. Returns how many pages were recognised.
    @discardableResult
    static func makeSearchable(source: URL, doc: PDFDocument, to output: URL, indices: [Int], settings: PdfOcrSettings, stripMetadata: Bool,
                               ctx: OperationContext, progress: ProgressSlice) async throws -> Int {
        guard let cg = CGPDFDocument(source as CFURL) else { throw ConversionError.fileUnreadable(source) }
        let attrs = doc.documentAttributes
        var kept = Set<Int>()
        if settings.skipText {
            for n in indices { if let page = doc.page(at: n), PdfGeometry.hasText(page) { kept.insert(n) } }
        }
        // Only the recognised pages are composed; with kept pages in the mix the file is then assembled by PDFKit.
        let composedURL = kept.isEmpty ? output : ctx.tempDir.appendingPathComponent("recognised-\(Util.hex8()).pdf")
        defer { if !kept.isEmpty { try? FileManager.default.removeItem(at: composedURL) } }
        var recognisedPages = 0
        do {
            let composer = try PdfComposer(url: composedURL, title: stripMetadata ? nil : attrs?[PDFDocumentAttribute.titleAttribute] as? String,
                                           author: stripMetadata ? nil : attrs?[PDFDocumentAttribute.authorAttribute] as? String)
            defer { composer.close() }
            for (i, n) in indices.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                guard let page = doc.page(at: n), let cgPage = cg.page(at: n + 1) else { continue }
                if kept.contains(n) {
                    ctx.log("Page \(n + 1) already has text: copied as it is")
                } else {
                    let text = try await recognize(page: page, number: n + 1, settings: settings, ctx: ctx)
                    recognisedPages += 1
                    if PdfGeometry.hasText(page) {
                        // Replace the old text: a picture of the page carries the new layer.
                        let size = PdfGeometry.displayedSize(page)
                        let image = try PdfRasterizer.render(page, dpi: Double(settings.dpi), maxLongSide: maxRecognitionSide)
                        if let backed = PdfComposer.jpegBackedImage(try PdfComposer.jpegData(image, quality: 85)) {
                            composer.addImagePage(backed, size: size, text: text.lines)
                        } else { composer.addPage(cgPage, text: text.lines) }
                    } else {
                        composer.addPage(cgPage, text: text.lines)
                    }
                }
                progress.report(Double(i + 1) / Double(indices.count))
            }
        }
        if !kept.isEmpty {
            try PdfAssembly.write(doc: doc, indices: indices, kept: kept, fresh: recognisedPages > 0 ? composedURL : nil, stripMeta: stripMetadata, to: output)
        }
        return recognisedPages
    }

    /// A picture as a one-page searchable PDF (page size from the picture's DPI, 150 when it has none).
    static func makeSearchable(image: CGImage, dpi: Double?, text: [OcrLine], to output: URL) throws {
        let d = (dpi ?? 0) >= 36 ? dpi! : 150
        let size = CGSize(width: Double(image.width) * 72 / d, height: Double(image.height) * 72 / d)
        let composer = try PdfComposer(url: output)
        defer { composer.close() }
        var drawn = image
        if let jpeg = try? PdfComposer.jpegData(flattened(image), quality: 90), let backed = PdfComposer.jpegBackedImage(jpeg) { drawn = backed }
        composer.addImagePage(drawn, size: size, text: text)
    }

    /// The picture on a white sheet (JPEG has no alpha).
    private static func flattened(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
