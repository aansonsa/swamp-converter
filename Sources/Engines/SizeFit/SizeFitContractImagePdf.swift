import Foundation
import CoreGraphics
import ImageIO
import PDFKit

// Size contract for pictures and PDFs, read back with ImageIO / PDFKit / `file` (never with the code that wrote them).

enum SizeFitContractImagePdf {
    fileprivate typealias S = FitTestSupport

    static func register() {
        registerImage()
        registerPdf()
        registerFallback()
    }

    // MARK: Image

    private static func registerImage() {
        let t = SelfTestRegistry.shared

        t.register("sizefit", "conformance.fit.image: a 1600x1200 photo into 300 KB becomes a real JPEG of 95-100% of the limit, same picture, and beats sips at the same size") {
            let fx = TestFixtures(label: "fitimg"); defer { fx.cleanup() }
            let src = try S.makePhoto(fx)
            let limit: Int64 = 300_000
            try expect(TestFile.size(src) > limit * 2, "the fixture must be much larger than the limit")
            let run = try await S.run(src, id: "fit.image", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            let size = TestFile.size(out)
            try expect(size <= limit, "result \(size) above \(limit)")
            try expect(Double(size) >= Double(limit) * 0.95, "result \(size) more than 5% under \(limit)")
            try expectEqual(out.pathExtension, "jpg")
            try expectEqual(FitOracle.imageType(out), "public.jpeg")
            let mime = try await FitOracle.mime(out)
            try expectEqual(mime, "image/jpeg")
            try expect(TestFile.magic(out, 3) == [0xFF, 0xD8, 0xFF])
            let dims = try unwrap(TestImage.size(of: out))
            try expect(abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.01, "aspect kept: \(dims)")
            let psnr = try unwrap(FitOracle.imagePSNR(source: src, output: out), "PSNR needs the same size")
            try expect(psnr > 20, "PSNR \(psnr) dB")
            // Reference encoder: sips at the highest quality that stays under OUR size. Ours must not be worse at the same size (full-size result only).
            if dims.width == 1600 {
                let ref = try await S.sipsReference(src, maxBytes: size, in: fx)
                let refPSNR = try unwrap(FitOracle.imagePSNR(source: src, output: ref))
                try expect(psnr >= refPSNR - 0.25, "ours \(psnr) dB is worse than sips \(refPSNR) dB at \(TestFile.size(ref)) bytes")
            }
            try expect(TestFile.partials(in: fx.root).isEmpty && (try fx.root.fitStrayFiles()).isEmpty)
        }

        t.register("sizefit", "conformance.fit.image: a bigger limit gives a bigger file and a higher PSNR; a tiny limit shrinks the picture and says so") {
            let fx = TestFixtures(label: "fitimgmono"); defer { fx.cleanup() }
            let src = try S.makePhoto(fx)
            let small = try unwrap(try await S.run(src, id: "fit.image", extra: S.target(bytes: 200_000)).result.outputs.first)
            let large = try unwrap(try await S.run(src, id: "fit.image", extra: S.target(bytes: 600_000)).result.outputs.first)
            try expect(TestFile.size(small) < TestFile.size(large))
            let a = try unwrap(FitOracle.imagePSNR(source: src, output: small)), b = try unwrap(FitOracle.imagePSNR(source: src, output: large))
            try expect(a < b, "PSNR small \(a) must be below large \(b)")
            // 60 KB of full noise cannot hold 1600x1200 at quality 60: the picture is made smaller, the quality stays reasonable.
            let tiny = try await S.run(src, id: "fit.image", extra: S.target(bytes: 60_000))
            let out = try unwrap(tiny.result.outputs.first)
            try expect(TestFile.size(out) <= 60_000 && Double(TestFile.size(out)) >= 57_000, "tiny result \(TestFile.size(out))")
            let dims = try unwrap(TestImage.size(of: out))
            try expect(dims.width < 1600, "picture must be smaller: \(dims)")
            try expect(abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.02, "aspect kept: \(dims)")
            let note = try unwrap(tiny.result.note)
            try expect(note.en.contains("Reduced to") && note.ru.contains("Уменьшено"), note.en)
        }

        t.register("sizefit", "fit.image: downscaling off fails with a calm message and leaves nothing; a file under the limit is copied with a note") {
            let fx = TestFixtures(label: "fitimgoff"); defer { fx.cleanup() }
            let src = try S.makePhoto(fx)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            var extra = S.target(bytes: 60_000); extra[FitKeys.allowDownscale] = false
            let error = try await expectThrows { _ = try await S.run(src, id: "fit.image", extra: extra) }
            try expect(ConversionError.describe(error).count > 30)
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path)), before)
            let small = try fx.jpeg("small.jpg", width: 200, height: 150, pattern: .noise(seed: 3), quality: 0.8)
            let run = try await S.run(small, id: "fit.image", extra: S.target(bytes: 5_000_000))
            let copy = try unwrap(run.result.outputs.first)
            try expectEqual(TestFile.size(copy), TestFile.size(small)); try expect(run.result.note != nil)
        }

        t.register("sizefit", "fit.image: the EXIF orientation is applied (portrait stays portrait); GPS and camera stay unless 'remove location' is on") {
            let fx = TestFixtures(label: "fitimgmeta"); defer { fx.cleanup() }
            let src = try S.makePhoto(fx, "rot.jpg", width: 1600, height: 1200, gps: true, orientation: 6)
            let limit: Int64 = 400_000
            let kept = try unwrap(try await S.run(src, id: "fit.image", extra: S.target(bytes: limit)).result.outputs.first)
            let dims = try unwrap(TestImage.size(of: kept))
            try expect(dims.height > dims.width, "a rotated photo must come out upright: \(dims)")
            try expect(TestFile.size(kept) <= limit)
            let p = FitOracle.imageProperties(kept)
            try expect(p[kCGImagePropertyGPSDictionary] != nil, "GPS is kept by default")
            try expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "SwampCam", "camera make is kept by default")
            var extra = S.target(bytes: limit); extra[FitKeys.stripMetadata] = true
            let clean = try unwrap(try await S.run(src, id: "fit.image", extra: extra).result.outputs.first)
            let q = FitOracle.imageProperties(clean)
            try expect(q[kCGImagePropertyGPSDictionary] == nil, "GPS must be gone")
            try expect((q[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil, "camera make must be gone")
            try expect(TestFile.size(clean) <= limit)
        }

        t.register("sizefit", "fit.image: PNG with transparency stays PNG with transparency; HEIC and WebP are real when asked") {
            let fx = TestFixtures(label: "fitimgfmt"); defer { fx.cleanup() }
            let png = try fx.png("alpha.png", width: 1200, height: 1200, pattern: .noise(seed: 5), alpha: true)
            let limit: Int64 = 400_000
            try expect(TestFile.size(png) > limit)
            let out = try unwrap(try await S.run(png, id: "fit.image", extra: S.target(bytes: limit)).result.outputs.first)
            try expectEqual(out.pathExtension, "png"); try expectEqual(FitOracle.imageType(out), "public.png")
            try expect(TestFile.size(out) <= limit, "png \(TestFile.size(out))")
            try expect((FitOracle.imageProperties(out)[kCGImagePropertyHasAlpha] as? Bool) == true, "alpha must survive")
            let photo = try S.makePhoto(fx)
            if FitImageIO.canWrite("public.heic") {
                var extra = S.target(bytes: 250_000); extra[FitKeys.imageFormat] = "heic"
                let heic = try unwrap(try await S.run(photo, id: "fit.image", extra: extra).result.outputs.first)
                try expectEqual(FitOracle.imageType(heic), "public.heic"); try expect(TestFile.size(heic) <= 250_000)
            }
            if ToolLocator.shared.has(.cwebp), await imageModuleWritesWebP() {
                var extra = S.target(bytes: 250_000); extra[FitKeys.imageFormat] = "webp"
                let webp = try unwrap(try await S.run(photo, id: "fit.image", extra: extra).result.outputs.first)
                try expectEqual(webp.pathExtension, "webp")
                try expectEqual(TestFile.magicString(webp, 4), "RIFF"); try expect(TestFile.size(webp) <= 250_000)
                let webpMime = try await FitOracle.mime(webp)
                try expectEqual(webpMime, "image/webp")
            }
        }
    }

    /// The image module is a separate engineer's work: while only its skeleton is linked ("not implemented yet") the WebP route cannot be exercised.
    private static func imageModuleWritesWebP() async -> Bool {
        let probe = FitTestSupport.tinyImage()
        do { _ = try await ImageEncoder.encode(probe, format: "webp", options: [ImageKeys.quality: .int(70)]); return true } catch { return false }
    }

    // MARK: PDF

    private static func registerPdf() {
        let t = SelfTestRegistry.shared

        t.register("sizefit", "conformance.fit.pdf: a picture-heavy PDF into 1 MB stays a real PDF with the same pages, size and text, and lands in 95-100% of the limit", timeout: 120) {
            let fx = TestFixtures(label: "fitpdf"); defer { fx.cleanup() }
            let src = try S.makePictureHeavyPDF(fx)
            let limit: Int64 = 1_000_000
            try expect(TestFile.size(src) > limit * 3, "fixture must be much larger than the limit: \(TestFile.size(src))")
            let run = try await S.run(src, id: "fit.pdf", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            let size = TestFile.size(out)
            try expect(size <= limit, "result \(size) above \(limit)")
            try expect(Double(size) >= Double(limit) * 0.95, "result \(size) more than 5% under \(limit)")
            let pdfMime = try await FitOracle.mime(out)
            try expectEqual(pdfMime, "application/pdf")
            let a = try unwrap(FitOracle.pdfFacts(src)), b = try unwrap(FitOracle.pdfFacts(out))
            try expectEqual(b.pages, a.pages)
            try expect(abs(b.size.width - a.size.width) < 0.5 && abs(b.size.height - a.size.height) < 0.5, "page size \(b.size) vs \(a.size)")
            let norm: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            try expectEqual(norm(b.text), norm(a.text), "text must be unchanged")
            try expectEqual(b.title, "Swamp report"); try expectEqual(b.author, "Andris")
            try expect(TestFile.partials(in: fx.root).isEmpty && (try fx.root.fitStrayFiles()).isEmpty)
        }

        t.register("sizefit", "fit.pdf: a limit inside the quality jump gets the sharpest result below it, near-identical pages, and a note that says why it is under the limit", timeout: 120) {
            let fx = ConformanceFixtures(label: "fitjump"); defer { fx.base.cleanup() }
            let src = try fx.richPDF("photos.pdf", pages: 3, withImage: true).url
            let limit: Int64 = 680_000
            try expect(TestFile.size(src) > limit * 2, "the fixture must be much larger than the limit: \(TestFile.size(src))")
            let run = try await S.run(src, id: "fit.pdf", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            let size = TestFile.size(out)
            try expect(size <= limit, "result \(size) above \(limit)")
            let note = try unwrap(run.result.note)
            if Double(size) < Double(limit) * 0.95 {
                try expect(note.en.contains("smaller than the limit") && note.ru.contains("меньше лимита"), "being far under the limit must be explained: \(note.en)")
            }
            for i in 0..<3 {
                let a = try unwrap(ImageFidelity.rasterize(pdf: src, page: i, width: 900)), b = try unwrap(ImageFidelity.rasterize(pdf: out, page: i, width: 900))
                let psnr = try unwrap(ImageFidelity.psnr(a, b))
                try expect(psnr >= ConformanceThresholds.fitPdfNearLosslessPSNR, String(format: "page %d is only %.1f dB from the source", i + 1, psnr))
            }
        }

        t.register("sizefit", "fit.pdf: removing document info drops title and author; a bigger limit keeps more picture quality", timeout: 120) {
            let fx = TestFixtures(label: "fitpdfmeta"); defer { fx.cleanup() }
            let src = try S.makePictureHeavyPDF(fx)
            var extra = S.target(bytes: 1_200_000); extra[FitKeys.stripMetadata] = true
            let clean = try unwrap(try await S.run(src, id: "fit.pdf", extra: extra).result.outputs.first)
            let f = try unwrap(FitOracle.pdfFacts(clean))
            try expect(f.title == nil && f.author == nil, "document info must be gone: \(String(describing: f.title)) \(String(describing: f.author))")
            let small = try unwrap(try await S.run(src, id: "fit.pdf", extra: S.target(bytes: 500_000)).result.outputs.first)
            let large = try unwrap(try await S.run(src, id: "fit.pdf", extra: S.target(bytes: 2_500_000)).result.outputs.first)
            try expect(TestFile.size(small) < TestFile.size(large), "\(TestFile.size(small)) vs \(TestFile.size(large))")
        }

        t.register("sizefit", "fit.pdf: vector pages need 'turn pages into pictures'; with it the result fits and the text stays searchable; without it the message is calm", timeout: 180) {
            let fx = TestFixtures(label: "fitpdfvec"); defer { fx.cleanup() }
            let src = try S.makeVectorHeavyPDF(fx)
            let limit: Int64 = 300_000
            try expect(TestFile.size(src) > limit * 2, "fixture \(TestFile.size(src))")
            var off = S.target(bytes: limit); off[FitKeys.allowDownscale] = false
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            let error = try await expectThrows { _ = try await S.run(src, id: "fit.pdf", extra: off) }
            try expect(ConversionError.describe(error).count > 40)
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path)), before, "nothing may remain after a refusal")
            let run = try await S.run(src, id: "fit.pdf", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            try expect(TestFile.size(out) <= limit, "result \(TestFile.size(out))")
            let f = try unwrap(FitOracle.pdfFacts(out))
            try expectEqual(f.pages, 2)
            try expect(f.text.contains("Vector page 1") && f.text.contains("Vector page 2"), "text must stay searchable: \(f.text.prefix(80))")
            try expect(run.result.note?.en.contains("pictures") == true, "the change must be reported")
            let pdfMime = try await FitOracle.mime(out)
            try expectEqual(pdfMime, "application/pdf")
        }

        t.register("sizefit", "fit.pdf: a PDF under the limit is copied with a note; an encrypted one is refused calmly") {
            let fx = TestFixtures(label: "fitpdfsmall"); defer { fx.cleanup() }
            let small = try fx.pdf("small.pdf", pages: 1)
            let run = try await S.run(small, id: "fit.pdf", extra: S.target(bytes: 5_000_000))
            try expectEqual(TestFile.size(try unwrap(run.result.outputs.first)), TestFile.size(small)); try expect(run.result.note != nil)
            let locked = fx.url("locked.pdf")
            let doc = try unwrap(PDFDocument(url: try S.makePictureHeavyPDF(fx, "big.pdf", pages: 2)))
            try expect(doc.write(to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "user"]))
            let error = try await expectThrows { _ = try await S.run(locked, id: "fit.pdf", extra: S.target(bytes: 100_000)) }
            try expect(ConversionError.describe(error).count > 30)
        }
    }
}

extension SizeFitContractImagePdf {
    static func registerFallback() {
        SelfTestRegistry.shared.register("sizefit", "fit.pdf: without the Quartz filter the PDFKit fallback still returns a valid PDF under the limit with the same pages and text", timeout: 120) {
            let fx = TestFixtures(label: "fitpdffallback"); defer { fx.cleanup() }
            let src = try S.makePictureHeavyPDF(fx)
            PdfQuartzFilter.forceUnavailable = true
            defer { PdfQuartzFilter.forceUnavailable = false }
            let limit: Int64 = 1_500_000
            let run = try await S.run(src, id: "fit.pdf", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            try expect(TestFile.size(out) <= limit, "fallback result \(TestFile.size(out))")
            let a = try unwrap(FitOracle.pdfFacts(src)), b = try unwrap(FitOracle.pdfFacts(out))
            try expectEqual(b.pages, a.pages)
            try expect(b.text.contains("Swamp page 1") && b.text.contains("Привет мир"), "text kept: \(b.text.prefix(60))")
        }
    }
}
