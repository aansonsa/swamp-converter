import Foundation

// DocModel -> EPUB 3 (with an EPUB 2 NCX for older readers). `mimetype` is the first entry and stored, then META-INF/container.xml, the package document, the navigation
// document, one XHTML file per chapter (the document is split at headings of the chosen level), the style sheet and the pictures. Chapter files are produced by the
// shared HTML writer, which emits well-formed XML.

enum DocEpubWriter {
    struct Options {
        var title: String?
        var author: String?
        var language: String?
        /// 0 = one chapter, 1 = split at <h1>, 2 = split at <h1> and <h2>.
        var splitLevel = 1
        var cover: Data?
        var includeDates = true
        var identifier = "urn:uuid:" + UUID().uuidString.lowercased()
    }

    struct Chapter { var title: String; var blocks: [DocBlock]; var file: String }

    static func write(_ source: DocModel, options o: Options = Options(), to url: URL) throws {
        let model = source.webSafeMedia()
        let title = (o.title ?? model.meta.title ?? model.firstHeading ?? "Untitled")
        let language = o.language ?? model.meta.language ?? "en"
        var chapters = split(model.blocks, level: o.splitLevel, fallbackTitle: title)
        for i in chapters.indices { chapters[i].file = String(format: "text/chapter%03d.xhtml", i + 1) }

        var parts: [DocPackage.Part] = [.init(name: "mimetype", data: Data("application/epub+zip".utf8), stored: true)]
        parts.append(.init(name: "META-INF/container.xml", data: Data((DocXML.declaration + "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>").utf8)))

        var manifest: [(id: String, href: String, type: String, props: String?)] = []
        var spine: [String] = []
        var navEntries: [(level: Int, title: String, href: String)] = []
        var mediaUsed: [String: String] = [:]          // media key -> file name inside images/
        var imageParts: [DocPackage.Part] = []

        var coverFile: String?
        if let cover = o.cover {
            var data = cover
            var mime = DocMediaKind.sniff(cover) ?? ""
            if !["image/png", "image/jpeg", "image/gif"].contains(mime) { data = DocMediaKind.pngData(cover) ?? Data(); mime = "image/png" }
            if !data.isEmpty {
                let ext = DocMediaKind.ext(forMime: mime)
                coverFile = "images/cover.\(ext)"
                imageParts.append(.init(name: "OEBPS/" + coverFile!, data: data, stored: true))
                manifest.append(("cover-image", coverFile!, mime, "cover-image"))
                let page = xhtml(title: title, language: language, body: "<div style=\"text-align:center\"><img src=\"../\(coverFile!)\" alt=\"\(DocXML.attr(title))\" style=\"max-width:100%;height:auto\"/></div>", bodyClass: "cover")
                parts.append(.init(name: "OEBPS/text/cover.xhtml", data: Data(page.utf8)))
                manifest.append(("cover-page", "text/cover.xhtml", "application/xhtml+xml", nil))
                spine.append("cover-page")
            }
        }

        for (i, ch) in chapters.enumerated() {
            try Task.checkCancellation()
            var chapterModel = DocModel(blocks: ch.blocks, meta: model.meta, media: model.media)
            chapterModel.meta.title = ch.title
            let out = DocHTMLWriter.write(chapterModel, options: .init(title: ch.title, fragment: true, headingIDs: true, imagePathPrefix: "../images/"))
            for key in out.usedMedia where mediaUsed[key] == nil {
                guard let m = model.media[key] else { continue }
                mediaUsed[key] = m.name
                imageParts.append(.init(name: "OEBPS/images/\(m.name)", data: m.data, stored: true))
                manifest.append(("img\(mediaUsed.count)", "images/" + (m.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.name), m.mime, nil))
            }
            let id = "ch\(i + 1)"
            parts.append(.init(name: "OEBPS/" + ch.file, data: Data(xhtml(title: ch.title, language: language, body: out.html, bodyClass: nil).utf8)))
            manifest.append((id, ch.file, "application/xhtml+xml", nil))
            spine.append(id)
            // Navigation: the chapter itself, then its headings below the split level.
            navEntries.append((1, ch.title, ch.file))
            for h in out.headings where h.level > o.splitLevel && h.level <= 3 { navEntries.append((h.level - max(o.splitLevel, 0), h.text, ch.file + "#" + h.id)) }
        }
        if chapters.count == 1 && o.splitLevel == 0 {
            // A single chapter: the headings are the table of contents.
            navEntries = []
            let out = DocHTMLWriter.write(DocModel(blocks: chapters[0].blocks, meta: model.meta, media: model.media), options: .init(fragment: true))
            for h in out.headings where h.level <= 3 { navEntries.append((h.level, h.text, chapters[0].file + "#" + h.id)) }
            if navEntries.isEmpty { navEntries.append((1, title, chapters[0].file)) }
        }

        parts.append(.init(name: "OEBPS/style.css", data: Data(css.utf8)))
        parts.append(.init(name: "OEBPS/nav.xhtml", data: Data(nav(entries: navEntries, title: title, language: language).utf8)))
        parts.append(.init(name: "OEBPS/toc.ncx", data: Data(ncx(entries: navEntries, title: title, identifier: o.identifier).utf8)))
        parts.append(.init(name: "OEBPS/content.opf", data: Data(opf(title: title, model: model, options: o, language: language, manifest: manifest, spine: spine, hasCover: coverFile != nil).utf8)))
        parts += imageParts
        try DocPackage.write(parts, to: url)
    }

    // MARK: Chapters

    static func split(_ blocks: [DocBlock], level: Int, fallbackTitle: String) -> [Chapter] {
        guard level > 0 else { return [Chapter(title: fallbackTitle, blocks: blocks, file: "")] }
        var chapters: [Chapter] = []
        var current: [DocBlock] = []
        var currentTitle = fallbackTitle
        var started = false
        for b in blocks {
            if case .heading(let l, let c) = b, l <= level {
                if started || !current.isEmpty { chapters.append(Chapter(title: currentTitle, blocks: current, file: "")) }
                current = [b]
                currentTitle = c.plainText.replacingOccurrences(of: "\n", with: " ")
                started = true
            } else { current.append(b) }
        }
        chapters.append(Chapter(title: currentTitle, blocks: current, file: ""))
        return chapters.filter { !$0.blocks.isEmpty }.isEmpty ? [Chapter(title: fallbackTitle, blocks: [], file: "")] : chapters.filter { !$0.blocks.isEmpty }
    }

    // MARK: Parts

    private static let css = "body{font-family:serif;line-height:1.5;margin:1em}h1,h2,h3,h4,h5,h6{font-family:sans-serif;line-height:1.25}pre{white-space:pre-wrap;background:#f2f2f2;padding:.6em}code{font-family:monospace}blockquote{margin:1em 0 1em 1em;padding-left:1em;border-left:3px solid #bbb}table{border-collapse:collapse}th,td{border:1px solid #999;padding:.3em .6em}img{max-width:100%;height:auto}"

    private static func xhtml(title: String, language: String, body: String, bodyClass: String?) -> String {
        DocXML.declaration + "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(DocXML.attr(language))\" xml:lang=\"\(DocXML.attr(language))\"><head><meta charset=\"utf-8\"/><title>\(DocXML.escape(title))</title><link rel=\"stylesheet\" type=\"text/css\" href=\"../style.css\"/></head><body\(bodyClass.map { " class=\"\($0)\"" } ?? "")>\n\(body)\n</body></html>"
    }

    private static func nestedList(_ entries: [(level: Int, title: String, href: String)], _ i: inout Int, level: Int) -> String {
        var s = "<ol>"
        while i < entries.count, entries[i].level >= level {
            let e = entries[i]
            if e.level > level { s += nestedList(entries, &i, level: e.level); continue }
            s += "<li><a href=\"\(DocXML.attr(e.href))\">\(DocXML.escape(e.title))</a>"
            i += 1
            if i < entries.count, entries[i].level > level { s += nestedList(entries, &i, level: entries[i].level) }
            s += "</li>"
        }
        return s + "</ol>"
    }

    private static func nav(entries: [(level: Int, title: String, href: String)], title: String, language: String) -> String {
        var i = 0
        let list = entries.isEmpty ? "<ol></ol>" : nestedList(entries, &i, level: 1)
        return DocXML.declaration + "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(DocXML.attr(language))\"><head><meta charset=\"utf-8\"/><title>\(DocXML.escape(title))</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>\(DocXML.escape(title))</h1>\(list)</nav></body></html>"
    }

    private static func ncx(entries: [(level: Int, title: String, href: String)], title: String, identifier: String) -> String {
        var s = DocXML.declaration + "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head><meta name=\"dtb:uid\" content=\"\(DocXML.attr(identifier))\"/><meta name=\"dtb:depth\" content=\"1\"/><meta name=\"dtb:totalPageCount\" content=\"0\"/><meta name=\"dtb:maxPageNumber\" content=\"0\"/></head><docTitle><text>\(DocXML.escape(title))</text></docTitle><navMap>"
        for (n, e) in entries.enumerated() {
            s += "<navPoint id=\"np\(n + 1)\" playOrder=\"\(n + 1)\"><navLabel><text>\(DocXML.escape(e.title))</text></navLabel><content src=\"\(DocXML.attr(e.href))\"/></navPoint>"
        }
        return s + "</navMap></ncx>"
    }

    private static func opf(title: String, model: DocModel, options o: Options, language: String,
                            manifest: [(id: String, href: String, type: String, props: String?)], spine: [String], hasCover: Bool) -> String {
        var s = DocXML.declaration + "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" xml:lang=\"\(DocXML.attr(language))\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
        s += "<dc:identifier id=\"book-id\">\(DocXML.escape(o.identifier))</dc:identifier><dc:title>\(DocXML.escape(title))</dc:title><dc:language>\(DocXML.escape(language))</dc:language>"
        if let a = o.author ?? model.meta.author, !a.isEmpty { s += "<dc:creator>\(DocXML.escape(a))</dc:creator>" }
        // EPUB 3 requires dcterms:modified; a stripped document gets a neutral constant instead of the real date.
        s += "<meta property=\"dcterms:modified\">\(o.includeDates ? DocXML.isoDate(model.meta.modified ?? Date()) : "2000-01-01T00:00:00Z")</meta>"
        if hasCover { s += "<meta name=\"cover\" content=\"cover-image\"/>" }
        s += "</metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>"
        for m in manifest { s += "<item id=\"\(m.id)\" href=\"\(DocXML.attr(m.href))\" media-type=\"\(m.type)\"" + (m.props.map { " properties=\"\($0)\"" } ?? "") + "/>" }
        s += "</manifest><spine toc=\"ncx\">" + spine.map { "<itemref idref=\"\($0)\"/>" }.joined() + "</spine></package>"
        return s
    }
}

extension DocModel {
    /// Pictures in formats every reader and browser draws (PNG, JPEG, GIF, SVG); anything else (TIFF, BMP, HEIC, WebP ...) is re-encoded as PNG through ImageIO.
    func webSafeMedia() -> DocModel {
        var m = self
        var taken = Set(media.values.map(\.name))
        for key in media.keys.sorted() {
            guard let media = media[key], !["image/png", "image/jpeg", "image/gif", "image/svg+xml"].contains(media.mime), let png = DocMediaKind.pngData(media.data) else { continue }
            let base = (media.name as NSString).deletingPathExtension
            var name = base + ".png"
            var n = 1
            while taken.contains(name) { n += 1; name = "\(base)-\(n).png" }
            taken.insert(name)
            m.media[key] = DocMedia(name: name, mime: "image/png", data: png)
        }
        return m
    }
}
