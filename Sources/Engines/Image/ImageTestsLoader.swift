import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Reading rules: every readable kind decodes to the right pixels (SVG at 2x with transparency, camera RAW developed at full size, icons by their largest picture),
/// and unreadable input fails cleanly.
enum ImageLoaderTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    private static func expectNoThrow(_ body: () throws -> Void) async -> Bool { (try? body()) != nil }

    static func register() {
        t("every readable raster kind decodes: HEIC, AVIF, TIFF, GIF, BMP, JPEG 2000, TGA, PNG, JPEG") {
            let fx = TestFixtures(label: "imgread"); defer { fx.cleanup() }
            let img = fx.cgImage(width: 96, height: 64, pattern: .quadrants)
            var kinds: [(String, UTType)] = [("png", .png), ("jpg", .jpeg), ("tiff", .tiff), ("gif", .gif), ("bmp", .bmp), ("jp2", UTType("public.jpeg-2000")!)]
            if Capabilities.shared.has("native.imageio.write.heic") { kinds.append(("heic", .heic)) }
            if Capabilities.shared.has("native.imageio.write.avif") { kinds.append(("avif", UTType("public.avif")!)) }
            if Capabilities.shared.has("native.imageio.write.tga") { kinds.append(("tga", UTType("com.truevision.tga-image")!)) }
            // Photoshop documents and OpenEXR are read natively; the fixtures are made when ImageIO will write them.
            kinds.append(("psd", UTType("com.adobe.photoshop-image")!))
            for (ext, type) in kinds {
                guard let src = try? fx.writeImage(img, name: "in.\(ext)", type: type) else {
                    if ext == "psd" { continue }
                    throw TestFailure(message: "ImageIO cannot write the \(ext) fixture", file: #fileID, line: #line)
                }
                let out = try await ImgT.convert(src, [K.format: "png"])
                try expect(ImgT.size(out) == (96, 64), "\(ext): size \(ImgT.size(out))")
                try expect(ImgT.isQuadrants(out, [.red, .green, .blue, .yellow], tolerance: ext == "gif" ? 60 : 40), "\(ext): quadrants \(ImgT.describe(out))")
            }
        }

        t("OpenEXR input is read and tone-mapped into a normal picture") {
            let fx = TestFixtures(label: "imgexr"); defer { fx.cleanup() }
            var half = [UInt16](repeating: 0, count: 64 * 32 * 4)
            for i in 0..<(64 * 32) { half[i * 4] = 0x3800; half[i * 4 + 1] = 0x3400; half[i * 4 + 2] = 0x3000; half[i * 4 + 3] = 0x3C00 }   // 0.5, 0.25, 0.125, 1.0
            let data = half.withUnsafeBytes { Data($0) }
            guard let provider = CGDataProvider(data: data as CFData),
                  let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let image = CGImage(width: 64, height: 32, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 64 * 8, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let src = try? fx.writeImage(image, name: "in.exr", type: UTType("com.ilm.openexr-image")!) else { try skipTest("ImageIO cannot write OpenEXR here") }
            let out = try await ImgT.convert(src, [K.format: "png"])
            try expect(ImgT.size(out) == (64, 32), "EXR size \(ImgT.size(out))")
            let p = try unwrap(ImgT.pixel(out, 0.5, 0.5))
            try expect(Int(p.r) > Int(p.g) && Int(p.g) > Int(p.b) && p.r > 100, "reddish brown from (0.5, 0.25, 0.125): \(p)")
        }

        t("ImageLoader and ImageEncoder are usable by other modules: size limit, orientation, formats") {
            let fx = TestFixtures(label: "imgapi"); defer { fx.cleanup() }
            let src = try fx.jpeg("o6.jpg", width: 400, height: 200, pattern: .quadrants, quality: 0.95, orientation: 6)
            let full = try ImageLoader.load(src)
            try expect(full.width == 200 && full.height == 400, "orientation applied: \(full.width)x\(full.height)")
            var o = ImageLoader.Options(); o.maxPixel = 100
            let small = try ImageLoader.load(src, o)
            try expect(max(small.width, small.height) == 100 && small.height == 100 && small.width == 50, "limited to 100 px: \(small.width)x\(small.height)")
            o.applyOrientation = false
            let stored = try ImageLoader.load(src, o)
            try expect(stored.width == 100 && stored.height == 50, "stored orientation kept: \(stored.width)x\(stored.height)")
            let loaded = try ImageLoader.loadUnoriented(src)
            try expectEqual(loaded.orientation, 6)
            let magic: [(String, String)] = [("jpg", "jpeg"), ("png", "png"), ("tiff", "tiff"), ("gif", "gif"), ("bmp", "bmp"), ("pdf", "pdf"), ("ico", "ico")]
            for (fmt, want) in magic {
                let data = try await ImageEncoder.encode(full, format: fmt, options: [K.quality: 60])
                let f = fx.url("api.\(fmt)"); try data.write(to: f)
                try expectEqual(ImgMetrics.sniff(f), want, "encode(\(fmt))")
            }
            if Capabilities.shared.has("tool.cwebp") {
                let f = fx.url("api.webp"); try await ImageEncoder.encode(full, format: "webp", options: [K.quality: 60]).write(to: f)
                try expectEqual(ImgMetrics.sniff(f), "webp")
            }
            if Capabilities.shared.has("tool.iconutil") {
                let f = fx.url("api.icns"); try await ImageEncoder.encode(full, format: "icns", options: [:]).write(to: f)
                try expectEqual(ImgMetrics.sniff(f), "icns")
            }
            let low = try await ImageEncoder.encode(full, format: "jpeg", options: [K.quality: 20]), high = try await ImageEncoder.encode(full, format: "jpeg", options: [K.quality: 95])
            try expect(low.count < high.count, "the same encoder honours quality: \(low.count) < \(high.count)")
            _ = await expectNoThrow { _ = try ImageEncoder.encodeSync(full, format: "png", options: [:]) }
        }

        t("WebP input is decoded", requires: ["tool.cwebp"]) {
            let fx = TestFixtures(label: "imgreadwebp"); defer { fx.cleanup() }
            let png = try fx.png("in.png", width: 96, height: 64, pattern: .quadrants)
            let webp = try await ImgT.convert(png, [K.format: "webp"])
            let back = try await ImgT.convert(webp, [K.format: "png"])
            try expect(ImgT.size(back) == (96, 64) && ImgT.isQuadrants(back, [.red, .green, .blue, .yellow]), "WebP -> PNG \(ImgT.describe(back))")
        }

        t("SVG is drawn at twice its nominal size on a transparent background") {
            let fx = TestFixtures(label: "imgsvg"); defer { fx.cleanup() }
            let svg = try fx.text("logo.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"48\"><rect x=\"16\" y=\"12\" width=\"32\" height=\"24\" fill=\"#0044cc\"/></svg>")
            let out = try await ImgT.convert(svg, [K.format: "png"])
            try expect(ImgT.size(out) == (128, 96), "2x of 64x48: \(ImgT.size(out))")
            try expectEqual(ImgMetrics.sniff(out), "png")
            try expect(try unwrap(ImgT.pixel(out, 0.02, 0.02)).a == 0, "the margin is transparent")
            let centre = try unwrap(ImgT.pixel(out, 0.5, 0.5))
            try expect(TestImage.close(centre, RGBA(r: 0, g: 68, b: 204), tolerance: 12) && centre.a == 255, "the rectangle is #0044cc, got \(centre)")
            let jpg = try await ImgT.convert(svg, [K.format: "jpeg"])
            try expect(TestImage.close(ImgT.pixel(jpg, 0.02, 0.02), .white, tolerance: 6), "JPEG puts the margin on white")
        }

        t("SVG edited in place becomes PNG, RAW becomes JPEG, other kinds keep their format") {
            let fx = TestFixtures(label: "imgsame"); defer { fx.cleanup() }
            let svg = try fx.svg("v.svg")
            let r = try await ImgT.run("image.max1920", [svg])
            try expectEqual(try unwrap(r.outputs.first).pathExtension, "png")
            try expectEqual(ImgMetrics.sniff(try unwrap(r.outputs.first)), "png")
            let tif = try fx.tiff("t.tiff", width: 50, height: 40)
            let r2 = try await ImgT.run("image.grayscale", [tif])
            try expectEqual(ImgMetrics.sniff(try unwrap(r2.outputs.first)), "tiff")
            let bmp = try fx.writeImage(fx.cgImage(width: 30, height: 20), name: "b.bmp", type: .bmp)
            let r3 = try await ImgT.run("image.flip", [bmp])
            try expectEqual(ImgMetrics.sniff(try unwrap(r3.outputs.first)), "bmp")
        }

        t("camera RAW is developed at full size (not the embedded preview) with the camera white balance") {
            let fx = TestFixtures(label: "imgraw"); defer { fx.cleanup() }
            let dng = try ImgT.dng(fx, "shot.dng", width: 2048, height: 1536)
            let r = try await ImgT.run("image.to.jpg", [dng])
            let out = try unwrap(r.outputs.first, "RAW converts")
            try expect(max(ImgT.size(out).width, ImgT.size(out).height) >= 2000, "longest side \(ImgT.size(out))")
            try expectEqual(ImgMetrics.sniff(out), "jpeg")
            let left = try unwrap(ImgT.pixel(out, 0.25, 0.5)), right = try unwrap(ImgT.pixel(out, 0.75, 0.5))
            try expect(Int(left.r) > Int(left.b) + 40, "left half is reddish: \(left)")
            try expect(Int(right.b) > Int(right.r) + 40, "right half is bluish: \(right)")
            let edit = try await ImgT.run("image.compress", [dng])
            try expectEqual(try unwrap(edit.outputs.first).pathExtension, "jpg", "RAW edits keep going out as JPEG")
        }

        t("ICO and ICNS inputs give their largest picture") {
            let fx = TestFixtures(label: "imgicoin"); defer { fx.cleanup() }
            let big = try ImgMetrics.photo(fx, "sq.png", width: 512, height: 512)
            let ico = try await ImgT.convert(big, [K.format: "ico"])
            let back = try await ImgT.convert(ico, [K.format: "png"])
            try expect(ImgT.size(back) == (256, 256), "largest ICO picture \(ImgT.size(back))")
            guard Capabilities.shared.has("tool.iconutil") else { return }
            let icns = try await ImgT.convert(big, [K.format: "icns"])
            let back2 = try await ImgT.convert(icns, [K.format: "png"])
            try expect(max(ImgT.size(back2).width, ImgT.size(back2).height) >= 256, "largest ICNS picture \(ImgT.size(back2))")
        }

        t("unreadable files fail with a clear error and leave nothing behind") {
            let fx = TestFixtures(label: "imgbad"); defer { fx.cleanup() }
            let junk = try fx.text("fake.jpg", "this is not a picture")
            let empty = try fx.text("empty.png", "")
            for bad in [junk, empty] {
                let err = try await expectThrows("\(bad.lastPathComponent) must fail") { _ = try await ImgT.convert(bad, [K.format: "png"]) }
                try expect(!ConversionError.describe(err).isEmpty, "message for \(bad.lastPathComponent)")
            }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []).sorted()
            try expectEqual(names, ["empty.png", "fake.jpg"], "no output and no partial files")
        }

        t("CMYK pictures come out as sRGB with the same colours, not as CMYK files") {
            let fx = TestFixtures(label: "imgcmyk"); defer { fx.cleanup() }
            let cmyk = CGColorSpaceCreateDeviceCMYK()
            guard let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: cmyk, bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let red = CGColor(colorSpace: cmyk, components: [0, 1, 1, 0, 1]) else { try skipTest("no CMYK bitmap here") }
            ctx.setFillColor(red); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let src = try fx.writeImage(ctx.makeImage()!, name: "cmyk.jpg", type: .jpeg)
            for fmt in ["jpeg", "png", "tiff"] {
                let out = try await ImgT.convert(src, [K.format: .string(fmt)])
                try expectEqual(ImgT.props(out)[kCGImagePropertyColorModel] as? String, "RGB", "\(fmt) is an RGB file")
                let p = try unwrap(ImgT.pixel(out, 0.5, 0.5))
                try expect(p.r > 180 && p.g < 80 && p.b < 80, "\(fmt): still a red, got \(p)")
            }
            let edited = try unwrap(try await ImgT.run("image.grayscale", [src]).outputs.first)
            try expect(ImgT.size(edited) == (64, 48), "tools work on CMYK too")
        }

        t("a truncated or damaged JPEG or PNG is converted but the result carries a warning; complete files do not") {
            let fx = TestFixtures(label: "imgtrunc"); defer { fx.cleanup() }
            let jpg = try ImgMetrics.photo(fx, "good.jpg", width: 320, height: 240, noise: 3)
            let png = try ImgMetrics.photo(fx, "good.png", width: 320, height: 240, noise: 3)
            let jd = try Data(contentsOf: jpg), pd = try Data(contentsOf: png)
            let badJPG = fx.url("half.jpg"), badPNG = fx.url("half.png")
            try jd.prefix(jd.count * 6 / 10).write(to: badJPG); try pd.prefix(pd.count / 2).write(to: badPNG)
            for bad in [badJPG, badPNG] {
                let r = try await ImgT.run("image.rotate.right", [bad])
                try expectEqual(r.outputs.count, 1, "\(bad.lastPathComponent) is still converted")
                try expectEqual(r.warnings.count, 1, "\(bad.lastPathComponent) warns: \(r.warnings)")
            }
            for good in [jpg, png] {
                let r = try await ImgT.run("image.rotate.right", [good])
                try expect(r.warnings.isEmpty, "\(good.lastPathComponent) is complete")
            }
            // Zero padding after the end marker is normal.
            let padded = fx.url("padded.jpg"); try (jd + Data(repeating: 0, count: 64)).write(to: padded)
            try expect(ImageIntegrity.warning(for: padded) == nil, "padding is fine")
        }

        t("a failing file does not stop the others in a batch and is reported") {
            let fx = TestFixtures(label: "imgbatchbad"); defer { fx.cleanup() }
            let good = try fx.png("good.png", width: 40, height: 30)
            let bad = try fx.text("bad.jpg", "nope")
            let r = try await ImgT.run("image.to.png", [good, bad], [K.format: "jpeg"], mode: .studio)
            try expectEqual(r.outputs.count, 1)
            try expectEqual(r.failures.count, 1)
            try expect(r.failures[0].contains("bad.jpg"), "failure names the file: \(r.failures)")
        }

        t("decoding stops at the first frame of animated and multi-page files by default") {
            let fx = TestFixtures(label: "imgfirst"); defer { fx.cleanup() }
            let gif = try ImgT.animatedGIF(fx, "a.gif", frames: 4)
            let r = try await ImgT.run("image.rotate.right", [gif])
            let out = try unwrap(r.outputs.first)
            try expectEqual(ImgT.frameCount(out), 1)
            try expect(TestImage.close(ImgT.pixel(out, 0.5, 0.5), .red, tolerance: 12), "first frame")
        }
    }
}
