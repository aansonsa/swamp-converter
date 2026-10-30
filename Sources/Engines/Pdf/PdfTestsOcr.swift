import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Self-tests of text recognition (Vision): the language list, recognition quality on drawn pages, searchable PDFs (text, position, invisibility, rotation),
/// the text outputs, the options (languages, auto-detect, resolution, skip-text, page range, clipboard) and cancellation.
/// Pages are drawn by these tests (Latin and Cyrillic lines at 3x letter size), so the expected words are known exactly.
enum PdfTestsOcr {
    static let english = ["Swamp Converter reads 12345", "The quick brown fox jumps", "over the lazy dog"]
    static let russian = ["Привет мир болото", "Быстрая лиса прыгает", "через ленивую собаку"]

    static func register() {
        registerLanguages()
        registerRecognition()
        registerSearchable()
        registerOutputs()
        registerOptions()
    }

    // MARK: Helpers

    /// Case, accents and spacing are ignored: "Привет" read as "ПРИВЕТ" still counts, "Рига" read without the diacritics still counts.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    static func contains(_ text: String, _ word: String) -> Bool { fold(text).contains(fold(word)) }

    /// Levenshtein distance divided by the length of `expected`.
    static func errorRate(_ got: String, _ expected: String) -> Double {
        let a = Array(fold(got)), b = Array(fold(expected))
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))) }
            prev = cur
        }
        return Double(prev[b.count]) / Double(b.count)
    }

    /// PSNR between two renders of the same size (RGB), in dB; 99 when identical.
    static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        func bytes(_ i: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: i.width * i.height * 4)
            let c = CGContext(data: &px, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            return px
        }
        let x = bytes(a), y = bytes(b)
        var sum = 0.0
        for k in 0..<x.count where k % 4 != 3 { let d = Double(x[k]) - Double(y[k]); sum += d * d }
        let mse = sum / Double(x.count / 4 * 3)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// A picture page with an INVISIBLE text layer that says something else than the picture (to tell recognised text from the page's own text).
    static func pictureWithFakeText(_ fx: TestFixtures, _ name: String, picture: [String], hidden: String) throws -> URL {
        let u = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        ctx.beginPDFPage(nil)
        ctx.draw(PdfFixtures.textImage(picture), in: box)
        ctx.setTextDrawingMode(.invisible)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        ctx.textPosition = CGPoint(x: 40, y: 400)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: hidden, attributes: [.font: font])), ctx)
        ctx.endPDFPage(); ctx.closePDF()
        return u
    }

    /// A picture file of the lines; `orientation` is the EXIF value (6 = the stored pixels are turned a quarter and a viewer turns them back).
    static func pictureFile(_ fx: TestFixtures, _ name: String, lines: [String], dpi: Int? = nil, orientation: Int = 1) throws -> URL {
        var image = PdfFixtures.textImage(lines)
        if orientation == 6 { image = rotated(image, clockwise: false) }    // stored sideways: the viewer applies orientation 6 (90 degrees clockwise)
        let u = fx.url(name)
        guard let dest = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw TestFailure(message: "no PNG writer", file: #fileID, line: #line) }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestFailure(message: "cannot write the PNG", file: #fileID, line: #line) }
        return u
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Core Graphics turns counter-clockwise for positive angles (y points up).
        if clockwise { ctx.translateBy(x: 0, y: CGFloat(w)); ctx.rotate(by: -.pi / 2) } else { ctx.translateBy(x: CGFloat(h), y: 0); ctx.rotate(by: .pi / 2) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Runs `tools.ocr` without touching the person's clipboard.
    @MainActor
    static func ocr(_ files: [URL], _ extra: OptionValues = OptionValues(), mode: RunMode = .quick, log: (@Sendable (String) -> Void)? = nil) async throws -> OperationResult {
        var e = extra
        if e[PdfKeys.ocrClipboard] == nil { e[PdfKeys.ocrClipboard] = false }
        return try await PdfRun.run("tools.ocr", files, e, mode: mode, log: log)
    }

    static func available() async throws {
        if OcrService.supportedIdentifiers().isEmpty { try skipTest("this Mac has no text recogniser") }
    }

    // MARK: Languages

    private static func registerLanguages() {
        pdfTest("OCR offers Russian and English, not Latvian, Lithuanian or Estonian, and says so") {
            try await available()
            let ids = OcrService.supportedLanguages().map(\.id)
            try expect(ids.contains("ru-RU") && ids.contains("en-US"), "ru-RU and en-US are recognisable: \(ids)")
            try expect(ids.count >= 20, "the accurate level reads about 30 languages: \(ids.count)")
            for lost in ["lv-LV", "lt-LT", "et-EE"] { try expect(!ids.contains(lost), "\(lost) is not read by Vision") }
            for (id, name) in OcrService.supportedLanguages().prefix(5) { try expect(!name.isEmpty && name != id, "a display name for \(id)") }
            try expect(Capabilities.shared.has("native.vision.lang.ru-RU") || !Capabilities.shared.has("native.vision.lang.lv-LV"), "capabilities follow the live list")
            PdfCapabilities.register()
            try expect(Capabilities.shared.has("native.vision.lang.ru-RU") && Capabilities.shared.has("native.vision.ocr"), "capability ids exist")
            try expect(!Capabilities.shared.has("native.vision.lang.lv-LV"), "no capability for Latvian")
            let picker = PdfSchemas.ocr(items: []).field(PdfKeys.ocrLanguages)
            try expect(picker != nil, "the schema has the language list")
            if case .tracks(let spec)? = picker?.kind, case .picker(let options)? = spec.columns.first?.kind {
                let codes = options.map(\.value)
                try expect(codes.contains("ru-RU") && codes.contains("en-US"), "the picker offers Russian and English")
                try expect(!codes.contains { $0.hasPrefix("lv") || $0.hasPrefix("lt") || $0.hasPrefix("et") }, "the picker does not pretend to read Latvian")
            } else { throw TestFailure(message: "the language field is not a list of pickers", file: #fileID, line: #line) }
            try expect((picker?.help?.en ?? "").contains("Latvian") && (picker?.help?.ru ?? "").contains("латыш"), "the help names the limit in both languages")
        }

        pdfTest("the default languages follow the system, keep Russian and English, and fall back to English", proves: ["pdf.ocr.langs"]) {
            try expectEqual(OcrService.defaultLanguages(preferred: ["ru-LV", "en-GB"]), ["ru-RU", "en-US"])
            try expectEqual(OcrService.defaultLanguages(preferred: ["lv-LV"]), ["en-US"])
            try expectEqual(OcrService.defaultLanguages(preferred: ["de-DE", "ru-RU"]), ["de-DE", "ru-RU", "en-US"])
            try await available()
            try expectEqual(OcrService.usableLanguages(["xx-XX"]).isEmpty, false)
            try expectEqual(OcrService.usableLanguages(["ru-RU", "lv-LV"]), ["ru-RU"])
            // 300 dpi is the render resolution of recognition whatever the image export uses
            var settings = SettingsData(); settings.quality.pdfDpi = 72
            let s = PdfOcrSettings(options: OptionValues())
            try expectEqual(s.dpi, 300); try expect(settings.quality.pdfDpi == 72)
            try expectEqual(PdfOcrSettings(options: [PdfKeys.ocrDPI: 9999]).dpi, 600)
            try expectEqual(PdfOcrSettings(options: [PdfKeys.ocrLanguages: .rows([["lang": "ru-RU"], ["lang": "en-US"]])]).languages, ["ru-RU", "en-US"])
        }
    }

    // MARK: Recognition

    private static func registerRecognition() {
        pdfTest("Vision reads Latin and Cyrillic lines of a drawn page in reading order, with boxes", timeout: 180) {
            try await available()
            let image = PdfFixtures.textImage(english + russian.map { $0 }, fontSize: 80)
            let r = try await OcrService.recognize(image, languages: ["ru-RU", "en-US"])
            try expect(r.confidence > 0.5, "confidence \(r.confidence)")
            let expected = english + russian
            try expect(r.lines.count >= expected.count - 1 && r.lines.count <= expected.count + 1, "about one row per drawn line: \(r.lines)")
            for (i, line) in expected.enumerated() {
                let got = r.lines.indices.contains(i) ? r.lines[i] : ""
                try expect(errorRate(got, line) <= 0.15, "line \(i + 1) '\(line)' read as '\(got)'")
            }
            // boxes: normalised, bottom-left origin, strictly top-to-bottom order
            let ys = r.observations.map(\.box.midY)
            try expect(ys == ys.sorted(by: >), "rows come top to bottom: \(ys)")
            for o in r.observations { try expect(o.box.minX >= 0 && o.box.maxX <= 1.001 && o.box.minY >= 0 && o.box.maxY <= 1.001, "box inside the page: \(o.box)") }
            // cancelling returns at once
            let task = Task { try await OcrService.recognize(image, languages: ["en-US"]) }
            task.cancel()
            let cancelled = try await expectThrows { _ = try await task.value }
            try expect(cancelled is CancellationError, "cancelled: \(cancelled)")
        }

        pdfTest("recognition quality: under 3 percent errors on a paragraph in English and in Russian", timeout: 180) {
            try await available()
            for (lines, langs) in [(english, ["en-US"]), (russian, ["ru-RU", "en-US"])] {
                let r = try await OcrService.recognize(PdfFixtures.textImage(lines, fontSize: 90), languages: langs)
                let rate = errorRate(r.text, lines.joined())
                try expect(rate < 0.03, "\(langs[0]): \(Int(rate * 100)) percent errors, read '\(r.text)'")
            }
            // Latvian is not supported: the base letters still come out, diacritics may not (spec trap 26)
            let lv = try await OcrService.recognize(PdfFixtures.textImage(["Rīgas jūrmala ir skaista"], fontSize: 90), languages: ["en-US"])
            try expect(errorRate(lv.text, "Rigas jurmala ir skaista") < 0.25, "Latvian base letters survive: \(lv.text)")
        }
    }

    // MARK: Searchable PDF

    private static func registerSearchable() {
        pdfTest("tools.ocr makes a searchable PDF: real text in both languages at the right place, and the page looks exactly as before",
                proves: ["pdf.ocr.out"], timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "scan.pdf", pages: [english, russian])
            try expect(PDFDocument(url: scan)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "the fixture has no text of its own")
            let r = try await ocr([scan], [PdfKeys.ocrOutput: "searchablePdf"], log: nil)
            try expectEqual(r.outputs.map(\.lastPathComponent), ["scan (searchable).pdf"])
            let out = r.outputs[0]
            try expectEqual(Array(TestFile.magic(out, 5)), Array("%PDF-".utf8))
            let doc = try unwrap(PDFDocument(url: out))
            try expectEqual(doc.pageCount, 2)
            let p1 = doc.page(at: 0)?.string ?? "", p2 = doc.page(at: 1)?.string ?? ""
            try expect(contains(p1, "Swamp Converter") && contains(p1, "lazy dog"), "page 1 text: \(p1)")
            try expect(contains(p2, "Привет мир") && contains(p2, "ленивую собаку"), "page 2 text: \(p2)")
            try expect(!contains(p1, "Привет"), "page 1 has no Russian")
            // searching finds the word, and the match sits where the word was drawn: line 2 of 3 on page 1, baseline at 2 * 96 + 1.9 * 96 px from the top (3 px per point)
            let hit = try unwrap(doc.findString("The quick", withOptions: .caseInsensitive).first, "search finds 'The quick'")
            let box = hit.bounds(for: try unwrap(hit.pages.first))
            let expectedMidY = 678.0     // line 2: baseline 2376 - 192 - 182.4 px from the bottom, plus half a letter, over 3 px per point
            try expectClose(Double(box.midY), expectedMidY, tolerance: 14, "the match is on the second line")
            try expectClose(Double(box.minX), 80.0 / 3, tolerance: 8, "and starts at the left margin: \(box)")
            let farHit = try unwrap(doc.findString("brown", withOptions: .caseInsensitive).first)
            try expect(farHit.bounds(for: try unwrap(farHit.pages.first)).minX > box.minX + 60, "later words sit further right")
            // invisible: the pages look the same as the scan
            for i in 0..<2 {
                let before = try PdfRasterizer.renderPage(pdf: scan, pageIndex: i, dpi: 72)
                let after = try PdfRasterizer.renderPage(pdf: out, pageIndex: i, dpi: 72)
                try expectEqual(before.width, after.width)
                try expect(psnr(before, after) > 45, "page \(i + 1) is unchanged: \(psnr(before, after)) dB")
            }
            let size = PdfGeometry.displayedSize(try PdfRun.page(out))
            try expectClose(Double(size.width), 612, tolerance: 0.5)
            // the picture is kept as it was: the file is not the source, and not bloated
            try expect(TestFile.size(out) != TestFile.size(scan) && TestFile.size(out) < TestFile.size(scan) * 3 / 2 + 20_000, "size \(TestFile.size(scan)) -> \(TestFile.size(out))")
            try expect(TestFile.partials(in: fx.root).isEmpty, "nothing is left behind")
        }

        pdfTest("a rotated scan page gets its text where a viewer shows the words", timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            // the picture is stored sideways; /Rotate 90 turns it upright for the viewer
            let doc = PDFDocument()
            let sideways = NSImage(cgImage: rotated(PdfFixtures.textImage(english), clockwise: false), size: NSSize(width: 2376, height: 1836))
            let opts: [PDFPage.ImageInitializationOption: Any] = [.mediaBox: NSValue(rect: NSRect(x: 0, y: 0, width: 792, height: 612)), .compressionQuality: 0.9]
            let page = try unwrap(PDFPage(image: sideways, options: opts))
            page.rotation = 90
            doc.insert(page, at: 0)
            let src = fx.url("sideways.pdf")
            try expect(doc.write(to: src))
            try expectEqual(PdfGeometry.displayedSize(try PdfRun.page(src)).width, 612)
            let r = try await ocr([src], [PdfKeys.ocrOutput: "searchablePdf"])
            let out = try unwrap(PDFDocument(url: r.outputs[0]))
            try expect(contains(out.page(at: 0)?.string ?? "", "quick brown fox"), "text read from the upright page: \(out.page(at: 0)?.string ?? "")")
            try expectEqual(PdfGeometry.displayedSize(try unwrap(out.page(at: 0))).height, 792)
            let hit = try unwrap(out.findString("The quick", withOptions: .caseInsensitive).first, "search finds the words on the turned page")
            let box = hit.bounds(for: try unwrap(hit.pages.first))
            let shown = PdfGeometry.displayedSize(try unwrap(out.page(at: 0)))
            let before = try PdfRasterizer.renderPage(pdf: src, pageIndex: 0, dpi: 72)
            let after = try PdfRasterizer.renderPage(pdf: r.outputs[0], pageIndex: 0, dpi: 72)
            try expect(psnr(before, after) > 40, "the turned page looks the same: \(psnr(before, after)) dB")
            // the page shows the text upright: the second line is near the top left, as on an unturned page
            let centre = CGPoint(x: box.midX, y: box.midY)
            try expect(centre.y > 600 && centre.x < 250, "the match sits where a viewer shows the words: \(box) on \(shown)")
            try expect(box.minX >= 0 && box.maxX <= shown.width + 2 && box.minY >= 0 && box.maxY <= shown.height + 2, "the match lies inside the page: \(box)")
        }

        pdfTest("keepText: pages with their own text are copied as they are, only pictures are recognised",
                proves: ["pdf.ocr.skipText"], timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            // a picture of Russian words whose own (hidden) text says ZZTOP
            let fake = try pictureWithFakeText(fx, "fake.pdf", picture: russian, hidden: "ZZTOP")
            try expect(PdfRun.text(fake).contains("ZZTOP"), "the fixture carries its hidden text: \(PdfRun.text(fake))")
            let kept = try await ocr([fake], [PdfKeys.ocrSkipText: true, PdfKeys.ocrOutput: "searchablePdf"])
            let keptText = PdfRun.text(kept.outputs[0])
            try expect(keptText.contains("ZZTOP") && !contains(keptText, "Привет"), "its own text is used and nothing is recognised: \(keptText)")
            let redone = try await ocr([fake], [PdfKeys.ocrSkipText: false, PdfKeys.ocrOutput: "searchablePdf"])
            let redoneText = PdfRun.text(redone.outputs[0])
            try expect(contains(redoneText, "Привет мир") && !redoneText.contains("ZZTOP"), "the recognised layer replaces the old one: \(redoneText)")
            // a vector text page stays vector and extractable
            let text = try PdfFixtures.text(fx, "vector.pdf", pages: 2)
            let r = try await ocr([text], [PdfKeys.ocrSkipText: true, PdfKeys.ocrOutput: "searchablePdf"])
            try expectEqual(PdfRun.pageCount(r.outputs[0]), 2)
            try expect(PdfRun.text(r.outputs[0]).contains("Swamp 12345 Привет мир стр1") && PdfRun.text(r.outputs[0]).contains("стр2"), "text kept")
            try expect(TestFile.size(r.outputs[0]) < 60_000, "still vector, not pictures: \(TestFile.size(r.outputs[0])) bytes")
            // a mixed file: text page kept, picture page recognised
            let mix = PDFDocument(url: text)!
            let pic = try unwrap(PDFDocument(url: try PdfFixtures.scan(fx, "pic.pdf", pages: [english])))
            mix.insert(try unwrap(pic.page(at: 0)?.copy() as? PDFPage), at: 2)
            let mixURL = fx.url("mixed.pdf")
            try expect(mix.write(to: mixURL))
            let logs = Locked<[String]>([])
            let m = try await ocr([mixURL], [PdfKeys.ocrSkipText: true, PdfKeys.ocrOutput: "searchablePdf"], log: { l in logs.withLock { $0.append(l) } })
            _ = m
            let joined = logs.value.joined(separator: "\n")
            try expect(joined.contains("Page 1 already has text") && joined.contains("Page 2 already has text") && joined.contains("Recognised page 3"), "only page 3 was recognised: \(joined)")
        }
    }

    // MARK: Text outputs

    private static func registerOutputs() {
        pdfTest("tools.ocr writes txt, md and json: the words, the boxes, the page range, and the clipboard",
                proves: ["pdf.ocr.pages", "pdf.ocr.clipboard"], timeout: 300) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "три стр.pdf", pages: [english, russian])
            let txt = try await ocr([scan], [PdfKeys.ocrOutput: "txt"])
            try expectEqual(txt.outputs.map(\.lastPathComponent), ["три стр (text).txt"].map { _ in txt.outputs[0].lastPathComponent })
            try expect(txt.outputs[0].pathExtension == "txt", "extension")
            let body = try String(contentsOf: txt.outputs[0], encoding: .utf8)
            try expect(errorRate(body, (english + russian).joined()) < 0.05, "both pages in the text: \(body)")
            try expect(contains(body, "Swamp Converter") && contains(body, "собаку"), "words of both pages")
            try expect(TestFile.magic(txt.outputs[0], 3) != [0xEF, 0xBB, 0xBF], "no BOM")
            // page range: only the second page
            let second = try await ocr([scan], [PdfKeys.ocrOutput: "txt", PdfKeys.pages: "2"])
            let secondText = try String(contentsOf: second.outputs[0], encoding: .utf8)
            try expect(contains(secondText, "Привет") && !contains(secondText, "Swamp"), "page 2 only: \(secondText)")
            let beyond = try await expectThrows { _ = try await ocr([scan], [PdfKeys.ocrOutput: "txt", PdfKeys.pages: "7"]) }
            try expect(ConversionError.describe(beyond).contains("2"), "mentions the page count: \(beyond)")
            // markdown
            let md = try await ocr([scan], [PdfKeys.ocrOutput: "md"])
            let mdText = try String(contentsOf: md.outputs[0], encoding: .utf8)
            try expectEqual(md.outputs[0].pathExtension, "md")
            try expect(mdText.contains("\n\n---\n\n") && contains(mdText, "lazy dog") && contains(mdText, "болото"), "pages divided by a rule: \(mdText)")
            // json with positions
            let js = try await ocr([scan], [PdfKeys.ocrOutput: "json"])
            let obj = try unwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: js.outputs[0])) as? [String: Any])
            let pages = try unwrap(obj["pages"] as? [[String: Any]])
            try expectEqual(pages.count, 2)
            let lines = try unwrap(pages[0]["lines"] as? [[String: Any]])
            try expect(lines.count >= 3, "lines of page 1: \(lines.count)")
            for l in lines {
                let box = try unwrap(l["box"] as? [String: Double])
                try expect((box["x"] ?? -1) >= 0 && (box["y"] ?? -1) >= 0 && (box["width"] ?? 0) > 0 && (box["x"] ?? 0) + (box["width"] ?? 0) <= 1.001, "box in 0...1: \(box)")
                try expect(!((l["text"] as? String) ?? "").isEmpty)
            }
            try expect(contains(lines.compactMap { $0["text"] as? String }.joined(), "brown fox"), "the text of the lines")
            // the clipboard: used in quick mode, untouched when switched off or for watched folders
            nonisolated(unsafe) let board = NSPasteboard(name: NSPasteboard.Name("swamp.ocr.test.\(UUID().uuidString)"))
            PdfOCROperation.pasteboard = { board }
            defer { PdfOCROperation.pasteboard = { NSPasteboard.general }; board.releaseGlobally() }
            board.clearContents(); board.setString("untouched", forType: .string)
            _ = try await PdfRun.run("tools.ocr", [scan], [PdfKeys.ocrOutput: "txt", PdfKeys.ocrClipboard: false])
            try expectEqual(board.string(forType: .string), "untouched")
            _ = try await PdfRun.run("tools.ocr", [scan], [PdfKeys.ocrOutput: "txt", PdfKeys.ocrClipboard: true], mode: .automatic)
            try expectEqual(board.string(forType: .string), "untouched", "watched folders never take the clipboard")
            let quick = try await PdfRun.run("tools.ocr", [scan], [PdfKeys.ocrOutput: "txt", PdfKeys.ocrClipboard: true])
            try expect(contains(board.string(forType: .string) ?? "", "Привет мир"), "the text is on the clipboard")
            try expect((quick.note?.en ?? "").contains("clipboard") && (quick.note?.ru ?? "").contains("буфер"), "the note says so in both languages")
            // a page without any words: calm message, no empty file
            let blank = try PdfFixtures.scan(fx, "white.pdf", pages: [[]])
            let none = try await expectThrows { _ = try await ocr([blank], [PdfKeys.ocrOutput: "txt"]) }
            try expect(!ConversionError.describe(none).isEmpty, "no text found: \(none)")
            try expect(TestFile.partials(in: fx.root).isEmpty)
        }

        pdfTest("tools.ocr reads pictures: the EXIF turn is applied, a searchable PDF takes the page size from the DPI", timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let flat = try pictureFile(fx, "text.png", lines: english, dpi: 144)
            let r = try await ocr([flat], [PdfKeys.ocrOutput: "txt"])
            try expect(r.outputs[0].lastPathComponent.hasSuffix(".txt") && r.outputs[0].lastPathComponent.hasPrefix("text"), "named after the picture: \(r.outputs[0].lastPathComponent)")
            let text = try String(contentsOf: r.outputs[0], encoding: .utf8)
            try expect(errorRate(text, english.joined()) < 0.05, "read: \(text)")
            let turned = try pictureFile(fx, "turned.png", lines: english, orientation: 6)
            let t = try await ocr([turned], [PdfKeys.ocrOutput: "txt"])
            let tText = try String(contentsOf: t.outputs[0], encoding: .utf8)
            try expect(errorRate(tText, english.joined()) < 0.05, "orientation 6 is applied before recognition: \(tText)")
            let pdf = try await ocr([flat], [PdfKeys.ocrOutput: "searchablePdf"])
            let doc = try unwrap(PDFDocument(url: pdf.outputs[0]))
            try expectEqual(doc.pageCount, 1)
            let size = PdfGeometry.displayedSize(try unwrap(doc.page(at: 0)))
            try expectClose(Double(size.width), 1836 * 72.0 / 144, tolerance: 0.6, "page width from 144 dpi")
            try expect(contains(doc.string ?? "", "lazy dog"), "the picture is searchable: \(doc.string ?? "")")
            let folder = fx.root.appendingPathComponent("dir", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let refused = OperationRegistry()
            refused.register(PdfCatalog.ocrOperations())
            try expect(refused.entries(wheel: .tools, items: FileItem.items([folder])).isEmpty, "folders are not offered")
            // two inputs, one failing: the other still gets its text
            let broken = fx.url("broken.png"); try Data("not a picture".utf8).write(to: broken)
            let both = try await ocr([flat, broken], [PdfKeys.ocrOutput: "txt"])
            try expectEqual(both.outputs.count, 1)
            try expectEqual(both.failures.count, 1)
            try expect(both.failures[0].contains("broken.png"), "the failure names the file: \(both.failures)")
        }
    }

    // MARK: Options

    private static func registerOptions() {
        pdfTest("OCR languages and automatic detection reach the recogniser as chosen, and Russian is read right", proves: ["pdf.ocr.langs", "pdf.ocr.auto"], timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "ru.pdf", pages: [russian])
            let seen = Locked<[OcrRequestInfo]>([])
            OcrService.observeRequests { info in seen.withLock { $0.append(info) } }
            defer { OcrService.observeRequests(nil) }
            func read(_ extra: OptionValues) async throws -> (text: String, info: OcrRequestInfo?) {
                seen.value = []
                var e = extra; e[PdfKeys.ocrOutput] = "txt"
                let r = try await ocr([scan], e)
                return (try String(contentsOf: r.outputs[0], encoding: .utf8), seen.value.last)
            }
            // The language list is a hint to Vision (this macOS reads Cyrillic whatever is listed), so the oracle is what Vision is asked: order, filtering, auto-detect.
            let ru = try await read([PdfKeys.ocrLanguages: .rows([["lang": "ru-RU"]]), PdfKeys.ocrAuto: false])
            try expectEqual(ru.info?.languages, ["ru-RU"]); try expectEqual(ru.info?.autoDetect, false); try expectEqual(ru.info?.accurate, true)
            try expect(errorRate(ru.text, russian.joined()) < 0.05, "Russian listed: \(ru.text)")
            let both = try await read([PdfKeys.ocrLanguages: .rows([["lang": "en-US"], ["lang": "ru-RU"]]), PdfKeys.ocrAuto: true])
            try expectEqual(both.info?.languages, ["en-US", "ru-RU"], "the order of the list is kept")
            try expectEqual(both.info?.autoDetect, true)
            try expect(errorRate(both.text, russian.joined()) < 0.05, "both listed: \(both.text)")
            let filtered = try await read([PdfKeys.ocrLanguages: .rows([["lang": "lv-LV"], ["lang": "ru-RU"]])])
            try expectEqual(filtered.info?.languages, ["ru-RU"], "a language Vision cannot read is dropped, not passed on")
            let none = try await read([PdfKeys.ocrLanguages: .rows([["lang": "lv-LV"]])])
            try expect(none.info?.languages.isEmpty == false, "nothing usable falls back to the defaults: \(String(describing: none.info?.languages))")
            // the accurate level is always used: the fast one has no Russian
            try expectEqual(none.info?.accurate, true)
        }

        pdfTest("the recognition resolution is the one asked for, 300 dpi by default", proves: ["pdf.ocr.dpi"], timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "dpi.pdf", pages: [english])
            func rendered(_ extra: OptionValues) async throws -> String {
                let logs = Locked<[String]>([])
                _ = try await ocr([scan], extra.merging([PdfKeys.ocrOutput: "txt"]), log: { l in logs.withLock { $0.append(l) } })
                return logs.value.first { $0.hasPrefix("Recognised page 1") } ?? ""
            }
            let normal = try await rendered([:])
            try expect(normal.contains("2550x3300 px at 300 dpi"), "letter page at 300 dpi is 2550x3300: \(normal)")
            let low = try await rendered([PdfKeys.ocrDPI: 150])
            try expect(low.contains("1275x1650 px at 150 dpi"), "150 dpi: \(low)")
            // the picture export setting does not leak into recognition
            var settings = SettingsData(); settings.quality.pdfDpi = 50
            let op = try PdfRun.op("tools.ocr")
            let ctx = OperationContext.testing(op, items: FileItem.items([scan]), settings: settings)
            try expectEqual(ctx.options.int(PdfKeys.ocrDPI, 0), 300)
        }

        pdfTest("OCR of a long file stops within a moment when cancelled and leaves nothing behind", timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "long.pdf", pages: Array(repeating: english, count: 8))
            let start = Date()
            let task = Task { @MainActor in try await ocr([scan], [PdfKeys.ocrOutput: "searchablePdf"]) }
            try await Task.sleep(nanoseconds: 700_000_000)
            let cancelledAt = Date()
            task.cancel()
            let err = try await expectThrows { _ = try await task.value }
            try expect(err is CancellationError, "cancelled: \(err)")
            try expect(Date().timeIntervalSince(cancelledAt) < 1.0, "the job stopped in \(Date().timeIntervalSince(cancelledAt)) s")
            try expect(Date().timeIntervalSince(start) < 8, "and did not finish the 8 pages")
            try expect(TestFile.partials(in: fx.root).isEmpty, "no partial files")
            let produced = ((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []).filter { $0.contains("searchable") }
            try expect(produced.isEmpty, "no result file: \(produced)")
        }

        pdfTest("pdf.optimize as pictures can add a text layer, and pdf.to.txt recognises scanned pages when asked",
                proves: ["pdf.optimize.ocr", "pdf.text.ocr"], timeout: 300) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "s.pdf", pages: [english])
            let withLayer = try await PdfRun.run("pdf.optimize", [scan], [PdfKeys.mode: "raster", PdfKeys.level: "custom", PdfKeys.imageDPI: 100, PdfKeys.ocr: true,
                                                                          PdfKeys.ocrSkipText: false])
            try expect(contains(PdfRun.text(withLayer.outputs[0]), "quick brown fox"), "searchable after optimising: \(PdfRun.text(withLayer.outputs[0]))")
            let without = try await PdfRun.run("pdf.optimize", [scan], [PdfKeys.mode: "raster", PdfKeys.level: "custom", PdfKeys.imageDPI: 100, PdfKeys.ocr: false,
                                                                        PdfKeys.ocrSkipText: false])
            try expect(PdfRun.text(without.outputs[0]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no recognition, no text")
            // text export of a scan
            let on = try await PdfRun.run("pdf.to.txt", [scan], [PdfKeys.ocr: true])
            try expect(contains(try String(contentsOf: on.outputs[0], encoding: .utf8), "lazy dog"), "recognised into the text file")
            let off = try await expectThrows { _ = try await PdfRun.run("pdf.to.txt", [scan], [PdfKeys.ocr: false]) }
            try expect(ConversionError.describe(off).lowercased().contains("scan") || ConversionError.describe(off).contains("скан"), "calm scan message: \(off)")
        }

        pdfTest("the document export hands recognised text of a scan to the writer", proves: ["pdf.export.ocr"], timeout: 240) {
            try await available()
            let fx = TestFixtures(); defer { fx.cleanup() }
            let scan = try PdfFixtures.scan(fx, "doc.pdf", pages: [russian, english])
            let op = try PdfRun.op("pdf.to.docx")
            let item = FileItem(url: scan)
            func markdown(_ extra: OptionValues) async throws -> String {
                let ctx = OperationContext.testing(op, items: [item], extra: extra)
                defer { ctx.cleanupTemp() }
                return try await PdfJobs.exportMarkdown(item, ctx: ctx, progress: ctx.slice(index: 0, count: 1)).markdown
            }
            let md = try await markdown([PdfKeys.ocr: true])
            try expect(contains(md, "Привет мир") && contains(md, "lazy dog") && md.contains("---"), "Markdown from recognised pages: \(md)")
            let off = try await expectThrows { _ = try await markdown([PdfKeys.ocr: false]) }
            try expect(!ConversionError.describe(off).isEmpty)
        }
    }
}

private extension OptionValues {
    func merging(_ other: OptionValues) -> OptionValues {
        var out = self
        for (k, v) in other.storage { out[k] = v }
        return out
    }
}
