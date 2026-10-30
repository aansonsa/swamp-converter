import Foundation

/// All per-file audio operations. Behaviour = f(items, ctx.options); operations differ by `quick` and meta only.
final class AudioOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues

    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) {
        self.quick = quick
        super.init(meta: meta)
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { AudioSchemas.convert(items: items) }

    /// MP3 needs ffmpeg (libmp3lame) OR lame; OGG / Opus / AC-3 need the matching ffmpeg encoder. Everything else works with macOS alone.
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        let env = AudEnvironment.current(tools: tools)
        guard let t = AudTarget(rawValue: quick(SettingsData()).string(AudioKeys.target)), t.isConcrete, let reason = env.unavailableReason(for: t) else { return .available }
        return .unavailable(reason: reason, missing: [.ffmpeg])
    }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        var out: [OptionMessage] = []
        let start = max(0, options[AudioKeys.trimStart]?.asDouble ?? 0)
        if let end = options[AudioKeys.trimEnd]?.asDouble, end <= start {
            out.append(OptionMessage(id: "aud.trim.order", severity: .error, text: L10n("The end must come after the start.", "Конец должен быть позже начала."), fieldKey: AudioKeys.trimEnd))
        }
        if let d = source?.duration, start >= d {
            out.append(OptionMessage(id: "aud.trim.start", severity: .error, text: L10n("The start is after the end of the file.", "Начало находится после конца файла."), fieldKey: AudioKeys.trimStart))
        }
        if options.double(AudioKeys.fitMB, 0) > 0, let d = source?.duration, d > 0 {
            let kbps = AudFit.kbps(durationSeconds: d, targetBytes: Int64(options.double(AudioKeys.fitMB) * 1_000_000), overheadBytes: 4_000)
            if kbps < 24 {
                out.append(OptionMessage(id: "aud.fit.small", severity: .warning,
                                         text: L10n("About \(kbps) kbit/s would be needed; the sound will be poor. Choose a larger size.", "Понадобится около \(kbps) кбит/с, звук будет плохим. Выберите размер побольше."),
                                         fieldKey: AudioKeys.fitMB))
            }
        }
        return out
    }

    /// Cheap: bit rate x duration for lossy targets, PCM size for WAV / AIFF / CAF, about 60 percent of PCM for FLAC / ALAC.
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        guard let source, source.duration != nil else { return nil }
        let info = AudInfo(source: source)
        guard let plan = try? AudPlanner.make(values: options, info: info, inputKey: Formats.key(of: source.url), env: AudEnvironment.current()) else { return nil }
        return AudEstimate.estimate(plan: plan, info: info)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        let info = source.map { AudInfo(source: $0) }
        guard let plan = try? AudPlanner.make(values: options, info: info, inputKey: source.map { Formats.key(of: $0.url) } ?? "", env: AudEnvironment.current()) else { return [] }
        return AudEstimate.chips(plan: plan, info: info)
    }

    override func privacyOverrides() -> OptionValues { [AudioKeys.tagsMode: "strip", AudioKeys.coverMode: "remove"] }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        // The option resolver quietly swaps a format this Mac cannot write for the schema's default (AAC). On the wheel and in automation that would turn a
        // "MP3" sector into an M4A file, so an unwritable quick target is refused instead.
        if ctx.mode != .studio, let wanted = AudTarget(rawValue: quick(ctx.settings).string(AudioKeys.target)), wanted.isConcrete,
           let reason = AudEnvironment.current(tools: ctx.tools).unavailableReason(for: wanted) {
            throw ConversionError.unsupported(reason)
        }
        let prepared = try await AudioTranscoder.prepare(input: item.url, options: ctx.options, ctx: ctx)
        var outputs: [URL] = []
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: prepared.fileExtension) { part in
            try await AudioTranscoder.run(prepared, output: part, ctx: ctx, progress: progress)
        }
        outputs.append(url)
        if prepared.plan.coverMode == .extract, prepared.info?.hasCover == true,
           let data = await AudCover.extract(from: item.url, ctx: ctx), let jpeg = AudCover.prepared(data, maxPixel: 0) {
            let cover = try await ctx.produceFile(for: item, suffix: L10n("cover", "обложка"), ext: "jpg") { part in try jpeg.write(to: part) }
            outputs.append(cover)
        }
        return outputs
    }
}

/// `audio.concat`: natural path order, output named after the first SORTED item.
final class AudioJoinOperation: BatchOperation, @unchecked Sendable {
    override func optionSchema(for items: [FileItem]) -> OptionSchema { AudioSchemas.join(items: items) }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability { .available }

    override func privacyOverrides() -> OptionValues { [AudioKeys.tagsMode: "strip", AudioKeys.coverMode: "remove"] }

    override func process(_ items: [FileItem], ctx: OperationContext) async throws -> [URL] {
        let env = AudEnvironment.current(tools: ctx.tools)
        let natural = ctx.options.string(AudioKeys.joinOrder, "natural") != "selection"
        let sortedFirst = AudJoin.ordered(items, natural: true)[0]
        let ordered = AudJoin.ordered(items, natural: natural)
        var sources: [AudJoinSource] = []
        for item in ordered {
            try ctx.checkCancelled()
            guard let info = await AudProbe.read(item.url, tools: ctx.tools) else { throw ConversionError.fileUnreadable(item.url) }
            guard info.hasAudio else { throw ConversionError.fileFailed(name: item.name, message: ConversionError.noAudioTrack.errorDescription ?? "") }
            sources.append(AudJoinSource(item: item, info: info))
        }
        let infos = sources.map(\.info)
        // The format: explicit, or the first file's in the join order.
        var values = ctx.options
        let wanted = AudTarget(rawValue: values.string(AudioKeys.target, "same")) ?? .same
        let firstKey = Formats.key(of: ordered[0].url)
        let target: AudTarget
        if wanted.isConcrete { target = wanted }
        else { target = AudSmart.same(inputKey: firstKey, info: infos[0], env: env).target }
        values[AudioKeys.target] = .string(target.rawValue)
        let rate = AudJoin.outputRate(choice: values.string(AudioKeys.joinRate, "auto"), infos: infos, target: target)
        let channels = min(AudJoin.outputChannels(choice: values.string(AudioKeys.joinChannels, "auto"), infos: infos), target.maxChannels)
        values[AudioKeys.channels] = .string(channels == 1 ? "mono" : "stereo")
        values[AudioKeys.sampleRate] = .string(String(rate))
        // Joining never trims, fades or normalises: those are options of the convert schema only.
        var plan = try AudPlanner.make(values: values, info: infos[0], inputKey: firstKey, env: env)
        guard env.canEncode(plan.target) else { throw ConversionError.unsupported(env.unavailableReason(for: plan.target) ?? L10n("This format is not available.", "Этот формат недоступен.")) }
        plan.passthrough = false
        plan.fileExtension = plan.target.fileExtension
        let gap = ctx.isActive(AudioKeys.joinGap) ? ctx.options.double(AudioKeys.joinGap, 0) : 0
        let crossfade = ctx.options.double(AudioKeys.joinCrossfade, 0)
        for note in plan.notes { ctx.log(note.en) }
        let report = AudProgress { ctx.report($0) }
        let url = try await ctx.produceFile(for: sortedFirst, suffix: meta.suffix, ext: plan.fileExtension) { part in
            try await AudJoin.run(sources: sources, plan: plan, rate: rate, channels: channels, gap: gap, crossfade: crossfade, output: part, env: env, ctx: ctx, progress: report)
        }
        return [url]
    }
}

enum AudEstimate {
    static func estimate(plan: AudPlan, info: AudInfo?) -> OperationEstimate? {
        guard let duration = plan.outputDuration(sourceDuration: info?.duration), duration > 0 else { return nil }
        if plan.passthrough, let s = info?.size { return OperationEstimate(bytes: s, seconds: nil, confidence: .measured, note: L10n("The file is kept as it is.", "Файл остаётся как есть.")) }
        let channels = Double(plan.channels ?? info?.channels ?? 2)
        let rate = Double(plan.sampleRate ?? info?.sampleRate ?? 44_100)
        var bytes: Double
        switch plan.target {
        case .wav, .aiff, .caf:
            bytes = duration * rate * channels * Double(AudFFmpegArgs.resolvedDepth(plan.bitDepth, info)) / 8 + 100
        case .flac, .alac:
            bytes = duration * rate * channels * Double(AudFFmpegArgs.resolvedDepth(plan.bitDepth, info)) / 8 * 0.62
        default:
            let kbps = plan.useQuality ? AudQuality.approxKbps(target: plan.target, quality: plan.quality) : plan.kbps
            bytes = Double(kbps) * 1000 / 8 * duration + Double(AudFit.overheadBytes(target: plan.target, coverBytes: info?.hasCover == true && plan.coverMode != .remove ? 60_000 : 0))
        }
        return OperationEstimate(bytes: Int64(bytes), seconds: nil, confidence: plan.useQuality || plan.target.isLossless ? .rough : .measured)
    }

    static func chips(plan: AudPlan, info: AudInfo?) -> [String] {
        var c: [String] = [plan.passthrough ? L("Kept as is", "Без изменений") : plan.target.title.text]
        if plan.target.isLossy && !plan.passthrough { c.append(plan.useQuality ? L("VBR \(plan.quality)", "VBR \(plan.quality)") : "\(plan.kbps) kbit/s") }
        if let r = plan.sampleRate ?? info?.sampleRate { c.append(AudRates.label(r)) }
        if let ch = plan.channels ?? info?.channels { c.append(AudioSourceProbe.channelsText(ch)) }
        if let n = plan.norm { c.append(n.kind == .peak ? L("Peak", "Пик") : "\(String(format: "%.0f", n.level)) LUFS") }
        if let mb = plan.fitBytes { c.append("≤ \(String(format: "%g", Double(mb) / 1_000_000)) MB") }
        return c
    }
}
