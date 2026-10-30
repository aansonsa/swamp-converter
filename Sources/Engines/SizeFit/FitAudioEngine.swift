import Foundation

extension AudioFit {
    /// Formats afconvert (AudioToolbox) reads: the native route needs no ffmpeg.
    static let nativeInputs: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf", "m4b", "mp4"]

    /// What the fit does for the chosen option and this Mac. Pure, so it is tested without audio.
    static func chooseCodec(option: String, hasFFmpeg: Bool, has: (String) -> Bool) -> (codec: AudioFitCodec, note: L10n?) {
        switch option {
        case "mp3":
            if hasFFmpeg, has("libmp3lame") { return (.mp3, nil) }
            return (.aac, L10n("MP3 needs ffmpeg with the LAME encoder, so AAC was used.", "Для MP3 нужен ffmpeg с кодировщиком LAME, поэтому использован AAC."))
        case "opus":
            if hasFFmpeg, has("libopus") { return (.opus, nil) }
            return (.aac, L10n("Opus needs ffmpeg, so AAC was used.", "Для Opus нужен ffmpeg, поэтому использован AAC."))
        default:
            return (.aac, nil)
        }
    }

    /// The ffmpeg arguments (after the fixed prefix) of one audio attempt. `mono` halves the stream for very low bitrates.
    static func ffmpegArguments(input: URL, output: URL, codec: AudioFitCodec, kbps: Int, mono: Bool, strip: Bool) -> [String] {
        var a = ["-i", input.path, "-map", "0:a:0", "-vn"]
        switch codec {
        case .aac: a += ["-c:a", "aac", "-b:a", "\(kbps)k"]
        // ABR (not CBR): any whole bitrate is accepted, so the correction can land close to the limit instead of on the coarse CBR steps.
        case .mp3: a += ["-c:a", "libmp3lame", "-abr", "1", "-b:a", "\(kbps)k", "-id3v2_version", "3", "-write_id3v1", "0"]
        case .opus: a += ["-c:a", "libopus", "-vbr", "off", "-b:a", "\(kbps)k", "-application", "audio"]
        }
        if mono { a += ["-ac", "1"] }
        a += strip ? ["-map_metadata", "-1", "-fflags", "+bitexact"] : ["-map_metadata", "0"]
        if codec == .aac { a += ["-movflags", "+faststart"] }
        a.append(output.path)
        return a
    }

    /// Native AAC (the best encoder on a Mac): afconvert, constant bitrate. Tags are not carried; `graftTags` puts them back when ffmpeg exists.
    static func afconvertArguments(input: URL, output: URL, kbps: Int, mono: Bool) -> [String] {
        var a = ["-f", "m4af", "-d", "aac", "-b", "\(kbps * 1000)", "-s", "0"]
        if mono { a += ["-c", "1"] }
        return a + [input.path, output.path]
    }

    static func run(input: FileItem, targetBytes: Int64, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws -> FitResult {
        try ctx.checkCancelled()
        let suffix = FitNaming.suffix(options)
        let sourceSize = input.size ?? FitProbe.fileSize(input.url)
        if sourceSize > 0, sourceSize <= targetBytes {
            let url = try await FitFiles.copyUnchanged(input, ext: input.url.pathExtension.isEmpty ? "m4a" : input.url.pathExtension, suffix: suffix, ctx: ctx)
            return FitResult(output: url, achievedBytes: FitProbe.fileSize(url), targetBytes: targetBytes, notes: [FitMessages.alreadySmall])
        }
        guard let duration = await FitProbe.audioDuration(input.url, ctx: ctx) else {
            throw ConversionError.message(L10n("The length of this recording cannot be read, so it cannot be fitted to a size.",
                                               "Не удалось определить длительность записи, поэтому уложить её в размер нельзя."))
        }
        let hasFFmpeg = ctx.tools.has(.ffmpeg)
        let (codec, codecNote) = chooseCodec(option: options.string(FitKeys.audioCodec, "auto"), hasFFmpeg: hasFFmpeg,
                                            has: { Capabilities.shared.has("ff.enc.\($0)") })
        var notes: [L10n] = codecNote.map { [$0] } ?? []
        let native = codec == .aac && nativeInputs.contains(input.key)
        if !native, !hasFFmpeg {
            throw ConversionError.message(L10n("This audio format can only be read with ffmpeg. Open Settings > Tools to see how to add it.",
                                               "Этот аудиоформат читается только через ffmpeg. Откройте Настройки > Инструменты, чтобы узнать, как его добавить."))
        }
        guard isReachable(durationSeconds: duration, targetBytes: targetBytes, codec: codec.rawValue) else {
            // AAC bottoms out at 24 kbit/s; Opus goes lower. Say so when it would help instead of a bare refusal.
            if codec != .opus, hasFFmpeg, Capabilities.shared.has("ff.enc.libopus"),
               isReachable(durationSeconds: duration, targetBytes: targetBytes, codec: AudioFitCodec.opus.rawValue) {
                throw ConversionError.message(L10n("AAC cannot get this small for a recording this long. Choose the Opus audio format, which goes lower, or a larger limit.",
                                                   "AAC не может быть таким маленьким для такой длинной записи. Выберите формат звука Opus, он сжимает сильнее, или лимит побольше."))
            }
            throw FitMessages.tooSmall(kind: .audio, smallest: expectedBytes(kbps: codec.minKbps, durationSeconds: duration, codec: codec.rawValue), target: targetBytes)
        }
        let strip = options.bool(FitKeys.stripMetadata, false)
        if native, !strip, !hasFFmpeg {
            notes.append(L10n("Title and artist could not be copied because ffmpeg is not installed.", "Название и исполнитель не скопированы, потому что ffmpeg не установлен."))
        }
        let aim = Int64(Double(targetBytes) * FitTuning.aimFraction)
        let initialKbps = rawKbps(durationSeconds: duration, targetBytes: targetBytes, codec: codec.rawValue)
        var kbps = initialKbps
        // Mono is decided once, from the first bitrate: switching channels between attempts would make the measured sizes inconsistent.
        let mono = initialKbps < 48
        if initialKbps >= codec.maxKbps { notes.append(L10n("The sound is already at its best, so the file is smaller than the limit.", "Звук уже в максимальном качестве, поэтому файл меньше лимита.")) }
        if mono { notes.append(L10n("Converted to mono to keep the voice clear at this size.", "Преобразовано в моно, чтобы голос оставался чётким при таком размере.")) }

        let output = try await ctx.produceFile(for: input, suffix: suffix, ext: codec.fileExtension) { temp in
            var best: (url: URL, bytes: Int64)?
            var current: URL?
            var history: [FitCorrection.Attempt] = []
            var smallestSeen = Int64.max
            let attempts = 5   // audio attempts take milliseconds to seconds: a few more than video buys a tighter fit
            do {
                for attempt in 1...attempts {
                    try ctx.checkCancelled()
                    let candidate = FitFiles.attempt(beside: temp, attempt, ext: codec.fileExtension)
                    current = candidate
                    let slice: @Sendable (Double) -> Void = { [attempt] in progress.report(($0 + Double(attempt - 1)) / Double(attempts)) }
                    if native {
                        try await ctx.runProcess(URL(fileURLWithPath: "/usr/bin/afconvert"), afconvertArguments(input: input.url, output: candidate, kbps: kbps, mono: mono))
                        slice(1)
                        if !strip, hasFFmpeg { try await graftTags(from: input.url, onto: candidate, ctx: ctx, duration: duration) }
                    } else {
                        try await FitFFmpeg.run(ffmpegArguments(input: input.url, output: candidate, codec: codec, kbps: kbps, mono: mono, strip: strip),
                                                ctx: ctx, duration: duration, report: slice)
                    }
                    let bytes = FitProbe.fileSize(candidate)
                    smallestSeen = min(smallestSeen, bytes)
                    history.append(FitCorrection.Attempt(request: Double(kbps), bytes: bytes))
                    ctx.log("fit.audio attempt \(attempt): \(kbps) kbit/s \(codec.rawValue) -> \(bytes) bytes (target \(targetBytes))")
                    if bytes <= targetBytes, best == nil || bytes > best!.bytes {
                        FitFiles.remove(best?.url); best = (candidate, bytes)
                    } else {
                        FitFiles.remove(candidate)
                    }
                    current = nil
                    if bytes <= targetBytes, Double(bytes) >= Double(targetBytes) * FitTuning.fillGoal { break }
                    if bytes <= targetBytes, kbps >= codec.maxKbps { break }
                    guard attempt < attempts,
                          let next = FitCorrection.nextRequest(history: history, aimBytes: aim, targetBytes: targetBytes, floor: Double(codec.minKbps), ceiling: Double(codec.maxKbps))
                    else { break }
                    let rounded = snap(Int(next.rounded(.down)), codec: codec)
                    if history.contains(where: { Int($0.request) == rounded }) { break }
                    kbps = rounded
                }
            } catch {
                FitFiles.remove(current); FitFiles.remove(best?.url)
                throw error
            }
            guard let best else { throw FitMessages.tooSmall(kind: .audio, smallest: smallestSeen == .max ? 0 : smallestSeen, target: targetBytes) }
            try FitFiles.place(best.url, at: temp)
        }
        if kbps != initialKbps { ctx.log("fit.audio: bitrate corrected from \(initialKbps) to \(kbps) kbit/s after measuring") }
        progress.report(1)
        return FitResult(output: output, achievedBytes: FitProbe.fileSize(output), targetBytes: targetBytes, notes: notes)
    }

    /// Clamps to what the codec accepts. (MP3 is written as ABR, which takes any whole bitrate, so its CBR steps only shape the first guess.)
    static func snap(_ kbps: Int, codec: AudioFitCodec) -> Int {
        min(max(kbps, codec.minKbps), codec.maxKbps)
    }

    /// afconvert writes no tags: copy the title / artist / album of the source into the new file with ffmpeg (a stream copy, nothing is re-encoded).
    private static func graftTags(from source: URL, onto encoded: URL, ctx: OperationContext, duration: Double) async throws {
        let tagged = encoded.deletingLastPathComponent().appendingPathComponent(".fit-tags-\(Util.hex8()).part.m4a")
        defer { FitFiles.remove(tagged) }
        do {
            try await FitFFmpeg.run(["-i", encoded.path, "-i", source.path, "-map", "0:a", "-map_metadata", "1", "-c:a", "copy", "-movflags", "+faststart", tagged.path],
                                    ctx: ctx, duration: duration, report: { _ in })
            if FitProbe.fileSize(tagged) > 0 { try FitFiles.place(tagged, at: encoded) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ctx.log("fit.audio: tags could not be copied (\(ConversionError.describe(error))); the file is kept without them")
        }
    }
}
