import Foundation
import CoreGraphics
import ImageIO

/// Format knowledge of the image module: canonical names, extensions, ImageIO type ids, what each format can carry.
/// "Canonical" format names are the values of the `img.format` picker ("jpeg", "png", "heic", "avif", "webp", "tiff", "gif", "bmp", "jp2", "tga", "ico", "icns", "pdf", "psd").
enum ImageFormat {
    /// "jpg" / "JPEG" / "jpe" -> "jpeg", "tif" -> "tiff", "heif" -> "heic". Unknown names come back lower-cased.
    static func canonical(_ name: String) -> String {
        switch name.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": return "jpeg"
        case "tif", "tiff": return "tiff"
        case "heif", "heic": return "heic"
        case "jpeg2000", "j2k": return "jp2"
        case let other: return other
        }
    }

    /// File extension (without dot) of a canonical format.
    static func fileExtension(_ format: String) -> String { canonical(format) == "jpeg" ? "jpg" : canonical(format) }

    /// What "same as source" means for a file key: svg -> png, RAW -> jpeg, JPEG XL / OpenEXR (not writable on this Mac) -> png, otherwise the input format.
    static func sameFormat(forKey key: String) -> String {
        if Formats.rawInputs.contains(key) { return "jpeg" }
        switch key {
        case "svg", "jxl", "exr": return "png"
        case "": return "png"
        default: return canonical(key)
        }
    }

    /// ImageIO destination type identifier for the formats ImageIO writes by itself (nil: webp, icns, pdf, which have their own routes).
    static func imageIOType(_ format: String) -> String? {
        switch canonical(format) {
        case "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "heic": return "public.heic"
        case "avif": return "public.avif"
        case "tiff": return "public.tiff"
        case "gif": return "com.compuserve.gif"
        case "bmp": return "com.microsoft.bmp"
        case "jp2": return "public.jpeg-2000"
        case "tga": return "com.truevision.tga-image"
        case "ico": return "com.microsoft.ico"
        case "psd": return "com.adobe.photoshop-image"
        default: return nil
        }
    }

    static let known: Set<String> = ["jpeg", "png", "heic", "avif", "webp", "tiff", "gif", "bmp", "jp2", "tga", "ico", "icns", "pdf", "psd"]

    /// Formats whose pixels are written with a quality setting.
    static func isLossy(_ format: String) -> Bool { ["jpeg", "heic", "avif", "webp", "jp2"].contains(canonical(format)) }

    /// Formats that keep an alpha channel. JPEG, BMP and PDF pages are flattened onto the background colour.
    static func supportsAlpha(_ format: String) -> Bool { !["jpeg", "bmp", "pdf"].contains(canonical(format)) }

    /// Formats whose files embed the colour profile of the picture. The others get sRGB pixels.
    static func carriesProfile(_ format: String) -> Bool { ["jpeg", "png", "tiff", "heic", "avif", "webp", "pdf", "icns", "ico"].contains(canonical(format)) }

    /// Formats that can store the EXIF orientation tag next to unrotated pixels (everything else gets the rotation baked in).
    static func carriesOrientation(_ format: String) -> Bool { ["jpeg", "tiff", "heic", "png"].contains(canonical(format)) }

    /// True when ImageIO on this Mac can write the format itself.
    static func writesNatively(_ format: String) -> Bool {
        guard let t = imageIOType(format) else { return false }
        return ImageIOTypes.destinationTypes.contains(t)
    }

    /// Parses "#RRGGBB" (also without the hash). Falls back to `fallback`.
    static func color(hex: String, fallback: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return fallback }
        return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

private enum ImageIOTypes {
    /// Writable ImageIO type ids, read once.
    static let destinationTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
}
