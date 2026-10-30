import Foundation

// The built-in engine: any of the eight formats -> DocModel -> any of the eight formats. Readers are our own (DOCX, ODT, EPUB, Markdown, HTML, plain text); the two legacy
// formats (binary .doc and RTF) go through /usr/bin/textutil to HTML first, which the HTML reader understands (headings are recognised by size and weight).

struct DocWriteReport: Sendable {
    /// Characters the output encoding could not represent (written as "?" in text files, as numeric references in HTML and Markdown).
    var replacedCharacters = 0
    var pages: Int?
    var notes: [String] = []
}

enum DocNative {
    // MARK: Reading

    /// Largest text file read into memory for conversion to a rich format. Re-encoding a bigger text file (txt -> txt) streams instead.
    static let maxTextBytes = 256 << 20

    static func read(_ url: URL, key: String, settings s: DocSettings, ctx: OperationContext?) async throws -> DocModel {
        try Task.checkCancellation()
        var model: DocModel
        switch key {
        case "docx": model = try DocDocxReader.read(url)
        case "odt": model = try DocOdtReader.read(url)
        case "epub": model = try DocEpubReader.read(url)
        case "doc", "rtf": model = try await readLegacy(url, ctx: ctx)
        case "md", "txt", "html":
            let data = try readText(url)
            let enc = s.encodingIn
            if key == "html" {
                var id = enc
                if id == "auto", !DocTextCodec.detect(data).hasBOM, let declared = declaredCharset(data) { id = declared }
                model = DocHTMLReader.read(DocTextCodec.decode(data, as: id).text)
            } else if key == "md" {
                model = DocMarkdown.parse(DocTextCodec.decode(data, as: enc).text, gfm: true)     // reading accepts GFM tables whatever flavour is written
            } else {
                model = DocModel()
                model.blocks = DocPlainText.read(DocTextCodec.decode(data, as: enc).text, reflow: s.reflow)
            }
            let base = url.deletingLastPathComponent()
            model.resolveImages { src in
                let decoded = src.removingPercentEncoding ?? src
                guard !decoded.hasPrefix("/"), !decoded.hasPrefix("~") else { return nil }
                let file = base.appendingPathComponent(decoded).standardizedFileURL
                guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= 100_000_000, let d = try? Data(contentsOf: file) else { return nil }
                return (d, file.lastPathComponent)
            }
        default:
            throw ConversionError.unsupported(L10n("The format \(Formats.displayName(key)) cannot be read by the built-in engine.", "Формат \(Formats.displayName(key)) нельзя прочитать встроенным движком."))
        }
        if s.stripImages { model.removePictures() }
        return model
    }

    static func readText(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxTextBytes {
            throw ConversionError.message(L10n("The file is too large to convert to another document format (\(Util.formatBytes(Int64(size)))). Converting plain text to plain text works at any size.",
                                               "Файл слишком велик для конвертации в другой формат документа (\(Util.formatBytes(Int64(size)))). Перекодировка простого текста в простой текст работает при любом размере."))
        }
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.fileUnreadable(url) }
    }

    /// The charset an HTML file declares in its first bytes, mapped to our encoding ids.
    static func declaredCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(4096).map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        guard let r = head.range(of: "charset\\s*=\\s*[\"']?([A-Za-z0-9_\\-]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let name = String(head[r]).replacingOccurrences(of: "charset", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " =\"'\t")).lowercased()
        switch name {
        case "utf-8", "utf8": return "utf-8"
        case "windows-1251", "cp1251", "x-cp1251": return "windows-1251"
        case "koi8-r", "koi8r": return "koi8-r"
        case "ibm866", "cp866", "866": return "cp866"
        case "windows-1257", "cp1257": return "windows-1257"
        case "iso-8859-13": return "iso-8859-13"
        case "windows-1250", "cp1250": return "windows-1250"
        case "windows-1252", "cp1252", "iso-8859-1", "latin1", "us-ascii": return "windows-1252"
        case "macintosh", "x-mac-roman": return "macroman"
        case "utf-16", "utf-16le": return "utf-16"
        case "utf-16be": return "utf-16be"
        default: return nil
        }
    }

    /// Binary .doc and RTF through textutil: HTML out, then our HTML reader. Pictures textutil writes next to the HTML are read back from the temporary folder.
    static func readLegacy(_ url: URL, ctx: OperationContext?) async throws -> DocModel {
        let work = AppPaths.makeTempDirectory(purpose: "doc-textutil")
        defer { AppPaths.removeTemp(work) }
        let html = work.appendingPathComponent("out.html")
        try await DocProcess.run(URL(fileURLWithPath: "/usr/bin/textutil"), ["-convert", "html", "-encoding", "UTF-8", "-output", html.path, url.path], ctx: ctx)
        guard let data = try? Data(contentsOf: html) else { throw ConversionError.fileUnreadable(url) }
        var model = DocHTMLReader.read(DocTextCodec.decode(data, as: "utf-8").text)
        model.blocks = DocLegacyLists.recover(model.blocks)
        model.resolveImages { src in
            let decoded = src.removingPercentEncoding ?? src
            guard !decoded.hasPrefix("/") else { return nil }
            let file = work.appendingPathComponent(decoded).standardizedFileURL
            guard file.path.hasPrefix(work.path), let d = try? Data(contentsOf: file) else { return nil }
            return (d, file.lastPathComponent)
        }
        return model
    }

    // MARK: Writing

    /// Writes `model` as `target` to `url` (a temporary file). `mediaFolder` is the name of the folder (next to the final file) that holds the extracted pictures.
    @discardableResult
    static func write(_ source: DocModel, to url: URL, settings s: DocSettings, baseName: String, mediaFolder: String? = nil) async throws -> DocWriteReport {
        try Task.checkCancellation()
        var model = source
        model.meta = s.metadata(of: source.meta)
        if s.stripImages { model.removePictures() }
        let target = s.target
        let includeMeta = !s.stripMetadata
        var report = DocWriteReport()
        let family = s.fontFamily(for: target)
        if target == "pdf" || target == "docx" || target == "odt" || target == "rtf", s.font != "auto", !PdfFonts.isInstalled(family) {
            report.notes.append("The font \(family) is not installed on this Mac; the result uses a substitute.")
        }
        switch target {
        case "docx":
            var o = DocDocxWriter.Options()
            o.page = s.page; o.includeAuthorAndTitle = includeMeta; o.includeDates = includeMeta
            o.font = family; o.fontSize = s.fontSize; o.lineSpacing = s.lineSpacing
            try DocDocxWriter.write(model, options: o, to: url)
        case "odt":
            var o = DocOdtWriter.Options()
            o.page = s.page; o.includeAuthorAndTitle = includeMeta; o.includeDates = includeMeta
            o.font = family; o.fontSize = s.fontSize; o.lineSpacing = s.lineSpacing
            try DocOdtWriter.write(model, options: o, to: url)
        case "rtf":
            var o = DocRtfWriter.Options()
            o.page = s.page; o.includeAuthorAndTitle = includeMeta; o.includeDates = includeMeta
            o.font = family; o.fontSize = s.fontSize; o.lineSpacing = s.lineSpacing
            try DocRtfWriter.write(model, options: o, to: url)
        case "pdf":
            var o = DocPdfWriter.Options()
            o.page = s.page; o.font = family; o.fontSize = s.fontSize; o.lineSpacing = s.lineSpacing
            o.pageNumbers = s.pageNumbers; o.includeAuthorAndTitle = includeMeta
            o.title = model.meta.title; o.author = model.meta.author
            report.pages = try DocPdfWriter.write(model, options: o, to: url)
            PdfPatch.normalize(url, stripDates: s.stripMetadata)
        case "epub":
            var o = DocEpubWriter.Options()
            o.title = model.meta.title ?? model.firstHeading ?? baseName
            o.author = model.meta.author
            o.language = model.meta.language
            o.splitLevel = s.epubSplit
            o.includeDates = includeMeta
            if !s.epubCover.isEmpty { o.cover = try? Data(contentsOf: URL(fileURLWithPath: s.epubCover)) }
            try DocEpubWriter.write(model, options: o, to: url)
        case "html":
            var o = DocHTMLWriter.Options()
            o.title = model.meta.title ?? model.firstHeading ?? baseName
            o.author = model.meta.author
            o.language = model.meta.language
            o.charset = DocSettings.charsetName(s.encodingOut)
            o.embedImages = s.htmlEmbed
            o.mediaFolder = s.htmlEmbed ? nil : mediaFolder
            let out = DocHTMLWriter.write(model.webSafeMedia(), options: o)
            report.replacedCharacters = try writeText(out.html, to: url, settings: s, entities: true)
        case "md":
            let r = DocMarkdownWriter.write(model.webSafeMedia(), gfm: s.markdownGFM, mediaFolder: s.extractMedia ? (mediaFolder ?? "") : nil, frontMatter: s.frontMatter)
            report.replacedCharacters = try writeText(r.markdown, to: url, settings: s, entities: true)
        case "txt":
            report.replacedCharacters = try writeText(DocPlainText.render(model.blocks, wrap: s.wrap), to: url, settings: s, entities: false)
        default:
            throw ConversionError.unsupported(L10n("The built-in engine cannot write \(Formats.displayName(target)).", "Встроенный движок не может записать \(Formats.displayName(target))."))
        }
        return report
    }

    /// Text output: line endings, encoding with BOM, unrepresentable characters. Returns how many characters were replaced.
    @discardableResult
    static func writeText(_ text: String, to url: URL, settings s: DocSettings, entities: Bool) throws -> Int {
        var body = DocTextCodec.normalizeLineEndings(text, to: s.eol)
        var replaced = 0
        let id = s.encodingOut.lowercased()
        if entities, let enc = DocTextCodec.stringEncoding(id), !id.hasPrefix("utf") {
            // Markup can say any character with a numeric reference: nothing is lost in a legacy code page.
            var out = String.UnicodeScalarView()
            for u in body.unicodeScalars {
                if u.isASCII || String(u).data(using: enc, allowLossyConversion: false) != nil { out.append(u) }
                else { out.append(contentsOf: "&#\(u.value);".unicodeScalars) }
            }
            body = String(out)
        }
        let encoded = DocTextCodec.encode(body, as: id, bom: s.bom)
        replaced = encoded.replaced
        try encoded.data.write(to: url)
        return replaced
    }
}

extension DocModel {
    mutating func removePictures() {
        mapImages { _, _, _ in .text("") }
        blocks = blocks.map { $0.mapInlineGroups { $0.normalized() } }
        media = [:]
    }
}

/// Runs a tool through the job when there is one (pause / cancel reach the process), else directly.
enum DocProcess {
    @discardableResult
    static func run(_ exe: URL, _ args: [String], ctx: OperationContext?, workingDirectory: URL? = nil, allowNonZeroExit: Bool = false) async throws -> ProcessOutput {
        if let ctx { return try await ctx.runProcess(exe, args, workingDirectory: workingDirectory, allowNonZeroExit: allowNonZeroExit) }
        return try await ProcessRunner.run(exe, args, workingDirectory: workingDirectory, allowNonZeroExit: allowNonZeroExit)
    }
}
