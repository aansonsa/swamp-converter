import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Default oracles for picture conversions: a photographic fixture goes in, the output is decoded again and compared pixel by pixel.
// Floors (PSNR / SSIM against the source, both flattened on white) are set from measurements of Apple's own encoders on the same fixture, with margin:
//   JPEG q90 reaches 26 dB on the grainy photo fixture (the 1-pixel chroma stripes cost about 3 dB), WebP q90 and HEIC are in the same range, AVIF a little lower.
// Lossless targets must reproduce every pixel.

extension ConformanceOracles {
    static let imageTargets: Set<String> = ["jpg", "png", "webp", "avif", "tiff", "ico", "bmp", "gif", "heic", "jp2"]
    static let lossyImageTargets: Set<String> = ["jpg", "webp", "avif", "heic", "jp2"]
    /// (PSNR dB, SSIM) floors against the source, both flattened on white. Calibration: sips JPEG q90 and cwebp q90 reach 26.4 / 26.3 dB on the fixture.
    static let imageFloors: [String: (Double, Double)] = ["jpg": (24, 0.90), "webp": (24, 0.90), "avif": (21, 0.85), "heic": (24, 0.90), "jp2": (24, 0.90), "gif": (16, 0.70)]

    static let imageConvert = ConformanceOracle(
        id: "image.convert", priority: 0,
        match: { m in
            m.wheel == .convert && (m.targetFormat.map { imageTargets.contains($0) } ?? false) && (m.inputs?.isDisjoint(with: Formats.imageInputs) == false)
        },
        timeout: 300,
        cases: { meta, fx in
            let target = meta.targetFormat ?? "jpg"
            let base = target == "png" || !(meta.inputs?.contains("png") ?? true) ? "tiff" : "png"
            let ext = (meta.inputs?.contains(base) ?? true) ? base : (meta.inputs?.contains("jpg") == true ? "jpg" : base)
            var cases: [ConformanceCase] = []
            if ext == "png" || ext == "tiff" {
                let photo = ext == "png" ? try fx.photo("photo.png") : try fx.base.writeImage(fx.photoImage(), name: "photo.tiff", type: .tiff)
                let alpha = ext == "png" ? try fx.photo("alpha.png", alpha: true) : try fx.base.writeImage(fx.photoImage(alpha: true), name: "alpha.tiff", type: .tiff)
                cases = [ConformanceCase(label: "photo", inputs: [photo]), ConformanceCase(label: "alpha", inputs: [alpha])]
            } else if let f = try await ConformanceInputs.file(key: ext, fx: fx, name: "photo") {
                cases = [ConformanceCase(label: "photo", inputs: [f])]
            }
            if meta.inputs?.contains("jpg") ?? true, target != "jpg" { cases.append(ConformanceCase(label: "rotated", inputs: [try fx.photoJPEG("rotated.jpg", orientation: 6, gps: true)])) }
            return cases
        },
        verify: { run in try await verifyImageConvert(run) },
        proves: "decodes to the same picture: lossless targets pixel-exact, lossy ones above PSNR/SSIM floors and as good as sips/cwebp at the same size; alpha kept or flattened on white; EXIF orientation applied; quality knob monotonic")

    @MainActor
    static func verifyImageConvert(_ run: ConformanceRun) async throws {
        let target = run.meta.targetFormat ?? ""
        let out = try run.sole()
        let label = run.testCase.label
        guard let src = ImageFidelity.decode(run.input), let got = ImageFidelity.decode(out, largestFrame: true) else { throw run.fail("cannot decode source or output") }
        if target == "ico" { try verifyICO(run, out: out, src: src); return }
        try expectEqual(got.width, src.width, "output width")
        try expectEqual(got.height, src.height, "output height")
        let keepsAlpha: Set<String> = ["png", "webp", "avif", "tiff", "heic", "jp2"]
        if label == "alpha" {
            if keepsAlpha.contains(target) {
                try expect(got.hasTransparency, "the \(target.uppercased()) output lost the transparency of an RGBA source")
                try expect(abs(got.transparentFraction - src.transparentFraction) < 0.02, "transparent area changed: \(src.transparentFraction) -> \(got.transparentFraction)")
                if let ae = ImageFidelity.alphaError(src, got) { try expect(ae <= 3.0, "alpha plane differs by \(ae) levels on average") }
            } else if target == "jpg" || target == "bmp" {
                try expect(!got.hasTransparency, "\(target.uppercased()) cannot carry alpha; it must be flattened on white")
            }
        }
        if label == "rotated" {
            try expect(ImageFidelity.orientationTag(out).map { $0 == 1 } ?? true, "the orientation tag must be reset after the pixels were rotated, got \(ImageFidelity.orientationTag(out) ?? 0)")
            try expectEqual(got.width, 480, "a 640x480 sideways JPEG (orientation 6) is 480 wide when shown upright")
        }
        guard let psnr = ImageFidelity.psnr(src, got), let ssim = ImageFidelity.ssim(src, got) else { throw run.fail("cannot compare") }
        let exact: Set<String> = ["png", "tiff", "bmp"]
        if exact.contains(target) {
            let maxDiff = ImageFidelity.maxDifference(src, got) ?? 255
            try expect(maxDiff <= (label == "alpha" ? 1 : 0), "lossless \(target.uppercased()) must keep every pixel, largest channel difference is \(maxDiff) (PSNR \(String(format: "%.1f", psnr)) dB)")
            run.note("pixel-exact (max diff \(maxDiff))")
        } else if let (minPSNR, minSSIM) = imageFloors[target] {
            try expect(psnr >= minPSNR, String(format: "PSNR %.1f dB is below the floor of %.0f dB for %@", psnr, minPSNR, target))
            try expect(ssim >= minSSIM, String(format: "SSIM %.3f is below the floor of %.2f for %@", ssim, minSSIM, target))
            run.note(String(format: "PSNR %.1f dB, SSIM %.3f", psnr, ssim))
        }
        if label == "photo" { try await verifyStudioTwin(run, out: out, got: got) }
        guard label == "photo", lossyImageTargets.contains(target), target != "jp2" else { return }
        try await verifyQualityKnob(run, srcPSNR: psnr)
        try verifyParity(run, out: out, ours: psnr, target: target)
    }

    /// Quick and Studio share one engine: the Studio run with the quick run's resolved options must produce the same picture.
    @MainActor
    private static func verifyStudioTwin(_ run: ConformanceRun, out: URL, got: RasterImage) async throws {
        let twin = try await ConformanceRunner.studioTwin(of: run)
        let o2 = try twin.sole()
        guard let g2 = ImageFidelity.decode(o2, largestFrame: true) else { throw run.fail("cannot decode the Studio result") }
        try expect(g2.width == got.width && g2.height == got.height, "Studio produced \(g2.width)x\(g2.height), Quick \(got.width)x\(got.height) from the same options")
        let p = ImageFidelity.psnr(got, g2) ?? 0
        try expect(p == .infinity, String(format: "Studio and Quick pictures differ for the same options (PSNR %.1f dB)", p))
        run.note(FileHash.sha256(out) == FileHash.sha256(o2) ? "Studio == Quick, byte for byte" : "Studio == Quick, pixel for pixel")
    }

    @MainActor
    private static func verifyQualityKnob(_ run: ConformanceRun, srcPSNR: Double) async throws {
        guard let (f, r) = ConformanceSchema.knob(of: run, names: ["quality"]) else { return }
        let low = r.lowerBound + (r.upperBound - r.lowerBound) * 0.3, high = r.upperBound
        var sizes: [Double] = [], scores: [Double] = []
        for v in [low, high] {
            let again = try await ConformanceRunner.execute(run.operation, run.testCase, with: [f.key: .double(v.rounded())], fx: run.fx)
            let o = try again.sole()
            guard let src = ImageFidelity.decode(again.input), let got = ImageFidelity.decode(o), let p = ImageFidelity.psnr(src, got) else { throw run.fail("cannot measure the quality sweep") }
            sizes.append(Double(TestFile.size(o))); scores.append(p)
        }
        try expect(sizes[0] < sizes[1], "lowering \(f.key) must shrink the file: \(Int(sizes[0])) B at \(Int(low)) vs \(Int(sizes[1])) B at \(Int(high))")
        try expect(scores[0] < scores[1], String(format: "lowering %@ must lower the PSNR: %.1f dB at %d vs %.1f dB at %d", f.key, scores[0], Int(low), scores[1], Int(high)))
        run.note("\(f.key) \(Int(low))->\(Int(high)): \(Int(sizes[0]))->\(Int(sizes[1])) B, \(String(format: "%.1f->%.1f", scores[0], scores[1])) dB")
    }

    private static func verifyParity(_ run: ConformanceRun, out: URL, ours: Double, target: String) throws {
        guard let src = ImageFidelity.decode(run.input) else { return }
        let dir = AppPaths.makeTempDirectory(purpose: "ref")
        defer { AppPaths.removeTemp(dir) }
        let render: (Int) -> URL? = target == "jpg" ? { ReferenceParity.sipsJPEG(run.input, quality: $0, into: dir) } : (target == "webp" ? { ReferenceParity.cwebp(run.input, quality: $0, into: dir) } : { _ in nil })
        guard target == "jpg" || (target == "webp" && ExternalProbe.has(.cwebp)) else { return }
        // The quick recipe may flatten or resize nothing, so the reference sees the same pixels as ours.
        let v = ReferenceParity.compare(oursBytes: TestFile.size(out), oursMetric: ours, range: 20...100, tolerance: 0.5, render: render) { url in
            ImageFidelity.decode(url).flatMap { ImageFidelity.psnr(src, $0) }
        }
        if let v {
            try expect(v.passes, "worse than the reference encoder at the same size: " + v.summary)
            run.note("parity: " + v.summary)
        }
    }

    private static func verifyICO(_ run: ConformanceRun, out: URL, src: RasterImage) throws {
        let sizes = ImageFidelity.frameSizes(out)
        try expect(sizes.count >= 3, "an icon should embed several sizes, found \(sizes.map { "\($0.width)x\($0.height)" })")
        try expect(sizes.allSatisfy { $0.width <= 256 && $0.height <= 256 }, "ICO frames are limited to 256 px: \(sizes)")
        guard let frame = ImageFidelity.decode(out, largestFrame: true) else { throw run.fail("cannot decode the largest icon frame") }
        let srcScaled: RasterImage?
        if abs(Double(frame.width) / Double(frame.height) - Double(src.width) / Double(src.height)) < 0.03 {
            srcScaled = ImageFidelity.scaled(src, width: frame.width, height: frame.height)
        } else {
            let k = Double(min(frame.width, frame.height)) / Double(max(src.width, src.height))
            srcScaled = ImageFidelity.scaled(src, width: max(1, Int(Double(src.width) * k)), height: max(1, Int(Double(src.height) * k))).map { ImageFidelity.padded($0, width: frame.width, height: frame.height) }
        }
        guard let s = srcScaled, let p = ImageFidelity.psnr(s, frame) else { throw run.fail("cannot compare the icon with the source") }
        try expect(p >= 20, String(format: "the largest icon frame differs from the scaled source (PSNR %.1f dB)", p))
        run.note("\(sizes.count) frames up to \(frame.width)x\(frame.height), PSNR \(String(format: "%.1f", p)) dB")
    }

    // MARK: Image to PDF

    static let imageToPDF = ConformanceOracle(
        id: "image.to-pdf", priority: 0,
        match: { $0.wheel == .convert && $0.targetFormat == "pdf" && ($0.inputs?.isDisjoint(with: Formats.imageInputs) == false) },
        cases: { _, fx in [ConformanceCase(label: "photo", inputs: [try fx.photo("photo.png")]), ConformanceCase(label: "alpha", inputs: [try fx.photo("alpha.png", alpha: true)])] },
        verify: { run in
            let out = try run.sole()
            guard let facts = PDFReader.facts(out) else { throw run.fail("PDFKit cannot read the output") }
            try expectEqual(facts.pageCount, 1, "one image makes one page")
            guard let src = ImageFidelity.decode(run.input), let page = ImageFidelity.rasterize(pdf: out, width: src.width) else { throw run.fail("cannot render the page") }
            let scaled = ImageFidelity.scaled(page, width: src.width, height: src.height) ?? page
            guard let psnr = ImageFidelity.psnr(src, scaled), let ssim = ImageFidelity.ssim(src, scaled) else { throw run.fail("cannot compare page and image") }
            let ratioSrc = Double(src.width) / Double(src.height), ratioPage = Double(page.width) / Double(page.height)
            try expect(abs(ratioSrc - ratioPage) < 0.02, "the page shape \(ratioPage) differs from the picture shape \(ratioSrc)")
            try expect(psnr >= 20 && ssim >= 0.80, String(format: "the rendered page differs from the image (PSNR %.1f dB, SSIM %.3f)", psnr, ssim))
            run.note(String(format: "page %.0fx%.0f pt, PSNR %.1f dB, SSIM %.3f", facts.pageSizes[0].width, facts.pageSizes[0].height, psnr, ssim))
        },
        proves: "a one-page PDF whose rendered page shows the picture (shape kept, flattened on white)")
}
