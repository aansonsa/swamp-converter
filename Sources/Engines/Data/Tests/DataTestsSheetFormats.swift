import Foundation
import PDFKit

// ODS, PDF and Excel 97-2003 (.xls) in the sheet family, plus LibreOffice as a second opinion where it is installed.

enum DataTestsSheetFormats {
    /// The grid our own XLSX reader returns for a file (used to compare readers of other formats against known-good data).
    static func grid(_ url: URL) throws -> [[String]] { try SheetReader.read(url).sheets[0].rows }

    static func register() {
        registerODS()
        registerPDF()
        registerExcel97()
    }

    // MARK: ODS

    private static func registerODS() {
        dataTest("data.sheet", "csv -> ods: valid package (mimetype stored first), typed cells, bold header, widths (independent python reader)",
                 proves: ["sheet.format.sniff", "sheet.header.style", "sheet.autofit.cols", "sheet.dates.types", "sheet.allText.types"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try SheetFixtures.csv(fx)
            let out = try await SheetRun.run("sheet.to.ods", src, fx: fx)
            try expectEqual(out[0].pathExtension, "ods")
            try expectEqual(DataOracle.mime(out[0]), "application/vnd.oasis.opendocument.spreadsheet", "file(1) recognises an OpenDocument spreadsheet")
            let d = try DataOracle.ods(out[0])
            try expectEqual(d.first, "mimetype"); try expectEqual(d.firstMethod, 0, "the mimetype entry is stored, not compressed")
            try expect(d.files.contains("content.xml") && d.files.contains("META-INF/manifest.xml"), "package parts \(d.files)")
            let rows = d.sheets[0].rows
            try expectEqual(rows[0].map(\.value), SheetFixtures.rows[0])
            try expectEqual(rows[1][2].type, "float"); try expectEqual(rows[1][2].value, "42")
            try expectEqual(rows[1][3].type, "float"); try expectEqual(rows[1][3].value, "1.5")
            try expectEqual(rows[2][2].type, "string"); try expectEqual(rows[2][2].value, "007"); try expectEqual(rows[2][3].type, "string"); try expectEqual(rows[3][2].type, "string")
            try expectEqual(rows[1][4].type, "date"); try expectEqual(rows[1][4].value, "2024-01-05")
            try expectEqual(rows[2][4].type, "date"); try expectEqual(rows[2][4].value, "2024-02-06T13:45:00")
            try expectEqual(rows[3][1].value, "line1\nline2", "a cell with a line break keeps it"); try expectEqual(rows[3][0].value, "Rīga \"quoted\"")
            try expect(rows[0].allSatisfy { $0.style == "ceHead" }, "header cells are bold"); try expect(rows[1].allSatisfy { $0.style != "ceHead" })
            try expect(d.content.contains("style:column-width"), "column widths")
            // Options.
            let noHeader = try DataOracle.ods(try await SheetRun.run("sheet.to.ods", src, [SheetKeys.headerRow: false], fx: fx)[0])
            try expect(noHeader.sheets[0].rows[0].allSatisfy { $0.style != "ceHead" }, "header off")
            let noFit = try DataOracle.ods(try await SheetRun.run("sheet.to.ods", src, [SheetKeys.autoFit: false], fx: fx)[0])
            try expect(!noFit.content.contains("style:column-width"), "widths off")
            let allText = try DataOracle.ods(try await SheetRun.run("sheet.to.ods", src, [SheetKeys.allText: true], fx: fx)[0])
            try expect(allText.sheets[0].rows.flatMap { $0 }.filter { !$0.value.isEmpty }.allSatisfy { $0.type == "string" }, "everything as text")
            let noDates = try DataOracle.ods(try await SheetRun.run("sheet.to.ods", src, [SheetKeys.dates: false], fx: fx)[0])
            try expectEqual(noDates.sheets[0].rows[1][4].type, "string")
        }

        dataTest("data.sheet", "ods round trip through our own reader keeps every sheet, spaces, tabs and paragraphs") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let tricky = [["  lead", "two  spaces", "tab\there"], ["trail  ", "a\nb\n\nc", ""], ["<&>\"'", "日本語", "😀"]]
            let wb = SheetWorkbook(sheets: [SheetTable(name: "One", rows: tricky), SheetTable(name: "Two", rows: [["x"], ["y", "z"]])])
            let u = fx.url("t.ods")
            try SheetWriter.writeODS(wb, to: u)
            let back = try SheetReader.read(u)
            try expectEqual(back.sheets.map(\.name), ["One", "Two"])
            try expectEqual(back.sheets[0].rows, tricky)
            try expectEqual(back.sheets[1].rows, [["x", ""], ["y", "z"]], "rows are rectangular like a spreadsheet grid")
            try expectEqual(try DataOracle.ods(u).sheets[0].rows[0][0].value, "  lead", "the independent reader sees the leading spaces too")
        }

        dataTest("data.sheet", "LibreOffice opens our XLSX and ODS and sees the same cells (second opinion)", requires: ["tool.soffice"], timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows = [["Name", "Qty", "Price", "Note"], ["Болт", "42", "1.5", "line1\nline2"], ["Žluťák", "007", "-3.25", "a,b;c"]]
            let src = try SheetFixtures.csv(fx, rows: rows)
            for target in ["xlsx", "ods"] {
                let file = try await SheetRun.run("sheet.to.\(target)", src, fx: fx)[0]
                let csv = try DataOracle.officeConvert(file, to: "csv", filter: "Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,0", in: fx.root)
                let got = try DataOracle.csv(csv, encoding: "utf-8")
                // 007 is text in our file, so LibreOffice keeps its leading zeros; numbers keep their value.
                try expectEqual(got, rows, "\(target) as LibreOffice reads it")
            }
        }
    }

    // MARK: PDF

    private static func registerPDF() {
        dataTest("data.sheet", "xlsx -> pdf (built-in layout): a real PDF with selectable text, every cell present, header repeated on every page",
                 proves: ["sheet.format.sniff", "sheet.header.style", "sheet.pdf.mediabox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            var rows: [[String]] = [["Номер", "Название", "Цена"]]
            for i in 1...160 { rows.append(["\(i)", "Товар \(i) Žluťák", String(format: "%.2f", Double(i) * 1.25)]) }
            let src = fx.url("long.xlsx")
            try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "Прайс", rows: rows)]), to: src, boldHeader: true, autoFit: true)
            let out = try await SheetRun.run("sheet.to.pdf", src, fx: fx)
            try expectEqual(out[0].pathExtension, "pdf"); try expectEqual(DataOracle.mime(out[0]), "application/pdf")
            let doc = try unwrap(PDFDocument(url: out[0]), "PDFKit opens it")
            try expect(doc.pageCount >= 3, "160 rows need several pages: \(doc.pageCount)")
            let all = doc.string ?? ""
            for r in [1, 80, 160] { try expect(all.contains("Товар \(r) Žluťák"), "row \(r) is in the extracted text") }
            try expect(all.contains("198.75"), "numbers keep their value (trailing zeros vanish like in Excel)")
            for p in 0..<doc.pageCount { try expect((doc.page(at: p)?.string ?? "").contains("Название"), "the header is repeated on page \(p + 1)") }
            let box = try unwrap(doc.page(at: 0)?.bounds(for: .mediaBox))
            try expectClose(Double(box.width), 595.28, tolerance: 0.5, "A4 width"); try expectClose(Double(box.height), 841.89, tolerance: 0.5, "A4 height")
            // Header off: page 2 has no header line.
            let noHeader = try unwrap(PDFDocument(url: try await SheetRun.run("sheet.to.pdf", src, [SheetKeys.headerRow: false], fx: fx)[0]))
            try expect(!(noHeader.page(at: 1)?.string ?? "").contains("Название"), "no repeated header when the first row is plain data")
            // Paper and orientation.
            func mediaBox(_ o: OptionValues) async throws -> CGRect {
                let d = try unwrap(PDFDocument(url: try await SheetRun.run("sheet.to.pdf", src, o, fx: fx)[0]))
                return try unwrap(d.page(at: 0)?.bounds(for: .mediaBox))
            }
            let letter = try await mediaBox([SheetKeys.pdfPageSize: "letter"])
            try expectClose(Double(letter.width), 612, tolerance: 0.5, "Letter"); try expectClose(Double(letter.height), 792, tolerance: 0.5)
            let a3 = try await mediaBox([SheetKeys.pdfPageSize: "a3"])
            try expectClose(Double(a3.width), 841.89, tolerance: 0.5, "A3")
            let land = try await mediaBox([SheetKeys.pdfOrientation: "landscape"])
            try expect(land.width > land.height, "landscape swaps the page"); try expectClose(Double(land.width), 841.89, tolerance: 0.5)
            let port = try await mediaBox([SheetKeys.pdfOrientation: "portrait"])
            try expect(port.height > port.width)
        }

        dataTest("data.sheet", "pdf: font size changes the page count; a wide table turns the page automatically; long cells wrap instead of disappearing",
                 proves: ["sheet.pdf.fontSize.pages", "sheet.pdf.orient.mediabox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            var rows: [[String]] = [["n", "text"]]
            for i in 1...120 { rows.append(["\(i)", "row \(i)"]) }
            let src = try SheetFixtures.csv(fx, rows: rows)
            func pages(_ size: Int) async throws -> Int {
                try unwrap(PDFDocument(url: try await SheetRun.run("sheet.to.pdf", src, [SheetKeys.pdfFontSize: .int(size)], fx: fx)[0])).pageCount
            }
            let small = try await pages(6), normal = try await pages(9), big = try await pages(14)
            try expect(small < normal && normal < big, "pages grow with the font size: \(small) < \(normal) < \(big)")
            // Wide table: 14 columns of 18 characters do not fit a portrait A4 -> landscape in auto mode.
            let wide = fx.url("wide.csv")
            let wideRows = (0..<5).map { r in (0..<14).map { c in "cell-\(r)-\(c)-xxxxxxxx" } }
            var d = CSVDialect(); d.bom = false
            try SheetWriter.writeCSV(SheetTable(name: "w", rows: wideRows), to: wide, dialect: d)
            let doc = try unwrap(PDFDocument(url: try await SheetRun.run("sheet.to.pdf", wide, fx: fx)[0]))
            let box = try unwrap(doc.page(at: 0)?.bounds(for: .mediaBox))
            try expect(box.width > box.height, "automatic orientation chooses landscape for a wide table")
            try expect((doc.string ?? "").contains("cell-4-13-xxxxxxxx") || (doc.string ?? "").replacingOccurrences(of: "\n", with: "").contains("cell-4-13"), "the last column is on the page")
            // A very long cell wraps and stays complete.
            let longCell = String(repeating: "слово ", count: 120)
            let longSrc = try SheetFixtures.csv(fx, name: "longcell.csv", rows: [["a", "b"], [longCell.trimmingCharacters(in: .whitespaces), "x"]])
            let longDoc = try unwrap(PDFDocument(url: try await SheetRun.run("sheet.to.pdf", longSrc, fx: fx)[0]))
            let text = (longDoc.string ?? "").replacingOccurrences(of: "\n", with: " ")
            try expect(text.components(separatedBy: "слово").count - 1 == 120, "all 120 words were drawn: \(text.components(separatedBy: "слово").count - 1)")
        }

        dataTest("data.sheet", "pdf through LibreOffice keeps the sheet's look and differs from the built-in layout", proves: ["sheet.pdf.engine.soffice"], requires: ["tool.soffice"], timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = fx.url("book.xlsx")
            try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "Sheet", rows: SheetFixtures.rows)]), to: src, boldHeader: true, autoFit: true)
            let office = try await SheetRun.run("sheet.to.pdf", src, [SheetKeys.pdfEngine: "soffice"], fx: fx)[0]
            let doc = try unwrap(PDFDocument(url: office))
            try expect((doc.string ?? "").contains("Москва") && (doc.string ?? "").contains("Příbram"), "LibreOffice printed the cells")
            let native = try await SheetRun.run("sheet.to.pdf", src, fx: fx)[0]
            try expect(try Data(contentsOf: office) != Data(contentsOf: native), "the two layouts are really different files")
            let producer = (doc.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String) ?? ""
            try expect(producer.lowercased().contains("libreoffice"), "produced by LibreOffice: \(producer)")
            // A CSV source falls back to the built-in layout (LibreOffice would guess the encoding and delimiter itself).
            let csv = try SheetFixtures.csv(fx)
            let fallback = try unwrap(PDFDocument(url: try await SheetRun.run("sheet.to.pdf", csv, [SheetKeys.pdfEngine: "soffice"], fx: fx)[0]))
            let fbProducer = (fallback.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String) ?? ""
            try expect(!fbProducer.lowercased().contains("libreoffice"), "CSV sources use the built-in layout: \(fbProducer)")
        }
    }

    // MARK: Excel 97-2003

    private static func registerExcel97() {
        dataTest("data.sheet", "native BIFF8 reader equals the XLSX reader on files LibreOffice wrote as .xls (numbers, text, dates, booleans, several sheets, 400 rows)",
                 requires: ["tool.soffice"], timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            var big: [[String]] = [["id", "name", "value"]]
            for i in 1...400 { big.append(["\(i)", "Строка \(i) Žluťák", String(format: "%.3f", Double(i) / 7)]) }
            let wb = SheetWorkbook(sheets: [SheetTable(name: "Data", rows: SheetFixtures.rows), SheetTable(name: "Big", rows: big)])
            let xlsx = fx.url("book.xlsx")
            try SheetWriter.writeXLSX(wb, to: xlsx, boldHeader: true, autoFit: true)
            let xls = try DataOracle.officeConvert(xlsx, to: "xls", in: fx.root)
            try expect(OLE2File.looksLikeOLE2(xls), "LibreOffice wrote an OLE2 workbook")
            var o = SheetReadOptions(); o.formatted = true
            let native = try BIFF8Reader.read(xls, options: o)
            let expected = try SheetReader.read(xlsx)
            try expectEqual(native.sheets.map(\.name), expected.sheets.map(\.name))
            for (a, b) in zip(native.sheets, expected.sheets) {
                try expectEqual(a.rows.count, b.rows.count, "\(a.name) rows")
                for (i, (ra, rb)) in zip(a.rows, b.rows).enumerated() { try expectEqual(ra, rb, "\(a.name) row \(i + 1)") }
            }
            // The whole operation chain on an .xls source.
            let csv = try await SheetRun.run("sheet.to.csv", xls, [SheetKeys.sheets: "first", SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            try expectEqual(try DataOracle.csv(csv, encoding: "utf-8").count, SheetFixtures.rows.count)
        }

        dataTest("data.sheet", "ods written by LibreOffice (repeated rows and columns, covered cells, formatted values) is read like the XLSX original", requires: ["tool.soffice"], timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows: [[String]] = [["a", "b", "c", "d"], ["1", "", "", "4"], ["", "", "", ""], ["x", "y", "", "w"], ["2024-01-05", "1.5", "007", "Привет"]]
            let xlsx = fx.url("src.xlsx")
            try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "S", rows: rows)]), to: xlsx, boldHeader: true, autoFit: true)
            let ods = try DataOracle.officeConvert(xlsx, to: "ods", in: fx.root)
            let got = try SheetReader.read(ods).sheets[0].rows
            let want = try SheetReader.read(xlsx).sheets[0].rows
            try expectEqual(got, want)
        }
    }
}
