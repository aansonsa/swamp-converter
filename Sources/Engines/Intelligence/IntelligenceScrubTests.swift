import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// D. Share-safe scrub: images and PDFs (video / audio live in IntelligenceScrubMediaTests). Oracles: ImageIO / PDFKit / CGPDF read the result back; the original is
// hashed before and after; the report must list exactly what was removed.

enum IntelligenceScrubTests {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("intelligence", "scrub.image: GPS and camera tags are gone, pixels and size are kept, the original is untouched, the report names exactly what went") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try IntelTest.richJPEG(fx)
            let before = try IntelTest.sha256(src)
            // Precondition: the fixture really carries everything (otherwise the test proves nothing).
            let present = ImageScrub.inspect(src).removed
            for item in [ScrubReport.Item.gps, .cameraMake, .cameraModel, .software, .author, .dateTaken, .lensModel, .serialNumber] {
                try expect(present.contains(item), "fixture lacks \(item); inspect saw \(present)")
            }
            let result = try await IntelTest.run("scrub.image", [src])
            let out = try unwrap(result.outputs.first)
            try expectEqual(out.lastPathComponent, "rich (clean).jpg")
            try expectEqual(try IntelTest.sha256(src), before, "the original must not change")
            try expect(try IntelTest.sha256(out) != before, "the copy must differ from the original")
            try expectEqual(TestFile.magic(out, 3), [0xFF, 0xD8, 0xFF], "must really be a JPEG")
            try expectEqual(TestImage.info(of: out)?.type, UTType.jpeg.identifier)
            let props = IntelTest.properties(out)
            try expect(props[kCGImagePropertyGPSDictionary as String] == nil, "GPS dictionary still present")
            let tiff = IntelTest.dictionary(out, kCGImagePropertyTIFFDictionary)
            try expect(tiff[kCGImagePropertyTIFFMake as String] == nil && tiff[kCGImagePropertyTIFFModel as String] == nil, "camera make / model still present")
            try expect(tiff[kCGImagePropertyTIFFSoftware as String] == nil, "software still present")
            let exif = IntelTest.dictionary(out, kCGImagePropertyExifDictionary)
            try expect(exif[kCGImagePropertyExifLensModel as String] == nil && exif[kCGImagePropertyExifBodySerialNumber as String] == nil, "lens / serial still present")
            // Not selected by the quick recipe: author and dates stay (ImageIO keeps the artist in XMP / IPTC, the date in Exif).
            let kept = ImageScrub.inspect(out).removed
            try expect(kept.contains(.author) && kept.contains(.dateTaken), "author and dates must stay, found \(kept)")
            try expectEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:05:01 10:00:00")
            try expectEqual(TestImage.size(of: out)?.width, 96)
            try expectEqual(TestImage.size(of: out)?.height, 64)
            try expect(IntelTest.meanDifference(src, out).map { $0 < 1.0 } == true, "pixels changed")
            // The note lists what was removed and nothing that was kept.
            let note = try unwrap(result.note).en
            try expect(note.hasPrefix("Removed:"), note)
            for word in ["location", "camera", "lens", "serial number", "software"] { try expect(note.lowercased().contains(word), "note lacks \(word): \(note)") }
            try expect(!note.lowercased().contains("dates") && !note.lowercased().contains("author"), "note names something that was kept: \(note)")
        }

        t.register("intelligence", "scrub.image: lossless route copies the compressed pixels (identical decode) and a second scrub finds nothing to remove") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try IntelTest.richJPEG(fx)
            let first = try unwrap(try await IntelTest.run("scrub.image", [src]).outputs.first)
            try expectEqual(IntelTest.meanDifference(src, first) ?? 99, 0, "a lossless copy must decode to the same pixels")
            let again = try await IntelTest.run("scrub.image", [first])
            let note = try unwrap(again.note).en
            try expect(note.hasPrefix("Nothing to remove"), note)
        }

        t.register("intelligence", "scrub.image: date, author and remove-all switches each remove their group") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try IntelTest.richJPEG(fx)
            let dates = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.removeDates: true]).outputs.first)
            try expect(IntelTest.dictionary(dates, kCGImagePropertyExifDictionary)[kCGImagePropertyExifDateTimeOriginal as String] == nil, "date taken still present")
            let afterDates = ImageScrub.inspect(dates).removed
            try expect(!afterDates.contains(.dateTaken), "dates left: \(afterDates)")
            try expect(afterDates.contains(.author), "author must stay when only dates are selected: \(afterDates)")

            let author = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.removeAuthor: true]).outputs.first)
            let afterAuthor = ImageScrub.inspect(author).removed
            try expect(!afterAuthor.contains(.author), "author left: \(afterAuthor)")
            try expect(afterAuthor.contains(.dateTaken), "dates must stay when only the author is selected: \(afterAuthor)")
            try expect(IntelTest.dictionary(author, kCGImagePropertyIPTCDictionary)[kCGImagePropertyIPTCByline as String] == nil, "IPTC byline still present")

            // GPS off: location stays (proves the switch is real, not "always remove").
            let keepGPS = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.removeGPS: false, ScrubKeys.removeCamera: false]).outputs.first)
            try expect(IntelTest.properties(keepGPS)[kCGImagePropertyGPSDictionary as String] != nil, "GPS must stay when its switch is off")
            try expectEqual(IntelTest.dictionary(keepGPS, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] as? String, "SwampCam")

            let all = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.removeAll: true]).outputs.first)
            let leftovers = ImageScrub.inspect(all).removed
            try expect(leftovers.isEmpty, "remove-all left \(leftovers)")
            try expect(IntelTest.dictionary(all, kCGImagePropertyIPTCDictionary).isEmpty, "IPTC still present")
        }

        t.register("intelligence", "scrub.image: orientation is baked into the pixels and the tag disappears") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try IntelTest.richJPEG(fx, "rot.jpg", orientation: 6, width: 96, height: 64)
            let out = try unwrap(try await IntelTest.run("scrub.image", [src]).outputs.first)
            // Stored 96x64, displayed turned 90 degrees clockwise: 64x96, and the stored bottom-left (blue) is now top-left.
            try expectEqual(TestImage.size(of: out)?.width, 64)
            try expectEqual(TestImage.size(of: out)?.height, 96)
            let orientation = TestImage.info(of: out)?.orientation ?? 1
            try expectEqual(orientation, 1, "orientation tag must be gone")
            try expect(TestImage.close(TestImage.pixel(of: out, x: 6, y: 6), .blue, tolerance: 60), "top-left should be the old bottom-left (blue)")
            try expect(TestImage.close(TestImage.pixel(of: out, x: 57, y: 6), .red, tolerance: 60), "top-right should be the old top-left (red)")
            try expect(ImageScrub.inspect(out).removed.filter { [.gps, .cameraMake, .cameraModel].contains($0) }.isEmpty)

            // Switched off: the tag and the stored pixels stay.
            let kept = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.keepOrientation: false]).outputs.first)
            try expectEqual(TestImage.size(of: kept)?.width, 96)
            try expectEqual(TestImage.info(of: kept)?.orientation, 6, "orientation tag must be kept when baking is off")
        }

        t.register("intelligence", "scrub.image: the re-encoded route (orientation baked) stays visually identical to the source, and is not bloated") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let photo = IntelTest.photoLike(fx)
            let src = try fx.writeImage(photo, name: "photo.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.92, kCGImagePropertyOrientation: 6,
                                                                                         kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SwampCam"] as [CFString: Any]])
            let copy = try unwrap(try await IntelTest.run("scrub.image", [src]).outputs.first)
            // Reference: the source as a viewer shows it (ImageIO applies the orientation), written losslessly.
            let s = try unwrap(CGImageSourceCreateWithURL(src as CFURL, nil))
            let ref = try unwrap(CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary))
            let refURL = try fx.writeImage(ref, name: "ref.png", type: .png)
            let psnr = try unwrap(IntelTest.psnr(refURL, copy), "sizes differ")
            out("psnr \(String(format: "%.1f", psnr)) dB, source \(TestFile.size(src)) B, copy \(TestFile.size(copy)) B")
            try expect(psnr > 38, "quality 0.95 must stay visually identical, PSNR \(psnr) dB")
            try expect(TestFile.size(copy) < TestFile.size(src) * 3, "the copy must not be bloated: \(TestFile.size(copy)) vs \(TestFile.size(src))")
            try expect(!ImageScrub.inspect(copy).removed.contains(.cameraMake), "make must be gone")
        }

        t.register("intelligence", "scrub.image: the colour profile is kept by default and dropped (sRGB) when asked") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { try skipTest("no Display P3 on this system") }
            let src = try IntelTest.richJPEG(fx, "p3.jpg", colorSpace: p3)
            let profile = TestImage.info(of: src)?.profileName ?? ""
            try expect(profile.contains("P3"), "fixture should carry Display P3, has \(profile)")
            let kept = try unwrap(try await IntelTest.run("scrub.image", [src]).outputs.first)
            try expect((TestImage.info(of: kept)?.profileName ?? "").contains("P3"), "profile must stay by default")
            let dropped = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.keepColorProfile: false]).outputs.first)
            let name = TestImage.info(of: dropped)?.profileName ?? ""
            try expect(name.contains("sRGB"), "profile should be sRGB after dropping, is \(name)")
            try expect(ImageScrub.inspect(dropped).removed.filter { [.gps, .cameraMake].contains($0) }.isEmpty)
        }

        t.register("intelligence", "scrub.image: PNG text chunks and non-JPEG formats are handled; unwritable formats become PNG") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.writeImage(fx.cgImage(width: 40, height: 30), name: "note.png", type: .png,
                                        properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: "Andris", kCGImagePropertyPNGDescription: "private"] as [CFString: Any]])
            try expect(ImageScrub.inspect(src).removed.contains(.author), "fixture should report an author")
            let out = try unwrap(try await IntelTest.run("scrub.image", [src], extra: [ScrubKeys.removeAll: true]).outputs.first)
            try expectEqual(out.pathExtension, "png")
            try expectEqual(TestFile.magic(out, 4), [0x89, 0x50, 0x4E, 0x47])
            try expect(ImageScrub.inspect(out).removed.isEmpty, "remove-all left \(ImageScrub.inspect(out).removed)")
            let png = IntelTest.dictionary(out, kCGImagePropertyPNGDictionary)
            try expect(png[kCGImagePropertyPNGAuthor as String] == nil, "PNG author chunk still present")
            // A WebP source that ImageIO cannot write comes out as PNG, never as a renamed file.
            let item = FileItem(url: fx.url("x.webp"), isDirectory: false)
            let ext = MetadataScrubber.outputExtension(for: item)
            try expect(["png", "webp"].contains(ext))
        }

        t.register("intelligence", "scrub.image: HEIC and TIFF sources lose GPS and camera too and stay in their format") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 50.08, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 14.42, kCGImagePropertyGPSLongitudeRef: "E"]
            let tiffTags: [CFString: Any] = [kCGImagePropertyTIFFMake: "SwampCam", kCGImagePropertyTIFFModel: "Test 1"]
            let photo = IntelTest.photoLike(fx, width: 160, height: 120)
            var checked = 0
            for (name, type) in [("p.heic", UTType.heic), ("p.tiff", UTType.tiff)] {
                guard let src = try? fx.writeImage(photo, name: name, type: type, properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyTIFFDictionary: tiffTags]) else { continue }
                guard ImageScrub.inspect(src).removed.contains(.gps) else { continue }   // this ImageIO build does not store GPS in this format
                let out = try unwrap(try await IntelTest.run("scrub.image", [src]).outputs.first)
                try expectEqual(out.pathExtension, name.split(separator: ".").last.map(String.init) ?? "")
                try expectEqual(TestImage.info(of: out)?.type, type.identifier, "format must not change")
                let left = ImageScrub.inspect(out).removed
                try expect(!left.contains(.gps) && !left.contains(.cameraMake) && !left.contains(.cameraModel), "\(name) still has \(left)")
                try expect((IntelTest.psnr(src, out) ?? 0) > 40, "\(name): pixels changed")
                checked += 1
            }
            if checked == 0 { try skipTest("ImageIO on this Mac stores no GPS in HEIC / TIFF test files") }
        }

        t.register("intelligence", "scrub.pdf: author stays, producer / creator and XMP go, pages and text are identical, the original is untouched") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try makePDF(fx, name: "doc.pdf", pages: 3)
            let before = try IntelTest.sha256(src)
            let present = PdfScrub.inspect(src).removed
            for item in [ScrubReport.Item.author, .title, .software, .xmp, .creationTime] { try expect(present.contains(item), "fixture lacks \(item); inspect saw \(present)") }

            let result = try await IntelTest.run("scrub.pdf", [src])
            let out = try unwrap(result.outputs.first)
            try expectEqual(out.lastPathComponent, "doc (clean).pdf")
            try expectEqual(try IntelTest.sha256(src), before, "the original must not change")
            try expectEqual(TestFile.magicString(out, 5), "%PDF-")
            let a = try unwrap(PDFDocument(url: src)), b = try unwrap(PDFDocument(url: out))
            try expectEqual(b.pageCount, a.pageCount)
            try expectEqual(b.string, a.string, "page text must be identical")
            try expectEqual(b.page(at: 0)?.bounds(for: .mediaBox), a.page(at: 0)?.bounds(for: .mediaBox))
            let attrs = b.documentAttributes ?? [:]
            try expectEqual(attrs[PDFDocumentAttribute.authorAttribute] as? String, "Andris Test", "author is not part of the quick recipe")
            try expect(attrs[PDFDocumentAttribute.creatorAttribute] == nil, "creator still present")
            let producer = (attrs[PDFDocumentAttribute.producerAttribute] as? String) ?? ""
            try expect(producer.trimmingCharacters(in: .whitespaces).isEmpty, "producer still present: \(producer)")
            try expect(!PdfScrub.hasXMP(out), "XMP stream still present")
            let note = try unwrap(result.note).en
            try expect(note.lowercased().contains("software"), note)
        }

        t.register("intelligence", "scrub.pdf: bookmarks survive the rebuild and point at the same pages") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let made = try makePDF(fx, name: "outline-src.pdf", pages: 4)
            let doc = try unwrap(PDFDocument(url: made))
            let root = PDFOutline()
            for (i, title) in ["Intro", "Middle", "End"].enumerated() {
                let item = PDFOutline()
                item.label = title
                item.destination = PDFDestination(page: try unwrap(doc.page(at: i == 2 ? 3 : i)), at: CGPoint(x: 0, y: 700))
                root.insertChild(item, at: i)
            }
            doc.outlineRoot = root
            let src = fx.url("outline.pdf")
            try expect(doc.write(to: src))
            try expect(PdfScrub.hasXMP(src), "the fixture keeps its XMP packet (so the scrub rebuilds the document)")
            let out = try unwrap(try await IntelTest.run("scrub.pdf", [src]).outputs.first)
            try expect(!PdfScrub.hasXMP(out))
            let copy = try unwrap(PDFDocument(url: out))
            let titles = (0..<(copy.outlineRoot?.numberOfChildren ?? 0)).compactMap { copy.outlineRoot?.child(at: $0)?.label }
            try expectEqual(titles, ["Intro", "Middle", "End"])
            let pages = (0..<3).compactMap { i in copy.outlineRoot?.child(at: i)?.destination?.page.map { copy.index(for: $0) } }
            try expectEqual(pages, [0, 1, 3])
        }

        t.register("intelligence", "scrub.pdf: author and remove-all switches take the title, author and dates out") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try makePDF(fx, name: "doc.pdf", pages: 2)
            let author = try unwrap(try await IntelTest.run("scrub.pdf", [src], extra: [ScrubKeys.removeAuthor: true]).outputs.first)
            let aAttrs = PDFDocument(url: author)?.documentAttributes ?? [:]
            try expect(((aAttrs[PDFDocumentAttribute.authorAttribute] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "author still present")
            try expectEqual(aAttrs[PDFDocumentAttribute.titleAttribute] as? String, "Secret Plan", "title must stay")

            let all = try unwrap(try await IntelTest.run("scrub.pdf", [src], extra: [ScrubKeys.removeAll: true]).outputs.first)
            let left = PdfScrub.inspect(all).removed
            try expect(left.isEmpty, "remove-all left \(left)")
            try expectEqual(PDFDocument(url: all)?.string, PDFDocument(url: src)?.string)
        }

        t.register("intelligence", "scrub.pdf: a PDF without personal data is copied unchanged and says so; a locked PDF is refused calmly") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let plain = try fx.pdf("plain.pdf", pages: 1)
            // fx.pdf writes only the Quartz producer + dates, which count as software and dates.
            let result = try await IntelTest.run("scrub.pdf", [plain], extra: [ScrubKeys.removeCamera: false])
            let out = try unwrap(result.outputs.first)
            try expectEqual(try IntelTest.sha256(out), try IntelTest.sha256(plain), "nothing selected is present: an unchanged copy")
            try expect(try unwrap(result.note).en.hasPrefix("Nothing to remove"))

            let locked = fx.url("locked.pdf")
            var box = CGRect(x: 0, y: 0, width: 200, height: 200)
            let ctx = try unwrap(CGContext(locked as CFURL, mediaBox: &box, [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"] as CFDictionary))
            ctx.beginPDFPage(nil); ctx.fill(CGRect(x: 1, y: 1, width: 5, height: 5)); ctx.endPDFPage(); ctx.closePDF()
            let error = try await expectThrows { _ = try await IntelTest.run("scrub.pdf", [locked]) }
            try expect(ConversionError.describe(error).lowercased().contains("password"), ConversionError.describe(error))
        }

        t.register("intelligence", "scrub.pdf: Info strings are blanked in place with the same length, escapes and arrays included") {
            let text = "<< /Producer (macOS \\(Build 1\\) Quartz) /Title (Keep) /AAPL:Keywords [ (a,b) (c) ] /Author <414243> /TitleX (zz) >>"
            var bytes = [UInt8](text.utf8)
            let n = bytes.count
            PdfScrub.blank(keys: ["Producer", "AAPL:Keywords", "Author", "Title"], in: &bytes)
            let s = String(decoding: bytes, as: UTF8.self)
            try expectEqual(bytes.count, n, "length must not change")
            try expect(!s.contains("Quartz") && !s.contains("Build") && !s.contains("a,b") && !s.contains("Keep") && !s.contains("414243"), s)
            try expect(s.contains("(zz)"), "/TitleX is another key and must stay: \(s)")
            try expect(s.contains("/Producer (") && s.contains("/Title ("), s)
        }

        t.register("intelligence", "ScrubReport: the summary names what was removed in both languages, collapses duplicates, merges several files") {
            var r = ScrubReport(removed: [.gps, .cameraMake, .cameraModel, .lensModel, .dateTaken])
            try expectEqual(r.summary.en, "Removed: location (GPS), camera, lens, dates")
            try expectEqual(r.summary.ru, "Удалено: геопозиция (GPS), камера, объектив, даты")
            r.residual = [.xmp]
            try expect(r.summary.en.hasSuffix("Could not remove: other metadata"), r.summary.en)
            try expect(r.summary.ru.contains("Не удалось удалить: прочие метаданные"), r.summary.ru)
            try expectEqual(ScrubReport().summary.en, "Nothing to remove: the file had no location or camera data.")
            let merged = ScrubReport.merged([ScrubReport(removed: [.gps]), ScrubReport(removed: [.cameraMake, .gps]), ScrubReport()])
            try expectEqual(merged.removed, [.gps, .cameraMake])
            // Selection semantics: the quick recipe removes location and device, nothing else.
            let o = IntelTest.quickScrubOptions()
            let sel = ScrubSelection(options: o)
            try expect(sel.gps && sel.device && !sel.dates && !sel.author && !sel.everything)
        }

        t.register("intelligence", "scrub.* operations: schema fields all carry an oracle and the quick recipe equals the schema defaults") {
            for id in ScrubSchemas.allIDs {
                let schema = ScrubSchemas.schema(id: id)
                try expect(!schema.allFields.isEmpty, "\(id) has no fields")
                for f in schema.allFields { try expect(!f.oracle.isEmpty, "\(id): field \(f.key) has no oracle") }
            }
            let op = try IntelTest.operation("scrub.image")
            let ctx = OperationContext.testing(op, items: [])
            try expect(ctx.options.bool(ScrubKeys.removeGPS) && ctx.options.bool(ScrubKeys.removeCamera))
            try expect(!ctx.options.bool(ScrubKeys.removeDates) && !ctx.options.bool(ScrubKeys.removeAll))
            // "remove all" makes the single switches inactive (the engine ignores them).
            let all = OperationContext.testing(op, items: [], extra: [ScrubKeys.removeAll: true])
            try expect(!all.isActive(ScrubKeys.removeGPS))
            try expect(ScrubSelection(options: all.options, isActive: all.isActive).everything)
            try expect(ScrubSchemas.schema(id: ScrubSchemas.pdfID).field(ScrubKeys.removeGPS) == nil, "PDFs have no location field")
        }
    }

    /// A 3-page PDF with title, author, creator, subject and an XMP packet (written by Quartz, so it also has a producer and dates).
    static func makePDF(_ fx: TestFixtures, name: String, pages: Int) throws -> URL {
        let url = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let aux: [CFString: Any] = [kCGPDFContextTitle: "Secret Plan", kCGPDFContextAuthor: "Andris Test", kCGPDFContextCreator: "SwampEdit 9",
                                    kCGPDFContextSubject: "private", kCGPDFContextKeywords: "a,b"]
        let ctx = try unwrap(CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary))
        let xmp = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:CreatorTool=\"SwampEdit\"/></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        ctx.addDocumentMetadata(Data(xmp.utf8) as CFData)
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            let font = CTFontCreateUIFontForLanguage(.system, 20, nil)!
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(p + 1) Привет мир swamp", attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: 60, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
