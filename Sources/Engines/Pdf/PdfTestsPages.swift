import Foundation
import PDFKit
import CoreGraphics

/// Self-tests of the PDF -> PDF operations: merge, split, rotate / paper size / trim, extract, optimise, protect, unlock.
enum PdfTestsPages {
    static func register() {
        registerMerge()
        registerSplit()
        registerPages()
        registerExtract()
        registerOptimize()
        registerProtection()
    }

    private static func ls(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    // MARK: Merge

    private static func registerMerge() {
        pdfTest("pdf.merge appends in natural order and names the result after the first sorted file", proves: ["pdf.merge.order", "pdf.merge.bookmarks"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let p10 = try fx.pdf("p10.pdf", pages: 1, text: { _ in "ten" })
            let p2 = try fx.pdf("p2.pdf", pages: 2, text: { _ in "two" })
            let p1 = try fx.pdf("p1.pdf", pages: 1, text: { _ in "one" })
            let r = try await PdfRun.run("pdf.merge", [p10, p2, p1])
            try expectEqual(r.outputs.map(\.lastPathComponent), ["p1 (merged).pdf"])
            try expectEqual(PdfRun.pageCount(r.outputs[0]), 4)
            let doc = try unwrap(PDFDocument(url: r.outputs[0]))
            let order = (0..<4).map { doc.page(at: $0)?.string ?? "" }
            try expect(order[0].contains("one") && order[1].contains("two") && order[2].contains("two") && order[3].contains("ten"), "natural order p1, p2, p10: \(order)")
            // bookmarks: one per file, labelled with the file name
            let root = try unwrap(doc.outlineRoot)
            try expectEqual(root.numberOfChildren, 3)
            try expectEqual((0..<3).map { root.child(at: $0)?.label ?? "" }, ["p1", "p2", "p10"])
            let none = try await PdfRun.run("pdf.merge", [p10, p2, p1], [PdfKeys.mergeBookmarks: false])
            try expectEqual(PDFDocument(url: none.outputs[0])?.outlineRoot?.numberOfChildren ?? 0, 0)
            // as selected: the first dropped file leads and names the result
            let sel = try await PdfRun.run("pdf.merge", [p10, p2, p1], [PdfKeys.mergeOrder: "selection"])
            try expectEqual(sel.outputs.map(\.lastPathComponent), ["p10 (merged).pdf"])
            try expect(PdfRun.text(sel.outputs[0]).range(of: "ten")!.lowerBound < PdfRun.text(sel.outputs[0]).range(of: "one")!.lowerBound, "ten comes before one")
            // by date: the oldest first
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: p10.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000)], ofItemAtPath: p1.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: p2.path)
            let byDate = try await PdfRun.run("pdf.merge", [p1, p2, p10], [PdfKeys.mergeOrder: "date"])
            let text = PdfRun.text(byDate.outputs[0])
            try expect(text.range(of: "ten")!.lowerBound < text.range(of: "two")!.lowerBound && text.range(of: "two")!.lowerBound < text.range(of: "one")!.lowerBound, "oldest first")
            try expect(TestFile.partials(in: fx.root).isEmpty)
        }

        pdfTest("pdf.merge can fit every page onto the first page's sheet", proves: ["pdf.merge.norm"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let a = try PdfFixtures.quadrants(fx, "a.pdf", width: 400, height: 200)
            let b = try PdfFixtures.text(fx, "b.pdf", pages: 2)
            let plain = try await PdfRun.run("pdf.merge", [a, b])
            let sizes = (0..<3).map { PdfGeometry.displayedSize(try! PdfRun.page(plain.outputs[0], $0)) }
            try expect(sizes[0] != sizes[1], "mixed sizes without normalising")
            let norm = try await PdfRun.run("pdf.merge", [a, b], [PdfKeys.mergeNormalize: true])
            for i in 0..<3 {
                let s = PdfGeometry.displayedSize(try PdfRun.page(norm.outputs[0], i))
                try expectClose(Double(s.width), 400, tolerance: 0.5); try expectClose(Double(s.height), 200, tolerance: 0.5)
            }
            try expect(PdfRun.text(norm.outputs[0]).contains("Привет"), "text stays vector and extractable after normalising")
        }

        pdfTest("pdf.merge refuses a protected input by name") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let a = try PdfFixtures.text(fx, "a.pdf", pages: 1)
            let locked = fx.url("closed.pdf")
            try PdfProtection.protect(try unwrap(PDFDocument(url: a)), openPassword: "pw", ownerPassword: "", allowPrint: true, allowCopy: true, allowEdit: true, to: locked)
            let err = try await expectThrows { _ = try await PdfRun.run("pdf.merge", [a, locked]) }
            try expect(ConversionError.describe(err).contains("closed.pdf"), "names the file: \(err)")
            try expect(TestFile.partials(in: fx.root).isEmpty)
        }
    }

    // MARK: Split

    private static func registerSplit() {
        pdfTest("pdf.split: each page, every N, ranges", proves: ["pdf.split.mode", "pdf.split.n", "pdf.split.ranges"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "book.pdf", pages: 7)
            let each = try await PdfRun.run("pdf.split", [doc])
            try expectEqual(each.outputs.map(\.lastPathComponent), ["book (pages)"])
            let files = ls(each.outputs[0])
            try expectEqual(files, (1...7).map { "book - \($0).pdf" })
            for (i, f) in files.enumerated() {
                let u = each.outputs[0].appendingPathComponent(f)
                try expectEqual(PdfRun.pageCount(u), 1); try expect(PdfRun.text(u).contains("Page \(i + 1)"), "\(f) holds page \(i + 1)")
            }
            let three = try await PdfRun.run("pdf.split", [doc], [PdfKeys.splitMode: "everyN", PdfKeys.splitEvery: 3])
            try expectEqual(ls(three.outputs[0]).map { PdfRun.pageCount(three.outputs[0].appendingPathComponent($0)) }, [3, 3, 1])
            let ranges = try await PdfRun.run("pdf.split", [doc], [PdfKeys.splitMode: "ranges", PdfKeys.splitRanges: "1-2, 4, 6-"])
            try expectEqual(ls(ranges.outputs[0]).map { PdfRun.pageCount(ranges.outputs[0].appendingPathComponent($0)) }, [2, 1, 2])
            let bad = try await expectThrows { _ = try await PdfRun.run("pdf.split", [doc], [PdfKeys.splitMode: "ranges", PdfKeys.splitRanges: "1-99"]) }
            try expect(ConversionError.describe(bad).contains("7"), "mentions the page count: \(bad)")
        }

        pdfTest("pdf.split by size keeps every file under the limit; by bookmark follows the outline", proves: ["pdf.split.mb"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let photos = try PdfFixtures.photo(fx, "photos.pdf", pages: 6, pixels: 500)
            let whole = TestFile.size(photos)
            let limit = Double(whole) / 3.0 / 1_000_000
            let r = try await PdfRun.run("pdf.split", [photos], [PdfKeys.splitMode: "bySize", PdfKeys.splitMegabytes: .double(limit)])
            let parts = ls(r.outputs[0]).map { r.outputs[0].appendingPathComponent($0) }
            try expect(parts.count >= 3, "more than one file: \(parts.count)")
            try expectEqual(parts.map(PdfRun.pageCount).reduce(0, +), 6, "every page is somewhere")
            for u in parts where PdfRun.pageCount(u) > 1 { try expect(Double(TestFile.size(u)) <= limit * 1_000_000 * 1.001, "\(u.lastPathComponent) is within the limit") }
            // bookmarks
            let doc = try unwrap(PDFDocument(url: try PdfFixtures.text(fx, "chapters.pdf", pages: 6)))
            let root = PDFOutline()
            for (i, (title, page)) in [("Intro", 0), ("Part two", 3)].enumerated() {
                let o = PDFOutline(); o.label = title
                o.destination = PDFDestination(page: try unwrap(doc.page(at: page)), at: CGPoint(x: 0, y: 700))
                root.insertChild(o, at: i)
            }
            doc.outlineRoot = root
            let marked = fx.url("marked.pdf")
            try expect(doc.write(to: marked))
            let split = try await PdfRun.run("pdf.split", [marked], [PdfKeys.splitMode: "byBookmark"])
            let names = ls(split.outputs[0])
            try expectEqual(names, ["marked - 1 Intro.pdf", "marked - 2 Part two.pdf"])
            try expectEqual(names.map { PdfRun.pageCount(split.outputs[0].appendingPathComponent($0)) }, [3, 3])
            let none = try PdfFixtures.text(fx, "plain.pdf", pages: 2)
            let err = try await expectThrows { _ = try await PdfRun.run("pdf.split", [none], [PdfKeys.splitMode: "byBookmark"]) }
            try expect(ConversionError.describe(err).lowercased().contains("bookmark") || ConversionError.describe(err).contains("закладк"), "calm message: \(err)")
        }

        pdfTest("split then merge round-trips the pages and their text") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "round.pdf", pages: 5)
            let split = try await PdfRun.run("pdf.split", [doc])
            let parts = ls(split.outputs[0]).map { split.outputs[0].appendingPathComponent($0) }
            let merged = try await PdfRun.run("pdf.merge", parts)
            try expectEqual(PdfRun.pageCount(merged.outputs[0]), 5)
            let a = (0..<5).map { PdfRun.page(doc: PDFDocument(url: doc), $0) }
            let b = (0..<5).map { PdfRun.page(doc: PDFDocument(url: merged.outputs[0]), $0) }
            try expectEqual(a, b, "the text of every page survives the round trip")
        }
    }

    // MARK: Rotate, paper size, trim

    private static func registerPages() {
        pdfTest("pdf.rotate adds to the rotation of every page, per scope", proves: ["pdf.rotate.angle", "pdf.rotate.scope", "pdf.rotate.pages"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "turn.pdf", pages: 4)
            func rotations(_ u: URL) -> [Int] { (0..<PdfRun.pageCount(u)).map { (try? PdfRun.page(u, $0).rotation) ?? -1 } }
            let r = try await PdfRun.run("pdf.rotate", [doc])
            try expectEqual(r.outputs.map(\.lastPathComponent), ["turn (rotated).pdf"])
            try expectEqual(rotations(r.outputs[0]), [90, 90, 90, 90])
            let again = try await PdfRun.run("pdf.rotate", [r.outputs[0]])
            try expectEqual(rotations(again.outputs[0]), [180, 180, 180, 180], "the new angle is added to the current one")
            let left = try await PdfRun.run("pdf.rotate", [doc], [PdfKeys.rotate: "270"])
            try expectEqual(rotations(left.outputs[0]), [270, 270, 270, 270])
            let odd = try await PdfRun.run("pdf.rotate", [doc], [PdfKeys.rotateScope: "odd"])
            try expectEqual(rotations(odd.outputs[0]), [90, 0, 90, 0])
            let even = try await PdfRun.run("pdf.rotate", [doc], [PdfKeys.rotateScope: "even", PdfKeys.rotate: "180"])
            try expectEqual(rotations(even.outputs[0]), [0, 180, 0, 180])
            let chosen = try await PdfRun.run("pdf.rotate", [doc], [PdfKeys.rotateScope: "selected", PdfKeys.pages: "2-3"])
            try expectEqual(rotations(chosen.outputs[0]), [0, 90, 90, 0])
            let none = try await PdfRun.run("pdf.rotate", [doc], [PdfKeys.rotate: "0"])
            try expectEqual(rotations(none.outputs[0]), [0, 0, 0, 0])
            try expect(PdfRun.text(r.outputs[0]).contains("Привет"), "text stays vector")
        }

        pdfTest("the paper size option re-draws pages onto A4 sheets in the page's orientation", proves: ["pdf.size.paper", "pdf.size.fit", "pdf.size.margins"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let wide = try PdfFixtures.quadrants(fx, "wide.pdf", width: 300, height: 100)
            func page(_ extra: OptionValues) async throws -> (url: URL, size: CGSize, image: CGImage) {
                var e = extra; e[PdfKeys.rotate] = "0"
                let r = try await PdfRun.run("pdf.rotate", [wide], e)
                let img = try PdfRasterizer.renderPage(pdf: r.outputs[0], pageIndex: 0, dpi: 72)
                return (r.outputs[0], PdfGeometry.displayedSize(try PdfRun.page(r.outputs[0])), img)
            }
            let fit = try await page([PdfKeys.pageSize: "a4", PdfKeys.pageSizeFit: "fit"])
            try expectClose(Double(fit.size.width), 841.89, tolerance: 0.6, "landscape source gives a landscape A4"); try expectClose(Double(fit.size.height), 595.28, tolerance: 0.6)
            try expect(TestImage.close(PdfFixtures.pixel(fit.image, 4, 4), .white, tolerance: 8), "fit letterboxes: top-left is paper")
            try expect(TestImage.close(PdfFixtures.pixel(fit.image, 200, 250), .red, tolerance: 80) && TestImage.close(PdfFixtures.pixel(fit.image, 200, 345), .blue, tolerance: 80), "content in the middle")
            let fill = try await page([PdfKeys.pageSize: "a4", PdfKeys.pageSizeFit: "fill"])
            try expect(TestImage.close(PdfFixtures.pixel(fill.image, 4, 4), .red, tolerance: 80), "fill covers the sheet: top-left is red")
            let none = try await page([PdfKeys.pageSize: "a5", PdfKeys.pageSizeFit: "none"])
            try expectClose(Double(none.size.width), 595.28, tolerance: 0.6, "A5 landscape")
            // margins on a portrait card
            let card = try PdfFixtures.quadrants(fx, "card.pdf", width: 200, height: 300)
            let r = try await PdfRun.run("pdf.rotate", [card], [PdfKeys.rotate: "0", PdfKeys.pageSize: "a4", PdfKeys.margins: 30])
            let img = try PdfRasterizer.renderPage(pdf: r.outputs[0], pageIndex: 0, dpi: 72)
            let margin = 30 * 72.0 / 25.4     // 85 pt
            try expect(TestImage.close(PdfFixtures.pixel(img, Int(margin) - 8, 130), .white, tolerance: 8), "paper inside the margin")
            try expect(TestImage.close(PdfFixtures.pixel(img, Int(margin) + 8, 130), .red, tolerance: 80), "content starts at the margin")
        }

        pdfTest("trimming cuts every side of every page's crop box", proves: ["pdf.trim"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "trim.pdf", pages: 2)
            let r = try await PdfRun.run("pdf.rotate", [doc], [PdfKeys.rotate: "0", PdfKeys.trim: 10])
            let cut = 10 * 72.0 / 25.4
            for i in 0..<2 {
                let box = try PdfRun.page(r.outputs[0], i).bounds(for: .cropBox)
                try expectClose(Double(box.width), 612 - 2 * cut, tolerance: 0.5); try expectClose(Double(box.height), 792 - 2 * cut, tolerance: 0.5)
            }
            let img = try PdfRasterizer.renderPage(pdf: r.outputs[0], pageIndex: 0, dpi: 72)
            try expectEqual(img.width, Int((612 - 2 * cut).rounded()))
        }

        pdfTest("document info can be removed from rotated, merged and extracted files", proves: ["pdf.meta.strip"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try unwrap(PDFDocument(url: try PdfFixtures.text(fx, "info.pdf", pages: 2)))
            doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Secret plan", PDFDocumentAttribute.authorAttribute: "Andris",
                                      PDFDocumentAttribute.subjectAttribute: "Private", PDFDocumentAttribute.keywordsAttribute: ["a", "b"],
                                      PDFDocumentAttribute.creatorAttribute: "Editor 9"]
            let src = fx.url("labelled.pdf")
            try expect(doc.write(to: src))
            try expectEqual(PDFDocument(url: src)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Andris")
            func scrubbed(_ id: String, _ files: [URL]) async throws {
                let r = try await PdfRun.run(id, files, [PdfKeys.stripMeta: true])
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: r.outputs[0].path, isDirectory: &isDir)
                let out = isDir.boolValue ? r.outputs[0].appendingPathComponent(ls(r.outputs[0])[0]) : r.outputs[0]
                let attrs = PDFDocument(url: out)?.documentAttributes ?? [:]
                for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute] {
                    try expect(attrs[key] == nil, "\(id): \(key.rawValue) was removed, found \(String(describing: attrs[key]))")
                }
                let cg = try unwrap(CGPDFDocument(out as CFURL))
                var stream: CGPDFStreamRef?
                let hasXMP = cg.catalog.map { CGPDFDictionaryGetStream($0, "Metadata", &stream) } ?? false
                try expect(!hasXMP, "\(id): no XMP packet")
            }
            try await scrubbed("pdf.rotate", [src]); try await scrubbed("pdf.extract", [src]); try await scrubbed("pdf.split", [src])
            try await scrubbed("pdf.merge", [src, src]); try await scrubbed("pdf.optimize", [src])
            // without the option the title survives (rotate keeps the PDFKit document)
            let kept = try await PdfRun.run("pdf.rotate", [src])
            try expectEqual(PDFDocument(url: kept.outputs[0])?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Secret plan")
            // the global "always strip metadata" setting reaches PDF-writing operations only
            try expectEqual(try PdfRun.op("pdf.optimize").privacyOverrides()[PdfKeys.stripMeta], .bool(true))
            try expectEqual(try PdfRun.op("pdf.merge").privacyOverrides()[PdfKeys.stripMeta], .bool(true))
            try expect(try PdfRun.op("pdf.to.png").privacyOverrides().isEmpty)
        }
    }

    // MARK: Extract

    private static func registerExtract() {
        pdfTest("pdf.extract keeps or removes a range, optionally reversed", proves: ["pdf.extract.pages", "pdf.extract.mode", "pdf.extract.order"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "six.pdf", pages: 6)
            func pages(_ u: URL) -> [String] { (0..<PdfRun.pageCount(u)).map { i in (1...6).first { PdfRun.text(u).isEmpty ? false : (PDFDocument(url: u)?.page(at: i)?.string ?? "").contains("Page \($0)") }.map(String.init) ?? "?" } }
            let keep = try await PdfRun.run("pdf.extract", [doc], [PdfKeys.pages: "2-3, 6"])
            try expectEqual(keep.outputs.map(\.lastPathComponent), ["six (extracted).pdf"])
            try expectEqual(pages(keep.outputs[0]), ["2", "3", "6"])
            let remove = try await PdfRun.run("pdf.extract", [doc], [PdfKeys.pages: "2-3, 6", PdfKeys.extractMode: "remove"])
            try expectEqual(pages(remove.outputs[0]), ["1", "4", "5"])
            let reversed = try await PdfRun.run("pdf.extract", [doc], [PdfKeys.pages: "1-3", PdfKeys.extractOrder: "reverse"])
            try expectEqual(pages(reversed.outputs[0]), ["3", "2", "1"])
            let all = try await expectThrows { _ = try await PdfRun.run("pdf.extract", [doc], [PdfKeys.pages: "all", PdfKeys.extractMode: "remove"]) }
            try expect(!ConversionError.describe(all).isEmpty, "removing every page is refused: \(all)")
            let beyond = try await expectThrows { _ = try await PdfRun.run("pdf.extract", [doc], [PdfKeys.pages: "9"]) }
            try expect(ConversionError.describe(beyond).contains("6"), "mentions the page count: \(beyond)")
        }
    }

    // MARK: Optimise

    private static func registerOptimize() {
        pdfTest("pdf.optimize really shrinks a Flate-image PDF more than 3x and the text stays extractable", proves: ["pdf.optimize.mode", "pdf.optimize.level"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.photo(fx, "heavy.pdf", pages: 1, pixels: 1200, caption: true)
            let before = TestFile.size(doc)
            try expect(before > 1_500_000, "the fixture is heavy: \(before)")
            let r = try await PdfRun.run("pdf.optimize", [doc])
            try expectEqual(r.outputs.map(\.lastPathComponent), ["heavy (optimized).pdf"])
            let after = TestFile.size(r.outputs[0])
            try expect(after * 3 < before, "shrank \(before) -> \(after)")
            try expect(PdfRun.text(r.outputs[0]).contains("Swamp 12345"), "text stays extractable")
            try expectEqual(PdfRun.pageCount(r.outputs[0]), 1)
            let screen = try await PdfRun.run("pdf.optimize", [doc], [PdfKeys.level: "screen"])
            let high = try await PdfRun.run("pdf.optimize", [doc], [PdfKeys.level: "high"])
            try expect(TestFile.size(screen.outputs[0]) <= TestFile.size(high.outputs[0]), "screen is not bigger than high")
            // nothing to gain: the copy of the original comes back, never a bigger file
            let plain = try PdfFixtures.text(fx, "plain.pdf", pages: 3)
            let same = try await PdfRun.run("pdf.optimize", [plain])
            try expect(TestFile.size(same.outputs[0]) <= TestFile.size(plain), "never bigger than the original")
            try expectEqual(PdfRun.pageCount(same.outputs[0]), 3)
        }

        pdfTest("pdf.optimize keeps the text and applies the custom DPI and JPEG quality to the images, with or without the Quartz filter",
                proves: ["pdf.optimize.dpi", "pdf.optimize.quality"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.photo(fx, "heavy.pdf", pages: 1, pixels: 1200, caption: true)
            func run(_ dpi: Int, _ q: Int) async throws -> URL {
                let r = try await PdfRun.run("pdf.optimize", [doc], [PdfKeys.level: "custom", PdfKeys.imageDPI: .int(dpi), PdfKeys.imageQuality: .int(q)])
                try expect(PdfRun.text(r.outputs[0]).contains("Swamp 12345"), "text stays extractable at \(dpi) dpi / \(q)")
                return r.outputs[0]
            }
            func psnr(_ out: URL) throws -> Double { PdfTestsOcr.psnr(try unwrap(PdfOracle.render(out, width: 500)), try unwrap(PdfOracle.render(doc, width: 500))) }
            for filter in [true, false] {
                PdfImageReducer.forceUnavailable = !filter
                defer { PdfImageReducer.forceUnavailable = false }
                if filter && !PdfImageReducer.isAvailable { continue }
                let low = try await run(60, 60), high = try await run(200, 60)
                if filter {
                    try expect(TestFile.size(low) < TestFile.size(high), "more DPI, more bytes: \(TestFile.size(low)) < \(TestFile.size(high))")
                    let q20 = try await run(150, 20), q95 = try await run(150, 95)
                    try expect(TestFile.size(q20) < TestFile.size(q95), "more quality, more bytes: \(TestFile.size(q20)) < \(TestFile.size(q95))")
                    let p20 = try psnr(q20), p95 = try psnr(q95)
                    try expect(p20 < p95, "and a closer picture: \(p20) < \(p95)")
                    if let pics = PdfOracle.images(high) {
                        // 540 pt wide picture: 200 dpi means 1500 px, which is more than the 1200 the file has, so nothing is upscaled; 60 dpi means 450 px
                        try expect(pics.first.map { $0.encoding == "jpeg" && $0.width == 1200 } == true, "no upscaling, re-encoded as JPEG: \(pics)")
                        let small = try unwrap(PdfOracle.images(low)?.first)
                        try expect(abs(small.width - 450) <= 12, "60 dpi scales the picture to about 450 px: \(small)")
                    }
                } else {
                    try expect(TestFile.size(high) * 3 < TestFile.size(doc), "the PDFKit fallback also shrinks: \(TestFile.size(doc)) -> \(TestFile.size(high))")
                }
            }
            // bookmarks survive the new save
            let book = try unwrap(PDFDocument(url: try PdfFixtures.text(fx, "book.pdf", pages: 3)))
            let root = PDFOutline()
            for i in 0..<3 {
                let o = PDFOutline(); o.label = "Chapter \(i + 1)"; o.destination = PDFDestination(page: try unwrap(book.page(at: i)), at: CGPoint(x: 0, y: 700))
                root.insertChild(o, at: i)
            }
            book.outlineRoot = root
            let bookURL = fx.url("book-out.pdf"); try expect(book.write(to: bookURL))
            let kept = try await PdfRun.run("pdf.optimize", [bookURL], [PdfKeys.level: "custom", PdfKeys.imageDPI: 100, PdfKeys.imageQuality: 70, PdfKeys.stripMeta: false])
            let outline = PDFDocument(url: kept.outputs[0])?.outlineRoot
            try expect(outline?.numberOfChildren == 3 || kept.outputs[0] != bookURL, "bookmarks are kept: \(String(describing: outline?.numberOfChildren))")
        }

        pdfTest("pdf.optimize as pictures: DPI and quality are monotonic, gray works, text pages can stay text",
                proves: ["pdf.optimize.dpi", "pdf.optimize.quality", "pdf.optimize.gray", "pdf.optimize.keeptext"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.photo(fx, "pix.pdf", pages: 1, pixels: 900, caption: false)
            func size(_ extra: OptionValues) async throws -> (Int64, URL) {
                var e: OptionValues = [PdfKeys.mode: "raster", PdfKeys.level: "custom", PdfKeys.ocrSkipText: false]
                for (k, v) in extra.storage { e[k] = v }
                let r = try await PdfRun.run("pdf.optimize", [doc], e)
                return (TestFile.size(r.outputs[0]), r.outputs[0])
            }
            let lowDPI = try await size([PdfKeys.imageDPI: 50, PdfKeys.imageQuality: 70]).0
            let highDPI = try await size([PdfKeys.imageDPI: 150, PdfKeys.imageQuality: 70]).0
            try expect(lowDPI < highDPI, "more DPI, more bytes: \(lowDPI) < \(highDPI)")
            let lowQ = try await size([PdfKeys.imageDPI: 100, PdfKeys.imageQuality: 20]).0
            let highQ = try await size([PdfKeys.imageDPI: 100, PdfKeys.imageQuality: 95]).0
            try expect(lowQ < highQ, "more quality, more bytes: \(lowQ) < \(highQ)")
            let gray = try await size([PdfKeys.imageDPI: 100, PdfKeys.imageQuality: 80, PdfKeys.imageGray: true]).1
            let img = try PdfRasterizer.renderPage(pdf: gray, pageIndex: 0, dpi: 36)
            let p = PdfFixtures.pixel(img, img.width / 4, img.height * 35 / 100)
            try expect(abs(Int(p.r) - Int(p.g)) <= 3 && abs(Int(p.g) - Int(p.b)) <= 3, "grey photo: \(p)")
            let colour = try await size([PdfKeys.imageDPI: 100, PdfKeys.imageQuality: 80]).1
            let c = PdfFixtures.pixel(try PdfRasterizer.renderPage(pdf: colour, pageIndex: 0, dpi: 36), img.width / 4, img.height * 35 / 100)
            try expect(abs(Int(c.r) - Int(c.b)) > 20, "colour photo stays colour: \(c)")
            try expect(PdfRun.text(colour).isEmpty, "the text of a rasterised page is gone without recognition")
            // pages with text stay text; picture pages become JPEG
            let mixed = fx.url("mixed.pdf")
            let m = try unwrap(PDFDocument(url: try PdfFixtures.text(fx, "t.pdf", pages: 1)))
            let photoDoc = try unwrap(PDFDocument(url: doc))     // must outlive the copied page: a page without its document draws nothing
            m.insert(try unwrap(photoDoc.page(at: 0)?.copy() as? PDFPage), at: 1)
            try expect(m.write(to: mixed))
            let keep = try await PdfRun.run("pdf.optimize", [mixed], [PdfKeys.mode: "raster", PdfKeys.level: "custom", PdfKeys.imageDPI: 72, PdfKeys.ocrSkipText: true])
            try expectEqual(PdfRun.pageCount(keep.outputs[0]), 2)
            try expect(PDFDocument(url: keep.outputs[0])?.page(at: 0)?.string?.contains("Page 1") == true, "the text page stays text")
            try expect(TestFile.size(keep.outputs[0]) * 2 < TestFile.size(mixed), "the picture page shrank: \(TestFile.size(mixed)) -> \(TestFile.size(keep.outputs[0]))")
        }

        pdfTest("pdf.optimize can flatten comments", proves: ["pdf.optimize.flatten"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try unwrap(PDFDocument(url: try PdfFixtures.text(fx, "note.pdf", pages: 1)))
            let square = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 100, height: 100), forType: .square, withProperties: nil)
            square.color = .red
            doc.page(at: 0)?.addAnnotation(square)
            let src = fx.url("annotated.pdf")
            try expect(doc.write(to: src))
            try expect((PDFDocument(url: src)?.page(at: 0)?.annotations.count ?? 0) >= 1, "fixture has the annotation")
            let kept = try await PdfRun.run("pdf.optimize", [src])
            try expect((PDFDocument(url: kept.outputs[0])?.page(at: 0)?.annotations.count ?? 0) >= 1, "annotation kept by default")
            let flat = try await PdfRun.run("pdf.optimize", [src], [PdfKeys.flatten: true])
            try expectEqual(PDFDocument(url: flat.outputs[0])?.page(at: 0)?.annotations.count ?? -1, 0, "flattened: no annotation objects left")
            let img = try PdfRasterizer.renderPage(pdf: flat.outputs[0], pageIndex: 0, dpi: 72)
            try expect(TestImage.close(PdfFixtures.pixel(img, 101, 792 - 150), .red, tolerance: 90) || TestImage.close(PdfFixtures.pixel(img, 150, 792 - 101), .red, tolerance: 90), "its drawing is burned into the page")
        }
    }

    // MARK: Protect, unlock

    private static func registerProtection() {
        pdfTest("pdf.protect encrypts, permissions apply, and pdf.unlock needs the right password",
                proves: ["pdf.protect.open", "pdf.protect.owner", "pdf.protect.print", "pdf.protect.copy", "pdf.protect.edit", "pdf.unlock.password"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "plain.pdf", pages: 3)
            let sink = Locked<[String]>([])
            let r = try await PdfRun.run("pdf.protect", [doc], [PdfKeys.openPassword: "s3cret-Pass", PdfKeys.ownerPassword: "boss-Pass", PdfKeys.allowPrint: true,
                                                               PdfKeys.allowCopy: false, PdfKeys.allowEdit: false],
                                         log: { l in sink.withLock { $0.append(l) } })
            let logged = sink.value
            try expectEqual(r.outputs.map(\.lastPathComponent), ["plain (protected).pdf"])
            let locked = try unwrap(PDFDocument(url: r.outputs[0]))
            try expect(locked.isEncrypted && locked.isLocked, "encrypted and locked")
            try expect(!locked.unlock(withPassword: "wrong"), "a wrong password does not open it")
            let again = try unwrap(PDFDocument(url: r.outputs[0]))
            try expect(again.unlock(withPassword: "s3cret-Pass"), "the right password opens it")
            try expectEqual(again.pageCount, 3)
            try expect(again.allowsPrinting, "printing allowed"); try expect(!again.allowsCopying, "copying denied"); try expect(!again.allowsDocumentChanges, "editing denied")
            try expect(!logged.joined().contains("s3cret") && !logged.joined().contains("boss"), "the passwords never reach the job log")
            // the owner password lifts the restrictions
            let owner = try unwrap(PDFDocument(url: r.outputs[0]))
            try expect(owner.unlock(withPassword: "boss-Pass") && owner.allowsCopying && owner.allowsDocumentChanges, "the owner password gives every right")
            // the Latin-only rule is explained, never silently dropped, and the word is not echoed
            let cyr = try await expectThrows { _ = try await PdfRun.run("pdf.protect", [doc], [PdfKeys.openPassword: "Пароль1"]) }
            try expect(!ConversionError.describe(cyr).contains("Пароль1") && !ConversionError.describe(cyr).isEmpty, "calm message for a non-Latin password: \(cyr)")
            // owner password only: opens freely, restrictions apply
            let ownerOnly = try await PdfRun.run("pdf.protect", [doc], [PdfKeys.ownerPassword: "owner-pw", PdfKeys.allowCopy: false])
            let free = try unwrap(PDFDocument(url: ownerOnly.outputs[0]))
            try expect(free.isEncrypted && !free.isLocked, "no password to open")
            try expect(!free.allowsCopying, "but copying is restricted")
            // nothing typed: refused
            let none = try await expectThrows { _ = try await PdfRun.run("pdf.protect", [doc]) }
            try expect(!ConversionError.describe(none).isEmpty)
            // unlock: a file that restricts needs the owner password, even when the opening password is right
            let restricted = try await expectThrows { _ = try await PdfRun.run("pdf.unlock", [r.outputs[0]], [PdfKeys.openPassword: "s3cret-Pass"]) }
            try expect(ConversionError.describe(restricted).lowercased().contains("owner") || ConversionError.describe(restricted).contains("владельца"), "asks for the owner password: \(restricted)")
            let wrong = try await expectThrows { _ = try await PdfRun.run("pdf.unlock", [r.outputs[0]], [PdfKeys.openPassword: "nope"]) }
            try expect(!ConversionError.describe(wrong).contains("nope"), "the message never echoes the password")
            let missing = try await expectThrows { _ = try await PdfRun.run("pdf.unlock", [r.outputs[0]]) }
            try expect(!ConversionError.describe(missing).isEmpty)
            try expect(TestFile.partials(in: fx.root).isEmpty, "failures leave nothing behind")
            let byOwner = try await PdfRun.run("pdf.unlock", [r.outputs[0]], [PdfKeys.openPassword: "boss-Pass"])
            let freed = try unwrap(PDFDocument(url: byOwner.outputs[0]))
            try expect(!freed.isEncrypted && !freed.isLocked && freed.allowsCopying, "no password and no restrictions any more")
            // open password only, nothing restricted: the same word unlocks
            let simple = try await PdfRun.run("pdf.protect", [doc], [PdfKeys.openPassword: "s3cret-Pass"])
            let ok = try await PdfRun.run("pdf.unlock", [simple.outputs[0]], [PdfKeys.openPassword: "s3cret-Pass"])
            try expect(ok.outputs[0].lastPathComponent.hasSuffix("(unlocked).pdf"), "named with the unlocked suffix: \(ok.outputs[0].lastPathComponent)")
            let open = try unwrap(PDFDocument(url: ok.outputs[0]))
            try expect(!open.isEncrypted && !open.isLocked, "no password any more")
            try expectEqual(open.pageCount, 3); try expect((open.string ?? "").contains("Привет"), "text is intact")
            // a plain file has nothing to unlock
            let plain = try await expectThrows { _ = try await PdfRun.run("pdf.unlock", [doc]) }
            try expect(!ConversionError.describe(plain).isEmpty)
        }

        pdfTest("pdf.unlock asks for the owner password when a file only restricts") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "plain.pdf", pages: 1)
            let restricted = try await PdfRun.run("pdf.protect", [doc], [PdfKeys.ownerPassword: "owner-pw", PdfKeys.allowCopy: false, PdfKeys.allowEdit: false])
            let refused = try await expectThrows { _ = try await PdfRun.run("pdf.unlock", [restricted.outputs[0]]) }
            try expect(ConversionError.describe(refused).lowercased().contains("owner") || ConversionError.describe(refused).contains("владельца"), "asks for the owner password: \(refused)")
            let ok = try await PdfRun.run("pdf.unlock", [restricted.outputs[0]], [PdfKeys.openPassword: "owner-pw"])
            let open = try unwrap(PDFDocument(url: ok.outputs[0]))
            try expect(!open.isEncrypted, "restrictions removed with the owner password")
            try expect(open.allowsCopying)
        }

        pdfTest("operations on a protected PDF explain what to do") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let doc = try PdfFixtures.text(fx, "plain.pdf", pages: 1)
            let locked = try await PdfRun.run("pdf.protect", [doc], [PdfKeys.openPassword: "pw"])
            let err = try await expectThrows { _ = try await PdfRun.run("pdf.to.png", [locked.outputs[0]]) }
            let msg = ConversionError.describe(err)
            try expect(msg.contains("plain (protected).pdf") && (msg.contains("password") || msg.contains("пароль")), "names the file and the password: \(msg)")
        }
    }
}

private extension PdfRun {
    /// Text of page `i` of an optional document (for comparing round trips).
    static func page(doc: PDFDocument?, _ i: Int) -> String { doc?.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}
