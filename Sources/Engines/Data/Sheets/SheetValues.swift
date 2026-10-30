import Foundation

// Cell value logic shared by the XLSX / ODS readers and writers: number-vs-text typing, ISO dates <-> Excel serials, column letters, number format display.

enum SheetValues {
    // MARK: Columns

    /// 0 -> "A", 25 -> "Z", 26 -> "AA".
    static func columnLetters(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 { let r = (n - 1) % 26; out = String(UnicodeScalar(UInt8(65 + r))) + out; n = (n - 1) / 26 }
        return out
    }

    /// "B3" -> (col 1, row 2). Returns nil for malformed references.
    static func cellReference(_ ref: String) -> (col: Int, row: Int)? {
        var col = 0, i = ref.startIndex
        while i < ref.endIndex, let a = ref[i].asciiValue, (a >= 65 && a <= 90) || (a >= 97 && a <= 122) {
            col = col * 26 + Int(a & 0x1F)
            i = ref.index(after: i)
        }
        guard col > 0, let row = Int(ref[i...]), row > 0 else { return nil }
        return (col - 1, row - 1)
    }

    // MARK: Typing on write

    /// `-12.5`, `0`, `0.5`, `1234567` become numbers; `007`, `+420123456`, `NaN`, `1,5` (unless `commaDecimal`), `1e5`, `1 234`, > 15 digits stay text.
    /// Returns the canonical text of the number (comma replaced by a dot) or nil.
    static func numberLiteral(_ s: String, commaDecimal: Bool = false) -> String? {
        let u = Array(s.utf8)
        if u.isEmpty || u.count > 16 { return nil }
        var i = 0
        if u[0] == 0x2D { i = 1 }
        guard i < u.count else { return nil }
        // integer part: "0" or a non-zero digit followed by digits
        let intStart = i
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
        let intLen = i - intStart
        guard intLen > 0 else { return nil }
        if u[intStart] == 0x30 && intLen > 1 { return nil }                 // leading zero: an id, a zip code
        var fracLen = 0
        var canonical = String(decoding: u[0..<i], as: UTF8.self)
        if i < u.count {
            guard u[i] == 0x2E || (commaDecimal && u[i] == 0x2C) else { return nil }
            i += 1
            let fs = i
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
            fracLen = i - fs
            guard fracLen > 0, i == u.count else { return nil }
            canonical += "." + String(decoding: u[fs..<i], as: UTF8.self)
        }
        if intLen + fracLen > 15 { return nil }                              // Excel keeps 15 significant digits
        if canonical == "-0" { return nil }
        return canonical
    }

    // MARK: Dates

    /// Days since 1970-01-01 of a civil date (proleptic Gregorian).
    static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civilFromDays(_ z0: Int) -> (y: Int, m: Int, d: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func isValidCivil(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        guard y >= 1900, y <= 9999, m >= 1, m <= 12, d >= 1 else { return false }
        let dim = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return d <= dim[m - 1]
    }

    /// "2024-01-05", "2024-01-05 13:45", "2024-01-05 13:45:09" or with a "T": the Excel serial number (1900 date system) and whether a time is present.
    /// Dates before 1900-03-01 are refused (Excel's 1900 leap-year quirk makes them ambiguous).
    static func serial(fromISO s: String) -> (value: Double, hasTime: Bool)? {
        let u = Array(s.utf8)
        guard u.count == 10 || u.count == 16 || u.count == 19 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for k in a..<(a + n) { guard u[k] >= 0x30, u[k] <= 0x39 else { return nil }; v = v * 10 + Int(u[k] - 0x30) }
            return v
        }
        guard u[4] == 0x2D, u[7] == 0x2D, let y = num(0, 4), let m = num(5, 2), let d = num(8, 2), isValidCivil(y, m, d) else { return nil }
        let days = daysFromCivil(y, m, d) + 25569
        if days < 61 { return nil }
        if u.count == 10 { return (Double(days), false) }
        guard u[10] == 0x20 || u[10] == 0x54, u[13] == 0x3A, let hh = num(11, 2), let mi = num(14, 2), hh < 24, mi < 60 else { return nil }
        var ss = 0
        if u.count == 19 { guard u[16] == 0x3A, let v = num(17, 2), v < 60 else { return nil }; ss = v }
        return (Double(days) + Double(hh * 3600 + mi * 60 + ss) / 86400.0, true)
    }

    /// Excel serial -> broken-down date. `date1904` selects the Mac epoch.
    static func components(fromSerial serial: Double, date1904: Bool) -> (y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int)? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        var whole = Int(serial.rounded(.down))
        var secs = Int(((serial - Double(whole)) * 86400).rounded())
        if secs >= 86400 { secs -= 86400; whole += 1 }
        let days1970: Int
        if date1904 { days1970 = whole - 24107 }
        else if whole < 60 { days1970 = whole - 25568 }                      // 1900-01-01 = serial 1
        else if whole == 60 { days1970 = -25509 }                            // the non-existent 1900-02-29, shown as 1900-03-01
        else { days1970 = whole - 25569 }
        let c = civilFromDays(days1970)
        return (c.y, c.m, c.d, secs / 3600, secs % 3600 / 60, secs % 60)
    }

    static func iso(_ c: (y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int), date: Bool, time: Bool) -> String {
        var parts: [String] = []
        if date { parts.append(String(format: "%04d-%02d-%02d", c.y, c.m, c.d)) }
        if time { parts.append(String(format: "%02d:%02d:%02d", c.h, c.mi, c.s)) }
        return parts.joined(separator: " ")
    }

    // MARK: Text helpers

    /// Characters that cannot appear in XML 1.0 are replaced by a space (control codes in pasted text).
    static func xmlSafe(_ s: String) -> String {
        var needs = false
        for u in s.unicodeScalars where u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { needs = true; break }
        if !needs { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars { out.append((u.value < 0x20 && u != "\t" && u != "\n" && u != "\r") ? " " : u) }
        return String(out)
    }

    static func xmlEscape(_ s: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for ch in xmlSafe(s).unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            case "\r" where attribute: out += "&#13;"
            case "\t" where attribute: out += "&#9;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// Approximate display width of a cell in "characters" (wide East-Asian characters count twice).
    static func displayWidth(_ s: String) -> Double {
        var w = 0.0
        for u in s.unicodeScalars {
            if u.value >= 0x1100 && (u.value <= 0x115F || (u.value >= 0x2E80 && u.value <= 0xA4CF) || (u.value >= 0xAC00 && u.value <= 0xD7A3) || (u.value >= 0xF900 && u.value <= 0xFAFF) || (u.value >= 0xFF00 && u.value <= 0xFF60)) { w += 2 }
            else { w += 1 }
        }
        return w
    }

    /// Excel sheet names: no `[]:*?/\`, at most 31 characters, unique (case-insensitive), never empty.
    static func sanitizedSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for raw in names {
            var n = String(raw.unicodeScalars.filter { !"[]:*?/\\".unicodeScalars.contains($0) && $0.value >= 32 })
            n = n.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'")))
            if n.isEmpty { n = L("Sheet", "Лист") }
            if n.count > 31 { n = String(n.prefix(31)) }
            var candidate = n, k = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " \(k)"
                candidate = String(n.prefix(31 - suffix.count)) + suffix
                k += 1
            }
            used.insert(candidate.lowercased())
            out.append(candidate)
        }
        return out
    }
}

/// Turns the stored number of an XLSX cell into its display string using the cell's number format (the "formatted string" the original produced). The formatter
/// covers the formats people actually use: General, fixed decimals, thousands separators, percent, currency literals, scientific, dates and times.
/// Fractions and exotic codes fall back to the General form of the number.
enum XLSXNumberFormat {
    static let builtinCodes: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
        14: "yyyy-mm-dd", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "yyyy-mm-dd h:mm",
        37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)", 45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0",
        48: "##0.0E+0", 49: "@"
    ]

    /// General: up to 15 significant digits, no trailing zeros, exponent only for very large / small numbers.
    static func general(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.15g", v)
        if s.contains("e") {
            // keep Excel's style: 1.5E+20
            s = s.replacingOccurrences(of: "e+0", with: "E+").replacingOccurrences(of: "e-0", with: "E-").replacingOccurrences(of: "e", with: "E")
        }
        return s
    }

    private static func isDateCode(_ code: String) -> Bool {
        var inQuote = false, inBracket = false
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inQuote.toggle() }
            else if !inQuote {
                if c == "[" { inBracket = true }
                else if c == "]" { inBracket = false }
                else if c == "\\" { i += 1 }
                else if !inBracket, "dmyhsDMYHS".contains(c) { return true }
                else if inBracket, c == "h" || c == "m" || c == "s" { return true }
            }
            i += 1
        }
        return false
    }

    /// Display string for a numeric cell.
    static func display(_ value: Double, code: String?, date1904: Bool) -> String {
        guard let code, code != "General", code != "@" else { return general(value) }
        let sections = splitSections(code)
        if isDateCode(sections[0]) {
            guard let c = SheetValues.components(fromSerial: value, date1904: date1904) else { return general(value) }
            let lower = sections[0].lowercased()
            if lower.contains("[h]") || lower.contains("[hh]") {
                let hours = Int((value * 24).rounded(.down))
                return String(format: "%d:%02d:%02d", hours, c.mi, c.s)
            }
            let hasDate = lower.contains("d") || lower.contains("y") || (lower.contains("m") && !lower.contains("h") && !lower.contains("s"))
            let hasTime = lower.contains("h") || lower.contains("s")
            if !hasDate && !hasTime { return general(value) }
            if hasTime && !hasDate && value >= 1 { return SheetValues.iso(c, date: false, time: true) }
            return SheetValues.iso(c, date: hasDate, time: hasTime && (value != value.rounded(.down) || !hasDate))
        }
        var section = sections[0]
        var v = value
        var negativeSection = false
        if v < 0, sections.count > 1 { section = sections[1]; v = -v; negativeSection = true }
        else if v == 0, sections.count > 2 { section = sections[2] }
        return render(v, section: section, negativeSection: negativeSection, original: value)
    }

    private static func splitSections(_ code: String) -> [String] {
        var out: [String] = [""]
        var inQuote = false
        for c in code {
            if c == "\"" { inQuote.toggle() }
            if c == ";" && !inQuote { out.append(""); continue }
            out[out.count - 1].append(c)
        }
        return out
    }

    private static func render(_ v: Double, section: String, negativeSection: Bool, original: Double) -> String {
        var prefix = "", suffix = ""
        var seenDigit = false
        var decimals = 0, afterPoint = false, grouping = false, percent = false, scientific = false
        var literal = ""
        let chars = Array(section)
        var i = 0
        func emit(_ s: String) { if seenDigit { suffix += s } else { prefix += s } }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "0", "#", "?":
                seenDigit = true
                if afterPoint { decimals += 1 }
            case ".": if seenDigit || true { afterPoint = true; seenDigit = true }
            case ",": if seenDigit && !afterPoint { grouping = true }
            case "%": percent = true; emit("%")
            case "\"":
                i += 1
                literal = ""
                while i < chars.count, chars[i] != "\"" { literal.append(chars[i]); i += 1 }
                emit(literal)
            case "\\": i += 1; if i < chars.count { emit(String(chars[i])) }
            case "_": i += 1; emit(" ")
            case "*": i += 1
            case "[":
                var tag = ""
                i += 1
                while i < chars.count, chars[i] != "]" { tag.append(chars[i]); i += 1 }
                if tag.hasPrefix("$") {
                    // [$€-407]: the currency symbol is the part before the dash
                    let body = tag.dropFirst()
                    emit(String(body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""))
                }
            case "E", "e":
                if i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" { scientific = true; i += 1 } else { emit(String(c)) }
            case "/", "@": return general(original)
            default: emit(String(c))
            }
            i += 1
        }
        if !seenDigit { return (negativeSection ? "-" : "") + prefix + suffix }
        var x = v
        if percent { x *= 100 }
        var body: String
        if scientific { body = String(format: "%.\(decimals)E", x).replacingOccurrences(of: "E+0", with: "E+").replacingOccurrences(of: "E-0", with: "E-") }
        else {
            body = String(format: "%.\(decimals)f", x)
            if grouping { body = group(body) }
        }
        let sign = (!negativeSection && x < 0 && body.hasPrefix("-")) ? "" : ""
        return sign + prefix + body + suffix
    }

    private static func group(_ s: String) -> String {
        var neg = false
        var str = s
        if str.hasPrefix("-") { neg = true; str.removeFirst() }
        let parts = str.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let digits = Array(parts[0])
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        if parts.count > 1 { out += "." + parts[1] }
        return (neg ? "-" : "") + out
    }
}
