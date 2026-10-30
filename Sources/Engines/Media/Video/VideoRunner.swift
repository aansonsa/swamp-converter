import Foundation

// One video job from probe to atomic output: analyses -> plan -> commands -> run (ffmpeg, or AVFoundation when there is no ffmpeg) with the
// safety nets of the brief: a software fallback when the hardware encoder refuses a file, up to three attempts to land a "target size" run at or
// below the target, cleanup of two-pass logs, and notes/warnings handed back to the operation result.

/// Notes (calm information) and warnings (something the person should know) collected per job and attached to the OperationResult.
final class VideoJobNotes: @unchecked Sendable {
    static let shared = VideoJobNotes()
    private let lock = NSLock()
    private var notes: [UUID: [L10n]] = [:]
    private var warnings: [UUID: [L10n]] = [:]

    func note(_ job: UUID, _ n: L10n) { lock.lock(); notes[job, default: []].append(n); lock.unlock() }
    func warn(_ job: UUID, _ n: L10n) { lock.lock(); warnings[job, default: []].append(n); lock.unlock() }
    func take(_ job: UUID) -> (notes: [L10n], warnings: [L10n]) {
        lock.lock(); defer { lock.unlock() }
        return (notes.removeValue(forKey: job) ?? [], warnings.removeValue(forKey: job) ?? [])
    }
}

struct VideoJob {
    let item: FileItem
    let info: MediaInfo
    let ctx: OperationContext
    let progress: ProgressSlice
    let toolset: MediaToolset
    let suffix: L10n?

    // MARK: Toolset

    static func toolset(for ctx: OperationContext) -> MediaToolset {
        if let o = MediaToolset.override.value { return o }
        return MediaToolset.detect(capabilities: .shared, tools: ctx.tools)
    }

    // MARK: Entry

    func run() async throws -> [URL] {
        let r = ctx.resolved
        let o = VOpts(r)
        if o.s(VideoKeys.container) == "mp3" { return [try await runAudioOnly()] }
        var (plan, an) = try await makePlan(r)
        for n in plan.notes { ctx.log("note: \(n.en)"); VideoJobNotes.shared.note(ctx.jobID, n) }
        if plan.copyTrim, plan.trimStart > 0.001, let k = await VideoAnalyzer.keyframe(atOrBefore: plan.trimStart, url: item.url, ctx: ctx), abs(k - plan.trimStart) > 0.05 {
            VideoJobNotes.shared.warn(ctx.jobID, L10n("Copying cuts at key frames, so the start moved from \(Util.formatTime(plan.trimStart, fraction: true)) to \(Util.formatTime(k, fraction: true)).",
                                                      "При копировании обрезка идёт по ключевым кадрам, поэтому начало сдвинулось с \(Util.formatTime(plan.trimStart, fraction: true)) на \(Util.formatTime(k, fraction: true))."))
        }
        let tokens = Self.tokens(plan: plan, info: info, r: r)
        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: plan.container, tokens: tokens) { part in
            try await encode(&plan, analysis: &an, options: r, output: part)
        }
        return [url]
    }

    /// Analyses, then the plan; a second planning round feeds the loudness measurement back in (it needs the filters the plan builds).
    func makePlan(_ r: ResolvedOptions) async throws -> (VideoEncodePlan, VideoAnalysis) {
        var an = try await VideoAnalyzer.run(r, info: info, toolset: toolset, ctx: ctx)
        var plan = try VideoPlanBuilder.build(options: r, source: info, analysis: an, toolset: toolset, preferHardware: ctx.preferHardware)
        if toolset.hasFFmpeg, an.loudness == nil, let t = plan.audioTracks.first(where: { $0.codec != "copy" && $0.filters.contains { $0.hasPrefix("loudnorm") } }) {
            let pre = Array(t.filters.prefix { !$0.hasPrefix("loudnorm") })
            let target = Self.loudnessTarget(VOpts(r))
            if let m = try await VideoAnalyzer.measureLoudness(url: item.url, streamIndex: t.sourceStream, preFilters: pre, target: target, trimStart: plan.trimStart, trimEnd: plan.trimEnd, ctx: ctx) {
                an.loudness = m
                plan = try VideoPlanBuilder.build(options: r, source: info, analysis: an, toolset: toolset, preferHardware: ctx.preferHardware)
            }
        }
        return (plan, an)
    }

    static func loudnessTarget(_ o: VOpts) -> Double {
        switch o.s(VideoKeys.audioNorm) {
        case "ebu": return -23
        case "podcast": return -16
        case "streaming": return -14
        default: return o.d(VideoKeys.audioNormLUFS, -16)
        }
    }

    // MARK: Encoding

    func encode(_ plan: inout VideoEncodePlan, analysis an: inout VideoAnalysis, options r: ResolvedOptions, output: URL) async throws {
        if plan.backend == .avfoundation {
            try await VideoAVFExporter.export(plan: plan, input: item.url, output: output, ctx: ctx, progress: progress)
            return
        }
        do {
            try await encodeWithAttempts(plan, analysis: an, options: r, output: output)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as ConversionError {
            // The hardware encoder refused this file (size, depth, a driver quirk): the software encoder gets one try.
            guard plan.hardware, case .toolFailed = e, plan.videoCodec != "copy" else { throw e }
            var r2 = r
            r2.values["venc"] = "software"
            let soft = try VideoPlanBuilder.build(options: r2, source: info, analysis: an, toolset: toolset, preferHardware: false)
            guard !soft.hardware else { throw e }
            ctx.log("The hardware encoder failed (\(ConversionError.describe(e))); trying the software encoder.")
            VideoJobNotes.shared.note(ctx.jobID, L10n("The hardware encoder could not handle this file, so the software encoder was used.", "Аппаратный кодировщик не справился с этим файлом, поэтому использован программный."))
            try? FileManager.default.removeItem(at: output)
            plan = soft
            try await encodeWithAttempts(soft, analysis: an, options: r2, output: output)
        }
    }

    /// Normal runs encode once. "Target size" runs measure the result and, when it is over the target, encode again at a corrected bitrate
    /// (and once at a higher one when the first try is far below). The best result that fits is kept.
    func encodeWithAttempts(_ plan: VideoEncodePlan, analysis: VideoAnalysis, options r: ResolvedOptions, output: URL) async throws {
        guard let target = plan.targetBytes else {
            try await runOnce(plan, output: output, range: 0...1)
            return
        }
        var scale = analysis.bitrateScale
        var best: (url: URL, size: Int64)? = nil
        var smallestOver: (url: URL, size: Int64)? = nil
        var current = plan
        let attemptsMax = 3
        for attempt in 0..<attemptsMax {
            try ctx.checkCancelled()
            let tmp = ctx.tempDir.appendingPathComponent("attempt-\(attempt).\(plan.container)")
            let lo = Double(attempt) / Double(attemptsMax), hi = Double(attempt + 1) / Double(attemptsMax)
            try await runOnce(current, output: tmp, range: lo...hi)
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0, size <= target {
                if best == nil || size > best!.size { try? best.map { try FileManager.default.removeItem(at: $0.url) }; best = (tmp, size) } else { try? FileManager.default.removeItem(at: tmp) }
            } else if size > 0 {
                if smallestOver == nil || size < smallestOver!.size { try? smallestOver.map { try FileManager.default.removeItem(at: $0.url) }; smallestOver = (tmp, size) } else { try? FileManager.default.removeItem(at: tmp) }
            }
            ctx.log("size attempt \(attempt + 1): \(size) bytes of \(target) (bitrate scale \(String(format: "%.3f", scale)))")
            let ratio = Double(target) / Double(max(size, 1))
            // Good enough: at or below the target and within 6% of it.
            if size <= target, ratio < 1.0 / 0.94 { break }
            if size <= target && attempt >= 1 { break }
            let next = size > target ? scale * ratio * 0.97 : scale * min(1.12, ratio * 0.985)
            if abs(next - scale) < 0.005 { break }
            scale = next
            var a2 = analysis
            a2.bitrateScale = scale
            current = try VideoPlanBuilder.build(options: r, source: info, analysis: a2, toolset: toolset, preferHardware: ctx.preferHardware)
        }
        guard let pick = best ?? smallestOver else { throw ConversionError.noOutput }
        if best == nil {
            VideoJobNotes.shared.warn(ctx.jobID, L10n("The result is a little over the requested size (\(Util.formatBytes(pick.size)) instead of \(Util.formatBytes(target))). Choose a smaller size or a lower resolution.",
                                                      "Результат немного больше заданного размера (\(Util.formatBytes(pick.size)) вместо \(Util.formatBytes(target))). Выберите размер поменьше или меньшее разрешение."))
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: pick.url, to: output)
        if let o = smallestOver, o.url != pick.url { try? FileManager.default.removeItem(at: o.url) }
    }

    /// One complete encode (all passes) into `output`.
    func runOnce(_ plan: VideoEncodePlan, output: URL, range: ClosedRange<Double>) async throws {
        let temp = ctx.tempDir.appendingPathComponent("enc-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cmds = try VideoFFmpegArgs.commands(for: plan, input: item.url, output: output, tempDirectory: temp)
        guard !cmds.isEmpty else { throw ConversionError.noOutput }
        let span = range.upperBound - range.lowerBound
        let duration = plan.outputDuration ?? plan.sourceDuration
        for (i, cmd) in cmds.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            let sub: ClosedRange<Double>
            if cmds.count == 2 { sub = i == 0 ? (range.lowerBound...(range.lowerBound + span * 0.4)) : ((range.lowerBound + span * 0.4)...range.upperBound) } else { sub = range }
            ctx.log(cmd.displayString())
            try await FFmpegRunner.run(cmd, ctx: ctx, totalDuration: duration, progress: progress, range: sub)
        }
    }

    // MARK: Audio only (MP3)

    func runAudioOnly() async throws -> URL {
        let audioOptions = VideoAudioBridge.audioOptions(from: ctx.resolved)
        return try await ctx.produceFile(for: item, suffix: suffix, ext: "mp3") { part in
            do {
                try await AudioTranscoder.transcode(input: item.url, output: part, options: audioOptions, ctx: ctx, progress: progress)
            } catch let e as ConversionError {
                // The audio service is not available (stub): fall back to the video planner's own audio-only route.
                guard case .unsupported = e, toolset.hasFFmpeg else { throw e }
                var plan = try VideoPlanBuilder.build(options: ctx.resolved, source: info, toolset: toolset)
                var an = VideoAnalysis()
                try? FileManager.default.removeItem(at: part)
                try await encode(&plan, analysis: &an, options: ctx.resolved, output: part)
            }
        }
    }

    // MARK: Output name tokens

    static func tokens(plan: VideoEncodePlan, info: MediaInfo, r: ResolvedOptions) -> [String: String] {
        var t: [String: String] = ["container": plan.container, "codec": plan.videoCodec]
        let size = plan.picture.outputSize ?? info.primaryVideo?.displaySize.map { ($0.width, $0.height) }
        if let s = size {
            t["width"] = "\(s.0)"; t["height"] = "\(s.1)"; t["res"] = "\(min(s.0, s.1))p"
        }
        if let f = plan.picture.fps ?? info.primaryVideo?.fps { t["fps"] = VideoPlanner.num((f * 100).rounded() / 100) }
        switch plan.rate {
        case .quality(let q): t["quality"] = plan.hardware ? "q\(Int(q))" : "CRF \(VideoPlanner.num(q))"
        case .bitrate(let k): t["quality"] = k >= 1000 ? "\(VideoPlanner.num((Double(k) / 100).rounded() / 10)) Mbps" : "\(k) kbps"
        case .lossless: t["quality"] = "lossless"
        case .none: break
        }
        return t
    }
}
