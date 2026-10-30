import Foundation

enum SmartCatalog {
    static let inputs = Formats.videoInputs

    @MainActor
    static func operations() -> [Operation] {
        func op(_ id: String, _ mode: SmartMode, label: L10n) -> Operation {
            SmartOperation(mode: mode, meta: .make(id, .convert, .video, label, sub: mode.subtitle, symbol: mode.symbol, schema: SmartSchemas.transcodeID,
                                                    inputs: inputs, requires: [.ffmpeg], suffix: mode.title, concurrency: .video,
                                                    passthrough: .conditional))   // an already suitable file is remuxed, the rest is transcoded
        }
        // "Best for Apple" is the one-gesture default for any video; the other two are one sector each.
        return [op("smart.best", .bestForApple, label: L10n("Best for Apple", "Лучшее для Apple")),
                op("smart.max", .maximum, label: L10n("Max quality", "Макс. качество")),
                op("smart.universal", .universal, label: L10n("Universal", "Для всех"))]
    }
}

/// One class, three registrations. Behaviour = f(items, ctx.options): `smart.mode` decides, never the operation id.
final class SmartOperation: PerFileOperation, @unchecked Sendable {
    let mode: SmartMode
    /// Warnings collected by `process` per job, handed to the result card by `execute`.
    private let pendingWarnings = Locked<[UUID: [String]]>([:])

    init(mode: SmartMode, meta: OperationMeta) { self.mode = mode; super.init(meta: meta) }

    override func quickOverrides(settings: SettingsData) -> OptionValues { [SmartKeys.mode: .string(mode.rawValue)] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { SmartSchemas.transcode(items: items) }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let opts = SmartOptions(options: ctx.options)
        let result = try await SmartTranscoder.transcodeDetailed(input: item, options: opts, ctx: ctx, progress: progress)
        if !result.warnings.isEmpty {
            pendingWarnings.withLock { $0[ctx.jobID, default: []] += result.warnings.map { "\(item.name): \($0)" } }
        }
        return [result.url]
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        defer { pendingWarnings.withLock { $0[ctx.jobID] = nil } }
        var result = try await super.execute(items: items, ctx: ctx)
        result.warnings += pendingWarnings.value[ctx.jobID] ?? []
        return result
    }

    // MARK: Studio helpers

    /// Plan for the current options and source (nil when the source facts are not known yet). Cheap: no I/O.
    private func plan(options: OptionValues, source: SourceInfo?) -> TranscodePlan? {
        guard let source, let info = SmartSourceAdapter.mediaInfo(from: source) else { return nil }
        let opts = SmartOptions(options: options)
        return TranscodePlanner.plan(probe: info, mode: opts.mode, capabilities: .current, options: opts)
    }

    /// Plan chips for the Studio summary ("HEVC 10-bit", "Remux", "AAC 256", "hvc1").
    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        if let p = plan(options: options, source: source) { return p.chips }
        let o = SmartOptions(options: options)
        switch o.mode {
        case .bestForApple: return ["HEVC", "hvc1", "AAC \(o.audioBitrateKbps)", "MP4"]
        case .maximum: return ["Remux"]
        case .universal: return ["H.264", "AAC \(o.audioBitrateKbps)", "MP4"]
        }
    }

    /// Size estimate from the plan (copy = source size; HEVC = source bitrate x quality factor), confidence `.rough`.
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        guard let source, let info = SmartSourceAdapter.mediaInfo(from: source) else { return nil }
        let opts = SmartOptions(options: options)
        let p = TranscodePlanner.plan(probe: info, mode: opts.mode, capabilities: .current, options: opts)
        return SmartEstimate.estimate(plan: p, source: info, options: opts)
    }

    /// The plan's warnings and problems as live messages in the Studio.
    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        guard let p = plan(options: options, source: source) else { return [] }
        var out: [OptionMessage] = []
        for (i, m) in p.problems.enumerated() { out.append(OptionMessage(id: "smart.problem.\(i)", severity: .error, text: m)) }
        for (i, m) in p.warnings.enumerated() { out.append(OptionMessage(id: "smart.warning.\(i)", severity: .warning, text: m)) }
        return out
    }

    /// Privacy: `smart.strip` when "always strip metadata" is on.
    override func privacyOverrides() -> OptionValues { [SmartKeys.stripMetadata: true] }
}

/// Cheap estimate from the plan and the source probe: no encoding, no I/O.
enum SmartEstimate {
    static func estimate(plan: TranscodePlan, source: MediaInfo, options: SmartOptions) -> OperationEstimate? {
        guard let duration = source.duration, duration > 0 else { return nil }
        let audioSrc = source.audioStreams
        func audioBitrate(_ s: MediaStreamInfo) -> Double { Double(s.bitRate ?? 160_000) }
        var audioBits = 0.0
        for (i, action) in plan.audio.enumerated() {
            let s = audioSrc.first { $0.index == plan.audioStreamIndexes[i] }
            switch action {
            case .copy: audioBits += s.map(audioBitrate) ?? 160_000
            case .aac(let k): audioBits += Double(k) * 1000
            case .alac: audioBits += 900_000
            }
        }
        let totalBits: Double? = source.bitRate.map(Double.init) ?? source.size.map { Double($0) * 8 / duration }
        let sourceAudioBits = audioSrc.reduce(0.0) { $0 + audioBitrate($1) }
        let sourceVideoBits = max(0, (totalBits ?? 0) - sourceAudioBits)
        var videoBits: Double
        switch plan.video {
        case .copy: videoBits = sourceVideoBits
        case .hevc, .h264:
            let codec = SmartCodec.video(source.videoStreams.first?.codec)
            let toH264 = plan.encoderName?.contains("264") == true
            var factor = SmartQuality.sizeFactor(sourceCodec: codec)
            if toH264 { factor *= 1.35 }
            factor *= pow(1.08, Double(options.qualityOffset))
            // Scaling down shrinks the file with the pixel count.
            if let tw = plan.targetWidth, let th = plan.targetHeight, let v = source.videoStreams.first, let w = v.width, let h = v.height, w * h > 0 {
                factor *= min(1, Double(tw * th) / Double(w * h))
            }
            videoBits = sourceVideoBits * factor
        }
        let bytes = Int64((videoBits + audioBits) * duration / 8 * 1.01)
        let speed: Double
        switch plan.video {
        case .copy: speed = 200
        case .hevc(let e, _): speed = e == "libx265" ? 0.8 : 5
        case .h264(let e): speed = e == "libx264" ? 3 : 8
        }
        return OperationEstimate(bytes: bytes > 0 ? bytes : nil, seconds: duration / speed, confidence: .rough,
                                 note: L10n("Rough estimate from the source bitrate.", "Приблизительная оценка по битрейту источника."))
    }
}

enum SmartPresets {
    /// "Best for Apple", "Best for Apple - maximum quality (slow)", "Maximum quality", "Universal 1080p", "Lossless audio".
    static let builtins: [Preset] = [
        .builtin("smart.best", target: SmartSchemas.transcodeID, L10n("Best for Apple", "Лучшее для Apple"),
                 notes: L10n("Copies what already plays on Apple devices, otherwise HEVC with the original size and HDR.", "Копирует то, что уже играет на устройствах Apple, иначе HEVC с исходным размером и HDR."),
                 symbol: "apple.logo", group: .devices, operation: "smart.best", [SmartKeys.mode: "best"]),
        .builtin("smart.best.slow", target: SmartSchemas.transcodeID, L10n("Best for Apple, maximum quality (slow)", "Лучшее для Apple, максимальное качество (медленно)"),
                 notes: L10n("Uses the software encoder libx265.", "Использует программный кодировщик libx265."),
                 symbol: "tortoise", group: .archive, operation: "smart.best", [SmartKeys.mode: "best", SmartKeys.slowMaxQuality: true]),
        .builtin("smart.best.lossless-audio", target: SmartSchemas.transcodeID, L10n("Best for Apple, lossless audio", "Лучшее для Apple, звук без потерь"),
                 notes: L10n("Audio that must change becomes ALAC.", "Звук, который приходится менять, сохраняется в ALAC."),
                 symbol: "waveform", group: .lossless, operation: "smart.best", [SmartKeys.mode: "best", SmartKeys.losslessAudio: true]),
        .builtin("smart.max", target: SmartSchemas.transcodeID, L10n("Maximum quality, keep source", "Максимальное качество, как в источнике"),
                 notes: L10n("No re-encoding at all.", "Без какого-либо перекодирования."),
                 symbol: "sparkles", group: .lossless, operation: "smart.max", [SmartKeys.mode: "max"]),
        .builtin("smart.universal", target: SmartSchemas.transcodeID, L10n("Universal 1080p", "Универсальный 1080p"),
                 notes: L10n("H.264 and AAC in MP4: plays on anything.", "H.264 и AAC в MP4: играет на чём угодно."),
                 symbol: "globe", group: .web, operation: "smart.universal", [SmartKeys.mode: "universal"])
    ]
}
