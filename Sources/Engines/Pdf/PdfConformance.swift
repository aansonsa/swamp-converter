import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit

/// "conformance.pdf": every PDF operation is run on a realistic fixture (a photograph-like picture with noise plus Latin and Cyrillic text, never flat colours)
/// and its output is judged by readers that share no code with the writer: magic bytes, `file(1)`, the low-level `CGPDFDocument` object model, Core Graphics'
/// own page interpreter and, when installed, Poppler (`pdfinfo`, `pdftotext`, `pdfimages`). An operation without a case fails
/// `every PDF operation has a conformance case`, so a new operation cannot ship without an oracle.
///
/// Documented defaults under test: pictures from PDFs use 300 dpi (print quality), JPEG quality 90 (visually lossless, about 3x smaller than PNG on photographs),
/// "Optimize" re-saves pictures as JPEG limited to screen resolution (standard level). The reference compressors (qpdf, Ghostscript) are not installed on this
/// Mac, so the size claim is measured against the file itself: a Flate-picture PDF must come out more than 3x smaller with the picture still similar (PSNR).
enum PdfConformance {
    struct Case {
        var op: String
        var requires: [String] = []
        var run: @MainActor (TestFixtures) async throws -> Void
    }

    static func pageText(_ n: Int) -> String { "Swamp 12345 Привет мир стр\(n)" }
    static func expectedWords(pages: Int) -> [String] { (1...pages).flatMap { PdfOracle.words("Page \($0) " + pageText($0)) } }

    // MARK: Fixtures

    /// Pages of a 300x400 pt sheet: "Page N" and a Latin + Cyrillic line at the top, a noisy gradient picture below (Flate, as Core Graphics writes it).
    @discardableResult
    static func fixture(_ fx: TestFixtures, _ name: String, pages: Int = 2, pixels: Int = 900, picture: Bool = true) throws -> URL {
        let u = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        let big = CTFontCreateUIFontForLanguage(.system, 18, nil)!, small = CTFontCreateUIFontForLanguage(.system, 11, nil)!
        for p in 1...pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
            if picture { ctx.draw(PdfFixtures.photoImage(side: pixels, seed: UInt64(p + 20)), in: CGRect(x: 30, y: 40, width: 240, height: 240)) }
            for (text, font, y) in [("Page \(p)", big, 360.0), (pageText(p), small, 330.0)] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
                ctx.textPosition = CGPoint(x: 30, y: y)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return u
    }

    /// Text of a page (1-based) from Poppler when it is installed, else from PDFKit.
    static func text(_ url: URL, page: Int? = nil, password: String? = nil) -> String {
        if let t = PdfOracle.pdftotext(url, page: page, password: password) { return t }
        let doc = PDFDocument(url: url)
        if let password { _ = doc?.unlock(withPassword: password) }
        if let page { return doc?.page(at: page - 1)?.string ?? "" }
        return doc?.string ?? ""
    }

    static func notAnInputCopy(_ src: URL, _ out: URL) throws {
        try expect(out.standardizedFileURL != src.standardizedFileURL, "wrote a new file")
        try expect(!PdfOracle.identical(src, out), "the output is not a byte copy of the input")
        try expect(TestFile.size(out) > 0, "the output is not empty")
    }

    static func psnr(_ out: CGImage?, _ ref: CGImage?) throws -> Double {
        let a = try unwrap(out, "the output picture decodes"), b = try unwrap(ref, "the reference picture renders")
        try expectEqual(a.width, b.width, "same width"); try expectEqual(a.height, b.height, "same height")
        return PdfTestsOcr.psnr(a, b)
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    // MARK: Table

    static let cases: [Case] = [
        Case(op: "pdf.to.png") { fx in
            let src = try fixture(fx, "src.pdf", pages: 1)
            let out = try unwrap(try await PdfRun.run("pdf.to.png", [src]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "png"); try expect(PdfOracle.mime(out) == "image/png", "file(1): \(PdfOracle.mime(out))")
            try expectEqual(out.pathExtension, "png"); try notAnInputCopy(src, out)
            let img = try unwrap(decode(out))
            try expectEqual(img.width, 1250); try expectEqual(img.height, 1667)      // 300 x 400 pt at 300 dpi
            let p = try psnr(img, PdfOracle.render(src, width: 1250))
            try expect(p >= 30, "PNG matches an independent render: \(p) dB")
            try expectClose(TestImage.info(of: out)?.dpiX ?? 0, 300, tolerance: 1, "DPI tag")
        },
        Case(op: "pdf.to.jpg") { fx in
            let src = try fixture(fx, "src.pdf", pages: 1)
            let out = try unwrap(try await PdfRun.run("pdf.to.jpg", [src]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "jpeg"); try expect(PdfOracle.mime(out) == "image/jpeg", "file(1): \(PdfOracle.mime(out))")
            try expectEqual(out.pathExtension, "jpg"); try notAnInputCopy(src, out)
            let img = try unwrap(decode(out))
            try expectEqual(img.width, 1250)
            let p = try psnr(img, PdfOracle.render(src, width: 1250))
            try expect(p >= 30, "JPEG quality 90 matches an independent render: \(p) dB")
        },
        Case(op: "pdf.to.txt") { fx in
            let src = try fixture(fx, "src.pdf", pages: 3)
            let out = try unwrap(try await PdfRun.run("pdf.to.txt", [src]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "utf8"); try expectEqual(out.pathExtension, "txt"); try notAnInputCopy(src, out)
            try expect(TestFile.magic(out, 3) != [0xEF, 0xBB, 0xBF], "UTF-8 without BOM")
            let body = try String(contentsOf: out, encoding: .utf8)
            try expectEqual(PdfOracle.words(body), expectedWords(pages: 3), "every word of every page, in order")
            try expectEqual(PdfOracle.words(body), PdfOracle.words(text(src)), "the same words as the reader that did not write it")
        },
        Case(op: "pdf.to.md") { fx in
            let src = try fixture(fx, "src.pdf", pages: 2)
            let out = try unwrap(try await PdfRun.run("pdf.to.md", [src]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "utf8"); try expectEqual(out.pathExtension, "md"); try notAnInputCopy(src, out)
            let body = try String(contentsOf: out, encoding: .utf8)
            try expectEqual(PdfOracle.words(body.replacingOccurrences(of: "---", with: " ")), expectedWords(pages: 2))
            try expect(body.contains("\n---\n"), "pages are divided by a rule")
        },
        Case(op: "pdf.to.docx") { fx in try await document(fx, "docx") { zipText in
            try expect(zipText("word/document.xml").contains("Привет"), "document.xml holds the Cyrillic text") } },
        Case(op: "pdf.to.html") { fx in try await document(fx, "html") { _ in } },
        Case(op: "pdf.to.epub") { fx in try await document(fx, "epub") { zipText in
            try expect(zipText("mimetype").hasPrefix("application/epub+zip"), "EPUB mimetype entry") } },
        Case(op: "pdf.to.pptx", requires: ["tool.soffice"]) { fx in
            let src = try fixture(fx, "src.pdf", pages: 2, picture: false)
            let out = try unwrap(try await PdfRun.run("pdf.to.pptx", [src]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "zip"); try notAnInputCopy(src, out)
            let listing = PdfOracle.run("/usr/bin/unzip", ["-Z1", out.path]).out
            try expectEqual(listing.split(separator: "\n").filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.count, 2, "one slide per page")
        },
        Case(op: "pdf.merge") { fx in
            let a = try fixture(fx, "a.pdf", pages: 2), b = try fixture(fx, "b.pdf", pages: 1)
            let out = try unwrap(try await PdfRun.run("pdf.merge", [b, a]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try expect(PdfOracle.mime(out) == "application/pdf", "file(1): \(PdfOracle.mime(out))")
            try expectEqual(out.lastPathComponent, "a (merged).pdf", "named after the first of the SORTED files")
            try expect(!PdfOracle.identical(a, out) && !PdfOracle.identical(b, out), "a new file")
            let f = try unwrap(PdfOracle.facts(out)); try expectEqual(f.pages, 3)
            if let info = PdfOracle.pdfinfo(out) { try expectEqual(info.pages, 3) }
            // sorted order: a.pdf (pages 1, 2) then b.pdf (page 1)
            for (n, source, sourcePage) in [(1, a, 1), (2, a, 2), (3, b, 1)] {
                try expectEqual(PdfOracle.words(text(out, page: n)), PdfOracle.words(text(source, page: sourcePage)), "text of merged page \(n)")
                let p = try psnr(PdfOracle.render(out, page: n, width: 600), PdfOracle.render(source, page: sourcePage, width: 600))
                try expect(p >= 40, "merged page \(n) looks like its source: \(p) dB")
            }
        },
        Case(op: "pdf.split") { fx in
            let src = try fixture(fx, "src.pdf", pages: 3)
            let folder = try unwrap(try await PdfRun.run("pdf.split", [src]).outputs.first)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            try expectEqual(names, ["src - 1.pdf", "src - 2.pdf", "src - 3.pdf"])
            for (i, name) in names.enumerated() {
                let part = folder.appendingPathComponent(name)
                try expectEqual(PdfOracle.sniff(part), "pdf"); try expect(!PdfOracle.identical(part, src))
                try expectEqual(try unwrap(PdfOracle.facts(part)).pages, 1)
                try expectEqual(PdfOracle.words(text(part)), PdfOracle.words(text(src, page: i + 1)), "page \(i + 1) text")
                let p = try psnr(PdfOracle.render(part, width: 600), PdfOracle.render(src, page: i + 1, width: 600))
                try expect(p >= 40, "part \(i + 1) looks like its page: \(p) dB")
            }
        },
        Case(op: "pdf.rotate") { fx in
            let quads = try PdfFixtures.quadrants(fx, "card.pdf", width: 300, height: 100)
            let out = try unwrap(try await PdfRun.run("pdf.rotate", [quads]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try notAnInputCopy(quads, out)
            try expectEqual(try unwrap(PdfOracle.facts(out)).rotations, [90])
            if let info = PdfOracle.pdfinfo(out) { try expectEqual(info.rotation, 90, "Poppler reads /Rotate 90") }
            let img = try unwrap(PdfOracle.render(out, width: 100))
            try expectEqual(img.height, 300, "a quarter turn swaps the sides")
            let corners = [PdfFixtures.pixel(img, 4, 4), PdfFixtures.pixel(img, 95, 4), PdfFixtures.pixel(img, 4, 295), PdfFixtures.pixel(img, 95, 295)]
            for (got, want) in zip(corners, [RGBA.blue, .red, .yellow, .green]) { try expect(TestImage.close(got, want, tolerance: 70), "corner \(got) should be \(want)") }
            let doc = try fixture(fx, "text.pdf", pages: 2)
            let turned = try unwrap(try await PdfRun.run("pdf.rotate", [doc]).outputs.first)
            try expectEqual(PdfOracle.words(text(turned)), expectedWords(pages: 2), "the text is still real text after turning")
        },
        Case(op: "pdf.optimize") { fx in
            let src = try fixture(fx, "heavy.pdf", pages: 2, pixels: 1100)
            let out = try unwrap(try await PdfRun.run("pdf.optimize", [src]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try notAnInputCopy(src, out)
            let before = TestFile.size(src), after = TestFile.size(out)
            try expect(after * 3 < before, "more than 3x smaller: \(before) -> \(after)")
            try expectEqual(try unwrap(PdfOracle.facts(out)).pages, 2)
            try expectEqual(PdfOracle.words(text(out)), expectedWords(pages: 2), "text is untouched and still text")
            if let was = PdfOracle.imageEncodings(src), let now = PdfOracle.imageEncodings(out) {
                try expect(!was.contains("jpeg") && now.allSatisfy { $0 == "jpeg" } && !now.isEmpty, "pictures were really re-encoded: \(was) -> \(now)")
            }
            for page in 1...2 {
                let p = try psnr(PdfOracle.render(out, page: page, width: 600), PdfOracle.render(src, page: page, width: 600))
                try expect(p >= 28, "page \(page) still looks like the original: \(p) dB")
            }
            // the levels are monotonic: stronger compression, smaller file, no better picture
            var sizes: [Int64] = [], quality: [Double] = []
            for level in ["screen", "standard", "high"] {
                let o = try unwrap(try await PdfRun.run("pdf.optimize", [src], [PdfKeys.level: .string(level)]).outputs.first)
                sizes.append(TestFile.size(o)); quality.append(try psnr(PdfOracle.render(o, width: 600), PdfOracle.render(src, width: 600)))
            }
            try expect(sizes[0] <= sizes[1] && sizes[1] <= sizes[2], "bytes grow with the level: \(sizes)")
            try expect(quality[0] <= quality[2] + 0.5, "PSNR does not fall with the level: \(quality)")
            // nothing to gain: never bigger than the input (the original may come back, which is the declared exception)
            let plain = try fixture(fx, "plain.pdf", pages: 2, picture: false)
            let same = try unwrap(try await PdfRun.run("pdf.optimize", [plain]).outputs.first)
            try expect(TestFile.size(same) <= TestFile.size(plain), "not bigger than a PDF that has nothing to shrink")
        },
        Case(op: "pdf.extract") { fx in
            let src = try fixture(fx, "src.pdf", pages: 5)
            let out = try unwrap(try await PdfRun.run("pdf.extract", [src], [PdfKeys.pages: "2-3"]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try notAnInputCopy(src, out)
            let f = try unwrap(PdfOracle.facts(out)); try expectEqual(f.pages, 2)
            try expectEqual(f.sizes, [CGSize(width: 300, height: 400), CGSize(width: 300, height: 400)])
            for (i, n) in [2, 3].enumerated() {
                try expectEqual(PdfOracle.words(text(out, page: i + 1)), PdfOracle.words(text(src, page: n)), "page \(n) text")
                let p = try psnr(PdfOracle.render(out, page: i + 1, width: 600), PdfOracle.render(src, page: n, width: 600))
                try expect(p >= 40, "page \(n) looks the same: \(p) dB")
            }
        },
        Case(op: "pdf.protect") { fx in
            let src = try fixture(fx, "src.pdf", pages: 3, picture: false)
            let out = try unwrap(try await PdfRun.run("pdf.protect", [src], [PdfKeys.openPassword: "open-Pw1", PdfKeys.ownerPassword: "owner-Pw2", PdfKeys.allowCopy: false]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try notAnInputCopy(src, out)
            let raw = try Data(contentsOf: out)
            try expect(raw.range(of: Data("/Encrypt".utf8)) != nil, "the file carries an /Encrypt dictionary")
            let locked = try unwrap(PdfOracle.facts(out))
            try expect(locked.encrypted && !locked.unlocked, "locked without the password")
            try expect(PdfOracle.facts(out, password: "wrong")?.unlocked == false, "a wrong password does not open it")
            try expectEqual(PdfOracle.facts(out, password: "open-Pw1")?.pages, 3)
            if PdfOracle.hasPoppler {
                try expect(PdfOracle.pdfinfo(out) == nil, "Poppler cannot read it without the password")
                let info = try unwrap(PdfOracle.pdfinfo(out, password: "open-Pw1"))
                try expect(info.encrypted && info.raw.contains("copy:no") && info.raw.contains("print:yes"), "permissions as asked: \(info.raw)")
                try expectEqual(PdfOracle.words(text(out, password: "open-Pw1")), PdfOracle.words(text(src)), "the text is intact behind the password")
            }
        },
        Case(op: "pdf.unlock") { fx in
            let plain = try fixture(fx, "plain.pdf", pages: 3, picture: false)
            let locked = fx.url("locked.pdf")
            try PdfProtection.protect(try unwrap(PDFDocument(url: plain)), openPassword: "Pw-4711", ownerPassword: "", allowPrint: true, allowCopy: true, allowEdit: true, to: locked)
            try expect(PdfOracle.facts(locked)?.unlocked == false, "the fixture is locked")
            let out = try unwrap(try await PdfRun.run("pdf.unlock", [locked], [PdfKeys.openPassword: "Pw-4711"]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try notAnInputCopy(locked, out)
            let f = try unwrap(PdfOracle.facts(out)); try expect(!f.encrypted && f.unlocked, "no encryption left"); try expectEqual(f.pages, 3)
            try expectEqual(PdfOracle.words(text(out)), expectedWords(pages: 3), "text readable without any password")
            if let info = PdfOracle.pdfinfo(out) { try expect(!info.encrypted, "Poppler agrees: not encrypted") }
            let p = try psnr(PdfOracle.render(out, width: 600), PdfOracle.render(plain, width: 600))
            try expect(p >= 40, "page 1 unchanged: \(p) dB")
        },
        Case(op: "tools.ocr") { fx in
            if OcrService.supportedIdentifiers().isEmpty { try skipTest("this Mac has no text recogniser") }
            let scan = try PdfFixtures.scan(fx, "scan.pdf", pages: [PdfTestsOcr.english, PdfTestsOcr.russian])
            nonisolated(unsafe) let board = NSPasteboard(name: NSPasteboard.Name("swamp.conf.\(UUID().uuidString)"))
            PdfOCROperation.pasteboard = { board }
            defer { PdfOCROperation.pasteboard = { NSPasteboard.general }; board.releaseGlobally() }
            let out = try unwrap(try await PdfRun.run("tools.ocr", [scan], [PdfKeys.ocrOutput: "searchablePdf"]).outputs.first)
            try expectEqual(PdfOracle.sniff(out), "pdf"); try notAnInputCopy(scan, out)
            try expect(!text(scan).contains("Swamp"), "the scan has no text before")
            let got = PdfOracle.words(text(out))
            for word in PdfOracle.words(PdfTestsOcr.english.joined(separator: " ") + " " + PdfTestsOcr.russian.joined(separator: " ")) {
                try expect(got.contains(word), "recognised word '\(word)' is searchable (found \(got.count) words)")
            }
            for page in 1...2 {
                let p = try psnr(PdfOracle.render(out, page: page, width: 612), PdfOracle.render(scan, page: page, width: 612))
                try expect(p >= 45, "page \(page) looks exactly like the scan: \(p) dB")
            }
            let picture = try PdfTestsOcr.pictureFile(fx, "shot.png", lines: PdfTestsOcr.english)
            let txt = try unwrap(try await PdfRun.run("tools.ocr", [picture]).outputs.first)     // the quick recipe: plain text
            try expectEqual(PdfOracle.sniff(txt), "utf8"); try expectEqual(txt.pathExtension, "txt")
            try expect(PdfTestsOcr.errorRate(try String(contentsOf: txt, encoding: .utf8), PdfTestsOcr.english.joined()) < 0.05, "the words of the picture")
            try expect(board.string(forType: .string)?.contains("Swamp") == true, "and on the clipboard")
        }
    ]

    /// pdf.to.docx / html / epub: the document writer belongs to the documents module; without it the case is skipped, never faked.
    @MainActor
    static func document(_ fx: TestFixtures, _ ext: String, extra: @MainActor ((String) -> String) throws -> Void) async throws {
        let src = try fixture(fx, "src.pdf", pages: 2, picture: false)
        let result: OperationResult
        do { result = try await PdfRun.run("pdf.to.\(ext)", [src]) }
        catch let e as ConversionError { if case .unsupported = e { try skipTest("the documents module's writer is not available yet: \(e.errorDescription ?? "")") }; throw e }
        let out = try unwrap(result.outputs.first)
        try expectEqual(out.pathExtension, ext); try notAnInputCopy(src, out)
        let words = expectedWords(pages: 2)
        func zipText(_ member: String) -> String { PdfOracle.run("/usr/bin/unzip", ["-p", out.path, member]).out }
        if ext == "html" {
            try expectEqual(PdfOracle.sniff(out), "utf8")
            let html = try String(contentsOf: out, encoding: .utf8)
            try expect(html.lowercased().contains("<html") || html.lowercased().contains("<p"), "markup")
            let got = PdfOracle.words(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            for w in words { try expect(got.contains(w), "the word '\(w)' is in the page") }
        } else {
            try expectEqual(PdfOracle.sniff(out), "zip")
            try expect(PdfOracle.run("/usr/bin/unzip", ["-tqq", out.path]).status == 0, "the ZIP container is intact")
            let all = PdfOracle.run("/usr/bin/unzip", ["-p", out.path]).out
            let got = PdfOracle.words(all.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            for w in words { try expect(got.contains(w), "the word '\(w)' is inside the package") }
            try extra(zipText)
        }
    }

    // MARK: Registration

    static func register() {
        let suite = "conformance.pdf"
        for c in cases {
            SelfTestRegistry.shared.register(suite, "\(c.op) is a real conversion judged by independent readers", requires: c.requires, timeout: 300) {
                let fx = TestFixtures(label: "confpdf"); defer { fx.cleanup() }
                try await c.run(fx)
                try expect(TestFile.partials(in: fx.root).isEmpty, "no partial files left")
            }
        }

        SelfTestRegistry.shared.register(suite, "every PDF operation has a conformance case") {
            let ids = Set((PdfCatalog.operations() + PdfCatalog.ocrOperations()).map(\.meta.id))
            let covered = Set(cases.map(\.op))
            try expect(ids.subtracting(covered).isEmpty, "operations without an oracle case: \(ids.subtracting(covered).sorted())")
            try expect(covered.subtracting(ids).isEmpty, "cases for unknown operations: \(covered.subtracting(ids).sorted())")
        }

        SelfTestRegistry.shared.register(suite, "pdf.to.jpg: a lower quality makes a smaller file and a worse picture, a higher DPI a bigger one") {
            let fx = TestFixtures(label: "confq"); defer { fx.cleanup() }
            let src = try fixture(fx, "src.pdf", pages: 1)
            var bytes: [Int64] = [], psnrs: [Double] = []
            for q in [25, 60, 95] {
                let out = try unwrap(try await PdfRun.run("pdf.to.jpg", [src], [PdfKeys.rasterDPI: 144, PdfKeys.rasterQuality: .int(q)]).outputs.first)
                bytes.append(TestFile.size(out)); psnrs.append(try psnr(decode(out), PdfOracle.render(src, width: 600)))
            }
            try expect(bytes[0] < bytes[1] && bytes[1] < bytes[2], "bytes grow with quality: \(bytes)")
            try expect(psnrs[0] < psnrs[1] && psnrs[1] < psnrs[2], "PSNR grows with quality: \(psnrs)")
            var dims: [Int] = []
            for dpi in [72, 144] {
                let out = try unwrap(try await PdfRun.run("pdf.to.png", [src], [PdfKeys.rasterDPI: .int(dpi)]).outputs.first)
                dims.append(decode(out)?.width ?? 0)
            }
            try expectEqual(dims, [300, 600])
        }
    }
}
