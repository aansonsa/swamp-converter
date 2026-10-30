import Foundation

// The sheet runner: read (SheetReader) -> pick sheets -> clean cells -> write one of xlsx / csv / tsv / ods / pdf, always through ctx.produceFile (hidden .part, atomic
// move, "(2)" names, nothing left behind on error or cancel). Delimited text to delimited text is STREAMED row by row (constant memory, any file size); everything else
// goes through an in-memory SheetWorkbook. The behaviour is a pure function of (file, ctx.options): it never looks at the operation id.

enum SheetConvert {
    struct Settings {
        var format: String
        var readOptions: SheetReadOptions
        var rowTransform: SheetRowTransform
        var sheetMode: String
        var sheetNames: String
        var dialect: CSVDialect
        var xlsx: XLSXWriteOptions
        var pdf: SheetPDFOptions
        var pdfEngine: String

        init(_ o: OptionValues) {
            format = o.string(SheetKeys.format, "xlsx")
            var ro = SheetReadOptions()
            let encKey = o.string(SheetKeys.encodingIn, "auto")
            ro.encoding = encKey == "auto" ? nil : DataEncoding(key: encKey)
            let delimKey = o.string(SheetKeys.delimiter, "auto")
            ro.delimiter = delimKey == "auto" ? nil : SheetTransforms.delimiterByte(delimKey)
            readOptions = ro

            let decimalIn: Character = o.string(SheetKeys.decimalIn, "dot") == "comma" ? "," : "."
            var t = SheetRowTransform()
            t.trim = o.bool(SheetKeys.trimCells)
            t.skipEmpty = o.bool(SheetKeys.skipEmpty)
            t.decimalIn = decimalIn
            switch o.string(SheetKeys.decimal, "keep") {
            case "dot": t.decimalOut = "."
            case "comma": t.decimalOut = ","
            default: t.decimalOut = nil
            }
            rowTransform = t
            sheetMode = o.string(SheetKeys.sheets, "all")
            sheetNames = o.string(SheetKeys.sheetNames)

            var d = CSVDialect()
            let delimOut = o.string(SheetKeys.delimiterOut, "comma")
            d.delimiter = format == "tsv" ? "\t" : Character(UnicodeScalar(SheetTransforms.delimiterByte(delimOut) ?? 0x2C))
            let (enc, bom) = SheetTransforms.outputEncoding(o.string(SheetKeys.encodingOut, "utf-8-bom"))
            d.dataEncoding = enc
            d.bom = bom
            d.crlf = o.string(SheetKeys.lineEnding, "crlf") != "lf"
            d.quoteAll = o.bool(SheetKeys.quoteAll)
            dialect = d

            var x = XLSXWriteOptions()
            let header = o.bool(SheetKeys.headerRow, true)
            x.boldHeader = header
            x.autoFit = o.bool(SheetKeys.autoFit, true)
            x.freezeHeader = header && o.bool(SheetKeys.freeze, true)
            x.autoFilter = o.bool(SheetKeys.filter)
            x.allText = o.bool(SheetKeys.allText)
            x.dates = o.bool(SheetKeys.dates, true)
            x.commaDecimal = decimalIn == ","
            xlsx = x

            var p = SheetPDFOptions()
            p.paperKey = o.string(SheetKeys.pdfPageSize, "a4")
            p.orientation = o.string(SheetKeys.pdfOrientation, "auto")
            p.fontSize = CGFloat(o.int(SheetKeys.pdfFontSize, 9))
            p.repeatHeader = header
            pdf = p
            pdfEngine = o.string(SheetKeys.pdfEngine, "native")
        }
    }

    static func run(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        var s = Settings(ctx.options)
        s.pdf.title = item.base
        let kind = SheetFileKind.detect(item.url)
        let delimitedSource = kind == .csv || kind == .tsv
        let delimitedTarget = s.format == "csv" || s.format == "tsv"
        if delimitedSource && delimitedTarget && s.sheetMode != "names" {
            return try await streamDelimited(item, kind: kind ?? .csv, ctx: ctx, progress: progress, settings: s)
        }
        if s.format == "pdf" && s.pdfEngine == "soffice" {
            if let office = try await officePDF(item, kind: kind, ctx: ctx, settings: s) { return [office] }
        }

        progress.report(0.02)
        try ctx.checkCancelled()
        var ro = s.readOptions
        if kind == .tsv && ro.delimiter == nil { ro.delimiter = 0x09 }
        let workbook = try SheetReader.read(item.url, options: ro)
        if let enc = workbook.detectedEncoding, let d = workbook.detectedDelimiter {
            ctx.log("Source: \(enc), delimiter \(CSVSniffer.name(of: d.asciiValue ?? 0x2C))")
        }
        progress.report(0.45)
        try ctx.checkCancelled()
        let chosen = try SheetTransforms.select(workbook.sheets, mode: s.sheetMode, names: s.sheetNames)
        let tables = SheetTransforms.applyRows(chosen, s.rowTransform)
        let out = SheetWorkbook(sheets: tables.isEmpty ? [SheetTable(name: item.base, rows: [])] : tables)

        switch s.format {
        case "xlsx":
            let url = try await ctx.produceFile(for: item, ext: "xlsx") { temp in
                let report = try XLSXWriter.write(out, to: temp, options: s.xlsx)
                if report.truncatedCells > 0 { ctx.log("\(report.truncatedCells) cells were longer than Excel allows and were shortened.") }
            }
            progress.report(1)
            return [url]
        case "ods":
            let url = try await ctx.produceFile(for: item, ext: "ods") { temp in
                let report = try ODSWriter.write(out, to: temp, options: s.xlsx)
                if report.truncatedCells > 0 { ctx.log("\(report.truncatedCells) cells were shortened.") }
            }
            progress.report(1)
            return [url]
        case "pdf":
            let url = try await ctx.produceFile(for: item, ext: "pdf") { temp in try SheetPDF.write(out.sheets, to: temp, options: s.pdf) }
            progress.report(1)
            return [url]
        default:
            return try await writeDelimited(out.sheets, item: item, ctx: ctx, progress: progress, settings: s)
        }
    }

    // MARK: CSV / TSV

    /// One file per non-empty sheet (the first sheet when all are empty); several files are named "{base} - {sheet}".
    private static func writeDelimited(_ tables: [SheetTable], item: FileItem, ctx: OperationContext, progress: ProgressSlice, settings s: Settings) async throws -> [URL] {
        var targets = tables.filter { !$0.rows.isEmpty }
        if targets.isEmpty, let first = tables.first { targets = [first] }
        var urls: [URL] = []
        let base = ctx.outputBaseName(for: item)
        for (i, t) in targets.enumerated() {
            try ctx.checkCancelled()
            let name = targets.count > 1 ? "\(base) - \(Util.safeFileName(t.name, fallback: "Sheet \(i + 1)"))" : nil
            let url = try await ctx.produceFile(for: item, ext: s.format, base: name) { temp in
                let report = try SheetWriter.writeCSVReporting(t, to: temp, dialect: s.dialect)
                if report.replacedCharacters > 0 { ctx.log("\(report.replacedCharacters) characters are not in the chosen encoding and were replaced.") }
            }
            urls.append(url)
            progress.report(0.5 + 0.5 * Double(i + 1) / Double(targets.count))
        }
        return urls
    }

    /// CSV / TSV -> CSV / TSV without ever holding the table in memory.
    private static func streamDelimited(_ item: FileItem, kind: SheetFileKind, ctx: OperationContext, progress: ProgressSlice, settings s: Settings) async throws -> [URL] {
        var cro = CSVReadOptions()
        cro.encoding = s.readOptions.encoding
        cro.delimiter = s.readOptions.delimiter
        cro.preferTab = kind == .tsv
        let url = try await ctx.produceFile(for: item, ext: s.format) { temp in
            let writer = try CSVRowWriter(url: temp, dialect: s.dialect)
            var rows = 0
            let info = try CSVFile.stream(item.url, options: cro, progress: { progress.report($0) }) { row in
                if let r = s.rowTransform.apply(row) { try writer.write(row: r) }
                rows += 1
                if rows % 2048 == 0 { try Task.checkCancellation() }
                return true
            }
            try writer.finish()
            ctx.log("Source: \(info.encoding.displayName), delimiter \(CSVSniffer.name(of: info.delimiter)), \(rows) rows")
            if writer.replacedCharacters > 0 { ctx.log("\(writer.replacedCharacters) characters are not in the chosen encoding and were replaced.") }
        }
        progress.report(1)
        return [url]
    }

    // MARK: LibreOffice PDF

    /// XLSX / XLS / ODS -> PDF through LibreOffice. nil = this route does not apply (CSV sources, a sheet selection): the table layout is used and the log says so.
    private static func officePDF(_ item: FileItem, kind: SheetFileKind?, ctx: OperationContext, settings s: Settings) async throws -> URL? {
        guard let kind, kind == .xlsx || kind == .xls || kind == .ods, s.sheetMode == "all", s.rowTransform.isIdentity else {
            ctx.log("LibreOffice prints whole XLSX, XLS and ODS files as they are; the built-in table layout was used instead.")
            return nil
        }
        let result = try await SheetOffice.convert(item.url, to: "pdf", ctx: ctx)
        defer { AppPaths.removeTemp(result.workDirectory) }
        return try await ctx.produceFile(for: item, ext: "pdf") { temp in
            try FileManager.default.copyItem(at: result.file, to: temp)
        }
    }
}
