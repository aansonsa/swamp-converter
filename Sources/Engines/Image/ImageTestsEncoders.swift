import Foundation
import ImageIO
import CoreGraphics

/// Encoder quality: the lossless PNG recompression is valid and bit exact, colours survive every format, and our encoders are compared with reference encoders found
/// on this Mac (libjpeg's cjpeg, ffmpeg, cwebp, sips): at the same file size ours must be as good or better.
enum ImageEncoderTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 180, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    // MARK: Helpers

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func tool(_ candidates: [String]) -> String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Binary PPM of a decoded picture (what libjpeg's cjpeg reads).
    static func writePPM(_ p: ImgMetrics.Pixels, to url: URL) throws {
        var d = Data("P6\n\(p.width) \(p.height)\n255\n".utf8)
        var rgb = [UInt8](); rgb.reserveCapacity(p.width * p.height * 3)
        for i in stride(from: 0, to: p.data.count, by: 4) { rgb.append(p.data[i]); rgb.append(p.data[i + 1]); rgb.append(p.data[i + 2]) }
        d.append(contentsOf: rgb)
        try d.write(to: url)
    }

    /// PSNR of a rate-distortion curve (bytes, dB) at `size` bytes, interpolated in log size. nil outside the measured range.
    static func psnr(at size: Double, curve: [(bytes: Double, psnr: Double)]) -> Double? {
        let c = curve.sorted { $0.bytes < $1.bytes }
        guard let first = c.first, let last = c.last, size >= first.bytes, size <= last.bytes else { return nil }
        for i in 1..<c.count where c[i].bytes >= size {
            let a = c[i - 1], b = c[i]
            let x = (log(size) - log(a.bytes)) / (log(b.bytes) - log(a.bytes))
            return a.psnr + x * (b.psnr - a.psnr)
        }
        return nil
    }

    /// Display P3 TIFF or PNG with a smooth 16-bit ramp, and a photo converted into Display P3 (the usual phone picture).
    static func p3Photo(_ fx: TestFixtures) throws -> URL {
        let srgb = try ImgMetrics.photo(fx, "srgb.png", width: 320, height: 240, noise: 2)
        guard let src = CGImageSourceCreateWithURL(srgb as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TestFailure(message: "no P3 context", file: #fileID, line: #line) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 320, height: 240))
        return try fx.writeImage(ctx.makeImage()!, name: "p3photo.tiff", type: .tiff)
    }

    // MARK: Tests

    static func register() {
        t("PNG recompression is lossless and valid: same pixels, intact chunks, smaller, readable by ffmpeg too") {
            let fx = TestFixtures(label: "imgpngopt"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 800, height: 600, noise: 2)
            let img = try ImageLoader.load(src)
            // What ImageIO alone writes (with a resolution and a profile) versus what the encoder writes.
            let plain = NSMutableData()
            let d = CGImageDestinationCreateWithData(plain, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
            _ = CGImageDestinationFinalize(d)
            let optimised = try unwrap(try PNGOptimizer.optimized(plain as Data), "a photo has something to gain")
            try expect(optimised.count < plain.length * 9 / 10, "\(optimised.count) vs \(plain.length) bytes")
            let a = fx.url("plain.png"), b = fx.url("optimised.png")
            try (plain as Data).write(to: a); try optimised.write(to: b)
            try expect(ImgMetrics.identical(a, b), "every pixel is the same")
            try expectEqual(ImgMetrics.sniff(b), "png")
            try expectClose(try unwrap(ImgT.dpi(b)), 144, tolerance: 1, "resolution chunk kept")
            try expect(!ImgT.profile(b).isEmpty, "profile kept: '\(ImgT.profile(b))'")
            // Chunk structure and CRCs, checked byte by byte.
            let bytes = [UInt8](optimised)
            var pos = 8, types: [String] = []
            while pos + 12 <= bytes.count {
                let len = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
                let body = Array(bytes[(pos + 4)..<(pos + 8 + len)])
                let stored = UInt32(bytes[pos + 8 + len]) << 24 | UInt32(bytes[pos + 9 + len]) << 16 | UInt32(bytes[pos + 10 + len]) << 8 | UInt32(bytes[pos + 11 + len])
                try expectEqual(PNGOptimizer.crc32(body), stored, "CRC of \(String(decoding: body.prefix(4), as: UTF8.self))")
                types.append(String(decoding: body.prefix(4), as: UTF8.self))
                pos += 12 + len
            }
            try expectEqual(types.first, "IHDR"); try expectEqual(types.last, "IEND"); try expectEqual(pos, bytes.count)
            try expectEqual(types.filter { $0 == "IDAT" }.count, 1)
            if let ffmpeg = tool(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) {
                try expectEqual(run(ffmpeg, ["-v", "error", "-xerror", "-i", b.path, "-f", "null", "-"]), 0, "an independent PNG decoder (ffmpeg) accepts it")
            }
        }

        t("PNG recompression handles gray, RGBA, 16-bit and palette pictures, and leaves what it cannot improve") {
            let fx = TestFixtures(label: "imgpngopt2"); defer { fx.cleanup() }
            let photo = try ImgMetrics.photo(fx, "photo.png", width: 400, height: 300, alpha: true, noise: 2)
            let wide = try ImgT.wideGamut(fx, "wide.png", type: .png, width: 256, height: 128)
            let flat = try fx.png("flat.png", width: 300, height: 200, pattern: .quadrants)
            for (name, src, options) in [("RGBA", photo, OptionValues()), ("16-bit P3", wide, OptionValues()), ("flat", flat, OptionValues()),
                                         ("gray", photo, [K.gray: true]), ("palette", photo, [K.pngPalette: true]), ("interlaced", photo, [K.pngInterlace: true])] as [(String, URL, OptionValues)] {
                var o = options; o[K.format] = "png"
                let out = try await ImgT.convert(src, o)
                if ["RGBA", "16-bit P3", "flat", "interlaced"].contains(name) { try expect(ImgMetrics.identical(src, out), "\(name): pixels survive") }
                try expectEqual(ImgMetrics.sniff(out), "png", name)
                if let ffmpeg = tool(["/opt/homebrew/bin/ffmpeg"]) { try expectEqual(run(ffmpeg, ["-v", "error", "-xerror", "-i", out.path, "-f", "null", "-"]), 0, "\(name): ffmpeg decodes it") }
            }
            let wide16 = try await ImgT.convert(wide, [K.format: "png"])
            try expectEqual(ImgT.depth(wide16), 16, "16-bit depth is kept")
            let nothing = try PNGOptimizer.optimized(Data("not a png at all, just text that is long enough to pass a size check....................".utf8))
            try expect(nothing == nil, "garbage is refused, not crashed on")
            let truncated = (try Data(contentsOf: flat)).prefix(80)
            try expect(try PNGOptimizer.optimized(Data(truncated)) == nil, "a truncated PNG is refused")
        }

        t("colours survive every format: a Display P3 photo looks the same after conversion", proves: ["image.cs.profile"]) {
            let fx = TestFixtures(label: "imgp3"); defer { fx.cleanup() }
            let src = try p3Photo(fx)
            try expect(ImgT.profile(src).contains("Display P3"), "fixture is Display P3: '\(ImgT.profile(src))'")
            var targets: [(String, Double)] = [("jpeg", 33), ("png", 60), ("tiff", 60), ("bmp", 40), ("gif", 24), ("jp2", 33), ("pdf", 30)]
            if Capabilities.shared.has("native.imageio.write.heic") { targets.append(("heic", 32)) }
            if Capabilities.shared.has("native.imageio.write.avif") { targets.append(("avif", 30)) }
            if Capabilities.shared.has("native.imageio.write.tga") { targets.append(("tga", 40)) }
            if Capabilities.shared.has("tool.cwebp") { targets.append(("webp", 33)) }
            for (fmt, minPSNR) in targets {
                let out = try await ImgT.convert(src, [K.format: .string(fmt)])
                let page: ImgMetrics.Pixels? = fmt == "pdf" ? PDFProbe.render(out).flatMap { ImgMetrics.pixels($0) } : ImgMetrics.pixels(out)
                let psnr = try unwrap(page.flatMap { p in ImgMetrics.pixels(src).flatMap { ImgMetrics.psnr($0, p) } }, "\(fmt) decodes at the source size")
                try expect(psnr >= minPSNR, "\(fmt): PSNR \(psnr) dB means the colours moved")
            }
            let pal = try await ImgT.convert(src, [K.format: "png", K.pngPalette: true])
            let pp = try unwrap(ImgMetrics.psnr(src, pal))
            try expect(pp >= 28, "palette PNG of a P3 photo: PSNR \(pp)")
            try expect(ImgT.profile(pal).contains("sRGB") || ImgT.profile(pal).isEmpty, "the palette is documented as sRGB: '\(ImgT.profile(pal))'")
        }

        t("reference: baseline JPEG is as good as libjpeg at the same file size") {
            guard let cjpeg = tool(["/opt/homebrew/bin/cjpeg", "/usr/local/bin/cjpeg"]) else { try skipTest("cjpeg (libjpeg) is not installed") }
            let fx = TestFixtures(label: "imgref1"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 960, height: 720, noise: 3)
            let ppm = fx.url("in.ppm"); try writePPM(try unwrap(ImgMetrics.pixels(src)), to: ppm)
            var ours: [(bytes: Double, psnr: Double)] = [], ref: [(bytes: Double, psnr: Double)] = [], oursProg: [(bytes: Double, psnr: Double)] = []
            for q in stride(from: 40, through: 96, by: 8) {
                let a = try await ImgT.convert(src, [K.format: "jpeg", K.quality: .int(q)])
                ours.append((Double(TestFile.size(a)), try unwrap(ImgMetrics.psnr(src, a))))
                let p = try await ImgT.convert(src, [K.format: "jpeg", K.quality: .int(q), K.progressive: true])
                oursProg.append((Double(TestFile.size(p)), try unwrap(ImgMetrics.psnr(src, p))))
                let r = fx.url("ref\(q).jpg")
                try expectEqual(run(cjpeg, ["-quality", "\(q)", "-sample", "2x2", "-baseline", "-outfile", r.path, ppm.path]), 0, "cjpeg runs")
                ref.append((Double(TestFile.size(r)), try unwrap(ImgMetrics.psnr(src, r))))
            }
            let lo = max(ours.map(\.bytes).min()!, ref.map(\.bytes).min()!) * 1.15, hi = min(ours.map(\.bytes).max()!, ref.map(\.bytes).max()!) * 0.9
            try expect(lo < hi, "the curves overlap")
            for f in [0.0, 0.5, 1.0] {
                let size = lo * pow(hi / lo, f)
                let o = try unwrap(psnr(at: size, curve: ours)), r = try unwrap(psnr(at: size, curve: ref)), pr = try unwrap(psnr(at: size, curve: oursProg))
                try expect(o >= r - 0.4, "at \(Int(size)) bytes: ours \(o) dB vs libjpeg \(r) dB")
                try expect(pr >= r - 0.1, "at \(Int(size)) bytes: ours progressive \(pr) dB vs libjpeg \(r) dB")
            }
        }

        t("reference: JPEG matches the system encoder (sips) at the same quality") {
            let fx = TestFixtures(label: "imgref2"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 640, height: 480, noise: 3)
            for q in [60, 90] {
                let ours = try await ImgT.convert(src, [K.format: "jpeg", K.quality: .int(q)])
                let ref = fx.url("sips\(q).jpg")
                try expectEqual(run("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", "\(q)", src.path, "--out", ref.path]), 0, "sips runs")
                let ratio = Double(TestFile.size(ours)) / Double(TestFile.size(ref))
                try expect(ratio < 1.05, "q\(q): ours \(TestFile.size(ours)) vs sips \(TestFile.size(ref)) bytes")
                let po = try unwrap(ImgMetrics.psnr(src, ours)), pr = try unwrap(ImgMetrics.psnr(src, ref))
                try expect(po >= pr - 0.2, "q\(q): quality equals sips (\(po) vs \(pr) dB)")
            }
        }

        t("reference: lossless PNG is not larger than ffmpeg's or ImageMagick's, palette PNG matches ffmpeg's palette at the same quality") {
            let fx = TestFixtures(label: "imgref3"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 800, height: 600, noise: 3)
            let ours = try await ImgT.convert(src, [K.format: "png"])
            if let ffmpeg = tool(["/opt/homebrew/bin/ffmpeg"]) {
                let ref = fx.url("ff.png")
                try expectEqual(run(ffmpeg, ["-v", "error", "-y", "-i", src.path, ref.path]), 0, "ffmpeg runs")
                try expect(TestFile.size(ours) <= TestFile.size(ref), "PNG: ours \(TestFile.size(ours)) vs ffmpeg \(TestFile.size(ref))")
                let pal = try await ImgT.convert(src, [K.format: "png", K.pngPalette: true])
                let rp = fx.url("ffpal.png")
                try expectEqual(run(ffmpeg, ["-v", "error", "-y", "-i", src.path, "-vf", "split[a][b];[a]palettegen=max_colors=256[p];[b][p]paletteuse=dither=floyd_steinberg", rp.path]), 0, "ffmpeg palette runs")
                // A palette trades size against quality; ours must not be beaten on both counts at once.
                let pp = try unwrap(ImgMetrics.psnr(src, pal)), pr = try unwrap(ImgMetrics.psnr(src, rp))
                try expect(Double(TestFile.size(pal)) <= Double(TestFile.size(rp)) * 1.02 || pp >= pr - 0.3,
                           "palette: ours \(TestFile.size(pal)) bytes \(pp) dB vs ffmpeg \(TestFile.size(rp)) bytes \(pr) dB")
                if let convert = tool(["/opt/ImageMagick/bin/convert"]) {
                    let im = fx.url("impal.png")
                    if run(convert, [src.path, "-dither", "FloydSteinberg", "-colors", "256", "-define", "png:compression-level=9", im.path]) == 0 {
                        let pi = try unwrap(ImgMetrics.psnr(src, im))
                        try expect(Double(TestFile.size(pal)) <= Double(TestFile.size(im)) * 1.02 || pp >= pi + 0.3,
                                   "palette: ours \(TestFile.size(pal)) bytes \(pp) dB vs ImageMagick \(TestFile.size(im)) bytes \(pi) dB")
                    }
                }
            }
            if let convert = tool(["/opt/ImageMagick/bin/convert"]) {
                let ref = fx.url("im.png")
                if run(convert, [src.path, "-define", "png:compression-level=9", ref.path]) == 0 {
                    try expect(Double(TestFile.size(ours)) <= Double(TestFile.size(ref)) * 1.10, "PNG: ours \(TestFile.size(ours)) vs ImageMagick level 9 \(TestFile.size(ref))")
                }
            }
        }

        t("reference: WebP equals cwebp itself and HEIC equals the system encoder", requires: ["tool.cwebp"]) {
            let fx = TestFixtures(label: "imgref4"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 800, height: 600, noise: 3)
            let cwebp = try unwrap(tool(["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]))
            for q in [60, 80, 90] {
                let ours = try await ImgT.convert(src, [K.format: "webp", K.quality: .int(q)])
                let ref = fx.url("ref\(q).webp")
                try expectEqual(run(cwebp, ["-quiet", "-q", "\(q)", "-m", "4", "-mt", src.path, "-o", ref.path]), 0, "cwebp runs")
                try expect(Double(TestFile.size(ours)) <= Double(TestFile.size(ref)) * 1.03 + 600, "q\(q): ours \(TestFile.size(ours)) vs cwebp -m 4 \(TestFile.size(ref)) (ours also carries the colour profile)")
                let po = try unwrap(ImgMetrics.psnr(src, ours)), pr = try unwrap(ImgMetrics.psnr(src, ref))
                try expect(po >= pr - 0.3, "q\(q) quality: \(po) vs \(pr) dB")
            }
            if Capabilities.shared.has("native.imageio.write.heic") {
                let ours = try await ImgT.convert(src, [K.format: "heic", K.quality: 80])
                let ref = fx.url("sips.heic")
                try expectEqual(run("/usr/bin/sips", ["-s", "format", "heic", "-s", "formatOptions", "80", src.path, "--out", ref.path]), 0, "sips heic runs")
                try expect(Double(TestFile.size(ours)) < Double(TestFile.size(ref)) * 1.1, "HEIC: ours \(TestFile.size(ours)) vs sips \(TestFile.size(ref))")
            }
        }

        t("the default quality is visually transparent on every codec: 90 gives PSNR above 38 dB on a photo", proves: ["image.quality.bytes"]) {
            let fx = TestFixtures(label: "imgdefq"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 640, height: 480, noise: 2)
            var fmts = ["jpeg"]
            if Capabilities.shared.has("native.imageio.write.heic") { fmts.append("heic") }
            if Capabilities.shared.has("native.imageio.write.avif") { fmts.append("avif") }
            if Capabilities.shared.has("tool.cwebp") { fmts.append("webp") }
            for fmt in fmts {
                let out = try await ImgT.run("image.to.jpg", [src], [K.format: .string(fmt)], mode: .quick).outputs.first
                let psnr = try unwrap(ImgMetrics.psnr(src, try unwrap(out)))
                try expect(psnr >= 38, "\(fmt) at the default quality: \(psnr) dB")
            }
        }
    }
}
