import Foundation
import ImageIO
import CoreGraphics

/// "conformance.image": every catalogue operation is run on a realistic fixture (photo with gradients, shapes, text and noise; never flat colours) and its output
/// is judged by readers that share no code with the writer: magic bytes, ImageIO, `file(1)`, PDFKit and PSNR / exact pixel comparisons. An operation without a case
/// in the table fails `every operation has a conformance case`, so a new operation cannot ship without an oracle.
enum ImageConformance {
    private typealias K = ImageKeys

    /// One case: the operation, the input to run it on, the real format expected, the check of the output content.
    struct Case {
        var op: String
        var input: String                  // fixture name made by `fixtures`
        var sniff: String                  // real format of the output
        var requires: [String] = []
        var check: @MainActor (_ source: URL, _ output: URL, _ fx: TestFixtures) async throws -> Void
    }

    static func register() {
        let suite = "conformance.image"
        for c in cases {
            SelfTestRegistry.shared.register(suite, "\(c.op) really decodes and re-encodes (\(c.sniff)), keeps the content", requires: c.requires, timeout: 180) {
                let fx = TestFixtures(label: "conf"); defer { fx.cleanup() }
                let src = try fixture(c.input, fx)
                let r = try await ImgT.run(c.op, [src], mode: .quick)
                let out = try unwrap(r.outputs.first, "\(c.op) produced no output")
                // 1. The REAL format, by three independent readers, and the extension agrees.
                try expectEqual(ImgMetrics.sniff(out), c.sniff, "magic bytes of \(out.lastPathComponent)")
                let ext = out.pathExtension.lowercased()
                try expect(ext == c.sniff || (c.sniff == "jpeg" && ext == "jpg") || (c.sniff == "tiff" && ext == "tiff"), "extension .\(ext) does not match \(c.sniff)")
                if let type = ImgMetrics.imageIOType(out) { try expect(type.contains(c.sniff == "jpeg" ? "jpeg" : c.sniff) || c.sniff == "heic" || c.sniff == "avif" || c.sniff == "jp2", "ImageIO says \(type)") }
                if c.sniff != "heic" && c.sniff != "avif" { try expect(ImgMetrics.mime(out).contains(c.sniff == "jpeg" ? "jpeg" : c.sniff) || c.sniff == "ico" || c.sniff == "jp2", "file(1) says \(ImgMetrics.mime(out))") }
                // 2. Not a renamed copy.
                try expect(out.standardizedFileURL != src.standardizedFileURL, "wrote a new file")
                try expect((try? Data(contentsOf: out)) != (try? Data(contentsOf: src)), "the output is not byte-identical to the input")
                try expect(TestFile.size(out) > 0, "output is not empty")
                // 3. The content.
                try await c.check(src, out, fx)
                try expect(TestFile.partials(in: fx.root).isEmpty, "no partial files left")
            }
        }

        SelfTestRegistry.shared.register(suite, "every operation has a conformance case") {
            let ids = Set(ImageCatalog.operations().map(\.meta.id))
            let covered = Set(cases.map(\.op)).union(["image.merge.pdf"])
            try expect(ids.subtracting(covered).isEmpty, "operations without an oracle case: \(ids.subtracting(covered).sorted())")
            try expect(covered.subtracting(ids).isEmpty, "cases for unknown operations: \(covered.subtracting(ids).sorted())")
        }

        SelfTestRegistry.shared.register(suite, "image.merge.pdf writes a real multi-page PDF whose pages show the pictures") {
            let fx = TestFixtures(label: "confmerge"); defer { fx.cleanup() }
            let a = try ImgMetrics.photo(fx, "p1.png", width: 400, height: 300), b = try ImgMetrics.photo(fx, "p2.jpg", width: 300, height: 400, seed: 9)
            let r = try await ImgT.run("image.merge.pdf", [a, b], mode: .quick)
            let out = try unwrap(r.outputs.first)
            try expectEqual(ImgMetrics.sniff(out), "pdf"); try expect(ImgMetrics.mime(out).contains("pdf"), "file(1): \(ImgMetrics.mime(out))")
            try expectEqual(PDFProbe.pageCount(out), 2)
            for (i, src) in [a, b].enumerated() {
                let page = try unwrap(PDFProbe.render(out, page: i))
                let psnr = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(src)), try unwrap(ImgMetrics.pixels(page))), "page \(i) has the picture's size")
                try expect(psnr >= 30, "page \(i) PSNR \(psnr)")
            }
        }
    }

    // MARK: Fixtures

    static func fixture(_ name: String, _ fx: TestFixtures) throws -> URL {
        switch name {
        case "photo.png": return try ImgMetrics.photo(fx, "photo.png", width: 640, height: 480)
        case "photo.jpg": return try ImgMetrics.photo(fx, "photo.jpg", width: 640, height: 480)
        case "big.jpg": return try ImgMetrics.photo(fx, "big.jpg", width: 2400, height: 1800)
        case "square.png": return try ImgMetrics.photo(fx, "square.png", width: 512, height: 512)
        case "quadrants.png": return try fx.png("quadrants.png", width: 80, height: 40, pattern: .quadrants)
        case "wide.png": return try ImgMetrics.photo(fx, "wide.png", width: 600, height: 400)
        case "tagged.jpg": return try ImageColourTests.taggedJPEG(fx, "tagged.jpg", width: 400, height: 300)
        default: throw TestFailure(message: "unknown fixture \(name)", file: #fileID, line: #line)
        }
    }

    private static func fidelity(_ minPSNR: Double) -> @MainActor (URL, URL, TestFixtures) async throws -> Void {
        { src, out, _ in
            let psnr = try unwrap(ImgMetrics.psnr(src, out), "output decodes at the source size")
            try expect(psnr >= minPSNR, "PSNR \(psnr) dB below \(minPSNR)")
        }
    }

    private static func scaledFidelity(_ w: Int, _ h: Int, _ minPSNR: Double) -> @MainActor (URL, URL, TestFixtures) async throws -> Void {
        { src, out, _ in
            try expect(ImgT.size(out) == (w, h), "size \(ImgT.size(out)), expected \(w)x\(h)")
            let psnr = try unwrap(ImgMetrics.psnrScaled(source: src, output: out))
            try expect(psnr >= minPSNR, "scaled PSNR \(psnr) dB below \(minPSNR)")
        }
    }

    private static func quadrantCheck(_ key: String, size: (Int, Int)) -> @MainActor (URL, URL, TestFixtures) async throws -> Void {
        { _, out, _ in
            try expect(ImgT.size(out) == size, "size \(ImgT.size(out))")
            try expect(ImgT.isQuadrants(out, ImageGeometryTests.q[key]!), "\(key): \(ImgT.describe(out))")
        }
    }

    // MARK: The table

    static let cases: [Case] = [
        Case(op: "image.to.jpg", input: "photo.png", sniff: "jpeg", check: fidelity(33)),
        Case(op: "image.to.png", input: "photo.jpg", sniff: "png") { src, out, _ in
            try expect(ImgMetrics.identical(src, out), "PNG of a JPEG reproduces the decoded JPEG exactly")
        },
        Case(op: "image.to.webp", input: "photo.png", sniff: "webp", requires: ["tool.cwebp"], check: fidelity(33)),
        Case(op: "image.to.avif", input: "photo.png", sniff: "avif", requires: ["native.imageio.write.avif"], check: fidelity(28)),
        Case(op: "image.to.heic", input: "photo.png", sniff: "heic", requires: ["native.imageio.write.heic"], check: fidelity(31)),
        Case(op: "image.to.tiff", input: "photo.jpg", sniff: "tiff") { src, out, _ in
            try expect(ImgMetrics.identical(src, out), "TIFF is lossless")
        },
        Case(op: "image.to.ico", input: "square.png", sniff: "ico") { _, out, _ in
            try expectEqual(ImageFormatTests.icoSizes(out), [256, 128, 64, 48, 32, 16])
            let big = try unwrap(ImgT.pixel(out, 0.5, 0.5)); try expect(big.a == 255, "opaque picture")
        },
        Case(op: "image.to.pdf", input: "photo.png", sniff: "pdf") { src, out, _ in
            try expectEqual(PDFProbe.pageCount(out), 1)
            let page = try unwrap(PDFProbe.render(out))
            let psnr = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(src)), try unwrap(ImgMetrics.pixels(page))), "page has the picture's size")
            try expect(psnr >= 30, "PDF page PSNR \(psnr)")
        },
        Case(op: "image.compress", input: "photo.jpg", sniff: "jpeg") { src, out, _ in
            try expect(TestFile.size(out) < TestFile.size(src), "smaller: \(TestFile.size(out)) vs \(TestFile.size(src))")
            let psnr = try unwrap(ImgMetrics.psnr(src, out)); try expect(psnr >= 30, "PSNR \(psnr)")
        },
        Case(op: "image.half", input: "photo.jpg", sniff: "jpeg", check: scaledFidelity(320, 240, 33)),
        Case(op: "image.max1920", input: "big.jpg", sniff: "jpeg", check: scaledFidelity(1920, 1440, 33)),
        Case(op: "image.rotate.right", input: "quadrants.png", sniff: "png", check: quadrantCheck("rot90", size: (40, 80))),
        Case(op: "image.rotate.left", input: "quadrants.png", sniff: "png", check: quadrantCheck("rot270", size: (40, 80))),
        Case(op: "image.flip", input: "quadrants.png", sniff: "png", check: quadrantCheck("flipH", size: (80, 40))),
        Case(op: "image.square", input: "wide.png", sniff: "png") { src, out, _ in
            try expect(ImgT.size(out) == (400, 400), "square \(ImgT.size(out))")
            // The middle 400 columns of the source are kept, pixel for pixel.
            let a = try unwrap(ImgMetrics.pixels(src)), b = try unwrap(ImgMetrics.pixels(out))
            var worst = 0
            for y in stride(from: 0, to: 400, by: 7) { for x in stride(from: 0, to: 400, by: 7) {
                let p = a.rgb(x + 100, y), q = b.rgb(x, y)
                worst = max(worst, abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2))
            } }
            try expect(worst <= 2, "centre crop differs by up to \(worst)")
        },
        Case(op: "image.grayscale", input: "photo.png", sniff: "png") { src, out, _ in
            let a = try unwrap(ImgMetrics.pixels(src)), b = try unwrap(ImgMetrics.pixels(out))
            try expect(a.width == b.width && a.height == b.height, "same size")
            var sum = 0.0
            for i in stride(from: 0, to: a.data.count, by: 4) {
                let y = 0.2126 * Double(a.data[i]) + 0.7152 * Double(a.data[i + 1]) + 0.0722 * Double(a.data[i + 2])
                sum += abs(y - Double(b.data[i + 1]))
                try expect(abs(Int(b.data[i]) - Int(b.data[i + 1])) <= 1, "neutral pixel")
            }
            try expect(sum / Double(a.data.count / 4) <= 2.5, "luminance error \(sum / Double(a.data.count / 4))")
        },
        Case(op: "image.strip", input: "tagged.jpg", sniff: "jpeg") { src, out, _ in
            try expect(ImgT.hasGPS(src) && ImgT.make(src) != nil, "the fixture is tagged")
            try expect(!ImgT.hasGPS(out) && ImgT.make(out) == nil && ImageColourTests.exifDate(out) == nil, "stripped")
            let psnr = try unwrap(ImgMetrics.psnr(src, out)); try expect(psnr >= 33, "pixels re-encoded at q90, PSNR \(psnr)")
        }
    ]
}
