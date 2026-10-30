import Foundation
import PDFKit
import CoreGraphics

/// The work of each PDF target for ONE input file: a pure function of (item, ctx.options). `PdfOperation.process` picks the job by the operation's schema id.
enum PdfJobs {
    // MARK: Helpers

    static func color(_ hex: String) -> RGBA {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return .white }
        return RGBA(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Pages to images

    static func images(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        var ro = PdfRasterOptions()
        ro.dpi = Util.clamp(o.int(PdfKeys.rasterDPI, 300), 36, 1200)
        ro.format = o.string(PdfKeys.rasterFormat, "png")
        ro.quality = Util.clamp(o.int(PdfKeys.rasterQuality, 90), 1, 100)
        ro.background = color(o.string(PdfKeys.rasterBackground, "#FFFFFF"))
        ro.grayscale = o.bool(PdfKeys.rasterGray)
        ro.annotations = o.bool(PdfKeys.rasterAnnotations, true)
        ro.transparent = o.bool(PdfKeys.rasterTransparent)
        ro.pages = try PdfDoc.indices(o.string(PdfKeys.pages, "all"), pageCount: doc.pageCount)
        return try await PdfRasterizer.rasterize(pdf: item.url, source: item, options: ro, ctx: ctx, progress: progress)
    }

    // MARK: Text

    /// The text of the selected pages: the pages' own text, the layout text from pdftotext, and recognised text for picture pages (when asked).
    static func pageTexts(_ item: FileItem, doc: PDFDocument, indices: [Int], ctx: OperationContext, progress: ProgressSlice) async throws -> [PdfPageText] {
        let o = ctx.options
        var texts: [Int: String] = [:]
        if o.bool(PdfKeys.textLayout) && ctx.isActive(PdfKeys.textLayout), ctx.tools.has(.pdftotext), let first = indices.first, let last = indices.last {
            let out = try await ctx.runTool(.pdftotext, ["-layout", "-enc", "UTF-8", "-f", String(first + 1), "-l", String(last + 1), item.url.path, "-"], captureStdout: true)
            let chunks = out.stdout.components(separatedBy: "\u{0C}")
            for n in indices where n - first < chunks.count { texts[n] = PdfGeometry.normalise(chunks[n - first]) }
        } else {
            for n in indices { if let p = doc.page(at: n) { texts[n] = PdfGeometry.text(of: p) } }
        }
        let missing = indices.filter { (texts[$0] ?? "").isEmpty }
        if !missing.isEmpty, o.bool(PdfKeys.ocr), ctx.isActive(PdfKeys.ocr) {
            var settings = PdfOcrSettings(options: o)
            settings.skipText = false
            for (i, n) in missing.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                guard let page = doc.page(at: n) else { continue }
                let r = try await PdfOcrPipeline.recognize(page: page, number: n + 1, settings: settings, ctx: ctx)
                texts[n] = r.text
                progress.report(0.9 * Double(i + 1) / Double(missing.count))
            }
        }
        let result = indices.compactMap { n -> PdfPageText? in
            guard let t = texts[n], !t.isEmpty else { return nil }
            return PdfPageText(number: n + 1, text: t)
        }
        if result.isEmpty { throw ConversionError.message(PdfRasterizer.scanMessage) }
        return result
    }

    static func text(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        let indices = try PdfDoc.indices(o.string(PdfKeys.pages, "all"), pageCount: doc.pageCount)
        let pages = try await pageTexts(item, doc: doc, indices: indices, ctx: ctx, progress: progress)
        let markdown = o.string(PdfKeys.textFormat, "txt") == "md"
        let separators = o.string(PdfKeys.textSeparators, "auto")
        let reflow = o.bool(PdfKeys.textReflow)
        let body = markdown ? PdfMarkdown.markdown(pages: pages, separators: separators, reflow: reflow)
                            : PdfMarkdown.plain(pages: pages, separators: separators, reflow: reflow)
        let data = PdfMarkdown.data(body, encoding: o.string(PdfKeys.textEncoding, "utf8"))
        let url = try await ctx.produceFile(for: item, ext: markdown ? "md" : "txt") { tmp in try data.write(to: tmp) }
        progress.report(1)
        return [url]
    }

    // MARK: Documents

    static func export(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let format = o.string(PdfKeys.exportFormat, "docx")
        if format == "pptx" { return try await presentation(item, ctx: ctx, progress: progress) }
        let (markdown, title) = try await exportMarkdown(item, ctx: ctx, progress: progress)
        let url = try await ctx.produceFile(for: item, ext: format) { tmp in
            try await DocConverter.write(markdown: markdown, title: title, as: format, to: tmp, options: [DocKeys.title: .string(title)])
        }
        progress.report(1)
        return [url]
    }

    /// The Markdown and the title handed to the document writer (a seam the self-tests read without needing the writer).
    static func exportMarkdown(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> (markdown: String, title: String) {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        let indices = try PdfDoc.indices(o.string(PdfKeys.pages, "all"), pageCount: doc.pageCount)
        let pages = try await pageTexts(item, doc: doc, indices: indices, ctx: ctx, progress: progress)
        let markdown = PdfMarkdown.markdown(pages: pages, separators: o.string(PdfKeys.textSeparators, "auto"), reflow: o.bool(PdfKeys.textReflow, true))
        return (markdown, PdfDoc.title(of: doc, fallback: item.base))
    }

    /// PDF -> PPTX through LibreOffice's PDF import filter (one slide per page). Only when LibreOffice is installed.
    static func presentation(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        _ = try ctx.tools.require(.soffice)
        let url = try await ctx.produceFile(for: item, ext: "pptx") { tmp in
            let work = ctx.tempDir.appendingPathComponent("office-\(Util.hex8())", isDirectory: true)
            let profile = work.appendingPathComponent("profile", isDirectory: true)
            let outDir = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try await ctx.runTool(.soffice, ["--headless", "--norestore", "--nolockcheck", "-env:UserInstallation=\(profile.absoluteString)",
                                             "--infilter=impress_pdf_import", "--convert-to", "pptx", "--outdir", outDir.path, item.url.path])
            let made = outDir.appendingPathComponent(item.base + ".pptx")
            guard FileManager.default.fileExists(atPath: made.path) else {
                throw ConversionError.message(L10n("LibreOffice could not convert the file (is it intact and not password-protected?).",
                                                   "LibreOffice не удалось конвертировать файл. Возможно, он повреждён или защищён паролем."))
            }
            try FileManager.default.moveItem(at: made, to: tmp)
        }
        progress.report(1)
        return [url]
    }

    // MARK: Split

    static func split(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        let mode = o.string(PdfKeys.splitMode, "eachPage")
        let chunks: [PdfPageOps.Chunk]
        if mode == "bySize" {
            chunks = try await PdfPageOps.splitBySize(doc: doc, limitBytes: max(1, Int(o.double(PdfKeys.splitMegabytes, 10) * 1_000_000)), ctx: ctx)
        } else {
            chunks = try PdfPageOps.chunks(doc: doc, mode: mode, every: o.int(PdfKeys.splitEvery, 10), ranges: o.string(PdfKeys.splitRanges))
        }
        let strip = o.bool(PdfKeys.stripMeta)
        let folder = try await ctx.produceFolder(for: item, suffix: L10n("pages", "страницы")) { dir in
            for (i, chunk) in chunks.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                let part = PdfPageOps.copyPages(of: doc, indices: chunk.pages)
                if strip { PdfDoc.stripMetadata(part) }
                var name = "\(item.base) - \(PdfGeometry.padded(i + 1, total: chunks.count))"
                if mode == "byBookmark", !chunk.title.isEmpty { name += " " + Util.safeFileName(chunk.title, fallback: "") }
                try PdfDoc.write(part, to: dir.appendingPathComponent(name.trimmingCharacters(in: .whitespaces) + ".pdf"))
                progress.report(Double(i + 1) / Double(chunks.count))
            }
        }
        return [folder]
    }

    // MARK: Rotate, paper size, trim

    static func pages(_ item: FileItem, suffix: L10n?, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        let scope = o.string(PdfKeys.rotateScope, "all")
        let selection: Set<Int> = scope == "selected" ? Set(try PdfDoc.indices(o.string(PdfKeys.pages, "1"), pageCount: doc.pageCount)) : []
        PdfPageOps.rotate(doc, angle: o.int(PdfKeys.rotate, 0), scope: scope, selection: selection)
        PdfPageOps.trim(doc, millimetres: o.double(PdfKeys.trim))
        let strip = o.bool(PdfKeys.stripMeta)
        let paper = PdfGeometry.paper(o.string(PdfKeys.pageSize, "keep"))
        let attrs = doc.documentAttributes
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: "pdf") { tmp in
            if strip { PdfDoc.stripMetadata(doc) }
            guard let paper else { try PdfDoc.write(doc, to: tmp); return }
            let staged = ctx.tempDir.appendingPathComponent("pages-\(Util.hex8()).pdf")
            defer { try? FileManager.default.removeItem(at: staged) }
            try PdfDoc.write(doc, to: staged)
            let fit: PdfComposer.Fit = { switch o.string(PdfKeys.pageSizeFit, "fit") { case "fill": return .fill; case "none": return .none; default: return .fit } }()
            try PdfPageOps.resize(source: staged, to: tmp, target: paper, fixedOrientation: false, fit: fit,
                                  marginPoints: CGFloat(o.double(PdfKeys.margins)) * PdfGeometry.pointsPerMillimetre, stripMeta: strip,
                                  title: attrs?[PDFDocumentAttribute.titleAttribute] as? String, author: attrs?[PDFDocumentAttribute.authorAttribute] as? String)
        }
        progress.report(1)
        return [url]
    }

    // MARK: Extract

    static func extract(_ item: FileItem, suffix: L10n?, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        let selection = try PdfDoc.indices(o.string(PdfKeys.pages, "1"), pageCount: doc.pageCount)
        let result = try PdfPageOps.extract(doc, selection: selection, mode: o.string(PdfKeys.extractMode, "keep"), reverse: o.string(PdfKeys.extractOrder, "keep") == "reverse")
        if o.bool(PdfKeys.stripMeta) { PdfDoc.stripMetadata(result) }
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: "pdf") { tmp in try PdfDoc.write(result, to: tmp) }
        progress.report(1)
        return [url]
    }

    // MARK: Optimise

    static func optimize(_ item: FileItem, suffix: L10n?, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let doc = try PdfDoc.open(item.url)
        let settings = PdfOptimizeSettings(options: ctx.options)
        let original = fileSize(item.url)
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: "pdf") { tmp in
            try await PdfOptimizer.optimize(source: item.url, doc: doc, settings: settings, to: tmp, ctx: ctx, progress: progress)
            if PdfOptimizer.shouldKeepOriginal(settings: settings, originalBytes: original, resultBytes: fileSize(tmp)) {
                ctx.log("The optimised file is not smaller (\(fileSize(tmp)) >= \(original) bytes); keeping a copy of the original.")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: item.url, to: tmp)
            }
        }
        progress.report(1)
        return [url]
    }

    // MARK: Protect, unlock

    static func protect(_ item: FileItem, suffix: L10n?, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let doc = try PdfDoc.open(item.url)
        if o.bool(PdfKeys.stripMeta) { PdfDoc.stripMetadata(doc) }
        let open = o.string(PdfKeys.openPassword), owner = o.string(PdfKeys.ownerPassword)
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: "pdf") { tmp in
            try PdfProtection.protect(doc, openPassword: open, ownerPassword: owner, allowPrint: o.bool(PdfKeys.allowPrint, true),
                                      allowCopy: o.bool(PdfKeys.allowCopy, true), allowEdit: o.bool(PdfKeys.allowEdit, true), to: tmp)
        }
        progress.report(1)
        return [url]
    }

    static func unlock(_ item: FileItem, suffix: L10n?, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let password = o.string(PdfKeys.openPassword)
        let strip = o.bool(PdfKeys.stripMeta)
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: "pdf") { tmp in
            try PdfProtection.unlock(source: item.url, password: password, stripMeta: strip, to: tmp)
        }
        progress.report(1)
        return [url]
    }
}
