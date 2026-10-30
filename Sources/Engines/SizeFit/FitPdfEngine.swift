import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO

enum PdfFit {
    /// Iterative downsampling: re-save with `.optimizeImagesForScreenOption` / `.saveImagesAsJPEGOption`, then lower the raster DPI of image pages
    /// (300 -> 200 -> 150 -> 110 -> 72) until the size fits. Text and vector content stay as they are while possible.
    ///
    /// How: the document is re-saved through a Quartz filter (the engine behind Preview's "Reduce File Size") whose image resolution and JPEG quality follow one
    /// "level" knob (`PdfFitCurve`); `PdfFitSearch` finds the lowest level that fits, so the pictures stay as sharp as the limit allows and text and vector
    /// drawings are not touched. When no level fits and pages may be turned into pictures, every page is redrawn as a JPEG with an invisible text layer on top
    /// (the text stays selectable and searchable). Where the Quartz filter cannot be loaded, the plain PDFKit options (JPEG images, optimised for screen) are the fallback.
    static func run(input: FileItem, targetBytes: Int64, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws -> FitResult {
        try ctx.checkCancelled()
        let suffix = FitNaming.suffix(options)
        let sourceSize = input.size ?? FitProbe.fileSize(input.url)
        if sourceSize > 0, sourceSize <= targetBytes {
            let url = try await FitFiles.copyUnchanged(input, ext: "pdf", suffix: suffix, ctx: ctx)
            return FitResult(output: url, achievedBytes: FitProbe.fileSize(url), targetBytes: targetBytes, notes: [FitMessages.alreadySmall])
        }
        guard let doc = PDFDocument(url: input.url) else { throw ConversionError.fileUnreadable(input.url) }
        if doc.isLocked || doc.isEncrypted {
            throw ConversionError.message(L10n("This PDF is protected with a password. Remove the protection first (Tools > Unlock PDF), then fit it to a size.",
                                               "Этот PDF защищён паролем. Сначала снимите защиту (Инструменты > Снять защиту PDF), затем уменьшайте размер."))
        }
        guard doc.pageCount > 0 else { throw ConversionError.noOutput }
        let strip = options.bool(FitKeys.stripMetadata, false)
        let minQ = options.int(FitKeys.minQuality, 50)
        let allowPages = options.bool(FitKeys.allowDownscale, true)
        let work = ctx.tempDir.appendingPathComponent("pdf-fit-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var smallest = Int64.max
        var runs = 0
        func finish(_ url: URL, _ bytes: Int64) { smallest = min(smallest, bytes); runs += 1 }

        // 1. Vector-preserving: re-save with the filter, searching the level.
        var files: [Double: URL] = [:]
        let filterAvailable = PdfQuartzFilter.isAvailable
        let vectorOutcome = try PdfFitSearch.search(targetBytes: targetBytes, range: PdfFitCurve.imageRange) { t in
            try ctx.checkCancelled()
            let url = work.appendingPathComponent("v-\(files.count).pdf")
            let s = PdfFitCurve.imageSettings(level: t, minQuality: minQ)
            try writeFiltered(doc, to: url, settings: s, strip: strip)
            let bytes = FitProbe.fileSize(url)
            files[t] = url; finish(url, bytes)
            progress.report(min(0.9, Double(runs) * 0.12))
            return bytes
        }
        var chosen: (url: URL, bytes: Int64, notes: [L10n])?
        if let o = vectorOutcome, let url = files[o.level] {
            let s = PdfFitCurve.imageSettings(level: o.level, minQuality: minQ)
            var notes: [L10n] = []
            if o.level > 0.01 { notes.append(L10n("Pictures inside the PDF were reduced to \(s.dpi) dpi; text and drawings are unchanged.", "Картинки внутри PDF уменьшены до \(s.dpi) dpi; текст и рисунки не тронуты.")) }
            if !filterAvailable { notes.append(L10n("The basic method was used for the pictures.", "Для картинок использован базовый способ.")) }
            // The Quartz re-encoding has a top JPEG quality and a coarse jump above it: a limit inside that jump is answered by the sharpest result below it, and the person is told why.
            if Double(o.bytes) < Double(targetBytes) * FitTuning.fillGoal, o.level > PdfFitCurve.imageRange.lowerBound + 1e-9 {
                notes.append(L10n("The result is smaller than the limit: the next sharper setting would not fit under it, so the pictures keep the best quality this method allows.",
                                  "Результат меньше лимита: следующая, более чёткая настройка уже не уместилась бы, поэтому картинки сохранены в наилучшем качестве, какое даёт этот способ."))
            }
            chosen = (url, o.bytes, notes)
        } else if allowPages {
            // 2. Last resort: pages as pictures with an invisible text layer.
            var pageFiles: [Double: URL] = [:]
            let pageOutcome = try PdfFitSearch.search(targetBytes: targetBytes, range: PdfFitCurve.pageRange) { t in
                try ctx.checkCancelled()
                let url = work.appendingPathComponent("p-\(pageFiles.count).pdf")
                let s = PdfFitCurve.pageSettings(level: t, minQuality: minQ)
                try rasterise(doc, to: url, settings: s, strip: strip, ctx: ctx)
                let bytes = FitProbe.fileSize(url)
                pageFiles[t] = url; finish(url, bytes)
                progress.report(min(0.95, 0.5 + Double(pageFiles.count) * 0.08))
                return bytes
            }
            if let o = pageOutcome, let url = pageFiles[o.level] {
                let s = PdfFitCurve.pageSettings(level: o.level, minQuality: minQ)
                chosen = (url, o.bytes, [L10n("Pages were turned into pictures (\(s.dpi) dpi) to fit; the text stays selectable.",
                                              "Страницы превращены в картинки (\(s.dpi) dpi), чтобы уложиться; текст остаётся выделяемым.")])
            }
        }
        guard let chosen else {
            throw FitMessages.tooSmall(kind: .pdf, smallest: smallest == .max ? 0 : smallest, target: targetBytes)
        }
        let output = try await ctx.produceFile(for: input, suffix: suffix, ext: "pdf") { temp in try FileManager.default.copyItem(at: chosen.url, to: temp) }
        progress.report(1)
        return FitResult(output: output, achievedBytes: FitProbe.fileSize(output), targetBytes: targetBytes, notes: chosen.notes)
    }

    // MARK: Writers

    /// Re-saves `doc` with images at `settings.dpi` and JPEG quality `settings.quality` (Quartz filter), or with the PDFKit options when the filter is unavailable.
    static func writeFiltered(_ doc: PDFDocument, to url: URL, settings: PdfFitCurve.Settings, strip: Bool) throws {
        var opts: [PDFDocumentWriteOption: Any] = [:]
        if let filter = PdfQuartzFilter.make(dpi: settings.dpi, quality: settings.quality) {
            opts[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        } else {
            opts[.saveImagesAsJPEGOption] = true
            opts[.optimizeImagesForScreenOption] = true
        }
        let saved = doc.documentAttributes
        if strip { doc.documentAttributes = [:] }
        defer { if strip { doc.documentAttributes = saved } }
        guard doc.write(to: url, withOptions: opts) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
    }

    /// Redraws every page as a JPEG picture at `settings.dpi` and lays the original text over it invisibly.
    static func rasterise(_ doc: PDFDocument, to url: URL, settings: PdfFitCurve.Settings, strip: Bool, ctx: OperationContext) throws {
        var aux: [CFString: Any] = [:]
        if !strip, let attrs = doc.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { aux[kCGPDFContextTitle] = t }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { aux[kCGPDFContextAuthor] = a }
            if let s = attrs[PDFDocumentAttribute.subjectAttribute] as? String { aux[kCGPDFContextSubject] = s }
        }
        guard let first = doc.page(at: 0)?.pageRef else { throw ConversionError.noOutput }
        var box0 = first.getBoxRect(.mediaBox)
        guard let out = CGContext(url as CFURL, mediaBox: &box0, aux as CFDictionary) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        for i in 0..<doc.pageCount {
            try ctx.checkCancelled()
            try autoreleasepool {
                guard let page = doc.page(at: i), let ref = page.pageRef else { return }
                let size = PdfPageGeometry.displaySize(ref)
                var mediaBox = CGRect(origin: .zero, size: size)
                let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
                let pixelsW = max(1, Int((size.width * CGFloat(settings.dpi) / 72).rounded())), pixelsH = max(1, Int((size.height * CGFloat(settings.dpi) / 72).rounded()))
                guard let bitmap = PdfPageGeometry.render(ref, pixelWidth: pixelsW, pixelHeight: pixelsH),
                      let jpeg = jpegData(bitmap, quality: settings.quality), let provider = CGDataProvider(data: jpeg as CFData),
                      let picture = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ConversionError.noOutput }
                out.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                out.draw(picture, in: mediaBox)
                if ref.rotationAngle == 0 { PdfInvisibleText.draw(page: page, in: out) }
                out.endPDFPage()
            }
        }
        out.closePDF()
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// The Quartz filter behind Preview's "Reduce File Size", configured with our own resolution and quality. QuartzFilters is a sub-framework of Quartz that
/// is not linked (it would pull ImageKit and more into every launch): it is loaded the first time a PDF is fitted. nil when it is not there.
enum PdfQuartzFilter {
    private static let loaded: Bool = {
        dlopen("/System/Library/Frameworks/Quartz.framework/Versions/A/Frameworks/QuartzFilters.framework/QuartzFilters", RTLD_LAZY) != nil
    }()

    /// Test hook: pretend the filter is missing to exercise the plain PDFKit fallback.
    nonisolated(unsafe) static var forceUnavailable = false

    static var isAvailable: Bool { !forceUnavailable && loaded && NSClassFromString("QuartzFilter") != nil }

    static func make(dpi: Int, quality: Double) -> AnyObject? {
        guard isAvailable, let cls = NSClassFromString("QuartzFilter") as? NSObject.Type else { return nil }
        let props: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Swamp fit",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": 100_000, "ImageSizeMin": 0]
            ] as [String: Any]]]
        ]
        return cls.perform(NSSelectorFromString("quartzFilterWithProperties:"), with: props)?.takeUnretainedValue()
    }
}

/// Page geometry that honours /Rotate (PDFKit's `bounds(for:)` does not).
enum PdfPageGeometry {
    static func displaySize(_ ref: CGPDFPage) -> CGSize {
        let b = ref.getBoxRect(.mediaBox)
        return ref.rotationAngle % 180 == 90 ? CGSize(width: b.height, height: b.width) : b.size
    }

    /// The page on a white bitmap of the given pixel size.
    static func render(_ ref: CGPDFPage, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }
}

/// Lays the text of an unrotated page over its picture invisibly, line by line, so the flattened page can still be searched and copied.
enum PdfInvisibleText {
    static func draw(page: PDFPage, in ctx: CGContext) {
        let bounds = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: bounds) else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in selection.selectionsByLine() {
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let box = line.bounds(for: page)
            guard box.width > 1, box.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(box.height * 0.85, 1), nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            ctx.saveGState()
            ctx.translateBy(x: box.minX - bounds.minX, y: box.minY - bounds.minY + box.height * 0.2)
            if width > 0 { ctx.scaleBy(x: box.width / CGFloat(width), y: 1) }
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
