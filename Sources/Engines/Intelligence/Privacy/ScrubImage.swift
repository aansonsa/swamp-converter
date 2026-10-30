import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// Image metadata: what is in a picture and how to take it out.
//
// Two routes, tried in this order:
//  1. LOSSLESS COPY. `CGImageDestinationCopyImageSource` moves the compressed pixels to a new file untouched while the metadata object we hand over replaces the
//     original one. Tags of the selected groups are removed from a copy of the original metadata, everything else (orientation, colour profile, the groups the person
//     chose to keep) stays. Used when the picture does not have to change (upright already or "bake" is off, profile kept, format writable).
//  2. DECODE + ENCODE. Pixels are decoded, rotated upright (the orientation is baked in), optionally converted to sRGB, and written again with only the properties
//     of the groups that stay. JPEG / HEIC are written at quality 0.95.
// After either route the result is inspected again: whatever selected group is still present is reported (and route 2 is tried when route 1 left something).

enum ImageScrub {
    // MARK: Format handling

    private static var writableTypes: Set<String> { Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []) }

    /// Same extension when ImageIO can write the source's type; otherwise JPEG for RAW photos and PNG for everything else (WebP, SVG, PSD ...).
    static func outputExtension(for item: FileItem) -> String {
        if item.kind == .raw { return "jpg" }
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil), let type = CGImageSourceGetType(src) as String?, writableTypes.contains(type) else { return "png" }
        return item.key.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : item.key
    }

    // MARK: Inspect

    static func inspect(_ url: URL) -> ScrubReport {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return ScrubReport() }
        var found = Set<ScrubReport.Item>()
        func dict(_ key: CFString) -> [String: Any]? { props[key as String] as? [String: Any] }

        if let gps = dict(kCGImagePropertyGPSDictionary), !gps.isEmpty { found.insert(.gps) }
        for (name, entries) in [("exif", dict(kCGImagePropertyExifDictionary)), ("tiff", dict(kCGImagePropertyTIFFDictionary)),
                                ("iptc", dict(kCGImagePropertyIPTCDictionary)), ("png", dict(kCGImagePropertyPNGDictionary)),
                                ("gif", dict(kCGImagePropertyGIFDictionary))] {
            for key in entries?.keys ?? [:].keys {
                if let item = item(forProperty: key, in: name) { found.insert(item) }
            }
        }
        if props.keys.contains(where: { $0.hasPrefix("{Maker") }) { found.insert(.makerNote) }
        if let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let tag = CGImageMetadataCopyTagWithPath(md, nil, "iio:hasXMP" as CFString),
           (CGImageMetadataTagCopyValue(tag) as? Bool) == true { found.insert(.xmp) }
        if CGImageSourceGetType(src) as String? == UTType.jpeg.identifier {
            let facts = jpegFacts(of: url)
            if facts.thumbnail { found.insert(.thumbnail) }
            if facts.comment { found.insert(.comment) }
        }
        return ScrubReport(removed: ScrubReport.Item.allCases.filter(found.contains))
    }

    /// A property of the Exif / TIFF / IPTC / PNG / GIF dictionaries -> the item it reveals (nil = technical, e.g. exposure time or pixel dimensions).
    static func item(forProperty key: String, in dictionary: String) -> ScrubReport.Item? {
        switch (dictionary, key) {
        case ("tiff", "Make"): return .cameraMake
        case ("tiff", "Model"): return .cameraModel
        case ("tiff", "Software"), ("tiff", "HostComputer"), ("png", "Software"): return .software
        case ("tiff", "Artist"), ("tiff", "Copyright"), ("png", "Author"), ("png", "Copyright"), ("exif", "CameraOwnerName"): return .author
        case ("tiff", "ImageDescription"), ("exif", "UserComment"), ("png", "Description"), ("png", "Comment"), ("png", "Disclaimer"), ("png", "Warning"): return .comment
        case ("tiff", "DocumentName"), ("png", "Title"): return .title
        case ("tiff", "DateTime"), ("png", "CreationTime"): return .creationTime
        case ("exif", let k) where k == "DateTimeOriginal" || k == "DateTimeDigitized" || k.hasPrefix("SubsecTime") || k.hasPrefix("OffsetTime"): return .dateTaken
        case ("exif", let k) where k.hasPrefix("Lens"): return .lensModel
        case ("exif", "BodySerialNumber"), ("exif", "ImageUniqueID"): return .serialNumber
        case ("iptc", let k):
            switch k {
            case "Byline", "BylineTitle", "Credit", "Source", "CopyrightNotice", "Contact", "WriterEditor": return .author
            case "ObjectName", "Headline": return .title
            case "Caption/Abstract", "Keywords", "SpecialInstructions": return .comment
            case "City", "Sub-location", "Province/State", "Country/PrimaryLocationName", "Country/PrimaryLocationCode": return .gps
            case "DateCreated", "TimeCreated", "DigitalCreationDate", "DigitalCreationTime": return .dateTaken
            default: return .iptc
            }
        default: return nil
        }
    }

    /// A tag of the CGImageMetadata view (`prefix:name`) -> the item it reveals. ImageIO shows EXIF / TIFF / IPTC values under XMP-style names
    /// (Artist as `dc:creator`, Software as `xmp:CreatorTool`, DateTimeOriginal as `photoshop:DateCreated`), so those are listed too.
    static func item(forTag path: String) -> ScrubReport.Item? {
        let name = path.split(separator: ":", maxSplits: 1).last.map(String.init) ?? path
        if name.hasPrefix("GPS") { return .gps }
        switch path {
        case "tiff:Make": return .cameraMake
        case "tiff:Model": return .cameraModel
        case "tiff:Software", "tiff:HostComputer", "xmp:CreatorTool", "xmpMM:History": return .software
        case "tiff:Artist", "tiff:Copyright", "dc:creator", "dc:rights", "exifEX:CameraOwnerName", "aux:OwnerName", "photoshop:Credit", "photoshop:Source",
             "photoshop:AuthorsPosition", "photoshop:CaptionWriter", "xmpRights:Owner", "xmpRights:UsageTerms", "Iptc4xmpCore:CreatorContactInfo": return .author
        case "tiff:ImageDescription", "exif:UserComment", "dc:description", "dc:subject", "photoshop:Instructions": return .comment
        case "dc:title", "photoshop:Headline", "tiff:DocumentName": return .title
        case "exif:DateTimeOriginal", "exif:DateTimeDigitized", "photoshop:DateCreated", "xmp:CreateDate": return .dateTaken
        case "tiff:DateTime", "xmp:ModifyDate", "xmp:MetadataDate": return .creationTime
        case "exifEX:BodySerialNumber", "exifEX:LensSerialNumber", "aux:SerialNumber", "aux:LensSerialNumber", "exif:ImageUniqueID", "exifEX:ImageUniqueID": return .serialNumber
        case "exifEX:LensModel", "exifEX:LensMake", "exifEX:LensSpecification", "aux:Lens", "aux:LensInfo", "aux:LensID": return .lensModel
        case "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode", "Iptc4xmpExt:LocationShown", "Iptc4xmpExt:LocationCreated": return .gps
        default:
            if name.hasPrefix("SubSecTime") || name.hasPrefix("OffsetTime") { return .dateTaken }
            return nil
        }
    }

    // MARK: JPEG segments (thumbnail, comment)

    /// Looks at the JPEG marker segments before the image data: an Exif block with a second IFD that holds a thumbnail, and COM (comment) segments.
    static func jpegFacts(of url: URL) -> (thumbnail: Bool, comment: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (false, false) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_576), data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return (false, false) }
        var thumbnail = false, comment = false
        var i = 2
        while i + 4 <= data.count {
            guard data[i] == 0xFF else { break }
            let marker = data[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }                       // start of scan / end: metadata segments are behind us
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            let payload = i + 4, end = min(i + 2 + length, data.count)
            if marker == 0xFE { comment = true }
            if marker == 0xE1, end - payload > 14, data[payload..<payload + 6] == Data([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                thumbnail = thumbnail || exifHasThumbnail(data[(payload + 6)..<end])
            }
            i = i + 2 + length
        }
        return (thumbnail, comment)
    }

    /// TIFF structure of an Exif block: IFD0 -> next-IFD offset -> IFD1 with tag 0x0201 (JPEGInterchangeFormat) is the embedded thumbnail.
    private static func exifHasThumbnail(_ tiff: Data) -> Bool {
        let t = Data(tiff)   // rebase indices to 0
        guard t.count > 8 else { return false }
        let little = t[0] == 0x49
        func u16(_ o: Int) -> Int? { o + 2 <= t.count ? (little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])) : nil }
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= t.count else { return nil }
            return little ? Int(t[o]) | Int(t[o + 1]) << 8 | Int(t[o + 2]) << 16 | Int(t[o + 3]) << 24 : Int(t[o]) << 24 | Int(t[o + 1]) << 16 | Int(t[o + 2]) << 8 | Int(t[o + 3])
        }
        guard let ifd0 = u32(4), let n0 = u16(ifd0), let next = u32(ifd0 + 2 + n0 * 12), next > 0, let n1 = u16(next) else { return false }
        for k in 0..<n1 where u16(next + 2 + k * 12) == 0x0201 { return true }
        return false
    }

    // MARK: Scrub

    /// Writes the scrubbed copy to `output` and reports what is gone. `output` must carry the extension from `outputExtension(for:)`.
    static func scrub(input: URL, output: URL, selection: ScrubSelection, keepProfile: Bool, bakeOrientation: Bool, quality: Double = 0.95) throws -> ScrubReport {
        let before = inspect(input)
        let wanted = before.removed.filter(selection.selects)
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(src) > 0, let type = CGImageSourceGetType(src) as String? else {
            throw ConversionError.fileUnreadable(input)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        let profile = (props[kCGImagePropertyProfileName as String] as? String) ?? ""
        let needsPixels = (bakeOrientation && orientation > 1) || (!keepProfile && !profile.isEmpty && !profile.hasPrefix("sRGB"))
        let writable = writableTypes.contains(type) && output.pathExtension.lowercased() == outputExtension(forType: type, source: input)
        var route = "lossless"

        var written = false
        if writable && !needsPixels {
            written = losslessCopy(src, to: output, type: type, selection: selection)
            if written, !inspect(output).removed.filter(selection.selects).isEmpty { written = false }
        }
        if !written {
            route = "re-encoded"
            try? FileManager.default.removeItem(at: output)
            try reencode(src, to: output, input: input, type: type, props: props, selection: selection, keepProfile: keepProfile, bake: bakeOrientation, quality: quality)
        }
        let after = inspect(output)
        let residual = after.removed.filter(selection.selects)
        var report = ScrubReport()
        report.removed = wanted.filter { !residual.contains($0) }
        report.residual = residual
        report.kept = [route]
        return report
    }

    private static func outputExtension(forType type: String, source: URL) -> String {
        let key = Formats.key(of: source)
        return key.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : key
    }

    // MARK: Route 1: lossless

    private static func losslessCopy(_ src: CGImageSource, to output: URL, type: String, selection: ScrubSelection) -> Bool {
        guard let original = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let md = CGImageMetadataCreateMutableCopy(original) else { return false }
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(md, nil, nil) { path, _ in paths.append(path as String); return true }
        for path in paths {
            if path.hasSuffix(":Orientation") { continue }
            let revealed = item(forTag: path)
            let drop = revealed.map(selection.selects) ?? selection.everything
            if drop { CGImageMetadataRemoveTagWithPath(md, nil, path as CFString) }
        }
        var options: [CFString: Any] = [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: false]
        if selection.gps { options[kCGImageMetadataShouldExcludeGPS] = true }
        if selection.everything { options[kCGImageMetadataShouldExcludeXMP] = true }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else { return false }
        var error: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error)
        if !ok { try? FileManager.default.removeItem(at: output) }
        return ok
    }

    // MARK: Route 2: decode + encode

    private static func reencode(_ src: CGImageSource, to output: URL, input: URL, type: String, props: [String: Any], selection: ScrubSelection,
                                 keepProfile: Bool, bake: Bool, quality: Double) throws {
        guard var image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else { throw ConversionError.fileUnreadable(input) }
        let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        if orientation > 1, bake {
            guard let up = upright(src, like: image) else { throw ConversionError.fileUnreadable(input) }
            image = up
        }
        if !keepProfile, let converted = inSRGB(image) { image = converted }

        let ext = output.pathExtension.lowercased()
        let target: UTType = {
            let fromExt = UTType(filenameExtension: ext)
            if let t = fromExt, writableTypes.contains(t.identifier) { return t }
            return writableTypes.contains(type) ? (UTType(type) ?? .png) : .png
        }()
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, target.identifier as CFString, 1, nil) else { throw ConversionError.outputNotWritable(output) }
        var out: [CFString: Any] = [:]
        if orientation > 1, !bake { out[kCGImagePropertyOrientation] = orientation }
        if target == .jpeg || target == .heic { out[kCGImageDestinationLossyCompressionQuality] = quality }
        if let dpiW = props[kCGImagePropertyDPIWidth as String], let dpiH = props[kCGImagePropertyDPIHeight as String] { out[kCGImagePropertyDPIWidth] = dpiW; out[kCGImagePropertyDPIHeight] = dpiH }
        if !selection.everything {
            for (key, name) in [(kCGImagePropertyExifDictionary, "exif"), (kCGImagePropertyTIFFDictionary, "tiff"), (kCGImagePropertyGPSDictionary, "gps"),
                                (kCGImagePropertyIPTCDictionary, "iptc"), (kCGImagePropertyPNGDictionary, "png")] {
                guard let source = props[key as String] as? [String: Any] else { continue }
                if name == "gps" { if !selection.gps { out[key] = source }; continue }
                var keep: [String: Any] = [:]
                for (k, v) in source {
                    if name == "tiff" && k == "Orientation" { continue }
                    if name == "exif" && (k == "PixelXDimension" || k == "PixelYDimension") { continue }
                    if name == "png" && ["Chromaticities", "Gamma", "InterlaceType", "sRGBIntent"].contains(k) { continue }
                    if let item = item(forProperty: k, in: name), selection.selects(item) { continue }
                    keep[k] = v
                }
                if !keep.isEmpty { out[key] = keep }
            }
        }
        CGImageDestinationAddImage(dest, image, out as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.outputNotWritable(output) }
    }

    /// The picture with its EXIF orientation applied (ImageIO's own transform, so all eight cases are right by construction). The size limit equals the
    /// longest side, so nothing is resampled.
    static func upright(_ src: CGImageSource, like image: CGImage) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height), kCGImageSourceShouldCacheImmediately: true]
        guard let out = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              out.width * out.height == image.width * image.height else { return nil }
        return out
    }

    private static func inSRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), image.colorSpace?.name != space.name,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
