import Foundation
import CoreGraphics
import ImageIO

enum ImageFit {
    /// Which file the result is written as. `requested` is the `FitKeys.imageFormat` option. Pure: the capabilities are passed in.
    ///  - keep format: the source format when it can be written with a size dial (JPEG, HEIC, PNG, WebP), else JPEG (PNG for transparency);
    ///  - otherwise: `auto` = JPEG (it opens everywhere), PNG when the picture has transparency; `heic` / `webp` / `jpg` as asked when this Mac can write them.
    static func chooseFormat(sourceKey: String, hasAlpha: Bool, keepFormat: Bool, requested: String, canHEIC: Bool, canWebP: Bool) -> (format: FitImageIO.Format, note: L10n?) {
        let fallback: FitImageIO.Format = hasAlpha ? .png : .jpg
        if keepFormat {
            switch sourceKey {
            case "jpg": return (.jpg, nil)
            case "png": return (.png, nil)
            case "heic": return canHEIC ? (.heic, nil) : (.jpg, nil)
            case "webp": return canWebP ? (.webp, nil) : (fallback, L10n("WebP needs cwebp, so the picture was saved as \(fallback.rawValue.uppercased()).", "Для WebP нужен cwebp, поэтому картинка сохранена как \(fallback.rawValue.uppercased())."))
            default: return (fallback, nil)
            }
        }
        switch requested {
        case "heic":
            return canHEIC ? (.heic, nil) : (fallback, L10n("This Mac cannot write HEIC, so the picture was saved as \(fallback.rawValue.uppercased()).", "Этот Mac не умеет писать HEIC, поэтому картинка сохранена как \(fallback.rawValue.uppercased())."))
        case "webp":
            return canWebP ? (.webp, nil) : (fallback, L10n("WebP needs cwebp, so the picture was saved as \(fallback.rawValue.uppercased()).", "Для WebP нужен cwebp, поэтому картинка сохранена как \(fallback.rawValue.uppercased())."))
        case "jpg": return (.jpg, nil)
        default: return (fallback, nil)
        }
    }

    /// The loop: ImageFitSearch decides which probe to try, this encodes it (JPEG / HEIC / PNG through ImageIO, WebP through the image module) and reports
    /// the size. Pictures are decoded straight to the probe's size from the file, so a 50-megapixel photo is never held at full size more than once.
    static func run(input: FileItem, targetBytes: Int64, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws -> FitResult {
        try ctx.checkCancelled()
        let suffix = FitNaming.suffix(options)
        let sourceSize = input.size ?? FitProbe.fileSize(input.url)
        if sourceSize > 0, sourceSize <= targetBytes, !input.kind.isRawLike {
            let url = try await FitFiles.copyUnchanged(input, ext: input.url.pathExtension.isEmpty ? "jpg" : input.url.pathExtension, suffix: suffix, ctx: ctx)
            return FitResult(output: url, achievedBytes: FitProbe.fileSize(url), targetBytes: targetBytes, notes: [FitMessages.alreadySmall])
        }
        guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil), let facts = FitImageIO.facts(of: source) else { throw ConversionError.fileUnreadable(input.url) }
        let (format, formatNote) = chooseFormat(sourceKey: input.key, hasAlpha: facts.hasAlpha, keepFormat: options.bool(FitKeys.keepFormat, false),
                                                requested: options.string(FitKeys.imageFormat, "auto"), canHEIC: FitImageIO.canWrite("public.heic"),
                                                canWebP: ctx.tools.has(.cwebp))
        let allowResize = options.bool(FitKeys.allowDownscale, true)
        let strip = options.bool(FitKeys.stripMetadata, false)
        let minQ = format.isLossy ? options.int(FitKeys.minQuality, 60) : 100
        let longEdge = max(facts.displayWidth, facts.displayHeight)
        var search = ImageFitSearch(targetBytes: Int(clamping: targetBytes), minQuality: minQ, maxQuality: 100, allowResize: allowResize, longEdge: longEdge)

        var decoded: (pixel: Int, image: CGImage)?
        var bestData: Data?
        var bestSize = (width: facts.displayWidth, height: facts.displayHeight)
        while let probe = search.next() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            let maxPixel = max(1, Int((Double(longEdge) * probe.scale).rounded()))
            let image: CGImage
            if let d = decoded, d.pixel == maxPixel { image = d.image }
            else {
                guard let img = FitImageIO.decode(source, maxPixel: maxPixel) else { throw ConversionError.fileUnreadable(input.url) }
                decoded = (maxPixel, img); image = img
            }
            let data: Data
            if format == .webp {
                data = try await ImageEncoder.encode(image, format: "webp", options: [ImageKeys.quality: .int(probe.quality), ImageKeys.mdMode: .string(strip ? "strip" : "keep")], source: input.url)
            } else {
                data = try FitImageIO.encode(image, format: format, quality: probe.quality,
                                             metadata: FitImageIO.metadata(of: source, strip: strip, width: image.width, height: image.height), flatten: !format.hasAlpha)
            }
            search.record(bytes: data.count)
            ctx.log("fit.image probe: \(image.width)x\(image.height) q\(probe.quality) -> \(data.count) bytes (target \(targetBytes))")
            if let b = search.best, b.probe == probe { bestData = data; bestSize = (image.width, image.height) }
            progress.report(min(0.95, Double(search.probeCount) / 12))
        }
        guard case .fit(let probe, let bytes)? = search.result, let data = bestData else {
            if case .unreachable(let smallest)? = search.result, !allowResize {
                let s = Util.formatBytes(Int64(smallest)), t = Util.formatBytes(targetBytes)
                throw ConversionError.message(L10n("At the lowest quality allowed the picture is still \(s), more than \(t). Allow a smaller picture size or lower the minimum quality.",
                                                   "При минимально допустимом качестве картинка всё равно занимает \(s), это больше \(t). Разрешите уменьшать размер картинки или снизьте минимальное качество."))
            }
            throw FitMessages.tooSmall(kind: .image, smallest: Int64(search.smallest == .max ? 0 : search.smallest), target: targetBytes)
        }
        let output = try await ctx.produceFile(for: input, suffix: suffix, ext: format.rawValue) { temp in try data.write(to: temp) }
        progress.report(1)

        var notes: [L10n] = formatNote.map { [$0] } ?? []
        if probe.scale < 0.999 {
            notes.append(L10n("Reduced to \(bestSize.width) x \(bestSize.height) px to fit", "Уменьшено до \(bestSize.width) x \(bestSize.height) px, чтобы уложиться"))
        }
        if facts.hasAlpha, !format.hasAlpha {
            notes.append(L10n("Transparency was replaced with white.", "Прозрачность заменена белым цветом."))
        }
        if CGImageSourceGetCount(source) > 1 {
            notes.append(L10n("Only the first frame was used.", "Использован только первый кадр."))
        }
        if Double(bytes) < Double(targetBytes) * FitTuning.fillGoal, probe.quality >= 100 || !format.isLossy, probe.scale >= 0.999 {
            notes.append(L10n("The picture is already at its best, so the file is smaller than the limit.", "Качество картинки уже максимальное, поэтому файл меньше лимита."))
        }
        return FitResult(output: output, achievedBytes: FitProbe.fileSize(output), targetBytes: targetBytes, notes: notes)
    }
}

private extension FileKind {
    /// RAW files are never copied unchanged as "the result": the point of the tool is a picture others can open.
    var isRawLike: Bool { self == .raw }
}
