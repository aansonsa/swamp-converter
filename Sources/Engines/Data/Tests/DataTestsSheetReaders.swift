import Foundation

// Reader robustness: an XLSX made by hand with the features real workbooks use (inline strings, rich text, phonetic runs, formulas with cached values, booleans, errors, number
// formats, the 1904 date system, gaps, hidden sheets), hidden sheets through every writer, and the probe.

enum DataTestsSheetReaders {
    static func handMadeXLSX(_ url: URL) throws {
        let ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let w = try ZipWriter(url: url, level: 6)
        try w.add(data: Data((head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>").utf8), as: "[Content_Types].xml")
        try w.add(data: Data((head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>").utf8), as: "_rels/.rels")
        try w.add(data: Data((head + "<workbook \(ns) xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><workbookPr date1904=\"1\"/><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Secret\" sheetId=\"2\" state=\"hidden\" r:id=\"rId2\"/></sheets></workbook>").utf8), as: "xl/workbook.xml")
        try w.add(data: Data((head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"/xl/worksheets/sheet2.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/><Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>").utf8), as: "xl/_rels/workbook.xml.rels")
        try w.add(data: Data((head + "<styleSheet \(ns)><numFmts count=\"2\"><numFmt numFmtId=\"165\" formatCode=\"#,##0.00\\ &quot;€&quot;\"/><numFmt numFmtId=\"166\" formatCode=\"yyyy\\-mm\\-dd\\ hh:mm\"/></numFmts><cellXfs count=\"6\"><xf numFmtId=\"0\"/><xf numFmtId=\"10\"/><xf numFmtId=\"4\"/><xf numFmtId=\"165\"/><xf numFmtId=\"14\"/><xf numFmtId=\"166\"/></cellXfs></styleSheet>").utf8), as: "xl/styles.xml")
        try w.add(data: Data((head + "<sst \(ns) count=\"3\" uniqueCount=\"3\"><si><r><t>Hel</t></r><r><rPr><b/></rPr><t>lo</t></r></si><si><t xml:space=\"preserve\">  spaced  </t><rPh sb=\"0\" eb=\"1\"><t>PHONETIC</t></rPh></si><si><t>Привет_x0041_</t></si></sst>").utf8), as: "xl/sharedStrings.xml")
        let sheet1 = head + "<worksheet \(ns)><sheetData>"
            + "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>inline text</t></is></c><c r=\"B1\" t=\"s\"><v>0</v></c><c r=\"C1\"><v>3.5</v></c><c r=\"D1\" t=\"b\"><v>1</v></c><c r=\"E1\" t=\"e\"><v>#DIV/0!</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\"><f>1+1</f><v>2</v></c><c r=\"B2\" t=\"str\"><f>CONCATENATE(\"a\",\"bc\")</f><v>abc</v></c><c r=\"C2\" t=\"s\"><v>1</v></c><c r=\"D2\" t=\"s\"><v>2</v></c></row>"
            + "<row r=\"3\"><c r=\"A3\" s=\"4\"><v>40000</v></c><c r=\"B3\" s=\"5\"><v>40000.5625</v></c></row>"
            + "<row r=\"4\"><c r=\"A4\" s=\"1\"><v>0.255</v></c><c r=\"B4\" s=\"2\"><v>1234567.891</v></c><c r=\"C4\" s=\"3\"><v>1234.5</v></c><c r=\"D4\"><v>1E+25</v></c><c r=\"E4\"><v>0.1</v></c></row>"
            + "<row r=\"6\"><c r=\"C6\" t=\"inlineStr\"><is><t>x</t></is></c></row>"
            + "<row r=\"8\"><c r=\"A8\" t=\"inlineStr\"><is><t>a&amp;b &lt;c&gt;</t></is></c></row></sheetData></worksheet>"
        try w.add(data: Data(sheet1.utf8), as: "xl/worksheets/sheet1.xml")
        try w.add(data: Data((head + "<worksheet \(ns)><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>secret</t></is></c></row></sheetData></worksheet>").utf8), as: "xl/worksheets/sheet2.xml")
        try w.finish()
    }

    static func register() {
        dataTest("data.sheet", "XLSX reader on a hand-made workbook: inline and shared strings, rich text, formulas, booleans, errors, formats, 1904 dates, gaps, hidden sheet") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let u = fx.url("hand.xlsx")
            try handMadeXLSX(u)
            let wb = try SheetReader.read(u)
            try expectEqual(wb.sheets.map(\.name), ["Data", "Secret"]); try expectEqual(wb.sheets.map(\.hidden), [false, true], "hidden sheets are kept and marked")
            let rows = wb.sheets[0].rows
            try expectEqual(rows[0], ["inline text", "Hello", "3.5", "TRUE", "#DIV/0!"])
            try expectEqual(rows[1][0], "2", "cached formula result"); try expectEqual(rows[1][1], "abc"); try expectEqual(rows[1][2], "  spaced  ", "phonetic runs are not text"); try expectEqual(rows[1][3], "Привет_x0041_".replacingOccurrences(of: "_x0041_", with: "A"), "Excel escapes _x0041_")
            try expectEqual(rows[2][0], "2013-07-07", "the 1904 date system"); try expectEqual(rows[2][1], "2013-07-07 13:30:00")
            try expectEqual(rows[3][0], "25.50%"); try expectEqual(rows[3][1], "1,234,567.89"); try expectEqual(rows[3][2], "1,234.50 €"); try expectEqual(rows[3][3], "1E+25", "General format as Excel prints it"); try expectEqual(rows[3][4], "0.1")
            try expectEqual(rows[4], ["", "", "", "", ""], "a gap row is an empty row"); try expectEqual(rows[5], ["", "", "x", "", ""]); try expectEqual(rows[6], ["", "", "", "", ""]); try expectEqual(rows[7][0], "a&b <c>")
            try expectEqual(wb.sheets[1].rows, [["secret"]])
            var raw = SheetReadOptions(); raw.formatted = false
            let stored = try SheetReader.read(u, options: raw).sheets[0].rows
            try expectEqual(stored[3][0], "0.255", "unformatted: the stored value"); try expectEqual(stored[2][0], "40000")
            try expectEqual(try SheetReader.preview(u, maxRows: 2).sheets.count, 1, "a preview reads the first visible sheet only")
            try expectEqual(try SheetReader.preview(u, maxRows: 2).sheets[0].rows.count, 2)
        }

        dataTest("data.sheet", "hidden sheets stay hidden through xlsx and ods writers, and \"first sheet\" means the first visible one", proves: ["sheet.sheets.files"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = fx.url("hand.xlsx"); try handMadeXLSX(src)
            let xlsx = try unwrap(try await SheetRun.run("sheet.to.xlsx", src, fx: fx).first)
            try expect(String(decoding: try ZipKit.read(xlsx, entry: "xl/workbook.xml"), as: UTF8.self).contains("state=\"hidden\""), "hidden in the xlsx")
            let ods = try unwrap(try await SheetRun.run("sheet.to.ods", src, fx: fx).first)
            try expectEqual(try SheetReader.read(ods).sheets.map(\.hidden), [false, true], "hidden in the ods")
            try expectEqual(try DataOracle.ods(ods).sheets.map(\.name), ["Data", "Secret"])
            let all = try await SheetRun.run("sheet.to.csv", src, fx: fx)
            try expectEqual(all.map(\.lastPathComponent).sorted(), ["hand - Data.csv", "hand - Secret.csv"], "nothing is dropped silently")
            // A workbook whose FIRST sheet is hidden previews and converts its first visible sheet.
            let wb = SheetWorkbook(sheets: [SheetTable(name: "calc", rows: [["h"]], hidden: true), SheetTable(name: "report", rows: [["visible"]])])
            let u = fx.url("firsthidden.xlsx"); try SheetWriter.writeXLSX(wb, to: u, boldHeader: true, autoFit: true)
            try expectEqual(try SheetReader.preview(u).sheets.map(\.name), ["report"])
            let first = try await SheetRun.run("sheet.to.csv", u, [SheetKeys.sheets: "first", SheetKeys.encodingOut: "utf-8"], fx: fx)
            try expectEqual(try DataOracle.csv(first[0], encoding: "utf-8"), [["visible"]])
        }

        dataTest("data.sheet", "the probe reads rows, columns, sheets, encoding and delimiter without converting; big files are estimated and say so") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let csv = try SheetFixtures.csv(fx, name: "p.csv", rows: [["имя", "город", "число"], ["Иван", "Москва", "3"], ["Мария", "Омск", "6"]], delimiter: ";", encoding: .windows1251)
            let info = await SheetSourceProbe().probe(FileItem(url: csv))
            try expectEqual(info.int("table.rows"), 3); try expectEqual(info.int("table.columns"), 3); try expectEqual(info.string("table.delimiter"), "semicolon"); try expectEqual(info.string("text.encoding"), "Windows-1251")
            try expectEqual(info.bool("table.estimated"), false)
            try expect(info.chips.contains { $0.text == "Windows-1251" } && info.chips.contains { $0.text.contains(";") }, "chips: \(info.chips.map(\.text))")
            let xlsx = fx.url("p.xlsx")
            try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "One", rows: (0..<50).map { ["\($0)", "x"] }), SheetTable(name: "Two", rows: [["y"]])]), to: xlsx, boldHeader: true, autoFit: true)
            let xi = await SheetSourceProbe().probe(FileItem(url: xlsx))
            try expectEqual(xi.int("table.sheets"), 2); try expectEqual(xi.int("table.rows"), 50); try expectEqual(xi.int("table.columns"), 2); try expectEqual(xi.string("table.sheet.1.name"), "Two")
            try expect(xi.chips.contains { $0.text == "2 sheets" || $0.text == "2 листа" }, "chips: \(xi.chips.map(\.text))")
            let ods = fx.url("p.ods"); try SheetWriter.writeODS(SheetWorkbook(sheets: [SheetTable(name: "S", rows: [["a", "b"], ["c", "d"]])]), to: ods)
            let oi = await SheetSourceProbe().probe(FileItem(url: ods))
            try expectEqual(oi.int("table.rows"), 2); try expectEqual(oi.string("table.kind"), "ods")
            // A file past the full-parse limit is sampled.
            let big = fx.url("big.csv")
            let w = try CSVRowWriter(url: big, dialect: CSVDialect())
            for i in 0..<400_000 { try w.write(row: ["\(i)", "value number \(i)", "some more text to fill the row"]) }
            try w.finish()
            let t0 = Date()
            let bi = await SheetSourceProbe().probe(FileItem(url: big))
            try expect(Date().timeIntervalSince(t0) < 1.5, "the probe of a \(TestFile.size(big) / 1_000_000) MB file took \(Date().timeIntervalSince(t0)) s")
            try expectEqual(bi.bool("table.estimated"), true)
            let rows = try unwrap(bi.int("table.rows")); try expect(abs(rows - 400_000) < 12_000, "estimated \(rows) rows")
            try expect(bi.chips.contains { $0.text.hasPrefix("~") }, "the chip says it is approximate")
            // Validation: an XLSX target is refused above its row limit.
            let op = try SheetRun.operation("sheet.to.xlsx")
            var huge = SourceInfo(url: big, kind: .spreadsheet); huge.facts["table.rows"] = .int(2_000_000)
            try expect(op.validate(options: [SheetKeys.format: "xlsx"], source: huge).contains { $0.severity == .error }, "error above 1 048 576 rows")
            try expect(op.validate(options: [SheetKeys.format: "csv"], source: huge).isEmpty, "CSV has no row limit")
        }

        dataTest("data.sheet", "estimates, summary chips and quick recipes of the five spreadsheet operations") {
            let ops = SheetCatalog.operations()
            try expectEqual(ops.map(\.meta.id), ["sheet.to.xlsx", "sheet.to.csv", "sheet.to.tsv", "sheet.to.ods", "sheet.to.pdf"])
            for op in ops {
                let quick = op.quickOverrides(settings: SettingsData())
                let target = try unwrap(quick[SheetKeys.format]?.asString)
                try expectEqual(op.meta.targetFormat, target, "\(op.meta.id): the quick recipe and the wheel tile agree")
                try expectEqual(op.optionSchema(for: []).id, op.meta.schemaID)
                let chips = op.summaryChips(options: quick, source: nil)
                try expectEqual(chips.first, Formats.displayName(target))
                let item = FileItem(url: URL(fileURLWithPath: "/tmp/x.csv"), isDirectory: false, size: 1_000_000)
                let est = try unwrap(op.estimate(options: quick, items: [item], source: nil))
                try expect((est.bytes ?? 0) > 0, "\(op.meta.id) estimates a size")
                let resolved = op.optionSchema(for: []).resolve(layers: [quick])
                try expect(!resolved.hasErrors, "\(op.meta.id) quick recipe resolves without errors: \(resolved.messages.map(\.id))")
            }
            let csv = ops[1]
            try expectEqual(csv.summaryChips(options: [SheetKeys.format: "csv", SheetKeys.delimiterOut: "semicolon", SheetKeys.encodingOut: "windows-1251"], source: nil), ["CSV", "Windows-1251", L("delimiter ;", "разделитель ;")])
        }
    }
}
