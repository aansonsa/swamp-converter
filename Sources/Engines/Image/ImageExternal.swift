import Foundation
import ImageIO
import CoreGraphics

/// The two outputs ImageIO cannot produce: WebP (`cwebp`) and JPEG with full colour detail (ffmpeg's MJPEG encoder). Both get their pixels from an
/// intermediate lossless PNG written by ImageIO, so the picture, the colour profile and the metadata policy are exactly those of every other format.
enum ImageExternal {
    // MARK: WebP

    static func writeWebP(_ image: CGImage, _ p: ImageEncodeParams, _ ctx: ImageEncodeContext, to url: URL) async throws {
        let cwebp = try ToolLocator.shared.require(.cwebp)
        let dir = AppPaths.makeTempDirectory(purpose: "webp")
        defer { AppPaths.removeTemp(dir) }
        let png = dir.appendingPathComponent("in.png")
        var pp = ImageEncodeParams(format: "png", options: [:])
        pp.metadataMode = p.metadataMode
        pp.dpi = p.dpi
        pp.optimizePNG = false
        try ImageEncoder.writeNative(image, pp, ctx, sink: .file(png))

        let meta = p.metadataMode == "strip" ? "icc" : "all"
        func run(_ extra: [String]) async throws {
            try await ProcessRunner.run(cwebp, extra + ["-metadata", meta, "-mt", png.path, "-o", url.path], toolName: "cwebp")
        }
        if let limit = p.targetBytes, !p.lossless {
            // cwebp aims at the size but may land a little above; tighten the aim until the file fits.
            var aim = limit
            for _ in 0..<5 {
                try Task.checkCancellation()
                try await run(["-size", String(aim), "-m", "6"])
                let size = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0)
                if size <= limit { return }
                aim = Int(Double(aim) * 0.93)
                try? FileManager.default.removeItem(at: url)
            }
            try await run(["-q", "20", "-m", "6"])
        } else if p.lossless {
            try await run(["-lossless", "-z", "6"])
        } else {
            try await run(["-q", String(p.quality), "-m", "6"])
        }
    }

    // MARK: JPEG 4:4:4

    /// mjpeg quality scale 2 (best) ... 31 (worst) from our 1...100.
    static func mjpegQuality(_ quality: Int) -> Int { min(31, max(2, 2 + (100 - min(100, max(1, quality))) * 29 / 100)) }

    static func writeJPEG444(_ image: CGImage, _ p: ImageEncodeParams, _ ctx: ImageEncodeContext, to url: URL) async throws {
        let ffmpeg = try ToolLocator.shared.require(.ffmpeg)
        let dir = AppPaths.makeTempDirectory(purpose: "j444")
        defer { AppPaths.removeTemp(dir) }
        // ffmpeg ignores colour profiles, so the pixels go in as sRGB and the result is untagged sRGB: correct everywhere.
        guard let srgb = ImageGeometry.render(image, .identity, colorSpace: ImageBitmap.sRGB, flatten: ImageBitmap.hasAlpha(image) ? p.background : nil) else { throw ImageLoader.outOfMemory() }
        var pp = ImageEncodeParams(format: "png", options: [:])
        pp.metadataMode = "strip"
        pp.optimizePNG = false
        let png = dir.appendingPathComponent("in.png"), jpg = dir.appendingPathComponent("out.jpg")
        try ImageEncoder.writeNative(srgb, pp, ImageEncodeContext(), sink: .file(png))
        try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", png.path, "-frames:v", "1", "-c:v", "mjpeg", "-pix_fmt", "yuvj444p",
                                             "-q:v", String(mjpegQuality(p.quality)), jpg.path], toolName: "ffmpeg")
        try Task.checkCancellation()
        if let dpi = p.dpi ?? ImageMetadata.dpi(ctx.sourceProperties)?.x { patchDensity(jpg, dpi: dpi) }
        if (p.metadataMode == "keep" || p.metadataMode == "noGPS"), mergeMetadata(from: ctx, into: jpg, to: url, image: image, noGPS: p.metadataMode == "noGPS") { return }
        try FileManager.default.moveItem(at: jpg, to: url)
    }

    /// Writes the dots-per-inch value into the JFIF header (units = 1, X / Y density).
    static func patchDensity(_ jpeg: URL, dpi: Double) {
        guard var data = try? Data(contentsOf: jpeg), data.count > 20, data[2] == 0xFF, data[3] == 0xE0, data[6] == 0x4A, data[7] == 0x46 else { return }
        let d = UInt16(min(65535, max(1, dpi.rounded())))
        data[13] = 1
        data[14] = UInt8(d >> 8); data[15] = UInt8(d & 255); data[16] = UInt8(d >> 8); data[17] = UInt8(d & 255)
        try? data.write(to: jpeg)
    }

    /// Lossless copy of the encoded JPEG with the source's EXIF / XMP / IPTC merged in (orientation reset: the pixels are already upright).
    private static func mergeMetadata(from ctx: ImageEncodeContext, into jpeg: URL, to url: URL, image: CGImage, noGPS: Bool) -> Bool {
        guard let srcURL = ctx.sourceURL, let orig = CGImageSourceCreateWithURL(srcURL as CFURL, nil), let md = CGImageSourceCopyMetadataAtIndex(orig, 0, nil),
              let mutable = CGImageMetadataCreateMutableCopy(md),
              let enc = CGImageSourceCreateWithURL(jpeg as CFURL, nil), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageMetadataSetValueWithPath(mutable, nil, "tiff:Orientation" as CFString, ctx.orientation as CFNumber)
        CGImageMetadataSetValueWithPath(mutable, nil, "exif:PixelXDimension" as CFString, image.width as CFNumber)
        CGImageMetadataSetValueWithPath(mutable, nil, "exif:PixelYDimension" as CFString, image.height as CFNumber)
        let options: [CFString: Any] = [kCGImageDestinationMetadata: mutable, kCGImageDestinationMergeMetadata: true, kCGImageMetadataShouldExcludeGPS: noGPS]
        var error: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dest, enc, options as CFDictionary, &error)
        if !ok { try? FileManager.default.removeItem(at: url) }
        return ok
    }
}
