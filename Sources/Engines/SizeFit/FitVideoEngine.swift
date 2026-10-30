import Foundation

extension VideoFit {
    /// Runs the plan with ffmpeg (two-pass when the encoder supports it, else single pass with a VBV window), then VERIFIES the file size and corrects.
    ///
    /// The process work is done by `FitFFmpeg` (same ffmpeg, same fixed prefix) because the loop needs the exact argument list of every attempt.
    /// Up to four attempts: the first from the plan, then bracketing corrections based on the MEASURED sizes (`FitCorrection.nextRequest`). The result is
    /// always the largest attempt that fits; an attempt over the target is never kept. When the hardware encoder cannot get under the limit (its rate control
    /// has a floor) the whole loop is repeated with x264, which can; when nothing fits the run fails with a calm message instead of exceeding the limit.
    static func run(input: FileItem, targetBytes: Int64, options: OptionValues, ctx: OperationContext, progress: ProgressSlice) async throws -> FitResult {
        try ctx.checkCancelled()
        let suffix = FitNaming.suffix(options)
        let sourceSize = input.size ?? FitProbe.fileSize(input.url)
        if sourceSize > 0, sourceSize <= targetBytes {
            let url = try await FitFiles.copyUnchanged(input, ext: input.url.pathExtension.isEmpty ? "mp4" : input.url.pathExtension, suffix: suffix, ctx: ctx)
            return FitResult(output: url, achievedBytes: FitProbe.fileSize(url), targetBytes: targetBytes, notes: [FitMessages.alreadySmall])
        }

        let info = try await FitProbe.video(input.url, ctx: ctx)
        let caps = Capabilities.shared
        let wantTwoPass = options.bool(FitKeys.twoPass, true) && ctx.isActive(FitKeys.twoPass)
        guard let choice = VideoFitEncoderChoice.choose(isHDR: info.isHDR, preferHardware: ctx.preferHardware, wantTwoPass: wantTwoPass,
                                                        has: { caps.has("ff.enc.\($0)") }) else {
            throw ConversionError.message(L10n("This ffmpeg cannot write H.264 video. Open Settings > Tools to see how to get a full build.",
                                               "Эта сборка ffmpeg не умеет писать видео H.264. Откройте Настройки > Инструменты, чтобы узнать, как получить полную сборку."))
        }
        let plan = plan(durationSeconds: info.duration, targetBytes: targetBytes, audioKbps: options.int(FitKeys.audioKbps, 96),
                        sourceWidth: info.width, sourceHeight: info.height, sourceFPS: info.fps, hasAudio: info.hasAudio,
                        allowDownscale: options.bool(FitKeys.allowDownscale, true), preferTwoPass: choice.twoPass,
                        codecEfficiency: choice.encoder.codecEfficiency)
        if plan.unreachable {
            let smallest = expectedBytes(videoKbps: FitTuning.minVideoKbps, audioKbps: plan.audioKbps, durationSeconds: info.duration)
            throw FitMessages.tooSmall(kind: .video, smallest: smallest, target: targetBytes)
        }
        ctx.log("fit.video: \(info.width)x\(info.height) \(String(format: "%.1f", info.fps)) fps, \(String(format: "%.1f", info.duration)) s, plan \(plan.videoKbps)+\(plan.audioKbps) kbit/s, encoder \(choice.encoder.rawValue), two-pass \(choice.twoPass)")

        var notes = plan.notes + choice.notes
        if info.extraAudioStreams > 0 {
            notes.append(L10n("Only the first audio track was kept.", "Сохранена только первая звуковая дорожка."))
        }
        if info.subtitleStreams > 0 {
            notes.append(L10n("Subtitles were not kept.", "Субтитры не сохранены."))
        }
        let base = VideoFitJob(input: input.url, output: input.url, info: info, plan: plan, encoder: choice.encoder, videoKbps: plan.videoKbps,
                               twoPass: choice.twoPass, strip: options.bool(FitKeys.stripMetadata, false), passLog: "")
        var encoders: [VideoFitEncoder] = [choice.encoder]
        if choice.encoder == .vtH264, caps.has("ff.enc.libx264") { encoders.append(.x264) }

        let output = try await ctx.produceFile(for: input, suffix: suffix, ext: "mp4") { temp in
            var smallestSeen = Int64.max
            var winner: (url: URL, bytes: Int64)?
            defer { FitFiles.remove(winner?.url) }
            for (n, encoder) in encoders.enumerated() {
                var job = base
                job.encoder = encoder
                job.twoPass = encoder.supportsTwoPass && wantTwoPass
                // With a fallback in line the first encoder gets the first third of the bar, the second the rest.
                let window: (Double, Double) = encoders.count == 1 ? (0, 1) : (n == 0 ? (0, 0.35) : (0.35, 1))
                let result = try await attempts(job: job, plan: plan, targetBytes: targetBytes, temp: temp, ctx: ctx, progress: progress, window: window)
                smallestSeen = min(smallestSeen, result.smallest)
                if let found = result.best { winner = found; break }
                if n + 1 < encoders.count {
                    notes.append(L10n("The hardware encoder could not get under the limit, so the software encoder was used.",
                                      "Аппаратный кодировщик не смог уложиться в лимит, поэтому использован программный."))
                }
            }
            guard let winner else { throw FitMessages.tooSmall(kind: .video, smallest: smallestSeen == .max ? 0 : smallestSeen, target: targetBytes) }
            try FitFiles.place(winner.url, at: temp)
        }
        let achieved = FitProbe.fileSize(output)
        let ceiling = max(VideoFitArgs.ceilingKbps(plan: plan, info: info, encoder: base.encoder), FitTuning.minVideoKbps)
        if Double(achieved) < Double(targetBytes) * FitTuning.fillGoal, plan.videoKbps >= ceiling {
            notes.append(L10n("The picture is already at its best, so the file is smaller than the limit.", "Качество картинки уже максимальное, поэтому файл меньше лимита."))
        }
        var seen = Set<L10n>()
        notes = notes.filter { seen.insert($0).inserted }
        return FitResult(output: output, achievedBytes: achieved, targetBytes: targetBytes, notes: notes)
    }

    /// The attempt loop for ONE encoder: returns the largest attempt that fits (kept next to `temp`) and the smallest size seen.
    private static func attempts(job base: VideoFitJob, plan: VideoFitPlan, targetBytes: Int64, temp: URL, ctx: OperationContext, progress: ProgressSlice,
                                 window: (Double, Double)) async throws -> (best: (url: URL, bytes: Int64)?, smallest: Int64) {
        var job = base
        let info = job.info, encoder = job.encoder
        let ceiling = max(VideoFitArgs.ceilingKbps(plan: plan, info: info, encoder: encoder), FitTuning.minVideoKbps)
        let aim = Int64(Double(targetBytes) * FitTuning.aimFraction)
        var best: (url: URL, bytes: Int64)?
        var history: [FitCorrection.Attempt] = []
        var smallest = Int64.max
        var current: URL?
        var kbps = Double(min(plan.videoKbps, ceiling))
        // Progress share of each attempt: the first carries most of the work, a correction is a smaller promise of more.
        let spans: [(Double, Double)] = [(0, 0.6), (0.6, 0.8), (0.8, 0.92), (0.92, 1.0)]
        do {
            for attempt in 1...spans.count {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                let candidate = FitFiles.attempt(beside: temp, attempt + (encoder == .x264 ? 10 : 0), ext: "mp4")
                job.output = candidate
                current = candidate
                job.videoKbps = max(Int((kbps * encoder.bitrateBias).rounded()), FitTuning.minVideoKbps)
                job.passLog = ctx.tempDir.appendingPathComponent("fit-pass-\(encoder.rawValue)-\(attempt)").path
                let span = (window.0 + (window.1 - window.0) * spans[attempt - 1].0, window.0 + (window.1 - window.0) * spans[attempt - 1].1)
                try await encode(job, ctx: ctx, duration: info.duration, progress: progress, span: span)
                let bytes = FitProbe.fileSize(candidate)
                smallest = min(smallest, bytes)
                history.append(FitCorrection.Attempt(request: kbps, bytes: bytes))
                ctx.log("fit.video attempt \(attempt) (\(encoder.rawValue)): \(job.videoKbps) kbit/s -> \(bytes) bytes (target \(targetBytes))")
                if bytes <= targetBytes, best == nil || bytes > best!.bytes {
                    FitFiles.remove(best?.url); best = (candidate, bytes)
                } else {
                    FitFiles.remove(candidate)
                }
                if bytes <= targetBytes, Double(bytes) >= Double(targetBytes) * FitTuning.fillGoal { break }
                // Under the band is only worth another run when more bits would show; over the limit always is.
                if bytes <= targetBytes, kbps >= Double(ceiling) { break }
                guard attempt < spans.count,
                      let next = FitCorrection.nextRequest(history: history, aimBytes: aim, targetBytes: targetBytes, floor: Double(FitTuning.minVideoKbps), ceiling: Double(ceiling))
                else { break }
                kbps = next
            }
        } catch {
            // Cancelled or failed in the middle of an attempt: neither the half-written attempt nor an earlier good one may stay behind.
            FitFiles.remove(current); FitFiles.remove(best?.url)
            throw error
        }
        return (best, smallest)
    }

    /// One attempt: a single ffmpeg run, or the two-pass pair (pass 1 weighs 40%, pass 2 60%). `span` is the slice of the file's progress it fills.
    private static func encode(_ job: VideoFitJob, ctx: OperationContext, duration: Double, progress: ProgressSlice, span: (Double, Double)) async throws {
        @Sendable func report(_ f: Double) { progress.report(span.0 + (span.1 - span.0) * f) }
        if job.twoPass {
            try await FitFFmpeg.run(VideoFitArgs.arguments(job, pass: 1), ctx: ctx, duration: duration) { report($0 * 0.4) }
            try await FitFFmpeg.run(VideoFitArgs.arguments(job, pass: 2), ctx: ctx, duration: duration) { report(0.4 + $0 * 0.6) }
        } else {
            try await FitFFmpeg.run(VideoFitArgs.arguments(job, pass: nil), ctx: ctx, duration: duration) { report($0) }
        }
    }
}
