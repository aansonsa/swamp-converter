import Foundation

// Joining audio files. The original app adopted the FIRST file's sample rate and channel layout silently (a stereo 48 kHz file after a
// mono 44.1 kHz one was downmixed). Here the target is explicit: by default the BEST of the inputs (highest rate; stereo if any is stereo).

struct AudJoinSource: Sendable {
    var item: FileItem
    var info: AudInfo
}

enum AudJoin {
    /// Natural order by path (track2 before track10), or the order given.
    static func ordered(_ items: [FileItem], natural: Bool) -> [FileItem] {
        natural ? items.sorted { Util.naturalCompare($0.url.path, $1.url.path) == .orderedAscending } : items
    }

    /// The output rate: the person's choice, else the highest input rate, moved onto the rates the target accepts.
    static func outputRate(choice: String, infos: [AudInfo], target: AudTarget) -> Int {
        let chosen = Int(choice)
        let best = infos.compactMap(\.sampleRate).max() ?? 44_100
        let rate = chosen ?? best
        guard let allowed = target.allowedRates else { return rate }
        return allowed.contains(rate) ? rate : AudRates.nearest(rate, in: allowed)
    }

    /// The output channels: the person's choice, else stereo when any input has two or more channels, else mono.
    static func outputChannels(choice: String, infos: [AudInfo]) -> Int {
        switch choice {
        case "mono": return 1
        case "stereo": return 2
        default: return infos.contains { ($0.channels ?? 1) >= 2 } ? 2 : 1
        }
    }

    /// Decodes every source through the joiner into `sink`. Progress is weighted by duration.
    static func decodeAll(_ sources: [AudJoinSource], rate: Int, channels: Int, gap: Double, crossfade: Double, sink: AudNativeSink,
                          env: AudEnvironment, ctx: OperationContext, progress: AudProgress) async throws {
        let totalSeconds = max(sources.reduce(0.0) { $0 + ($1.info.duration ?? 0) }, 1)
        var doneSeconds = 0.0
        let joiner = AudJoiner(channels: channels, rate: rate, gapSeconds: gap, crossfadeSeconds: crossfade) { try sink.write($0) }
        var chunks = 0
        for source in sources {
            try Task.checkCancellation()
            let decodable = try await AudDecodable.url(for: source.item.url, env: env, ctx: ctx)
            defer { decodable.cleanup() }
            let reader = try AudNativeReader(url: decodable.url)
            let resampler = AudResampler(inRate: reader.rate, outRate: rate, channels: channels)
            let seconds = Double(reader.rangeFrames) / Double(max(reader.rate, 1))
            try joiner.beginSource()
            while let raw = try reader.next() {
                try Task.checkCancellation()
                chunks += 1
                if chunks % 8 == 0 { try await ctx.waitIfPaused() }
                var c = raw.count != channels ? AudMix.apply(raw, to: channels) : raw
                if let resampler { c = try resampler.process(c) }
                try joiner.append(c)
                progress.report((doneSeconds + seconds * Double(reader.framesRead) / Double(max(reader.rangeFrames, 1))) / totalSeconds)
            }
            if let resampler { try joiner.append(try resampler.flush()) }
            try joiner.endSource()
            doneSeconds += seconds
        }
        try joiner.finish()
        try sink.close()
    }

    /// Complete join into `output` (the hidden `.part` path): native target written directly, or float WAV then ffmpeg / lame.
    static func run(sources: [AudJoinSource], plan: AudPlan, rate: Int, channels: Int, gap: Double, crossfade: Double, output: URL,
                    env: AudEnvironment, ctx: OperationContext, progress: AudProgress) async throws {
        let first = sources[0]
        // First file's tags and cover travel to the result (tags mode keep / custom / strip applies to them).
        let firstTags = AudTagResolver.effective(plan: plan, info: first.info)
        let cover = await AudCover.data(for: plan, info: first.info, source: first.item.url, ctx: ctx)
        var joined = plan
        joined.sampleRate = rate
        joined.channels = channels
        let t = plan.target
        let tagsNeedFFmpeg = (t == .flac || t == .wav) && env.hasFFmpeg && (!firstTags.isEmpty || cover != nil)
        let external = !t.hasNativeEncoder || tagsNeedFFmpeg
        let info = AudInfo(url: first.item.url, sampleRate: rate, channels: channels)
        if !external {
            let (sink, work) = try AudNativeEngine.makeSink(plan: joined, kind: .target, output: output, rate: rate, channels: channels, info: info)
            defer { if work != output { try? FileManager.default.removeItem(at: work) } }
            try await decodeAll(sources, rate: rate, channels: channels, gap: gap, crossfade: crossfade, sink: sink, env: env, ctx: ctx, progress: progress.scaled(0, 0.98))
            try await AudNativeEngine.finish(work: work, output: output, plan: joined, kind: .target, tags: firstTags, cover: cover, ctx: ctx)
            progress.report(1)
            return
        }
        // External encoder: float WAV first, then ffmpeg (or lame for MP3 without ffmpeg's encoder).
        let wav = ctx.tempDir.appendingPathComponent("join-\(Util.hex8()).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let (sink, _) = try AudNativeEngine.makeSink(plan: joined, kind: .floatWAV, output: wav, rate: rate, channels: channels, info: info)
        try await decodeAll(sources, rate: rate, channels: channels, gap: gap, crossfade: crossfade, sink: sink, env: env, ctx: ctx, progress: progress.scaled(0, 0.6))
        let duration = sources.reduce(0.0) { $0 + ($1.info.duration ?? 0) }
        var wavInfo = AudInfo(url: wav, sampleRate: rate, channels: channels)
        wavInfo.duration = duration
        wavInfo.codec = "pcm_f32le"; wavInfo.isFloat = true; wavInfo.bitDepth = 32; wavInfo.audioStreamCount = 1
        var encode = joined
        encode.tagsMode = .custom
        encode.tagEdits = [:]
        for (_, name) in AudioKeys.tagFields where !firstTags[name].isEmpty { encode.tagEdits[name] = firstTags[name] }
        encode.coverMode = .keep
        var coverURL: URL? = nil
        if let cover { coverURL = try AudCover.writeTemp(cover, ctx: ctx) }
        if t == .ogg, !env.hasVorbis, env.hasSoxVorbis {
            let args = AudSox.arguments(plan: encode, tags: firstTags, input: wav, output: output)
            try await ctx.runTool(.sox, args, onStdoutLine: { _ in }, onStderrLine: { _ in })
        } else if t == .mp3, env.hasLame, !env.has(encoder: "libmp3lame") || channels == 1 {
            let args = AudLameArgs.arguments(plan: encode, tags: firstTags, cover: coverURL, input: wav, output: output)
            let last = Locked<Double>(0)
            try await ctx.runTool(.lame, args, onStdoutLine: { _ in }, onStderrLine: { line in
                if let f = AudLameArgs.parsePercent(line), f - last.value >= 0.01 { last.value = f; progress.report(0.6 + 0.4 * f) }
            })
        } else {
            if coverURL != nil { encode.coverMode = .replace; encode.coverFile = coverURL }
            try await AudFFmpegEngine.transcode(input: wav, output: output, plan: encode, info: wavInfo, env: env, cover: coverURL, ctx: ctx, progress: progress.scaled(0.6, 1))
        }
        progress.report(1)
    }
}

extension AudInfo {
    /// A minimal info for synthetic sources (a temporary WAV).
    init(url: URL, sampleRate: Int, channels: Int) {
        self.init(url: url)
        self.sampleRate = sampleRate
        self.channels = channels
        self.audioStreamCount = 1
    }

    /// Rebuilds the facts the engine needs from the cached probe (Studio estimate, quick validation) without touching the file.
    init(source: SourceInfo) {
        self.init(url: source.url)
        container = source.string("container") ?? ""
        codec = source.string("audio.0.codec") ?? ""
        sampleRate = source.int("audio.0.rate")
        channels = source.int("audio.0.channels")
        bitRate = source.int("audio.0.bitrate")
        bitDepth = source.int("audio.0.bitdepth")
        duration = source.duration
        size = source.sizeBytes
        audioStreamCount = source.int("audio.count") ?? (codec.isEmpty ? 0 : 1)
        hasCover = source.bool("audio.hasCover") ?? false
        var raw: [String: String] = [:]
        for (_, name) in AudioKeys.tagFields { if let v = source.string("audio.tag.\(name)") { raw[name == "albumArtist" ? "album_artist" : (name == "year" ? "date" : name)] = v } }
        rawTags = raw
    }
}
