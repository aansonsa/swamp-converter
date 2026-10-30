import Foundation
import PDFKit
import AppKit

// The Page, Type, Pictures and Metadata options: paper size, margins, page numbers, font, size and line spacing are proven on the geometry PDFKit reports and on the
// package XML / RTF control words of the word-processor formats; metadata options on what each format stores. Results are read with PDFKit, unzip and plain text.

enum DocsPageTests {
    struct Line { var text: String; var bounds: CGRect }

    static func lines(_ page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return selection.selectionsByLine().map { Line(text: $0.string ?? "", bounds: $0.bounds(for: page)) }
    }

    static func box(_ url: URL, page i: Int = 0) throws -> CGRect { try unwrap(PDFDocument(url: url)?.page(at: i), "page \(i + 1) of \(url.lastPathComponent)").bounds(for: .mediaBox) }

    /// A long document (about 8 pages) made as a DOCX so the PDF layout has real work to do.
    static func longDocx(_ fx: TestFixtures, name: String = "long.docx") async throws -> URL {
        try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx, long: true), name: name)
    }

    static func register() {
        registerPaper()
        registerType()
        registerMetadata()
        registerPictures()
    }

    // MARK: Paper

    private static func registerPaper() {
        docTest("doc.pdf.size: the PDF media box, the DOCX page size, the ODT page layout and the RTF paper words follow the chosen paper", proves: ["doc.pdf.mediabox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = try await DocFixtures.makeInput("md", in: fx, model: DocFixtures.sample(fx), name: "paper.md")
            let region = Locale.current.region?.identifier ?? ""
            let auto = ["US", "CA", "MX"].contains(region) ? "letter" : "a4"
            let sizes: [String: (w: Double, h: Double)] = ["a4": (595.2756, 841.8898), "letter": (612, 792), "a5": (419.5276, 595.2756), "legal": (612, 1008)]
            for id in ["a4", "letter", "a5", "legal", "auto"] {
                let want = sizes[id] ?? sizes[auto]!
                let pdf = try box(try await DocRun.convert(src, to: "pdf", [DocKeys.pageSize: .string(id)], into: out))
                try expectClose(Double(pdf.width), want.w, tolerance: 0.5, "\(id): PDF width"); try expectClose(Double(pdf.height), want.h, tolerance: 0.5, "\(id): PDF height")
                let docx = try await DocRun.convert(src, to: "docx", [DocKeys.pageSize: .string(id)], into: out)
                let sect = DocOracle.zipPart(docx, "word/document.xml")
                try expect(sect.contains("<w:pgSz w:w=\"\(Int((want.w * 20).rounded()))\" w:h=\"\(Int((want.h * 20).rounded()))\"/>"), "\(id): DOCX page size in twips")
                let odt = try await DocRun.convert(src, to: "odt", [DocKeys.pageSize: .string(id)], into: out)
                let styles = DocOracle.zipPart(odt, "styles.xml")
                try expect(styles.contains("fo:page-width=\"\(String(format: "%.3fcm", want.w / 72 * 2.54))\"") && styles.contains("fo:page-height=\"\(String(format: "%.3fcm", want.h / 72 * 2.54))\""), "\(id): ODT page layout")
                let rtf = try String(contentsOf: try await DocRun.convert(src, to: "rtf", [DocKeys.pageSize: .string(id)], into: out), encoding: .ascii)
                try expect(rtf.contains("\\paperw\(Int((want.w * 20).rounded()))\\paperh\(Int((want.h * 20).rounded()))"), "\(id): RTF paper words")
            }
        }

        docTest("doc.pdf.margins: text starts and stops inside the margins, and wider margins make more pages; DOCX, ODT and RTF carry the same margins", proves: ["doc.pdf.margins"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = try await longDocx(fx)
            var pageCounts: [Int] = []
            for mm in [10.0, 25.0, 40.0] {
                let pt = mm / 25.4 * 72
                let pdf = try await DocRun.convert(src, to: "pdf", [DocKeys.margins: .double(mm)], into: out)
                let doc = try unwrap(PDFDocument(url: pdf))
                pageCounts.append(doc.pageCount)
                let page = try unwrap(doc.page(at: 1))
                let ls = lines(page)
                let frame = page.bounds(for: .mediaBox)
                try expect(ls.count > 10, "\(mm) mm: page 2 has text")
                let minX = ls.map { $0.bounds.minX }.min() ?? 0, maxX = ls.map { $0.bounds.maxX }.max() ?? 0
                let top = ls.map { $0.bounds.maxY }.max() ?? 0, bottom = ls.map { $0.bounds.minY }.min() ?? 0
                try expectClose(Double(minX), pt, tolerance: 3, "\(mm) mm: left edge of the text")
                try expect(Double(maxX) <= Double(frame.width) - pt + 1.5, "\(mm) mm: the right edge \(maxX) stays inside the margin")
                try expect(Double(top) <= Double(frame.height) - pt + 1.5, "\(mm) mm: top \(top)")
                try expect(Double(bottom) >= pt - 3, "\(mm) mm: bottom \(bottom)")
                let docx = DocOracle.zipPart(try await DocRun.convert(src, to: "docx", [DocKeys.margins: .double(mm)], into: out), "word/document.xml")
                let tw = Int((pt * 20).rounded())
                try expect(docx.contains("<w:pgMar w:top=\"\(tw)\" w:right=\"\(tw)\" w:bottom=\"\(tw)\" w:left=\"\(tw)\""), "\(mm) mm: DOCX margins")
                let odt = DocOracle.zipPart(try await DocRun.convert(src, to: "odt", [DocKeys.margins: .double(mm)], into: out), "styles.xml")
                try expect(odt.contains("fo:margin-left=\"\(String(format: "%.3fcm", pt / 72 * 2.54))\""), "\(mm) mm: ODT margins")
                let rtf = try String(contentsOf: try await DocRun.convert(src, to: "rtf", [DocKeys.margins: .double(mm)], into: out), encoding: .ascii)
                try expect(rtf.contains("\\margl\(tw)\\margr\(tw)\\margt\(tw)\\margb\(tw)"), "\(mm) mm: RTF margins")
            }
            try expect(pageCounts[0] < pageCounts[1] && pageCounts[1] < pageCounts[2], "wider margins, more pages: \(pageCounts)")
        }

        docTest("doc.pdf.numbers: a centred page number sits in the bottom margin of every page, and only when asked", proves: ["doc.pdf.numbers"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = try await longDocx(fx)
            let off = try unwrap(PDFDocument(url: try await DocRun.convert(src, to: "pdf", [DocKeys.pageNumbers: false], into: out)))
            let on = try unwrap(PDFDocument(url: try await DocRun.convert(src, to: "pdf", [DocKeys.pageNumbers: true], into: out)))
            try expectEqual(off.pageCount, on.pageCount, "numbers do not change the layout")
            for i in [0, 1, on.pageCount - 1] {
                let page = try unwrap(on.page(at: i))
                let frame = page.bounds(for: .mediaBox)
                let bottom = lines(page).filter { $0.bounds.midY < 56.7 }       // inside the 20 mm bottom margin
                try expectEqual(bottom.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }, ["\(i + 1)"], "page \(i + 1): its number is the only text in the margin")
                try expectClose(Double(bottom[0].bounds.midX), Double(frame.width) / 2, tolerance: 6, "page \(i + 1): centred")
                let offBottom = lines(try unwrap(off.page(at: i))).filter { $0.bounds.midY < 56.7 }
                try expect(offBottom.isEmpty, "page \(i + 1): nothing in the margin without numbers")
            }
        }
    }

    // MARK: Type

    private static func registerType() {
        docTest("doc.pdf.font: the chosen family is what the PDF text is set in, and DOCX, ODT and RTF name it too", proves: ["doc.pdf.font"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = try await DocFixtures.makeInput("md", in: fx, model: DocFixtures.sample(fx), name: "fonts.md")
            func bodyFont(_ pdf: URL) throws -> NSFont {
                let page = try unwrap(PDFDocument(url: pdf)?.page(at: 0))
                let attr = try unwrap(page.attributedString)
                let r = try unwrap(attr.string.range(of: "Plain words"), "body text")
                return try unwrap(attr.attribute(.font, at: attr.string.distance(from: attr.string.startIndex, to: r.lowerBound), effectiveRange: nil) as? NSFont)
            }
            var seen: Set<String> = []
            for family in ["Times New Roman", "Georgia", "Menlo", "Arial", "Palatino"] {
                let f = try bodyFont(try await DocRun.convert(src, to: "pdf", [DocKeys.font: .string(family)], into: out))
                try expect(f.familyName?.hasPrefix(family) == true || f.fontName.replacingOccurrences(of: "-", with: " ").hasPrefix(family.replacingOccurrences(of: " ", with: "")), "\(family): the PDF uses \(f.fontName)")
                seen.insert(f.familyName ?? "")
                let docx = DocOracle.zipPart(try await DocRun.convert(src, to: "docx", [DocKeys.font: .string(family)], into: out), "word/styles.xml")
                try expect(docx.contains("w:ascii=\"\(family)\""), "\(family): DOCX default font")
                let odt = DocOracle.zipPart(try await DocRun.convert(src, to: "odt", [DocKeys.font: .string(family)], into: out), "styles.xml")
                try expect(odt.contains("svg:font-family=\"'\(family)'\""), "\(family): ODT font face")
                let rtf = try String(contentsOf: try await DocRun.convert(src, to: "rtf", [DocKeys.font: .string(family)], into: out), encoding: .ascii)
                try expect(rtf.contains("{\\f0\\fnil\\fcharset0 \(family);}"), "\(family): RTF font table")
            }
            try expectEqual(seen.count, 5, "five families give five different looks")
            // Automatic = the usual font of each format.
            let auto = try bodyFont(try await DocRun.convert(src, to: "pdf", [DocKeys.font: "auto"], into: out))
            try expect(auto.familyName == "Helvetica Neue", "automatic PDF font: \(auto.fontName)")
            let autoDocx = DocOracle.zipPart(try await DocRun.convert(src, to: "docx", into: out), "word/styles.xml")
            try expect(autoDocx.contains("w:ascii=\"Calibri\""), "automatic DOCX font")
        }

        docTest("doc.pdf.fontSize: the PDF text size, the DOCX half-points, the ODT points and the RTF \\fs follow the chosen size; bigger type means more pages", proves: ["doc.pdf.fontsize"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = try await longDocx(fx)
            var pages: [Int] = []
            for size in [8, 11, 16] {
                let pdf = try await DocRun.convert(src, to: "pdf", [DocKeys.fontSize: .int(size)], into: out)
                let doc = try unwrap(PDFDocument(url: pdf)); pages.append(doc.pageCount)
                let attr = try unwrap(doc.page(at: 1)?.attributedString)
                let r = try unwrap(attr.string.range(of: "the quick brown frog"), "body text on page 2")
                let f = try unwrap(attr.attribute(.font, at: attr.string.distance(from: attr.string.startIndex, to: r.lowerBound), effectiveRange: nil) as? NSFont)
                try expectClose(Double(f.pointSize), Double(size), tolerance: 0.1, "\(size) pt: the PDF text size")
                let dStyles = DocOracle.zipPart(try await DocRun.convert(src, to: "docx", [DocKeys.fontSize: .int(size)], into: out), "word/styles.xml")
                try expect(dStyles.contains("<w:sz w:val=\"\(size * 2)\"/>"), "\(size) pt: DOCX half-points")
                let oStyles = DocOracle.zipPart(try await DocRun.convert(src, to: "odt", [DocKeys.fontSize: .int(size)], into: out), "styles.xml")
                try expect(oStyles.contains("fo:font-size=\"\(String(format: "%.1f", Double(size)))pt\""), "\(size) pt: ODT")
                let rtf = try String(contentsOf: try await DocRun.convert(src, to: "rtf", [DocKeys.fontSize: .int(size)], into: out), encoding: .ascii)
                try expect(rtf.contains("\\f0\\fs\(size * 2)\n"), "\(size) pt: RTF")
            }
            try expect(pages[0] < pages[1] && pages[1] < pages[2], "bigger type, more pages: \(pages)")
        }

        docTest("doc.pdf.lineSpacing: the distance between baselines scales with the setting (PDF), and DOCX, ODT and RTF carry the same factor", proves: ["doc.pdf.spacing"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = try await longDocx(fx)
            func pitch(_ spacing: Double) async throws -> (Double, Int) {
                let doc = try unwrap(PDFDocument(url: try await DocRun.convert(src, to: "pdf", [DocKeys.lineSpacing: .double(spacing)], into: out)))
                let ls = lines(try unwrap(doc.page(at: 1))).sorted { $0.bounds.midY > $1.bounds.midY }
                var gaps: [Double] = []
                for i in 1..<min(ls.count, 12) { let g = Double(ls[i - 1].bounds.midY - ls[i].bounds.midY); if g > 4 && g < 60 { gaps.append(g) } }
                gaps.sort()
                return (gaps.isEmpty ? 0 : gaps[gaps.count / 2], doc.pageCount)
            }
            let (tight, tightPages) = try await pitch(1.0), (loose, loosePages) = try await pitch(2.0)
            try expect(tight > 8, "measured a baseline pitch: \(tight)")
            try expectClose(loose / tight, 2.0, tolerance: 0.2, "double spacing is about twice the pitch (\(tight) -> \(loose))")
            try expect(loosePages > tightPages, "looser lines need more pages")
            for ls in [1.0, 1.5, 2.0] {
                let dStyles = DocOracle.zipPart(try await DocRun.convert(src, to: "docx", [DocKeys.lineSpacing: .double(ls)], into: out), "word/styles.xml")
                try expect(dStyles.contains("w:line=\"\(Int(ls * 240))\""), "DOCX \(ls)")
                let oStyles = DocOracle.zipPart(try await DocRun.convert(src, to: "odt", [DocKeys.lineSpacing: .double(ls)], into: out), "styles.xml")
                try expect(oStyles.contains("fo:line-height=\"\(Int(ls * 100))%\""), "ODT \(ls)")
                let rtf = try String(contentsOf: try await DocRun.convert(src, to: "rtf", [DocKeys.lineSpacing: .double(ls)], into: out), encoding: .ascii)
                try expect(rtf.contains("\\sl\(Int(ls * 240))\\slmult1"), "RTF \(ls)")
            }
        }
    }

    // MARK: Metadata

    private static func registerMetadata() {
        docTest("doc.meta.mode: removing metadata leaves no author, title or date in DOCX, ODT, PDF, EPUB, HTML, RTF and Markdown; keeping carries them over",
                proves: ["doc.meta.mode"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "private.docx")
            // Keep.
            let kDocx = DocOracle.zipPart(try await DocRun.convert(docx, to: "docx", [DocKeys.metaMode: "keep"], into: out), "docProps/core.xml")
            try expect(kDocx.contains("<dc:title>Swamp report</dc:title>") && kDocx.contains("<dc:creator>Андрис Лейте</dc:creator>") && kDocx.contains("dcterms:created"), "DOCX keeps: \(kDocx)")
            let kOdt = DocOracle.zipPart(try await DocRun.convert(docx, to: "odt", [DocKeys.metaMode: "keep"], into: out), "meta.xml")
            try expect(kOdt.contains("<dc:title>Swamp report</dc:title>") && kOdt.contains("Андрис Лейте") && kOdt.contains("meta:creation-date"), "ODT keeps")
            let kPdf = try unwrap(PDFDocument(url: try await DocRun.convert(docx, to: "pdf", [DocKeys.metaMode: "keep"], into: out)))
            try expectEqual(kPdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Swamp report")
            try expectEqual(kPdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Андрис Лейте")
            try expect(kPdf.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] != nil, "PDF keeps a date")
            let kEpub = DocOracle.zipPart(try await DocRun.convert(docx, to: "epub", [DocKeys.metaMode: "keep"], into: out), "OEBPS/content.opf")
            try expect(kEpub.contains("<dc:creator>Андрис Лейте</dc:creator>") && !kEpub.contains("2000-01-01T00:00:00Z"), "EPUB keeps")
            let kHtml = try String(contentsOf: try await DocRun.convert(docx, to: "html", [DocKeys.metaMode: "keep"], into: out), encoding: .utf8)
            try expect(kHtml.contains("<meta name=\"author\" content=\"Андрис Лейте\"/>") && kHtml.contains("<title>Swamp report</title>"), "HTML keeps")
            let kRtf = try String(contentsOf: try await DocRun.convert(docx, to: "rtf", [DocKeys.metaMode: "keep"], into: out), encoding: .ascii)
            try expect(kRtf.contains("{\\title Swamp report}") && kRtf.contains("{\\author ") && kRtf.contains("{\\creatim"), "RTF keeps")
            // Remove.
            let sDocx = DocOracle.zipPart(try await DocRun.convert(docx, to: "docx", [DocKeys.metaMode: "strip"], into: out), "docProps/core.xml")
            try expect(!sDocx.contains("dc:title") && !sDocx.contains("dc:creator") && !sDocx.contains("dcterms:created") && !sDocx.contains("dcterms:modified") && !sDocx.contains("Андрис"), "DOCX removed: \(sDocx)")
            let sOdt = DocOracle.zipPart(try await DocRun.convert(docx, to: "odt", [DocKeys.metaMode: "strip"], into: out), "meta.xml")
            try expect(!sOdt.contains("dc:title") && !sOdt.contains("creator") && !sOdt.contains("date") && !sOdt.contains("Андрис"), "ODT removed: \(sOdt)")
            let sPdfURL = try await DocRun.convert(docx, to: "pdf", [DocKeys.metaMode: "strip"], into: out)
            let sPdf = try unwrap(PDFDocument(url: sPdfURL))
            let attrs = sPdf.documentAttributes ?? [:]
            try expect(attrs[PDFDocumentAttribute.titleAttribute] == nil && attrs[PDFDocumentAttribute.authorAttribute] == nil, "PDF has no title or author: \(attrs)")
            try expect(attrs[PDFDocumentAttribute.creationDateAttribute] == nil && attrs[PDFDocumentAttribute.modificationDateAttribute] == nil, "PDF has no dates: \(attrs)")
            let raw = try String(decoding: Data(contentsOf: sPdfURL), as: UTF8.self)
            try expect(!raw.contains("/CreationDate (") && !raw.contains("/ModDate (") && !raw.contains("macOS Version"), "the PDF info dictionary does not name the date or the macOS build")
            try expect(sPdf.pageCount >= 1 && sPdf.string?.contains("Болотный") == true, "the patched PDF still opens and reads")
            let sEpub = DocOracle.zipPart(try await DocRun.convert(docx, to: "epub", [DocKeys.metaMode: "strip"], into: out), "OEBPS/content.opf")
            try expect(!sEpub.contains("<dc:creator>") && !sEpub.contains("Андрис") && sEpub.contains("2000-01-01T00:00:00Z"), "EPUB removed (the mandatory modified date is a neutral constant): \(sEpub.prefix(500))")
            let sHtml = try String(contentsOf: try await DocRun.convert(docx, to: "html", [DocKeys.metaMode: "strip"], into: out), encoding: .utf8)
            try expect(!sHtml.contains("name=\"author\"") && !sHtml.contains("Андрис"), "HTML removed")
            let sRtf = try String(contentsOf: try await DocRun.convert(docx, to: "rtf", [DocKeys.metaMode: "strip"], into: out), encoding: .ascii)
            try expect(!sRtf.contains("\\author") && !sRtf.contains("\\creatim") && !sRtf.contains("{\\title"), "RTF removed")
            let sMd = try String(contentsOf: try await DocRun.convert(docx, to: "md", [DocKeys.metaMode: "strip", DocKeys.mdFrontMatter: true], into: out), encoding: .utf8)
            try expect(!sMd.contains("author:") && !sMd.contains("Андрис"), "Markdown front matter removed")
            // Typed title and author are inactive (reset) while metadata is removed.
            let typed = DocOracle.zipPart(try await DocRun.convert(docx, to: "docx", [DocKeys.metaMode: "strip", DocKeys.title: "Secret", DocKeys.author: "Me"], into: out), "docProps/core.xml")
            try expect(!typed.contains("Secret") && !typed.contains(">Me<"), "a typed title cannot leak through while removing metadata")
            // The global privacy layer does the same for a wheel run.
            let op = try DocRun.op("doc.to.pdf")
            try expectEqual(op.privacyOverrides().string(DocKeys.metaMode), "strip")
        }

        docTest("doc.meta.title, doc.meta.author, doc.meta.lang: typed values are written to every format that has such a field", proves: ["doc.meta.title", "doc.meta.author", "doc.meta.lang"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let md = try await DocFixtures.makeInput("md", in: fx, model: { var m = DocFixtures.sample(fx); m.meta = DocMeta(); return m }(), name: "plain.md")
            let o: OptionValues = [DocKeys.title: "Мой отчёт", DocKeys.author: "Žanis Ķirsis", DocKeys.language: "lv-LV"]
            let docx = try await DocRun.convert(md, to: "docx", o, into: out)
            let core = DocOracle.zipPart(docx, "docProps/core.xml")
            try expect(core.contains("<dc:title>Мой отчёт</dc:title>") && core.contains("<dc:creator>Žanis Ķirsis</dc:creator>"), "DOCX core: \(core)")
            try expect(DocOracle.zipPart(docx, "word/styles.xml").contains("w:lang w:val=\"lv-LV\""), "DOCX language")
            let odt = try await DocRun.convert(md, to: "odt", o, into: out)
            let meta = DocOracle.zipPart(odt, "meta.xml")
            try expect(meta.contains("<dc:title>Мой отчёт</dc:title>") && meta.contains("Žanis Ķirsis") && meta.contains("<dc:language>lv-LV</dc:language>"), "ODT meta")
            let pdf = try unwrap(PDFDocument(url: try await DocRun.convert(md, to: "pdf", o, into: out)))
            try expectEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Мой отчёт")
            try expectEqual(pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Žanis Ķirsis")
            let opf = DocOracle.zipPart(try await DocRun.convert(md, to: "epub", o, into: out), "OEBPS/content.opf")
            try expect(opf.contains("<dc:title>Мой отчёт</dc:title>") && opf.contains("<dc:creator>Žanis Ķirsis</dc:creator>") && opf.contains("<dc:language>lv-LV</dc:language>"), "EPUB package")
            let html = try String(contentsOf: try await DocRun.convert(md, to: "html", o, into: out), encoding: .utf8)
            try expect(html.contains("<title>Мой отчёт</title>") && html.contains("name=\"author\" content=\"Žanis Ķirsis\"") && html.contains("<html lang=\"lv-LV\">"), "HTML head")
            let rtf = try String(contentsOf: try await DocRun.convert(md, to: "rtf", o, into: out), encoding: .ascii)
            try expect(rtf.contains("{\\title \\u1052?"), "RTF title is escaped as Unicode: \(rtf.prefix(400))")
            let front = try String(contentsOf: try await DocRun.convert(md, to: "md", o.merged(over: [DocKeys.mdFrontMatter: true]), into: out), encoding: .utf8)
            try expect(front.contains("title: \"Мой отчёт\"") && front.contains("lang: \"lv-LV\""), "Markdown front matter")
            // Without typed values the document's own title is used, falling back to the first heading and then the file name.
            let plainHtml = try String(contentsOf: try await DocRun.convert(md, to: "html", into: out), encoding: .utf8)
            try expect(plainHtml.contains("<title>Болотный отчёт — Purvs 2026</title>"), "the first heading titles an untitled page")
        }
    }

    // MARK: Pictures

    private static func registerPictures() {
        docTest("doc.images: removing pictures drops them from every format and makes the file smaller; keeping them leaves them inside", proves: ["doc.images"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "pics.docx")
            let pictureBytes = DocFixtures.picture(fx).count
            for target in ["docx", "odt", "epub", "html", "pdf", "rtf"] {
                let keep = try await DocRun.convert(docx, to: target, [DocKeys.images: "keep"], into: out)
                let drop = try await DocRun.convert(docx, to: target, [DocKeys.images: "remove"], into: out)
                try expect(TestFile.size(keep) - TestFile.size(drop) > Int64(pictureBytes / 2), "\(target): keeping the picture costs its bytes (\(TestFile.size(keep)) vs \(TestFile.size(drop)))")
                switch target {
                case "docx": try expect(DocOracle.zipNames(keep).contains { $0.hasPrefix("word/media/") } && !DocOracle.zipNames(drop).contains { $0.hasPrefix("word/media/") }, "docx media parts")
                    try expect(!DocOracle.zipPart(drop, "word/document.xml").contains("<w:drawing>"), "no drawing element left")
                case "odt": try expect(DocOracle.zipNames(keep).contains { $0.hasPrefix("Pictures/") } && !DocOracle.zipNames(drop).contains { $0.hasPrefix("Pictures/") }, "odt pictures")
                case "epub": try expect(DocOracle.zipNames(keep).contains { $0.hasPrefix("OEBPS/images/") } && !DocOracle.zipNames(drop).contains { $0.hasPrefix("OEBPS/images/") }, "epub images")
                case "html": try expect(try String(contentsOf: keep, encoding: .utf8).contains("<img ") && !(try String(contentsOf: drop, encoding: .utf8).contains("<img ")), "html img")
                case "rtf": try expect(try String(contentsOf: keep, encoding: .ascii).contains("\\pngblip") && !(try String(contentsOf: drop, encoding: .ascii).contains("\\pngblip")), "rtf picture")
                default: break
                }
            }
            // The text is untouched.
            let t = DocOracle.text(of: try await DocRun.convert(docx, to: "pdf", [DocKeys.images: "remove"], into: out))
            try expect(DocOracle.firstMissing(DocFixtures.orderedTokens, in: t) == nil, "the words are all still there")
        }
    }
}
