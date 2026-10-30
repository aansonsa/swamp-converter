import Foundation

/// Stable option keys of the `sheet.convert` schema (spec/handbrake.md 3.6). Adding keys is free; renaming or removing breaks presets.
enum SheetKeys {
    static let format = "sheet.format"           // xlsx, csv, tsv, ods, pdf
    static let delimiter = "sheet.delim"         // INPUT delimiter of csv / tsv sources: auto, comma, semicolon, tab, pipe
    static let encodingIn = "sheet.enc.in"       // auto, utf-8, utf-16, windows-1251, windows-1250, windows-1252, windows-1257, koi8-r, cp866
    static let encodingOut = "sheet.enc.out"     // utf-8-bom (default, Excel shows diacritics), utf-8, utf-16, windows-1251, windows-1250, windows-1252, windows-1257, koi8-r, cp866
    static let lineEnding = "sheet.eol"          // crlf, lf
    static let quoteAll = "sheet.quoteAll"
    static let decimal = "sheet.decimal"         // decimal mark of numbers in CSV / TSV results: keep, dot, comma
    static let headerRow = "sheet.header"        // first row is a header (bold + frozen in xlsx, bold + repeated in pdf)
    static let sheets = "sheet.sheets"           // all, first, names
    static let autoFit = "sheet.autofit"
    static let trimCells = "sheet.trim"
    static let pdfPageSize = "sheet.pdf.size"    // a4, a3, a5, letter, legal

    // Added after the first release of the keys (adding is free).
    static let sheetNames = "sheet.sheets.names" // comma separated, used when `sheets` == names
    static let delimiterOut = "sheet.delim.out"  // comma, semicolon, pipe (csv results; tsv always uses tab)
    static let decimalIn = "sheet.decimal.in"    // decimal mark of the SOURCE text: dot, comma
    static let skipEmpty = "sheet.skipEmpty"     // drop rows without any value
    static let freeze = "sheet.freeze"           // xlsx: freeze the header row
    static let filter = "sheet.filter"           // xlsx: auto filter on the header row
    static let allText = "sheet.allText"         // xlsx / ods: keep every cell as text
    static let dates = "sheet.dates"             // xlsx / ods: ISO dates become real dates
    static let pdfOrientation = "sheet.pdf.orient" // auto, portrait, landscape
    static let pdfEngine = "sheet.pdf.engine"    // native, soffice
    static let pdfFontSize = "sheet.pdf.fontSize"
}
