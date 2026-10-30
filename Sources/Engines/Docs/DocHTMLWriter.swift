import Foundation

// DocModel -> HTML. The markup is valid HTML5 and well-formed XML at the same time (void elements self-closed, attributes quoted, no named entities), so the same
// writer serves standalone pages, the single-file variant (pictures as data: URIs), the CommonMark table fallback and the XHTML chapters of an EPUB.

enum DocHTMLWriter {
    struct Options {
        var title: String?
        var author: String?
        var language: String?
        var charset = "utf-8"
        /// Pictures become data: URIs (one self-contained file).
        var embedImages = false
        /// Otherwise pictures are referenced as `<mediaFolder>/<name>` (the caller writes the files).
        var mediaFolder: String?
        /// Body only (EPUB chapters wrap it themselves).
        var fragment = false
        /// Adds `id` attributes to headings (anchors for tables of contents).
        var headingIDs = true
        /// Prefix of image paths inside an EPUB (`images/`); overrides `mediaFolder`.
        var imagePathPrefix: String?
    }

    struct Output {
        var html: String
        /// Media keys referenced by the markup (to be written next to the file when not embedded).
        var usedMedia: [String]
        /// (level, text, id) of every heading, in order.
        var headings: [(level: Int, text: String, id: String)]
    }

    static func write(_ model: DocModel, options o: Options = Options()) -> Output {
        var w = Writer(model: model, options: o)
        let body = w.blocks(model.blocks)
        var html = ""
        if !o.fragment {
            let title = o.title ?? model.meta.title ?? model.firstHeading ?? ""
            html += "<!DOCTYPE html>\n<html" + ((o.language ?? model.meta.language).map { " lang=\"\(DocXML.attr($0))\"" } ?? "") + ">\n<head>\n"
            html += "<meta charset=\"\(DocXML.attr(o.charset))\"/>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n"
            if let a = o.author ?? model.meta.author, !a.isEmpty { html += "<meta name=\"author\" content=\"\(DocXML.attr(a))\"/>\n" }
            html += "<title>\(DocXML.escape(title))</title>\n<style>\(css)</style>\n</head>\n<body>\n"
        }
        html += body.joined(separator: "\n") + "\n"
        if !o.fragment { html += "</body>\n</html>\n" }
        return Output(html: html, usedMedia: w.used, headings: w.headings)
    }

    static func inlineHTML(_ inlines: [DocInline], model: DocModel) -> String {
        var w = Writer(model: model, options: Options(embedImages: false))
        return w.inline(inlines)
    }

    private static let css = """
    :root{color-scheme:light dark}body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}\
    h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .5em}pre{overflow:auto;padding:.8em 1em;border-radius:6px;background:rgba(127,127,127,.12)}\
    code{font:.92em ui-monospace,SFMono-Regular,Menlo,monospace}blockquote{margin:1em 0;padding:0 1em;border-left:3px solid rgba(127,127,127,.4)}\
    table{border-collapse:collapse;margin:1em 0}th,td{border:1px solid rgba(127,127,127,.45);padding:.35em .7em;vertical-align:top}img{max-width:100%;height:auto}hr{border:0;border-top:1px solid rgba(127,127,127,.4)}
    """

    // MARK: Writer

    private struct Writer {
        let model: DocModel
        let o: Options
        var used: [String] = []
        var headings: [(level: Int, text: String, id: String)] = []
        private var ids: Set<String> = []

        init(model: DocModel, options: Options) { self.model = model; self.o = options }

        mutating func blocks(_ bs: [DocBlock], tight: Bool = false) -> [String] {
            var out: [String] = []
            for b in bs {
                switch b {
                case .heading(let level, let c):
                    let l = max(1, min(6, level))
                    let text = c.plainText.replacingOccurrences(of: "\n", with: " ")
                    var attr = ""
                    if o.headingIDs { let id = uniqueID(text); attr = " id=\"\(id)\""; headings.append((l, text, id)) }
                    out.append("<h\(l)\(attr)>\(inline(c))</h\(l)>")
                case .paragraph(let c):
                    if c.isBlank { continue }
                    out.append(tight ? inline(c) : "<p>\(inline(c))</p>")
                case .list(let l):
                    let tag = l.ordered ? "ol" : "ul"
                    var s = "<\(tag)" + (l.ordered && l.start != 1 ? " start=\"\(l.start)\"" : "") + ">\n"
                    for item in l.items {
                        var inner = blocks(item.blocks, tight: l.tight)
                        if let c = item.checked, gfmBox { inner.insert("<input type=\"checkbox\" disabled=\"\"\(c ? " checked=\"\"" : "")/> ", at: 0); inner = [inner.joined()] }
                        s += "<li>" + inner.joined(separator: "\n") + "</li>\n"
                    }
                    out.append(s + "</\(tag)>")
                case .quote(let inner):
                    out.append("<blockquote>\n" + blocks(inner).joined(separator: "\n") + "\n</blockquote>")
                case .code(let lang, let text):
                    let cls = lang.map { " class=\"language-\(DocXML.attr($0))\"" } ?? ""
                    out.append("<pre><code\(cls)>\(DocXML.escape(text))\n</code></pre>")
                case .table(let t): out.append(table(t))
                case .rule: out.append("<hr/>")
                case .pageBreak: out.append("<div style=\"page-break-after: always\"></div>")
                }
            }
            return out
        }

        private var gfmBox: Bool { true }

        private mutating func uniqueID(_ text: String) -> String {
            var slug = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
            while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
            slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if slug.isEmpty { slug = "section" }
            if let f = slug.unicodeScalars.first, CharacterSet.decimalDigits.contains(f) { slug = "s-" + slug }
            var id = slug
            var n = 2
            while ids.contains(id) { id = "\(slug)-\(n)"; n += 1 }
            ids.insert(id)
            return id
        }

        private mutating func table(_ t: DocTable) -> String {
            let cols = max(1, t.columnCount)
            func cells(_ r: [[DocInline]], tag: String, _ w: inout Writer) -> String {
                (0..<cols).map { i in
                    let al = i < t.align.count ? t.align[i] : DocAlign.none
                    let attr = al == .none ? "" : " align=\"\(al.rawValue)\""
                    return "<\(tag)\(attr)>\(w.inline(i < r.count ? r[i] : []))</\(tag)>"
                }.joined()
            }
            var s = "<table>\n"
            if let h = t.header { s += "<thead>\n<tr>\(cells(h, tag: "th", &self))</tr>\n</thead>\n" }
            s += "<tbody>\n"
            for r in t.rows { s += "<tr>\(cells(r, tag: "td", &self))</tr>\n" }
            return s + "</tbody>\n</table>"
        }

        mutating func inline(_ items: [DocInline]) -> String {
            var out = ""
            for i in items {
                switch i {
                case .text(let t): out += DocXML.escape(t)
                case .code(let c): out += "<code>\(DocXML.escape(c))</code>"
                case .emphasis(let c): out += "<em>\(inline(c))</em>"
                case .strong(let c): out += "<strong>\(inline(c))</strong>"
                case .strike(let c): out += "<del>\(inline(c))</del>"
                case .underline(let c): out += "<u>\(inline(c))</u>"
                case .link(let url, let title, let c):
                    out += "<a href=\"\(DocXML.attr(url))\"" + (title.map { " title=\"\(DocXML.attr($0))\"" } ?? "") + ">\(inline(c))</a>"
                case .image(let src, let alt, let title):
                    out += "<img src=\"\(DocXML.attr(imageSource(src)))\" alt=\"\(DocXML.attr(alt))\"" + (title.map { " title=\"\(DocXML.attr($0))\"" } ?? "") + "/>"
                case .lineBreak: out += "<br/>"
                case .softBreak: out += "\n"
                }
            }
            return out
        }

        private mutating func imageSource(_ src: String) -> String {
            guard let m = model.media[src] else { return src }
            if !used.contains(src) { used.append(src) }
            if o.embedImages { return "data:\(m.mime);base64,\(m.data.base64EncodedString())" }
            let name = m.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.name
            if let p = o.imagePathPrefix { return p + name }
            if let f = o.mediaFolder, !f.isEmpty { return (f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f) + "/" + name }
            return name
        }
    }
}
