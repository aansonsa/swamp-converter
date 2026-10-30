import Foundation

enum ScrubCatalog {
    @MainActor
    static func operations() -> [Operation] {
        let kinds: [(String, OperationFamily, Set<String>, [Tool])] = [
            (ScrubSchemas.imageID, .image, Formats.imageAndRawInputs, []), (ScrubSchemas.videoID, .video, Formats.videoInputs, []),
            (ScrubSchemas.audioID, .audio, Formats.audioInputs, []), (ScrubSchemas.pdfID, .pdf, Formats.pdfInputs, [])
        ]
        return kinds.map { id, family, inputs, tools in
            ScrubOperation(meta: .make(id, .tools, family, L10n("Share-safe", "Безопасно"), sub: L10n("no location, no camera", "без геопозиции и камеры"), symbol: "hand.raised",
                                       schema: id, inputs: inputs, requires: tools, suffix: L10n("clean", "чисто"),
                                       passthrough: id == ScrubSchemas.pdfID ? .identity : .none))   // a PDF with nothing to remove is copied as it is
        }
    }
}

/// `scrub.image|video|audio|pdf`: a scrubbed copy `{name} (clean).ext` and a job note listing what was removed (`ScrubReport.summary`).
/// Video and audio need no tool: ffmpeg gives the finest control, AVFoundation does the common cases without it (see `MediaScrub`, `AVScrub`).
final class ScrubOperation: PerFileOperation, @unchecked Sendable {
    /// Reports of the running jobs, merged into the note when the job ends.
    private let reports = Locked<[UUID: [ScrubReport]]>([:])

    override func optionSchema(for items: [FileItem]) -> OptionSchema { ScrubSchemas.schema(id: meta.schemaID) }

    override func quickOverrides(settings: SettingsData) -> OptionValues {
        [ScrubKeys.removeGPS: true, ScrubKeys.removeCamera: true, ScrubKeys.removeDates: false, ScrubKeys.removeAuthor: false, ScrubKeys.removeAll: false]
    }

    /// "Always strip metadata" layers these over quick and automatic runs of OTHER operations; for this one they are simply its own recipe.
    override func privacyOverrides() -> OptionValues { [ScrubKeys.removeGPS: true, ScrubKeys.removeCamera: true] }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        if options.bool(ScrubKeys.removeAll) { return [L("All metadata", "Все метаданные")] }
        var chips: [String] = []
        if meta.schemaID != ScrubSchemas.pdfID, options.bool(ScrubKeys.removeGPS) { chips.append(L("Location", "Геопозиция")) }
        if options.bool(ScrubKeys.removeCamera) { chips.append(meta.schemaID == ScrubSchemas.pdfID ? L("Program", "Программа") : L("Camera", "Камера")) }
        if options.bool(ScrubKeys.removeDates) { chips.append(L("Dates", "Даты")) }
        if options.bool(ScrubKeys.removeAuthor) { chips.append(L("Author", "Автор")) }
        return chips
    }

    /// A copy is about as large as the original (pixels and streams are copied, only tags go).
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return total > 0 ? OperationEstimate(bytes: total, seconds: nil, confidence: .rough) : nil
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        defer { _ = reports.withLock { $0.removeValue(forKey: ctx.jobID) } }
        var result = try await super.execute(items: items, ctx: ctx)
        let merged = ScrubReport.merged(reports.withLock { $0[ctx.jobID] ?? [] })
        result.note = merged.summary
        return result
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let keepProfile = ctx.options.bool(ScrubKeys.keepColorProfile, true) || !ctx.isActive(ScrubKeys.keepColorProfile)
        let ext = MetadataScrubber.outputExtension(for: item)
        let holder = Locked<ScrubReport?>(nil)
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: ext) { out in
            holder.withLock { $0 = nil }
            let report = try await MetadataScrubber.scrub(input: item, output: out, keepColorProfile: keepProfile, ctx: ctx, progress: progress)
            holder.withLock { $0 = report }
        }
        if let r = holder.value {
            reports.withLock { $0[ctx.jobID, default: []].append(r) }
            ctx.log("scrub \(item.name): \(r.summary.en) [\(r.kept.joined(separator: ","))]")
        }
        progress.report(1)
        return [url]
    }
}
