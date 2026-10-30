import Foundation
import PDFKit

// Default oracles for PDF operations. The fixture is a multi-page text PDF (headings, wrapped paragraphs in Latin, Cyrillic and Czech) whose text is known
// page by page, so "the text survived" is a number (word recall in reading order, from PDFKit's own extraction), and "the page looks the same" is a PSNR
// against an independent PDFKit render.

extension ConformanceOracles {
    static func pageTexts(of url: URL) -> [String] { PDFReader.facts(url)?.pageText ?? [] }

    /// PDFs set in the San Francisco system font: macOS 26 PDFKit rewrites their Cyrillic text layer wrongly on any re-save, so the same check runs as an advisory.
    static let sfFontLimitation = "macOS 26 PDFKit maps the Cyrillic к of SF-font text to U+0138 on every re-save (verified with an unmodified PDFDocument.write); other fonts are unaffected"
    @MainActor static func sfCase(_ fx: ConformanceFixtures, pages: Int = 2, extra: OptionValues = OptionValues(), userPassword: String? = nil) throws -> ConformanceCase {
        var c = ConformanceCase(label: "SF system font (advisory)", inputs: [try fx.richPDF("sf.pdf", pages: pages, userPassword: userPassword, systemFont: true).url])
        c.extra = extra
        c.advisory = sfFontLimitation
        return c
    }

    // MARK: PDF to pictures

    static let pdfToImages = ConformanceOracle(
        id: "pdf.to-images", priority: 0,
        match: { $0.wheel == .convert && ["jpg", "png"].contains($0.targetFormat ?? "") && ($0.inputs?.contains("pdf") ?? false) },
        timeout: 300,
        cases: { _, fx in
            [ConformanceCase(label: "3 pages", inputs: [try fx.richPDF("doc.pdf", pages: 3).url]), ConformanceCase(label: "1 page", inputs: [try fx.richPDF("single.pdf", pages: 1).url])]
        },
        verify: { run in
            let target = run.meta.targetFormat ?? "png"
            guard let facts = PDFReader.facts(run.input) else { throw run.fail("cannot read the source PDF") }
            try expectEqual(run.outputs.count, facts.pageCount, "one picture per page")
            let dpi = run.options.keys.first(where: { $0.lowercased().hasSuffix("dpi") }).map { run.options.double($0, 300) } ?? 300
            for (i, file) in run.outputs.enumerated() {
                guard let stored = ImageFidelity.storedSize(file) else { throw run.fail("cannot read the size of \(file.lastPathComponent)") }
                let size = facts.pageSizes[i]
                let ew = Int((size.width * dpi / 72).rounded()), eh = Int((size.height * dpi / 72).rounded())
                try expect(abs(stored.width - ew) <= 2 && abs(stored.height - eh) <= 2, "page \(i + 1) is \(stored.width)x\(stored.height) px; \(Int(dpi)) dpi of a \(Int(size.width))x\(Int(size.height)) pt page is \(ew)x\(eh)")
                // The content is compared at a reduced size, and both sides are reduced by the same ImageIO scaler: the picture as delivered, and an independent PDFKit render at the delivered width.
                guard let img = ImageFidelity.decode(file, maxSide: 900) else { throw run.fail("cannot decode \(file.lastPathComponent)") }
                guard let ref = ImageFidelity.rasterizeReduced(pdf: run.input, page: i, renderWidth: stored.width, maxSide: 900) else { throw run.fail("cannot render page \(i + 1) for comparison") }
                let aligned = ImageFidelity.scaled(ref, width: img.width, height: img.height) ?? ref
                guard let psnr = ImageFidelity.psnr(aligned, img) else { throw run.fail("cannot compare page \(i + 1)") }
                let floor = target == "png" ? ConformanceThresholds.pdfRasterPSNRPNG : ConformanceThresholds.pdfRasterPSNRJPG
                try expect(psnr >= floor, String(format: "page %d differs from an independent render: PSNR %.1f dB (floor %.0f dB)", i + 1, psnr, floor))
                let dark = img.luma.filter { $0 < 100 }.count
                try expect(dark > img.pixelCount / 500, "page \(i + 1) is blank")
                // A second, unrelated renderer (poppler's pdftoppm, when installed) must see the same page: the same layout of ink, and better than it matches the neighbouring page.
                var poppler = ""
                if let theirs = popplerRender(pdf: run.input, page: i), let same = ImageFidelity.layoutCorrelation(img, theirs) {
                    try expect(same >= ConformanceThresholds.pdfRasterLayoutCorrelation, String(format: "page %d does not look like poppler's render of it: layout correlation %.2f (floor %.2f)", i + 1, same, ConformanceThresholds.pdfRasterLayoutCorrelation))
                    if facts.pageCount > 1, let other = popplerRender(pdf: run.input, page: (i + 1) % facts.pageCount), let wrong = ImageFidelity.layoutCorrelation(img, other) {
                        try expect(same > wrong, String(format: "page %d looks more like another page (%.2f) than like itself (%.2f): wrong order?", i + 1, wrong, same))
                    }
                    poppler = String(format: ", layout vs poppler %.3f", same)
                }
                if i == 0 { run.note(String(format: "%d page(s) at %d dpi, page 1 %@%@", facts.pageCount, Int(dpi), psnr.isInfinite ? "identical to PDFKit's render" : String(format: "PSNR %.1f dB", psnr), poppler)) }
            }
            if facts.pageCount > 1 {
                let names = run.outputs.map(\.lastPathComponent)
                try expect(names.enumerated().allSatisfy { $0.element.contains(" - ") && $0.element.hasSuffix(".\(target)") }, "multi-page output should be named '<name> - N.\(target)': \(names)")
            }
        },
        proves: "one picture per page, sized pages x dpi, in page order, within PSNR of an independent PDFKit render, not blank")

    /// One page rendered by poppler's pdftoppm at 100 dpi; nil when pdftoppm is not installed.
    private static func popplerRender(pdf: URL, page: Int) -> RasterImage? {
        let dirs = [ToolLocator.shared.find(.pdftotext)?.url.deletingLastPathComponent().path].compactMap { $0 } + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let exe = dirs.map({ $0 + "/pdftoppm" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let dir = AppPaths.makeTempDirectory(purpose: "conformance-poppler"); defer { AppPaths.removeTemp(dir) }
        let r = ExternalProbe.run(exe, ["-r", "100", "-f", "\(page + 1)", "-l", "\(page + 1)", "-png", pdf.path, dir.appendingPathComponent("p").path], timeout: 60)
        guard r.status == 0, let png = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "png" }) else { return nil }
        return ImageFidelity.decode(png)
    }

    // MARK: PDF to text

    static let pdfToText = ConformanceOracle(
        id: "pdf.to-text", priority: 0,
        match: { $0.wheel == .convert && ["txt", "md"].contains($0.targetFormat ?? "") && ($0.inputs?.contains("pdf") ?? false) },
        cases: { _, fx in [ConformanceCase(label: "3 pages", inputs: [try fx.richPDF("doc.pdf", pages: 3).url])] },
        verify: { run in
            let out = try run.sole()
            let data = try Data(contentsOf: out)
            try expect(!data.starts(with: [0xEF, 0xBB, 0xBF]), "text exports are UTF-8 without a BOM")
            guard let text = String(data: data, encoding: .utf8) else { throw run.fail("the text is not valid UTF-8") }
            let expected = pageTexts(of: run.input).joined(separator: "\n")
            let recall = TextCompare.wordRecall(expected: expected, actual: text)
            try expect(recall >= 0.97, String(format: "only %.1f%% of the PDF's words came through, in order", recall * 100))
            run.note(String(format: "%.1f%% of words in order", recall * 100))
        },
        proves: "all the text of the PDF in reading order, UTF-8 without BOM, Cyrillic and Czech letters intact")

    // MARK: PDF to office documents

    static let pdfToDocument = ConformanceOracle(
        id: "pdf.to-document", priority: 0,
        match: { $0.wheel == .convert && ["docx", "html", "epub", "odt"].contains($0.targetFormat ?? "") && ($0.inputs?.contains("pdf") ?? false) },
        cases: { _, fx in [ConformanceCase(label: "3 pages", inputs: [try fx.richPDF("doc.pdf", pages: 3).url])] },
        verify: { run in
            let out = try run.sole()
            guard let doc = DocStructure.read(out) else { throw run.fail("cannot read the produced document") }
            let expected = pageTexts(of: run.input).joined(separator: "\n")
            let recall = TextCompare.wordRecall(expected: expected, actual: doc.text)
            try expect(recall >= 0.95, String(format: "only %.1f%% of the PDF's words are in the document", recall * 100))
            run.note(String(format: "%.1f%% of words, %@ (text only: a PDF has no document structure)", recall * 100, doc.summary))
        },
        proves: "the text of the PDF in the document, in order (no layout is claimed)")

    // MARK: PDF tools (by what they promise)

    static let pdfMerge = ConformanceOracle(
        id: "pdf.merge", priority: 10, match: { $0.id == "pdf.merge" },
        cases: { _, fx in
            let a = try fx.richPDF("a.pdf", pages: 2), b = try fx.richPDF("b.pdf", pages: 3, seed: 6)
            var sf = ConformanceCase(label: "SF system font (advisory)", inputs: [try fx.richPDF("sfa.pdf", pages: 2, systemFont: true).url, try fx.richPDF("sfb.pdf", pages: 2, seed: 6, systemFont: true).url])
            sf.advisory = sfFontLimitation
            return [ConformanceCase(label: "2+3 pages", inputs: [a.url, b.url]), sf]
        },
        verify: { run in
            let out = try run.sole()
            let a = pageTexts(of: run.inputs[0]), b = pageTexts(of: run.inputs[1])
            let got = pageTexts(of: out)
            try expectEqual(got.count, a.count + b.count, "merged page count")
            for (i, expected) in (a + b).enumerated() {
                let r = TextCompare.wordRecall(expected: expected, actual: got[i])
                try expect(r >= 0.97, String(format: "page %d of the merge is not page %d of %@ (word recall %.0f%%; expected \"%@\", got \"%@\")", i + 1, i + 1 > a.count ? i + 1 - a.count : i + 1,
                                              i + 1 > a.count ? "b" : "a", r * 100, String(TextCompare.normalize(expected).prefix(50)), String(TextCompare.normalize(got[i]).prefix(50))))
            }
            run.note("\(got.count) pages in the right order")
        },
        proves: "every page of every input, once, in order, with its text")

    static let pdfSplit = ConformanceOracle(
        id: "pdf.split", priority: 10, match: { $0.id == "pdf.split" },
        cases: { _, fx in [ConformanceCase(label: "3 pages", inputs: [try fx.richPDF("doc.pdf", pages: 3).url]), try sfCase(fx, pages: 3)] },
        verify: { run in
            let pages = pageTexts(of: run.input)
            try expectEqual(run.outputs.count, pages.count, "one file per page")
            for (i, file) in run.outputs.enumerated() {
                let got = pageTexts(of: file)
                try expectEqual(got.count, 1, "\(file.lastPathComponent) holds one page")
                let r = TextCompare.wordRecall(expected: pages[i], actual: got[0])
                try expect(r >= 0.97, String(format: "%@ is not page %d (word recall %.0f%%; expected \"%@\", got \"%@\")", file.lastPathComponent, i + 1, r * 100, String(TextCompare.normalize(pages[i]).prefix(50)), String(TextCompare.normalize(got[0]).prefix(50))))
            }
        },
        proves: "one single-page PDF per page, in order, with that page's text")

    static let pdfRotate = ConformanceOracle(
        id: "pdf.rotate", priority: 10, match: { $0.id == "pdf.rotate" },
        cases: { _, fx in [ConformanceCase(label: "3 pages", inputs: [try fx.richPDF("doc.pdf", pages: 3).url]), try sfCase(fx, pages: 3)] },
        verify: { run in
            let out = try run.sole()
            guard let before = PDFReader.facts(run.input), let after = PDFReader.facts(out) else { throw run.fail("cannot read the PDFs") }
            try expectEqual(after.pageCount, before.pageCount, "page count")
            for i in 0..<before.pageCount { try expectEqual((after.rotations[i] - before.rotations[i] + 360) % 360, 90, "page \(i + 1) must turn 90 degrees clockwise") }
            let r = TextCompare.wordRecall(expected: before.allText, actual: after.allText)
            try expect(r >= 0.97, String(format: "text changed after rotating (word recall %.0f%%; before \"%@\", after \"%@\")", r * 100, String(TextCompare.normalize(before.allText).prefix(60)), String(TextCompare.normalize(after.allText).prefix(60))))
        },
        proves: "every page turned by +90 degrees, nothing else changed")

    static let pdfOptimize = ConformanceOracle(
        id: "pdf.optimize", priority: 10, match: { $0.id == "pdf.optimize" },
        cases: { _, fx in [ConformanceCase(label: "with photos", inputs: [try fx.richPDF("photos.pdf", pages: 3, withImage: true).url]), try sfCase(fx)] },
        verify: { run in
            let out = try run.sole()
            guard let before = PDFReader.facts(run.input), let after = PDFReader.facts(out) else { throw run.fail("cannot read the PDFs") }
            try expectEqual(after.pageCount, before.pageCount, "page count")
            try expect(TextCompare.wordRecall(expected: before.allText, actual: after.allText) >= 0.97, "text changed")
            let a = TestFile.size(run.input), b = TestFile.size(out)
            try expect(Double(b) <= Double(a) * 1.05, "optimized file is larger than the original: \(a) -> \(b) bytes")
            for i in 0..<min(before.pageCount, 1) {
                guard let x = ImageFidelity.rasterize(pdf: run.input, page: i, width: 600), let y = ImageFidelity.rasterize(pdf: out, page: i, width: 600), let p = ImageFidelity.psnr(x, y) else { continue }
                try expect(p >= 30, String(format: "page %d no longer looks the same (PSNR %.1f dB)", i + 1, p))
            }
            run.note("\(Util.formatBytes(a)) -> \(Util.formatBytes(b))")
        },
        proves: "same pages, same text, same look, not larger")
}

extension ConformanceOracles {
    static let pdfProtect = ConformanceOracle(
        id: "pdf.protect", priority: 10, match: { $0.id == "pdf.protect" },
        cases: { _, fx in
            var c = ConformanceCase(label: "open password", inputs: [try fx.richPDF("doc.pdf", pages: 2).url])
            c.extra = ["pdf.pw.open": "swamp-pass"]
            return [c, try sfCase(fx, extra: ["pdf.pw.open": "swamp-pass"])]
        },
        verify: { run in
            let out = try run.sole()
            guard let doc = PDFDocument(url: out) else { throw run.fail("PDFKit cannot open the output") }
            try expect(doc.isEncrypted && doc.isLocked, "the output must be encrypted and locked until the password is given")
            try expect(!doc.unlock(withPassword: "not-the-password"), "a wrong password opened the file")
            try expect(doc.unlock(withPassword: "swamp-pass"), "the right password does not open the file")
            guard let before = PDFReader.facts(run.input), let after = PDFReader.facts(out, password: "swamp-pass") else { throw run.fail("cannot read the PDFs") }
            try expectEqual(after.pageCount, before.pageCount, "page count")
            let r = TextCompare.wordRecall(expected: before.allText, actual: after.allText)
            try expect(r >= 0.97, String(format: "text changed after protecting (recall %.0f%%)", r * 100))
            run.note("locked; opens with the password only; \(after.pageCount) pages and text intact")
        },
        proves: "really encrypted: locked without the password, a wrong password refused, the right one opens the same pages and text")

    static let pdfUnlock = ConformanceOracle(
        id: "pdf.unlock", priority: 10, match: { $0.id == "pdf.unlock" },
        cases: { _, fx in
            var good = ConformanceCase(label: "right password", inputs: [try fx.richPDF("secret.pdf", pages: 2, userPassword: "swamp-pass").url])
            good.extra = ["pdf.pw.open": "swamp-pass"]
            var bad = ConformanceCase(label: "wrong password", inputs: [try fx.richPDF("secret2.pdf", pages: 2, userPassword: "swamp-pass").url])
            bad.extra = ["pdf.pw.open": "guess"]
            bad.expectsFailure = true
            return [good, bad, try sfCase(fx, extra: ["pdf.pw.open": "swamp-pass"], userPassword: "swamp-pass")]
        },
        verify: { run in
            if run.testCase.expectsFailure {
                try expect(run.error != nil, "a wrong password must be refused with a message")
                run.note("refused: \(run.error ?? "")")
                return
            }
            let out = try run.sole()
            guard let doc = PDFDocument(url: out) else { throw run.fail("PDFKit cannot open the output") }
            try expect(!doc.isLocked && !doc.isEncrypted, "the output still asks for a password")
            guard let before = PDFReader.facts(run.input, password: "swamp-pass"), let after = PDFReader.facts(out) else { throw run.fail("cannot read the PDFs") }
            try expectEqual(after.pageCount, before.pageCount, "page count")
            let r = TextCompare.wordRecall(expected: before.allText, actual: after.allText)
            try expect(r >= 0.97, String(format: "text changed after unlocking (recall %.0f%%)", r * 100))
            run.note("opens without a password; \(after.pageCount) pages and text intact")
        },
        proves: "an unlocked copy that opens without a password with the same pages and text; a wrong password is refused")
}
