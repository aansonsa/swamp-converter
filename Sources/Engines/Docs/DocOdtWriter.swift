import Foundation

// DocModel -> ODT (OpenDocument Text 1.2). Hand-written like the DOCX writer because the system writer drops pictures and heading styles (spec/platform.md 5.1).
// Headings use text:h with outline levels, lists use text:list with bullet / number styles (restartable), tables use table:table with a header-rows group,
// pictures are stored under Pictures/ and anchored as characters. `mimetype` is the first entry and stored uncompressed, as the format requires.

enum DocOdtWriter {
    struct Options {
        var page = DocPageSetup(size: "a4", marginMillimetres: 20)
        var includeAuthorAndTitle = true
        var includeDates = true
        var font = "Liberation Serif"
        var fontSize = 11.0
        var lineSpacing = 1.15
    }

    static let mimeType = "application/vnd.oasis.opendocument.text"
    static let namespaces = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\""

    static func write(_ model: DocModel, options: Options = Options(), to url: URL) throws {
        var b = Builder(model: model, options: options)
        let body = b.body()
        try DocPackage.write(b.parts(body: body), to: url)
    }

    // MARK: Builder

    struct Builder {
        let model: DocModel
        let o: Options
        var pictures: [DocPackage.Part] = []
        var pictureNames: [String: String] = [:]
        var textStyles: Set<Int> = []
        var numberedLists: [(name: String, start: Int)] = []
        var tableCount = 0

        init(model: DocModel, options: Options) { self.model = model; self.o = options }

        // MARK: Blocks

        mutating func body() -> String {
            var out = ""
            for b in model.blocks { out += block(b, inList: false) }
            return out
        }

        mutating func block(_ b: DocBlock, inList: Bool, quote: Bool = false) -> String {
            switch b {
            case .heading(let level, let c):
                let l = max(1, min(6, level))
                return "<text:h text:style-name=\"Heading_20_\(l)\" text:outline-level=\"\(l)\">\(inline(c, 0))</text:h>"
            case .paragraph(let c):
                if c.isBlank { return "" }
                let style = quote ? "Quotations" : (inList ? "List_20_Paragraph" : "Text_20_body")
                return "<text:p text:style-name=\"\(style)\">\(inline(c, 0))</text:p>"
            case .list(let l): return list(l)
            case .quote(let inner): return inner.map { block($0, inList: inList, quote: true) }.joined()
            case .code(_, let text):
                return text.components(separatedBy: "\n").map { "<text:p text:style-name=\"Preformatted_20_Text\">\(escapedText($0))</text:p>" }.joined()
            case .table(let t): return table(t)
            case .rule: return "<text:p text:style-name=\"Horizontal_20_Line\"/>"
            case .pageBreak: return "<text:p text:style-name=\"PageBreak\"/>"
            }
        }

        private mutating func list(_ l: DocList) -> String {
            var style = "BulletList"
            if l.ordered {
                style = "NumberList\(numberedLists.count + 1)"
                numberedLists.append((style, l.start))
            }
            var s = "<text:list text:style-name=\"\(style)\">"
            for item in l.items {
                s += "<text:list-item>"
                var wroteFirst = false
                for b in item.blocks {
                    if !wroteFirst, case .paragraph(let c) = b {
                        var content = inline(c, 0)
                        if let ch = item.checked { content = (ch ? "\u{2611} " : "\u{2610} ") + content }
                        s += "<text:p text:style-name=\"List_20_Paragraph\">\(content)</text:p>"
                        wroteFirst = true
                        continue
                    }
                    if !wroteFirst { s += "<text:p text:style-name=\"List_20_Paragraph\"/>"; wroteFirst = true }
                    s += block(b, inList: true)
                }
                if !wroteFirst { s += "<text:p text:style-name=\"List_20_Paragraph\"/>" }
                s += "</text:list-item>"
            }
            return s + "</text:list>"
        }

        private mutating func table(_ t: DocTable) -> String {
            tableCount += 1
            let name = "Table\(tableCount)"
            let cols = max(1, t.columnCount)
            var s = "<table:table table:name=\"\(name)\" table:style-name=\"Tbl\"><table:table-column table:style-name=\"TblCol\" table:number-columns-repeated=\"\(cols)\"/>"
            func row(_ r: [[DocInline]], header: Bool) -> String {
                var x = "<table:table-row>"
                for i in 0..<cols {
                    let al = i < t.align.count ? t.align[i] : DocAlign.none
                    let style = header ? "TblHead" : (al == .right ? "TblRight" : (al == .center ? "TblCenter" : "TblBody"))
                    x += "<table:table-cell table:style-name=\"TblCell\" office:value-type=\"string\"><text:p text:style-name=\"\(style)\">\(inline(i < r.count ? r[i] : [], header ? 1 : 0))</text:p></table:table-cell>"
                }
                return x + "</table:table-row>"
            }
            if let h = t.header { s += "<table:table-header-rows>" + row(h, header: true) + "</table:table-header-rows>" }
            for r in t.rows { s += row(r, header: false) }
            return s + "</table:table>"
        }

        // MARK: Inlines
        // Text style bits: 1 bold, 2 italic, 4 underline, 8 strike, 16 code.

        private mutating func inline(_ items: [DocInline], _ mask: Int) -> String {
            var out = ""
            for i in items {
                switch i {
                case .text(let t): out += span(escapedText(t), mask)
                case .code(let c): out += span(escapedText(c), mask | 16)
                case .emphasis(let c): out += inline(c, mask | 2)
                case .strong(let c): out += inline(c, mask | 1)
                case .underline(let c): out += inline(c, mask | 4)
                case .strike(let c): out += inline(c, mask | 8)
                case .link(let url, _, let c):
                    let inner = inline(c, mask)
                    out += url.isEmpty || url.hasPrefix("#") ? inner : "<text:a xlink:type=\"simple\" xlink:href=\"\(DocXML.attr(url))\">\(inner)</text:a>"
                case .image(let src, let alt, _):
                    if let f = frame(src: src, alt: alt) { out += f } else if !alt.isEmpty { out += span(escapedText("[\(alt)]"), mask) }
                case .lineBreak: out += "<text:line-break/>"
                case .softBreak: out += " "
                }
            }
            return out
        }

        private mutating func span(_ xml: String, _ mask: Int) -> String {
            guard mask != 0, !xml.isEmpty else { return xml }
            textStyles.insert(mask)
            return "<text:span text:style-name=\"T\(mask)\">\(xml)</text:span>"
        }

        /// Text with ODF whitespace rules: runs of spaces become text:s, tabs text:tab, newlines text:line-break.
        func escapedText(_ s: String) -> String {
            var out = ""
            var spaces = 0
            var atStart = true          // start of the text or right after a tab / line break: a space there would be dropped by ODF
            func flush(final: Bool) {
                guard spaces > 0 else { return }
                let explicit = atStart || final
                if spaces == 1 { out += explicit ? "<text:s/>" : " " }
                else { out += (explicit ? "" : " ") + "<text:s text:c=\"\(explicit ? spaces : spaces - 1)\"/>" }
                spaces = 0
            }
            for u in s.unicodeScalars {
                if u == " " { spaces += 1; continue }
                flush(final: false)
                switch u {
                case "\t": out += "<text:tab/>"; atStart = true
                case "\n": out += "<text:line-break/>"; atStart = true
                case "\r": break
                default: out += DocXML.escape(String(u)); atStart = false
                }
            }
            flush(final: true)
            return out
        }

        private mutating func frame(src: String, alt: String) -> String? {
            guard var m = model.media[src] else { return nil }
            if !["image/png", "image/jpeg", "image/gif", "image/bmp", "image/tiff", "image/svg+xml"].contains(m.mime) {
                guard let png = DocMediaKind.pngData(m.data) else { return nil }
                m = DocMedia(name: (m.name as NSString).deletingPathExtension + ".png", mime: "image/png", data: png)
            }
            let path: String
            if let p = pictureNames[src] { path = p } else {
                path = "Pictures/image\(pictureNames.count + 1).\(m.fileExtension)"
                pictureNames[src] = path
                pictures.append(DocPackage.Part(name: path, data: m.data, stored: true))
            }
            let px = DocMediaKind.pixelSize(m.data) ?? (400, 300)
            let maxW = o.page.contentWidth, maxH = o.page.contentHeight * 0.9
            var w = Double(px.width) * 0.75, h = Double(px.height) * 0.75      // CSS pixels to points
            let scale = min(1, maxW / w, maxH / h)
            w *= scale; h *= scale
            let cm = { (pt: Double) in String(format: "%.3fcm", pt / 72 * 2.54) }
            return "<draw:frame draw:name=\"Image\(pictureNames.count)\" text:anchor-type=\"as-char\" svg:width=\"\(cm(w))\" svg:height=\"\(cm(h))\"><draw:image xlink:href=\"\(path)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>\(alt.isEmpty ? "" : "<svg:desc>\(DocXML.escape(alt))</svg:desc>")</draw:frame>"
        }

        // MARK: Package

        func parts(body: String) -> [DocPackage.Part] {
            var parts: [DocPackage.Part] = []
            parts.append(.init(name: "mimetype", data: Data(DocOdtWriter.mimeType.utf8), stored: true))
            var manifest = DocXML.declaration + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"\(DocOdtWriter.mimeType)\"/>"
            for n in ["content.xml", "styles.xml", "meta.xml"] { manifest += "<manifest:file-entry manifest:full-path=\"\(n)\" manifest:media-type=\"text/xml\"/>" }
            for p in pictures { manifest += "<manifest:file-entry manifest:full-path=\"\(p.name)\" manifest:media-type=\"\(DocMediaKind.mime(forExtension: (p.name as NSString).pathExtension))\"/>" }
            parts.append(.init(name: "META-INF/manifest.xml", data: Data((manifest + "</manifest:manifest>").utf8)))
            parts.append(.init(name: "meta.xml", data: Data(meta().utf8)))
            parts.append(.init(name: "styles.xml", data: Data(styles().utf8)))
            parts.append(.init(name: "content.xml", data: Data(content(body: body).utf8)))
            parts += pictures
            return parts
        }

        private func meta() -> String {
            var s = DocXML.declaration + "<office:document-meta \(DocOdtWriter.namespaces) office:version=\"1.2\"><office:meta><meta:generator>Swamp Converter</meta:generator>"
            if o.includeAuthorAndTitle {
                if let t = model.meta.title, !t.isEmpty { s += "<dc:title>\(DocXML.escape(t))</dc:title>" }
                if let a = model.meta.author, !a.isEmpty { s += "<meta:initial-creator>\(DocXML.escape(a))</meta:initial-creator><dc:creator>\(DocXML.escape(a))</dc:creator>" }
            }
            if let l = model.meta.language, !l.isEmpty { s += "<dc:language>\(DocXML.escape(l))</dc:language>" }
            if o.includeDates {
                s += "<meta:creation-date>\(DocXML.isoDate(model.meta.created ?? Date()))</meta:creation-date><dc:date>\(DocXML.isoDate(Date()))</dc:date>"
            }
            return s + "</office:meta></office:document-meta>"
        }

        private func content(body: String) -> String {
            var s = DocXML.declaration + "<office:document-content \(DocOdtWriter.namespaces) office:version=\"1.2\"><office:automatic-styles>"
            for mask in textStyles.sorted() {
                var props = ""
                if mask & 1 != 0 { props += " fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"" }
                if mask & 2 != 0 { props += " fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\"" }
                if mask & 4 != 0 { props += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"" }
                if mask & 8 != 0 { props += " style:text-line-through-style=\"solid\"" }
                if mask & 16 != 0 { props += " fo:font-family=\"Menlo\" style:font-name=\"Menlo\" fo:font-size=\"90%\"" }
                s += "<style:style style:name=\"T\(mask)\" style:family=\"text\"><style:text-properties\(props)/></style:style>"
            }
            s += "<style:style style:name=\"PageBreak\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:break-after=\"page\"/></style:style>"
            s += "<style:style style:name=\"Tbl\" style:family=\"table\"><style:table-properties style:width=\"\(String(format: "%.3fcm", o.page.contentWidth / 72 * 2.54))\" table:align=\"margins\"/></style:style>"
            s += "<style:style style:name=\"TblCol\" style:family=\"table-column\"/>"
            s += "<style:style style:name=\"TblCell\" style:family=\"table-cell\"><style:table-cell-properties fo:padding=\"0.1cm\" fo:border=\"0.5pt solid #a6a6a6\"/></style:style>"
            s += "<style:style style:name=\"TblHead\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:text-properties fo:font-weight=\"bold\"/></style:style>"
            s += "<style:style style:name=\"TblBody\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"/>"
            s += "<style:style style:name=\"TblRight\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:text-align=\"end\"/></style:style>"
            s += "<style:style style:name=\"TblCenter\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:text-align=\"center\"/></style:style>"
            s += "<text:list-style style:name=\"BulletList\">"
            for l in 1...9 {
                s += "<text:list-level-style-bullet text:level=\"\(l)\" text:bullet-char=\"\(["\u{2022}", "\u{25E6}", "\u{25AA}"][(l - 1) % 3])\"><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(0.63 * Double(l))cm\" fo:text-indent=\"-0.63cm\" fo:margin-left=\"\(0.63 * Double(l))cm\"/></style:list-level-properties></text:list-level-style-bullet>"
            }
            s += "</text:list-style>"
            for (name, _) in numberedLists {
                s += "<text:list-style style:name=\"\(name)\">"
                for l in 1...9 {
                    s += "<text:list-level-style-number text:level=\"\(l)\" style:num-suffix=\".\" style:num-format=\"\(["1", "a", "i"][(l - 1) % 3])\"><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(0.63 * Double(l))cm\" fo:text-indent=\"-0.63cm\" fo:margin-left=\"\(0.63 * Double(l))cm\"/></style:list-level-properties></text:list-level-style-number>"
                }
                s += "</text:list-style>"
            }
            s += "</office:automatic-styles><office:body><office:text>"
            // Restart values: the first item of a numbered list carries its start value.
            var xml = body
            for (name, start) in numberedLists where start != 1 {
                if let r = xml.range(of: "<text:list text:style-name=\"\(name)\"><text:list-item>") {
                    xml.replaceSubrange(r, with: "<text:list text:style-name=\"\(name)\"><text:list-item text:start-value=\"\(start)\">")
                }
            }
            return s + xml + "</office:text></office:body></office:document-content>"
        }

        private func styles() -> String {
            let font = DocXML.attr(o.font)
            let size = String(format: "%.1fpt", o.fontSize)
            let p = o.page
            let lh = String(format: "%.0f%%", o.lineSpacing * 100)
            func heading(_ n: Int, _ pt: Double) -> String {
                "<style:style style:name=\"Heading_20_\(n)\" style:display-name=\"Heading \(n)\" style:family=\"paragraph\" style:parent-style-name=\"Heading\" style:next-style-name=\"Text_20_body\" style:default-outline-level=\"\(n)\" style:class=\"text\"><style:paragraph-properties fo:margin-top=\"\(n == 1 ? "0.42cm" : "0.3cm")\" fo:margin-bottom=\"0.12cm\" fo:keep-with-next=\"always\"/><style:text-properties fo:font-size=\"\(String(format: "%.1f", pt * o.fontSize / 11))pt\" fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"/></style:style>"
            }
            var s = DocXML.declaration + "<office:document-styles \(DocOdtWriter.namespaces) office:version=\"1.2\"><office:font-face-decls><style:font-face style:name=\"\(font)\" svg:font-family=\"'\(font)'\"/><style:font-face style:name=\"Menlo\" svg:font-family=\"Menlo\" style:font-family-generic=\"modern\"/></office:font-face-decls><office:styles>"
            s += "<style:default-style style:family=\"paragraph\"><style:paragraph-properties fo:orphans=\"2\" fo:widows=\"2\" style:writing-mode=\"page\"/><style:text-properties style:font-name=\"\(font)\" fo:font-size=\"\(size)\" fo:language=\"\(DocXML.attr((model.meta.language ?? "en-US").split(separator: "-").first.map(String.init) ?? "en"))\"/></style:default-style>"
            s += "<style:style style:name=\"Standard\" style:family=\"paragraph\" style:class=\"text\"/>"
            s += "<style:style style:name=\"Heading\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" style:next-style-name=\"Text_20_body\" style:class=\"text\"/>"
            s += "<style:style style:name=\"Text_20_body\" style:display-name=\"Text body\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" style:class=\"text\"><style:paragraph-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0.21cm\" fo:line-height=\"\(lh)\"/></style:style>"
            let sizes: [Double] = [20, 16, 14, 13, 12, 11]
            for (i, pt) in sizes.enumerated() { s += heading(i + 1, pt) }
            s += "<style:style style:name=\"List_20_Paragraph\" style:display-name=\"List Paragraph\" style:family=\"paragraph\" style:parent-style-name=\"Text_20_body\" style:class=\"list\"><style:paragraph-properties fo:margin-bottom=\"0.1cm\"/></style:style>"
            s += "<style:style style:name=\"Quotations\" style:family=\"paragraph\" style:parent-style-name=\"Text_20_body\" style:class=\"html\"><style:paragraph-properties fo:margin-left=\"1cm\" fo:margin-right=\"0cm\" fo:border-left=\"1.5pt solid #bfbfbf\" fo:padding-left=\"0.3cm\"/><style:text-properties fo:font-style=\"italic\"/></style:style>"
            s += "<style:style style:name=\"Preformatted_20_Text\" style:display-name=\"Preformatted Text\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" style:class=\"html\"><style:paragraph-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:background-color=\"#f2f2f2\"/><style:text-properties style:font-name=\"Menlo\" fo:font-family=\"Menlo\" fo:font-size=\"90%\"/></style:style>"
            s += "<style:style style:name=\"Horizontal_20_Line\" style:display-name=\"Horizontal Line\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:margin-top=\"0.1cm\" fo:margin-bottom=\"0.2cm\" fo:border-bottom=\"0.5pt solid #999999\"/></style:style>"
            s += "</office:styles><office:automatic-styles><style:page-layout style:name=\"pm1\"><style:page-layout-properties fo:page-width=\"\(p.widthCM)\" fo:page-height=\"\(p.heightCM)\" style:print-orientation=\"portrait\" fo:margin-top=\"\(p.marginCM)\" fo:margin-bottom=\"\(p.marginCM)\" fo:margin-left=\"\(p.marginCM)\" fo:margin-right=\"\(p.marginCM)\"/></style:page-layout></office:automatic-styles>"
            s += "<office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"pm1\"/></office:master-styles></office:document-styles>"
            return s
        }
    }
}
