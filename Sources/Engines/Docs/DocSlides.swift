import Foundation
import PDFKit

// Slides (pptx, ppt, odp) through LibreOffice. pdf / pptx / odp are one LibreOffice run; png / jpg run LibreOffice to a temporary PDF and render the chosen pages with the
// shared PDF renderer (one slide -> a file, several -> the folder "name (pages)"). The slide range is applied to the PDF with PDFKit, so it works the same for every output
// and does not depend on LibreOffice's own range syntax.

enum DocSlides {
    static func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let target = o.string(DocKeys.format, "pdf")
        let rangeText = o.string(DocKeys.slideRange)
        if !rangeText.isEmpty, rangeText.lowercased() != "all", DocPageRange.indices(rangeText, count: 100_000) == nil {
            throw ConversionError.invalidOption(key: DocKeys.slideRange, reason: L10n("Write slides like 1-3, 5.", "Укажите слайды так: 1-3, 5."))
        }
        let work = ctx.tempDir.appendingPathComponent("slides-\(Util.hex8())", isDirectory: true)
        let lo = ProgressSlice(ctx: ctx, index: progress.index * 2, count: progress.count * 2)
        // The first half of the progress is LibreOffice (it cannot report), the second half is rendering / writing.
        switch target {
        case "pptx", "odp":
            let url = try await ctx.produceFile(for: item, ext: target) { tmp in
                let made = try await DocConverter.officeConvert(input: item.url, filter: target, outputDirectory: work, ctx: ctx)
                try FileManager.default.moveItem(at: made, to: tmp)
            }
            progress.report(1)
            return [url]
        default:
            break
        }
        let deck = try await DocConverter.officeConvert(input: item.url, filter: "pdf", outputDirectory: work, ctx: ctx)
        lo.report(1)
        guard let doc = PDFDocument(url: deck), doc.pageCount > 0 else { throw ConversionError.message(DocOffice.failureMessage) }
        let all = Array(0..<doc.pageCount)
        let chosen = rangeText.isEmpty || rangeText.lowercased() == "all" ? all : (DocPageRange.indices(rangeText, count: doc.pageCount) ?? all)
        guard !chosen.isEmpty else {
            throw ConversionError.invalidOption(key: DocKeys.slideRange, reason: L10n("The deck has \(doc.pageCount) slides; none of the chosen ones exist.", "В презентации слайдов: \(doc.pageCount); выбранных среди них нет."))
        }
        let rest = ProgressSlice(ctx: ctx, index: progress.index * 2 + 1, count: progress.count * 2)
        if target == "pdf" {
            let url = try await ctx.produceFile(for: item, ext: "pdf") { tmp in
                if chosen.count == doc.pageCount { try FileManager.default.moveItem(at: deck, to: tmp); return }
                let subset = PDFDocument()
                for (i, n) in chosen.enumerated() { if let p = doc.page(at: n) { subset.insert(p, at: i) } }
                guard subset.write(to: tmp) else { throw ConversionError.noOutput }
            }
            rest.report(1)
            return [url]
        }
        return try await PdfRasterizer.rasterize(pdf: deck, source: item, options: rasterOptions(o, target: target, pages: chosen), ctx: ctx, progress: rest)
    }

    /// The picture settings of a slides run, as the shared PDF renderer takes them.
    static func rasterOptions(_ o: OptionValues, target: String, pages: [Int]?) -> PdfRasterOptions {
        var r = PdfRasterOptions()
        r.dpi = Int(Util.clamp(o.int(DocKeys.slideDPI, 300), 72, 600))
        r.format = target == "jpg" ? "jpeg" : "png"
        r.quality = Int(Util.clamp(o.int(DocKeys.slideFormatQuality, 90), 50, 100))
        r.background = DocColor.rgba(o.string(DocKeys.slideBackground, "#FFFFFF")) ?? .white
        r.pages = pages
        return r
    }
}

/// "1-3, 5", "2-" (to the end), "all" or empty -> zero-based page indices, ascending and unique. nil when the text is malformed or selects nothing inside `count`.
enum DocPageRange {
    static func indices(_ text: String, count: Int) -> [Int]? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "all" { return Array(0..<count) }
        var picked = Set<Int>()
        for part in t.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { return nil }
            let ends = p.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if ends.count == 1 {
                guard let n = Int(ends[0]), n >= 1 else { return nil }
                if n <= count { picked.insert(n - 1) }
            } else {
                guard let a = Int(ends[0]), a >= 1 else { return nil }
                let b = ends[1].isEmpty ? count : (Int(ends[1]) ?? -1)
                guard b >= a else { return nil }
                if a <= count { for n in a...min(b, count) { picked.insert(n - 1) } }
            }
        }
        return picked.sorted()
    }
}

enum DocColor {
    /// "#RRGGBB" / "RRGGBB" -> RGBA.
    static func rgba(_ hex: String) -> RGBA? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGBA(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
}
