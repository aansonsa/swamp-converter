import Foundation
import PDFKit
import AppKit

/// `tools.ocr`: images and PDFs -> one `{base} (text).txt` per input (or a searchable PDF / Markdown / JSON per the schema). The text of every input is also
/// put on the clipboard (note "The text is also on the clipboard."). Offered unless this Mac is known to have no recogniser.
final class PdfOCROperation: PerFileOperation, @unchecked Sendable {
    /// Where "also copy the text" puts it. The system pasteboard; the self-tests swap in a private one so they never touch the person's clipboard.
    nonisolated(unsafe) static var pasteboard: @Sendable () -> NSPasteboard = { NSPasteboard.general }

    /// Text collected while one run goes through its inputs.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        func add(_ s: String) { guard !s.isEmpty else { return }; lock.lock(); parts.append(s); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined(separator: "\n\n") }
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { [PdfKeys.ocrOutput: "txt", PdfKeys.ocrClipboard: true] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { PdfSchemas.ocr(items: items) }
    override func privacyOverrides() -> OptionValues { [PdfKeys.stripMeta: true] }

    override func appliesTo(_ items: [FileItem]) -> Bool { OcrService.knownAvailability != false && super.appliesTo(items) }
    override func appliesInStudio(_ items: [FileItem]) -> Bool { OcrService.knownAvailability != false && super.appliesInStudio(items) }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        if OcrService.knownAvailability == false {
            return .unavailable(reason: L10n("Text recognition is not available on this Mac.", "Распознавание текста недоступно на этом Mac."), missing: [])
        }
        return super.availability(for: items, tools: tools)
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        try await run(item, ctx: ctx, progress: progress, sink: Sink())
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        let sink = Sink()
        var result = OperationResult()
        var failures: [String] = []
        for (i, item) in items.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            ctx.setCurrentItem(item, index: i, count: items.count)
            do {
                result.outputs += try await run(item, ctx: ctx, progress: ctx.slice(index: i, count: items.count), sink: sink)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if items.count == 1 { throw error }
                failures.append("\(item.name): \(ConversionError.describe(error))")
                ctx.log("FAILED \(item.name): \(ConversionError.describe(error))")
            }
        }
        ctx.report(1)
        if result.outputs.isEmpty && !failures.isEmpty { throw ConversionError.aggregate(failures) }
        result.failures = failures
        let text = sink.text
        if ctx.options.bool(PdfKeys.ocrClipboard, true), ctx.mode != .automatic, !text.isEmpty {
            await MainActor.run {
                let board = Self.pasteboard()
                board.clearContents()
                board.setString(text, forType: .string)
            }
            result.note = L10n("The text is also on the clipboard.", "Текст также скопирован в буфер обмена.")
        }
        return result
    }

    // MARK: One input

    private func run(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice, sink: Sink) async throws -> [URL] {
        let o = ctx.options
        let settings = PdfOcrSettings(options: o)
        let output = o.string(PdfKeys.ocrOutput, "searchablePdf")
        let textSuffix = L10n("text", "текст")
        if item.kind == .pdf {
            let doc = try PdfDoc.open(item.url)
            let indices = try PdfDoc.indices(o.string(PdfKeys.pages, "all"), pageCount: doc.pageCount)
            if output == "searchablePdf" {
                let strip = o.bool(PdfKeys.stripMeta)
                let url = try await ctx.produceFile(for: item, suffix: L10n("searchable", "с поиском"), ext: "pdf") { tmp in
                    try await PdfOcrPipeline.makeSearchable(source: item.url, doc: doc, to: tmp, indices: indices, settings: settings, stripMetadata: strip, ctx: ctx, progress: progress)
                }
                if let made = PDFDocument(url: url), let s = made.string { sink.add(PdfGeometry.normalise(s)) }
                return [url]
            }
            let pages = try await PdfOcrPipeline.pageTexts(doc: doc, indices: indices, settings: settings, ctx: ctx, progress: progress)
            return try await write(pages, as: output, item: item, suffix: textSuffix, ctx: ctx, sink: sink)
        }
        let (page, image, dpi) = try await PdfOcrPipeline.recognize(imageAt: item.url, settings: settings)
        if output == "searchablePdf" {
            let url = try await ctx.produceFile(for: item, suffix: L10n("searchable", "с поиском"), ext: "pdf") { tmp in
                try PdfOcrPipeline.makeSearchable(image: image, dpi: dpi, text: page.lines, to: tmp)
            }
            if !page.text.isEmpty { sink.add(page.text) }
            progress.report(1)
            return [url]
        }
        progress.report(0.9)
        return try await write([page], as: output, item: item, suffix: textSuffix, ctx: ctx, sink: sink)
    }

    private func write(_ pages: [OcrPageText], as format: String, item: FileItem, suffix: L10n, ctx: OperationContext, sink: Sink) async throws -> [URL] {
        let nonEmpty = pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { throw ConversionError.noText }
        sink.add(PdfMarkdown.plain(pages: nonEmpty.map { PdfPageText(number: $0.number, text: $0.text) }, separators: "auto", reflow: false))
        let body: String
        let ext: String
        switch format {
        case "md":
            ext = "md"
            body = nonEmpty.map { p in
                (p.recognised ? OcrLayout.paragraphs(OcrLayout.rows(p.lines)) : PdfMarkdown.paragraphs(from: p.text)).joined(separator: "\n\n")
            }.joined(separator: "\n\n---\n\n")
        case "json":
            ext = "json"
            body = Self.json(nonEmpty)
        default:
            ext = "txt"
            body = PdfMarkdown.plain(pages: nonEmpty.map { PdfPageText(number: $0.number, text: $0.text) }, separators: "auto", reflow: false)
        }
        let data = Data(body.utf8)
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: ext) { tmp in try data.write(to: tmp) }
        return [url]
    }

    /// `{"pages": [{"page": 1, "recognised": true, "confidence": 0.98, "lines": [{"text": "...", "confidence": 1, "box": {"x":..,"y":..,"width":..,"height":..}}]}]}`.
    /// Boxes are fractions of the page, origin bottom-left.
    static func json(_ pages: [OcrPageText]) -> String {
        let list: [[String: Any]] = pages.map { p in
            let lines: [[String: Any]] = p.recognised
                ? p.lines.map { ["text": $0.text, "confidence": $0.confidence, "box": ["x": $0.box.minX, "y": $0.box.minY, "width": $0.box.width, "height": $0.box.height]] }
                : p.rows.map { ["text": $0] }
            return ["page": p.number, "recognised": p.recognised, "confidence": p.confidence, "lines": lines]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["pages": list], options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
