import Foundation

// The pure half of the video fit: which encoder, and the exact ffmpeg argument list of every pass. Golden-tested without encoding anything.

enum VideoFitEncoder: String, Sendable {
    /// libx264, two passes or single-pass constrained VBR (the precise, portable default).
    case x264
    /// h264_videotoolbox: Apple's hardware encoder (single pass; cooler and faster, its rate control is approximate).
    case vtH264
    /// hevc_videotoolbox: for HDR / 10-bit footage, which keeps its colours only in 10-bit HEVC.
    case vtHevc
    /// libx265 single pass: the same, when no hardware encoder exists.
    case x265

    var isHEVC: Bool { self == .vtHevc || self == .x265 }
    var supportsTwoPass: Bool { self == .x264 }
    /// Measured on this Mac: how far the file lands above the bitrate sum; the planner's bitrate is multiplied by this before encoding.
    var bitrateBias: Double {
        switch self { case .x264: return 1.0; case .vtH264: return 0.975; case .vtHevc: return 0.965; case .x265: return 0.99 }
    }
    var codecEfficiency: Double { isHEVC ? 0.75 : 1.0 }
}

struct VideoFitChoice: Equatable, Sendable {
    var encoder: VideoFitEncoder
    var twoPass: Bool
    var notes: [L10n]
}

enum VideoFitEncoderChoice {
    /// `has` answers `ff.enc.<name>` (injectable for tests). nil when this ffmpeg has no usable encoder at all.
    static func choose(isHDR: Bool, preferHardware: Bool, wantTwoPass: Bool, has: (String) -> Bool) -> VideoFitChoice? {
        var notes: [L10n] = []
        if isHDR {
            if has("hevc_videotoolbox") {
                notes.append(L10n("HDR kept: the clip is written as 10-bit HEVC.", "HDR сохранён: ролик записан как 10-битный HEVC."))
                return VideoFitChoice(encoder: .vtHevc, twoPass: false, notes: notes)
            }
            if has("libx265") {
                notes.append(L10n("HDR kept: the clip is written as 10-bit HEVC.", "HDR сохранён: ролик записан как 10-битный HEVC."))
                return VideoFitChoice(encoder: .x265, twoPass: false, notes: notes)
            }
            notes.append(L10n("This ffmpeg has no HEVC encoder, so HDR colors may look flat.", "В этой сборке ffmpeg нет кодировщика HEVC, поэтому цвета HDR могут выглядеть блёклыми."))
        }
        if preferHardware, has("h264_videotoolbox") { return VideoFitChoice(encoder: .vtH264, twoPass: false, notes: notes) }
        if has("libx264") { return VideoFitChoice(encoder: .x264, twoPass: wantTwoPass, notes: notes) }
        if has("h264_videotoolbox") { return VideoFitChoice(encoder: .vtH264, twoPass: false, notes: notes) }
        return nil
    }
}

/// Everything one ffmpeg run needs. `pass` is nil for a single-pass run, 1 or 2 for the two-pass pair.
struct VideoFitJob: Sendable {
    var input: URL
    var output: URL
    var info: FitVideoInfo
    var plan: VideoFitPlan
    var encoder: VideoFitEncoder
    var videoKbps: Int
    var twoPass: Bool
    var strip: Bool
    var passLog: String

    /// The picture the output will have.
    var outputSize: (width: Int, height: Int) { VideoFitArgs.outputSize(plan: plan, info: info) }
}

enum VideoFitArgs {
    /// Output display size for a plan: the capped height with the width following the aspect ratio, both even.
    static func outputSize(plan: VideoFitPlan, info: FitVideoInfo) -> (width: Int, height: Int) {
        guard let cap = plan.maxHeight, cap < info.height else { return (VideoFit.even(info.width), VideoFit.even(info.height)) }
        return (VideoFit.even(Int((Double(info.width) * Double(cap) / Double(info.height)).rounded())), VideoFit.even(cap))
    }

    /// The ceiling (kbit/s) beyond which more bits show nothing at the output size: retries never ask for more.
    static func ceilingKbps(plan: VideoFitPlan, info: FitVideoInfo, encoder: VideoFitEncoder) -> Int {
        let s = outputSize(plan: plan, info: info)
        let fps = plan.maxFPS ?? info.fps
        return Int((FitTuning.ceilingBitsPerPixel * encoder.codecEfficiency * Double(s.width * s.height) * fps / 1000).rounded(.down))
    }

    /// The arguments after the fixed ffmpeg prefix. Pass 1 of a two-pass run writes nothing (`-f null`) and has no audio.
    static func arguments(_ job: VideoFitJob, pass: Int?) -> [String] {
        let info = job.info, plan = job.plan
        var a = ["-i", job.input.path, "-map", "0:\(info.videoIndex)"]
        if pass != 1, let ai = info.audioIndex { a += ["-map", "0:\(ai)"] }

        var filters: [String] = []
        if let h = plan.maxHeight, h < info.height { filters.append("scale=-2:\(h)") }
        else if info.width % 2 != 0 || info.height % 2 != 0 { filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2") }
        if let fps = plan.maxFPS, fps < info.fps { filters.append("fps=\(Int(fps))") }
        if !filters.isEmpty { a += ["-vf", filters.joined(separator: ",")] }

        let k = max(job.videoKbps, FitTuning.minVideoKbps)
        switch job.encoder {
        case .x264:
            a += ["-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "\(k)k"]
            // The VBV window (peak 1.5 x, buffer 2 x the average) is what keeps x264 on the requested size: measured on this Mac, a very noisy 4 s clip asked
            // for 800 kbit/s came out at 1010 kbit/s in two passes without it (qp ceiling reached) and at 798 kbit/s with it; clean footage lands within 1-5% either way.
            a += ["-maxrate", "\(k * 3 / 2)k", "-bufsize", "\(k * 2)k"]
            if let p = pass { a += ["-pass", "\(p)", "-passlogfile", job.passLog] }
        case .vtH264:
            a += ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "\(k)k"]
        case .vtHevc:
            a += ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-b:v", "\(k)k"]
            a += info.bitDepth > 8 || info.isHDR ? ["-profile:v", "main10", "-pix_fmt", "p010le"] : ["-profile:v", "main", "-pix_fmt", "yuv420p"]
        case .x265:
            a += ["-c:v", "libx265", "-preset", "medium", "-tag:v", "hvc1", "-b:v", "\(k)k", "-x265-params", "log-level=error"]
            a += info.bitDepth > 8 || info.isHDR ? ["-pix_fmt", "yuv420p10le"] : ["-pix_fmt", "yuv420p"]
        }
        if info.isHDR {
            if let p = info.colorPrimaries { a += ["-color_primaries", p] }
            if let t = info.colorTransfer { a += ["-color_trc", t] }
            if let s = info.colorSpace { a += ["-colorspace", s] }
        }

        if pass == 1 || info.audioIndex == nil {
            a += ["-an"]
        } else {
            a += ["-c:a", "aac", "-b:a", "\(plan.audioKbps)k"]
            if plan.audioKbps < 48 { a += ["-ac", "1"] } else if info.audioChannels > 2 { a += ["-ac", "2"] }
        }
        if job.strip { a += ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact"] }
        if pass == 1 { a += ["-f", "null", "/dev/null"] } else { a += ["-movflags", "+faststart", job.output.path] }
        return a
    }
}
