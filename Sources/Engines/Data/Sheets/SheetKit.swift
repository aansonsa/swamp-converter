import Foundation

// Pure model + readers + writers for tables (spec/backends.md 3.6.2, spec/catalog.md 3.7). No UI. Everything here is unit-tested with fixtures.
//
// Files: SheetKit (model, façade), CSVKit (parser, sniffer, streaming reader / writer), SheetValues (typing, dates, number formats), XLSXReader / XLSXWriter,
// ODSKit, SheetTextFormats (json / markdown / html), SheetPDF (basic table renderer), SheetTransforms, SheetCatalog (operations), SheetSchemas.

struct SheetTable: Equatable, Sendable {
    var name: String
    var rows: [[String]]
    /// A sheet the source file hides. Readers keep hidden sheets (nothing is dropped silently); writers keep them hidden.
    var hidden = false
    var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

struct SheetWorkbook: Equatable, Sendable {
    var sheets: [SheetTable]
    /// Detected while reading (shown in the Studio source strip).
    var detectedEncoding: String? = nil
    var detectedDelimiter: Character? = nil
}

struct CSVDialect: Equatable, Sendable {
    var delimiter: Character = ","
    var quote: Character = "\""
    var encoding: String.Encoding = .utf8
    var bom = true
    var crlf = true
    /// Decimal separator used when the writer formats numbers it knows (nil = leave strings as they are).
    var decimalComma = false
    /// Code pages Foundation's `String.Encoding` cannot name conveniently (KOI8-R, Windows-1257 ...). Wins over `encoding` when set.
    var dataEncoding: DataEncoding? = nil
    /// Quote every field, not only those that need it.
    var quoteAll = false
}

/// What the readers need to know besides the file.
struct SheetReadOptions {
    var encoding: DataEncoding? = nil
    var delimiter: UInt8? = nil
    /// XLSX / ODS: numbers and dates as the cells display them (number formats applied). False = stored values.
    var formatted = true
    /// Previews: stop after this many rows of the first sheet.
    var maxRows: Int? = nil
    var firstSheetOnly = false
}

enum SheetFileKind {
    case csv, tsv, xlsx, ods, xls

    /// By extension first, then by content (a CSV renamed to .xlsx, a zip with the wrong extension).
    static func detect(_ url: URL) -> SheetFileKind? {
        switch Formats.key(of: url) {
        case "csv": return .csv
        case "tsv": return .tsv
        case "xlsx", "xlsm": return .xlsx
        case "ods": return .ods
        case "xls": return .xls
        default: break
        }
        if ZipKit.looksLikeZip(url) {
            if let entries = try? ZipKit.list(url) {
                if entries.contains(where: { $0.name == "xl/workbook.xml" }) { return .xlsx }
                if entries.contains(where: { $0.name == "content.xml" }) { return .ods }
            }
            return nil
        }
        return .csv
    }
}

enum SheetReader {
    /// csv / tsv: strict UTF-8, else Windows-1251 / 1250 / 1257 by plausibility (Russian, Czech, Latvian samples), BOM skipped; delimiter = most consistent of `, ; TAB |`
    /// in the first lines; RFC 4180 (quotes, doubled quotes, embedded newlines, CRLF / LF / CR). xlsx / xlsm: every sheet via `ZipKit` + XMLParser, shared strings,
    /// dates, formatted numbers. xls: best effort (LibreOffice when present, else a calm "needs LibreOffice").
    static func read(_ url: URL, encodingOverride: String.Encoding? = nil, delimiterOverride: Character? = nil) throws -> SheetWorkbook {
        var o = SheetReadOptions()
        if let e = encodingOverride { o.encoding = DataEncoding.from(e) }
        o.delimiter = delimiterOverride?.asciiValue
        return try read(url, options: o)
    }

    /// First `maxRows` rows of the first sheet for the Studio preview (fast, no full parse of huge files).
    static func preview(_ url: URL, maxRows: Int = 100) throws -> SheetWorkbook {
        var o = SheetReadOptions()
        o.maxRows = maxRows; o.firstSheetOnly = true
        return try read(url, options: o)
    }

    static func read(_ url: URL, options: SheetReadOptions) throws -> SheetWorkbook {
        guard let kind = SheetFileKind.detect(url) else {
            throw ConversionError.unsupported(L10n("This file is not a spreadsheet the app can read.", "Этот файл не является таблицей, которую приложение умеет читать."))
        }
        switch kind {
        case .csv, .tsv: return try readDelimited(url, kind: kind, options: options)
        case .xlsx: return try XLSXReader.read(url, options: options)
        case .ods: return try ODSReader.read(url, options: options)
        case .xls: return try XLSConverter.read(url, options: options)
        }
    }

    private static func readDelimited(_ url: URL, kind: SheetFileKind, options: SheetReadOptions) throws -> SheetWorkbook {
        var rows: [[String]] = []
        var ro = CSVReadOptions()
        ro.encoding = options.encoding; ro.delimiter = options.delimiter; ro.preferTab = kind == .tsv
        var count = 0
        let info = try CSVFile.stream(url, options: ro) { row in
            rows.append(row)
            count += 1
            return options.maxRows.map { count < $0 } ?? true
        }
        let name = Formats.baseName(of: url)
        return SheetWorkbook(sheets: [SheetTable(name: name, rows: rows)], detectedEncoding: info.encoding.displayName,
                             detectedDelimiter: Character(UnicodeScalar(info.delimiter)))
    }
}

struct SheetWriteReport: Sendable {
    /// Characters the target encoding could not represent (CSV).
    var replacedCharacters = 0
    /// Cells longer than the format allows that were cut.
    var truncatedCells = 0
    var rows = 0
}

struct XLSXWriteOptions {
    var boldHeader = true
    var autoFit = true
    var freezeHeader = true
    var autoFilter = false
    /// Everything is written as text (ids, phone numbers, codes keep every digit).
    var allText = false
    /// ISO dates become real Excel dates.
    var dates = true
    /// "1,5" becomes the number 1.5.
    var commaDecimal = false
}

enum SheetWriter {
    /// CSV / TSV per `dialect` (UTF-8 BOM default so Excel shows diacritics; quoting rules of spec/catalog.md 3.7).
    static func writeCSV(_ table: SheetTable, to url: URL, dialect: CSVDialect) throws { _ = try writeCSVReporting(table, to: url, dialect: dialect) }

    @discardableResult
    static func writeCSVReporting(_ table: SheetTable, to url: URL, dialect: CSVDialect) throws -> SheetWriteReport {
        let w = try CSVRowWriter(url: url, dialect: dialect)
        for (i, row) in table.rows.enumerated() {
            if i % 4096 == 0 { try Task.checkCancellation() }
            try w.write(row: row)
        }
        try w.finish()
        return SheetWriteReport(replacedCharacters: w.replacedCharacters, truncatedCells: 0, rows: w.rows)
    }

    /// XLSX: sheet-name sanitising, numbers vs text rule (leading zeros stay text), bold header, auto-fitted columns, frozen header row option.
    static func writeXLSX(_ workbook: SheetWorkbook, to url: URL, boldHeader: Bool, autoFit: Bool) throws {
        var o = XLSXWriteOptions()
        o.boldHeader = boldHeader; o.autoFit = autoFit
        _ = try XLSXWriter.write(workbook, to: url, options: o)
    }

    /// ODS (own ODF writer; no LibreOffice needed).
    static func writeODS(_ workbook: SheetWorkbook, to url: URL) throws { _ = try ODSWriter.write(workbook, to: url, options: XLSXWriteOptions()) }
}

extension DataEncoding {
    /// Maps Foundation's `String.Encoding` (the frozen `CSVDialect.encoding`) to the data module's encodings.
    static func from(_ e: String.Encoding) -> DataEncoding? {
        switch e {
        case .utf8: return .utf8
        case .utf16, .unicode: return .utf16
        case .utf16LittleEndian: return .utf16le
        case .utf16BigEndian: return .utf16be
        case .windowsCP1251: return .windows1251
        case .windowsCP1250: return .windows1250
        case .windowsCP1252: return .windows1252
        case .isoLatin2: return .iso88592
        default:
            func cf(_ e: CFStringEncodings) -> String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))) }
            if e == cf(.windowsBalticRim) { return .windows1257 }
            if e == cf(.KOI8_R) { return .koi8r }
            if e == cf(.dosRussian) { return .cp866 }
            if e == cf(.isoLatin7) { return .iso885913 }
            return nil
        }
    }
}
