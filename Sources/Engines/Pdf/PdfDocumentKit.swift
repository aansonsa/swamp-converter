import Foundation
import PDFKit
import CoreGraphics

// Small shared helpers of the PDF engine: opening documents with calm errors, page selection, page geometry (rotation aware)
// and the paper sizes. PDFKit's `bounds(for:)` ignores /Rotate (spec trap 14), so everything that needs the DISPLAYED size goes through here.

enum PdfDoc {
    /// Opens a PDF. Locked documents throw a calm message that points to Tools > Unlock (or opens with `password` when given).
    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.fileUnreadable(url) }
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.message(L10n("Cannot open PDF \(url.lastPathComponent): the file is damaged or is not a PDF.",
                                               "Не удалось открыть PDF \(url.lastPathComponent): файл повреждён или это не PDF."))
        }
        if doc.isLocked {
            if let password, !password.isEmpty, doc.unlock(withPassword: password) {
                // opened with the given password
            } else {
                throw ConversionError.message(L10n("Cannot open PDF \(url.lastPathComponent): it is protected with a password. Remove the password first with Tools > Unlock.",
                                                   "Не удалось открыть PDF \(url.lastPathComponent): он защищён паролем. Сначала снимите пароль: Инструменты > Снять пароль."))
            }
        }
        guard doc.pageCount > 0 else {
            throw ConversionError.message(L10n("Cannot open PDF \(url.lastPathComponent): it has no pages.", "Не удалось открыть PDF \(url.lastPathComponent): в нём нет страниц."))
        }
        return doc
    }

    /// Cheap "is this PDF password protected" check for the wheel (does not parse pages).
    static func isEncrypted(_ url: URL) -> Bool {
        guard let doc = CGPDFDocument(url as CFURL) else { return false }
        return doc.isEncrypted
    }

    /// 0-based page indices from a user range ("all", "1-3, 5, 8-"). Bad syntax or numbers beyond the page count throw a calm option error.
    static func indices(_ text: String, pageCount: Int, key: String = PdfKeys.pages) throws -> [Int] {
        guard let list = PageRange.parse(text, pageCount: pageCount) else {
            throw ConversionError.invalidOption(key: key, reason: L10n("Use a range like 1-3, 5, 8- within the \(pageCount) pages of the file.",
                                                                       "Введите диапазон, например 1-3, 5, 8-, в пределах \(pageCount) стр. файла."))
        }
        guard !list.isEmpty else {
            throw ConversionError.invalidOption(key: key, reason: L10n("No pages selected.", "Страницы не выбраны."))
        }
        return list
    }

    /// Writes `doc` to `url` (atomic temp already handled by the caller). Throws a calm error when PDFKit refuses.
    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let ok = options == nil || options!.isEmpty ? doc.write(to: url) : doc.write(to: url, withOptions: options)
        guard ok, FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.message(L10n("Could not write the PDF.", "Не удалось записать PDF."))
        }
    }

    /// Document title for exports: the PDF's own title, else the file's base name.
    static func title(of doc: PDFDocument, fallback: String) -> String {
        let t = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? fallback : t
    }

    /// A document with copies of all pages, the outline and the document info, but none of the source's encryption.
    static func plainCopy(of doc: PDFDocument) -> PDFDocument {
        let out = PDFDocument()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
        }
        if let attrs = doc.documentAttributes, !attrs.isEmpty { out.documentAttributes = attrs }
        copyOutline(from: doc, to: out, pageMap: Dictionary(uniqueKeysWithValues: (0..<doc.pageCount).map { ($0, $0) }))
        return out
    }

    /// Copies the bookmarks of `doc` into `out`; `pageMap` turns a source page index into the index of the same page in `out` (entries whose page is not in the map
    /// keep their title but have no destination).
    static func copyOutline(from doc: PDFDocument, to out: PDFDocument, pageMap: [Int: Int]) {
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else { return }
        let newRoot = PDFOutline()
        func copyChildren(from src: PDFOutline, to dst: PDFOutline) {
            for k in 0..<src.numberOfChildren {
                guard let child = src.child(at: k) else { continue }
                let entry = PDFOutline()
                entry.label = child.label
                if let dest = child.destination, let page = dest.page {
                    let idx = doc.index(for: page)
                    if idx != NSNotFound, let mapped = pageMap[idx], let newPage = out.page(at: mapped) { entry.destination = PDFDestination(page: newPage, at: dest.point) }
                }
                dst.insertChild(entry, at: dst.numberOfChildren)
                copyChildren(from: child, to: entry)
            }
        }
        copyChildren(from: root, to: newRoot)
        out.outlineRoot = newRoot
    }

    /// Removes author, creator, producer, dates, keywords, title and subject (and with them the XMP packet PDFKit would carry).
    static func stripMetadata(_ doc: PDFDocument) {
        doc.documentAttributes = [:]
    }
}

enum PdfGeometry {
    /// Size in points as a viewer shows the page: crop box, swapped for /Rotate 90 and 270.
    static func displayedSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        let r = ((page.rotation % 360) + 360) % 360
        return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b.size
    }

    /// Paper sizes in points (portrait).
    static func paper(_ key: String) -> CGSize? {
        switch key {
        case "a3": return CGSize(width: 841.89, height: 1190.55)
        case "a4": return CGSize(width: 595.28, height: 841.89)
        case "a5": return CGSize(width: 419.53, height: 595.28)
        case "letter": return CGSize(width: 612, height: 792)
        case "legal": return CGSize(width: 612, height: 1008)
        default: return nil
        }
    }

    /// Name of the paper a page size matches (either orientation, 3 pt tolerance), for chips: "A4", "Letter".
    static func paperName(_ size: CGSize) -> String? {
        let w = min(size.width, size.height), h = max(size.width, size.height)
        for key in ["a3", "a4", "a5", "letter", "legal"] {
            guard let p = paper(key) else { continue }
            if abs(p.width - w) <= 3 && abs(p.height - h) <= 3 { return key == "letter" ? "Letter" : key == "legal" ? "Legal" : key.uppercased() }
        }
        return nil
    }

    static let pointsPerMillimetre: CGFloat = 72.0 / 25.4

    /// The page's own text, trimmed. Empty for picture-only pages.
    static func text(of page: PDFPage) -> String {
        normalise(page.string ?? "")
    }

    static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a page carries real text (at least two letters or digits; stray marks do not count).
    static func hasText(_ page: PDFPage) -> Bool {
        var n = 0
        for u in text(of: page).unicodeScalars where CharacterSet.alphanumerics.contains(u) { n += 1; if n >= 2 { return true } }
        return false
    }

    /// Zero-padded page number, padded to the digit count of `total` (9 pages: 1..9; 12 pages: 01..12).
    static func padded(_ n: Int, total: Int) -> String {
        let width = String(max(total, 1)).count
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
