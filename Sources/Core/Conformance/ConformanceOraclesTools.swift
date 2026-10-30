import Foundation
import PDFKit
import CoreGraphics

// Oracles of the operations that used to rely on the generic checks alone: page extraction, text recognition (OCR), the five slides operations and PDF to
// PowerPoint. Each reads the result back with something that is not the code that wrote it (PDFKit, unzip + XMLParser, ImageIO, an independent LibreOffice run)
// and compares it with facts known from the fixture. Numbers live in `ConformanceThresholds`.

extension ConformanceOracles {
    // MARK: Extract pages

    static let pdfExtract = ConformanceOracle(
        id: "pdf.extract", priority: 10, match: { $0.id == "pdf.extract" },
        cases: { meta, fx in
            guard let key = meta.quickPromptKeys.first else { return [] }
            let src = try fx.richPDF("book.pdf", pages: 5).url
            var range = ConformanceCase(label: "pages 2-3, 5", inputs: [src]); range.extra = [key: "2-3, 5"]
            var one = ConformanceCase(label: "page 4", inputs: [try fx.richPDF("single-pick.pdf", pages: 5, seed: 9).url]); one.extra = [key: "4"]
            return [range, one]
        },
        verify: { run in
            let out = try run.sole()
            guard let key = run.meta.quickPromptKeys.first, let spec = run.options[key]?.asString else { throw run.fail("the page range did not reach the operation") }
            let wanted: [Int] = spec.split(separator: ",").flatMap { part -> [Int] in
                let ends = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                return ends.count == 2 ? Array(ends[0]...ends[1]) : ends
            }
            guard let src = PDFReader.facts(run.input), let dst = PDFReader.facts(out) else { throw run.fail("PDFKit cannot read the source or the result") }
            try expectEqual(dst.pageCount, wanted.count, "the result holds exactly the asked pages \(wanted)")
            try expect(dst.pageCount < src.pageCount, "extracting must leave pages out")
            for (i, n) in wanted.enumerated() {
                let want = src.pageText[n - 1], got = dst.pageText[i]
                let recall = TextCompare.wordRecall(expected: want, actual: got)
                try expect(recall >= ConformanceThresholds.extractedPageWordRecall, String(format: "result page %d (source page %d): only %.1f%% of the words", i + 1, n, recall * 100))
                try expect(TextCompare.wordRecall(expected: got, actual: want) >= ConformanceThresholds.extractedPageWordRecall, "result page \(i + 1) holds text that is not on source page \(n)")
                try expect(abs(dst.pageSizes[i].width - src.pageSizes[n - 1].width) < 0.5 && abs(dst.pageSizes[i].height - src.pageSizes[n - 1].height) < 0.5, "page size changed")
                guard let a = ImageFidelity.rasterize(pdf: run.input, page: n - 1, width: 600), let b = ImageFidelity.rasterize(pdf: out, page: i, width: 600), let p = ImageFidelity.psnr(a, b) else { throw run.fail("cannot render page \(i + 1)") }
                try expect(p >= ConformanceThresholds.extractedPagePSNR, String(format: "result page %d no longer looks like source page %d (PSNR %.1f dB)", i + 1, n, p))
            }
            run.note("pages \(wanted) of \(src.pageCount) kept, text and look equal")
        },
        proves: "exactly the asked pages in order, each with its own text (recall in both directions), size and look (PSNR against PDFKit's render of the source page)")

    // MARK: OCR

    /// What each OCR fixture says, by file name.
    @MainActor static let ocrTruth: [String: (lines: [String], language: String, limit: Double)] = [
        "english.png": (["Swamp Converter reads 12345", "The quick brown fox jumps", "over the lazy dog"], "en-US", ConformanceThresholds.ocrCharacterErrorEnglish),
        "russian.png": (["Привет мир болото", "Быстрая лиса прыгает", "через ленивую собаку"], "ru-RU", ConformanceThresholds.ocrCharacterErrorRussian),
        "english-scan.pdf": (["Page one of the scan", "Numbers 2024 and words"], "en-US", ConformanceThresholds.ocrCharacterErrorEnglish),
        "russian-scan.pdf": (["Сканированная страница", "Русский текст для проверки"], "ru-RU", ConformanceThresholds.ocrCharacterErrorRussian)
    ]

    static let toolsOCR = ConformanceOracle(
        id: "tools.ocr", priority: 10, match: { $0.id == "tools.ocr" }, requires: ["native.vision.ocr"], timeout: 300,
        cases: { _, fx in
            var cases: [ConformanceCase] = []
            for (name, truth) in ocrTruth.sorted(by: { $0.key < $1.key }) {
                let file = name.hasSuffix(".png") ? try fx.textPagePNG(name, lines: truth.lines) : try fx.scannedPDF(name, pages: [truth.lines])
                var c = ConformanceCase(label: name, inputs: [file])
                // The clipboard stays the person's: the suite never writes to it. The language is named, as Studio would.
                c.extra = ["pdf.ocr.clipboard": false, "pdf.ocr.out": "txt", "pdf.ocr.auto": false, "pdf.ocr.langs": .rows([["lang": .string(truth.language)]])]
                cases.append(c)
            }
            return cases
        },
        verify: { run in
            let out = try run.sole()
            try expectEqual(out.pathExtension, "txt")
            guard let truth = ocrTruth[run.input.lastPathComponent] else { throw run.fail("no ground truth for \(run.input.lastPathComponent)") }
            let text = try String(contentsOf: out, encoding: .utf8)
            let cer = TextCompare.characterErrorRate(expected: truth.lines.joined(separator: " "), actual: text)
            try expect(cer <= truth.limit, String(format: "%@ read with a character error rate of %.1f%% (limit %.1f%%): \"%@\"", run.input.lastPathComponent, cer * 100, truth.limit * 100, String(text.prefix(120))))
            run.note(String(format: "%@ CER %.1f%% (limit %.0f%%)", truth.language, cer * 100, truth.limit * 100))
        },
        proves: "the text of a rendered page / a scanned PDF read back with a character error rate under the documented limit, in English and in Russian; the clipboard untouched")

    // MARK: Slides

    private static func slideTexts(fromXML xml: String) -> String {
        // The text runs of a slide: <a:t> (PowerPoint) and <text:p> / <text:span> content (OpenDocument), tags removed.
        var s = xml
        s = s.replacingOccurrences(of: #"</(a:p|text:p)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func wellFormed(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        return parser.parse()
    }

    /// LibreOffice's own PDF of the deck, made by a separate command-line run with a throw-away profile: the reference the slide pictures are compared with.
    @MainActor static func referenceDeckPDF(_ deck: URL, fx: ConformanceFixtures) throws -> URL {
        guard let soffice = ExternalProbe.path(.soffice) else { throw TestSkip(reason: "LibreOffice is not installed") }
        let out = try fx.folder("ref-" + UUID().uuidString.prefix(6))
        let profile = try fx.folder("profile-" + UUID().uuidString.prefix(6))
        let r = ExternalProbe.run(soffice, ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore", "--nolockcheck", "--nodefault", "--convert-to", "pdf", "--outdir", out.path, deck.path], timeout: 240)
        let pdf = out.appendingPathComponent(Formats.baseName(of: deck, isDirectory: false) + ".pdf")
        guard FileManager.default.fileExists(atPath: pdf.path) else { throw TestFailure(message: "LibreOffice could not make the reference PDF (exit \(r.status)): \(r.error.prefix(200))", file: #fileID, line: #line) }
        return pdf
    }

    static let slidesConvert = ConformanceOracle(
        id: "slides.convert", priority: 10, match: { $0.family == .slides }, requires: ["tool.soffice"], timeout: 420,
        cases: { meta, fx in
            // The deck is an ODP written by hand. Same-format hiding applies to the wheel only: ODP to ODP is a Studio re-save.
            var c = ConformanceCase(label: "3 slides", inputs: [try fx.odp("deck.odp", slides: 3)])
            if meta.targetFormat == "odp" { c.mode = .studio }
            return [c]
        },
        verify: { run in
            let target = run.meta.targetFormat ?? "pdf"
            let slides = 3
            func slideMatches(_ text: String, _ i: Int) -> Bool { TextCompare.wordRecall(expected: ConformanceFixtures.slideText(i), actual: text) >= ConformanceThresholds.slideWordRecall }
            switch target {
            case "pdf":
                let out = try run.sole()
                guard let f = PDFReader.facts(out) else { throw run.fail("PDFKit cannot read the PDF") }
                try expectEqual(f.pageCount, slides, "one PDF page per slide")
                for i in 1...slides { try expect(slideMatches(f.pageText[i - 1], i), "page \(i) lacks the text of slide \(i): \(f.pageText[i - 1])") }
                try expect(abs(f.pageSizes[0].width - 28 / 2.54 * 72) < 2 && abs(f.pageSizes[0].height - 15.75 / 2.54 * 72) < 2, "the page is not the slide's size: \(f.pageSizes[0])")
                run.note("3 pages, each with its slide's text, \(Int(f.pageSizes[0].width))x\(Int(f.pageSizes[0].height)) pt")
            case "png", "jpg":
                try expectEqual(run.outputs.count, slides, "one picture per slide")
                let dpi = run.options.keys.first(where: { $0.lowercased().hasSuffix("dpi") }).map { run.options.double($0, 300) } ?? 300
                let ref = try referenceDeckPDF(run.input, fx: run.fx)
                let floor = target == "png" ? ConformanceThresholds.slidePicturePSNRPNG : ConformanceThresholds.slidePicturePSNRJPG
                var worst = 999.0
                for (i, file) in run.outputs.enumerated() {
                    guard let stored = ImageFidelity.storedSize(file) else { throw run.fail("cannot read the size of \(file.lastPathComponent)") }
                    let ew = Int((28 / 2.54 * dpi).rounded()), eh = Int((15.75 / 2.54 * dpi).rounded())
                    try expect(abs(stored.width - ew) <= 3 && abs(stored.height - eh) <= 3, "\(file.lastPathComponent) is \(stored.width)x\(stored.height); \(Int(dpi)) dpi of the slide is \(ew)x\(eh)")
                    guard let img = ImageFidelity.decode(file, maxSide: 900) else { throw run.fail("cannot decode \(file.lastPathComponent)") }
                    try expect(img.luma.filter { $0 < 100 }.count > Int(Double(img.pixelCount) * ConformanceThresholds.slideMinInkFraction), "\(file.lastPathComponent) is blank: the slide's text is not drawn")
                    guard let truth = ImageFidelity.rasterize(pdf: ref, page: i, width: img.width), let aligned = ImageFidelity.scaled(truth, width: img.width, height: img.height),
                          let p = ImageFidelity.psnr(aligned, img) else { throw run.fail("cannot compare slide \(i + 1)") }
                    try expect(p >= floor, String(format: "slide %d differs from LibreOffice's own render: PSNR %.1f dB (floor %.0f dB)", i + 1, p, floor))
                    worst = min(worst, p)
                }
                let names = run.outputs.map(\.lastPathComponent)
                try expectEqual(names, (1...slides).map { "deck - \($0).\(target)" }, "files are numbered in slide order")
                run.note(String(format: "3 pictures at %d dpi, worst PSNR %.1f dB against LibreOffice's render", Int(dpi), worst))
            case "pptx", "odp":
                let out = try run.sole()
                guard let members = ZipProbe.entries(out) else { throw run.fail("\(out.lastPathComponent) is not a readable ZIP package") }
                let names = members.map(\.name)
                func part(_ n: String) -> String { members.first { $0.name == n }.flatMap { ZipProbe.read($0, from: out) }.map { String(decoding: $0, as: UTF8.self) } ?? "" }
                if target == "pptx" {
                    try expect(names.contains("[Content_Types].xml") && names.contains("_rels/.rels") && names.contains("ppt/presentation.xml"), "OOXML presentation parts are missing")
                    let slideParts = names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.sorted { Util.naturalCompare($0, $1) == .orderedAscending }
                    try expectEqual(slideParts.count, slides, "a slide part per slide")
                    for (i, n) in slideParts.enumerated() {
                        try expect(slideMatches(slideTexts(fromXML: part(n)), i + 1), "\(n) lacks the text of slide \(i + 1)")
                        try expect(wellFormed(Data(part(n).utf8)), "\(n) is not well-formed XML")
                    }
                    try expect(wellFormed(Data(part("ppt/presentation.xml").utf8)), "presentation.xml is not well-formed XML")
                } else {
                    try expectEqual(names.first, "mimetype", "mimetype comes first")
                    try expect(members.first?.method == 0, "mimetype is stored, not compressed")
                    try expectEqual(part("mimetype"), "application/vnd.oasis.opendocument.presentation")
                    let content = part("content.xml")
                    try expect(wellFormed(Data(content.utf8)), "content.xml is not well-formed XML")
                    try expectEqual(content.components(separatedBy: "<draw:page ").count - 1, slides, "a draw:page per slide")
                    for i in 1...slides { try expect(content.contains(ConformanceFixtures.slideText(i)), "slide \(i) text is missing from content.xml") }
                }
                run.note("package parts, \(slides) slides in order with their text, XML well-formed")
            default:
                throw run.fail("no slides check for \(target)")
            }
        },
        proves: "pdf: a page per slide with its text and the slide's size; png / jpg: a numbered picture per slide at dpi x size within PSNR of LibreOffice's own render; pptx / odp: a valid package with a part per slide, its text, well-formed XML")

    // MARK: PDF to PowerPoint

    static let pdfToPptx = ConformanceOracle(
        id: "pdf.to-pptx", priority: 10, match: { $0.id == "pdf.to.pptx" }, requires: ["tool.soffice"], timeout: 420,
        cases: { _, fx in [ConformanceCase(label: "2 pages", inputs: [try fx.richPDF("paper.pdf", pages: 2).url])] },
        verify: { run in
            let out = try run.sole()
            guard let src = PDFReader.facts(run.input), let members = ZipProbe.entries(out) else { throw run.fail("cannot read the source PDF or the PPTX package") }
            let names = members.map(\.name)
            try expect(names.contains("[Content_Types].xml") && names.contains("ppt/presentation.xml"), "not an OOXML presentation")
            let parts = names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.sorted { Util.naturalCompare($0, $1) == .orderedAscending }
            try expectEqual(parts.count, src.pageCount, "one slide per page")
            for (i, n) in parts.enumerated() {
                guard let m = members.first(where: { $0.name == n }), let data = ZipProbe.read(m, from: out) else { throw run.fail("cannot read \(n)") }
                try expect(wellFormed(data), "\(n) is not well-formed XML")
                let text = slideTexts(fromXML: String(decoding: data, as: UTF8.self))
                let recall = TextCompare.wordRecall(expected: src.pageText[i], actual: text)
                try expect(recall >= ConformanceThresholds.pdfToPptxWordRecall, String(format: "slide %d holds only %.0f%% of page %d's words", i + 1, recall * 100, i + 1))
            }
            run.note("\(parts.count) slides, one per page, with the page's words")
        },
        proves: "a PPTX package with one well-formed slide per PDF page, each holding the words of its page in order")
}
