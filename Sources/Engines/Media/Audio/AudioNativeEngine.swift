import Foundation
import AVFoundation

// The native route: decode with AVAudioFile, mix channels, resample, gain / normalise / fade in Swift, encode with AudioToolbox.
// Works without any external tool. Also produces the float32 WAV that external encoders (lame, or ffmpeg after a join) read.

enum AudSinkKind: Sendable { case target, floatWAV }

enum AudNativeEngine {
    /// Fraction of the work spent measuring loudness when the plan normalises.
    static let measureShare = 0.35

    static func run(input: URL, info: AudInfo?, plan: AudPlan, output: URL, sinkKind: AudSinkKind, tags: AudTags?, cover: Data?,
                    ctx: OperationContext, progress: AudProgress) async throws {
        let reader = try AudNativeReader(url: input, start: plan.trimStart, end: plan.trimEnd)
        let inRate = reader.rate, inChannels = reader.channels
        guard reader.rangeFrames > 0 else { throw ConversionError.message(L10n("There is no sound in the chosen range.", "В выбранном фрагменте нет звука.")) }
        var outChannels = plan.channels ?? inChannels
        if sinkKind == .target { outChannels = min(outChannels, plan.target.maxChannels) }
        let outRate = plan.sampleRate ?? inRate
        let measures = plan.norm != nil
        let share = measures ? measureShare : 0

        // Pass 1: loudness / peak of the range as it will be encoded (after the channel mix, before the rate change).
        var totalGainDB = plan.gainDB
        if let norm = plan.norm {
            let meter = AudLoudnessMeter(rate: inRate, channels: outChannels)
            let probe = try AudNativeReader(url: input, start: plan.trimStart, end: plan.trimEnd)
            var chunks = 0
            while let raw = try probe.next() {
                try Task.checkCancellation()
                chunks += 1
                if chunks % 8 == 0 { try await ctx.waitIfPaused() }
                meter.feed(outChannels != inChannels ? AudMix.apply(raw, to: outChannels) : raw)
                progress.report(share * Double(probe.framesRead) / Double(max(probe.rangeFrames, 1)))
            }
            switch norm.kind {
            case .peak:
                totalGainDB = norm.level - meter.peakDB
            case .loudness:
                if let l = meter.integratedLUFS {
                    var g = norm.level - l
                    // Never push the peak past the ceiling: the target is then reached as far as the signal allows.
                    let headroom = norm.truePeak - meter.peakDB
                    if g > headroom {
                        ctx.log("Loudness target limited by the peak ceiling (\(String(format: "%.1f", g)) dB wanted, \(String(format: "%.1f", headroom)) dB possible).")
                        g = headroom
                    }
                    totalGainDB = g
                } else {
                    ctx.log("The sound is too quiet or too short to measure; loudness was not changed.")
                    totalGainDB = plan.gainDB
                }
            }
        }

        // Destination.
        let (sink, work) = try makeSink(plan: plan, kind: sinkKind, output: output, rate: outRate, channels: outChannels, info: info)
        defer { if work != output { try? FileManager.default.removeItem(at: work) } }

        // Pass 2: convert and write.
        let outTotal = Int((Double(reader.rangeFrames) * Double(outRate) / Double(inRate)).rounded())
        let stage = AudGainStage(gain: AudDB.linear(totalGainDB), fadeInFrames: Int((plan.fadeIn * Double(outRate)).rounded()),
                                 fadeOutFrames: Int((plan.fadeOut * Double(outRate)).rounded()), totalFrames: outTotal)
        let resampler = AudResampler(inRate: inRate, outRate: outRate, channels: outChannels)
        // Dither only where bits are really thrown away: 16-bit output from deeper, float, lossy or processed sound (never an untouched 16-bit original).
        let losslessTarget = [AudTarget.wav, .aiff, .caf, .flac, .alac].contains(plan.target)
        let untouched16 = (info?.isLossless ?? false) && !(info?.isFloat ?? true) && (info?.bitDepth ?? 99) <= 16
        let touched = !stage.isIdentity || resampler != nil || outChannels < inChannels      // copying a channel into a second one adds no precision
        let dither: AudDitherStage? = sinkKind == .target && losslessTarget && plan.dither != .none && AudFFmpegArgs.resolvedDepth(plan.bitDepth, info) == 16 && !(untouched16 && !touched)
            ? AudDitherStage(mode: plan.dither) : nil
        var index = 0
        var chunks = 0
        while let raw = try reader.next() {
            try Task.checkCancellation()
            chunks += 1
            if chunks % 8 == 0 { try await ctx.waitIfPaused() }
            var c = outChannels != inChannels ? AudMix.apply(raw, to: outChannels) : raw
            if let resampler { c = try resampler.process(c) }
            stage.apply(&c, start: index)
            dither?.apply(&c)
            index += c.first?.count ?? 0
            try sink.write(c)
            progress.report(share + (1 - share) * Double(reader.framesRead) / Double(max(reader.rangeFrames, 1)) * 0.98)
        }
        if let resampler {
            var tail = try resampler.flush()
            stage.apply(&tail, start: index)
            dither?.apply(&tail)
            try sink.write(tail)
        }
        try sink.close()
        try Task.checkCancellation()

        try await finish(work: work, output: output, plan: plan, kind: sinkKind, tags: tags, cover: cover, ctx: ctx)
        progress.report(1)
    }

    /// The destination writer and the file it writes to (MP4 family targets are written as `.m4a` next to the output, then finished by `finish`).
    static func makeSink(plan: AudPlan, kind: AudSinkKind, output: URL, rate: Int, channels: Int, info: AudInfo?) throws -> (AudNativeSink, URL) {
        switch kind {
        case .floatWAV:
            return (try AudNativeSink(url: output, container: .wav, rate: rate, channels: channels, bits: 32), output)
        case .target:
            let depth = AudFFmpegArgs.resolvedDepth(plan.bitDepth, info)
            switch plan.target {
            case .wav: return (try AudNativeSink(url: output, container: .wav, rate: rate, channels: channels, bits: depth), output)
            case .aiff: return (try AudNativeSink(url: output, container: .aiff, rate: rate, channels: channels, bits: depth >= 24 ? 24 : 16), output)
            default: break
            }
            let work = plan.target.isMP4Family ? output.deletingLastPathComponent().appendingPathComponent(".aud-\(Util.hex8()).part.m4a") : output
            let settings = AudNativeSettings.settings(plan: plan, rate: rate, channels: channels, info: info)
            return (try AudNativeSink(url: work, settings: settings, rate: rate, channels: channels), work)
        }
    }

    /// MP4 family: tags and artwork through the system exporter, no re-encoding; otherwise the work file already is the output.
    static func finish(work: URL, output: URL, plan: AudPlan, kind: AudSinkKind, tags: AudTags?, cover: Data?, ctx: OperationContext) async throws {
        guard kind == .target, plan.target.isMP4Family else { return }
        // Always through the system exporter, even without tags: AVAudioFile leaves a large empty `free` box (about 49 KB) in front of the audio, which the
        // exporter drops without touching a single audio packet. That matters for short files and for size limits.
        do { try await AudMP4Meta.write(source: work, destination: output, tags: tags ?? AudTags(), cover: cover) }
        catch {
            ctx.log("The file could not be tidied (\(error.localizedDescription)); it was kept as written.")
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: work, to: output)
        }
    }
}
