import Foundation

/// Text of one page with its 1-based number.
struct PdfPageText: Sendable, Equatable {
    var number: Int
    var text: String
}

/// Pure text formatting for pdf.to.txt / pdf.to.md / the document exports: paragraphs, page separators, encodings.
/// No heading or list detection (like the original); wrapped lines are joined into paragraphs and hyphenated line ends are repaired.
enum PdfMarkdown {
    // MARK: Paragraphs

    /// Joins two wrapped lines: "hyphen-" + "ated" becomes "hyphenated" (a dash after a letter, next line starting in lower case), else a space.
    static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        if a.hasSuffix("-"), a.count >= 2 {
            let beforeDash = a[a.index(a.endIndex, offsetBy: -2)]
            if beforeDash.isLetter, let first = b.first, first.isLowercase { return String(a.dropLast()) + b }
        }
        return a + " " + b
    }

    private static func startsListItem(_ line: String) -> Bool {
        if let f = line.unicodeScalars.first, "\u{2022}\u{25CF}\u{25AA}\u{2013}\u{2014}-*".unicodeScalars.contains(f), line.dropFirst().first == " " { return true }
        var digits = 0
        for ch in line { if ch.isNumber { digits += 1 } else { break } }
        if digits > 0, digits < 4 {
            let rest = line.dropFirst(digits)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return true }
        }
        return false
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return ".!?:;\u{2026}\u{00BB}\"".contains(last)
    }

    /// Splits the extracted text of one page into paragraphs: a blank line, a list item, or a short line that ends a sentence starts a new one.
    static func paragraphs(from pageText: String) -> [String] {
        let lines = pageText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let longest = lines.map(\.count).max() ?? 0
        var out: [String] = []
        var current = ""
        var previous = ""
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { out.append(current); current = "" }
                previous = ""
                continue
            }
            if current.isEmpty {
                current = line
            } else {
                let previousIsShort = Double(previous.count) < 0.6 * Double(longest) && endsSentence(previous)
                if startsListItem(line) || previousIsShort { out.append(current); current = line }
                else { current = join(current, line) }
            }
            previous = line
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Documents

    /// Separator values of `pdf.text.pages`: auto, marker, formfeed, none.
    static func plain(pages: [PdfPageText], separators: String, reflow: Bool) -> String {
        let blocks: [String] = pages.map { p in
            let body = reflow ? paragraphs(from: p.text).joined(separator: "\n\n") : p.text
            return separators == "marker" ? "--- \(L("Page", "Страница")) \(p.number) ---\n\(body)" : body
        }
        let glue: String
        switch separators {
        case "formfeed": glue = "\u{0C}"
        case "none": glue = "\n"
        default: glue = "\n\n"
        }
        return blocks.joined(separator: glue)
    }

    /// Markdown: paragraphs separated by blank lines, pages by a `---` rule (marker: a `## Page N` heading per page; none: blank line only).
    static func markdown(pages: [PdfPageText], separators: String, reflow: Bool) -> String {
        func body(_ p: PdfPageText) -> String {
            if reflow { return paragraphs(from: p.text).joined(separator: "\n\n") }
            return p.text.components(separatedBy: "\n").map { $0.isEmpty ? "" : $0 + "  " }.joined(separator: "\n")
        }
        switch separators {
        case "marker":
            return pages.map { "## \(L("Page", "Страница")) \($0.number)\n\n\(body($0))" }.joined(separator: "\n\n")
        case "none":
            return pages.map(body).joined(separator: "\n\n")
        default:
            return pages.map(body).joined(separator: "\n\n---\n\n")
        }
    }

    // MARK: Encoding

    /// Bytes of `text` in the chosen encoding: utf8 (no BOM), utf8bom, utf16 (with BOM), cp1251 (characters outside it become "?").
    static func data(_ text: String, encoding: String) -> Data {
        switch encoding {
        case "utf8bom": return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case "utf16": return text.data(using: .utf16) ?? Data(text.utf8)
        case "cp1251": return text.data(using: .windowsCP1251, allowLossyConversion: true) ?? Data(text.utf8)
        default: return Data(text.utf8)
        }
    }
}
