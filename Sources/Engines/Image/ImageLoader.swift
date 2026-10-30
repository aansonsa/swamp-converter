import Foundation
import AppKit
import ImageIO
import CoreImage

/// Decoding service used by this module AND by other modules (OCR renders images through it; Studio previews; background removal).
/// Reads every kind of the catalogue: ImageIO formats (JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, WebP, JPEG 2000, PSD, TGA, ICNS, ICO, EXR, JPEG XL ...),
/// SVG (vector, drawn at 2x its nominal size on a transparent background) and camera RAW (developed at full size with the camera white balance
/// into sRGB; never the embedded preview).
enum ImageLoader {
    struct Options: Sendable {
        /// Longest side limit in pixels (nil = full size). Decoders scale while decoding, so a huge file is never fully held in memory.
        var maxPixel: Int? = nil
        /// Bake EXIF orientation into the pixels (spec/catalog.md 1.4: always on for conversions).
        var applyOrientation = true
        /// SVG is rasterised at this scale of its nominal size (spec: density 192 = 2x).
        var svgScale: Double = 2
        /// Which frame of a multi-frame file (GIF, TIFF, WebP). Icons (ICO / ICNS) always give their largest picture for frame 0.
        var frameIndex = 0
    }

    /// A decoded frame together with what the file said about it. `orientation` is the EXIF value still to be applied (1 when baked in or upright).
    struct Loaded: @unchecked Sendable {
        var image: CGImage
        var orientation: Int
        var frameCount: Int
        var properties: [CFString: Any]?
    }

    /// Loads any readable image kind (including RAW, SVG, HEIC, AVIF, WebP). The first frame unless `frameIndex` says otherwise.
    static func load(_ url: URL, _ options: Options = Options()) throws -> CGImage {
        let loaded = try loadUnoriented(url, options)
        guard options.applyOrientation, loaded.orientation != 1 else { return loaded.image }
        guard let upright = ImageGeometry.render(loaded.image, Dihedral(orientation: loaded.orientation)) else { throw outOfMemory() }
        return upright
    }

    /// Like `load`, but EXIF orientation is reported and NOT applied (unless it was baked in while decoding at a reduced size), so the caller can fuse
    /// it with its own rotation into one drawing pass.
    static func loadUnoriented(_ url: URL, _ options: Options = Options()) throws -> Loaded {
        try Task.checkCancellation()
        let key = Formats.key(of: url)
        if key == "svg" { return try loadSVG(url, options) }
        if Formats.rawInputs.contains(key), let raw = try? loadRAW(url, options) { return raw }
        return try loadImageIO(url, options)
    }

    static func outOfMemory() -> ConversionError {
        .message(L10n("Not enough memory for a picture this big. Try a smaller size or fewer files at once.",
                      "Не хватает памяти для такой большой картинки. Уменьшите размер или обработайте меньше файлов сразу."))
    }

    // MARK: ImageIO

    private static func loadImageIO(_ url: URL, _ o: Options) throws -> Loaded {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(src) > 0 else {
            throw ConversionError.fileUnreadable(url)
        }
        let count = CGImageSourceGetCount(src)
        var index = min(max(o.frameIndex, 0), count - 1)
        if o.frameIndex == 0, count > 1, let type = CGImageSourceGetType(src) as String?, type == "com.microsoft.ico" || type == "com.apple.icns" {
            index = largestFrame(src, count: count)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let depth = (props?[kCGImagePropertyDepth] as? Int) ?? 8
        let orientation = ImageMetadata.orientation(props)

        if let limit = o.maxPixel, limit > 0, max(w, h) > limit, depth <= 8 {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: o.applyOrientation,
                                         kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceShouldCacheImmediately: true]
            if let th = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) {
                return Loaded(image: th, orientation: o.applyOrientation ? 1 : orientation, frameCount: count, properties: props)
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(src, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ConversionError.fileUnreadable(url)
        }
        return Loaded(image: image, orientation: orientation, frameCount: count, properties: props)
    }

    private static func largestFrame(_ src: CGImageSource, count: Int) -> Int {
        var best = 0, bestSide = -1
        for i in 0..<count {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let side = max((p?[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
            if side > bestSide { best = i; bestSide = side }
        }
        return best
    }

    // MARK: SVG

    private static func loadSVG(_ url: URL, _ o: Options) throws -> Loaded {
        guard let ns = NSImage(contentsOf: url) else { throw ConversionError.fileUnreadable(url) }
        var size = ns.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 512, height: 512) }
        var scale = max(0.01, o.svgScale)
        let cap = Double(min(o.maxPixel ?? 8192, 16384))
        let long = Double(max(size.width, size.height)) * scale
        if long > cap { scale *= cap / long }
        let w = max(1, Int((Double(size.width) * scale).rounded())), h = max(1, Int((Double(size.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImageBitmap.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw outOfMemory() }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw outOfMemory() }
        return Loaded(image: image, orientation: 1, frameCount: 1, properties: nil)
    }

    // MARK: Camera RAW

    private static func loadRAW(_ url: URL, _ o: Options) throws -> Loaded {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ConversionError.fileUnreadable(url) }
        let native = filter.nativeSize
        let longest = Double(max(native.width, native.height))
        // Orientation is applied by the pipeline (like every other format), so the filter delivers the sensor orientation.
        filter.orientation = .up
        filter.isDraftModeEnabled = false
        if let limit = o.maxPixel, limit > 0, longest > Double(limit) { filter.scaleFactor = Float(max(0.05, Double(limit) / longest)) }
        guard let out = filter.outputImage, !out.extent.isInfinite, !out.extent.isEmpty else { throw ConversionError.fileUnreadable(url) }
        let ctx = CIContext(options: [.cacheIntermediates: false])
        guard let image = ctx.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: ImageBitmap.sRGB) else { throw outOfMemory() }
        let props = ImageMetadata.read(url)
        return Loaded(image: image, orientation: ImageMetadata.orientation(props), frameCount: 1, properties: props)
    }
}
