import Foundation

// EPUB -> DocModel: container.xml -> package document -> spine order -> each XHTML chapter through the HTML reader. Pictures are loaded from the package and merged
// into one media table; the table-of-contents document and non-linear items (notes, covers marked non-linear) are left out. Works for EPUB 2 and 3.

extension DocXMLNode {
    /// Children whose name is `local`, with or without a namespace prefix ("item", "opf:item").
    func localChildren(_ local: String) -> [DocXMLNode] { elements.filter { $0.name == local || $0.name.hasSuffix(":" + local) } }
    func localChild(_ local: String) -> DocXMLNode? { elements.first { $0.name == local || $0.name.hasSuffix(":" + local) } }
}

enum DocEpubReader {
    static func read(_ url: URL) throws -> DocModel {
        let pkg = try DocPackage.Reader(url: url)
        guard let container = try pkg.xml("META-INF/container.xml"),
              let rootfile = container.descendants("rootfile").first, let opfPath = rootfile["full-path"],
              let opf = try pkg.xml(opfPath) else {
            throw ConversionError.message(L10n("This is not a valid EPUB file (no package document).", "Это неверный файл EPUB (нет описания книги)."))
        }
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        for item in opf.localChild("manifest")?.localChildren("item") ?? [] {
            if let id = item["id"], let href = item["href"] { manifest[id] = (href.removingPercentEncoding ?? href, item["media-type"] ?? "", item["properties"] ?? "") }
        }
        var model = DocModel()
        var store = DocMediaStore()
        for ref in opf.localChild("spine")?.localChildren("itemref") ?? [] {
            try Task.checkCancellation()
            guard let id = ref["idref"], let item = manifest[id], item.type.contains("html") || item.type.contains("xml") && item.href.hasSuffix("html"),
                  !item.props.contains("nav"), ref["linear"] != "no" else { continue }
            let path = pkg.resolve(item.href, relativeTo: opfPath)
            guard let data = try pkg.data(path, limit: 64_000_000) else { continue }
            var chapter = DocHTMLReader.read(DocTextCodec.decode(data, as: "auto").text)
            chapter.resolveImages { src in
                let target = pkg.resolve(src.removingPercentEncoding ?? src, relativeTo: path)
                guard let d = try? pkg.data(target, limit: 100_000_000) else { return nil }
                return (d, (target as NSString).lastPathComponent)
            }
            model.append(chapter, mediaStore: &store)
        }
        model.media = store.items
        if let meta = opf.localChild("metadata") {
            model.meta.title = meta.localChild("title")?.textContent.nonEmpty
            model.meta.author = meta.localChild("creator")?.textContent.nonEmpty
            model.meta.language = meta.localChild("language")?.textContent.nonEmpty
            model.meta.modified = DocXML.parseISODate(meta.localChildren("meta").first { $0["property"] == "dcterms:modified" }?.textContent)
        }
        return model
    }
}

// MARK: - Pictures and merging

extension DocMediaStore {
    init(existing: [String: DocMedia]) {
        self.init()
        for key in existing.keys.sorted() { if let m = existing[key] { _ = add(m.data, suggestedName: m.name) } }
    }
}

extension DocInline {
    /// Rebuilds the tree with every picture replaced by `f(src, alt, title)`.
    func mapImages(_ f: (String, String, String?) -> DocInline) -> DocInline {
        switch self {
        case .image(let s, let a, let t): return f(s, a, t)
        case .emphasis(let c): return .emphasis(c.map { $0.mapImages(f) })
        case .strong(let c): return .strong(c.map { $0.mapImages(f) })
        case .strike(let c): return .strike(c.map { $0.mapImages(f) })
        case .underline(let c): return .underline(c.map { $0.mapImages(f) })
        case .link(let u, let t, let c): return .link(url: u, title: t, content: c.map { $0.mapImages(f) })
        default: return self
        }
    }
}

extension DocBlock {
    func mapInlineGroups(_ f: ([DocInline]) -> [DocInline]) -> DocBlock {
        switch self {
        case .heading(let l, let c): return .heading(level: l, content: f(c))
        case .paragraph(let c): return .paragraph(f(c))
        case .quote(let b): return .quote(b.map { $0.mapInlineGroups(f) })
        case .list(var l):
            l.items = l.items.map { DocListItem(blocks: $0.blocks.map { $0.mapInlineGroups(f) }, checked: $0.checked) }
            return .list(l)
        case .table(var t):
            t.header = t.header.map { $0.map(f) }
            t.rows = t.rows.map { $0.map(f) }
            return .table(t)
        default: return self
        }
    }
}

extension DocModel {
    mutating func mapImages(_ f: @escaping (String, String, String?) -> DocInline) {
        blocks = blocks.map { $0.mapInlineGroups { $0.map { i in i.mapImages(f) } } }
    }

    /// Loads pictures that the markup references by path (files next to an HTML / Markdown document, entries of an EPUB). Only data that really is a picture is
    /// embedded (sniffed from the bytes), so a stray `src="../../secret.txt"` never copies a non-image file into the result. Network addresses are never fetched.
    mutating func resolveImages(_ load: (String) -> (data: Data, name: String)?) {
        var store = DocMediaStore(existing: media)
        var cache: [String: String?] = [:]
        let known = Set(media.keys)
        var rewrite: [String: String] = [:]
        for src in imageSources where !known.contains(src) {
            if cache[src] != nil { continue }
            let lower = src.lowercased()
            if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") { cache[src] = .some(nil); continue }
            if let loaded = load(src), loaded.data.count <= 100_000_000, DocMediaKind.sniff(loaded.data) != nil {
                let key = store.add(loaded.data, suggestedName: loaded.name)
                cache[src] = key; rewrite[src] = key
            } else { cache[src] = .some(nil) }
        }
        media = store.items
        guard !rewrite.isEmpty else { return }
        mapImages { src, alt, title in .image(src: rewrite[src] ?? src, alt: alt, title: title) }
    }

    /// Appends `other` after this document, merging its pictures into `store` (names are made unique, identical files are shared).
    mutating func append(_ other: DocModel, mediaStore store: inout DocMediaStore) {
        var rename: [String: String] = [:]
        for (key, m) in other.media { rename[key] = store.add(m.data, suggestedName: m.name) }
        var added = other
        if !rename.isEmpty { added.mapImages { src, alt, title in .image(src: rename[src] ?? src, alt: alt, title: title) } }
        blocks += added.blocks
    }
}
