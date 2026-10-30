import Foundation
import CoreGraphics
import CoreText

// Documents, tables and subtitles with KNOWN content: the specs below say exactly what the file contains, so a converter's output can be checked
// against facts instead of against another converter.

struct DocSpec {
    var headings: [(level: Int, text: String)]
    var listItems: [String]
    var tableRows: [[String]]
    var boldPhrases: [String]
    /// Every word of the body in reading order (headings, paragraphs, list items, table cells).
    var words: String
}

struct PDFSpec {
    var url: URL
    /// The text drawn on each page, in reading order.
    var pages: [String]
}

extension ConformanceFixtures {
    // MARK: Structured documents

    static let docSpec = DocSpec(
        headings: [(1, "Swamp report"), (2, "Ingredients"), (2, "Prices"), (3, "Steps")],
        listItems: ["Flour 500 g", "Žluťoučký kůň", "Привет, мир", "Mix", "Bake"],
        tableRows: [["Name", "Qty"], ["Apples", "3"], ["Груши", "12"]],
        boldPhrases: ["introduction"],
        words: "Swamp report This is the introduction with a link to example and the sentence quoted. Ingredients Flour 500 g Žluťoučký kůň Привет, мир Prices Name Qty Apples 3 Груши 12 Steps Mix Bake Closing paragraph.")

    static let docHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Swamp report</title></head><body>
    <h1>Swamp report</h1>
    <p>This is the <strong>introduction</strong> with a link to <a href="https://example.com">example</a> and the sentence “quoted”.</p>
    <h2>Ingredients</h2>
    <ul><li>Flour 500 g</li><li>Žluťoučký kůň</li><li>Привет, мир</li></ul>
    <h2>Prices</h2>
    <table border="1"><tr><th>Name</th><th>Qty</th></tr><tr><td>Apples</td><td>3</td></tr><tr><td>Груши</td><td>12</td></tr></table>
    <h3>Steps</h3>
    <ol><li>Mix</li><li>Bake</li></ol>
    <p>Closing paragraph.</p>
    </body></html>
    """

    static let docMarkdown = """
    # Swamp report

    This is the **introduction** with a link to [example](https://example.com) and the sentence “quoted”.

    ## Ingredients

    - Flour 500 g
    - Žluťoučký kůň
    - Привет, мир

    ## Prices

    | Name | Qty |
    | --- | --- |
    | Apples | 3 |
    | Груши | 12 |

    ### Steps

    1. Mix
    2. Bake

    Closing paragraph.
    """

    @discardableResult func htmlDoc(_ name: String = "report.html") throws -> URL { try base.text(name, Self.docHTML) }
    @discardableResult func markdownDoc(_ name: String = "report.md") throws -> URL { try base.text(name, Self.docMarkdown + "\n") }

    /// RTF (via Apple's textutil from the HTML): the body text is known, the structure is whatever RTF can carry.
    func rtfDoc(_ name: String = "report.rtf") throws -> URL? {
        let html = try htmlDoc(name.replacingOccurrences(of: ".rtf", with: ".src.html"))
        let out = url(name)
        let r = ExternalProbe.run("/usr/bin/textutil", ["-convert", "rtf", html.path, "-output", out.path], timeout: 30)
        return r.status == 0 ? out : nil
    }

    /// A DOCX written by hand with real heading styles, bullet and numbered lists, a table and a bold run.
    func docx(_ name: String = "report.docx") throws -> URL {
        func p(_ text: String, style: String? = nil, list: Int? = nil, bold: String? = nil) -> String {
            var ppr = ""
            if style != nil || list != nil {
                ppr = "<w:pPr>" + (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + (list.map { "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\($0)\"/></w:numPr>" } ?? "") + "</w:pPr>"
            }
            var runs = ""
            if let b = bold, let range = text.range(of: b) {
                runs = "<w:r><w:t xml:space=\"preserve\">\(esc(String(text[text.startIndex..<range.lowerBound])))</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(esc(b))</w:t></w:r><w:r><w:t xml:space=\"preserve\">\(esc(String(text[range.upperBound...])))</w:t></w:r>"
            } else { runs = "<w:r><w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r>" }
            return "<w:p>\(ppr)\(runs)</w:p>"
        }
        func cell(_ t: String) -> String { "<w:tc><w:tcPr><w:tcW w:w=\"2400\" w:type=\"dxa\"/></w:tcPr>\(p(t))</w:tc>" }
        let table = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\"/><w:left w:val=\"single\" w:sz=\"4\"/><w:bottom w:val=\"single\" w:sz=\"4\"/><w:right w:val=\"single\" w:sz=\"4\"/><w:insideH w:val=\"single\" w:sz=\"4\"/><w:insideV w:val=\"single\" w:sz=\"4\"/></w:tblBorders></w:tblPr>"
            + Self.docSpec.tableRows.map { "<w:tr>" + $0.map(cell).joined() + "</w:tr>" }.joined() + "</w:tbl>"
        let body = p("Swamp report", style: "Heading1")
            + p("This is the introduction with a link to example and the sentence “quoted”.", bold: "introduction")
            + p("Ingredients", style: "Heading2")
            + ["Flour 500 g", "Žluťoučký kůň", "Привет, мир"].map { p($0, style: "ListParagraph", list: 1) }.joined()
            + p("Prices", style: "Heading2") + table + p("Steps", style: "Heading3")
            + ["Mix", "Bake"].map { p($0, style: "ListParagraph", list: 2) }.joined() + p("Closing paragraph.")
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles \(ns)>" + [("Heading1", "heading 1"), ("Heading2", "heading 2"), ("Heading3", "heading 3"), ("ListParagraph", "List Paragraph")]
            .map { id, name in
                // Word writes the outline level into every heading style; without it LibreOffice treats "Heading 1" as an ordinary named paragraph style and saves text:p, not text:h.
                let outline = id.hasPrefix("Heading") ? "<w:pPr><w:outlineLvl w:val=\"\((Int(id.dropFirst(7)) ?? 1) - 1)\"/></w:pPr>" : ""
                return "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/>\(outline)</w:style>"
            }.joined() + "</w:styles>"
        let numbering = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:numbering \(ns)>"
            + "<w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/></w:lvl></w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/></w:lvl></w:abstractNum>"
            + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let parts: [String: String] = [
            "[Content_Types].xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            "word/_rels/document.xml.rels": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/></Relationships>",
            "word/document.xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document \(ns)><w:body>\(body)</w:body></w:document>",
            "word/styles.xml": styles, "word/numbering.xml": numbering]
        return try zipParts(name, parts, order: ["[Content_Types].xml", "_rels/.rels", "word/_rels/document.xml.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml"])
    }

    /// An ODT written by hand (mimetype stored first, headings with outline levels, lists, a table).
    func odt(_ name: String = "report.odt") throws -> URL {
        func p(_ t: String) -> String { "<text:p>\(esc(t))</text:p>" }
        let list = { (items: [String]) in "<text:list>" + items.map { "<text:list-item>\(p($0))</text:list-item>" }.joined() + "</text:list>" }
        let table = "<table:table table:name=\"Prices\">" + Self.docSpec.tableRows.map { "<table:table-row>" + $0.map { "<table:table-cell office:value-type=\"string\">\(p($0))</table:table-cell>" }.joined() + "</table:table-row>" }.joined() + "</table:table>"
        let body = "<text:h text:outline-level=\"1\">Swamp report</text:h>" + p("This is the introduction with a link to example and the sentence “quoted”.")
            + "<text:h text:outline-level=\"2\">Ingredients</text:h>" + list(["Flour 500 g", "Žluťoučký kůň", "Привет, мир"])
            + "<text:h text:outline-level=\"2\">Prices</text:h>" + table + "<text:h text:outline-level=\"3\">Steps</text:h>" + list(["Mix", "Bake"]) + p("Closing paragraph.")
        let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" office:version=\"1.2\"><office:body><office:text>\(body)</office:text></office:body></office:document-content>"
        let manifest = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
        return try zipParts(name, ["mimetype": "application/vnd.oasis.opendocument.text", "content.xml": content, "META-INF/manifest.xml": manifest], order: ["mimetype", "content.xml", "META-INF/manifest.xml"], storeFirst: true)
    }

    private func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    /// Writes `parts` into a folder and zips it with /usr/bin/zip (an independent writer); `storeFirst` stores the first part uncompressed (ODF `mimetype`).
    func zipParts(_ name: String, _ parts: [String: String], order: [String], storeFirst: Bool = false) throws -> URL {
        let work = try folder("zipwork-" + UUID().uuidString.prefix(6))
        for (rel, content) in parts {
            let f = work.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: f)
        }
        let out = url(name)
        func zip(_ args: [String]) throws {
            let r = ExternalProbe.run("/usr/bin/zip", ["-X", "-q"] + args, timeout: 30, environment: ["PATH": "/usr/bin:/bin"], currentDirectory: work)
            if r.status != 0 { throw TestFixtures.fail("zip failed for \(name): \(r.error)") }
        }
        // zip runs inside `work` so member names are relative; the first part goes in on its own so it stays first (ODF needs `mimetype` first and stored).
        try zip([storeFirst ? "-0" : "-9", out.path, order[0]])
        if order.count > 1 { try zip(["-9", out.path] + Array(order.dropFirst())) }
        return out
    }

    // MARK: PDF

    private static let wordsEN = ["swamp", "river", "convert", "quality", "format", "archive", "margin", "signal", "frame", "record", "window", "garden", "bridge", "pattern", "number"]
    private static let wordsRU = ["болото", "река", "формат", "качество", "архив", "мост", "сигнал", "кадр", "окно", "сад", "число", "образец"]
    private static let wordsCZ = ["žluťoučký", "kůň", "příliš", "úpěl", "ďábelské", "ódy", "řeka", "máslo"]

    /// A multi-page text PDF with headings, wrapped paragraphs in three scripts and (optionally) a photographic image on every page.
    func richPDF(_ name: String = "doc.pdf", pages: Int = 3, withImage: Bool = false, size: CGSize = CGSize(width: 612, height: 792), seed: UInt64 = 5, userPassword: String? = nil, systemFont: Bool = false) throws -> PDFSpec {
        let u = url(name)
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Swamp test document", kCGPDFContextAuthor: "Swamp Converter tests"]
        if let pw = userPassword { info[kCGPDFContextUserPassword] = pw; info[kCGPDFContextOwnerPassword] = pw + "-owner" }
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, info as CFDictionary) else { throw TestFixtures.fail("cannot create PDF context") }
        var noise = Noise(seed: seed)
        let photo = withImage ? photoImage(width: 1200, height: 800, seed: seed &- 2) : nil
        var texts: [String] = []
        for p in 0..<pages {
            var pageText: [String] = []
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
            let heading = "Chapter \(p + 1): \(Self.wordsEN[(p * 3) % Self.wordsEN.count].capitalized) Привет"
            pageText.append(heading)
            drawBlock(heading, in: ctx, rect: CGRect(x: 56, y: size.height - 96, width: size.width - 112, height: 40), size: 22, bold: true, systemFont: systemFont)
            var top = size.height - 110
            for para in 0..<3 {
                var words: [String] = []
                for i in 0..<38 {
                    let r = Int(noise.unit() * 1000)
                    words.append(i % 7 == 6 ? Self.wordsRU[r % Self.wordsRU.count] : (i % 11 == 10 ? Self.wordsCZ[r % Self.wordsCZ.count] : Self.wordsEN[r % Self.wordsEN.count]))
                }
                let text = words.joined(separator: " ") + "."
                pageText.append(text)
                let height: CGFloat = withImage ? 70 : 110
                drawBlock(text, in: ctx, rect: CGRect(x: 56, y: top - height, width: size.width - 112, height: height), size: 12, bold: false, systemFont: systemFont)
                top -= height + 14
                _ = para
            }
            if let photo { ctx.draw(photo, in: CGRect(x: 56, y: 70, width: size.width - 112, height: (size.width - 112) * 2 / 3)) }
            ctx.endPDFPage()
            texts.append(pageText.joined(separator: "\n"))
        }
        ctx.closePDF()
        return PDFSpec(url: u, pages: texts)
    }

    /// `systemFont` draws with the San Francisco system font (what macOS itself uses in printed PDFs); the default is Helvetica Neue. Reason for the choice: on macOS 26
    /// PDFKit turns the Cyrillic "к" of an SF-font text layer into U+0138 on ANY re-save (checked with a plain `PDFDocument.write`), so operations are judged on both.
    private func drawBlock(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat, bold: Bool, systemFont: Bool) {
        let font: CTFont
        if systemFont { font = bold ? CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)! : CTFontCreateUIFontForLanguage(.system, size, nil)! }
        else { font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil) }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    // MARK: Tables

    /// Rows that stress a table converter: quotes, the delimiter and line breaks inside fields, leading zeros, a decimal comma, an exponent, 4-byte characters, empties.
    static let unicodeTable: [[String]] = [
        ["id", "name", "note", "amount"],
        ["007", "Žluťák", "He said \"hi\", then left", "1,5"],
        ["2", "Привет\nмир", "line1\nline2", "-3.25"],
        ["3", "日本語 𝔘", "a;b;c", "1e3"],
        ["4", "", "tab\there", ""]]

    /// An XLSX written by hand (numbers as numbers, everything else as inline strings), zipped with /usr/bin/zip.
    func xlsx(_ name: String = "table.xlsx", sheets: [(name: String, rows: [[String]])] = [("Data", ConformanceFixtures.unicodeTable)]) throws -> URL {
        func ref(_ r: Int, _ c: Int) -> String {
            var col = "", n = c + 1
            while n > 0 { col = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + col; n = (n - 1) / 26 }
            return "\(col)\(r + 1)"
        }
        var parts: [String: String] = [:]
        var order = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"]
        var overrides = "", sheetEntries = "", rels = ""
        for (i, s) in sheets.enumerated() {
            let rowsXML = s.rows.enumerated().map { (r, row) in
                "<row r=\"\(r + 1)\">" + row.enumerated().compactMap { (c, v) -> String? in
                    if v.isEmpty { return nil }
                    if TableFidelity.number(v) != nil, v.count < 16, !v.contains(",") { return "<c r=\"\(ref(r, c))\"><v>\(v)</v></c>" }
                    return "<c r=\"\(ref(r, c))\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(v))</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            parts["xl/worksheets/sheet\(i + 1).xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rowsXML)</sheetData></worksheet>"
            order.append("xl/worksheets/sheet\(i + 1).xml")
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetEntries += "<sheet name=\"\(esc(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        parts["[Content_Types].xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(overrides)</Types>"
        parts["_rels/.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        parts["xl/workbook.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEntries)</sheets></workbook>"
        parts["xl/_rels/workbook.xml.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"
        return try zipParts(name, parts, order: order)
    }

    @discardableResult
    func unicodeCSV(_ name: String = "table.csv", delimiter: Character = ",", bom: Bool = false, lineEnding: String = "\r\n") throws -> URL {
        try base.csv(name, rows: Self.unicodeTable, delimiter: delimiter, bom: bom, lineEnding: lineEnding)
    }

    // MARK: Subtitles

    static let cues: [OracleCue] = [
        OracleCue(start: 0.5, end: 2.0, text: "Hello, swamp"),
        OracleCue(start: 2.25, end: 4.0, text: "Two lines\nof text"),
        OracleCue(start: 4.5, end: 6.0, text: "<i>Italic</i> and <b>bold</b>"),
        OracleCue(start: 3600.25, end: 3602.0, text: "After one hour — Привет, мир"),
        OracleCue(start: 3602.5, end: 3604.75, text: "Žluťoučký kůň"),
        OracleCue(start: 3605.0, end: 3606.0, text: "Ünïcödé 日本語")]

    private static func stamp(_ t: Double, comma: Bool) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    @discardableResult
    func srtFile(_ name: String = "subs.srt") throws -> URL {
        let s = Self.cues.enumerated().map { "\($0.offset + 1)\n\(Self.stamp($0.element.start, comma: true)) --> \(Self.stamp($0.element.end, comma: true))\n\($0.element.text)\n" }.joined(separator: "\n")
        return try base.text(name, s)
    }

    @discardableResult
    func vttFile(_ name: String = "subs.vtt") throws -> URL {
        let s = "WEBVTT\n\nNOTE written by the conformance fixtures\n\n" + Self.cues.enumerated().map {
            "cue\($0.offset + 1)\n\(Self.stamp($0.element.start, comma: false)) --> \(Self.stamp($0.element.end, comma: false)) align:start position:10%\n\($0.element.text)\n"
        }.joined(separator: "\n")
        return try base.text(name, s)
    }
}
