import Foundation

// Output size / time estimates and the summary chips of the Studio capsule (spec/handbrake.md 2.14, 6.5). Pure arithmetic over the plan:
// fixed-bitrate modes are exact within a couple of percent; constant-quality sizes are a heuristic (bits per pixel per frame, capped by the
// source bitrate) and are labelled "rough". Nothing here encodes or touches the disk.

enum VideoEstimator {
    /// Bits per pixel per frame of live-action H.264 at CRF 22 (spec: ~0.09 - 0.10).
    static let baseBPP = 0.09

    /// The H.264-CRF-equivalent of a native quality value, used to scale `baseBPP` ("each +6 CRF halves the size").
    static func crfEquivalent(plan: VideoEncodePlan, quality q: Double) -> Double {
        if plan.hardware { return 22 + (58 - q) / 2.5 }                       // VideoToolbox: higher = better
        switch plan.videoCodec {
        case "hevc": return q - 2
        case "av1", "vp9": return q - 10
        case "mpeg4": return 22 + (4 - q) * 3
        default: return q
        }
    }

    /// Efficiency of the codec relative to H.264 at the same visual quality (spec 2.14).
    static func codecFactor(_ codec: String) -> Double {
        ["hevc": 0.6, "vp9": 0.65, "av1": 0.5, "mpeg4": 1.6, "vp8": 1.2][codec] ?? 1.0
    }

    static func proresMbps(_ profile: String, w: Int, h: Int, fps: Double) -> Double {
        let base: Double = ["proxy": 45, "lt": 102, "standard": 147, "hq": 220, "4444": 330, "xq": 500][profile] ?? 220
        return base * Double(w * h) / (1920 * 1080) * fps / 30
    }

    /// Video bitrate in kbit/s the plan produces (nil when unknown).
    static func videoKbps(plan: VideoEncodePlan, info: MediaInfo, profile: String) -> Double? {
        let size = plan.picture.outputSize ?? info.primaryVideo?.displaySize.map { ($0.width, $0.height) }
        guard let (w, h) = size else { return nil }
        let fps = plan.picture.fps ?? info.primaryVideo?.fps ?? 30
        let speed = max(plan.picture.speed, 0.25)
        let srcV = info.primaryVideo?.bitRate ?? ((info.bitRate ?? 0) > 0 ? Int(Double(info.bitRate!) * 0.9) : 0)
        switch plan.rate {
        case .bitrate(let k): return Double(k)
        case .none:
            if plan.videoCodec == "copy" { return srcV > 0 ? Double(srcV) / 1000 : nil }
            if plan.videoCodec == "prores" { return proresMbps(profile, w: w, h: h, fps: fps) * 1000 }
            if plan.videoCodec == "dnxhr" { return 180_000 * Double(w * h) / (1920 * 1080) * fps / 30 / 1000 * 1.0 }
            if plan.videoCodec == "ffv1" { return Double(w * h) * fps * 4 / 1000 }
            return nil
        case .lossless: return Double(w * h) * fps * 3.0 / 1000 * codecFactor(plan.videoCodec)
        case .quality(let q):
            let eq = crfEquivalent(plan: plan, quality: q)
            let bpp = baseBPP * pow(2, (22 - eq) / 6) * codecFactor(plan.videoCodec)
            var kbps = bpp * Double(w * h) * fps * speed / 1000
            // Re-encoding never makes a stream much larger than its source at a normal quality.
            if srcV > 0, eq >= 16 { kbps = min(kbps, Double(srcV) / 1000 * 1.1) }
            return max(kbps, 80)
        }
    }

    static func audioKbps(plan: VideoEncodePlan, info: MediaInfo) -> Double {
        plan.audioTracks.reduce(0) { sum, t in
            if t.codec == "copy" { return sum + Double(info.audioStreams.first(where: { $0.index == t.sourceStream })?.bitRate ?? 160_000) / 1000 }
            if let k = t.bitrateKbps { return sum + Double(k) }
            if t.vbr, let q = t.quality { return sum + Double(max(48, 256 - q * 14)) * 0.9 }
            switch t.codec {
            case "flac": return sum + 700
            case "alac": return sum + 800
            case "pcm16": return sum + 1411 * Double(t.channels ?? 2) / 2
            case "pcm24": return sum + 2100 * Double(t.channels ?? 2) / 2
            default: return sum + 160
            }
        }
    }

    static func estimate(options: OptionValues, source: SourceInfo?) -> OperationEstimate? {
        guard let info = VideoSourceBridge.mediaInfo(from: source) else { return nil }
        let r = VideoSourceBridge.resolve(options, source: source)
        guard let plan = try? VideoPlanBuilder.build(options: r, source: info, toolset: MediaToolset.current) else { return nil }
        guard let dur = plan.outputDuration ?? info.duration, dur > 0 else { return nil }
        let o = VOpts(r)
        var bytes: Double
        var confidence = OperationEstimate.Confidence.rough
        if plan.container == "gif", let g = plan.gif {
            let w = Double(g.width), h = (info.primaryVideo?.displaySize).map { w * Double($0.height) / Double(max(1, $0.width)) } ?? w * 0.5625
            bytes = w * h * Double(g.fps) * dur * 0.12 * (Double(g.colors) / 256 * 0.5 + 0.5)
        } else if plan.noVideo {
            bytes = audioKbps(plan: plan, info: info) * 125 * dur
            confidence = plan.audioTracks.first?.vbr == true ? .rough : .sampled
        } else if let v = videoKbps(plan: plan, info: info, profile: o.s(VideoKeys.profile)) {
            bytes = (v + audioKbps(plan: plan, info: info)) * 125 * dur
            if case .bitrate = plan.rate { confidence = .sampled }
            if plan.videoCodec == "copy" { confidence = .sampled }
        } else { return nil }
        bytes *= 1.01
        if let t = plan.targetBytes { bytes = min(bytes, Double(t)) }
        return OperationEstimate(bytes: Int64(bytes), seconds: encodeSeconds(plan: plan, info: info, duration: dur), confidence: confidence,
                                 note: L10n("A rough estimate from the picture size and quality.", "Примерная оценка по размеру кадра и качеству."))
    }

    /// Wall-clock time of the encode: how many times faster than real time the encoder runs at this picture size.
    static func encodeSeconds(plan: VideoEncodePlan, info: MediaInfo, duration: Double) -> Double? {
        if plan.videoCodec == "copy" { return max(1, duration * 0.02) }
        if plan.noVideo { return max(1, duration * 0.02) }
        let size = plan.picture.outputSize ?? info.primaryVideo?.displaySize.map { ($0.width, $0.height) } ?? (1920, 1080)
        let fps = plan.picture.fps ?? info.primaryVideo?.fps ?? 30
        let load = Double(size.0 * size.1) * fps / (1920 * 1080 * 30)
        let base: Double
        if plan.hardware { base = 8 }
        else {
            switch plan.videoEncoder {
            case "libx264": base = 2.5 / (1 + Double(VideoCodecTables.stopIndex(speedKey(plan)) - 5) * 0.35)
            case "libx265": base = 0.9
            case "libsvtav1": base = 1.2
            case "libvpx-vp9": base = 0.5
            default: base = 3
            }
        }
        let passes = Double(max(plan.passes, 1))
        return duration * max(plan.picture.speed, 0.25) * load * passes / max(base, 0.1)
    }

    private static func speedKey(_ plan: VideoEncodePlan) -> String {
        if let i = plan.encoderOptions.firstIndex(of: "-preset"), plan.encoderOptions.indices.contains(i + 1) { return plan.encoderOptions[i + 1] }
        return "medium"
    }

    // MARK: Chips

    static func chips(options: OptionValues, source: SourceInfo?) -> [String] {
        let r = VideoSourceBridge.resolve(options, source: source)
        let info = VideoSourceBridge.mediaInfo(from: source)
        guard let plan = try? VideoPlanBuilder.build(options: r, source: info, toolset: MediaToolset.current) else {
            return [options.string(VideoKeys.container, "mp4").uppercased()]
        }
        var c: [String] = [plan.container.uppercased()]
        if plan.noVideo {
            c.append(plan.audioTracks.first.map { audioChip($0) } ?? "MP3")
            return c
        }
        if plan.container == "gif" {
            if let g = plan.gif { c.append("\(g.width) px"); c.append("\(g.fps) " + L("fps", "к/с")) }
            return c
        }
        c.append(MediaSourceMapper.codecDisplay(plan.videoCodec == "copy" ? (info?.primaryVideo?.codec ?? "copy") : plan.videoCodec) + (plan.videoCodec == "copy" ? " (" + L("copy", "копия") + ")" : ""))
        if let s = plan.picture.outputSize { c.append("\(min(s.w, s.h))p" + ((plan.picture.fps ?? info?.primaryVideo?.fps).map { MediaSourceMapper.fpsText($0) } ?? "")) }
        let t = tokens(plan: plan, info: info, r: r)
        if let q = t["quality"] { c.append(q) }
        if let a = plan.audioTracks.first { c.append(audioChip(a)) } else if plan.audioCodec == "none" { c.append(L("No audio", "Без звука")) }
        return c
    }

    private static func tokens(plan: VideoEncodePlan, info: MediaInfo?, r: ResolvedOptions) -> [String: String] {
        guard let info else { return [:] }
        return VideoJob.tokens(plan: plan, info: info, r: r)
    }

    static func audioChip(_ t: VideoAudioTrackPlan) -> String {
        if t.codec == "copy" { return L("Audio copy", "Звук без перекодирования") }
        let name = t.codec.uppercased()
        if let k = t.bitrateKbps { return "\(name) \(k)k" }
        return name
    }
}
