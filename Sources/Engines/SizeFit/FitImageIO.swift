import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ImageIO helpers of the image fit: decoding straight to a target size (no full-size copy per probe) and encoding to JPEG / HEIC / PNG with the
/// source's capture metadata kept (or stripped). WebP goes through `ImageEncoder` (it needs `cwebp`).
enum FitImageIO {
    /// Output formats the fit writes.
    enum Format: String, Sendable {
        case jpg, heic, png, webp
        var utType: String {
            switch self { case .jpg: return "public.jpeg"; case .heic: return "public.heic"; case .png: return "public.png"; case .webp: return "org.webmproject.webp" }
        }
        /// Lossless formats have no quality dial: the fit can only shrink the pixels.
        var isLossy: Bool { self != .png }
        /// Formats that keep transparency.
        var hasAlpha: Bool { self == .png || self == .webp }
    }

    struct SourceFacts: Sendable {
        var width: Int
        var height: Int
        var hasAlpha: Bool
        var orientation: Int
        /// Pixel size after the EXIF orientation is applied.
        var displayWidth: Int { orientation >= 5 ? height : width }
        var displayHeight: Int { orientation >= 5 ? width : height }
    }

    static func facts(of source: CGImageSource) -> SourceFacts? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return SourceFacts(width: w, height: h, hasAlpha: (p[kCGImagePropertyHasAlpha] as? Bool) ?? false, orientation: (p[kCGImagePropertyOrientation] as? Int) ?? 1)
    }

    /// The first frame decoded with the orientation applied and its longest side limited to `maxPixel`.
    static func decode(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, o as CFDictionary)
    }

    static func canWrite(_ uti: String) -> Bool {
        ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(uti)
    }

    /// The capture metadata worth keeping (EXIF without sizes, TIFF without orientation, GPS, IPTC, resolution). Empty when `strip` is on.
    static func metadata(of source: CGImageSource, strip: Bool, width: Int, height: Int) -> [CFString: Any] {
        guard !strip, let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] { if let d = p[key] { out[key] = d } }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { if let d = p[key] { out[key] = d } }
        return out
    }

    /// JPEG / HEIC / PNG bytes of `image`. JPEG is progressive (smaller at the same quality). Transparency is flattened on white for JPEG and HEIC.
    static func encode(_ image: CGImage, format: Format, quality: Int, metadata: [CFString: Any], flatten: Bool) throws -> Data {
        guard format != .webp else { throw ConversionError.unsupported(L10n("WebP is written by the image module.", "WebP записывает модуль изображений.")) }
        let drawn: CGImage
        if flatten, image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast {
            drawn = ImageFit.draw(image, width: image.width, height: image.height, flattenOnWhite: true) ?? image
        } else {
            drawn = image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType as CFString, 1, nil) else {
            throw ConversionError.unsupported(L10n("This Mac cannot write \(format.rawValue.uppercased()) pictures.", "Этот Mac не умеет записывать картинки \(format.rawValue.uppercased())."))
        }
        var props = metadata
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = Double(min(max(quality, 1), 100)) / 100 }
        if format == .jpg { props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] as [CFString: Any] }
        CGImageDestinationAddImage(dest, drawn, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.noOutput }
        return data as Data
    }
}
