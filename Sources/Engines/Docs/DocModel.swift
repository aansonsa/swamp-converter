import Foundation
import ImageIO

// The intermediate document model of the native document engine. Every reader (Markdown, HTML, DOCX, ODT, EPUB, RTF / DOC, plain text) produces a `DocModel`;
// every writer (Markdown, HTML, DOCX, ODT, EPUB, RTF, PDF, plain text) consumes one. The model keeps structure (headings, lists, tables, emphasis, links, images)
// and drops layout (page geometry, fonts, columns): the Studio info line says so for the native route.

indirect enum DocInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([DocInline])
    case strong([DocInline])
    case strike([DocInline])
    case underline([DocInline])
    case link(url: String, title: String?, content: [DocInline])
    /// `src` is either a key of `DocModel.media` (embedded picture) or an external reference (http URL, relative path that could not be loaded).
    case image(src: String, alt: String, title: String?)
    case lineBreak
    case softBreak
}

enum DocAlign: String, Equatable, Sendable { case none, left, center, right }

struct DocListItem: Equatable, Sendable {
    var blocks: [DocBlock]
    /// GFM task list state (`- [x]`); nil = not a task.
    var checked: Bool? = nil
}

struct DocList: Equatable, Sendable {
    var ordered: Bool
    var start: Int = 1
    var tight = true
    var items: [DocListItem]
}

struct DocTable: Equatable, Sendable {
    var align: [DocAlign]
    /// nil = the table has no header row (writers that need one promote the first row).
    var header: [[DocInline]]?
    var rows: [[[DocInline]]]
    var columnCount: Int { max(align.count, header?.count ?? 0, rows.map(\.count).max() ?? 0) }
}

indirect enum DocBlock: Equatable, Sendable {
    case heading(level: Int, content: [DocInline])
    case paragraph([DocInline])
    case list(DocList)
    case quote([DocBlock])
    case code(language: String?, text: String)
    case table(DocTable)
    case rule
    case pageBreak
}

struct DocMedia: Equatable, Sendable {
    /// File name inside the package / media folder ("image1.png").
    var name: String
    var mime: String
    var data: Data

    var fileExtension: String { DocMediaKind.ext(forMime: mime) }
}

struct DocMeta: Equatable, Sendable {
    var title: String?
    var author: String?
    var language: String?
    var created: Date?
    var modified: Date?
    var isEmpty: Bool { title == nil && author == nil && language == nil && created == nil && modified == nil }
}

struct DocModel: Equatable, Sendable {
    var blocks: [DocBlock] = []
    var meta = DocMeta()
    /// Embedded pictures by key (the `src` of `DocInline.image`).
    var media: [String: DocMedia] = [:]

    /// Text of the first heading, if any.
    var firstHeading: String? {
        for b in blocks { if case .heading(_, let c) = b { return c.plainText } }
        return nil
    }

    /// All words (letters / digits runs) for the probe and the Studio summary.
    var plainText: String { blocks.map { $0.plainText }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

// MARK: Plain text of the tree

extension Array where Element == DocInline {
    var plainText: String {
        var out = ""
        for i in self {
            switch i {
            case .text(let t), .code(let t): out += t
            case .emphasis(let c), .strong(let c), .strike(let c), .underline(let c): out += c.plainText
            case .link(_, _, let c): out += c.plainText
            case .image(_, let alt, _): out += alt
            case .lineBreak: out += "\n"
            case .softBreak: out += " "
            }
        }
        return out
    }

    /// Merges neighbouring text nodes and equal containers (Word splits one bold phrase into many runs) and removes empty ones.
    func normalized() -> [DocInline] {
        var out: [DocInline] = []
        for i in self {
            switch i {
            case .text(let t):
                if t.isEmpty { continue }
                if case .text(let prev)? = out.last { out[out.count - 1] = .text(prev + t) } else { out.append(i) }
            case .emphasis(let c):
                let n = c.normalized(); if n.isEmpty { continue }
                if case .emphasis(let prev)? = out.last { out[out.count - 1] = .emphasis((prev + n).normalized()) } else { out.append(.emphasis(n)) }
            case .strong(let c):
                let n = c.normalized(); if n.isEmpty { continue }
                if case .strong(let prev)? = out.last { out[out.count - 1] = .strong((prev + n).normalized()) } else { out.append(.strong(n)) }
            case .strike(let c):
                let n = c.normalized(); if n.isEmpty { continue }
                if case .strike(let prev)? = out.last { out[out.count - 1] = .strike((prev + n).normalized()) } else { out.append(.strike(n)) }
            case .underline(let c):
                let n = c.normalized(); if n.isEmpty { continue }
                if case .underline(let prev)? = out.last { out[out.count - 1] = .underline((prev + n).normalized()) } else { out.append(.underline(n)) }
            case .link(let u, let t, let c):
                let n = c.normalized()
                if case .link(let pu, let pt, let prev)? = out.last, pu == u, pt == t { out[out.count - 1] = .link(url: u, title: t, content: (prev + n).normalized()) }
                else { out.append(.link(url: u, title: t, content: n)) }
            case .code(let c):
                if case .code(let prev)? = out.last { out[out.count - 1] = .code(prev + c) } else if !c.isEmpty { out.append(i) }
            default: out.append(i)
            }
        }
        return out
    }

    /// The content without its bold wrapper when EVERYTHING is bold (header cells: a table header is bold by convention, so the weight carries no information);
    /// nil as soon as anything visible is not bold.
    func unbolded() -> [DocInline]? {
        var out: [DocInline] = []
        for i in self {
            switch i {
            case .strong(let c): out += c
            case .lineBreak, .softBreak: out.append(i)
            case .text(let t): if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(i) } else { return nil }
            default: return nil
            }
        }
        return out
    }

    /// True when there is nothing visible (only blanks / breaks).
    var isBlank: Bool {
        for i in self {
            switch i {
            case .text(let t): if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .code(let t): if !t.isEmpty { return false }
            case .emphasis(let c), .strong(let c), .strike(let c), .underline(let c): if !c.isBlank { return false }
            case .link(_, _, let c): if !c.isBlank { return false }
            case .image: return false
            case .lineBreak, .softBreak: continue
            }
        }
        return true
    }

    /// Every image reference in the tree.
    var imageSources: [String] {
        var out: [String] = []
        for i in self {
            switch i {
            case .image(let s, _, _): out.append(s)
            case .emphasis(let c), .strong(let c), .strike(let c), .underline(let c): out += c.imageSources
            case .link(_, _, let c): out += c.imageSources
            default: break
            }
        }
        return out
    }
}

extension DocBlock {
    var plainText: String {
        switch self {
        case .heading(_, let c), .paragraph(let c): return c.plainText
        case .list(let l): return l.items.map { $0.blocks.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .quote(let b): return b.map(\.plainText).joined(separator: "\n")
        case .code(_, let t): return t
        case .table(let t):
            let rows = (t.header.map { [$0] } ?? []) + t.rows
            return rows.map { $0.map { $0.plainText }.joined(separator: "\t") }.joined(separator: "\n")
        case .rule, .pageBreak: return ""
        }
    }

    /// Visits this block and every nested block depth-first.
    func walk(_ visit: (DocBlock) -> Void) {
        visit(self)
        switch self {
        case .quote(let b): b.forEach { $0.walk(visit) }
        case .list(let l): l.items.forEach { $0.blocks.forEach { $0.walk(visit) } }
        default: break
        }
    }

    /// Inline groups directly owned by this block (headings, paragraphs, table cells).
    var inlineGroups: [[DocInline]] {
        switch self {
        case .heading(_, let c), .paragraph(let c): return [c]
        case .table(let t): return (t.header ?? []) + t.rows.flatMap { $0 }
        default: return []
        }
    }
}

extension DocModel {
    /// Every `src` used by an image anywhere in the document, in order of appearance (duplicates kept).
    var imageSources: [String] {
        var out: [String] = []
        for b in blocks { b.walk { out += $0.inlineGroups.flatMap { $0.imageSources } } }
        return out
    }

    /// Number of words (runs of letters / digits). Cheap; used by the probe and the preview.
    static func wordCount(_ text: String) -> Int {
        var n = 0
        var inWord = false
        for u in text.unicodeScalars {
            let isWordChar = CharacterSet.alphanumerics.contains(u)
            if isWordChar && !inWord { n += 1 }
            inWord = isWordChar
        }
        return n
    }
}

// MARK: Pictures

enum DocMediaKind {
    static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg", "jpe": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "emf": return "image/x-emf"
        case "wmf": return "image/x-wmf"
        default: return "application/octet-stream"
        }
    }

    static func ext(forMime mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/heic": return "heic"
        case "image/x-emf": return "emf"
        case "image/x-wmf": return "wmf"
        default: return "bin"
        }
    }

    /// Mime type from the first bytes (the extension of a file inside a package can lie).
    static func sniff(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(16))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A) { return "image/tiff" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        if let s = String(data: d.prefix(512), encoding: .utf8), s.contains("<svg") { return "image/svg+xml" }
        return nil
    }

    /// Pixel size via ImageIO (no decoding of the pixels).
    static func pixelSize(_ d: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// PNG bytes of any picture ImageIO can read (WebP, HEIC, TIFF ... -> PNG) for formats that accept only a few raster types.
    static func pngData(_ d: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Collects pictures while a reader runs and hands out unique keys.
struct DocMediaStore {
    private(set) var items: [String: DocMedia] = [:]
    private var order: [String] = []

    /// Stores `data` and returns its key (the file name, made unique). The same bytes under the same name are stored once.
    mutating func add(_ data: Data, suggestedName: String?) -> String {
        let mime = DocMediaKind.sniff(data) ?? DocMediaKind.mime(forExtension: (suggestedName.map { ($0 as NSString).pathExtension } ?? ""))
        var base = Util.safeFileName(((suggestedName ?? "image") as NSString).deletingPathExtension, fallback: "image")
        if base.isEmpty { base = "image" }
        let ext = DocMediaKind.ext(forMime: mime) == "bin" ? ((suggestedName ?? "") as NSString).pathExtension.lowercased() : DocMediaKind.ext(forMime: mime)
        var name = ext.isEmpty ? base : "\(base).\(ext)"
        var n = 1
        while let existing = items[name] {
            if existing.data == data { return name }
            n += 1
            name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
        }
        items[name] = DocMedia(name: name, mime: mime, data: data)
        order.append(name)
        return name
    }

    var inOrder: [DocMedia] { order.compactMap { items[$0] } }
}
