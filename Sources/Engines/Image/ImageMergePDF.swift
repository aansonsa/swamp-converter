import Foundation
import ImageIO
import CoreGraphics

/// Images to one PDF. Every picture becomes a page; the pictures are compressed as JPEG (`img.quality`) and embedded without recompression.
enum ImageMergePDF {
    /// Portrait page sizes in points.
    static func pageSize(_ name: String) -> CGSize? {
        switch name {
        case "a4": return CGSize(width: 595.276, height: 841.89)
        case "a5": return CGSize(width: 419.528, height: 595.276)
        case "a3": return CGSize(width: 841.89, height: 1190.551)
        case "letter": return CGSize(width: 612, height: 792)
        default: return nil
        }
    }

    /// Items in page order.
    static func ordered(_ items: [FileItem], by order: String) -> [FileItem] {
        switch order {
        case "name": return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "date":
            func date(_ i: FileItem) -> Date { ((try? FileManager.default.attributesOfItem(atPath: i.url.path))?[.modificationDate] as? Date) ?? .distantPast }
            return items.sorted { let a = date($0), b = date($1); return a == b ? Util.naturalCompare($0.url.path, $1.url.path) == .orderedAscending : a < b }
        case "selection": return items
        default: return items.sorted { Util.naturalCompare($0.url.path, $1.url.path) == .orderedAscending }
        }
    }

    /// The page and the rectangle the picture is drawn into (both in points) for a picture of `pixelsW x pixelsH`.
    static func layout(pixelsW: Int, pixelsH: Int, dpiTag: Double?, options o: OptionValues) -> (page: CGRect, picture: CGRect, clip: CGRect?) {
        let iw = Double(max(1, pixelsW)), ih = Double(max(1, pixelsH))
        guard let base = pageSize(o.string(ImageKeys.pdfPageSize, "image")) else {
            let dpi = Double(o.string(ImageKeys.dpi, "keep")) ?? dpiTag ?? 72
            let k = 72 / max(1, dpi)
            let page = CGRect(x: 0, y: 0, width: max(1, (iw * k).rounded()), height: max(1, (ih * k).rounded()))
            return (page, page, nil)
        }
        var landscape = iw > ih
        switch o.string(ImageKeys.pdfOrientation, "auto") {
        case "portrait": landscape = false
        case "landscape": landscape = true
        default: break
        }
        let pageSize = landscape ? CGSize(width: base.height, height: base.width) : base
        let page = CGRect(origin: .zero, size: pageSize)
        let margin = min(Double(o.int(ImageKeys.pdfMargin, 10)) * 72 / 25.4, Double(min(pageSize.width, pageSize.height)) * 0.4)
        let content = page.insetBy(dx: margin, dy: margin)
        let cover = o.string(ImageKeys.pdfFit, "contain") == "cover"
        let s = cover ? max(content.width / iw, content.height / ih) : min(content.width / iw, content.height / ih)
        let w = iw * s, h = ih * s
        return (page, CGRect(x: content.midX - w / 2, y: content.midY - h / 2, width: w, height: h), cover ? content : nil)
    }

    static func run(_ items: [FileItem], ctx: OperationContext) async throws -> URL {
        let o = ctx.options
        let sorted = ordered(items, by: o.string(ImageKeys.pdfOrder, "natural"))
        guard let first = sorted.first else { throw ConversionError.noOutput }
        let quality = o.int(ImageKeys.quality, 90)
        let background = ImageFormat.color(hex: o.string(ImageKeys.alphaBackground, "#FFFFFF"))
        let name = ctx.outputBaseName(for: first)
        return try await ctx.produceFile(for: first, ext: "pdf", base: name) { tmp in
            var placeholder = CGRect(x: 0, y: 0, width: 612, height: 792)
            let pdf = try ImageContainers.makePDFContext(sink: .file(tmp), mediaBox: &placeholder)
            for (i, item) in sorted.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                ctx.setCurrentItem(item, index: i, count: sorted.count)
                try autoreleasepool {
                    let props = ImageMetadata.read(item.url)
                    let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 1, h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 1
                    let upright = Dihedral(orientation: ImageMetadata.orientation(props)).size(of: w, h)
                    let g = layout(pixelsW: upright.width, pixelsH: upright.height, dpiTag: ImageMetadata.dpi(props)?.x, options: o)
                    // Pictures are decoded no larger than the page can show at 300 dpi.
                    var opts = ImageLoader.Options()
                    let need = Int((max(g.picture.width, g.picture.height) * 300 / 72).rounded(.up))
                    if o.string(ImageKeys.pdfPageSize, "image") != "image", need * 2 < max(w, h) { opts.maxPixel = need }
                    guard let loaded = try? ImageLoader.loadUnoriented(item.url, opts) else { throw ConversionError.fileUnreadable(item.url) }
                    let image = try ImageProcessor.process(loaded, spec: ImageSpec())
                    let page = try ImageContainers.pageImage(image, quality: quality, background: background)
                    var box = g.page
                    let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
                    pdf.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                    if let clip = g.clip { pdf.saveGState(); pdf.clip(to: clip) }
                    pdf.draw(page, in: g.picture)
                    if g.clip != nil { pdf.restoreGState() }
                    pdf.endPDFPage()
                }
                ctx.report(Double(i + 1) / Double(sorted.count))
            }
            pdf.closePDF()
        }
    }
}
