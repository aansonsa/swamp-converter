import Foundation
import PDFKit
import CoreGraphics

/// Real compression (the original's "optimise" did nothing). Two methods:
///  * keepText - PDFKit re-saves the file with images re-encoded as JPEG (and, for Screen / Standard, limited to screen resolution): text and vectors stay vector.
///  * raster   - pages become pictures at the chosen DPI and JPEG quality (maximum compression; text becomes pixels), optionally with an invisible
///               recognised-text layer so the file stays searchable. Pages that already have text can stay vector (`skipText`).
struct PdfOptimizeSettings: Sendable {
    var mode = "keepText"
    var level = "standard"
    var dpi = 150
    var quality = 75
    var gray = false
    var flatten = false
    var stripMeta = false
    var ocr = false
    var keepTextPages = true
    var ocrSettings = PdfOcrSettings()

    /// DPI and JPEG quality of the three named levels (spec/handbrake.md 3.3 "Optimise").
    static let levels: [String: (dpi: Int, quality: Int)] = ["screen": (100, 60), "standard": (150, 75), "high": (220, 85)]

    init() {}

    init(options o: OptionValues) {
        mode = o.string(PdfKeys.mode, "keepText")
        level = o.string(PdfKeys.level, "standard")
        gray = o.bool(PdfKeys.imageGray)
        flatten = o.bool(PdfKeys.flatten)
        stripMeta = o.bool(PdfKeys.stripMeta)
        ocr = o.bool(PdfKeys.ocr)
        keepTextPages = o.bool(PdfKeys.ocrSkipText, true)
        ocrSettings = PdfOcrSettings(options: o)
        if let preset = Self.levels[level] { dpi = preset.dpi; quality = preset.quality }
        else { dpi = Util.clamp(o.int(PdfKeys.imageDPI, 150), 36, 600); quality = Util.clamp(o.int(PdfKeys.imageQuality, 75), 10, 100) }
    }

    /// Fallback when the Quartz filter is missing: PDFKit's "optimise for screen" flag (its own fixed resolution) for the levels that ask for screen resolution.
    var limitsImagesToScreen: Bool { dpi <= 150 }
}

enum PdfOptimizer {
    static func optimize(source: URL, doc: PDFDocument, settings: PdfOptimizeSettings, to output: URL, ctx: OperationContext, progress: ProgressSlice) async throws {
        if settings.mode == "raster" {
            try await rasterise(source: source, doc: doc, settings: settings, to: output, ctx: ctx, progress: progress)
        } else {
            if settings.stripMeta { PdfDoc.stripMetadata(doc) }
            try PdfDoc.write(doc, to: output, options: keepTextOptions(settings))
            progress.report(1)
        }
    }

    /// Images are re-saved as JPEG at the level's resolution and quality by the Quartz filter behind Preview's "Reduce File Size" (text and vectors untouched).
    /// Without the filter PDFKit's own flags are used: JPEG, and screen resolution for the lower levels.
    static func keepTextOptions(_ s: PdfOptimizeSettings) -> [PDFDocumentWriteOption: Any] {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let filter = PdfImageReducer.make(dpi: s.dpi, quality: Double(s.quality) / 100) {
            options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        } else {
            options[.saveImagesAsJPEGOption] = true
            if s.limitsImagesToScreen { options[.optimizeImagesForScreenOption] = true }
        }
        if s.flatten { options[.burnInAnnotationsOption] = true }
        return options
    }

    private static func rasterise(source: URL, doc: PDFDocument, settings s: PdfOptimizeSettings, to output: URL, ctx: OperationContext, progress: ProgressSlice) async throws {
        guard doc.pageCount > 0 else { throw ConversionError.fileUnreadable(source) }
        let attrs = doc.documentAttributes
        let total = doc.pageCount
        var kept = Set<Int>()
        if s.keepTextPages {
            for i in 0..<total { if let page = doc.page(at: i), PdfGeometry.hasText(page) { kept.insert(i) } }
        }
        // Pictures are composed on their own; with vector pages in the mix PDFKit copies those pages untouched (an invisible text layer survives) and the
        // assembled file gets one more pass that recompresses the images of the copied pages too.
        let composedURL = kept.isEmpty ? output : ctx.tempDir.appendingPathComponent("composed-\(Util.hex8()).pdf")
        defer { if !kept.isEmpty { try? FileManager.default.removeItem(at: composedURL) } }
        do {
            let composer = try PdfComposer(url: composedURL, title: s.stripMeta ? nil : attrs?[PDFDocumentAttribute.titleAttribute] as? String,
                                           author: s.stripMeta ? nil : attrs?[PDFDocumentAttribute.authorAttribute] as? String)
            defer { composer.close() }
            for i in 0..<total {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                guard let page = doc.page(at: i) else { continue }
                if !kept.contains(i) {
                    let size = PdfGeometry.displayedSize(page)
                    let jpeg: Data = try autoreleasepool {
                        let image = try PdfRasterizer.render(page, dpi: Double(s.dpi), background: .white, annotations: true, grayscale: s.gray)
                        return try PdfComposer.jpegData(image, quality: s.quality)
                    }
                    var lines: [OcrLine] = []
                    if s.ocr { lines = try await PdfOcrPipeline.recognize(page: page, number: i + 1, settings: s.ocrSettings, ctx: ctx).lines }
                    guard let backed = PdfComposer.jpegBackedImage(jpeg) else { throw ConversionError.message(L10n("Could not compress the page.", "Не удалось сжать страницу.")) }
                    composer.addImagePage(backed, size: size, text: lines)
                }
                progress.report(Double(i + 1) / Double(total))
            }
        }
        if !kept.isEmpty {
            try PdfAssembly.write(doc: doc, indices: Array(0..<total), kept: kept, fresh: kept.count < total ? composedURL : nil, stripMeta: s.stripMeta,
                                  options: keepTextOptions(s), to: output)
        } else if s.stripMeta, let d = PDFDocument(url: output) {
            PdfDoc.stripMetadata(d)
            try PdfDoc.write(d, to: output)
        }
    }

    /// An optimised file that came out bigger than the original is pointless: the caller keeps a copy of the original instead
    /// (unless the run also strips metadata, flattens, converts to grey or adds a text layer - those have their own purpose).
    static func shouldKeepOriginal(settings s: PdfOptimizeSettings, originalBytes: Int64, resultBytes: Int64) -> Bool {
        resultBytes >= originalBytes && !s.stripMeta && !s.flatten && !s.gray && !s.ocr
    }
}


/// The Quartz filter behind Preview's "Reduce File Size", configured with the level's resolution and JPEG quality. `QuartzFilters` is a sub-framework of Quartz
/// that is not linked at launch (it would pull ImageKit into every start): it is loaded the first time a PDF is optimised. Nil when it is not there.
enum PdfImageReducer {
    private static let loaded: Bool = {
        dlopen("/System/Library/Frameworks/Quartz.framework/Versions/A/Frameworks/QuartzFilters.framework/QuartzFilters", RTLD_LAZY) != nil
    }()

    /// Test hook: pretend the filter is missing to exercise the PDFKit fallback.
    nonisolated(unsafe) static var forceUnavailable = false

    static var isAvailable: Bool { !forceUnavailable && loaded && NSClassFromString("QuartzFilter") != nil }

    static func make(dpi: Int, quality: Double) -> AnyObject? {
        guard isAvailable, let cls = NSClassFromString("QuartzFilter") as? NSObject.Type else { return nil }
        let props: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Swamp optimize",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": Util.clamp(quality, 0.05, 1),
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": 100_000, "ImageSizeMin": 0]
            ] as [String: Any]]]
        ]
        return cls.perform(NSSelectorFromString("quartzFilterWithProperties:"), with: props)?.takeUnretainedValue()
    }
}
