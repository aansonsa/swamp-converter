import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Colour space, grayscale, resolution (DPI), metadata modes and multi-frame oracles.
enum ImageColourTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    /// A JPEG that carries location, camera, copyright and capture date (what the privacy options must handle).
    static func taggedJPEG(_ fx: TestFixtures, _ name: String = "tagged.jpg", width: Int = 120, height: Int = 90, orientation: Int? = nil) throws -> URL {
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 56.95, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 24.10, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SwampCam", kCGImagePropertyTIFFModel: "Frog 1", kCGImagePropertyTIFFCopyright: "Swamp 2026"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 12:30:00"] as [CFString: Any]]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        return try fx.writeImage(fx.cgImage(width: width, height: height, pattern: .gradient), name: name, type: .jpeg, properties: props)
    }

    static func exifDate(_ url: URL) -> String? { ImgT.dict(url, kCGImagePropertyExifDictionary)?[kCGImagePropertyExifDateTimeOriginal] as? String }
    static func copyright(_ url: URL) -> String? { ImgT.dict(url, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFCopyright] as? String }

    static func register() {
        // MARK: Colour

        t("colour space: sRGB, Display P3, Adobe RGB and gray are embedded and the picture still looks the same", proves: ["image.cs.profile"]) {
            let fx = TestFixtures(label: "imgcs"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 320, height: 240)
            for (value, needle, minPSNR) in [("srgb", "sRGB", 33.0), ("p3", "Display P3", 33.0), ("adobe", "Adobe RGB", 33.0)] {
                let out = try await ImgT.convert(src, [K.format: "jpeg", K.colorSpace: .string(value)])
                try expect(ImgT.profile(out).contains(needle), "\(value): profile is '\(ImgT.profile(out))'")
                let psnr = try unwrap(ImgMetrics.psnr(src, out))
                try expect(psnr >= minPSNR, "\(value): colours must not shift, PSNR \(psnr)")
            }
            let gray = try await ImgT.convert(src, [K.format: "png", K.colorSpace: "gray"])
            try expect((ImgT.props(gray)[kCGImagePropertyColorModel] as? String) == "Gray", "gray model: \(String(describing: ImgT.props(gray)[kCGImagePropertyColorModel]))")
        }

        t("a wide-gamut 16-bit source keeps its profile and depth unless told otherwise", proves: ["image.cs.profile"]) {
            let fx = TestFixtures(label: "imgwide"); defer { fx.cleanup() }
            let src = try ImgT.wideGamut(fx, "p3.tiff")
            try expect(ImgT.profile(src).contains("Display P3"), "fixture profile '\(ImgT.profile(src))'")
            try expectEqual(ImgT.depth(src), 16, "fixture depth")
            let keep = try await ImgT.convert(src, [K.format: "tiff"])
            try expect(ImgT.profile(keep).contains("Display P3"), "kept profile '\(ImgT.profile(keep))'")
            try expectEqual(ImgT.depth(keep), 16, "kept depth")
            let png = try await ImgT.convert(src, [K.format: "png"])
            try expect(ImgT.profile(png).contains("Display P3"), "PNG profile '\(ImgT.profile(png))'")
            let jpeg = try await ImgT.convert(src, [K.format: "jpeg"])
            try expect(ImgT.profile(jpeg).contains("Display P3"), "JPEG profile '\(ImgT.profile(jpeg))'")
            try expectEqual(ImgT.depth(jpeg), 8, "JPEG is 8-bit")
            let srgb = try await ImgT.convert(src, [K.format: "png", K.colorSpace: "srgb"])
            try expect(ImgT.profile(srgb).contains("sRGB"), "converted to sRGB '\(ImgT.profile(srgb))'")
        }

        t("black and white: Rec. 709 luminance in every channel", proves: ["image.gray.pixels"]) {
            let fx = TestFixtures(label: "imggray"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 240, height: 180)
            let out = try await ImgT.convert(src, [K.format: "png", K.gray: true])
            let a = try unwrap(ImgMetrics.pixels(src)), b = try unwrap(ImgMetrics.pixels(out))
            var maxDiff = 0, sum = 0
            for i in stride(from: 0, to: a.data.count, by: 4) {
                let y = 0.2126 * Double(a.data[i]) + 0.7152 * Double(a.data[i + 1]) + 0.0722 * Double(a.data[i + 2])
                let r = Int(b.data[i]), g = Int(b.data[i + 1]), bl = Int(b.data[i + 2])
                try expect(abs(r - g) <= 1 && abs(g - bl) <= 1, "pixel \(i / 4) is not neutral: \(r),\(g),\(bl)")
                let d = abs(Int(y.rounded()) - g); maxDiff = max(maxDiff, d); sum += d
            }
            try expect(maxDiff <= 8, "luminance deviates by up to \(maxDiff)")
            try expect(Double(sum) / Double(a.data.count / 4) <= 2.5, "mean luminance error \(Double(sum) / Double(a.data.count / 4))")
            // Transparency stays transparent.
            let al = try ImgMetrics.photo(fx, "alpha.png", width: 100, height: 60, alpha: true)
            let g2 = try await ImgT.convert(al, [K.format: "png", K.gray: true])
            try expect(try unwrap(ImgT.pixel(g2, 0.9, 0.5)).a < 10, "alpha kept through gray")
        }

        // MARK: DPI

        t("DPI: the tag is written, kept from the source, and sizes a PDF page", proves: ["image.dpi.tag"]) {
            let fx = TestFixtures(label: "imgdpi"); defer { fx.cleanup() }
            let src = try fx.writeImage(fx.cgImage(width: 300, height: 200, pattern: .gradient), name: "d144.jpg", type: .jpeg,
                                        properties: [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
            try expectClose(try unwrap(ImgT.dpi(src)), 144, tolerance: 0.5)
            for fmt in ["jpeg", "png", "tiff"] {
                let set = try await ImgT.convert(src, [K.format: .string(fmt), K.dpi: "300"])
                try expectClose(try unwrap(ImgT.dpi(set)), 300, tolerance: 1, "\(fmt) DPI set")
                let keep = try await ImgT.convert(src, [K.format: .string(fmt), K.dpi: "keep"])
                try expectClose(try unwrap(ImgT.dpi(keep)), 144, tolerance: 1, "\(fmt) DPI kept")
                try expect(ImgT.size(set) == (300, 200), "DPI changes the tag, not the pixels")
            }
            let pdf300 = try await ImgT.convert(src, [K.format: "pdf", K.dpi: "300"])
            let box = try unwrap(ImgT.mediaBox(pdf300))
            try expectClose(box.width, 72, tolerance: 1, "300 px at 300 dpi are 72 pt"); try expectClose(box.height, 48, tolerance: 1)
            let pdfKeep = try await ImgT.convert(src, [K.format: "pdf"])
            try expectClose(try unwrap(ImgT.mediaBox(pdfKeep)).width, 150, tolerance: 1, "300 px at the source's 144 dpi are 150 pt")
        }

        // MARK: Metadata

        t("metadata keep: location, camera, copyright and date stay", proves: ["image.md.exif"]) {
            let fx = TestFixtures(label: "imgmd1"); defer { fx.cleanup() }
            let src = try taggedJPEG(fx)
            try expect(ImgT.hasGPS(src) && ImgT.make(src) == "SwampCam", "fixture carries tags")
            var formats = ["jpeg", "tiff"]
            if Capabilities.shared.has("native.imageio.write.heic") { formats.append("heic") }
            for fmt in formats {
                let out = try await ImgT.convert(src, [K.format: .string(fmt), K.mdMode: "keep"])
                try expect(ImgT.hasGPS(out), "\(fmt): GPS kept")
                try expectEqual(ImgT.make(out), "SwampCam", "\(fmt): camera kept")
                try expectEqual(copyright(out), "Swamp 2026", "\(fmt): copyright kept")
                try expectEqual(exifDate(out), "2024:05:01 12:30:00", "\(fmt): date kept")
            }
        }

        t("metadata noGPS: only the location goes", proves: ["image.md.exif"]) {
            let fx = TestFixtures(label: "imgmd2"); defer { fx.cleanup() }
            let src = try taggedJPEG(fx)
            var formats = ["jpeg", "tiff"]
            if Capabilities.shared.has("native.imageio.write.heic") { formats.append("heic") }
            for fmt in formats {
                let out = try await ImgT.convert(src, [K.format: .string(fmt), K.mdMode: "noGPS"])
                try expect(!ImgT.hasGPS(out), "\(fmt): GPS removed")
                try expectEqual(ImgT.make(out), "SwampCam", "\(fmt): camera kept")
                try expectEqual(exifDate(out), "2024:05:01 12:30:00", "\(fmt): date kept")
            }
        }

        t("metadata strip: nothing identifying is left, the colour profile stays", proves: ["image.md.exif"]) {
            let fx = TestFixtures(label: "imgmd3"); defer { fx.cleanup() }
            let src = try taggedJPEG(fx)
            var formats = ["jpeg", "tiff", "png"]
            if Capabilities.shared.has("native.imageio.write.heic") { formats.append("heic") }
            for fmt in formats {
                let out = try await ImgT.convert(src, [K.format: .string(fmt), K.mdMode: "strip"])
                try expect(!ImgT.hasGPS(out), "\(fmt): GPS removed")
                try expect(ImgT.make(out) == nil, "\(fmt): camera removed")
                try expect(copyright(out) == nil, "\(fmt): copyright removed")
                try expect(exifDate(out) == nil, "\(fmt): date removed")
                try expect(!ImgT.profile(out).isEmpty, "\(fmt): colour profile kept ('\(ImgT.profile(out))')")
            }
            // The raw bytes hold no leftover coordinates or camera name either.
            let out = try await ImgT.convert(src, [K.format: "jpeg", K.mdMode: "strip"])
            let bytes = try Data(contentsOf: out)
            try expect(bytes.range(of: Data("SwampCam".utf8)) == nil, "camera name is nowhere in the bytes")
            try expect(bytes.range(of: Data("Swamp 2026".utf8)) == nil, "copyright is nowhere in the bytes")
        }

        t("metadata strip with a rotated source bakes the rotation instead of losing it", proves: ["image.md.exif", "image.orient.bake"]) {
            let fx = TestFixtures(label: "imgmd4"); defer { fx.cleanup() }
            let src = try fx.jpeg("o6.jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: 6, gps: true)
            let out = try await ImgT.convert(src, [K.format: "jpeg", K.mdMode: "strip", K.autoOrient: false])
            // Even with "apply camera rotation" off, a stripped file must not lose the information that decides how it looks.
            let upright = ImgT.size(out) == (40, 80) || (ImgT.props(out)[kCGImagePropertyOrientation] as? Int) == 6
            try expect(upright, "rotation survives stripping: size \(ImgT.size(out)), tag \(String(describing: ImgT.props(out)[kCGImagePropertyOrientation]))")
            try expect(!ImgT.hasGPS(out), "GPS gone")
        }

        t("the privacy override removes metadata from any quick recipe") {
            let ops = ImageCatalog.operations()
            for op in ops where op.meta.id != "image.merge.pdf" { try expectEqual(op.privacyOverrides()[K.mdMode]?.asString, "strip", op.meta.id) }
            let fx = TestFixtures(label: "imgmd5"); defer { fx.cleanup() }
            let src = try taggedJPEG(fx)
            let r = try await ImgT.run("image.half", [src], ImgT.op("image.half").privacyOverrides())
            let out = try unwrap(r.outputs.first)
            try expect(!ImgT.hasGPS(out) && ImgT.make(out) == nil, "half + privacy = no location, no camera")
        }

        // MARK: Frames

        t("several frames: first only, every frame as a file, or the animation kept", proves: ["image.frames.count"]) {
            let fx = TestFixtures(label: "imgframes"); defer { fx.cleanup() }
            let gif = try ImgT.animatedGIF(fx, "anim.gif", frames: 3, width: 40, height: 30, delay: 0.2)
            let first = try await ImgT.convert(gif, [K.format: "png", K.frames: "first"])
            try expect(TestImage.close(ImgT.pixel(first, 0.5, 0.5), .red, tolerance: 12), "first frame is red")
            try expectEqual(ImgT.frameCount(first), 1)

            let r = try await ImgT.run("image.to.png", [gif], [K.frames: "all"], mode: .studio)
            try expectEqual(r.outputs.count, 3, "one file per frame")
            let sorted = r.outputs.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for (url, colour) in zip(sorted, [RGBA.red, .green, .blue]) {
                try expect(TestImage.close(ImgT.pixel(url, 0.5, 0.5), colour, tolerance: 25), "\(url.lastPathComponent) should be \(colour)")
            }
            try expect(sorted[0].lastPathComponent.contains("1") && sorted[2].lastPathComponent.contains("3"), "frames are numbered: \(sorted.map(\.lastPathComponent))")

            let anim = try await ImgT.convert(gif, [K.format: "gif", K.frames: "animated"])
            try expectEqual(ImgMetrics.sniff(anim), "gif")
            try expectEqual(ImgT.frameCount(anim), 3, "the animation is kept")
            let delay = (ImgMetrics.frameProps(anim, 1)?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double
            try expectClose(delay ?? 0, 0.2, tolerance: 0.03, "frame delay")
            try expect(TestImage.close(ImgMetrics.pixel(anim, frame: 2, 0.5, 0.5), .blue, tolerance: 25), "third frame is blue")
        }
    }
}
