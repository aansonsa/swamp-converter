import Foundation

// Runs ffmpeg for audio: progress from `-progress pipe:1`, friendly errors, two-pass loudness. The command lines come from AudFFmpegArgs.
// The process is started through `ctx.runTool`, so pause, cancel (<= 200 ms, the whole process tree) and the log are handled by Core.

/// Progress of one step as a plain closure, so steps can be nested ("measure" 0...0.35, "encode" 0.35...1).
struct AudProgress: Sendable {
    private let sink: @Sendable (Double) -> Void
    init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }
    init(_ slice: ProgressSlice) { sink = { slice.report($0) } }
    func report(_ fraction: Double) { sink(min(1, max(0, fraction))) }
    /// Never reports less than it already did (a second encode of a size-limit run must not send the bar backwards).
    func monotonic() -> AudProgress { let high = Locked<Double>(0); let s = sink; return AudProgress { f in if f > high.value { high.value = f; s(f) } } }
    /// Progress `f` of the inner step becomes `from + (to - from) * f` of this one.
    func scaled(_ from: Double, _ to: Double) -> AudProgress { let s = sink; return AudProgress { s(from + (to - from) * $0) } }
}

enum AudFFmpegEngine {
    /// Runs one ffmpeg invocation and returns its stderr lines. `duration` is the expected length of the OUTPUT in seconds.
    @discardableResult
    static func run(_ args: [String], ctx: OperationContext, duration: Double?, input: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        let errLines = Locked<[String]>([])
        let last = Locked<Double>(-1)
        do {
            try await ctx.runTool(.ffmpeg, args, onStdoutLine: { line in
                guard let d = duration, d > 0, let t = AudFFmpegArgs.parseProgressSeconds(line) else { return }
                let f = min(0.99, max(0, t / d))
                if f - last.value >= 0.005 { last.value = f; progress(f) }
            }, onStderrLine: { line in
                errLines.withLock { if $0.count < 400 { $0.append(line) } }
            })
        } catch let error as ConversionError {
            throw map(error, stderr: errLines.value, input: input)
        }
        return errLines.value
    }

    /// Maps known ffmpeg complaints onto calm messages.
    static func map(_ error: ConversionError, stderr: [String], input: URL) -> Error {
        guard case .toolFailed = error else { return error }
        let text = stderr.joined(separator: "\n")
        if text.contains("matches no streams") || text.contains("does not contain any stream") { return ConversionError.noAudioTrack }
        if text.contains("Invalid data found when processing input") { return ConversionError.fileUnreadable(input) }
        if text.contains("No space left on device") {
            return ConversionError.message(L10n("There is not enough free space for the result.", "Не хватает свободного места для результата."))
        }
        if text.range(of: "Encoder .* not found", options: .regularExpression) != nil || text.contains("Unknown encoder") {
            return ConversionError.unsupported(L10n("This ffmpeg cannot write that format. Install a full build: brew install ffmpeg", "Этот ffmpeg не умеет писать такой формат. Установите полную сборку: brew install ffmpeg"))
        }
        if text.contains("Permission denied") {
            return ConversionError.message(L10n("The output folder is not writable. Choose another folder in Settings.", "В папку результата нельзя записать. Выберите другую папку в настройках."))
        }
        return error
    }

    /// One complete encode: optional measuring pass, then the real run. Progress goes 0...1 across both passes.
    static func transcode(input: URL, output: URL, plan: AudPlan, info: AudInfo?, env: AudEnvironment, cover: URL?, kbpsOverride: Int? = nil,
                          ctx: OperationContext, progress: AudProgress) async throws {
        var job = AudFFmpegJob(input: input, output: output, plan: plan, info: info, env: env, coverInput: cover, measurement: nil, kbpsOverride: kbpsOverride)
        let outDuration = plan.outputDuration(sourceDuration: info?.duration)
        var share = 0.0
        if let norm = plan.norm, norm.kind == .peak || norm.twoPass {
            share = 0.35
            let preDuration = outDuration, measureShare = share
            let lines = try await run(AudFFmpegArgs.measurement(job), ctx: ctx, duration: preDuration, input: input) { progress.report($0 * measureShare) }
            switch norm.kind {
            case .peak:
                if let maxVolume = AudFFmpegArgs.parseMaxVolume(lines) { job.measurement = AudMeasurement(peakGainDB: norm.level - maxVolume) }
                else { ctx.log("Peak level could not be measured; the volume was not changed.") }
            case .loudness:
                if let m = AudFFmpegArgs.parseLoudnorm(lines) { job.measurement = m }
                else {
                    ctx.log("Loudness could not be measured (silent sound?); using a single pass.")
                    job.plan.norm?.twoPass = false
                }
            }
        }
        let base = share
        _ = try await run(AudFFmpegArgs.transcode(job), ctx: ctx, duration: outDuration, input: input) { progress.report(base + (1 - base) * $0) }
        progress.report(1)
    }
}
