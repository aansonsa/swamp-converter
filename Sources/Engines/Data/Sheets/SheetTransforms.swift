import Foundation

// Pure, per-row cell clean-ups shared by every sheet target (so the streaming CSV path and the in-memory path give the same result): trim, skip empty rows, decimal marks.
// Plus the sheet selection of a workbook ("all", "first", "by name").

struct SheetRowTransform: Sendable {
    var trim = false
    var skipEmpty = false
    /// The decimal mark of the SOURCE text (what counts as a number) and the mark to write (nil = leave the text alone).
    var decimalIn: Character = "."
    var decimalOut: Character? = nil

    var isIdentity: Bool { !trim && !skipEmpty && (decimalOut == nil || decimalOut == decimalIn) }

    /// nil = the row is dropped.
    func apply(_ row: [String]) -> [String]? {
        var out = row
        if trim { for i in out.indices { out[i] = Self.trimmed(out[i]) } }
        if skipEmpty && out.allSatisfy({ $0.isEmpty }) { return nil }
        if let to = decimalOut, to != decimalIn {
            for i in out.indices { out[i] = SheetTransforms.rewriteDecimal(out[i], from: decimalIn, to: to) }
        }
        return out
    }

    /// Space, tab, no-break space and the other Unicode spaces at both ends (not line breaks inside the value).
    static func trimmed(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last, Self.isSpace(first) || Self.isSpace(last) else { return s }
        var scalars = Substring(s).unicodeScalars
        while let f = scalars.first, isSpace(f) { scalars.removeFirst() }
        while let l = scalars.last, isSpace(l) { scalars.removeLast() }
        return String(scalars)
    }

    private static func isSpace(_ u: Unicode.Scalar) -> Bool {
        u == " " || u == "\t" || u == "\u{00A0}" || u == "\u{2007}" || u == "\u{202F}" || u == "\u{FEFF}" || u == "\u{200B}" || u.properties.generalCategory == .spaceSeparator
    }
}

enum SheetTransforms {
    /// `1.5` <-> `1,5` for cells that are plain numbers in the source notation: optional sign, an integer part without leading zero (or just 0), ONE mark, digits.
    /// Everything else (dates, "1.234.567", "007,5", words, formulas) is returned unchanged.
    static func rewriteDecimal(_ s: String, from: Character, to: Character) -> String {
        guard from != to, s.utf8.count >= 3, s.utf8.count <= 40, let fromByte = from.asciiValue else { return s }
        let u = Array(s.utf8)
        var i = 0
        if u[0] == 0x2D || u[0] == 0x2B { i = 1 }
        let intStart = i
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
        let intLen = i - intStart
        guard intLen > 0, i < u.count, u[i] == fromByte else { return s }
        if u[intStart] == 0x30 && intLen > 1 { return s }
        let markAt = i
        i += 1
        let fracStart = i
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
        guard i == u.count, i > fracStart else { return s }
        var out = Array(u[0..<markAt])
        out.append(to.asciiValue ?? fromByte)
        out.append(contentsOf: u[fracStart...])
        return String(decoding: out, as: UTF8.self)
    }

    /// "1; 2" style lists: trims and drops empty entries.
    static func names(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The sheets the options ask for. "names" matches sheet names case-insensitively; no match is an error (a typo must not produce an empty file).
    static func select(_ tables: [SheetTable], mode: String, names: String) throws -> [SheetTable] {
        switch mode {
        case "first":
            return (tables.first(where: { !$0.hidden }) ?? tables.first).map { [$0] } ?? []
        case "names":
            let wanted = Self.names(from: names)
            let picked = tables.filter { t in wanted.contains { $0.caseInsensitiveCompare(t.name) == .orderedSame } }
            if picked.isEmpty {
                let available = tables.map(\.name).joined(separator: ", ")
                throw ConversionError.message(L10n("No sheet has the name you typed. The workbook has: \(available).", "Листа с таким именем нет. В книге есть: \(available)."))
            }
            return picked
        default:
            return tables
        }
    }

    static func applyRows(_ tables: [SheetTable], _ t: SheetRowTransform) -> [SheetTable] {
        if t.isIdentity { return tables }
        return tables.map { SheetTable(name: $0.name, rows: $0.rows.compactMap { t.apply($0) }) }
    }

    /// Maps the option value of the delimiter pickers to a byte.
    static func delimiterByte(_ key: String) -> UInt8? { CSVSniffer.byte(named: key) }

    /// Output encoding choice -> (encoding, BOM). Unknown keys fall back to UTF-8 with BOM.
    static func outputEncoding(_ key: String) -> (DataEncoding, bom: Bool) {
        switch key {
        case "utf-8": return (.utf8, false)
        case "utf-8-bom": return (.utf8, true)
        default: return (DataEncoding(key: key) ?? .utf8, key == "utf-16")
        }
    }
}
