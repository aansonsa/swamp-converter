import Foundation
import PDFKit
import CoreGraphics

// PDF: document information (title, author, subject, keywords, creator, producer, dates) and the XMP packet.
//
// PDFKit rewrites the Info dictionary on every save: Author / Title / Subject / Keywords / Creator can be removed through `documentAttributes`, but it always
// stamps a Producer (the macOS version and build!) and fresh dates, and it keeps an XMP stream of the source. So:
//   * a source with XMP is rebuilt as a new document from copies of its pages (no XMP; bookmarks are copied across); the attributes that stay are set again;
//   * Producer and the dates are blanked in place afterwards (same length, so the cross-reference table stays valid) when the person asked for it.
// The result is inspected again and the report says what really disappeared.

enum PdfScrub {
    // MARK: Inspect

    static func inspect(_ url: URL) -> ScrubReport {
        guard let doc = PDFDocument(url: url) else { return ScrubReport() }
        var found = Set<ScrubReport.Item>()
        let attrs = doc.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> Bool {
            if let s = attrs[key] as? String { return !s.trimmingCharacters(in: .whitespaces).isEmpty }
            if let a = attrs[key] as? [String] { return a.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
            return attrs[key] != nil
        }
        if text(.authorAttribute) { found.insert(.author) }
        if text(.titleAttribute) { found.insert(.title) }
        if text(.subjectAttribute) || text(.keywordsAttribute) { found.insert(.comment) }
        if text(.creatorAttribute) || text(.producerAttribute) { found.insert(.software) }
        if attrs[PDFDocumentAttribute.creationDateAttribute] != nil || attrs[PDFDocumentAttribute.modificationDateAttribute] != nil {
            // A blanked date comes back as nil; a real one is a date.
            found.insert(.creationTime)
        }
        if hasXMP(url) { found.insert(.xmp) }
        return ScrubReport(removed: ScrubReport.Item.allCases.filter(found.contains))
    }

    static func hasXMP(_ url: URL) -> Bool {
        guard let d = CGPDFDocument(url as CFURL), let catalog = d.catalog else { return false }
        var stream: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(catalog, "Metadata", &stream)
    }

    // MARK: Scrub

    static func scrub(input: URL, output: URL, selection: ScrubSelection) throws -> ScrubReport {
        guard let doc = PDFDocument(url: input) else { throw ConversionError.fileUnreadable(input) }
        if doc.isEncrypted || doc.isLocked {
            throw ConversionError.message(L10n("This PDF is password-protected. Remove the password first, then clean it.", "PDF защищён паролем. Сначала снимите пароль, затем очистите файл."))
        }
        let before = inspect(input).removed
        let wanted = before.filter(selection.selects)
        if wanted.isEmpty && !(before.contains(.xmp) && selection.everything) {
            try FileManager.default.copyItem(at: input, to: output)
            var r = ScrubReport()
            r.kept = ["unchanged"]
            return r
        }

        let attrs = doc.documentAttributes ?? [:]
        var keep: [AnyHashable: Any] = [:]
        func carry(_ key: PDFDocumentAttribute, item: ScrubReport.Item) { if let v = attrs[key], !selection.selects(item) { keep[key] = v } }
        carry(.authorAttribute, item: .author)
        carry(.titleAttribute, item: .title)
        carry(.subjectAttribute, item: .comment)
        carry(.keywordsAttribute, item: .comment)
        carry(.creatorAttribute, item: .software)

        // XMP cannot be edited, only dropped: it goes with the rebuild when the person removes anything (it repeats author, tool and dates).
        let rebuild = before.contains(.xmp) && (!wanted.isEmpty || selection.everything)
        let target: PDFDocument
        if rebuild {
            target = PDFDocument()
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                target.insert(page, at: target.pageCount)
            }
            guard target.pageCount == doc.pageCount else { throw ConversionError.fileUnreadable(input) }
            if let root = doc.outlineRoot { target.outlineRoot = copyOutline(root, from: doc, to: target) }
        } else {
            target = doc
        }
        target.documentAttributes = keep
        guard target.write(to: output) else { throw ConversionError.outputNotWritable(output) }

        // Producer and the dates are always written by PDFKit; blank them in place when they were selected.
        var blank: [String] = []
        if selection.device { blank += ["Producer", "Creator"] }
        if selection.dates { blank += ["CreationDate", "ModDate"] }
        if selection.everything { blank += ["Producer", "Creator", "CreationDate", "ModDate", "Title", "Author", "Subject", "Keywords", "AAPL:Keywords"] }
        if selection.author { blank += ["Author"] }
        if !blank.isEmpty { try patchInfo(at: output, blanking: blank) }

        let after = inspect(output).removed
        return MediaScrub.report(before: before, after: after, selection: selection, route: rebuild ? "rebuilt" : "rewritten")
    }

    /// Bookmarks of the source, pointing at the same pages of the rebuilt document.
    static func copyOutline(_ node: PDFOutline, from source: PDFDocument, to target: PDFDocument) -> PDFOutline {
        let copy = PDFOutline()
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            let item = copyOutline(child, from: source, to: target)
            item.label = child.label
            if let d = child.destination, let page = d.page {
                let index = source.index(for: page)
                if index != NSNotFound, let newPage = target.page(at: index) { item.destination = PDFDestination(page: newPage, at: d.point) }
            }
            item.isOpen = child.isOpen
            copy.insertChild(item, at: copy.numberOfChildren)
        }
        return copy
    }

    // MARK: Same-length blanking of Info dictionary strings

    static func patchInfo(at url: URL, blanking keys: [String]) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        let before = bytes
        blank(keys: keys, in: &bytes)
        if bytes != before { try Data(bytes).write(to: url) }
    }

    /// Replaces the contents of the string values (literal `(...)`, hex `<...>`, or an array of them) that follow `/Key` with spaces / zeros of the same length.
    static func blank(keys: [String], in bytes: inout [UInt8]) {
        let start = bytes.count > 8_000_000 ? bytes.count - 4_000_000 : 0
        for key in Set(keys) {
            let token = Array(("/" + key).utf8)
            var i = start
            while i + token.count < bytes.count {
                guard bytes[i] == token[0], Array(bytes[i..<i + token.count]) == token else { i += 1; continue }
                var j = i + token.count
                // The name must end here (so /Title does not match /TitleX).
                if isNameChar(bytes[j]) { i = j; continue }
                while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                guard j < bytes.count else { break }
                if bytes[j] == UInt8(ascii: "[") {
                    j += 1
                    while j < bytes.count, bytes[j] != UInt8(ascii: "]") {
                        if isSpace(bytes[j]) { j += 1; continue }
                        j = blankString(in: &bytes, at: j) ?? bytes.count
                    }
                } else {
                    j = blankString(in: &bytes, at: j) ?? j
                }
                i = max(j, i + token.count)
            }
        }
    }

    /// Blanks the string starting at `at` and returns the index behind it; nil when no string starts there.
    private static func blankString(in bytes: inout [UInt8], at: Int) -> Int? {
        guard at < bytes.count else { return nil }
        if bytes[at] == UInt8(ascii: "(") {
            var depth = 1, k = at + 1
            while k < bytes.count, depth > 0 {
                let c = bytes[k]
                if c == UInt8(ascii: "\\") { bytes[k] = UInt8(ascii: " "); if k + 1 < bytes.count { bytes[k + 1] = UInt8(ascii: " ") }; k += 2; continue }
                if c == UInt8(ascii: "(") { depth += 1 } else if c == UInt8(ascii: ")") { depth -= 1; if depth == 0 { break } }
                bytes[k] = UInt8(ascii: " ")
                k += 1
            }
            // Inner parentheses were blanked too; keep the string balanced.
            return min(k + 1, bytes.count)
        }
        if bytes[at] == UInt8(ascii: "<"), at + 1 < bytes.count, bytes[at + 1] != UInt8(ascii: "<") {
            var k = at + 1
            while k < bytes.count, bytes[k] != UInt8(ascii: ">") { bytes[k] = UInt8(ascii: "0"); k += 1 }
            return min(k + 1, bytes.count)
        }
        return nil
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }
    private static func isNameChar(_ c: UInt8) -> Bool {
        !(isSpace(c) || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "<") || c == UInt8(ascii: ">") || c == UInt8(ascii: "[")
          || c == UInt8(ascii: "]") || c == UInt8(ascii: "/") || c == UInt8(ascii: "%"))
    }
}
