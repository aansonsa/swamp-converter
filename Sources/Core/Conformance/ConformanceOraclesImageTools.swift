import Foundation
import CoreGraphics
import ImageIO

// Oracles for the one-tap picture tools of the catalogue (shrink, rotate, mirror, square, grayscale, strip, compress, merge). Each is judged by what its
// name promises, computed independently on the decoded source: the expected result is built here with plain pixel arithmetic and compared with the output.

extension RasterImage {
    /// 90 degrees clockwise (`clockwise: false` = counter-clockwise).
    func rotated(clockwise: Bool) -> RasterImage {
        var rgb = [UInt8](repeating: 0, count: pixelCount * 3), a = [UInt8](repeating: 255, count: pixelCount)
        for ny in 0..<width { for nx in 0..<height {
            let ox = clockwise ? ny : width - 1 - ny, oy = clockwise ? height - 1 - nx : nx
            let s = oy * width + ox, d = ny * height + nx
            rgb[d * 3] = self.rgb[s * 3]; rgb[d * 3 + 1] = self.rgb[s * 3 + 1]; rgb[d * 3 + 2] = self.rgb[s * 3 + 2]; a[d] = alpha[s]
        } }
        return RasterImage(width: height, height: width, rgb: rgb, alpha: a)
    }

    func mirroredHorizontally() -> RasterImage {
        var rgb = rgb, a = alpha
        for y in 0..<height { for x in 0..<width {
            let s = y * width + (width - 1 - x), d = y * width + x
            rgb[d * 3] = self.rgb[s * 3]; rgb[d * 3 + 1] = self.rgb[s * 3 + 1]; rgb[d * 3 + 2] = self.rgb[s * 3 + 2]; a[d] = alpha[s]
        } }
        return RasterImage(width: width, height: height, rgb: rgb, alpha: a)
    }

    /// Centre crop to the shorter side.
    func centerSquare() -> RasterImage {
        let n = min(width, height), ox = (width - n) / 2, oy = (height - n) / 2
        var rgb = [UInt8](repeating: 0, count: n * n * 3), a = [UInt8](repeating: 255, count: n * n)
        for y in 0..<n { for x in 0..<n {
            let s = (y + oy) * width + x + ox, d = y * n + x
            rgb[d * 3] = self.rgb[s * 3]; rgb[d * 3 + 1] = self.rgb[s * 3 + 1]; rgb[d * 3 + 2] = self.rgb[s * 3 + 2]; a[d] = alpha[s]
        } }
        return RasterImage(width: n, height: n, rgb: rgb, alpha: a)
    }

    /// Rec.709 luminance in all three channels.
    func grayscale709() -> RasterImage {
        var rgb = self.rgb
        for i in 0..<pixelCount {
            let r = Double(self.rgb[i * 3]), g = Double(self.rgb[i * 3 + 1]), b = Double(self.rgb[i * 3 + 2])
            let luma: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let y = UInt8(max(0.0, min(255.0, luma.rounded())))
            rgb[i * 3] = y; rgb[i * 3 + 1] = y; rgb[i * 3 + 2] = y
        }
        return RasterImage(width: width, height: height, rgb: rgb, alpha: alpha)
    }

    /// Largest difference between the three channels of any pixel (0 = pure grey).
    var maxChannelSpread: Int {
        var m = 0
        for i in 0..<pixelCount { let r = Int(rgb[i * 3]), g = Int(rgb[i * 3 + 1]), b = Int(rgb[i * 3 + 2]); m = max(m, max(r, g, b) - min(r, g, b)) }
        return m
    }

    var distinctColours: Int {
        var set = Set<UInt32>()
        for i in 0..<pixelCount { set.insert(UInt32(rgb[i * 3]) << 16 | UInt32(rgb[i * 3 + 1]) << 8 | UInt32(rgb[i * 3 + 2])); if set.count > 70_000 { break } }
        return set.count
    }
}

extension ConformanceOracles {
    @MainActor
    private static func compare(_ run: ConformanceRun, expected: RasterImage, minPSNR: Double, what: String) throws {
        let out = try run.sole()
        guard let got = ImageFidelity.decode(out) else { throw run.fail("cannot decode \(out.lastPathComponent)") }
        try expect(got.width == expected.width && got.height == expected.height, "\(what): the result is \(got.width)x\(got.height), expected \(expected.width)x\(expected.height)")
        guard let p = ImageFidelity.psnr(expected, got) else { throw run.fail("cannot compare") }
        try expect(p >= minPSNR, String(format: "%@: the result differs from the expected picture (PSNR %.1f dB, needs %.0f dB)", what, p, minPSNR))
        run.note(String(format: "%dx%d, PSNR %.1f dB against the expected result", got.width, got.height, p))
    }

    private static func tool(_ id: String, proves: String, cases: @escaping @MainActor (OperationMeta, ConformanceFixtures) async throws -> [ConformanceCase],
                             verify: @escaping @MainActor (ConformanceRun) async throws -> Void) -> ConformanceOracle {
        ConformanceOracle(id: id, priority: 10, match: { $0.id == id }, cases: cases, verify: verify, proves: proves)
    }

    private static let pngCase: @MainActor (OperationMeta, ConformanceFixtures) async throws -> [ConformanceCase] = { _, fx in
        [ConformanceCase(label: "png", inputs: [try fx.photo("sample.png")])]
    }

    static let imageHalf = tool("image.half", proves: "both sides halved, picture equal to a high-quality 50% resample of the source", cases: pngCase) { run in
        guard let src = ImageFidelity.decode(run.input), let half = ImageFidelity.scaled(src, width: src.width / 2, height: src.height / 2), let got = ImageFidelity.decode(try run.sole()) else { throw run.fail("cannot decode") }
        try expect(abs(got.width - half.width) <= 1 && abs(got.height - half.height) <= 1, "expected \(half.width)x\(half.height), got \(got.width)x\(got.height)")
        let aligned = ImageFidelity.scaled(got, width: half.width, height: half.height) ?? got
        let p = ImageFidelity.psnr(half, aligned) ?? 0, s = ImageFidelity.ssim(half, aligned) ?? 0
        try expect(p >= 26 && s >= 0.85, String(format: "the halved picture differs from a 50%% resample (PSNR %.1f dB, SSIM %.3f)", p, s))
        run.note(String(format: "%dx%d, PSNR %.1f dB, SSIM %.3f", got.width, got.height, p, s))
    }

    static let imageMax1920 = tool("image.max1920", proves: "the long side fits 1920 px with the aspect ratio kept, and a smaller picture is never enlarged", cases: { _, fx in
        [ConformanceCase(label: "2400x1600", inputs: [try fx.photo("big.png", width: 2400, height: 1600)]), ConformanceCase(label: "640x480", inputs: [try fx.photo("small.png")])]
    }) { run in
        let out = try run.sole()
        guard let s = ImageFidelity.storedSize(run.input), let g = ImageFidelity.storedSize(out) else { throw run.fail("cannot read the sizes") }
        if max(s.width, s.height) > 1920 {
            try expect(max(g.width, g.height) == 1920, "the long side should be 1920, got \(g.width)x\(g.height)")
            try expect(abs(Double(g.width) / Double(g.height) - Double(s.width) / Double(s.height)) < 0.01, "aspect ratio changed")
            guard let src = ImageFidelity.decode(run.input, maxSide: 800), let got = ImageFidelity.decode(out, maxSide: 800) else { throw run.fail("cannot decode") }
            try expect(src.width == got.width && src.height == got.height, "cannot compare at a reduced size")
            let p = ImageFidelity.psnr(src, got) ?? 0
            try expect(p >= 26, String(format: "picture differs from a resample (PSNR %.1f dB)", p))
            run.note(String(format: "%dx%d, PSNR %.1f dB", g.width, g.height, p))
        } else {
            try expect(g.width == s.width && g.height == s.height, "a picture within 1920 px must keep its size, got \(g.width)x\(g.height)")
        }
    }

    static let imageRotateRight = tool("image.rotate.right", proves: "turned 90 degrees clockwise: every pixel where it belongs", cases: pngCase) { run in
        guard let src = ImageFidelity.decode(run.input) else { throw run.fail("cannot decode") }
        try compare(run, expected: src.rotated(clockwise: true), minPSNR: 45, what: "rotate right")
    }

    static let imageRotateLeft = tool("image.rotate.left", proves: "turned 90 degrees counter-clockwise: every pixel where it belongs", cases: pngCase) { run in
        guard let src = ImageFidelity.decode(run.input) else { throw run.fail("cannot decode") }
        try compare(run, expected: src.rotated(clockwise: false), minPSNR: 45, what: "rotate left")
    }

    static let imageFlip = tool("image.flip", proves: "mirrored left to right, every pixel where it belongs", cases: pngCase) { run in
        guard let src = ImageFidelity.decode(run.input) else { throw run.fail("cannot decode") }
        try compare(run, expected: src.mirroredHorizontally(), minPSNR: 45, what: "mirror")
    }

    static let imageSquare = tool("image.square", proves: "center crop to the shorter side, pixels untouched", cases: pngCase) { run in
        guard let src = ImageFidelity.decode(run.input) else { throw run.fail("cannot decode") }
        try compare(run, expected: src.centerSquare(), minPSNR: 45, what: "square crop")
    }

    static let imageGrayscale = tool("image.grayscale", proves: "no color left (R=G=B) and the luminance is Rec.709 of the source", cases: pngCase) { run in
        guard let src = ImageFidelity.decode(run.input), let got = ImageFidelity.decode(try run.sole()) else { throw run.fail("cannot decode") }
        try expect(got.maxChannelSpread <= 2, "the picture still has color (channel spread \(got.maxChannelSpread))")
        let expected = src.grayscale709()
        try expect(got.width == expected.width && got.height == expected.height, "size changed")
        let p = ImageFidelity.psnr(expected, got) ?? 0
        try expect(p >= 38, String(format: "luminance differs from Rec.709 (PSNR %.1f dB against the expected grey picture)", p))
        run.note(String(format: "spread %d, PSNR %.1f dB", got.maxChannelSpread, p))
    }

    static let imageStrip = tool("image.strip", proves: "GPS, camera and date metadata gone, picture unchanged", cases: { _, fx in
        [ConformanceCase(label: "jpg with GPS", inputs: [try fx.photoJPEG("tagged.jpg", gps: true)])]
    }) { run in
        let before = ImageFidelity.properties(run.input)
        try expect(before[kCGImagePropertyGPSDictionary] != nil, "fixture check: the source carries GPS")
        let out = try run.sole()
        let after = ImageFidelity.properties(out)
        try expect(after[kCGImagePropertyGPSDictionary] == nil, "GPS survived: \(after[kCGImagePropertyGPSDictionary] ?? "")")
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        try expect(tiff?[kCGImagePropertyTIFFMake] == nil && tiff?[kCGImagePropertyTIFFModel] == nil, "camera make / model survived")
        try expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil, "the capture date survived")
        guard let c = ImageFidelity.compare(source: run.input, output: out) else { throw run.fail("cannot compare pictures") }
        try expect(c.psnr >= 30, String(format: "the picture changed (PSNR %.1f dB)", c.psnr))
        run.note("metadata removed; " + c.summary)
    }

    static let imageCompress = tool("image.compress", proves: "smaller than the source, metadata removed, still the same picture", cases: { _, fx in
        [ConformanceCase(label: "png", inputs: [try fx.photo("sample.png")]), ConformanceCase(label: "jpg with GPS", inputs: [try fx.photoJPEG("tagged.jpg", quality: 0.97, gps: true)])]
    }) { run in
        let out = try run.sole()
        let a = TestFile.size(run.input), b = TestFile.size(out)
        try expect(b < a, "compressing made the file larger: \(a) -> \(b) bytes")
        guard let c = ImageFidelity.compare(source: run.input, output: out) else { throw run.fail("cannot compare pictures") }
        try expect(c.psnr >= 22 && c.ssim >= 0.85, "too much damage: " + c.summary)
        let props = ImageFidelity.properties(out)
        try expect(props[kCGImagePropertyGPSDictionary] == nil, "GPS survived compression")
        run.note("\(Util.formatBytes(a)) -> \(Util.formatBytes(b)), " + c.summary)
    }

    static let imageMergePDF = tool("image.merge.pdf", proves: "one PDF page per image, in order, each page showing its picture", cases: { _, fx in
        [ConformanceCase(label: "3 images", inputs: [try fx.photo("p1.png", seed: 1), try fx.photo("p2.png", width: 480, height: 640, seed: 2), try fx.photo("p3.png", seed: 3)])]
    }) { run in
        let out = try run.sole()
        guard let facts = PDFReader.facts(out) else { throw run.fail("PDFKit cannot read the output") }
        try expectEqual(facts.pageCount, 3, "one page per image")
        for (i, input) in run.inputs.enumerated() {
            guard let src = ImageFidelity.decode(input), let page = ImageFidelity.rasterize(pdf: out, page: i, width: src.width) else { throw run.fail("cannot render page \(i + 1)") }
            let aligned = ImageFidelity.scaled(page, width: src.width, height: src.height) ?? page
            let p = ImageFidelity.psnr(src, aligned) ?? 0
            try expect(p >= 20, String(format: "page %d does not show image %d (PSNR %.1f dB)", i + 1, i + 1, p))
        }
        run.note("3 pages in input order")
    }
}
