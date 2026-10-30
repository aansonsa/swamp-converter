import Foundation

// AudioTranscoder: the one door for "turn this audio (or the soundtrack of this video) into that". Used by the audio operations,
// by video.to.mp3, by transcription and by the privacy scrub.
//
//   prepare(...)  probes the input, builds the typed plan and picks the route; the caller then knows the output extension
//   run(...)      does the work into the hidden `.part` path handed out by ctx.produceFile
//   transcode(...) both in one go (the frozen signature other modules call)

enum AudRoute: Equatable, Sendable {
    /// Keep the file exactly as it is (an already compact file in "automatic" mode).
    case copy
    /// ffmpeg does everything (filters, encode, tags).
    case ffmpeg
    /// macOS frameworks do everything.
    case native
    /// Native signal work, `lame` encodes the MP3.
    case hybridLame
    /// Signal work (native, or ffmpeg filters), then `sox` encodes the Ogg Vorbis file.
    case hybridSox
}

struct AudPrepared: Sendable {
    var input: URL
    var inputKey: String
    var info: AudInfo?
    var plan: AudPlan
    var route: AudRoute
    var env: AudEnvironment
    var fileExtension: String { plan.fileExtension }
}

enum AudRouter {
    /// Pure routing: native first when the target is native and nothing needs ffmpeg.
    static func choose(plan: AudPlan, info: AudInfo?, env: AudEnvironment) throws -> AudRoute {
        if plan.passthrough { return .copy }
        let t = plan.target
        func needFFmpeg() throws -> AudRoute {
            guard env.hasFFmpeg else { throw ConversionError.toolMissing(.ffmpeg) }
            return .ffmpeg
        }
        switch t {
        case .mp3:
            // ffmpeg's Info frame of a MONO MP3 carries no gapless data that Apple's decoders read (the file plays with 25 to 65 ms of extra silence);
            // lame's does. So mono goes to lame whenever it can do the whole job.
            let mono = (plan.channels ?? info?.channels ?? 2) == 1
            if mono, env.hasLame, !plan.needsFFmpegFeature { return .hybridLame }
            if env.has(encoder: "libmp3lame") { return .ffmpeg }
            if env.hasLame { return .hybridLame }
            throw ConversionError.unsupported(env.unavailableReason(for: .mp3) ?? L10n("MP3 needs ffmpeg or lame.", "Для MP3 нужен ffmpeg или lame."))
        case .ogg:
            if env.hasVorbis { return try needFFmpeg() }
            if env.hasSoxVorbis { return .hybridSox }
            throw ConversionError.unsupported(env.unavailableReason(for: .ogg) ?? L10n("Ogg Vorbis is not available.", "Ogg Vorbis недоступен."))
        case .opus, .ac3, .eac3:
            if let reason = env.unavailableReason(for: t) { throw ConversionError.unsupported(reason) }
            return try needFFmpeg()
        case .auto, .same:
            throw ConversionError.message(L10n("The output format could not be decided.", "Не удалось определить формат результата."))
        default:
            break
        }
        // Native target. HE-AAC exists only in the system encoder.
        if plan.aacProfile != .lc { return .native }
        let tagsNeedFFmpeg = (t == .flac || t == .wav) && plan.tagsMode != .strip
            && ((plan.tagsMode == .custom && !plan.tagEdits.isEmpty) || (plan.tagsMode == .keep && !(info?.tags.isEmpty ?? true)))
        let coverNeedsFFmpeg = t == .flac && (plan.coverMode == .replace || (plan.coverMode == .keep && info?.hasCover == true))
        if (plan.needsFFmpegFeature || tagsNeedFFmpeg || coverNeedsFFmpeg) && env.hasFFmpeg { return .ffmpeg }
        return .native
    }
}

enum AudioTranscoder {
    /// Probes, plans and routes. Throws `noAudioTrack` for inputs without sound.
    static func prepare(input: URL, options: OptionValues, ctx: OperationContext, outputExtension: String? = nil) async throws -> AudPrepared {
        let env = AudEnvironment.current(tools: ctx.tools)
        let info = await AudProbe.read(input, tools: ctx.tools)
        if let info, !info.hasAudio { throw ConversionError.noAudioTrack }
        if info == nil && !FileManager.default.isReadableFile(atPath: input.path) { throw ConversionError.fileUnreadable(input) }
        let key = Formats.key(of: input)
        let plan = try AudPlanner.make(values: options, info: info, inputKey: key, outputExtension: outputExtension, env: env)
        let route = try AudRouter.choose(plan: plan, info: info, env: env)
        return AudPrepared(input: input, inputKey: key, info: info, plan: plan, route: route, env: env)
    }

    /// The frozen entry point: `output` is the hidden `.part` path from `ctx.produceFile` (its extension is the container).
    static func transcode(input: URL, output: URL, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws {
        let prepared = try await prepare(input: input, options: options, ctx: ctx, outputExtension: output.pathExtension)
        try await run(prepared, output: output, ctx: ctx, progress: progress)
    }

    static func run(_ p: AudPrepared, output: URL, ctx: OperationContext, progress slice: ProgressSlice) async throws {
        let progress = AudProgress(slice).monotonic()
        for note in p.plan.notes { ctx.log(note.en) }
        switch p.route {
        case .copy:
            try FileManager.default.copyItem(at: p.input, to: output)
            progress.report(1)
        case .ffmpeg:
            try await withFit(p.plan, output: output) { plan in try await ffmpegEncode(p, plan: plan, output: output, ctx: ctx, progress: progress) }
        case .native:
            do {
                try await withFit(p.plan, output: output) { plan in try await nativeEncode(p, plan: plan, output: output, ctx: ctx, progress: progress) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard p.env.hasFFmpeg, p.plan.aacProfile == .lc else { throw error }
                ctx.log("Native encoder failed (\(ConversionError.describe(error))); trying ffmpeg.")
                try? FileManager.default.removeItem(at: output)
                try await withFit(p.plan, output: output) { plan in try await ffmpegEncode(p, plan: plan, output: output, ctx: ctx, progress: progress) }
            }
        case .hybridLame:
            try await withFit(p.plan, output: output) { plan in try await lameEncode(p, plan: plan, output: output, ctx: ctx, progress: progress) }
        case .hybridSox:
            try await withFit(p.plan, output: output) { plan in try await soxEncode(p, plan: plan, output: output, ctx: ctx, progress: progress) }
        }
    }

    // MARK: Routes

    private static func ffmpegEncode(_ p: AudPrepared, plan: AudPlan, output: URL, ctx: OperationContext, progress: AudProgress) async throws {
        var cover: URL? = nil
        if AudFFmpegArgs.supportsCover(plan.target) {
            let needsPrepared = plan.coverMode == .replace || (plan.coverMode == .keep && plan.coverMax > 0 && p.info?.hasCover == true)
            if needsPrepared, let data = await AudCover.data(for: plan, info: p.info, source: p.input, ctx: ctx) { cover = try AudCover.writeTemp(data, ctx: ctx) }
        }
        try await AudFFmpegEngine.transcode(input: p.input, output: output, plan: plan, info: p.info, env: p.env, cover: cover, ctx: ctx, progress: progress)
    }

    private static func nativeEncode(_ p: AudPrepared, plan: AudPlan, output: URL, ctx: OperationContext, progress: AudProgress) async throws {
        let source = try await AudDecodable.url(for: p.input, env: p.env, ctx: ctx)
        defer { source.cleanup() }
        var cover: Data? = nil
        if plan.target.isMP4Family { cover = await AudCover.data(for: plan, info: p.info, source: p.input, ctx: ctx) }
        let tags = plan.target.isMP4Family ? AudTagResolver.effective(plan: plan, info: p.info) : nil
        if !plan.target.isMP4Family, !AudTagResolver.effective(plan: plan, info: p.info).isEmpty {
            ctx.log("Tags cannot be written to \(plan.target.rawValue.uppercased()) without ffmpeg; the file has none.")
        }
        try await AudNativeEngine.run(input: source.url, info: p.info, plan: plan, output: output, sinkKind: .target, tags: tags, cover: cover, ctx: ctx, progress: progress)
    }

    private static func lameEncode(_ p: AudPrepared, plan: AudPlan, output: URL, ctx: OperationContext, progress: AudProgress) async throws {
        let source = try await AudDecodable.url(for: p.input, env: p.env, ctx: ctx)
        defer { source.cleanup() }
        let wav = ctx.tempDir.appendingPathComponent("lame-\(Util.hex8()).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        var dsp = plan
        dsp.channels = plan.channels ?? min(p.info?.channels ?? 2, 2)
        try await AudNativeEngine.run(input: source.url, info: p.info, plan: dsp, output: wav, sinkKind: .floatWAV, tags: nil, cover: nil, ctx: ctx, progress: progress.scaled(0, 0.6))
        var coverURL: URL? = nil
        if let data = await AudCover.data(for: plan, info: p.info, source: p.input, ctx: ctx) { coverURL = try AudCover.writeTemp(data, ctx: ctx) }
        let args = AudLameArgs.arguments(plan: plan, tags: AudTagResolver.effective(plan: plan, info: p.info), cover: coverURL, input: wav, output: output)
        let last = Locked<Double>(0)
        try await ctx.runTool(.lame, args, onStdoutLine: { _ in }, onStderrLine: { line in
            if let f = AudLameArgs.parsePercent(line), f - last.value >= 0.01 { last.value = f; progress.report(0.6 + 0.4 * f) }
        })
        progress.report(1)
    }

    /// Signal work into a float WAV (ffmpeg when the plan needs its filters, the native engine otherwise), then sox writes the Vorbis stream.
    private static func soxEncode(_ p: AudPrepared, plan: AudPlan, output: URL, ctx: OperationContext, progress: AudProgress) async throws {
        let wav = ctx.tempDir.appendingPathComponent("sox-\(Util.hex8()).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        if plan.needsFFmpegFeature, p.env.hasFFmpeg {
            var pre = plan
            pre.target = .wav; pre.fileExtension = "wav"; pre.bitDepth = .f32; pre.tagsMode = .strip; pre.coverMode = .remove
            pre.fitBytes = nil; pre.passthrough = false; pre.trimCopy = false; pre.kbps = 0; pre.useQuality = false
            try await AudFFmpegEngine.transcode(input: p.input, output: wav, plan: pre, info: p.info, env: p.env, cover: nil, ctx: ctx, progress: progress.scaled(0, 0.85))
        } else {
            let source = try await AudDecodable.url(for: p.input, env: p.env, ctx: ctx)
            defer { source.cleanup() }
            var dsp = plan
            dsp.channels = plan.channels ?? min(p.info?.channels ?? 2, 2)
            try await AudNativeEngine.run(input: source.url, info: p.info, plan: dsp, output: wav, sinkKind: .floatWAV, tags: nil, cover: nil, ctx: ctx, progress: progress.scaled(0, 0.85))
        }
        let args = AudSox.arguments(plan: plan, tags: AudTagResolver.effective(plan: plan, info: p.info), input: wav, output: output)
        try await ctx.runTool(.sox, args, onStdoutLine: { _ in }, onStderrLine: { _ in })
        progress.report(1)
    }

    // MARK: Size limit

    /// How close below the limit a result must land to be accepted without another try.
    static let fitAccept = 0.95

    /// Encodes once; when the plan carries a size limit, measures the result and corrects the bit rate by the measured ratio (a bit-rate mode is only
    /// an average): up when the file came out well under the limit, down when it came out over. At most five encodes; the best result that does not
    /// exceed the limit wins, and when the last try is not it the best one is encoded again (the encoders are deterministic).
    static func withFit(_ plan: AudPlan, output: URL, _ encode: (AudPlan) async throws -> Void) async throws {
        guard let limit = plan.fitBytes, plan.kbps > 0, !plan.useQuality else { try await encode(plan); return }
        func size() -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        let range = AudBitrates.range(for: plan.target, channels: plan.channels ?? 2)
        var current = plan
        var tried = Set<Int>()
        var best: (kbps: Int, size: Int64)? = nil
        var last: (kbps: Int, size: Int64) = (plan.kbps, 0)
        for _ in 0..<5 {
            try Task.checkCancellation()
            tried.insert(current.kbps)
            try? FileManager.default.removeItem(at: output)
            try await encode(current)
            let got = size()
            last = (current.kbps, got)
            if got <= limit, got > (best?.size ?? 0) { best = (current.kbps, got) }
            if got <= limit, Double(got) >= Double(limit) * fitAccept { return }
            let aimed = Double(current.kbps) * Double(limit) * 0.985 / Double(max(got, 1))
            let next = min(max(Int(aimed.rounded(.down)), range.lowerBound), range.upperBound)
            if next == current.kbps || tried.contains(next) { break }
            current.kbps = next
        }
        if let b = best, last.kbps != b.kbps {
            current.kbps = b.kbps
            try? FileManager.default.removeItem(at: output)
            try await encode(current)
        }
    }
}

/// An input the native decoder can open: the file itself, or (when AVAudioFile cannot read the format) a temporary WAV decoded by ffmpeg.
struct AudDecodable {
    var url: URL
    var temporary: URL?
    func cleanup() { if let t = temporary { try? FileManager.default.removeItem(at: t) } }

    static func url(for input: URL, env: AudEnvironment, ctx: OperationContext) async throws -> AudDecodable {
        if (try? AudNativeReader(url: input)) != nil { return AudDecodable(url: input, temporary: nil) }
        guard env.hasFFmpeg else { throw ConversionError.fileUnreadable(input) }
        let tmp = ctx.tempDir.appendingPathComponent("decoded-\(Util.hex8()).wav")
        let args = AudFFmpegArgs.prefix + ["-i", input.path, "-map", "0:a:0", "-c:a", "pcm_f32le", "-rf64", "auto", "-f", "wav", tmp.path]
        do { try await AudFFmpegEngine.run(args, ctx: ctx, duration: nil, input: input) { _ in } }
        catch { try? FileManager.default.removeItem(at: tmp); throw error }
        return AudDecodable(url: tmp, temporary: tmp)
    }
}
