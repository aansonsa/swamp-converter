import Foundation

enum FitCatalog {
    @MainActor
    static func operations() -> [Operation] {
        let kinds: [(FitKind, OperationFamily, Set<String>, [Tool], ConcurrencyClass)] = [
            (.video, .video, Formats.videoInputs, [.ffmpeg, .ffprobe], .video),
            (.audio, .audio, Formats.audioInputs, [], .light),
            (.image, .image, Formats.imageAndRawInputs, [], .light),
            (.pdf, .pdf, Formats.pdfInputs, [], .light)
        ]
        return kinds.map { kind, family, inputs, tools, concurrency in
            FitOperation(meta: .make(kind.schemaID, .tools, family, L10n("Fit to size", "До размера"), sub: L10n("for WhatsApp, e-mail …", "для WhatsApp, почты …"),
                                     symbol: "scalemass", schema: kind.schemaID, inputs: inputs, requires: tools, suffix: L10n("fit", "до размера"),
                                     concurrency: concurrency, prompts: [FitKeys.target],
                                     passthrough: .identity))   // a file already under the limit is copied unchanged
        }
    }
}

/// Notes the engines produce while a job runs ("Reduced to 720p to fit"), collected per job and shown on the finished card.
final class FitNoteBoard: @unchecked Sendable {
    static let shared = FitNoteBoard()
    private let notes = Locked<[UUID: [L10n]]>([:])

    func add(_ new: [L10n], job: UUID) {
        guard !new.isEmpty else { return }
        notes.withLock { $0[job, default: []] += new }
    }

    func take(job: UUID) -> [L10n] {
        notes.withLock { $0.removeValue(forKey: job) ?? [] }
    }

    /// One note from several (English and Russian joined separately, repeated sentences once).
    static func combine(_ list: [L10n]) -> L10n? {
        var seen = Set<L10n>()
        let unique = list.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        return L10n(unique.map(\.en).joined(separator: " "), unique.map(\.ru).joined(separator: " "))
    }
}

/// One class for the four kinds; the file kind of each item selects the engine (`VideoFit` / `AudioFit` / `ImageFit` / `PdfFit`).
final class FitOperation: PerFileOperation, @unchecked Sendable {
    override func quickOverrides(settings: SettingsData) -> OptionValues { [FitKeys.target: .string(FitSchemas.defaultTarget)] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { FitSchemas.schema(id: meta.schemaID) }

    /// Resolves `SizeTargetCatalog.bytes`, runs the engine of the item's kind, reports `FitResult.notes` through `ctx.log` and the job note
    /// ("Reduced to 720p to fit"). Engines fail with a calm message when the target is physically unreachable.
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        guard let kind = FitKind(fileKind: item.kind) else {
            throw ConversionError.unsupported(L10n("Fit to size does not work with this kind of file.", "«До размера» не работает с таким типом файлов."))
        }
        let options = ctx.options
        guard let bytes = SizeEstimator.targetBytes(options) else {
            throw ConversionError.invalidOption(key: FitKeys.customMB, reason: L10n("Enter a size greater than zero.", "Введите размер больше нуля."))
        }
        let result: FitResult
        switch kind {
        case .video: result = try await VideoFit.run(input: item, targetBytes: bytes, options: options, ctx: ctx, progress: progress)
        case .audio: result = try await AudioFit.run(input: item, targetBytes: bytes, options: options, ctx: ctx, progress: progress)
        case .image: result = try await ImageFit.run(input: item, targetBytes: bytes, options: options, ctx: ctx, progress: progress)
        case .pdf: result = try await PdfFit.run(input: item, targetBytes: bytes, options: options, ctx: ctx, progress: progress)
        }
        ctx.log("fit: \(result.output.lastPathComponent) \(result.achievedBytes) bytes of \(bytes) (\(String(format: "%.1f", result.slack * 100))% below)")
        result.notes.forEach { ctx.log($0.en) }
        FitNoteBoard.shared.add(result.notes, job: ctx.jobID)
        return [result.output]
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        defer { _ = FitNoteBoard.shared.take(job: ctx.jobID) }
        var result = try await super.execute(items: items, ctx: ctx)
        result.note = FitNoteBoard.combine(FitNoteBoard.shared.take(job: ctx.jobID))
        return result
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        SizeEstimator.estimate(kind: items.first?.kind ?? source?.kind ?? .other, options: options, source: source)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        guard let bytes = SizeEstimator.targetBytes(options) else { return [] }
        var chips = ["\u{2264} " + SizeTarget.formatMB(Double(bytes) / 1_000_000, russian: Loc.shared.language == .ru)]
        if let t = SizeTargetCatalog.target(id: options.string(FitKeys.target)), t.id != SizeTarget.customID { chips.insert(t.name.text, at: 0) }
        if meta.schemaID == FitKind.video.schemaID, options.bool(FitKeys.twoPass, true) { chips.append(L("2 passes", "2 прохода")) }
        return chips
    }

    /// A custom size must be positive; for video and audio the limit is checked against the clip length (calm warnings, not blocks).
    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        var out: [OptionMessage] = []
        guard let bytes = SizeEstimator.targetBytes(options) else {
            return [OptionMessage(id: "fit.size.invalid", severity: .error, text: L10n("Enter a size greater than zero.", "Введите размер больше нуля."), fieldKey: FitKeys.customMB)]
        }
        guard let source, let d = source.duration, d > 0 else { return out }
        switch FitKind(schemaID: meta.schemaID) {
        case .video?:
            if let w = source.int("video.width"), let h = source.int("video.height") {
                let plan = VideoFit.plan(durationSeconds: d, targetBytes: bytes, audioKbps: options.int(FitKeys.audioKbps, 96), sourceWidth: w, sourceHeight: h,
                                         sourceFPS: source.number("video.fps") ?? 30, hasAudio: (source.int("audio.count") ?? 1) > 0,
                                         allowDownscale: options.bool(FitKeys.allowDownscale, true), preferTwoPass: true)
                if plan.unreachable {
                    out.append(OptionMessage(id: "fit.video.unreachable", severity: .error, text: plan.notes.first ?? FitMessages.alreadySmall, fieldKey: FitKeys.target))
                } else if let note = plan.notes.first, plan.downscaled {
                    out.append(OptionMessage(id: "fit.video.downscale", severity: .info, text: note, fieldKey: FitKeys.allowDownscale))
                }
            }
        case .audio?:
            let codec = AudioFitCodec(name: options.string(FitKeys.audioCodec, "auto")).rawValue
            if !AudioFit.isReachable(durationSeconds: d, targetBytes: bytes, codec: codec) {
                out.append(OptionMessage(id: "fit.audio.unreachable", severity: .error,
                                         text: L10n("The recording is too long for this limit. Choose a larger size or trim it first.", "Запись слишком длинная для этого лимита. Выберите больший размер или сначала обрежьте её."),
                                         fieldKey: FitKeys.target))
            }
        default: break
        }
        return out
    }

    /// Metadata strip rides along when "always strip metadata" is on.
    override func privacyOverrides() -> OptionValues { [FitKeys.stripMetadata: true] }
}

enum FitPresets {
    /// One preset per size target and kind ("Video for WhatsApp", "Image under 1 MB", ...), generated from `SizeTargetCatalog` so the numbers live in one place.
    static let builtins: [Preset] = {
        var out: [Preset] = []
        for kind in FitKind.allCases {
            for target in SizeTargetCatalog.fixedTargets(for: kind.fileKind) {
let generic = target.id.hasPrefix("mb")
                let en = generic ? "\(kind.noun.en) \(lowerFirst(target.name.en))" : "\(kind.noun.en) for \(target.name.en)"
                let ru = generic ? "\(kind.noun.ru) \(lowerFirst(target.name.ru))" : "\(kind.noun.ru) для \(target.name.ru)"
                let group: PresetGroup = (target.id.hasPrefix("email") || generic) ? .smallSize : .social
                out.append(Preset.builtin("fit.\(kind.rawValue).\(target.id)", target: kind.schemaID, L10n(en, ru), notes: target.note, symbol: target.symbol,
                                          group: group, operation: kind.schemaID, [FitKeys.target: .string(target.id)]))
            }
        }
        return out
    }()

    private static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
}
