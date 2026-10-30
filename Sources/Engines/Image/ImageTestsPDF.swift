import Foundation
import CoreGraphics
import PDFKit

/// Images to PDF: page count and order, page boxes, fit, margins, quality and background are read back with PDFKit and by rendering the pages.
enum ImagePDFTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    private static func solid(_ fx: TestFixtures, _ name: String, _ c: RGBA, width: Int = 100, height: Int = 50) throws -> URL {
        try fx.png(name, width: width, height: height, pattern: .solid(c))
    }

    private static func merge(_ urls: [URL], _ extra: OptionValues = OptionValues(), rules: OutputRules = OutputRules()) async throws -> URL {
        let r = try await ImgT.run("image.merge.pdf", urls, extra, rules: rules, mode: .studio)
        try expectEqual(r.outputs.count, 1, "one PDF")
        return try unwrap(r.outputs.first)
    }

    static func register() {
        t("merge: one real PDF, one page per picture, named after the first page", proves: ["imgpdf.order.pages"]) {
            let fx = TestFixtures(label: "imgmerge"); defer { fx.cleanup() }
            let p2 = try solid(fx, "p2.png", .red), p10 = try solid(fx, "p10.png", .green), p1 = try fx.jpeg("p1.jpg", width: 100, height: 50, pattern: .solid(.blue))
            let out = try await merge([p2, p10, p1])
            try expectEqual(out.lastPathComponent, "p1.pdf", "named after the first sorted item")
            try expectEqual(ImgMetrics.sniff(out), "pdf")
            try expectEqual(PDFProbe.pageCount(out), 3)
            // Natural order: p1, p2, p10.
            let colours = (0..<3).map { ImgT.pdfPixel(out, page: $0, 0.5, 0.5) }
            try expect(TestImage.close(colours[0], .blue, tolerance: 20) && TestImage.close(colours[1], .red, tolerance: 20) && TestImage.close(colours[2], .green, tolerance: 20),
                       "page order p1 (blue), p2 (red), p10 (green): \(colours)")
            let byName = try await merge([p2, p10, p1], [K.pdfOrder: "name"])
            let c2 = (0..<3).map { ImgT.pdfPixel(byName, page: $0, 0.5, 0.5) }
            try expect(TestImage.close(c2[0], .blue, tolerance: 20) && TestImage.close(c2[1], .green, tolerance: 20) && TestImage.close(c2[2], .red, tolerance: 20),
                       "text order p1, p10, p2: \(c2)")
            let asGiven = try await merge([p2, p10, p1], [K.pdfOrder: "selection"])
            let c3 = (0..<3).map { ImgT.pdfPixel(asGiven, page: $0, 0.5, 0.5) }
            try expect(TestImage.close(c3[0], .red, tolerance: 20) && TestImage.close(c3[2], .blue, tolerance: 20), "selection order keeps the drop order: \(c3)")
            try expectEqual(asGiven.lastPathComponent.hasPrefix("p2"), true, "named after the first page, whatever the order")
        }

        t("merge by date modified orders pages by file time", proves: ["imgpdf.order.pages"]) {
            let fx = TestFixtures(label: "imgmergedate"); defer { fx.cleanup() }
            let a = try solid(fx, "a.png", .red), b = try solid(fx, "b.png", .green)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: a.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: b.path)
            let out = try await merge([a, b], [K.pdfOrder: "date"])
            try expect(TestImage.close(ImgT.pdfPixel(out, page: 0, 0.5, 0.5), .green, tolerance: 20), "older file first")
            try expect(TestImage.close(ImgT.pdfPixel(out, page: 1, 0.5, 0.5), .red, tolerance: 20), "newer file second")
        }

        t("merge: the page is the picture at 72 dpi, or at the chosen resolution", proves: ["imgpdf.mediabox", "imgpdf.mediabox.dpi"]) {
            let fx = TestFixtures(label: "imgmergebox"); defer { fx.cleanup() }
            let a = try solid(fx, "a.png", .red, width: 600, height: 300), b = try solid(fx, "b.png", .green, width: 300, height: 600)
            let out = try await merge([a, b])
            let b0 = try unwrap(ImgT.mediaBox(out, page: 0)), b1 = try unwrap(ImgT.mediaBox(out, page: 1))
            try expect(abs(b0.width - 600) < 1 && abs(b0.height - 300) < 1, "page 1 \(b0)")
            try expect(abs(b1.width - 300) < 1 && abs(b1.height - 600) < 1, "page 2 \(b1)")
            let dpi = try await merge([a, b], [K.dpi: "300"])
            let d0 = try unwrap(ImgT.mediaBox(dpi, page: 0))
            try expect(abs(d0.width - 144) < 1 && abs(d0.height - 72) < 1, "300 dpi page \(d0)")
        }

        t("merge: A4, A5, A3 and Letter pages, portrait or landscape by picture or by choice", proves: ["imgpdf.mediabox", "imgpdf.orientation"]) {
            let fx = TestFixtures(label: "imgmergea4"); defer { fx.cleanup() }
            let land = try solid(fx, "land.png", .red, width: 200, height: 100), port = try solid(fx, "port.png", .green, width: 100, height: 200)
            let sizes: [(String, Double, Double)] = [("a4", 595.276, 841.89), ("a5", 419.528, 595.276), ("a3", 841.89, 1190.551), ("letter", 612, 792)]
            for (name, w, h) in sizes {
                let out = try await merge([land, port], [K.pdfPageSize: .string(name)])
                let p0 = try unwrap(ImgT.mediaBox(out, page: 0)), p1 = try unwrap(ImgT.mediaBox(out, page: 1))
                try expect(abs(p0.width - h) < 1.5 && abs(p0.height - w) < 1.5, "\(name): landscape picture on a landscape page \(p0)")
                try expect(abs(p1.width - w) < 1.5 && abs(p1.height - h) < 1.5, "\(name): portrait picture on a portrait page \(p1)")
            }
            let forced = try await merge([land, port], [K.pdfPageSize: "a4", K.pdfOrientation: "portrait"])
            for i in 0..<2 {
                let b = try unwrap(ImgT.mediaBox(forced, page: i))
                try expect(abs(b.width - 595.276) < 1.5 && abs(b.height - 841.89) < 1.5, "forced portrait page \(i) \(b)")
            }
            let forcedLand = try await merge([land, port], [K.pdfPageSize: "a4", K.pdfOrientation: "landscape"])
            for i in 0..<2 {
                let b = try unwrap(ImgT.mediaBox(forcedLand, page: i))
                try expect(abs(b.width - 841.89) < 1.5 && abs(b.height - 595.276) < 1.5, "forced landscape page \(i) \(b)")
            }
        }

        t("merge: fit inside leaves paper around the picture, fill covers the page content area", proves: ["imgpdf.fit", "imgpdf.margin"]) {
            let fx = TestFixtures(label: "imgmergefit"); defer { fx.cleanup() }
            let wide = try solid(fx, "wide.png", .red, width: 400, height: 100)
            let other = try solid(fx, "other.png", .red, width: 400, height: 100)
            // A4 portrait, no margin: a 4:1 picture fitted inside is a band across the middle (about 149 pt of 842 high).
            let contain = try await merge([wide, other], [K.pdfPageSize: "a4", K.pdfOrientation: "portrait", K.pdfMargin: 0, K.pdfFit: "contain"])
            try expect(TestImage.close(ImgT.pdfPixel(contain, 0.5, 0.5), .red, tolerance: 20), "centre shows the picture")
            try expect(TestImage.close(ImgT.pdfPixel(contain, 0.5, 0.2), .white, tolerance: 8), "paper above the band")
            try expect(TestImage.close(ImgT.pdfPixel(contain, 0.02, 0.5), .red, tolerance: 20), "no margin: the band touches the left edge")
            let cover = try await merge([wide, other], [K.pdfPageSize: "a4", K.pdfOrientation: "portrait", K.pdfMargin: 0, K.pdfFit: "cover"])
            try expect(TestImage.close(ImgT.pdfPixel(cover, 0.5, 0.2), .red, tolerance: 20), "fill covers the whole page")
            try expect(TestImage.close(ImgT.pdfPixel(cover, 0.02, 0.98), .red, tolerance: 20), "fill reaches the corners")
            // Margin: 20 mm = 56.7 pt = 9.5% of the A4 width.
            let margin = try await merge([wide, other], [K.pdfPageSize: "a4", K.pdfOrientation: "portrait", K.pdfMargin: 20, K.pdfFit: "cover"])
            try expect(TestImage.close(ImgT.pdfPixel(margin, 0.03, 0.5), .white, tolerance: 8), "inside the 20 mm margin it is paper")
            try expect(TestImage.close(ImgT.pdfPixel(margin, 0.15, 0.5), .red, tolerance: 20), "beyond the margin it is the picture")
            let m0 = try await merge([wide, other], [K.pdfPageSize: "a4", K.pdfOrientation: "portrait", K.pdfMargin: 0, K.pdfFit: "cover"])
            _ = m0
        }

        t("merge: quality changes the size and the picture, transparency is filled", proves: ["imgpdf.quality.bytes", "imgpdf.alpha.pixel"]) {
            let fx = TestFixtures(label: "imgmergeq"); defer { fx.cleanup() }
            let photo = try ImgMetrics.photo(fx, "a.png", width: 600, height: 400), photo2 = try ImgMetrics.photo(fx, "b.png", width: 600, height: 400, seed: 5)
            let low = try await merge([photo, photo2], [K.quality: 30])
            let high = try await merge([photo, photo2], [K.quality: 95])
            try expect(TestFile.size(low) < TestFile.size(high), "q30 \(TestFile.size(low)) < q95 \(TestFile.size(high))")
            let pl = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(photo)), try unwrap(ImgMetrics.pixels(try unwrap(PDFProbe.render(low))))))
            let ph = try unwrap(ImgMetrics.psnr(try unwrap(ImgMetrics.pixels(photo)), try unwrap(ImgMetrics.pixels(try unwrap(PDFProbe.render(high))))))
            try expect(pl < ph && ph >= 33, "PSNR q30 \(pl) < q95 \(ph)")
            let alpha = try ImgMetrics.photo(fx, "0alpha.png", width: 200, height: 100, alpha: true)
            let filled = try await merge([alpha, photo], [K.alphaBackground: "#FF0000"])
            try expect(TestImage.close(ImgT.pdfPixel(filled, page: 0, 0.9, 0.5), .red, tolerance: 14), "transparent area shows the chosen colour")
            let white = try await merge([alpha, photo])
            try expect(TestImage.close(ImgT.pdfPixel(white, page: 0, 0.9, 0.5), .white, tolerance: 8), "default is white")
        }

        t("merge: a huge picture on a small page is embedded at a printable resolution, not at full size") {
            let fx = TestFixtures(label: "imgmergebig"); defer { fx.cleanup() }
            let big = try ImgT.bigJPEG(fx, "big.jpg", width: 4000, height: 3000)
            let other = try ImgMetrics.photo(fx, "o.png", width: 200, height: 150)
            let out = try await merge([big, other], [K.pdfPageSize: "a5", K.quality: 70])
            try expectEqual(PDFProbe.pageCount(out), 2)
            try expect(TestFile.size(out) < 2_500_000, "A5 pages are small, got \(TestFile.size(out)) bytes")
        }

        t("merge: the PDF is named after the first sorted picture and goes next to it; collisions are numbered") {
            let fx = TestFixtures(label: "imgmergename"); defer { fx.cleanup() }
            let a = try solid(fx, "b-scan.png", .red), b = try solid(fx, "a-scan.png", .green)
            let one = try await merge([a, b])
            let two = try await merge([a, b])
            try expectEqual(one.lastPathComponent, "a-scan.pdf")
            try expectEqual(two.lastPathComponent, "a-scan (2).pdf")
            try expectEqual(one.deletingLastPathComponent().standardizedFileURL.path, fx.root.standardizedFileURL.path)
            try expect(TestFile.partials(in: fx.root).isEmpty, "no partial files")
        }

        t("merge: an unreadable picture fails the whole PDF and leaves no file") {
            let fx = TestFixtures(label: "imgmergebad"); defer { fx.cleanup() }
            let good = try solid(fx, "good.png", .red), bad = try fx.text("bad.png", "not an image")
            _ = try await expectThrows("a broken page must fail the merge") { _ = try await merge([good, bad]) }
            try expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []).sorted(), ["bad.png", "good.png"])
        }
    }
}
