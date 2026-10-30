import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Tags and cover art: reading the embedded picture, scaling it, and writing tags + artwork into MP4-family files with the system exporter.
// (The ffmpeg route writes tags and pictures with its own muxers; see AudFFmpegArgs.)

enum AudCover {
    static func isJPEG(_ d: Data) -> Bool { d.count > 3 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8 }

    /// Pixel size of a picture, nil when the bytes are not an image.
    static func pixelSize(_ d: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// JPEG bytes of the picture, scaled so its longest side is at most `maxPixel` (0 = never scale). Pictures are never enlarged.
    /// A JPEG that needs no scaling is returned unchanged. Nil when the bytes are not an image.
    static func prepared(_ data: Data, maxPixel: Int) -> Data? {
        guard let size = pixelSize(data) else { return nil }
        let longest = max(size.width, size.height)
        let needsScale = maxPixel > 0 && longest > maxPixel
        if isJPEG(data) && !needsScale { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image: CGImage?
        if needsScale {
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The embedded picture of an audio file (AVFoundation first, ffmpeg for formats it cannot read).
    static func extract(from url: URL, ctx: OperationContext?) async -> Data? {
        let asset = AVURLAsset(url: url)
        for item in (try? await asset.load(.metadata)) ?? [] where item.commonKey == .commonKeyArtwork {
            if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
        }
        guard let ctx, ctx.tools.has(.ffmpeg) else { return nil }
        let tmp = ctx.tempDir.appendingPathComponent("cover-\(Util.hex8()).jpg")
        let args = AudFFmpegArgs.prefix + ["-i", url.path, "-map", "0:v:0", "-frames:v", "1", "-q:v", "2", "-f", "image2", tmp.path]
        guard (try? await ctx.runTool(.ffmpeg, args, onStdoutLine: { _ in })) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try? Data(contentsOf: tmp)
    }

    /// Writes prepared bytes to a temp file for use as a second ffmpeg input.
    static func writeTemp(_ data: Data, ctx: OperationContext) throws -> URL {
        let url = ctx.tempDir.appendingPathComponent("cover-\(Util.hex8()).jpg")
        try data.write(to: url)
        return url
    }

    /// The picture the plan wants in the output: replace -> the chosen file, keep -> the source's own (scaled when asked). Nil: none.
    static func data(for plan: AudPlan, info: AudInfo?, source: URL, ctx: OperationContext?) async -> Data? {
        switch plan.coverMode {
        case .remove, .extract: return nil
        case .replace:
            guard let f = plan.coverFile, let d = try? Data(contentsOf: f) else { return nil }
            return prepared(d, maxPixel: plan.coverMax)
        case .keep:
            guard info?.hasCover == true, let d = await extract(from: source, ctx: ctx) else { return nil }
            return prepared(d, maxPixel: plan.coverMax)
        }
    }
}

enum AudTagResolver {
    /// The tags the output should carry: keep -> the source's, strip -> none, custom -> the source's with the person's edits on top.
    static func effective(plan: AudPlan, info: AudInfo?) -> AudTags {
        switch plan.tagsMode {
        case .strip: return AudTags()
        case .keep: return info?.tags ?? AudTags()
        case .custom:
            var t = info?.tags ?? AudTags()
            for (name, value) in plan.tagEdits { t[name] = value }
            return t
        }
    }
}

enum AudMP4Meta {
    private static func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, type: String? = nil) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value
        if let type { m.dataType = type }
        m.extendedLanguageTag = "und"
        return m
    }

    /// Metadata items of an M4A / M4B / M4R file.
    static func items(tags: AudTags, cover: Data?) -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        let utf8 = kCMMetadataBaseDataType_UTF8 as String
        func text(_ id: AVMetadataIdentifier, _ s: String) { if !s.isEmpty { out.append(item(id, s as NSString, type: utf8)) } }
        text(.commonIdentifierTitle, tags.title)
        text(.commonIdentifierArtist, tags.artist)
        text(.commonIdentifierAlbumName, tags.album)
        text(.iTunesMetadataAlbumArtist, tags.albumArtist)
        text(.iTunesMetadataUserGenre, tags.genre)
        text(.iTunesMetadataComposer, tags.composer)
        text(.iTunesMetadataUserComment, tags.comment)
        text(.iTunesMetadataReleaseDate, tags.year)
        func number(_ s: String) -> UInt16 { UInt16(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        if !tags.track.isEmpty {
            let t = number(tags.track), n = number(tags.trackTotal)
            out.append(item(.iTunesMetadataTrackNumber, Data([0, 0, UInt8(t >> 8), UInt8(t & 0xFF), UInt8(n >> 8), UInt8(n & 0xFF), 0, 0]) as NSData,
                            type: kCMMetadataBaseDataType_RawData as String))
        }
        if !tags.disc.isEmpty {
            let d = number(tags.disc)
            out.append(item(.iTunesMetadataDiscNumber, Data([0, 0, UInt8(d >> 8), UInt8(d & 0xFF), 0, 0]) as NSData, type: kCMMetadataBaseDataType_RawData as String))
        }
        if let cover, !cover.isEmpty {
            out.append(item(.commonIdentifierArtwork, cover as NSData, type: AudCover.isJPEG(cover) ? kCMMetadataBaseDataType_JPEG as String : kCMMetadataBaseDataType_PNG as String))
        }
        return out
    }

    /// Copies `source` (an .m4a written by AVAudioFile) to `destination` with tags and artwork, without re-encoding.
    static func write(source: URL, destination: URL, tags: AudTags, cover: Data?) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw ConversionError.noOutput }
        session.metadata = items(tags: tags, cover: cover)
        try await session.export(to: destination, as: .m4a)
    }
}
