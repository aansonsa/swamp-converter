import Foundation
import ImageIO
import CoreGraphics

/// Formats that wrap several pictures or pages: ICO (one picture per size), ICNS (an iconset through `iconutil`), PDF (the picture as a JPEG page) and animated GIF.
enum ImageContainers {
    // MARK: ICO

    /// A square `side x side` frame with the picture fitted inside and centred on transparency.
    static func squareFrame(_ image: CGImage, side: Int) -> CGImage? {
        guard side > 0, image.width > 0, image.height > 0 else { return nil }
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let dw = max(1, Int((Double(image.width) * scale).rounded())), dh = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: ImageBitmap.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (side - dw) / 2, y: (side - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()
    }

    /// One ICO with a picture for every requested size (largest first).
    static func writeICO(_ image: CGImage, _ p: ImageEncodeParams, sink: ImageEncoder.Sink) throws {
        let sizes = p.icoSizes
        guard let dest = sink.destination(type: "com.microsoft.ico", count: sizes.count) else {
            throw ConversionError.unsupported(L10n("This Mac cannot write ICO files.", "Этот Mac не может записывать файлы ICO."))
        }
        for s in sizes {
            try Task.checkCancellation()
            guard let frame = squareFrame(image, side: s) else { throw ImageLoader.outOfMemory() }
            CGImageDestinationAddImage(dest, frame, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.message(L10n("The ICO file could not be written.", "Не удалось записать файл ICO.")) }
    }

    // MARK: ICNS

    /// An ICNS built by `iconutil` from an iconset of PNGs (16 to 1024 px, 1x and 2x). Sizes larger than the picture are left out, except the smallest two.
    static func writeICNS(_ image: CGImage, _ p: ImageEncodeParams, to url: URL) async throws {
        let iconutil = try ToolLocator.shared.require(.iconutil)
        let dir = AppPaths.makeTempDirectory(purpose: "icns")
        defer { AppPaths.removeTemp(dir) }
        let set = dir.appendingPathComponent("icon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let long = max(image.width, image.height)
        let entries: [(String, Int)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                                        ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
        for (name, px) in entries where px <= max(long, 32) {
            try Task.checkCancellation()
            guard let frame = squareFrame(image, side: px), let dest = CGImageDestinationCreateWithURL(set.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil) else {
                throw ImageLoader.outOfMemory()
            }
            CGImageDestinationAddImage(dest, frame, nil)
            guard CGImageDestinationFinalize(dest) else { throw ConversionError.message(L10n("The icon could not be prepared.", "Не удалось подготовить значок.")) }
        }
        try await ProcessRunner.run(iconutil, ["-c", "icns", set.path, "-o", url.path], toolName: "iconutil")
    }

    // MARK: PDF

    /// The picture flattened and compressed as JPEG, wrapped as a `CGImage` that Core Graphics embeds into a PDF WITHOUT recompressing
    /// (so the quality setting decides the file size). Falls back to the plain picture for sources JPEG cannot hold.
    static func jpegBacked(_ image: CGImage, quality: Int, background: CGColor) throws -> CGImage {
        var p = ImageEncodeParams(format: "jpeg", options: [ImageKeys.quality: .int(quality)])
        p.background = background
        p.metadataMode = "strip"
        let flat = try ImageEncoder.prepared(image, p)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return flat }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 1), 100)) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data as CFData),
              let backed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return flat }
        return backed
    }

    /// The picture as a PDF page image: JPEG-compressed at `quality` (the embedded bytes are those of the JPEG), or at quality 100 the flattened pixels themselves,
    /// which Core Graphics stores losslessly with Flate (the right choice for screenshots and scans).
    static func pageImage(_ image: CGImage, quality: Int, background: CGColor) throws -> CGImage {
        guard quality >= 100 else { return try jpegBacked(image, quality: quality, background: background) }
        var p = ImageEncodeParams(format: "pdf", options: [:])
        p.background = background
        return try ImageEncoder.prepared(image, p)
    }

    /// A PDF graphics context writing to a file or to memory. The caller closes it.
    static func makePDFContext(sink: ImageEncoder.Sink, mediaBox: inout CGRect) throws -> CGContext {
        let aux: [CFString: Any] = [kCGPDFContextCreator: "Swamp Converter"]
        let ctx: CGContext?
        switch sink {
        case .file(let url): ctx = CGContext(url as CFURL, mediaBox: &mediaBox, aux as CFDictionary)
        case .data(let d):
            if let consumer = CGDataConsumer(data: d) { ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, aux as CFDictionary) } else { ctx = nil }
        }
        guard let c = ctx else { throw ConversionError.message(L10n("The PDF file could not be created.", "Не удалось создать файл PDF.")) }
        return c
    }

    /// One page whose size is the picture's size at its resolution (`img.dpi`, else the source's DPI tag, else 72: one pixel per point).
    static func writePDF(_ image: CGImage, _ p: ImageEncodeParams, _ ctx: ImageEncodeContext, sink: ImageEncoder.Sink) throws {
        let dpi = p.dpi ?? ImageMetadata.dpi(ctx.sourceProperties)?.x ?? 72
        let k = 72 / max(1, dpi)
        var box = CGRect(x: 0, y: 0, width: (Double(image.width) * k).rounded(), height: (Double(image.height) * k).rounded())
        box.size.width = max(1, box.width); box.size.height = max(1, box.height)
        let page = try pageImage(image, quality: p.quality, background: p.background)
        let pdf = try makePDFContext(sink: sink, mediaBox: &box)
        pdf.beginPDFPage(nil)
        pdf.draw(page, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    // MARK: Animated GIF

    /// All frames with their delays (seconds) as one looping GIF.
    static func writeAnimatedGIF(frames: [(image: CGImage, delay: Double)], to url: URL) throws {
        guard !frames.isEmpty, let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else {
            throw ConversionError.unsupported(L10n("This Mac cannot write GIF files.", "Этот Mac не может записывать файлы GIF."))
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            try Task.checkCancellation()
            CGImageDestinationAddImage(dest, f.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(0.02, f.delay)]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.message(L10n("The GIF file could not be written.", "Не удалось записать файл GIF.")) }
    }
}
