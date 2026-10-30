import Foundation

/// What a finished smart run produced: the file, the plan that was executed and (when "check the result" was on) the verdict.
struct SmartTranscodeResult: Sendable {
    var url: URL
    var plan: TranscodePlan
    var verification: SmartVerification?
    /// Plain-text warnings for the finished card (picture subtitles dropped, HDR kept in Universal, hardware encoder replaced ...).
    var warnings: [String]
}

/// The engine: plan -> ffmpeg -> verified output. Also called directly by the downloader's convert stage and by `SmartOperation`.
enum SmartTranscoder {
    /// Probes `input` (MediaProbe), plans, runs, verifies (`ctx` rules: `out.verify`), returns the final URL written with `ctx.produceFile`
    /// (`{name} (Best for Apple).mp4` style suffix comes from the mode; callers pass `base` to name the file).
    /// Progress is monotone 0...1 and never 100% before ffmpeg exits; cancel removes the partial output; audio tracks and soft subtitles survive.
    /// Hardware first, software fallback: a failing hardware encode (or a result that fails the check) is retried once with libx265 / libx264.
    /// `capabilities` exists for tests (fake machines); production passes nothing.
    static func transcode(input: FileItem, options: SmartOptions, ctx: OperationContext, progress: ProgressSlice?, base: String? = nil,
                          capabilities: SmartCapabilities? = nil) async throws -> URL {
        try await transcodeDetailed(input: input, options: options, ctx: ctx, progress: progress, base: base, capabilities: capabilities).url
    }

    static func transcodeDetailed(input: FileItem, options: SmartOptions, ctx: OperationContext, progress: ProgressSlice?, base: String? = nil,
                                  capabilities: SmartCapabilities? = nil) async throws -> SmartTranscodeResult {
        let caps = capabilities ?? SmartCapabilities.current
        guard caps.hasFFmpeg, ctx.tools.has(.ffmpeg) else { throw ConversionError.toolMissing(.ffmpeg) }
        var opts = options
        if ctx.preferHardware { opts.preferHardware = true }

        try ctx.checkCancelled()
        let info = try await MediaProbe.probe(input.url, tools: ctx.tools)
        try ctx.checkCancelled()
        let facts = await SmartVideoFacts.read(url: input.url, tools: ctx.tools, ctx: ctx)
        var plan = TranscodePlanner.plan(probe: info, mode: opts.mode, capabilities: caps, options: opts, facts: facts)
        if let problem = plan.problems.first { throw ConversionError.message(problem) }
        ctx.log("smart: \(opts.mode.rawValue) -> " + plan.chips.joined(separator: ", "))
        for w in plan.warnings { ctx.log("warning: " + w.en) }

        var warnings = plan.warnings.map(\.text)
        var triedSoftware = false
        while true {
            do {
                let (url, verification) = try await produce(plan: plan, input: input, info: info, opts: opts, caps: caps, ctx: ctx, progress: progress, base: base)
                return SmartTranscodeResult(url: url, plan: plan, verification: verification, warnings: warnings)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard plan.isHardwareEncode, !triedSoftware, let fallback = softwareFallback(info: info, facts: facts, caps: caps, opts: opts) else { throw error }
                ctx.log("hardware encode failed (\(ConversionError.describe(error))); retrying with \(fallback.encoderName ?? "the software encoder")")
                warnings.append(L("The hardware encoder could not finish; the software encoder was used.", "Аппаратный кодировщик не справился; использован программный."))
                triedSoftware = true
                plan = fallback
                progress?.report(0)
            }
        }
    }

    /// The plan the engine would run for `input` (Studio summary, `swamp probe --plan`). Uses MediaProbe; never writes anything.
    static func preview(input: FileItem, options: SmartOptions) async throws -> TranscodePlan {
        let info = try await MediaProbe.probe(input.url)
        let facts = await SmartVideoFacts.read(url: input.url)
        return TranscodePlanner.plan(probe: info, mode: options.mode, capabilities: .current, options: options, facts: facts)
    }

    /// The ffmpeg argv of a plan (one command; golden-tested). Arguments are an array, never a shell string.
    static func command(for plan: TranscodePlan, input: URL, output: URL) -> FFmpegCommand {
        SmartCommandBuilder.command(for: plan, input: input, output: output)
    }

    // MARK: Internals

    private static func produce(plan: TranscodePlan, input: FileItem, info: MediaInfo, opts: SmartOptions, caps: SmartCapabilities, ctx: OperationContext,
                                progress: ProgressSlice?, base: String?) async throws -> (URL, SmartVerification?) {
        let verdict = Locked<SmartVerification?>(nil)
        let ext = SmartContainer.fileExtension(plan.container)
        let url = try await ctx.produceFile(for: input, suffix: opts.mode.title, ext: ext, base: base) { tmp in
            let cmd = SmartCommandBuilder.command(for: plan, input: input.url, output: tmp, capabilities: caps)
            try await withTaskCancellationHandler {
                try await FFmpegRunner.run(cmd, ctx: ctx, totalDuration: plan.sourceDuration, progress: progress)
            } onCancel: {
                hardStop(ctx)
            }
            try ctx.checkCancelled()
            guard FileManager.default.fileExists(atPath: tmp.path), ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw ConversionError.noOutput
            }
            guard ctx.outputRules.verify else { return }
            let tolerance = max(0.5, (plan.sourceDuration ?? 0) * 0.03)
            let v = await SmartVerifier.verify(output: tmp, against: plan, source: info, durationTolerance: tolerance)
            ctx.log("verify (\(v.judge)): " + (v.passed ? "ok, \(v.readableFrames) frames decoded" : v.problems.joined(separator: "; ")))
            guard v.passed else {
                let list = v.problems.isEmpty ? "not playable" : v.problems.joined(separator: "; ")
                throw ConversionError.message(L10n("The result did not pass the playback check (\(list)).", "Результат не прошёл проверку воспроизведения (\(list))."))
            }
            verdict.value = v
        }
        return (url, verdict.value)
    }

    /// ffmpeg answers the first SIGTERM by finishing the encode in an orderly way: it flushes the encoder, which takes seconds with libx265 (1.3 s
    /// medium, 3.3 s slow measured) and would break the 200 ms cancel budget. Four signals make it exit at once (its own "hard exiting" rule), and the
    /// half-written file is a hidden temp that `produceFile` removes anyway. Only this job's processes are touched.
    static func hardStop(_ ctx: OperationContext) {
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<4 {
                ctx.processes.cancelAll()
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    /// Same job with the hardware encoders switched off; nil when there is no software encoder either.
    static func softwareFallback(info: MediaInfo, facts: SmartVideoFacts, caps: SmartCapabilities, opts: SmartOptions) -> TranscodePlan? {
        var c = caps
        c.hevcHardware = false
        c.h264Hardware = false
        let p = TranscodePlanner.plan(probe: info, mode: opts.mode, capabilities: c, options: opts, facts: facts)
        return p.problems.isEmpty && !p.isHardwareEncode ? p : nil
    }
}
