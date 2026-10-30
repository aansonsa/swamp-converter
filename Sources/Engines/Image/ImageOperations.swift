import Foundation

/// One class for every per-file image operation (convert, compress, shrink, rotate ...): behaviour is a pure function of
/// (items, ctx.options); the operations differ only by `quick` (their quick recipe) and their meta.
final class ImageOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues
    /// True for tools whose quick recipe keeps the source format ("same"): a WebP source then needs cwebp to be written back.
    private let keepsSourceFormat: Bool

    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) {
        self.quick = quick
        self.keepsSourceFormat = quick(SettingsData())[ImageKeys.format]?.asString == "same"
        super.init(meta: meta)
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { ImageSchemas.convert(items: items) }
    override func privacyOverrides() -> OptionValues { [ImageKeys.mdMode: "strip"] }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        let base = super.availability(for: items, tools: tools)
        guard base.isAvailable else { return base }
        // HEIC / AVIF come from the system's ImageIO encoders: say so plainly when this Mac has none (never fake the format).
        if let t = meta.targetFormat, ["heic", "avif"].contains(t), !Capabilities.shared.has("native.imageio.write.\(t)") {
            return .unavailable(reason: L10n("This Mac cannot write \(t.uppercased()) pictures.", "Этот Mac не умеет записывать картинки \(t.uppercased())."), missing: [])
        }
        if keepsSourceFormat, items.contains(where: { $0.key == "webp" }), !tools.has(.cwebp) {
            return .unavailable(reason: Capabilities.reason(for: "tool.cwebp"), missing: [.cwebp])
        }
        return base
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        var result = try await super.execute(items: items, ctx: ctx)
        for item in items where !shouldSkip(item, ctx: ctx) {
            if let w = ImageIntegrity.warning(for: item.url) { result.warnings.append("\(item.name): \(w.text)") }
        }
        return result
    }

    /// Decodes, applies the options in the fixed order orient -> crop -> rotate / mirror -> resize -> colour -> metadata -> encode, and writes the result with `ctx.produceFile`.
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        try await ImageRunner.run(item, ctx: ctx, progress: progress, suffix: meta.suffix)
    }

    // MARK: Studio

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        ImageStudioSupport.estimate(options: options, items: items, source: source)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] { ImageStudioSupport.chips(options: options, source: source) }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] { ImageStudioSupport.validate(options: options, source: source) }

    /// Before / after of the first item at <= maxPixel using the current options (decoded at reduced size; the quality of lossy formats is visible).
    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        guard let item = items.first else { return nil }
        let resolved = optionSchema(for: items).resolve(layers: [options], source: source).values
        return try await Task.detached(priority: .userInitiated) { try ImageStudioSupport.preview(item: item, options: resolved, maxPixel: maxPixel) }.value
    }
}

/// `image.merge.pdf`: several images into one PDF, natural path order by default, named after the first page (the first SORTED item, not the first dropped one).
final class ImageMergePDFOperation: BatchOperation, @unchecked Sendable {
    override func quickOverrides(settings: SettingsData) -> OptionValues { [ImageKeys.quality: .int(settings.quality.jpegQuality)] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { ImageSchemas.mergePDF(items: items) }

    override func process(_ items: [FileItem], ctx: OperationContext) async throws -> [URL] {
        [try await ImageMergePDF.run(items, ctx: ctx)]
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        let q = Double(options.int(ImageKeys.quality, 90)) / 90
        return OperationEstimate(bytes: Int64(Double(total) * min(1.4, max(0.15, q * q))), seconds: Double(items.count) * 0.25, confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        ["PDF", options.string(ImageKeys.pdfPageSize, "image") == "image" ? L("Page = picture", "Страница = картинка") : options.string(ImageKeys.pdfPageSize).uppercased(),
         "Q\(options.int(ImageKeys.quality, 90))"]
    }
}
