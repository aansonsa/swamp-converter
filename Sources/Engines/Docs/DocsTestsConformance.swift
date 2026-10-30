import Foundation
import PDFKit

// "conformance.*": every document operation is run on every other input format and the result is checked by something other than the code that wrote it:
//   format   /usr/bin/file --mime-type, the package layout read with unzip, PDFKit's media box, the first bytes
//   text     textutil / PDFKit / unzip + tag stripper: every text snippet is there, in reading order, with Cyrillic and Latvian letters intact
//   structure our reader on the result: headings, list items (numbers, nesting), table cells and code blocks equal the source's
//   not a rename: the output is not the input's bytes, and its content really changed form
// The list of targets mirrors the catalogue; the coverage test fails when an operation has no oracle test.

enum DocsConformance {
    static let inputs = ["docx", "doc", "odt", "rtf", "md", "txt", "html", "epub"]
    static let targets = ["docx", "pdf", "odt", "md", "html", "txt", "epub", "rtf"]
    /// Targets whose result keeps headings / lists / tables well enough to compare structure with our reader.
    static let structured: Set<String> = ["docx", "odt", "epub", "html", "md"]
    /// Inputs that carry that structure (a txt only has paragraphs; rtf / doc lose list semantics in the system reader).
    static let structuredInputs: Set<String> = ["docx", "odt", "epub", "html", "md"]
    /// Inputs that still hold the picture (a .doc / RTF made by the system from HTML, a Markdown or plain-text file do not).
    static let picturedInputs: Set<String> = ["docx", "odt", "epub", "html"]

    static func register() {
        for t in targets { registerTarget(t) }

        docTest("conformance.coverage: every document operation of the catalogue has a conformance test and the slides have theirs") {
            let ids = DocsCatalog.operations().map(\.meta.id)
            let names = SelfTestRegistry.shared.cases.filter { $0.suite == "docs" }.map(\.name)
            for id in ids where id.hasPrefix("doc.to.") {
                try expect(names.contains { $0.hasPrefix("conformance.\(id):") }, "\(id) has a conformance test")
            }
            for id in ids where id.hasPrefix("slides.to.") {
                try expect(names.contains { $0.hasPrefix("conformance.\(id):") }, "\(id) has a conformance test")
            }
            let formats = DocsCatalog.operations().filter { $0.meta.id.hasPrefix("doc.to.") }.compactMap { $0.meta.targetFormat }
            try expectEqual(Set(formats), Set(targets), "targets list is current")
        }
    }

    // MARK: One target

    private static func registerTarget(_ target: String) {
        docTest("conformance.doc.to.\(target): from every other format the result is a real \(target.uppercased()) with the text, order and structure of the source",
                proves: ["doc.format.sniff"], timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let model = DocFixtures.sample(fx)
            let out = try fx.makeDirectory("out")
            let expected = outline(of: model.blocks)
            var failures: [String] = []
            for inKey in inputs where inKey != target {
              let label = "\(inKey) -> \(target)"
              do {
                let input = try await DocFixtures.makeInput(inKey, in: fx, model: model, name: "sample.\(inKey)")
                let before = try Data(contentsOf: input)
                let url = try await DocRun.convert(input, to: target, into: out)
                // Format: the extension, the sniffed type, and not the input's bytes.
                try expectEqual(Formats.key(of: url), target, "\(label): extension")
                let mime = DocOracle.mime(url)
                try expect(DocOracle.expectedMime[target]?.contains(mime) == true, "\(label): file(1) says \(mime)")
                try expect(try Data(contentsOf: url) != before, "\(label): the output is not a copy of the input")
                try expect(TestFile.partials(in: out).isEmpty, "\(label): no in-flight files left")
                // Text: every snippet, in order, none lost to the encoding.
                let text = DocOracle.text(of: url)
                if let miss = DocOracle.firstMissing(DocFixtures.orderedTokens, in: text) { throw TestFailure(message: "\(label): the text lost or reordered \"\(miss)\"", file: #fileID, line: #line) }
                let cells = DocOracle.missingAnywhere(DocFixtures.cellTokens, in: text)
                try expect(cells.isEmpty, "\(label): table cells missing: \(cells)")
                // Structure.
                try await checkStructure(url, target: target, input: inKey, expected: expected, label: label)
                try checkFormat(url, target: target, label: label, fx: fx, picture: picturedInputs.contains(inKey), structure: structuredInputs.contains(inKey))
              } catch let f as TestFailure { failures.append(f.message) }
            }
            try expect(failures.isEmpty, failures.joined(separator: " | "))
        }
    }

    // MARK: Structure

    static func outline(of blocks: [DocBlock]) -> [String] {
        DocOracle.outline(blocks).filter { !$0.hasPrefix("hr") && !$0.contains("Swamp picture") }
    }

    private static func checkStructure(_ url: URL, target: String, input: String, expected: [String], label: String) async throws {
        guard structuredInputs.contains(input) else { return }
        var s = DocSettings(); s.target = target
        if structured.contains(target) {
            let back = try await DocNative.read(url, key: target, settings: s, ctx: nil)
            let got = outline(of: back.blocks)
            if let d = DocOracle.firstDifference(got, expected) { throw TestFailure(message: "\(label): structure after the round trip, \(d)", file: #fileID, line: #line) }
        } else if target == "rtf" {
            // RTF through the system reader: headings and tables survive; list semantics are text bullets there.
            let back = try await DocNative.read(url, key: "rtf", settings: s, ctx: nil)
            func keep(_ lines: [String]) -> [String] { lines.filter { $0.hasPrefix("h") || $0.hasPrefix("th") || $0.hasPrefix("tr") }.map { $0.hasPrefix("th ") ? "tr " + $0.dropFirst(3) : $0 } }
            if let d = DocOracle.firstDifference(keep(outline(of: back.blocks)), keep(expected)) { throw TestFailure(message: "\(label): headings and table rows after the round trip, \(d)", file: #fileID, line: #line) }
        }
    }

    // MARK: Format specifics

    private static func checkFormat(_ url: URL, target: String, label: String, fx: TestFixtures, picture: Bool, structure: Bool) throws {
        let head = TestFile.magic(url, 16)
        switch target {
        case "pdf":
            try expectEqual(String(decoding: head.prefix(5), as: UTF8.self), "%PDF-", "\(label): PDF header")
            let doc = try unwrap(PDFDocument(url: url), "\(label): PDFKit opens the result")
            try expect(doc.pageCount >= 1, "\(label): at least one page")
            let box = try unwrap(doc.page(at: 0)?.bounds(for: .mediaBox), "\(label): media box")
            try expectClose(Double(box.width), 595.2756, tolerance: 0.6, "\(label): A4 width")
            try expectClose(Double(box.height), 841.8898, tolerance: 0.6, "\(label): A4 height")
        case "docx":
            let names = DocOracle.zipNames(url)
            try expectEqual(names.first, "[Content_Types].xml", "\(label): content types first")
            try expect(names.contains("word/document.xml") && names.contains("word/styles.xml") && names.contains("word/numbering.xml"), "\(label): DOCX parts")
            if picture { try expect(names.contains { $0.hasPrefix("word/media/") }, "\(label): the picture is inside") }
            let bad = DocOracle.xmlProblems(in: url, fx: fx)
            try expect(bad.isEmpty, "\(label): xmllint rejects \(bad)")
            let doc = DocOracle.zipPart(url, "word/document.xml")
            if structure { try expect(doc.contains("w:pStyle w:val=\"Heading1\"") && doc.contains("<w:tbl>") && doc.contains("w:numId"), "\(label): real heading styles, a table and numbering") }
        case "odt":
            let names = DocOracle.zipNames(url)
            try expectEqual(names.first, "mimetype", "\(label): mimetype first")
            let listing = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-v", url.path], timeout: 20) ?? ""
            try expect(listing.split(separator: "\n").first { $0.hasSuffix(" mimetype") }?.contains("Stored") == true, "\(label): mimetype is stored, not compressed")
            try expectEqual(DocOracle.zipPart(url, "mimetype"), "application/vnd.oasis.opendocument.text", "\(label): mimetype content")
            try expect(names.contains("content.xml") && names.contains("styles.xml") && names.contains("META-INF/manifest.xml"), "\(label): ODF parts")
            if picture { try expect(names.contains { $0.hasPrefix("Pictures/") }, "\(label): the picture is inside") }
            let bad = DocOracle.xmlProblems(in: url, fx: fx)
            try expect(bad.isEmpty, "\(label): xmllint rejects \(bad)")
        case "epub":
            let names = DocOracle.zipNames(url)
            try expectEqual(names.first, "mimetype", "\(label): mimetype first")
            let listing = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-v", url.path], timeout: 20) ?? ""
            try expect(listing.split(separator: "\n").first { $0.hasSuffix(" mimetype") }?.contains("Stored") == true, "\(label): mimetype is stored")
            try expectEqual(DocOracle.zipPart(url, "mimetype"), "application/epub+zip", "\(label): mimetype content")
            try expect(names.contains("META-INF/container.xml") && names.contains("OEBPS/content.opf") && names.contains("OEBPS/nav.xhtml") && names.contains("OEBPS/toc.ncx"), "\(label): EPUB parts")
            let bad = DocOracle.xmlProblems(in: url, fx: fx)
            try expect(bad.isEmpty, "\(label): xmllint rejects \(bad)")
            let opf = DocOracle.zipPart(url, "OEBPS/content.opf")
            try expect(opf.contains("<dc:title>") && opf.contains("dcterms:modified") && opf.contains("properties=\"nav\""), "\(label): required EPUB 3 metadata")
        case "html":
            let html = try String(contentsOf: url, encoding: .utf8)
            try expect(html.hasPrefix("<!DOCTYPE html>") && html.contains("<meta charset=\"utf-8\"/>") && html.contains("<title>"), "\(label): a complete page")
            if picture { try expect(html.contains("src=\"data:image/png;base64,"), "\(label): the picture is embedded") }
        case "md":
            let md = try String(contentsOf: url, encoding: .utf8)
            if structure { try expect(md.contains("# Болотный отчёт") && md.contains("| Name | Count | Note |") && md.contains("```"), "\(label): heading, pipe table and fence in:\n\(md.prefix(600))") }
        case "txt":
            let data = try Data(contentsOf: url)
            try expect(!data.starts(with: [0xEF, 0xBB, 0xBF]), "\(label): no BOM by default")
            try expect(String(data: data, encoding: .utf8) != nil && !data.contains(13), "\(label): UTF-8 with LF line endings")
        case "rtf":
            try expectEqual(String(decoding: head.prefix(5), as: UTF8.self), "{\\rtf", "\(label): RTF header")
            try expect(TestFile.magic(url, 1_000_000).allSatisfy { $0 < 0x80 }, "\(label): 7-bit ASCII")
        default: break
        }
    }
}
