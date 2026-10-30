import Foundation
import PDFKit
import CoreGraphics
import ImageIO

/// What the Studio shows around a PDF job: cross-field messages, a cheap size estimate, summary chips and a before / after page preview.
enum PdfStudio {
    // MARK: Validation

    static func validate(schemaID: String, options o: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        var out: [OptionMessage] = []
        let pageCount = source?.int("pdf.pages")
        let hasText = source?.bool("pdf.hasText")
        // Ranges that are fine as text but run past the end of this file.
        if let n = pageCount {
            for key in [PdfKeys.pages, PdfKeys.splitRanges] where o.has(key) {
                let text = o.string(key).trimmingCharacters(in: .whitespaces)
                if key == PdfKeys.splitRanges && o.string(PdfKeys.splitMode) != "ranges" { continue }
                if key == PdfKeys.pages && schemaID == PdfTargets.pages && o.string(PdfKeys.rotateScope) != "selected" { continue }
                if text.isEmpty || PageRange.parse(text, pageCount: nil) == nil { continue }
                let ok = text.split(separator: ",").allSatisfy { PageRange.parse(String($0), pageCount: n) != nil }
                if !ok {
                    out.append(OptionMessage(id: "pdf.range.beyond", severity: .error,
                                             text: L10n("The file has only \(n) pages.", "В файле всего \(n) стр."), fieldKey: key))
                }
            }
        }
        switch schemaID {
        case PdfTargets.optimize:
            if o.string(PdfKeys.mode) == "raster" && !o.bool(PdfKeys.ocr) && hasText == true {
                out.append(OptionMessage(id: "pdf.optimize.pixels", severity: .warning,
                                         text: L10n("The text will become a picture and can no longer be selected. Turn on recognition to keep it searchable.",
                                                    "Текст превратится в картинку и перестанет выделяться. Включите распознавание, чтобы сохранить поиск."),
                                         fieldKey: PdfKeys.ocr))
            }
        case PdfTargets.text, PdfTargets.export:
            if hasText == false && !o.bool(PdfKeys.ocr) {
                out.append(OptionMessage(id: "pdf.text.scan", severity: .warning,
                                         text: L10n("The pages are pictures with no text. Turn on recognition to read them.", "Страницы — картинки без текста. Включите распознавание, чтобы их прочитать."),
                                         fieldKey: PdfKeys.ocr))
            }
        case PdfTargets.unlock:
            if source?.bool("pdf.encrypted") == false {
                out.append(OptionMessage(id: "pdf.unlock.none", severity: .info, text: L10n("This file has no password.", "У этого файла нет пароля.")))
            }
        case PdfTargets.ocr:
            if hasText == true && !o.bool(PdfKeys.ocrSkipText, true) {
                out.append(OptionMessage(id: "pdf.ocr.replace", severity: .info,
                                         text: L10n("Pages that already have text are recognized again and their old text layer is replaced.", "Страницы с готовым текстом распознаются заново, старый текстовый слой заменяется.")))
            }
        default: break
        }
        return out
    }

    // MARK: Estimate

    /// Pages that a range selects in this file (all pages when the range or the page count is unknown).
    private static func selectedPages(_ o: OptionValues, total: Int) -> Int {
        guard total > 0 else { return 1 }
        return PageRange.parse(o.string(PdfKeys.pages, "all"), pageCount: total)?.count ?? total
    }

    static func estimate(schemaID: String, options o: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let size = Double(source?.sizeBytes ?? items.compactMap(\.size).first ?? 0)
        let total = source?.int("pdf.pages") ?? 0
        let selected = Double(selectedPages(o, total: total))
        let w = source?.number("pdf.width") ?? 595, h = source?.number("pdf.height") ?? 842
        switch schemaID {
        case PdfTargets.images:
            guard total > 0 else { return nil }
            let dpi = Double(o.int(PdfKeys.rasterDPI, 200))
            let pixels = (w * dpi / 72) * (h * dpi / 72)
            let perPixel: Double
            switch o.string(PdfKeys.rasterFormat, "png") {
            case "jpeg": perPixel = 0.03 + 0.25 * Double(o.int(PdfKeys.rasterQuality, 85)) / 100
            case "heic": perPixel = 0.02 + 0.12 * Double(o.int(PdfKeys.rasterQuality, 85)) / 100
            case "tiff": perPixel = 0.6
            default: perPixel = 0.12
            }
            return OperationEstimate(bytes: Int64(pixels * perPixel * selected * (o.bool(PdfKeys.rasterGray) ? 0.6 : 1)), seconds: selected * (0.05 + pixels / 1e8),
                                     confidence: .rough, note: L10n("Depends on the content of the pages.", "Зависит от содержимого страниц."))
        case PdfTargets.text, PdfTargets.export:
            let scan = source?.bool("pdf.hasText") == false && o.bool(PdfKeys.ocr)
            return OperationEstimate(bytes: Int64(selected * 3_000), seconds: scan ? selected * 1.2 : 0.5, confidence: .rough)
        case PdfTargets.optimize:
            guard size > 0 else { return nil }
            let s = PdfOptimizeSettings(options: o)
            let ratio: Double
            if s.mode == "raster" { ratio = min(1.2, Double(s.dpi * s.dpi) / 90_000 * Double(s.quality) / 75 * 0.35) }
            else { ratio = s.level == "high" ? 0.7 : (s.level == "screen" ? 0.35 : 0.45) }
            return OperationEstimate(bytes: Int64(size * ratio), seconds: s.mode == "raster" ? Double(max(total, 1)) * (s.ocr ? 1.4 : 0.15) : 1, confidence: .rough,
                                     note: L10n("Files without large images shrink little.", "Файлы без крупных изображений почти не уменьшаются."))
        case PdfTargets.extract:
            guard size > 0, total > 0 else { return nil }
            let keep = o.string(PdfKeys.extractMode) == "remove" ? Double(total) - selected : selected
            return OperationEstimate(bytes: Int64(size * max(keep, 1) / Double(total)), seconds: 0.5, confidence: .rough)
        case PdfTargets.ocr:
            return OperationEstimate(bytes: nil, seconds: Double(max(total, 1)) * 1.2, confidence: .rough)
        case PdfTargets.merge, PdfTargets.split, PdfTargets.pages, PdfTargets.protect, PdfTargets.unlock:
            guard size > 0 else { return nil }
            return OperationEstimate(bytes: Int64(size), seconds: 0.5 + Double(total) * 0.01, confidence: .rough)
        default: return nil
        }
    }

    // MARK: Chips

    static func chips(schemaID: String, options o: OptionValues, source: SourceInfo?) -> [String] {
        switch schemaID {
        case PdfTargets.images:
            var c = [o.string(PdfKeys.rasterFormat, "png").uppercased(), "\(o.int(PdfKeys.rasterDPI, 200)) dpi"]
            if o.bool(PdfKeys.rasterGray) { c.append(L("Gray", "Серый")) }
            return c
        case PdfTargets.text:
            return [o.string(PdfKeys.textFormat, "txt").uppercased(), o.string(PdfKeys.textEncoding, "utf8").uppercased()]
        case PdfTargets.export:
            return [o.string(PdfKeys.exportFormat, "docx").uppercased()]
        case PdfTargets.optimize:
            let s = PdfOptimizeSettings(options: o)
            var c = [s.mode == "raster" ? L("Pictures", "Картинки") : L("Keep text", "Текст"), s.mode == "raster" ? "\(s.dpi) dpi · Q\(s.quality)" : s.level.capitalized]
            if s.ocr { c.append("OCR") }
            return c
        case PdfTargets.split:
            return [o.string(PdfKeys.splitMode, "eachPage")]
        case PdfTargets.pages:
            var c: [String] = []
            if o.int(PdfKeys.rotate) != 0 { c.append("\(o.int(PdfKeys.rotate))°") }
            if o.string(PdfKeys.pageSize, "keep") != "keep" { c.append(o.string(PdfKeys.pageSize).uppercased()) }
            return c
        case PdfTargets.merge:
            return [o.string(PdfKeys.mergeOrder, "name")]
        case PdfTargets.extract:
            return [o.string(PdfKeys.pages, "1"), o.string(PdfKeys.extractMode, "keep")]
        case PdfTargets.ocr:
            return [o.string(PdfKeys.ocrOutput, "searchablePdf"), o.rows(PdfKeys.ocrLanguages).compactMap { $0["lang"]?.asString }.joined(separator: " ")].filter { !$0.isEmpty }
        default: return []
        }
    }

    // MARK: Preview

    /// Page 1 of the selection before / after the options (pixels at most `maxPixel` on the long side). Nil where a picture says nothing.
    static func preview(schemaID: String, items: [FileItem], options o: OptionValues, maxPixel: Int) async throws -> OperationPreview? {
        guard let item = items.first, item.kind == .pdf else { return nil }
        guard schemaID == PdfTargets.images || schemaID == PdfTargets.pages || schemaID == PdfTargets.optimize else { return nil }
        let doc = try PdfDoc.open(item.url)
        let index: Int
        if schemaID == PdfTargets.images, let first = PageRange.parse(o.string(PdfKeys.pages, "all"), pageCount: doc.pageCount)?.first { index = first } else { index = 0 }
        guard let page = doc.page(at: index) else { return nil }
        let before = try PdfRasterizer.render(page, dpi: 150, maxLongSide: maxPixel)
        try Task.checkCancellation()
        switch schemaID {
        case PdfTargets.images:
            var after = try PdfRasterizer.render(page, dpi: 150, background: o.bool(PdfKeys.rasterTransparent) ? nil : PdfJobs.color(o.string(PdfKeys.rasterBackground, "#FFFFFF")),
                                                 annotations: o.bool(PdfKeys.rasterAnnotations, true), grayscale: o.bool(PdfKeys.rasterGray), maxLongSide: maxPixel)
            if ["jpeg", "heic"].contains(o.string(PdfKeys.rasterFormat)), let round = jpegRoundTrip(after, quality: o.int(PdfKeys.rasterQuality, 85)) { after = round }
            return OperationPreview(before: before, after: after, note: L10n("Page \(index + 1)", "Страница \(index + 1)"))
        case PdfTargets.pages:
            PdfPageOps.rotate(doc, angle: o.int(PdfKeys.rotate), scope: o.string(PdfKeys.rotateScope, "all"), selection: Set(PageRange.parse(o.string(PdfKeys.pages, "1"), pageCount: doc.pageCount) ?? []))
            PdfPageOps.trim(doc, millimetres: o.double(PdfKeys.trim))
            let rotated = doc.page(at: 0) ?? page
            return OperationPreview(before: before, after: try PdfRasterizer.render(rotated, dpi: 150, maxLongSide: maxPixel), note: L10n("Page 1", "Страница 1"))
        default:
            let s = PdfOptimizeSettings(options: o)
            guard s.mode == "raster" else {
                return OperationPreview(before: before, after: nil, note: L10n("Text and vector shapes stay as they are; only images are re-compressed.", "Текст и векторная графика не меняются; пересжимаются только изображения."))
            }
            let image = try PdfRasterizer.render(page, dpi: Double(s.dpi), grayscale: s.gray, maxLongSide: maxPixel * 2)
            let after = jpegRoundTrip(image, quality: s.quality)
            return OperationPreview(before: before, after: after, note: L10n("Page 1 as a \(s.dpi) dpi picture", "Страница 1 как картинка \(s.dpi) dpi"))
        }
    }

    private static func jpegRoundTrip(_ image: CGImage, quality: Int) -> CGImage? {
        guard let data = try? PdfComposer.jpegData(image, quality: quality), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
