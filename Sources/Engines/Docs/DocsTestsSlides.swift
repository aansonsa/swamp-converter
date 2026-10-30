import Foundation
import PDFKit
import ImageIO

// conformance.slides.*: every slides operation on a hand-made three-slide deck, judged by something other than the code that wrote the result: PDFKit (pages and text), ImageIO
// (picture type, size, ink on the page), the package layout read with unzip (PPTX / ODP) and `file`. They need the real LibreOffice and SKIP without it.

enum DocsSlidesTests {
    static func register() {
        let lo = ["tool.soffice"]

        docTest("conformance.slides.to.pdf: one PDF page per slide, in order, with each slide's text and the deck's page size", requires: lo, timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let deck = try DocsRouteTests.odp(fx)
            let before = try Data(contentsOf: deck)
            let r = try await DocRun.run("slides.to.pdf", [deck], mode: .quick, rules: DocRun.into(out), tools: .shared)
            let pdf = try unwrap(r.outputs.first)
            try expectEqual(pdf.lastPathComponent, "deck.pdf"); try expectEqual(DocOracle.mime(pdf), "application/pdf")
            let doc = try unwrap(PDFDocument(url: pdf))
            try expectEqual(doc.pageCount, 3)
            for i in 0..<3 { try expect(doc.page(at: i)?.string?.contains("Slide \(i + 1) of the swamp deck: Привет \(i + 1)") == true, "slide \(i + 1) text: \(doc.page(at: i)?.string ?? "")") }
            try expect(try Data(contentsOf: pdf) != before, "not a copy of the deck")
            try expectEqual(try Data(contentsOf: deck), before, "the deck is untouched")
            try expect(TestFile.partials(in: out).isEmpty)
        }

        for (id, type, expectedType) in [("png", "PNG", "public.png"), ("jpg", "JPG", "public.jpeg")] {
            docTest("conformance.slides.to.\(id): one \(type) picture per slide in a folder \"name (pages)\", each a real \(type) with the slide on it", requires: lo, timeout: 180) {
                let fx = TestFixtures(); defer { fx.cleanup() }
                let out = try fx.makeDirectory("out")
                let deck = try DocsRouteTests.odp(fx)
                let folder = try unwrap(try await DocRun.run("slides.to.\(id)", [deck], [DocKeys.slideDPI: 96], mode: .quick, rules: DocRun.into(out), tools: .shared).outputs.first)
                try expectEqual(folder.lastPathComponent, "deck (pages)")
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                try expectEqual(names, (1...3).map { "deck - \($0).\(id)" })
                for n in names {
                    let f = folder.appendingPathComponent(n)
                    try expectEqual(TestImage.info(of: f)?.type, expectedType, "\(n) is really a \(type)")
                    let size = try unwrap(TestImage.size(of: f))
                    try expectClose(Double(size.width), 28 / 2.54 * 96, tolerance: 3, "\(n): width at 96 dpi")
                    try expectClose(Double(size.height), 15.75 / 2.54 * 96, tolerance: 3, "\(n): height at 96 dpi")
                    // Ink: the slide's text is dark on white, so the picture is not blank.
                    let src = try unwrap(CGImageSourceCreateWithURL(f as CFURL, nil)); let img = try unwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
                    var dark = 0
                    for y in stride(from: 0, to: img.height, by: 2) { for x in stride(from: 0, to: img.width, by: 2) { let p = PdfRaster.pixel(img, x, y); if Int(p.r) + Int(p.g) + Int(p.b) < 300 { dark += 1 } } }
                    try expect(dark > 80, "\(n): the slide text is drawn (\(dark) dark samples)")
                }
                try expect(TestFile.partials(in: out).isEmpty)
            }
        }

        docTest("conformance.slides.to.pptx: a real PPTX package with a slide part per slide and every slide's text, which opens again", requires: lo, timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let deck = try DocsRouteTests.odp(fx)
            let pptx = try unwrap(try await DocRun.run("slides.to.pptx", [deck], mode: .quick, rules: DocRun.into(out), tools: .shared).outputs.first)
            try expectEqual(DocOracle.mime(pptx), "application/vnd.openxmlformats-officedocument.presentationml.presentation")
            let names = DocOracle.zipNames(pptx)
            try expect(names.contains("[Content_Types].xml") && names.contains("_rels/.rels") && names.contains("ppt/presentation.xml"), "OOXML presentation parts")
            let slides = names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.sorted()
            try expectEqual(slides.count, 3)
            for (i, n) in slides.enumerated() { try expect(DocOracle.zipPart(pptx, n).contains("Slide \(i + 1) of the swamp deck"), "\(n) holds its text") }
            let bad = DocOracle.xmlProblems(in: pptx, fx: fx)
            try expect(bad.isEmpty, "xmllint: \(bad)")
            // The second opinion: LibreOffice itself reads the file it wrote.
            let pdf = try unwrap(try await DocRun.run("slides.to.pdf", [pptx], mode: .quick, rules: DocRun.into(out), tools: .shared).outputs.first)
            try expectEqual(PDFDocument(url: pdf)?.pageCount, 3)
        }

        docTest("conformance.slides.to.odp: a real ODP package (mimetype first and stored) with a page per slide, from a PPTX input too", requires: lo, timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let deck = try DocsRouteTests.odp(fx)
            let pptx = try unwrap(try await DocRun.run("slides.to.pptx", [deck], mode: .quick, rules: DocRun.into(out), tools: .shared).outputs.first)
            let odp = try unwrap(try await DocRun.run("slides.to.odp", [pptx], mode: .quick, rules: DocRun.into(out), tools: .shared).outputs.first)
            try expectEqual(DocOracle.zipNames(odp).first, "mimetype")
            try expectEqual(DocOracle.zipPart(odp, "mimetype"), "application/vnd.oasis.opendocument.presentation")
            let content = DocOracle.zipPart(odp, "content.xml")
            try expectEqual(content.components(separatedBy: "<draw:page ").count - 1, 3, "three pages")
            try expect(content.contains("Slide 2 of the swamp deck"), "the text came through PPTX and back")
            try expect(DocOracle.xmlProblems(in: odp, fx: fx).isEmpty)
            // Same-format hiding: an ODP is not offered ODP on the wheel, but the Studio can still re-save it.
            let op = try DocRun.op("slides.to.odp")
            try expect(!op.appliesTo([FileItem(url: odp, isDirectory: false)]) && op.appliesInStudio([FileItem(url: odp, isDirectory: false)]))
        }
    }
}
