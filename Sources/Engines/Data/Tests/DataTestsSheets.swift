import Foundation

// Option-level tests of the sheet family: every field of `sheet.convert` is proven on a real run and read back with an independent oracle (python's zipfile / csv
// modules, `file`, PDFKit, LibreOffice). The conversions run through the real operations and `ctx.produceFile`.

@MainActor
enum SheetRun {
    static func operation(_ id: String) throws -> Operation {
        try unwrap(SheetCatalog.operations().first { $0.meta.id == id }, "operation \(id)")
    }

    /// Runs operation `id` on `src` in Studio mode with `options` layered over its quick recipe; the results land in a fresh folder inside the fixture root.
    @discardableResult
    static func run(_ id: String, _ src: URL, _ options: OptionValues = OptionValues(), fx: TestFixtures, mode: RunMode = .studio) async throws -> [URL] {
        let out = fx.url("out-\(Util.hex8())")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rules = OutputRules()
        rules.dirMode = .custom; rules.customDir = out.path
        let op = try operation(id)
        let items = [FileItem(url: src)]
        let ctx = OperationContext.testing(op, items: items, extra: options, mode: mode, rules: rules)
        let result = try await op.execute(items: items, ctx: ctx)
        try expect(TestFile.partials(in: out).isEmpty, "no .part leftovers: \(TestFile.partials(in: out))")
        return result.outputs
    }
}

enum SheetFixtures {
    /// Text, numbers, ids that must stay text, ISO dates, embedded newline and quotes, an empty row.
    static let rows: [[String]] = [
        ["Название", "Город", "Количество", "Цена", "Дата"],
        ["Болт М8", "Москва", "42", "1.5", "2024-01-05"],
        ["Žluťák", "Příbram", "007", "+420123456", "2024-02-06 13:45"],
        ["Rīga \"quoted\"", "line1\nline2", "NaN", "-3.25", ""],
        ["", "", "", "", ""],
        ["last", "row", "1234567890123456789", "0.5", "2024-12-31"]
    ]

    @discardableResult
    static func csv(_ fx: TestFixtures, name: String = "data.csv", rows: [[String]] = SheetFixtures.rows, delimiter: Character = ",", encoding: DataEncoding = .utf8, bom: Bool = false) throws -> URL {
        let u = fx.url(name)
        var d = CSVDialect(); d.delimiter = delimiter; d.dataEncoding = encoding; d.bom = bom
        try SheetWriter.writeCSV(SheetTable(name: "data", rows: rows), to: u, dialect: d)
        return u
    }

    static func cellText(_ c: DataOracle.Cell?) -> String { c?.value ?? "" }
}

enum DataTestsSheets {
    static func register() {
        registerXLSX()
        registerCSVOutput()
        registerNumbersAndCleaning()
        registerReading()
        DataTestsSheetFormats.register()
        DataTestsSheetReaders.register()
    }

    // MARK: XLSX

    private static func registerXLSX() {
        dataTest("data.sheet", "csv -> xlsx: numbers, ids kept as text, dates, header style, frozen header, column widths (independent python reader)",
                 proves: ["sheet.format.sniff", "sheet.header.style", "sheet.freeze.pane", "sheet.autofit.cols", "sheet.dates.types"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try SheetFixtures.csv(fx)
            let out = try await SheetRun.run("sheet.to.xlsx", src, fx: fx)
            try expectEqual(out.count, 1)
            try expectEqual(out[0].pathExtension, "xlsx")
            try expectEqual(DataOracle.mime(out[0]), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "file(1) recognises it as an Excel workbook")
            let dump = try DataOracle.xlsx(out[0])
            try expectEqual(dump.sheets.count, 1)
            let rows = dump.sheets[0].rows
            // Text survives exactly, including the line break, the quotes and Cyrillic.
            try expectEqual(SheetFixtures.cellText(rows[0][0]), "Название")
            try expectEqual(SheetFixtures.cellText(rows[2][0]), "Žluťák")
            try expectEqual(SheetFixtures.cellText(rows[3][0]), "Rīga \"quoted\"")
            try expectEqual(SheetFixtures.cellText(rows[3][1]), "line1\nline2")
            // Numbers are numbers; ids, plus-prefixed phone numbers, NaN and 19-digit values stay text.
            try expectEqual(rows[1][2]?.type, "n"); try expectEqual(rows[1][2]?.value, "42")
            try expectEqual(rows[1][3]?.type, "n"); try expectEqual(rows[1][3]?.value, "1.5")
            try expectEqual(rows[3][3]?.value, "-3.25"); try expectEqual(rows[3][3]?.type, "n")
            for (r, c) in [(2, 2), (2, 3), (3, 2), (5, 2)] { try expectEqual(rows[r][c]?.type, "s", "row \(r) col \(c) stays text: \(rows[r][c]?.value ?? "")") }
            try expectEqual(rows[2][2]?.value, "007"); try expectEqual(rows[2][3]?.value, "+420123456"); try expectEqual(rows[5][2]?.value, "1234567890123456789")
            // Dates are real dates: 2024-01-05 is serial 45296, 2024-02-06 13:45 is 45328.572916...
            try expectEqual(rows[1][4]?.type, "n"); try expectClose(Double(rows[1][4]?.value ?? "") ?? 0, 45296, tolerance: 0.0001)
            try expectClose(Double(rows[2][4]?.value ?? "") ?? 0, 45328 + (13 * 60 + 45) / 1440.0, tolerance: 0.0001)
            try expectEqual(rows[1][4]?.style, 3, "date style"); try expectEqual(rows[2][4]?.style, 4, "date-time style")
            try expect(dump.styles.contains("yyyy\\-mm\\-dd"), "the date number format exists")
            // Header: bold style on the first row, frozen pane, widths.
            for c in 0..<5 { try expectEqual(rows[0][c]?.style, 1, "header cell \(c) uses the bold style") }
            try expect(dump.styles.contains("<font><b/>"), "the bold font exists")
            try expect(dump.sheets[0].raw.contains("state=\"frozen\""), "header row frozen")
            try expect(dump.sheets[0].raw.contains("<cols>"), "column widths present")
            try expect(!dump.sheets[0].raw.contains("<autoFilter"), "no filter by default")
            try expect(dump.files.contains("[Content_Types].xml") && dump.files.contains("xl/workbook.xml"), "package parts")
        }

        dataTest("data.sheet", "xlsx options change the file: header off, freeze off, widths off, filter on, everything as text, dates off",
                 proves: ["sheet.header.style", "sheet.freeze.pane", "sheet.autofit.cols", "sheet.filter.autofilter", "sheet.allText.types", "sheet.dates.types"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try SheetFixtures.csv(fx)
            func dump(_ o: OptionValues) async throws -> DataOracle.XLSXDump { try DataOracle.xlsx(try await SheetRun.run("sheet.to.xlsx", src, o, fx: fx)[0]) }
            let noHeader = try await dump([SheetKeys.headerRow: false])
            try expectEqual(noHeader.sheets[0].rows[0][0]?.style, 0, "no bold header")
            try expect(!noHeader.sheets[0].raw.contains("state=\"frozen\""), "no frozen pane without a header")
            let noFreeze = try await dump([SheetKeys.freeze: false])
            try expect(!noFreeze.sheets[0].raw.contains("state=\"frozen\""), "freeze off")
            try expectEqual(noFreeze.sheets[0].rows[0][0]?.style, 1, "the header is still bold")
            let noFit = try await dump([SheetKeys.autoFit: false])
            try expect(!noFit.sheets[0].raw.contains("<cols>"), "no column widths")
            let filteredFile = try await SheetRun.run("sheet.to.xlsx", src, [SheetKeys.filter: true], fx: fx)[0]
            let sheetXML = String(decoding: try ZipKit.read(filteredFile, entry: "xl/worksheets/sheet1.xml"), as: UTF8.self)
            try expect(sheetXML.contains("<autoFilter ref=\"A1:E6\"/>"), "auto filter over the whole table")
            let text = try await dump([SheetKeys.allText: true])
            for row in text.sheets[0].rows { for c in row.compactMap({ $0 }) { try expectEqual(c.type, "s", "\(c.value) is text") } }
            let noDates = try await dump([SheetKeys.dates: false])
            try expectEqual(noDates.sheets[0].rows[1][4]?.type, "s", "ISO dates stay text"); try expectEqual(noDates.sheets[0].rows[1][4]?.value, "2024-01-05")
            try expectEqual(noDates.sheets[0].rows[1][2]?.type, "n", "numbers are still numbers")
        }

        dataTest("data.sheet", "xlsx sheet names are sanitised and unique; more than 1 048 576 rows is refused with a calm message") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let wb = SheetWorkbook(sheets: [SheetTable(name: "A/B:C*", rows: [["x"]]), SheetTable(name: "a/b:c*", rows: [["y"]]), SheetTable(name: "", rows: [["z"]]),
                                            SheetTable(name: String(repeating: "N", count: 40), rows: [["w"]])])
            let u = fx.url("names.xlsx")
            try SheetWriter.writeXLSX(wb, to: u, boldHeader: true, autoFit: true)
            let names = try DataOracle.xlsx(u).sheets.map(\.name)
            try expectEqual(names.count, 4)
            try expectEqual(names[0], "ABC"); try expectEqual(names[1], "abc 2"); try expectEqual(names[2], L("Sheet", "Лист")); try expectEqual(names[3].count, 31)
            let back = try SheetReader.read(u).sheets
            try expectEqual(back.map(\.name), names, "our reader agrees")
            let huge = SheetWorkbook(sheets: [SheetTable(name: "big", rows: [[String]](repeating: ["x"], count: XLSXWriter.maxRows + 1))])
            let err = try await expectThrows("too many rows") { try SheetWriter.writeXLSX(huge, to: fx.url("huge.xlsx"), boldHeader: false, autoFit: false) }
            try expect(ConversionError.describe(err).contains("1 048 576"), ConversionError.describe(err))
        }
    }

    // MARK: CSV / TSV output

    private static func registerCSVOutput() {
        dataTest("data.sheet", "xlsx -> csv: one file per sheet named \"{base} - {sheet}\", first sheet only, sheets by name",
                 proves: ["sheet.sheets.files", "sheet.sheets.names", "sheet.format.sniff"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let wb = SheetWorkbook(sheets: [SheetTable(name: "Sales", rows: [["a", "b"], ["1", "2"]]), SheetTable(name: "Empty", rows: []),
                                            SheetTable(name: "Costs/Q1", rows: [["x"], ["Привет"]])])
            let src = fx.url("book.xlsx")
            try SheetWriter.writeXLSX(wb, to: src, boldHeader: true, autoFit: true)
            let all = try await SheetRun.run("sheet.to.csv", src, fx: fx)
            try expectEqual(all.map(\.lastPathComponent).sorted(), ["book - CostsQ1.csv", "book - Sales.csv"], "empty sheets are skipped (sheet names lose / : * ? [ ] \\ when the workbook is written)")
            let sales = try unwrap(all.first { $0.lastPathComponent == "book - Sales.csv" })
            try expectEqual(try DataOracle.csv(sales, encoding: "utf-8-sig"), [["a", "b"], ["1", "2"]])
            try expect(DataOracle.mime(sales).hasPrefix("text/"), "file(1) agrees it is text: \(DataOracle.mime(sales))")
            let first = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.sheets: "first"], fx: fx)
            try expectEqual(first.map(\.lastPathComponent), ["book.csv"], "a single result keeps the plain name")
            let named = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.sheets: "names", SheetKeys.sheetNames: "costsq1"], fx: fx)
            try expectEqual(named.map(\.lastPathComponent), ["book.csv"]); try expectEqual(try DataOracle.csv(named[0], encoding: "utf-8-sig"), [["x"], ["Привет"]])
            let err = try await expectThrows("a name that does not exist") { _ = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.sheets: "names", SheetKeys.sheetNames: "Nope"], fx: fx) }
            try expect(ConversionError.describe(err).contains("Sales"), "the message lists the real names: \(ConversionError.describe(err))")
            let xlsxNamed = try await SheetRun.run("sheet.to.xlsx", src, [SheetKeys.sheets: "names", SheetKeys.sheetNames: "Sales, CostsQ1"], fx: fx)
            try expectEqual(try DataOracle.xlsx(xlsxNamed[0]).sheets.map(\.name), ["Sales", "CostsQ1"], "xlsx output keeps only the named sheets")
        }

        dataTest("data.sheet", "csv output: delimiter, encodings with exact bytes, BOM, line endings, quote-all, TSV",
                 proves: ["sheet.delim.out.bytes", "sheet.enc.out.bytes", "sheet.eol.bytes", "sheet.quoteAll.bytes", "sheet.format.sniff"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows = [["Название", "Город"], ["Болт; \"М8\"", "Москва"], ["три\nстроки", "x|y"]]
            let src = try SheetFixtures.csv(fx, rows: rows)
            func result(_ o: OptionValues, op: String = "sheet.to.csv") async throws -> URL { try await SheetRun.run(op, src, o, fx: fx)[0] }
            // Defaults: UTF-8 with BOM, comma, CRLF.
            let def = try await result([:])
            let defBytes = try Data(contentsOf: def)
            try expectEqual(Array(defBytes.prefix(3)), [0xEF, 0xBB, 0xBF]); try expect(String(decoding: defBytes, as: UTF8.self).contains("\r\n"))
            try expectEqual(try DataOracle.csv(def, encoding: "utf-8-sig"), rows)
            // Semicolon and pipe.
            try same(try DataOracle.csv(try await result([SheetKeys.delimiterOut: "semicolon"]), encoding: "utf-8-sig", delimiter: ";"), rows)
            try same(try DataOracle.csv(try await result([SheetKeys.delimiterOut: "pipe"]), encoding: "utf-8-sig", delimiter: "|"), rows)
            // Encodings: the bytes decode with the matching python codec.
            let noBOM = try await result([SheetKeys.encodingOut: "utf-8"])
            try expect(Array(try Data(contentsOf: noBOM).prefix(3)) != [0xEF, 0xBB, 0xBF], "utf-8 without a BOM"); try expectEqual(try DataOracle.csv(noBOM, encoding: "utf-8"), rows)
            let u16 = try await result([SheetKeys.encodingOut: "utf-16"])
            try expectEqual(Array(try Data(contentsOf: u16).prefix(2)), [0xFF, 0xFE]); try expectEqual(try DataOracle.csv(u16, encoding: "utf-16"), rows)
            for (key, codec) in [("windows-1251", "cp1251"), ("koi8-r", "koi8_r"), ("cp866", "cp866")] {
                try same(try DataOracle.csv(try await result([SheetKeys.encodingOut: .string(key)]), encoding: codec), rows, key)
            }
            let latvian = try SheetFixtures.csv(fx, name: "lv.csv", rows: [["Rīga", "Ķekava"], ["ūdens", "Šodien"]])
            let lv = try await SheetRun.run("sheet.to.csv", latvian, [SheetKeys.encodingOut: "windows-1257"], fx: fx)[0]
            try expectEqual(try DataOracle.csv(lv, encoding: "cp1257"), [["Rīga", "Ķekava"], ["ūdens", "Šodien"]])
            // Line endings and quoting.
            let lf = try Data(contentsOf: try await result([SheetKeys.lineEnding: "lf", SheetKeys.encodingOut: "utf-8"]))
            try expect(!lf.contains(0x0D) && lf.contains(0x0A), "LF only")
            let crlf = String(decoding: try Data(contentsOf: noBOM), as: UTF8.self)
            try expect(crlf.hasPrefix("Название,Город\r\n"), "CRLF default: \(crlf.debugDescription)")
            let quoted = String(decoding: try Data(contentsOf: try await result([SheetKeys.quoteAll: true, SheetKeys.encodingOut: "utf-8"])), as: UTF8.self)
            try expect(quoted.hasPrefix("\"Название\",\"Город\"\r\n"), "quote everything: \(quoted.debugDescription)")
            let plain = String(decoding: try Data(contentsOf: noBOM), as: UTF8.self)
            try expect(plain.hasPrefix("Название,Город") && !plain.hasPrefix("\"Название\""), "only fields that need quotes are quoted")
            // TSV: tab delimiter, tabs inside a value become spaces.
            let tabSrc = try SheetFixtures.csv(fx, name: "tab.csv", rows: [["a", "b\tc"], ["1", "2"]])
            let tsv = try await SheetRun.run("sheet.to.tsv", tabSrc, [SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            try expectEqual(tsv.pathExtension, "tsv")
            try expectEqual(try DataOracle.csv(tsv, encoding: "utf-8", delimiter: "\t"), [["a", "b c"], ["1", "2"]])
        }
    }

    // MARK: Numbers, decimal marks, cleaning

    private static func registerNumbersAndCleaning() {
        dataTest("data.sheet", "decimal marks: comma numbers become real numbers in xlsx only when declared; csv output rewrites 1.5 <-> 1,5; text is left alone",
                 proves: ["sheet.decimal.in.parse", "sheet.decimal.out.text"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows = [["item", "price", "code", "note"], ["bolt", "1,5", "007,5", "see 1,5 later"], ["nut", "12,25", "1.234,5", "2024-01-05"], ["pi", "3.14", "-0,5", "1,5,6"]]
            let src = try SheetFixtures.csv(fx, rows: rows, delimiter: ";")
            let asComma = try DataOracle.xlsx(try await SheetRun.run("sheet.to.xlsx", src, [SheetKeys.decimalIn: "comma"], fx: fx)[0]).sheets[0].rows
            try expectEqual(asComma[1][1]?.type, "n"); try expectEqual(asComma[1][1]?.value, "1.5", "1,5 is the number 1.5")
            try expectEqual(asComma[2][1]?.value, "12.25"); try expectEqual(asComma[3][1]?.value, "3.14", "dots still work")
            try expectEqual(asComma[3][2]?.value, "-0.5", "negative comma decimals")
            try expectEqual(asComma[1][2]?.type, "s", "007,5 keeps its leading zeros"); try expectEqual(asComma[2][2]?.type, "s", "1.234,5 has thousands marks")
            try expectEqual(asComma[1][3]?.type, "s", "words are text")
            let asDot = try DataOracle.xlsx(try await SheetRun.run("sheet.to.xlsx", src, [:], fx: fx)[0]).sheets[0].rows
            try expectEqual(asDot[1][1]?.type, "s"); try expectEqual(asDot[1][1]?.value, "1,5"); try expectEqual(asDot[3][1]?.type, "n")
            // CSV -> CSV: decimal rewriting uses the declared source mark.
            let toDot = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.decimalIn: "comma", SheetKeys.decimal: "dot", SheetKeys.delimiterOut: "semicolon", SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            let dotRows = try DataOracle.csv(toDot, encoding: "utf-8", delimiter: ";")
            try expectEqual(dotRows[1], ["bolt", "1.5", "007,5", "see 1,5 later"]); try expectEqual(dotRows[2][1], "12.25"); try expectEqual(dotRows[3][2], "-0.5")
            try expectEqual(dotRows[2][2], "1.234,5", "not a plain number: untouched"); try expectEqual(dotRows[3][1], "3.14")
            let toComma = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.decimal: "comma", SheetKeys.delimiterOut: "semicolon", SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            let commaRows = try DataOracle.csv(toComma, encoding: "utf-8", delimiter: ";")
            try expectEqual(commaRows[3][1], "3,14", "dot decimals become commas"); try expectEqual(commaRows[1][1], "1,5", "comma decimals stay (the source mark is the dot)")
            // XLSX numbers -> CSV with the chosen mark.
            let numbers = fx.url("numbers.xlsx")
            try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "n", rows: [["v"], ["1.5"], ["-2.75"], ["10"]])]), to: numbers, boldHeader: true, autoFit: true)
            let xl = try await SheetRun.run("sheet.to.csv", numbers, [SheetKeys.decimal: "comma", SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            try expectEqual(try DataOracle.csv(xl, encoding: "utf-8"), [["v"], ["1,5"], ["-2,75"], ["10"]])
        }

        dataTest("data.sheet", "trim and skip-empty clean the cells in every output", proves: ["sheet.trim.cells", "sheet.skipEmpty.rows"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows = [["  a ", "\u{00A0}b\t"], ["", ""], ["  ", " "], ["c", "d"]]
            let src = try SheetFixtures.csv(fx, rows: rows)
            func csv(_ o: OptionValues) async throws -> [[String]] {
                var all = o; all[SheetKeys.encodingOut] = "utf-8"
                return try DataOracle.csv(try await SheetRun.run("sheet.to.csv", src, all, fx: fx)[0], encoding: "utf-8")
            }
            try same(try await csv([:]), rows, "nothing changes by default")
            try same(try await csv([SheetKeys.trimCells: true]), [["a", "b"], ["", ""], ["", ""], ["c", "d"]], "spaces, tabs and no-break spaces are trimmed")
            try same(try await csv([SheetKeys.skipEmpty: true]), [["  a ", "\u{00A0}b\t"], ["  ", " "], ["c", "d"]], "only rows without any value are dropped")
            try same(try await csv([SheetKeys.skipEmpty: true, SheetKeys.trimCells: true]), [["a", "b"], ["c", "d"]], "trim first, then rows of blanks count as empty")
            let x = try DataOracle.xlsx(try await SheetRun.run("sheet.to.xlsx", src, [SheetKeys.trimCells: true, SheetKeys.skipEmpty: true], fx: fx)[0]).sheets[0].rows
            try expectEqual(x.count, 2); try expectEqual(SheetFixtures.cellText(x[0][0]), "a")
            let inner = fx.url("inner.csv"); try Data("a  b ,\" c \"\r\n".utf8).write(to: inner)
            try same(try DataOracle.csv(try await SheetRun.run("sheet.to.csv", inner, [SheetKeys.trimCells: true, SheetKeys.encodingOut: "utf-8"], fx: fx)[0], encoding: "utf-8"), [["a  b", "c"]], "inner spaces stay")
        }
    }

    // MARK: Reading

    private static func registerReading() {
        dataTest("data.sheet", "reading options end to end: Windows-1251 and Baltic sources, wrong encoding changes the text, explicit delimiter", proves: ["sheet.enc.in.decode", "sheet.delim.in.parse"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows = [["имя", "город"], ["Иван", "Москва"], ["Мария", "Санкт-Петербург"]]
            let src = try SheetFixtures.csv(fx, name: "ru1251.csv", rows: rows, delimiter: ";", encoding: .windows1251)
            let auto = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            try expectEqual(try DataOracle.csv(auto, encoding: "utf-8"), rows, "automatic detection converts a Windows-1251 file to readable UTF-8")
            let forced = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.encodingIn: "koi8-r", SheetKeys.encodingOut: "utf-8"], fx: fx)[0]
            try expect(try DataOracle.csv(forced, encoding: "utf-8") != rows, "an explicit (wrong) source encoding is honoured")
            let lv = try SheetFixtures.csv(fx, name: "lv1257.csv", rows: [["pilsēta", "ielā"], ["Rīga", "Šķūņu"]], delimiter: ";", encoding: .windows1257)
            let viaXLSX = try DataOracle.xlsx(try await SheetRun.run("sheet.to.xlsx", lv, fx: fx)[0]).sheets[0].rows
            try expectEqual(SheetFixtures.cellText(viaXLSX[1][1]), "Šķūņu"); try expectEqual(SheetFixtures.cellText(viaXLSX[1][0]), "Rīga")
            // Delimiter: "a;b,c" is ambiguous; the explicit choice decides.
            let amb = fx.url("amb.csv"); try Data("a;b,c\r\n1;2,3\r\n".utf8).write(to: amb)
            let semi = try await SheetRun.run("sheet.to.csv", amb, [SheetKeys.delimiter: "semicolon", SheetKeys.encodingOut: "utf-8", SheetKeys.delimiterOut: "pipe"], fx: fx)[0]
            try expectEqual(try DataOracle.csv(semi, encoding: "utf-8", delimiter: "|"), [["a", "b,c"], ["1", "2,3"]])
            let comma = try await SheetRun.run("sheet.to.csv", amb, [SheetKeys.delimiter: "comma", SheetKeys.encodingOut: "utf-8", SheetKeys.delimiterOut: "pipe"], fx: fx)[0]
            try expectEqual(try DataOracle.csv(comma, encoding: "utf-8", delimiter: "|"), [["a;b", "c"], ["1;2", "3"]])
        }
    }
}
