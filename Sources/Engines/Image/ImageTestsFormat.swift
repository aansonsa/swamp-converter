import Foundation
import ImageIO
import CoreGraphics

/// Format, quality, container and file-size oracles: what is written is the REAL format (magic bytes + ImageIO + `file`), with the right extension, decoded
/// pixels close to the source, and the knobs move size and quality the right way.
enum ImageFormatTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    /// (canonical format, extension, magic-byte sniff, ImageIO type, minimum PSNR vs the 640x480 photo at the default quality 90, requires)
    static let targets: [(format: String, ext: String, sniff: String, uti: String, psnr: Double, requires: [String])] = [
        ("jpeg", "jpg", "jpeg", "public.jpeg", 33, []),
        ("png", "png", "png", "public.png", 90, []),
        ("tiff", "tiff", "tiff", "public.tiff", 90, []),
        ("bmp", "bmp", "bmp", "com.microsoft.bmp", 90, []),
        ("heic", "heic", "heic", "public.heic", 31, ["native.imageio.write.heic"]),
        ("avif", "avif", "avif", "public.avif", 28, ["native.imageio.write.avif"]),
        ("jp2", "jp2", "jp2", "public.jpeg-2000", 31, ["native.imageio.write.jp2"]),
        ("gif", "gif", "gif", "com.compuserve.gif", 24, []),
        ("webp", "webp", "webp", "org.webmproject.webp", 33, ["tool.cwebp"])
    ]

    static func register() {
        for target in targets {
            t("converts to \(target.format.uppercased()): real \(target.format) data, extension .\(target.ext), pixels close to the source",
              proves: target.format == "jpeg" ? ["image.format.type"] : [], requires: target.requires) {
                let fx = TestFixtures(label: "imgfmt"); defer { fx.cleanup() }
                let src = try ImgMetrics.photo(fx, "photo.png")
                let out = try await ImgT.convert(src, [K.format: .string(target.format)])
                try expectEqual(out.pathExtension, target.ext, "output extension")
                try expectEqual(ImgMetrics.sniff(out), target.sniff, "magic bytes")
                try expectEqual(ImgMetrics.imageIOType(out), target.uti, "ImageIO type")
                try expect(ImgMetrics.mime(out).hasPrefix("image/") || target.format == "heic" || target.format == "avif", "file(1) says \(ImgMetrics.mime(out))")
                try expect(TestFile.size(out) > 0 && TestFile.size(out) != TestFile.size(src) || target.format == "png", "not a copy of the input")
                let psnr = try unwrap(ImgMetrics.psnr(src, out), "output decodes at the source size")
                try expect(psnr >= target.psnr, "\(target.format) PSNR \(psnr) dB below \(target.psnr)")
                try expectEqual(ImgT.size(out).width, 640); try expectEqual(ImgT.size(out).height, 480)
            }
        }

        t("lossless pairs are bit exact: PNG, TIFF and BMP reproduce the source pixels") {
            let fx = TestFixtures(label: "imglossless"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 160, height: 120)
            for fmt in ["png", "tiff", "bmp"] {
                let out = try await ImgT.convert(src, [K.format: .string(fmt)])
                try expect(ImgMetrics.identical(src, out), "\(fmt) must reproduce every pixel")
            }
        }

        t("PDF output is a one-page PDF whose page shows the picture", proves: ["image.format.type"]) {
            let fx = TestFixtures(label: "imgpdf1"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 320, height: 240)
            let out = try await ImgT.convert(src, [K.format: "pdf"])
            try expectEqual(out.pathExtension, "pdf")
            try expectEqual(ImgMetrics.sniff(out), "pdf")
            let box = try unwrap(ImgT.mediaBox(out), "PDFKit opens it")
            try expectClose(box.width, 320, tolerance: 1); try expectClose(box.height, 240, tolerance: 1)
            try expectEqual(PDFProbe.pageCount(out), 1)
            let page = try unwrap(PDFProbe.render(out), "page renders")
            let psnr = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(src)), try unwrap(ImgMetrics.pixels(page))), "same size")
            try expect(psnr >= 30, "PDF page PSNR \(psnr)")
        }

        t("PDF at quality 100 keeps the pixels without loss; lower qualities are JPEG pages", proves: ["image.quality.bytes"]) {
            let fx = TestFixtures(label: "imgpdf100"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 320, height: 240, noise: 3)
            let lossless = try await ImgT.convert(src, [K.format: "pdf", K.quality: 100])
            let lossy = try await ImgT.convert(src, [K.format: "pdf", K.quality: 60])
            let pl = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(src)), try unwrap(ImgMetrics.pixels(try unwrap(PDFProbe.render(lossless))))))
            let pq = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(src)), try unwrap(ImgMetrics.pixels(try unwrap(PDFProbe.render(lossy))))))
            try expect(pl >= 50, "quality 100 PSNR \(pl)")
            try expect(pq < pl, "quality 60 is lossier (\(pq) dB)")
            try expect(TestFile.size(lossy) < TestFile.size(lossless), "\(TestFile.size(lossy)) < \(TestFile.size(lossless))")
        }

        t("HEIC keeps transparency", requires: ["native.imageio.write.heic"]) {
            let fx = TestFixtures(label: "imgheica"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "alpha.png", width: 200, height: 100, alpha: true)
            let out = try await ImgT.convert(src, [K.format: "heic"])
            try expect(try unwrap(ImgT.pixel(out, 0.9, 0.5)).a < 20, "the hole stays transparent")
            try expect(try unwrap(ImgT.pixel(out, 0.2, 0.5)).a > 235, "the picture stays opaque")
        }

        t("ICNS output is a real icon file with several sizes", proves: ["image.format.type"], requires: ["tool.iconutil"]) {
            let fx = TestFixtures(label: "imgicns"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "square.png", width: 600, height: 600)
            let out = try await ImgT.convert(src, [K.format: "icns"])
            try expectEqual(out.pathExtension, "icns")
            try expectEqual(ImgMetrics.sniff(out), "icns")
            try expect(ImgT.frameCount(out) >= 4, "icns holds \(ImgT.frameCount(out)) pictures")
            try expect(ImgMetrics.mime(out).contains("icns") || ImgMetrics.mime(out).hasPrefix("image/"), "file(1): \(ImgMetrics.mime(out))")
        }

        t("TGA output decodes as TGA with the picture", proves: ["image.format.type"], requires: ["native.imageio.write.tga"]) {
            let fx = TestFixtures(label: "imgtga"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 100, height: 80)
            let out = try await ImgT.convert(src, [K.format: "tga"])
            try expectEqual(out.pathExtension, "tga")
            try expectEqual(ImgMetrics.imageIOType(out), "com.truevision.tga-image")
            try expect(ImgMetrics.identical(src, out), "TGA is lossless")
        }

        t("output is never byte-identical to the input and the extension matches the sniffed format") {
            let fx = TestFixtures(label: "imgnotcopy"); defer { fx.cleanup() }
            let jpg = try ImgMetrics.photo(fx, "photo.jpg", width: 200, height: 150)
            let out = try await ImgT.convert(jpg, [K.format: "png"])
            try expect(try Data(contentsOf: out) != Data(contentsOf: jpg), "a PNG is not the JPEG bytes")
            try expectEqual(ImgMetrics.sniff(out), "png")
            // Even same-format studio output is a re-encode, not a copy, when the format is chosen explicitly.
            let again = try await ImgT.convert(jpg, [K.format: "jpeg", K.quality: 60])
            try expect(try Data(contentsOf: again) != Data(contentsOf: jpg), "quality 60 re-encodes")
            try expect(TestFile.size(again) < TestFile.size(jpg), "quality 60 is smaller than the q95 source")
        }

        // MARK: Quality

        for (fmt, req) in [("jpeg", [String]()), ("heic", ["native.imageio.write.heic"]), ("avif", ["native.imageio.write.avif"])] {
            t("\(fmt.uppercased()) quality is monotonic: lower quality gives a smaller file and a lower PSNR", proves: fmt == "jpeg" ? ["image.quality.bytes"] : [], requires: req) {
                let fx = TestFixtures(label: "imgq"); defer { fx.cleanup() }
                let src = try ImgMetrics.photo(fx, "photo.png")
                var sizes: [Int64] = [], psnrs: [Double] = []
                for q in [30, 60, 90] {
                    let out = try await ImgT.convert(src, [K.format: .string(fmt), K.quality: .int(q)])
                    sizes.append(TestFile.size(out)); psnrs.append(try unwrap(ImgMetrics.psnr(src, out)))
                }
                try expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "\(fmt) bytes \(sizes)")
                try expect(psnrs[0] < psnrs[1] && psnrs[1] < psnrs[2], "\(fmt) PSNR \(psnrs)")
            }
        }

        t("WebP quality is monotonic and lossless WebP reproduces the pixels", proves: ["image.lossless.webp"], requires: ["tool.cwebp"]) {
            let fx = TestFixtures(label: "imgwebp"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png")
            var sizes: [Int64] = [], psnrs: [Double] = []
            for q in [30, 60, 90] {
                let out = try await ImgT.convert(src, [K.format: "webp", K.quality: .int(q)])
                try expectEqual(ImgMetrics.sniff(out), "webp")
                sizes.append(TestFile.size(out)); psnrs.append(try unwrap(ImgMetrics.psnr(src, out)))
            }
            try expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "webp bytes \(sizes)")
            try expect(psnrs[0] < psnrs[1] && psnrs[1] < psnrs[2], "webp PSNR \(psnrs)")
            let lossless = try await ImgT.convert(src, [K.format: "webp", K.lossless: true])
            try expect(ImgMetrics.identical(src, lossless), "lossless WebP is bit exact")
        }

        t("WebP keeps transparency") {
            let fx = TestFixtures(label: "imgwebpa"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "alpha.png", width: 200, height: 100, alpha: true)
            let out = try await ImgT.convert(src, [K.format: "webp"])
            let px = try unwrap(ImgT.pixel(out, 0.9, 0.5), "pixel")
            try expect(px.a < 10, "transparent area stays transparent, alpha \(px.a)")
            let kept = try unwrap(ImgT.pixel(out, 0.2, 0.5))
            try expect(kept.a > 240, "opaque area stays opaque")
        }

        // MARK: Fit to size

        t("fit to file size: the JPEG is not above the limit and uses most of it", proves: ["image.targetKB.size"]) {
            let fx = TestFixtures(label: "imgfit"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 1200, height: 900)
            let full = try await ImgT.convert(src, [K.format: "jpeg", K.quality: 95])
            let limit = Int(TestFile.size(full) / 1024 / 3)
            let out = try await ImgT.convert(src, [K.format: "jpeg", K.targetKB: .int(limit)])
            let size = TestFile.size(out)
            try expect(size <= Int64(limit) * 1024, "\(size) bytes above the \(limit) KB limit")
            try expect(Double(size) >= Double(limit) * 1024 * 0.80, "only \(size) of \(limit * 1024) bytes used")
            try expectEqual(ImgMetrics.sniff(out), "jpeg")
        }

        t("fit to file size works for HEIC and WebP too", proves: ["image.targetKB.size"], requires: ["native.imageio.write.heic"]) {
            let fx = TestFixtures(label: "imgfit3"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 1200, height: 900, noise: 6)
            for fmt in ["heic", "webp"] {
                if fmt == "webp", !Capabilities.shared.has("tool.cwebp") { continue }
                let full = try await ImgT.convert(src, [K.format: .string(fmt), K.quality: 95])
                let limit = Int(TestFile.size(full) / 1024 * 6 / 10)
                let out = try await ImgT.convert(src, [K.format: .string(fmt), K.targetKB: .int(limit)])
                let size = TestFile.size(out)
                try expect(size <= Int64(limit) * 1024, "\(fmt): \(size) bytes above the \(limit) KB limit")
                try expect(Double(size) >= Double(limit) * 1024 * 0.75, "\(fmt): only \(size) of \(limit * 1024) bytes used")
                try expectEqual(ImgMetrics.sniff(out), fmt)
            }
        }

        t("fit to file size with an unreachable limit says so instead of writing a file over it") {
            let fx = TestFixtures(label: "imgfit2"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 600, height: 400)
            var failed = false
            do { _ = try await ImgT.convert(src, [K.format: "jpeg", K.targetKB: 1]) } catch { failed = true }
            let leftovers = TestFile.partials(in: fx.root)
            try expect(leftovers.isEmpty, "no partial files: \(leftovers)")
            if !failed {
                let outs = ((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []).filter { $0.hasSuffix(".jpg") }
                try expect(outs.allSatisfy { TestFile.size(fx.url($0)) <= 1024 }, "a result must respect the limit")
            }
        }

        // MARK: Container options

        t("progressive JPEG writes an SOF2 marker, baseline writes SOF0/1", proves: ["image.jpeg.sof2"]) {
            let fx = TestFixtures(label: "imgprog"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 320, height: 240)
            let prog = try await ImgT.convert(src, [K.format: "jpeg", K.progressive: true])
            let base = try await ImgT.convert(src, [K.format: "jpeg", K.progressive: false])
            try expectEqual(ImgT.jpegFrame(prog)?.marker, 0xC2, "progressive")
            try expect([0xC0, 0xC1].contains(ImgT.jpegFrame(base)?.marker ?? 0), "baseline marker \(String(describing: ImgT.jpegFrame(base)?.marker))")
        }

        t("JPEG colour detail: 4:2:0 by default, 4:4:4 with ffmpeg", proves: ["image.jpeg.sampling"]) {
            let fx = TestFixtures(label: "imgsamp"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 320, height: 240)
            let std = try await ImgT.convert(src, [K.format: "jpeg", K.subsampling: "420"])
            let comps = try unwrap(ImgT.jpegFrame(std)?.components, "SOF")
            try expectEqual(comps.count, 3)
            try expect(comps[0].h == 2 && comps[0].v == 2 && comps[1].h == 1 && comps[1].v == 1, "4:2:0 sampling \(comps)")
            guard Capabilities.shared.has("tool.ffmpeg") else { return }
            let full = try await ImgT.convert(src, [K.format: "jpeg", K.subsampling: "444"])
            let c2 = try unwrap(ImgT.jpegFrame(full)?.components, "SOF")
            try expect(c2.allSatisfy { $0.h == c2[0].h && $0.v == c2[0].v }, "4:4:4: every component has the same sampling factor, got \(c2)")
            try expectEqual(ImgMetrics.sniff(full), "jpeg")
            let psnr = try unwrap(ImgMetrics.psnr(src, full))
            try expect(psnr >= 33, "4:4:4 PSNR \(psnr)")
        }

        t("interlaced PNG sets the Adam7 flag", proves: ["image.png.interlace"]) {
            let fx = TestFixtures(label: "imgint"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.jpg", width: 200, height: 150)
            let plain = try await ImgT.convert(src, [K.format: "png", K.pngInterlace: false])
            let inter = try await ImgT.convert(src, [K.format: "png", K.pngInterlace: true])
            try expectEqual(ImgT.pngHeader(plain)?.interlace, 0)
            try expectEqual(ImgT.pngHeader(inter)?.interlace, 1)
            try expect(ImgMetrics.identical(plain, inter), "interlacing does not change pixels")
        }

        t("PNG palette makes an indexed PNG that is much smaller and still looks the same", proves: ["image.png.palette"]) {
            let fx = TestFixtures(label: "imgpal"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png")
            let full = try await ImgT.convert(src, [K.format: "png", K.pngPalette: false])
            let pal = try await ImgT.convert(src, [K.format: "png", K.pngPalette: true])
            try expectEqual(ImgT.pngHeader(full)?.colorType, 2, "truecolour")
            try expectEqual(ImgT.pngHeader(pal)?.colorType, 3, "indexed")
            try expect(TestFile.size(pal) < TestFile.size(full) * 6 / 10, "palette \(TestFile.size(pal)) vs \(TestFile.size(full))")
            let psnr = try unwrap(ImgMetrics.psnr(src, pal))
            try expect(psnr >= 28, "palette PSNR \(psnr)")
            // Translucent pictures are left in full colour.
            let a = try ImgMetrics.photo(fx, "alpha.png", width: 200, height: 100, alpha: true)
            let keep = try await ImgT.convert(a, [K.format: "png", K.pngPalette: true])
            try expectEqual(ImgT.pngHeader(keep)?.colorType, 6, "RGBA kept")
        }

        t("PNG palette of flat graphics is exact", proves: ["image.png.palette"]) {
            let fx = TestFixtures(label: "imgpal2"); defer { fx.cleanup() }
            let src = try fx.png("flat.png", width: 120, height: 90, pattern: .quadrants)
            let pal = try await ImgT.convert(src, [K.format: "png", K.pngPalette: true])
            try expectEqual(ImgT.pngHeader(pal)?.colorType, 3)
            try expect(ImgMetrics.identical(src, pal), "four flat colours survive exactly")
        }

        t("TIFF compression is recorded and lossless for every mode", proves: ["image.tiff.compression"]) {
            let fx = TestFixtures(label: "imgtiff"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 240, height: 180)
            let expected = ["none": 1, "lzw": 5, "deflate": 8, "packbits": 32773]
            var sizes: [String: Int64] = [:]
            for (mode, tag) in expected {
                let out = try await ImgT.convert(src, [K.format: "tiff", K.tiffCompression: .string(mode)])
                let found = ImgT.dict(out, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFCompression] as? Int
                try expectEqual(found, tag, "TIFF compression tag for \(mode)")
                try expect(ImgMetrics.identical(src, out), "\(mode) is lossless")
                sizes[mode] = TestFile.size(out)
            }
            try expect(sizes["lzw"]! < sizes["none"]!, "LZW is smaller than uncompressed: \(sizes)")
            try expect(sizes["deflate"]! < sizes["none"]!, "Deflate is smaller than uncompressed: \(sizes)")
        }

        t("ICO holds one picture per requested size, at most 256 px", proves: ["image.ico.sizes"]) {
            let fx = TestFixtures(label: "imgico"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "big.png", width: 1000, height: 600)
            let std = try await ImgT.convert(src, [K.format: "ico"])
            try expectEqual(ImgMetrics.sniff(std), "ico")
            try expectEqual(icoSizes(std), [256, 128, 64, 48, 32, 16])
            let custom = try await ImgT.convert(src, [K.format: "ico", K.icoSizes: "48, 16"])
            try expectEqual(icoSizes(custom), [48, 16])
            // A wide picture is fitted into the square and centred on transparency; the middle keeps the picture.
            let largest = try unwrap(ImgT.pixel(std, 0.5, 0.5))
            try expect(largest.a > 250, "centre is opaque")
            let corner = try unwrap(ImgT.pixel(std, 0.5, 0.02))
            try expect(corner.a < 5, "the letterbox above the wide picture is transparent")
        }

        t("ICO sizes text with junk falls back to the standard set") {
            try expectEqual(ImageEncodeParams.parseSizes("abc"), [256, 128, 64, 48, 32, 16])
            try expectEqual(ImageEncodeParams.parseSizes("16 32,32; 999 0 64"), [64, 32, 16])
        }

        t("transparency: JPEG, BMP and PDF fill it with the chosen background, PNG and TIFF keep it", proves: ["image.alpha.pixel"]) {
            let fx = TestFixtures(label: "imgalpha"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "alpha.png", width: 200, height: 100, alpha: true)
            let white = try await ImgT.convert(src, [K.format: "jpeg"])
            let px = try unwrap(ImgT.pixel(white, 0.9, 0.5))
            try expect(TestImage.close(px, .white, tolerance: 6), "default background is white, got \(px)")
            let red = try await ImgT.convert(src, [K.format: "jpeg", K.alphaBackground: "#FF0000"])
            try expect(TestImage.close(try unwrap(ImgT.pixel(red, 0.9, 0.5)), .red, tolerance: 12), "red background")
            let bmp = try await ImgT.convert(src, [K.format: "bmp", K.alphaBackground: "#00FF00"])
            try expect(TestImage.close(try unwrap(ImgT.pixel(bmp, 0.9, 0.5)), RGBA(r: 0, g: 255, b: 0), tolerance: 6), "BMP background")
            let pdf = try await ImgT.convert(src, [K.format: "pdf", K.alphaBackground: "#0000FF"])
            let pp = try unwrap(ImgT.pdfPixel(pdf, 0.9, 0.5))
            try expect(TestImage.close(pp, .blue, tolerance: 12), "PDF background \(pp)")
            for fmt in ["png", "tiff"] {
                let kept = try await ImgT.convert(src, [K.format: .string(fmt), K.alphaBackground: "#FF0000"])
                try expect(try unwrap(ImgT.pixel(kept, 0.9, 0.5)).a < 10, "\(fmt) keeps the hole")
                try expect(try unwrap(ImgT.pixel(kept, 0.2, 0.5)).a > 245, "\(fmt) keeps the picture opaque")
            }
        }
    }

    /// Frame sizes (longest side, descending) of an ICO read with ImageIO.
    static func icoSizes(_ url: URL) -> [Int] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).map { i in
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            return max((p?[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        }.sorted(by: >)
    }
}
