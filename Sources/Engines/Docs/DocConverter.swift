import Foundation

// DocConverter: the shared service of the documents engine. The wheel, the Studio, the CLI and the PDF module all come through here.
//   convert        one file -> one file, through the engine the router picks (built-in, Pandoc, LibreOffice or a pair of them)
//   write          Markdown (from the PDF text extractor) -> docx / html / epub / odt / rtf / pdf / txt, always the built-in writers
//   readMarkdown   any supported document -> Markdown text (pictures optionally extracted)
//   officeConvert  one LibreOffice run (single instance, private profile, watchdog)
// Output files are written to the temporary URL the caller got from `ctx.produceFile`; folders of extracted pictures are produced next to the final file.

struct DocRunReport: Sendable {
    var route: DocRoute = .native
    /// Extra results produced next to the file (the folder of extracted pictures).
    var extras: [URL] = []
    var replacedCharacters = 0
    var pages: Int?
    var notes: [String] = []
}

enum DocConverter {
    /// Converts `input` to `target` ("docx", "pdf", "odt", "md", "html", "txt", "epub", "rtf") into `output` (a temp URL from `ctx.produceFile`).
    /// Route choice: `DocRouter` (built-in first; Pandoc / LibreOffice when they are found, the options allow it or the person forced them).
    static func convert(input: URL, to target: String, output: URL, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws {
        _ = try await convertDetailed(input: input, to: target, output: output, options: options, ctx: ctx, progress: progress)
    }

    @discardableResult
    static func convertDetailed(input: URL, to target: String, output: URL, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws -> DocRunReport {
        var s = DocSettings(options)
        s.target = target
        let inKey = Formats.key(of: input)
        let base = Formats.baseName(of: input)
        let ignored = s.nativeOnlyChanges(for: target)
        let decision = DocRouter.route(input: inKey, target: target, engine: s.engine, nativeOptionsChanged: !ignored.isEmpty, tools: ctx.tools)
        guard case .route(let route) = decision else {
            if case .none(let reason, _) = decision { throw ConversionError.message(reason) }
            throw ConversionError.noOutput
        }
        var report = DocRunReport(route: route)
        ctx.log("Document engine: \(route.label.en)")
        if route != .native && route != .sofficeThenNative && !ignored.isEmpty { ctx.log("Options this engine does not apply: " + ignored.joined(separator: ", ")) }
        try ctx.checkCancelled()

        switch route {
        case .native:
            try await native(input: input, inKey: inKey, base: base, settings: s, output: output, ctx: ctx, progress: progress, report: &report)
        case .soffice:
            let work = ctx.tempDir.appendingPathComponent("office-\(Util.hex8())", isDirectory: true)
            let made = try await DocOffice.convert(input: input, filter: DocOffice.convertTo(target), outputDirectory: work, ctx: ctx)
            progress.report(0.95)
            try FileManager.default.moveItem(at: made, to: output)
        case .sofficeThenNative:
            let work = ctx.tempDir.appendingPathComponent("office-\(Util.hex8())", isDirectory: true)
            let docx = try await DocOffice.convert(input: input, filter: DocOffice.convertTo("docx"), outputDirectory: work, ctx: ctx)
            progress.report(0.5)
            try await native(input: docx, inKey: "docx", base: base, settings: s, output: output, ctx: ctx, progress: progress, report: &report, progressBase: 0.5, recoverLists: true)
        case .pandoc, .pandocThenSoffice, .sofficeThenPandoc:
            try await pandocRoutes(route, input: input, inKey: inKey, base: base, settings: s, output: output, ctx: ctx, progress: progress, report: &report)
        }
        progress.report(1)
        return report
    }

    // MARK: Built-in route

    private static func native(input: URL, inKey: String, base: String, settings s: DocSettings, output: URL, ctx: OperationContext, progress: ProgressSlice,
                               report: inout DocRunReport, progressBase: Double = 0, recoverLists: Bool = false) async throws {
        func at(_ f: Double) { progress.report(progressBase + (1 - progressBase) * f) }
        // Plain text to plain text is a re-encode: stream it, so a huge log file never sits in memory.
        if inKey == "txt", s.target == "txt", s.wrap == 0, s.reflow != .join {
            let r = try DocTextCodec.transcodeFile(input: input, encodingIn: s.encodingIn, to: output, encodingOut: s.encodingOut, bom: s.bom, eol: s.eol) { at($0) }
            report.replacedCharacters = r.replaced
            ctx.log("Detected input encoding: \(r.detected)")
            if r.replaced > 0 { report.notes.append("\(r.replaced) characters are not representable in \(s.encodingOut) and became \"?\"") }
            return
        }
        var model = try await DocNative.read(input, key: inKey, settings: s, ctx: ctx)
        if recoverLists { model.blocks = DocLegacyLists.recover(model.blocks) }       // a .doc that went through LibreOffice still has typed bullets
        at(0.45)
        // Pictures next to the file (Markdown extraction, HTML that is not a single file): the folder is produced first so its final name is known.
        var folderName: String?
        let wantsFolder = (s.target == "md" && s.extractMedia) || (s.target == "html" && !s.htmlEmbed)
        let used = Set(model.imageSources).filter { model.media[$0] != nil }
        if wantsFolder && !used.isEmpty {
            let safe = model.webSafeMedia()
            let folder = try await ctx.produceFolder(for: FileItem(url: input), name: DocConverter.mediaFolderName(base)) { dir in
                for key in used.sorted() { if let m = safe.media[key] { try m.data.write(to: dir.appendingPathComponent(m.name)) } }
            }
            folderName = folder.lastPathComponent
            report.extras.append(folder)
        }
        do {
            let w = try await DocNative.write(model, to: output, settings: s, baseName: base, mediaFolder: folderName)
            report.replacedCharacters = w.replacedCharacters
            report.pages = w.pages
            report.notes += w.notes
            if w.replacedCharacters > 0 { report.notes.append("\(w.replacedCharacters) characters are not representable in \(s.encodingOut)") }
        } catch {
            for e in report.extras { try? FileManager.default.removeItem(at: e) }       // the folder is ours: do not leave it without its document
            report.extras = []
            throw error
        }
        for n in report.notes { ctx.log(n) }
    }

    static func mediaFolderName(_ base: String) -> String { "\(base) - media" }

    // MARK: Pandoc routes

    private static func pandocRoutes(_ route: DocRoute, input: URL, inKey: String, base: String, settings s: DocSettings, output: URL, ctx: OperationContext,
                                     progress: ProgressSlice, report: inout DocRunReport) async throws {
        let work = ctx.tempDir.appendingPathComponent("pandoc-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let version = DocPandocVersion(ctx.tools.version(of: .pandoc))
        func writeFilter(target: String, settings: DocSettings) throws -> String {
            let need = DocPandoc.filterNeeds(target: target, settings: settings)
            let url = work.appendingPathComponent("structure-\(target).lua")
            try DocPandoc.filterSource(keepTitle: need.keepTitle, promoteHeader: need.promoteHeader).write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        var source = input, sourceKey = inKey
        if route == .sofficeThenPandoc {
            source = try await DocOffice.convert(input: input, filter: DocOffice.convertTo("docx"), outputDirectory: work.appendingPathComponent("lo"), ctx: ctx)
            sourceKey = "docx"
            progress.report(0.4)
        }
        if route == .pandocThenSoffice {
            let tmp = work.appendingPathComponent("\(base).docx")
            var step = s; step.target = "docx"
            let args = DocPandoc.arguments(input: input, inputKey: inKey, target: "docx", output: tmp, settings: step, baseName: base, version: version,
                                           filter: try writeFilter(target: "docx", settings: step))
            _ = try await ctx.runTool(.pandoc, args, workingDirectory: input.deletingLastPathComponent())
            progress.report(0.4)
            let made = try await DocOffice.convert(input: tmp, filter: DocOffice.convertTo(s.target), outputDirectory: work.appendingPathComponent("lo"), ctx: ctx)
            try FileManager.default.moveItem(at: made, to: output)
            return
        }
        let plannedFolder = DocConverter.mediaFolderName(base)
        let extracts = s.target == "md" && s.extractMedia && ["docx", "odt", "epub"].contains(sourceKey)
        let args = DocPandoc.arguments(input: source, inputKey: sourceKey, target: s.target, output: output, settings: s, baseName: base, version: version,
                                       mediaFolder: extracts ? plannedFolder : nil, filter: try writeFilter(target: s.target, settings: s))
        _ = try await ctx.runTool(.pandoc, args, workingDirectory: extracts ? work : source.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.noOutput }
        if extracts, FileManager.default.fileExists(atPath: work.appendingPathComponent(plannedFolder).path) {
            let extracted = work.appendingPathComponent(plannedFolder)
            let folder = try await ctx.produceFolder(for: FileItem(url: input), name: plannedFolder) { dir in
                for item in (try? FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)) ?? [] {
                    try FileManager.default.moveItem(at: item, to: dir.appendingPathComponent(item.lastPathComponent))
                }
            }
            report.extras.append(folder)
            if folder.lastPathComponent != plannedFolder, var text = try? String(contentsOf: output, encoding: .utf8) {
                text = text.replacingOccurrences(of: plannedFolder + "/", with: folder.lastPathComponent + "/")
                try text.write(to: output, atomically: false, encoding: .utf8)
            }
        }
    }

    // MARK: Writing Markdown (the PDF module's door)

    /// Writes Markdown / plain paragraphs (from the PDF text extractor) as docx / html / epub / odt / rtf / pdf / txt / md with the built-in writers.
    static func write(markdown: String, title: String?, as target: String, to output: URL, options: OptionValues) async throws {
        var s = DocSettings(options)
        s.target = target
        if s.title == nil { s.title = title?.nonEmpty }
        guard DocRouter.nativeWrites.contains(target) else {
            throw ConversionError.unsupported(L10n("The format \(Formats.displayName(target)) is not a document format.", "Формат \(Formats.displayName(target)) не является форматом документа."))
        }
        let model = DocMarkdown.parse(markdown, gfm: s.markdownGFM)
        try await DocNative.write(model, to: output, settings: s, baseName: title?.nonEmpty ?? "Document")
    }

    // MARK: Reading Markdown

    /// Reads any supported document as Markdown (headings, lists, emphasis, tables best effort). Pictures are written to `extractMediaTo` (referenced relative to its parent)
    /// or left out when it is nil.
    static func readMarkdown(_ input: URL, extractMediaTo: URL?) async throws -> String {
        let key = Formats.key(of: input)
        let model = try await DocNative.read(input, key: key, settings: DocSettings(), ctx: nil)
        let safe = model.webSafeMedia()
        var folderName: String?
        if let dir = extractMediaTo, !safe.media.isEmpty {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for m in safe.media.values { try m.data.write(to: dir.appendingPathComponent(m.name)) }
            folderName = dir.lastPathComponent
        }
        return DocMarkdownWriter.write(safe, gfm: true, mediaFolder: folderName).markdown
    }

    // MARK: LibreOffice

    /// LibreOffice headless conversion (one instance at a time, private profile dir). `filter` is the target format ("pdf", "docx", "odt", "pptx", "odp", "txt" ...).
    /// PDF input to pptx / odp uses the PDF import filter. Returns the produced file inside `outputDirectory`.
    static func officeConvert(input: URL, filter: String, outputDirectory: URL, ctx: OperationContext) async throws -> URL {
        let pdfImport = Formats.key(of: input) == "pdf" && (filter == "pptx" || filter == "odp")
        return try await DocOffice.convert(input: input, filter: DocOffice.convertTo(filter), outputDirectory: outputDirectory, ctx: ctx, infilter: pdfImport ? "impress_pdf_import" : nil)
    }
}

/// Same-length edits of the document information dictionary of a PDF written by Core Graphics: the Producer string (it carries the macOS build) becomes our name, and,
/// when asked, the date keys are renamed so no creation or modification date is stored. Offsets in the cross-reference table stay valid because nothing changes length.
enum PdfPatch {
    static func normalize(_ url: URL, stripDates: Bool) {
        guard var data = try? Data(contentsOf: url), data.count < 256 << 20 else { return }
        var bytes = [UInt8](data)
        func find(_ needle: String, from: Int = 0) -> Int? {
            let n = Array(needle.utf8)
            guard bytes.count >= n.count else { return nil }
            var i = max(0, from)
            outer: while i <= bytes.count - n.count {
                for k in 0..<n.count where bytes[i + k] != n[k] { i += 1; continue outer }
                return i
            }
            return nil
        }
        if let p = find("/Producer (") {
            var i = p + 11, depth = 1
            let start = i
            while i < bytes.count, depth > 0 {
                if bytes[i] == 0x5C { i += 2; continue }          // backslash escape
                if bytes[i] == 0x28 { depth += 1 } else if bytes[i] == 0x29 { depth -= 1 }
                if depth > 0 { i += 1 }
            }
            let len = i - start
            if len > 0 {
                var text = Array("Swamp Converter".utf8.prefix(len))
                while text.count < len { text.append(0x20) }
                bytes.replaceSubrange(start..<start + len, with: text)
            }
        }
        if stripDates {
            if let c = find("/CreationDate (") { bytes.replaceSubrange(c..<c + 13, with: Array("/NoCreationDt".utf8)) }
            if let m = find("/ModDate (") { bytes.replaceSubrange(m..<m + 8, with: Array("/NoModDt".utf8)) }
        }
        data = Data(bytes)
        try? data.write(to: url)
    }

    static func blankDates(in url: URL) { normalize(url, stripDates: true) }
}
