import Foundation
import PDFKit
import CryptoKit

// PDF facts, text normalisation and file hashing for the conformance checks.

enum FileHash {
    /// SHA-256 of a file, streamed (never loads it whole).
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of every regular file under `root`, keyed by the path relative to it.
    static func tree(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return out }
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            out[rel] = sha256(u)
        }
        return out
    }
}

enum TextCompare {
    /// Canonical form for "same text modulo layout": NFC, invisible characters removed, every whitespace run one space.
    static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping
        for ch in ["\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{FFFC}"] { t = t.replacingOccurrences(of: ch, with: "") }
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func words(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init) }

    /// Share of `expected` words that appear in `actual` in the same order (longest common subsequence over words). 1 = nothing lost or reordered.
    static func wordRecall(expected: String, actual: String, limit: Int = 4000) -> Double {
        let a = Array(words(expected).prefix(limit)), b = Array(words(actual).prefix(limit * 2))
        guard !a.isEmpty else { return 1 }
        guard !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = prev
        for i in 1...a.count {
            for j in 1...b.count { cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]) }
            swap(&prev, &cur)
        }
        return Double(prev[b.count]) / Double(a.count)
    }

    /// `textutil -convert txt` (Apple's own readers for docx, doc, odt, rtf, html, rtfd, webarchive): a second opinion on what a document says.
    static func textutilText(_ url: URL) -> String? {
        let r = ExternalProbe.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path], timeout: 60)
        return r.status == 0 ? r.output : nil
    }
}

struct PDFFacts {
    var pageCount: Int
    var pageSizes: [CGSize]
    var rotations: [Int]
    var pageText: [String]
    var isEncrypted: Bool
    var isLocked: Bool
    var title: String?
    var author: String?
    var allText: String { pageText.joined(separator: "\n") }
}

enum PDFReader {
    /// Reads a PDF with PDFKit. A locked document is unlocked with `password` when one is given.
    static func facts(_ url: URL, password: String? = nil) -> PDFFacts? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let encrypted = doc.isEncrypted
        if doc.isLocked, let password { _ = doc.unlock(withPassword: password) }
        if doc.isLocked { return PDFFacts(pageCount: doc.pageCount, pageSizes: [], rotations: [], pageText: [], isEncrypted: encrypted, isLocked: true) }
        var sizes: [CGSize] = [], rots: [Int] = [], texts: [String] = []
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            sizes.append(p.bounds(for: .mediaBox).size)
            rots.append(p.rotation)
            texts.append(p.string ?? "")
        }
        let attrs = doc.documentAttributes
        return PDFFacts(pageCount: doc.pageCount, pageSizes: sizes, rotations: rots, pageText: texts, isEncrypted: encrypted, isLocked: false,
                        title: attrs?[PDFDocumentAttribute.titleAttribute] as? String, author: attrs?[PDFDocumentAttribute.authorAttribute] as? String)
    }
}
