import Foundation
import ImageIO
import CoreGraphics

/// Everything that decides HOW a finished picture is written, read from the image option keys (`ImageKeys`). Missing keys fall back to the schema defaults, so
/// other modules can call the encoder with a one-key dictionary such as `[ImageKeys.quality: 80]`.
struct ImageEncodeParams: Sendable {
    var format: String
    var quality = 90
    var lossless = false
    var progressive = false
    var fullColour444 = false
    var background = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    var pngInterlace = false
    var pngPalette = false
    /// Lossless re-filtering and re-deflating of PNG output (`PNGOptimizer`). Off for throw-away intermediates that another tool reads next.
    var optimizePNG = true
    var tiffCompression = "lzw"
    var icoSizes: [Int] = [256, 128, 64, 48, 32, 16]
    /// nil = keep what the source says.
    var dpi: Double? = nil
    var metadataMode = "keep"
    /// Output size limit in bytes (WebP uses cwebp's own size search; other formats are searched by the caller). nil = off.
    var targetBytes: Int? = nil

    init(format: String, options o: OptionValues) {
        typealias K = ImageKeys
        self.format = ImageFormat.canonical(format)
        quality = min(100, max(1, o.int(K.quality, 90)))
        lossless = o.bool(K.lossless)
        progressive = o.bool(K.progressive)
        fullColour444 = o.string(K.subsampling, "420") == "444"
        background = ImageFormat.color(hex: o.string(K.alphaBackground, "#FFFFFF"))
        pngInterlace = o.bool(K.pngInterlace)
        pngPalette = o.bool(K.pngPalette)
        tiffCompression = o.string(K.tiffCompression, "lzw")
        icoSizes = Self.parseSizes(o.string(K.icoSizes, ""))
        if let d = Double(o.string(K.dpi, "keep")), d >= 1 { dpi = d }
        metadataMode = o.string(K.mdMode, "keep")
        if o.int(K.targetKB) > 0 { targetBytes = o.int(K.targetKB) * 1024 }
    }

    /// "256, 128 64" -> [256, 128, 64]; values outside 1...256 are dropped; empty input gives the standard set.
    static func parseSizes(_ text: String) -> [Int] {
        let nums = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...256).contains($0) }
        let unique = Array(Set(nums)).sorted(by: >)
        return unique.isEmpty ? [256, 128, 64, 48, 32, 16] : Array(unique.prefix(12))
    }
}

/// What the encoder needs to know about the picture's origin.
struct ImageEncodeContext: @unchecked Sendable {
    var sourceURL: URL? = nil
    var sourceProperties: [CFString: Any]? = nil
    /// EXIF orientation to record next to UNROTATED pixels (only when auto-rotation is off and the format can carry it); 1 = nothing to record.
    var orientation = 1

    init() {}
    init(sourceURL: URL?, properties: [CFString: Any]? = nil, orientation: Int = 1) {
        self.sourceURL = sourceURL
        self.sourceProperties = properties ?? sourceURL.flatMap { ImageMetadata.read($0) }
        self.orientation = orientation
    }
}

/// Encoding service used by this module AND by other modules (fit-to-size searches quality with it, background removal writes PNG / WebP / HEIC through it,
/// the Studio preview measures sizes with it). Same code path as `ImageOperation`, so a Studio estimate equals the real output.
enum ImageEncoder {
    /// Encodes `image` as `format` ("jpg", "png", "heic", "avif", "tiff", "gif", "bmp", "jp2", "ico", "icns", "pdf", "webp") with the image options of `ImageKeys`
    /// (img.quality, img.lossless, img.jpeg.progressive, img.jpeg.subsampling, img.alpha.bg, img.dpi, img.md.mode ...). `source` is the original file whose metadata
    /// travels along (per `img.md.mode`). `webp` needs `cwebp` (throws `ConversionError.toolMissing(.cwebp)` without it). Returns the file bytes; nothing is written next to the user's files.
    static func encode(_ image: CGImage, format: String, options: OptionValues, source: URL? = nil) async throws -> Data {
        let p = ImageEncodeParams(format: format, options: options)
        let needsTool = p.format == "webp" || p.format == "icns" || (p.format == "jpeg" && p.fullColour444 && Capabilities.shared.has("tool.ffmpeg"))
        if !needsTool { return try encodeSync(image, format: format, options: options, source: source) }
        let dir = AppPaths.makeTempDirectory(purpose: "enc")
        defer { AppPaths.removeTemp(dir) }
        let url = dir.appendingPathComponent("out." + ImageFormat.fileExtension(p.format))
        try await write(image, format: format, options: options, context: ImageEncodeContext(sourceURL: source), to: url)
        return try Data(contentsOf: url)
    }

    /// Synchronous variant for the formats ImageIO (and PDFKit) write by themselves; the quality searches of fit-to-size call it in a loop.
    /// Throws for WebP, ICNS and 4:4:4 JPEG, which need an external tool.
    static func encodeSync(_ image: CGImage, format: String, options: OptionValues, source: URL? = nil, context: ImageEncodeContext? = nil) throws -> Data {
        let p = ImageEncodeParams(format: format, options: options)
        let ctx = context ?? ImageEncodeContext(sourceURL: source)
        switch p.format {
        case "pdf":
            let data = NSMutableData()
            try ImageContainers.writePDF(image, p, ctx, sink: .data(data))
            return data as Data
        case "ico":
            let data = NSMutableData()
            try ImageContainers.writeICO(image, p, sink: .data(data))
            return data as Data
        case "webp": throw ConversionError.toolMissing(.cwebp)
        case "icns": throw ConversionError.unsupported(L10n("ICNS files are written to disk only.", "Файлы ICNS записываются только на диск."))
        default:
            guard ImageFormat.imageIOType(p.format) != nil else {
                throw ConversionError.unsupported(L10n("This Mac cannot write \(p.format.uppercased()) files.", "Этот Mac не может записывать файлы \(p.format.uppercased())."))
            }
            let data = NSMutableData()
            try writeNative(image, p, ctx, sink: .data(data))
            return data as Data
        }
    }

    /// Writes the finished picture to `url` (a hidden `.part` file of the job). The route depends on the format: ImageIO, PDF, ICO / ICNS containers,
    /// `cwebp` for WebP, ffmpeg for 4:4:4 JPEG.
    static func write(_ image: CGImage, format: String, options: OptionValues, context: ImageEncodeContext, to url: URL) async throws {
        let p = ImageEncodeParams(format: format, options: options)
        try Task.checkCancellation()
        switch p.format {
        case "webp": try await ImageExternal.writeWebP(image, p, context, to: url)
        case "icns": try await ImageContainers.writeICNS(image, p, to: url)
        case "pdf": try ImageContainers.writePDF(image, p, context, sink: .file(url))
        case "ico": try ImageContainers.writeICO(image, p, sink: .file(url))
        case "jpeg" where p.fullColour444 && Capabilities.shared.has("tool.ffmpeg"):
            try await ImageExternal.writeJPEG444(image, p, context, to: url)
        default:
            guard ImageFormat.imageIOType(p.format) != nil else {
                throw ConversionError.unsupported(L10n("This Mac cannot write \(p.format.uppercased()) files.", "Этот Mac не может записывать файлы \(p.format.uppercased())."))
            }
            try writeNative(image, p, context, sink: .file(url))
        }
    }

    // MARK: ImageIO route

    enum Sink {
        case file(URL)
        case data(NSMutableData)

        func destination(type: String, count: Int = 1) -> CGImageDestination? {
            switch self {
            case .file(let url): return CGImageDestinationCreateWithURL(url as CFURL, type as CFString, count, nil)
            case .data(let d): return CGImageDestinationCreateWithData(d, type as CFString, count, nil)
            }
        }
    }

    /// Makes the picture ready for `p.format`: transparency is flattened onto the background for formats without alpha, and colours are converted to sRGB for formats
    /// that cannot carry a colour profile (BMP, GIF, TGA, JPEG 2000 and PSD would otherwise show a Display P3 or Adobe RGB photo with shifted colours).
    static func prepared(_ image: CGImage, _ p: ImageEncodeParams) throws -> CGImage {
        let flatten = !ImageFormat.supportsAlpha(p.format) && ImageBitmap.hasAlpha(image)
        let convert = !ImageFormat.carriesProfile(p.format) && ImageBitmap.needsSRGB(image)
        guard flatten || convert else { return image }
        guard let out = ImageGeometry.render(image, .identity, colorSpace: convert ? ImageBitmap.sRGB : nil, flatten: flatten ? p.background : nil) else { throw ImageLoader.outOfMemory() }
        return out
    }

    static func writeNative(_ source: CGImage, _ p: ImageEncodeParams, _ ctx: ImageEncodeContext, sink: Sink) throws {
        var image = try prepared(source, p)
        if p.format == "png", p.pngPalette, let indexed = try ImageQuantizer.quantize(image) { image = indexed }
        let unsupported = ConversionError.unsupported(L10n("This Mac cannot write \(p.format.uppercased()) files.", "Этот Mac не может записывать файлы \(p.format.uppercased())."))
        guard let type = ImageFormat.imageIOType(p.format) else { throw unsupported }
        let failed = ConversionError.message(L10n("The \(p.format.uppercased()) file could not be written. The picture may be too large for this format.",
                                                  "Не удалось записать файл \(p.format.uppercased()). Возможно, картинка слишком велика для этого формата."))
        if p.format == "png" {
            // PNG goes through memory: ImageIO writes it unfiltered, and the optimiser re-filters and re-deflates it losslessly (about 20 percent smaller).
            let mem = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(mem, type as CFString, 1, nil) else { throw unsupported }
            CGImageDestinationAddImage(dest, image, frameProperties(p, image: image, ctx) as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw failed }
            var data = mem as Data
            if !p.pngInterlace, p.optimizePNG, let better = try PNGOptimizer.optimized(data) { data = better }
            switch sink {
            case .data(let d): d.append(data)
            case .file(let url): try data.write(to: url)
            }
            return
        }
        guard let dest = sink.destination(type: type) else { throw unsupported }
        CGImageDestinationAddImage(dest, image, frameProperties(p, image: image, ctx) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw failed }
    }

    /// The frame properties handed to ImageIO: carried metadata, quality, format specifics, resolution and orientation.
    static func frameProperties(_ p: ImageEncodeParams, image: CGImage, _ ctx: ImageEncodeContext) -> [CFString: Any] {
        var d = ImageMetadata.carried(from: ctx.sourceProperties, mode: p.metadataMode, pixelWidth: image.width, pixelHeight: image.height)
        if ImageFormat.isLossy(p.format) && p.format != "webp" {
            let q = Double(min(max(p.quality, 1), 100)) / 100
            d[kCGImageDestinationLossyCompressionQuality] = p.format == "avif" ? min(q, 0.99) : q   // AVIF refuses 1.0 at finalize
        }
        switch p.format {
        case "jpeg": if p.progressive { d[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] as [CFString: Any] }
        case "png": if p.pngInterlace { d[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGInterlaceType: 1] as [CFString: Any] }
        case "tiff":
            var t = (d[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            t[kCGImagePropertyTIFFCompression] = ["none": 1, "lzw": 5, "packbits": 32773, "deflate": 8][p.tiffCompression] ?? 5
            d[kCGImagePropertyTIFFDictionary] = t
        default: break
        }
        if let dpi = p.dpi ?? ImageMetadata.dpi(ctx.sourceProperties)?.x {
            d[kCGImagePropertyDPIWidth] = dpi
            d[kCGImagePropertyDPIHeight] = p.dpi ?? ImageMetadata.dpi(ctx.sourceProperties)?.y ?? dpi
        }
        if ctx.orientation != 1, ImageFormat.carriesOrientation(p.format) { d[kCGImagePropertyOrientation] = ctx.orientation }
        return d
    }
}
