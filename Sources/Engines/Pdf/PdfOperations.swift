import Foundation
import PDFKit

/// Per-file PDF operations (convert to images/text/documents, split, rotate, extract, optimise, protect, unlock). Behaviour = f(items, ctx.options).
/// Several operations share a schema (and so a job); they differ only by their quick recipe, label and wheel slot.
final class PdfOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues
    /// Offered on the wheel only when every file is password protected (the Studio target is always there).
    private let wheelNeedsEncrypted: Bool

    init(_ meta: OperationMeta, wheelNeedsEncrypted: Bool = false, quick: @escaping @Sendable (SettingsData) -> OptionValues) {
        self.quick = quick
        self.wheelNeedsEncrypted = wheelNeedsEncrypted
        super.init(meta: meta)
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { PdfSchemas.schema(id: meta.schemaID, items: items) }

    override func appliesTo(_ items: [FileItem]) -> Bool {
        guard super.appliesTo(items) else { return false }
        return !wheelNeedsEncrypted || items.allSatisfy { PdfDoc.isEncrypted($0.url) }
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let suffix = meta.suffix
        switch meta.schemaID {
        case PdfTargets.images: return try await PdfJobs.images(item, ctx: ctx, progress: progress)
        case PdfTargets.text: return try await PdfJobs.text(item, ctx: ctx, progress: progress)
        case PdfTargets.export: return try await PdfJobs.export(item, ctx: ctx, progress: progress)
        case PdfTargets.split: return try await PdfJobs.split(item, ctx: ctx, progress: progress)
        case PdfTargets.pages: return try await PdfJobs.pages(item, suffix: suffix, ctx: ctx, progress: progress)
        case PdfTargets.extract: return try await PdfJobs.extract(item, suffix: suffix, ctx: ctx, progress: progress)
        case PdfTargets.optimize: return try await PdfJobs.optimize(item, suffix: suffix, ctx: ctx, progress: progress)
        case PdfTargets.protect: return try await PdfJobs.protect(item, suffix: suffix, ctx: ctx, progress: progress)
        case PdfTargets.unlock: return try await PdfJobs.unlock(item, suffix: suffix, ctx: ctx, progress: progress)
        default:
            throw ConversionError.unsupported(L10n("This operation is not available.", "Эта операция недоступна."))
        }
    }

    /// Operations that write a PDF carry the "always strip metadata" setting into quick and automatic runs.
    override func privacyOverrides() -> OptionValues {
        PdfOperation.writesPDF.contains(meta.schemaID) ? [PdfKeys.stripMeta: true] : OptionValues()
    }

    static let writesPDF: Set<String> = [PdfTargets.merge, PdfTargets.split, PdfTargets.pages, PdfTargets.optimize, PdfTargets.protect, PdfTargets.unlock,
                                         PdfTargets.extract, PdfTargets.ocr]

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        PdfStudio.validate(schemaID: meta.schemaID, options: options, source: source)
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        PdfStudio.estimate(schemaID: meta.schemaID, options: options, items: items, source: source)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        PdfStudio.chips(schemaID: meta.schemaID, options: options, source: source)
    }

    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        try await PdfStudio.preview(schemaID: meta.schemaID, items: items, options: options, maxPixel: maxPixel)
    }
}

/// `pdf.merge`: pages appended in the chosen order (natural path order by default); output dir and name from the first SORTED file: `{first sorted} (merged)`.
final class PdfMergeOperation: BatchOperation, @unchecked Sendable {
    override func optionSchema(for items: [FileItem]) -> OptionSchema { PdfSchemas.merge(items: items) }
    override func privacyOverrides() -> OptionValues { [PdfKeys.stripMeta: true] }

    override func process(_ items: [FileItem], ctx: OperationContext) async throws -> [URL] {
        let o = ctx.options
        let ordered = PdfPageOps.mergeOrder(items, mode: o.string(PdfKeys.mergeOrder, "name"))
        guard let first = ordered.first else { throw ConversionError.noOutput }
        let url = try await ctx.produceFile(for: first, suffix: meta.suffix, ext: "pdf") { tmp in
            try await PdfPageOps.merge(ordered, bookmarks: o.bool(PdfKeys.mergeBookmarks, true), normalize: o.bool(PdfKeys.mergeNormalize),
                                       stripMeta: o.bool(PdfKeys.stripMeta), to: tmp, ctx: ctx)
        }
        return [url]
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        OperationEstimate(bytes: items.compactMap(\.size).reduce(0, +), seconds: Double(items.count) * 0.1, confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        PdfStudio.chips(schemaID: PdfTargets.merge, options: options, source: source)
    }
}
