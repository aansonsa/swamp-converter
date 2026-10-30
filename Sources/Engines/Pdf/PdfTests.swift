import Foundation
import PDFKit
import CoreGraphics
import ImageIO

enum PdfTests {
    static func register() {
        registerCatalogue()
        registerRendering()
        registerImages()
        registerText()
        registerStudio()
    }

    // MARK: Catalogue, schemas, presets

    private static func registerCatalogue() {
        // Structural acceptance (spec/wheel.md 11.6): one PDF -> Convert [DOCX, JPG, PNG, PPTX, TXT, MD, HTML, EPUB]; Tools [Split, Rotate, Optimize] (+ Merge for 2+).
        // Added by this engine: Tools "Extract pages" for every PDF and "Remove password" for protected ones; "Protect" is a Studio-only target.
        pdfTest("wheel contents for PDF files follow the catalogue order") {
            let reg = OperationRegistry()
            reg.register(PdfCatalog.operations())
            let one = [FileItem(url: URL(fileURLWithPath: "/tmp/a.pdf"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: one).map(\.id), ["pdf.to.docx", "pdf.to.jpg", "pdf.to.png", "pdf.to.pptx", "pdf.to.txt", "pdf.to.md", "pdf.to.html", "pdf.to.epub"])
            try expectEqual(reg.entries(wheel: .tools, items: one).map(\.id), ["pdf.split", "pdf.rotate", "pdf.optimize", "pdf.extract"])
            let two = one + [FileItem(url: URL(fileURLWithPath: "/tmp/b.pdf"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .tools, items: two).map(\.id).first, "pdf.merge")
            try expect(reg.studioTargets(for: one).map(\.id).contains("pdf.protect"), "pdf.protect is a Studio-only target")
            try expect(reg.studioTargets(for: one).map(\.id).contains("pdf.unlock"), "pdf.unlock is always a Studio target")
            try expect(reg.studioTargets(for: one).map(\.id).contains("pdf.extract"), "pdf.extract is a Studio target")
            try expect(!reg.entries(wheel: .tools, items: one).map(\.id).contains("pdf.protect"), "protect is not on the wheel")
        }

        pdfTest("the unlock slice appears on the wheel only for password protected PDFs") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let plain = try PdfFixtures.text(fx, "plain.pdf", pages: 1)
            let locked = fx.url("locked.pdf")
            try PdfProtection.protect(try unwrap(PDFDocument(url: plain)), openPassword: "s3cret", ownerPassword: "", allowPrint: true, allowCopy: true, allowEdit: true, to: locked)
            let reg = OperationRegistry()
            reg.register(PdfCatalog.operations())
            try expect(!reg.entries(wheel: .tools, items: FileItem.items([plain])).map(\.id).contains("pdf.unlock"), "not offered for a plain PDF")
            try expect(reg.entries(wheel: .tools, items: FileItem.items([locked])).map(\.id).contains("pdf.unlock"), "offered for a protected PDF")
            try expect(reg.entries(wheel: .tools, items: FileItem.items([plain, locked])).map(\.id).contains("pdf.unlock") == false, "all files must be protected")
        }

        pdfTest("tools.ocr takes images and PDFs, no folders, and is the last Tools slice") {
            let reg = OperationRegistry()
            reg.register(PdfCatalog.operations())
            reg.register(PdfCatalog.ocrOperations())
            let pdf = [FileItem(url: URL(fileURLWithPath: "/tmp/a.pdf"), isDirectory: false)]
            let png = [FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)]
            let folder = [FileItem(url: URL(fileURLWithPath: "/tmp/dir"), isDirectory: true)]
            try expectEqual(reg.entries(wheel: .tools, items: pdf).map(\.id).last, "tools.ocr")
            try expectEqual(reg.entries(wheel: .tools, items: png).map(\.id), ["tools.ocr"])
            try expect(reg.entries(wheel: .tools, items: folder).isEmpty, "no folders")
        }

        pdfTest("every schema builds without items, has unique keys, an oracle that a test proves, and clean defaults") {
            for id in PdfSchemas.allIDs {
                let schema = PdfSchemas.schema(id: id, items: [])
                try expectEqual(schema.id, id)
                let keys = schema.allFields.map(\.key)
                try expectEqual(Set(keys).count, keys.count, "duplicate keys in \(id)")
                for f in schema.allFields {
                    try expect(!f.oracle.isEmpty, "\(f.key) has no oracle")
                    try expect(PdfOracles.map[f.oracle] != nil, "the oracle \(f.oracle) of \(f.key) has no test (use pdfTest(..., proves:))")
                    try expect(!f.label.en.isEmpty && !f.label.ru.isEmpty, "\(f.key) lacks a label")
                }
                let resolved = schema.resolve(layers: [])
                let errors = resolved.messages.filter { $0.severity == .error }.map(\.id)
                try expect(errors.isEmpty || (id == PdfTargets.protect && errors == ["pdf.protect.nopassword"]), "defaults of \(id) are invalid: \(errors)")
            }
        }

        pdfTest("operations and their schemas agree; passwords are secret fields") {
            for op in PdfCatalog.operations() + PdfCatalog.ocrOperations() {
                let schema = op.optionSchema(for: [])
                try expectEqual(schema.id, op.meta.schemaID, "\(op.meta.id) must return the schema of its target")
                try expect(!schema.pages.isEmpty, "\(op.meta.id) has no option pages")
                // quick recipes only name keys the schema knows
                let known = Set(schema.allFields.map(\.key))
                for k in op.quickOverrides(settings: SettingsData()).keys { try expect(known.contains(k), "\(op.meta.id): quick key \(k) is not in the schema") }
            }
            for id in [PdfTargets.protect, PdfTargets.unlock] {
                let schema = PdfSchemas.schema(id: id, items: [])
                for key in [PdfKeys.openPassword, PdfKeys.ownerPassword] {
                    guard let f = schema.field(key) else { continue }
                    try expect(!f.persist, "\(key) must not be persisted")
                    if case .text(let spec) = f.kind { try expect(spec.secure, "\(key) must be a secure field") } else { throw TestFailure(message: "\(key) is not text", file: #fileID, line: #line) }
                }
            }
        }

        pdfTest("built-in presets only use keys of their schema, never a password, and resolve cleanly") {
            try expect(PdfPresets.builtins.count >= 10, "presets are registered")
            for p in PdfPresets.builtins {
                let schema = PdfSchemas.schema(id: p.targetID, items: [])
                for (k, _) in p.values.storage {
                    let f = try unwrap(schema.field(k), "preset \(p.id) names unknown key \(k)")
                    try expect(f.persist, "preset \(p.id) stores the secret \(k)")
                }
                let r = schema.resolve(layers: [p.values])
                let errors = r.messages.filter { $0.severity == .error }.map(\.id)
                try expect(errors.isEmpty || (p.targetID == PdfTargets.protect && errors == ["pdf.protect.nopassword"]), "preset \(p.id): \(errors)")
                try expect(!p.name.en.isEmpty && !p.name.ru.isEmpty)
            }
        }
    }

    // MARK: Rendering

    private static func registerRendering() {
        pdfTest("render size follows the DPI and the page's /Rotate, with the colours where a viewer shows them",
                proves: []) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let flat = try PdfFixtures.quadrants(fx, width: 300, height: 100)
            for (dpi, w, h) in [(72, 300, 100), (144, 600, 200), (300, 1250, 417)] {
                let img = try PdfRasterizer.renderPage(pdf: flat, pageIndex: 0, dpi: dpi)
                try expectEqual(img.width, w, "width at \(dpi) dpi"); try expectEqual(img.height, h, "height at \(dpi) dpi")
            }
            // spec trap 14: bounds ignore /Rotate; the canvas must be swapped for 90 and 270
            let expected: [Int: [RGBA]] = [   // TL, TR, BL, BR
                0: [.red, .green, .blue, .yellow], 90: [.blue, .red, .yellow, .green],
                180: [.yellow, .blue, .green, .red], 270: [.green, .yellow, .red, .blue]]
            for rot in [0, 90, 180, 270] {
                let doc = try unwrap(PDFDocument(url: flat))
                doc.page(at: 0)?.rotation = rot
                let u = fx.url("rot\(rot).pdf")
                try expect(doc.write(to: u))
                let img = try PdfRasterizer.renderPage(pdf: u, pageIndex: 0, dpi: 72)
                let swapped = rot == 90 || rot == 270
                try expectEqual(img.width, swapped ? 100 : 300, "rotated \(rot) width"); try expectEqual(img.height, swapped ? 300 : 100, "rotated \(rot) height")
                let w = img.width, h = img.height
                let got = [PdfFixtures.pixel(img, 4, 4), PdfFixtures.pixel(img, w - 5, 4), PdfFixtures.pixel(img, 4, h - 5), PdfFixtures.pixel(img, w - 5, h - 5)]
                for (i, c) in expected[rot]!.enumerated() { try expect(TestImage.close(got[i], c, tolerance: 70), "rotation \(rot): corner \(i) is \(got[i]) not \(c)") }
            }
        }

        pdfTest("the crop box is honoured") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let flat = try PdfFixtures.quadrants(fx, width: 300, height: 100)
            let doc = try unwrap(PDFDocument(url: flat))
            doc.page(at: 0)?.setBounds(CGRect(x: 150, y: 0, width: 150, height: 100), for: .cropBox)
            let u = fx.url("cropped.pdf")
            try expect(doc.write(to: u))
            let img = try PdfRasterizer.renderPage(pdf: u, pageIndex: 0, dpi: 72)
            try expectEqual(img.width, 150); try expectEqual(img.height, 100)
            try expect(TestImage.close(PdfFixtures.pixel(img, 4, 4), .green, tolerance: 70), "top-left of the right half is green")
            try expect(TestImage.close(PdfFixtures.pixel(img, 4, 95), .yellow, tolerance: 70), "bottom-left of the right half is yellow")
        }

        pdfTest("huge requests are lowered instead of exhausting memory") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let u = try PdfFixtures.quadrants(fx, width: 6000, height: 6000)
            let source = try unwrap(PDFDocument(url: u))
            let page = try PdfRasterizer.render(try unwrap(source.page(at: 0)), dpi: 1200, background: .white)
            try expect(page.width * page.height <= PdfRasterizer.maxPixels + 10_000, "pixels are capped")
            try expect(max(page.width, page.height) <= PdfRasterizer.maxSide, "side is capped")
        }
    }

    // MARK: Pages to images

    private static func registerImages() {
        pdfTest("pdf.to.png: one page gives one file, twelve pages a folder with zero-padded names",
                proves: ["pdf.raster.format", "pdf.raster.pages"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let one = try PdfFixtures.text(fx, "doc one.pdf", pages: 1)
            let r1 = try await PdfRun.run("pdf.to.png", [one], [PdfKeys.rasterDPI: 36])
            try expectEqual(r1.outputs.map(\.lastPathComponent), ["doc one.png"])
            try expectEqual(Array(TestFile.magic(r1.outputs[0], 4)), [0x89, 0x50, 0x4E, 0x47])
            let twelve = try PdfFixtures.text(fx, "twelve.pdf", pages: 12)
            let r12 = try await PdfRun.run("pdf.to.png", [twelve], [PdfKeys.rasterDPI: 36])
            try expectEqual(r12.outputs.map(\.lastPathComponent), ["twelve (pages)"])
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: r12.outputs[0].path)) ?? []).sorted()
            try expectEqual(names.count, 12)
            try expectEqual(names.first, "twelve - 01.png"); try expectEqual(names.last, "twelve - 12.png")
            let nine = try PdfFixtures.text(fx, "nine.pdf", pages: 9)
            let r9 = try await PdfRun.run("pdf.to.png", [nine], [PdfKeys.rasterDPI: 36])
            let n9 = ((try? FileManager.default.contentsOfDirectory(atPath: r9.outputs[0].path)) ?? []).sorted()
            try expectEqual(n9.first, "nine - 1.png"); try expectEqual(n9.last, "nine - 9.png")
            // page ranges: two of five pages -> a folder with exactly those; one of five -> a single numbered file
            let five = try PdfFixtures.text(fx, "five.pdf", pages: 5)
            let rr = try await PdfRun.run("pdf.to.png", [five], [PdfKeys.rasterDPI: 36, PdfKeys.pages: "2-3"])
            let rn = ((try? FileManager.default.contentsOfDirectory(atPath: rr.outputs[0].path)) ?? []).sorted()
            try expectEqual(rn, ["five - 2.png", "five - 3.png"])
            let rs = try await PdfRun.run("pdf.to.png", [five], [PdfKeys.rasterDPI: 36, PdfKeys.pages: "4"])
            try expectEqual(rs.outputs.map(\.lastPathComponent), ["five - 4.png"])
            // formats: jpeg, tiff, heic
            for (fmt, ext) in [("jpeg", "jpg"), ("tiff", "tiff"), ("heic", "heic")] {
                let r = try await PdfRun.run("pdf.to.png", [one], [PdfKeys.rasterFormat: .string(fmt), PdfKeys.rasterDPI: 36])
                let out = try unwrap(r.outputs.first)
                try expectEqual(out.pathExtension, ext)
                let magic = TestFile.magic(out, 12)
                switch fmt {
                case "jpeg": try expectEqual(Array(magic.prefix(3)), [0xFF, 0xD8, 0xFF])
                case "tiff": try expect(Array(magic.prefix(4)) == [0x49, 0x49, 0x2A, 0x00] || Array(magic.prefix(4)) == [0x4D, 0x4D, 0x00, 0x2A], "TIFF magic")
                default: try expectEqual(String(decoding: magic[4..<8], as: UTF8.self), "ftyp")
                }
                try expect(TestImage.size(of: out) != nil, "\(fmt) decodes")
            }
        }

        pdfTest("pdf.to.png: DPI sets the pixel size and the DPI tag; JPEG quality is monotonic in bytes",
                proves: ["pdf.raster.dpi", "pdf.raster.quality"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.photo(fx, "photo.pdf", pages: 1, pixels: 600)
            var sizes: [Int: Int] = [:]
            for dpi in [72, 144] {
                let r = try await PdfRun.run("pdf.to.png", [doc], [PdfKeys.rasterDPI: .int(dpi)])
                let info = try unwrap(TestImage.info(of: r.outputs[0]))
                try expectEqual(info.width, dpi == 72 ? 612 : 1224); try expectEqual(info.height, dpi == 72 ? 792 : 1584)
                try expectClose(info.dpiX ?? 0, Double(dpi), tolerance: 1, "DPI tag at \(dpi)")
                sizes[dpi] = Int(TestFile.size(r.outputs[0]))
            }
            try expect(sizes[144]! > sizes[72]!, "more pixels, more bytes")
            var bytes: [Int] = []
            for q in [20, 55, 95] {
                let r = try await PdfRun.run("pdf.to.jpg", [doc], [PdfKeys.rasterDPI: 72, PdfKeys.rasterQuality: .int(q)])
                bytes.append(Int(TestFile.size(r.outputs[0])))
            }
            try expect(bytes[0] < bytes[1] && bytes[1] < bytes[2], "JPEG bytes grow with quality: \(bytes)")
        }

        pdfTest("pdf.to.png: background, transparency, grayscale and annotations take effect",
                proves: ["pdf.raster.bg", "pdf.raster.alpha", "pdf.raster.gray", "pdf.raster.annots"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.blank(fx, "blank.pdf")
            func corner(_ extra: OptionValues, fmt: String = "png") async throws -> RGBA? {
                var e = extra; e[PdfKeys.rasterDPI] = 36; e[PdfKeys.rasterFormat] = .string(fmt)
                let r = try await PdfRun.run("pdf.to.png", [doc], e)
                return TestImage.pixel(of: r.outputs[0], x: 2, y: 2)
            }
            let paper = try await corner([:])
            try expect(TestImage.close(paper, .white, tolerance: 4), "default paper is white")
            let red = try await corner([PdfKeys.rasterBackground: "#FF0000"])
            try expect(TestImage.close(red, .red, tolerance: 6), "the background colour is used")
            let clear = try await corner([PdfKeys.rasterTransparent: true])
            try expectEqual(clear?.a, 0, "transparent PNG has no paper")
            let jpegClear = try await corner([PdfKeys.rasterTransparent: true], fmt: "jpeg")
            try expect(TestImage.close(jpegClear, .white, tolerance: 12), "JPEG cannot be transparent: the background is used")
            // grayscale on the colour card
            let card = try PdfFixtures.quadrants(fx, "card.pdf")
            let g = try await PdfRun.run("pdf.to.png", [card], [PdfKeys.rasterDPI: 36, PdfKeys.rasterGray: true])
            let p = try unwrap(TestImage.pixel(of: g.outputs[0], x: 4, y: 4))
            try expect(abs(Int(p.r) - Int(p.g)) <= 2 && abs(Int(p.g) - Int(p.b)) <= 2, "gray output has equal channels: \(p)")
            let colour = try await PdfRun.run("pdf.to.png", [card], [PdfKeys.rasterDPI: 36])
            let c = try unwrap(TestImage.pixel(of: colour.outputs[0], x: 4, y: 4))
            try expect(c.r > 200 && c.g < 80, "colour output keeps the red quadrant: \(c)")
            // annotations
            let annotated = try unwrap(PDFDocument(url: doc))
            let square = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 400, height: 400), forType: .square, withProperties: nil)
            square.color = .red; square.interiorColor = .red
            annotated.page(at: 0)?.addAnnotation(square)
            let annotatedURL = fx.url("annotated.pdf")
            try expect(annotated.write(to: annotatedURL))
            let withAnnots = try await PdfRun.run("pdf.to.png", [annotatedURL], [PdfKeys.rasterDPI: 36, PdfKeys.rasterAnnotations: true])
            let without = try await PdfRun.run("pdf.to.png", [annotatedURL], [PdfKeys.rasterDPI: 36, PdfKeys.rasterAnnotations: false])
            try expect(TestImage.close(TestImage.pixel(of: withAnnots.outputs[0], x: 20, y: 300), .red, tolerance: 40), "annotation is drawn")
            try expect(TestImage.close(TestImage.pixel(of: without.outputs[0], x: 20, y: 300), .white, tolerance: 12), "annotation is left out")
        }

        pdfTest("rasterize is rotation aware and cleans up after itself") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let flat = try PdfFixtures.quadrants(fx, width: 300, height: 100)
            let doc = try unwrap(PDFDocument(url: flat))
            doc.page(at: 0)?.rotation = 90
            let u = fx.url("turned.pdf")
            try expect(doc.write(to: u))
            let r = try await PdfRun.run("pdf.to.png", [u], [PdfKeys.rasterDPI: 72])
            try expectEqual(TestImage.size(of: r.outputs[0])?.width, 100)
            try expectEqual(TestImage.size(of: r.outputs[0])?.height, 300)
            try expect(TestFile.partials(in: fx.root).isEmpty, "no in-flight files are left")
        }
    }

    // MARK: Text

    private static func registerText() {
        pdfTest("extractText returns reading-order text per page; a picture-only PDF gives the scan message") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, pages: 2)
            let pages = try PdfRasterizer.extractText(pdf: doc)
            try expectEqual(pages.count, 2)
            try expect(pages[0].contains("Page 1") && pages[0].contains("Привет мир"), "page 1 text: \(pages[0])")
            try expectEqual(try PdfRasterizer.extractText(pdf: doc, pages: [1]).count, 1)
            let scan = try PdfFixtures.scan(fx, pages: [["Swamp"]])
            let err = try await expectThrows { _ = try PdfRasterizer.extractText(pdf: scan) }
            try expect(ConversionError.describe(err).lowercased().contains("scan") || ConversionError.describe(err).contains("скан"), "calm scan message: \(err)")
        }

        pdfTest("pdf.to.txt writes UTF-8 without BOM, pages separated by a blank line", proves: ["pdf.text.format", "pdf.text.pages.range"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "три страницы.pdf", pages: 3)
            let r = try await PdfRun.run("pdf.to.txt", [doc], [PdfKeys.ocr: false])
            try expectEqual(r.outputs.map(\.lastPathComponent), ["три страницы.txt"])
            let bytes = TestFile.magic(r.outputs[0], 3)
            try expect(bytes != [0xEF, 0xBB, 0xBF], "no BOM")
            let text = try String(contentsOf: r.outputs[0], encoding: .utf8)
            try expect(text.contains("Swamp 12345 Привет мир"), "Latin, digits and Cyrillic survive: \(text.prefix(120))")
            try expectEqual(text.components(separatedBy: "\n\n").count, 3, "three pages, two blank-line gaps")
            // page range: only page 2
            let part = try await PdfRun.run("pdf.to.txt", [doc], [PdfKeys.pages: "2", PdfKeys.ocr: false])
            let partText = try String(contentsOf: part.outputs[0], encoding: .utf8)
            try expect(partText.contains("Page 2") && !partText.contains("Page 1") && !partText.contains("Page 3"), "only page 2: \(partText)")
            // markdown: pages are separated by a rule
            let md = try await PdfRun.run("pdf.to.md", [doc], [PdfKeys.ocr: false])
            try expectEqual(md.outputs[0].pathExtension, "md")
            let mdText = try String(contentsOf: md.outputs[0], encoding: .utf8)
            try expectEqual(mdText.components(separatedBy: "\n\n---\n\n").count, 3, "a rule between pages")
        }

        pdfTest("pdf.to.txt: encodings, page separators and reflow are real", proves: ["pdf.text.encoding", "pdf.text.separators", "pdf.text.reflow"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "enc.pdf", pages: 2, word: { _ in "Привет" })
            func data(_ extra: OptionValues) async throws -> Data {
                var e = extra; e[PdfKeys.ocr] = false
                let r = try await PdfRun.run("pdf.to.txt", [doc], e)
                return try Data(contentsOf: r.outputs[0])
            }
            let bom = try await data([PdfKeys.textEncoding: "utf8bom"])
            try expectEqual(Array(bom.prefix(3)), [0xEF, 0xBB, 0xBF])
            let u16 = try await data([PdfKeys.textEncoding: "utf16"])
            try expect(u16.prefix(2) == Data([0xFF, 0xFE]) || u16.prefix(2) == Data([0xFE, 0xFF]), "UTF-16 BOM")
            try expect(String(data: u16, encoding: .utf16)?.contains("Привет") == true, "UTF-16 decodes")
            let cp = try await data([PdfKeys.textEncoding: "cp1251"])
            try expect(cp.contains(0xCF), "П is 0xCF in Windows-1251")
            try expect(String(data: cp, encoding: .windowsCP1251)?.contains("Привет") == true, "cp1251 decodes")
            let marker = String(decoding: try await data([PdfKeys.textSeparators: "marker"]), as: UTF8.self)
            try expect(marker.contains("--- Page 1 ---") || marker.contains("--- Страница 1 ---"), "page marker line: \(marker)")
            let ff = String(decoding: try await data([PdfKeys.textSeparators: "formfeed"]), as: UTF8.self)
            try expect(ff.contains("\u{0C}"), "form feed between pages")
            let none = String(decoding: try await data([PdfKeys.textSeparators: "none"]), as: UTF8.self)
            try expect(!none.contains("\n\n"), "no blank line with separator none")
            // reflow: wrapped lines become paragraphs
            let wrapped = "This is a long first line of a paragraph that wraps hy-\nphenated across two lines of the same long paragraph and\nends with a short last line.\n\nNext paragraph starts here."
            let flowed = PdfMarkdown.paragraphs(from: wrapped)
            try expectEqual(flowed.count, 2)
            try expect(flowed[0].contains("hyphenated across") && !flowed[0].contains("hy-"), "de-hyphenated: \(flowed[0])")
            try expectEqual(PdfMarkdown.join("a-", "B"), "a- B", "a capital after the dash keeps the dash")
            try expectEqual(PdfMarkdown.join("well-", "known"), "wellknown")
            try expectEqual(PdfMarkdown.join("end", "next"), "end next")
            let pages = [PdfPageText(number: 1, text: "line one\nline two")]
            try expectEqual(PdfMarkdown.plain(pages: pages, separators: "auto", reflow: true), "line one line two")
            try expectEqual(PdfMarkdown.plain(pages: pages, separators: "auto", reflow: false), "line one\nline two")
            try expect(PdfMarkdown.markdown(pages: pages, separators: "auto", reflow: false).contains("line one  \n"), "hard line breaks in Markdown")
        }

        pdfTest("pdf.to.txt: layout mode uses pdftotext", proves: ["pdf.text.layout"], requires: ["tool.pdftotext"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "layout.pdf", pages: 2)
            let r = try await PdfRun.run("pdf.to.txt", [doc], [PdfKeys.textLayout: true, PdfKeys.ocr: false])
            let text = try String(contentsOf: r.outputs[0], encoding: .utf8)
            try expect(text.contains("Swamp 12345") && text.contains("Page 2"), "layout text has both pages: \(text.prefix(200))")
        }

        pdfTest("pdf.to.docx / html / epub hand Markdown to the document writer", proves: ["pdf.export.format", "pdf.export.pages", "pdf.export.separators", "pdf.export.reflow", "pdf.export.ocr", "pdf.text.ocr"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "export.pdf", pages: 2)
            // The Markdown that is handed over (pure).
            let pages = [PdfPageText(number: 1, text: "First page"), PdfPageText(number: 2, text: "Second page")]
            let rule = PdfMarkdown.markdown(pages: pages, separators: "auto", reflow: true)
            try expect(rule.contains("First page\n\n---\n\nSecond page"), "rule between pages")
            let heads = PdfMarkdown.markdown(pages: pages, separators: "marker", reflow: true)
            try expect(heads.contains("## Page 1") || heads.contains("## Страница 1"), "page headings")
            // The real files (needs the documents module's writer).
            do {
                let r = try await PdfRun.run("pdf.to.html", [doc], [PdfKeys.pages: "1"])
                let html = try String(contentsOf: r.outputs[0], encoding: .utf8)
                try expect(html.contains("Swamp 12345") && html.contains("Привет"), "html has the text")
                try expect(!html.contains("Page 2"), "only the chosen page")
                let docx = try await PdfRun.run("pdf.to.docx", [doc])
                try expect(TestFile.magicString(docx.outputs[0], 2) == "PK", "docx is a zip")
                let epub = try await PdfRun.run("pdf.to.epub", [doc])
                try expect(TestFile.magicString(epub.outputs[0], 2) == "PK", "epub is a zip")
            } catch let e as ConversionError {
                if case .unsupported = e { try skipTest("the documents module's writer is not available yet: \(e.errorDescription ?? "")") }
                throw e
            }
        }
    }

    // MARK: Probe, validation, estimates, naming

    private static func registerStudio() {
        pdfTest("the probe reports pages, paper, text, scans and protection") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let text = try PdfFixtures.text(fx, "t.pdf", pages: 4)
            let info = await PdfSourceProbe().probe(FileItem(url: text))
            try expectEqual(info.int("pdf.pages"), 4); try expectEqual(info.bool("pdf.hasText"), true); try expectEqual(info.bool("pdf.encrypted"), false)
            try expectEqual(info.string("pdf.paper"), "Letter")
            try expectClose(info.number("pdf.width") ?? 0, 612, tolerance: 1)
            try expect(info.chips.contains { $0.text.contains("4") }, "page count chip")
            try expect(info.warnings.isEmpty, "a text PDF has no warning")
            let scan = try PdfFixtures.scan(fx, pages: [["Swamp"]])
            let scanInfo = await PdfSourceProbe().probe(FileItem(url: scan))
            try expectEqual(scanInfo.bool("pdf.hasText"), false)
            try expect(scanInfo.warnings.contains { $0.en.contains("pictures with no text") }, "scan warning (PDF1)")
            let locked = fx.url("l.pdf")
            try PdfProtection.protect(try unwrap(PDFDocument(url: text)), openPassword: "pw", ownerPassword: "", allowPrint: true, allowCopy: true, allowEdit: true, to: locked)
            let lockedInfo = await PdfSourceProbe().probe(FileItem(url: locked))
            try expectEqual(lockedInfo.bool("pdf.encrypted"), true); try expectEqual(lockedInfo.bool("pdf.locked"), true)
            let rotated = try unwrap(PDFDocument(url: text)); rotated.page(at: 0)?.rotation = 90
            let ru = fx.url("r.pdf"); try expect(rotated.write(to: ru))
            let rInfo = await PdfSourceProbe().probe(FileItem(url: ru))
            try expectClose(rInfo.number("pdf.width") ?? 0, 792, tolerance: 1, "the probe reports the displayed (rotated) size")
        }

        pdfTest("validation: ranges beyond the page count are errors, scans and rasterising warn") {
            var src = SourceInfo(url: URL(fileURLWithPath: "/tmp/a.pdf"), kind: .pdf)
            src.facts["pdf.pages"] = .int(3); src.facts["pdf.hasText"] = .bool(true)
            let op = try PdfRun.op("pdf.to.png")
            let schema = op.optionSchema(for: [])
            let bad = schema.resolve(layers: [[PdfKeys.pages: "2-9"]], source: src).values
            try expect(op.validate(options: bad, source: src).contains { $0.id == "pdf.range.beyond" }, "page 9 does not exist")
            let ok = schema.resolve(layers: [[PdfKeys.pages: "2-3"]], source: src).values
            try expect(op.validate(options: ok, source: src).isEmpty, "2-3 is fine")
            let optimize = try PdfRun.op("pdf.optimize")
            let raster = optimize.optionSchema(for: []).resolve(layers: [[PdfKeys.mode: "raster"]], source: src).values
            try expect(optimize.validate(options: raster, source: src).contains { $0.id == "pdf.optimize.pixels" }, "warns that the text becomes pixels")
            var scan = src; scan.facts["pdf.hasText"] = .bool(false)
            let txt = try PdfRun.op("pdf.to.txt")
            let off = txt.optionSchema(for: []).resolve(layers: [[PdfKeys.ocr: false]], source: scan).values
            try expect(txt.validate(options: off, source: scan).contains { $0.id == "pdf.text.scan" }, "warns about a scan without recognition")
        }

        pdfTest("estimates are cheap, positive and move with the options") {
            var src = SourceInfo(url: URL(fileURLWithPath: "/tmp/a.pdf"), kind: .pdf)
            src.facts["pdf.pages"] = .int(10); src.facts["pdf.width"] = .double(595); src.facts["pdf.height"] = .double(842); src.facts["size"] = .double(5_000_000)
            let op = try PdfRun.op("pdf.to.png")
            let schema = op.optionSchema(for: [])
            func bytes(_ dpi: Int) -> Int64 {
                let v = schema.resolve(layers: [[PdfKeys.rasterDPI: .int(dpi)]], source: src).values
                return op.estimate(options: v, items: [], source: src)?.bytes ?? 0
            }
            try expect(bytes(300) > bytes(150) && bytes(150) > 0, "more DPI, bigger estimate")
            let optimize = try PdfRun.op("pdf.optimize")
            let os = optimize.optionSchema(for: [])
            let screen = optimize.estimate(options: os.resolve(layers: [[PdfKeys.level: "screen"]], source: src).values, items: [], source: src)?.bytes ?? 0
            let high = optimize.estimate(options: os.resolve(layers: [[PdfKeys.level: "high"]], source: src).values, items: [], source: src)?.bytes ?? 0
            try expect(screen > 0 && screen < high, "screen is smaller than high")
            let t0 = Date()
            for _ in 0..<200 { _ = op.estimate(options: schema.defaults(), items: [], source: src) }
            try expect(Date().timeIntervalSince(t0) < 0.5, "estimates are cheap")
        }

        pdfTest("names with spaces, unicode, dots and a leading dash; existing outputs get (2); read-only folders fail cleanly") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let url = try PdfFixtures.text(fx, "-Отчёт v2.1 final.pdf", pages: 1)
            let first = try await PdfRun.run("pdf.to.txt", [url], [PdfKeys.ocr: false])
            try expectEqual(first.outputs.map(\.lastPathComponent), ["-Отчёт v2.1 final.txt"])
            let second = try await PdfRun.run("pdf.to.txt", [url], [PdfKeys.ocr: false])
            try expectEqual(second.outputs.map(\.lastPathComponent), ["-Отчёт v2.1 final (2).txt"])
            try expect(TestFile.partials(in: fx.root).isEmpty)
            // a read-only folder
            let ro = try fx.makeDirectory("readonly")
            let inside = ro.appendingPathComponent("a.pdf")
            try FileManager.default.copyItem(at: url, to: inside)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
            let err = try await expectThrows { _ = try await PdfRun.run("pdf.to.txt", [inside], [PdfKeys.ocr: false]) }
            try expect(!ConversionError.describe(err).isEmpty, "a calm message: \(err)")
            try expect(TestFile.partials(in: ro).isEmpty, "nothing half-written")
        }

        pdfTest("a damaged file gets the calm 'Cannot open PDF' message", timeout: 60) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let bad = try fx.text("broken.pdf", "this is not a pdf")
            let err = try await expectThrows { _ = try await PdfRun.run("pdf.to.txt", [bad]) }
            try expect(ConversionError.describe(err).contains("broken.pdf"), "names the file: \(err)")
        }

        pdfTest("cancelling a long job is quick and leaves nothing behind", timeout: 120) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let big = try PdfFixtures.text(fx, "long.pdf", pages: 60)
            let task = Task { @MainActor in try await PdfRun.run("pdf.to.png", [big], [PdfKeys.rasterDPI: 300]) }
            try await Task.sleep(nanoseconds: 300_000_000)
            let t0 = Date()
            task.cancel()
            let result = await task.result
            let elapsed = Date().timeIntervalSince(t0)
            if case .success = result { throw TestFailure(message: "the job finished before it could be cancelled", file: #fileID, line: #line) }
            if case .failure(let e) = result { try expect(e is CancellationError, "cancellation propagates: \(e)") }
            try expect(elapsed < 1.5, "cancelled within \(elapsed) s")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []
            try expectEqual(left.filter { $0 != "long.pdf" }, [], "no folder, no partials")
        }
    }
}
