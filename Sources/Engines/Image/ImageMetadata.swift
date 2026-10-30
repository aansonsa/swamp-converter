import Foundation
import ImageIO

/// Reads the metadata of a source picture and decides what travels into the result. Three modes (`img.md.mode`):
///  keep   camera, date, description, copyright, location (EXIF / TIFF / IPTC / GPS)
///  noGPS  the same without the GPS block
///  strip  nothing (the colour profile, resolution and, when asked, the orientation are not "metadata" and are handled elsewhere)
enum ImageMetadata {
    /// The ImageIO properties of frame `index` (nil when the file cannot be opened). Cheap: no pixels are decoded.
    static func read(_ url: URL, index: Int = 0) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let i = min(max(index, 0), max(CGImageSourceGetCount(src) - 1, 0))
        return CGImageSourceCopyPropertiesAtIndex(src, i, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
    }

    static func hasGPS(_ props: [CFString: Any]?) -> Bool {
        guard let gps = props?[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return false }
        return !gps.isEmpty
    }

    static func orientation(_ props: [CFString: Any]?) -> Int {
        let o = (props?[kCGImagePropertyOrientation] as? Int) ?? ((props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? Int) ?? 1
        return (1...8).contains(o) ? o : 1
    }

    /// Print resolution recorded in the file (dots per inch), when it is a sensible number.
    static func dpi(_ props: [CFString: Any]?) -> (x: Double, y: Double)? {
        guard let x = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, let y = (props?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
              x >= 1, y >= 1, x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    private static let tiffKept: [CFString] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime,
                                               kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription,
                                               kCGImagePropertyTIFFHostComputer]

    /// The frame-property entries that carry `mode` over from `source` into a file of `pixelWidth x pixelHeight`.
    /// Only well-understood blocks are copied (pixel dimensions, compression and thumbnails of the source would be wrong for the result).
    static func carried(from source: [CFString: Any]?, mode: String, pixelWidth: Int, pixelHeight: Int) -> [CFString: Any] {
        guard let source, mode == "keep" || mode == "noGPS" else { return [:] }
        var out: [CFString: Any] = [:]
        if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = pixelWidth
            exif[kCGImagePropertyExifPixelYDimension] = pixelHeight
            out[kCGImagePropertyExifDictionary] = exif
        }
        if let aux = source[kCGImagePropertyExifAuxDictionary] as? [CFString: Any], !aux.isEmpty { out[kCGImagePropertyExifAuxDictionary] = aux }
        if let iptc = source[kCGImagePropertyIPTCDictionary] as? [CFString: Any], !iptc.isEmpty { out[kCGImagePropertyIPTCDictionary] = iptc }
        if let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var kept: [CFString: Any] = [:]
            for k in tiffKept { if let v = tiff[k] { kept[k] = v } }
            if !kept.isEmpty { out[kCGImagePropertyTIFFDictionary] = kept }
        }
        if mode == "keep", let gps = source[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { out[kCGImagePropertyGPSDictionary] = gps }
        return out
    }

    /// What a "remove" run would take away, for chips and the privacy summary: location, device, capture date.
    struct Inventory: Sendable, Equatable {
        var hasGPS = false
        var device: String? = nil
        var captureDate: String? = nil
        var isEmpty: Bool { !hasGPS && device == nil && captureDate == nil }
    }

    static func inventory(_ props: [CFString: Any]?) -> Inventory {
        var inv = Inventory()
        inv.hasGPS = hasGPS(props)
        if let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = model.hasPrefix(make) ? model : "\(make) \(model)"
            inv.device = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces)
        }
        if let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            inv.captureDate = (exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
        }
        return inv
    }
}
