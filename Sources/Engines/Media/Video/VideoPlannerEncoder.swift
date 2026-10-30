import Foundation

// The encoder argument list: preset / speed, rate control, profile, level, tune, key frames, B-frames, references, film grain,
// validated extra parameters, colour tags, Apple's hvc1 tag (spec/handbrake.md 2.3). The result goes to `plan.encoderOptions`.

extension VideoPlanner {
    /// "k=v:k=v" with unknown shapes dropped (the Studio field is validated; this protects the command line).
    static func sanitizeExtra(_ text: String) -> [String] {
        text.split(separator: ":").compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, kv[0].range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  kv[1].range(of: #"^[^\s:=]+$"#, options: .regularExpression) != nil else { return nil }
            return "\(kv[0])=\(kv[1])"
        }
    }

    static func fmtNumber(_ v: Double) -> String { num(v) }

    mutating func buildEncoderOptions() {
        let codec = plan.videoCodec
        guard codec != "copy" else { return }
        let enc = plan.videoEncoder
        let container = plan.container
        var a: [String] = []
        let stop = o.s(VideoKeys.speed).isEmpty ? "medium" : o.s(VideoKeys.speed)
        let idx = VideoCodecTables.stopIndex(stop)
        let stopName = VideoCodecTables.stops.contains(stop) ? stop : "medium"
        let fps = plan.picture.fps ?? sv?.fps ?? 30
        let keyint = o.d(VideoKeys.keyint)
        let gop = keyint > 0 ? max(1, Int((keyint * fps).rounded())) : 0
        let bframes = o.isActive(VideoKeys.bframes) && o.has(VideoKeys.bframes) ? o.i(VideoKeys.bframes, -1) : -1
        let refs = o.i(VideoKeys.refs)
        let extra = Self.sanitizeExtra(o.s(VideoKeys.extra))
        let tune = o.s(VideoKeys.tune)
        let profile = o.s(VideoKeys.profile)
        let level = o.s(VideoKeys.level)
        let maxrate = o.i(VideoKeys.vbvMaxrate)
        let appleTag = o.b(VideoKeys.appleTag) && ["mp4", "mov"].contains(container)
        let slowFirst = !o.b(VideoKeys.turbo1) && plan.passes == 2

        func rate(crfName: String = "-crf") -> [String] {
            switch plan.rate {
            case .quality(let q): return [crfName, Self.num(q)]
            case .bitrate(let k): return ["-b:v", "\(k)k"]
            case .lossless: return [crfName, "0"]
            case .none: return []
            }
        }
        func vbv() -> [String] { maxrate > 0 ? ["-maxrate", "\(maxrate)k", "-bufsize", "\(o.i(VideoKeys.vbvBuffer) > 0 ? o.i(VideoKeys.vbvBuffer) : maxrate * 2)k"] : [] }

        switch enc {
        case "libx264":
            a += ["-c:v", "libx264", "-preset", stopName] + rate()
            if let p = x264Profile(profile) { a += ["-profile:v", p] }
            if !level.isEmpty, level != "auto" { a += ["-level", level] }
            if VideoCodecTables.x264Tunes.contains(tune) { a += ["-tune", tune] }
            a += vbv()
            if gop > 0 { a += ["-g", "\(gop)", "-flags", "+cgop"] }
            if bframes >= 0 { a += ["-bf", "\(bframes)"] }
            if refs > 0 { a += ["-refs", "\(refs)"] }
            var params = extra
            if slowFirst { params.append("slow-firstpass=1") }
            if !params.isEmpty { a += ["-x264-params", params.joined(separator: ":")] }
        case "libx265":
            a += ["-c:v", "libx265", "-preset", stopName]
            if plan.rate == .lossless { a += [] } else { a += rate() }
            if let p = x265Profile(profile) { a += ["-profile:v", p] }
            if VideoCodecTables.x265Tunes.contains(tune) { a += ["-tune", tune] }
            a += vbv()
            var params = ["log-level=error"]
            if plan.rate == .lossless { params.append("lossless=1") }
            if gop > 0 { params.append("keyint=\(gop)") }
            if bframes >= 0 { params.append("bframes=\(bframes)") }
            if refs > 0 { params.append("ref=\(refs)") }
            if !level.isEmpty, level != "auto", let n = Double(level) { params.append("level-idc=\(Int((n * 10).rounded()))") }
            if wantsHDRKeep { params.append("repeat-headers=1") }
            if slowFirst { params.append("slow-firstpass=1") }
            params += extra
            a += ["-x265-params", params.joined(separator: ":")]
            if gop > 0 { a += ["-flags", "+cgop"] }
        case "libsvtav1":
            a += ["-c:v", "libsvtav1", "-preset", "\(VideoCodecTables.av1Presets[idx])"] + rate()
            var params: [String] = []
            if let t = VideoCodecTables.av1Tunes[tune] { params.append("tune=\(t)") }
            let grain = o.i(VideoKeys.filmgrain)
            if grain > 0 { params += ["film-grain=\(grain)", "film-grain-denoise=1"] }
            params += extra
            if !params.isEmpty { a += ["-svtav1-params", params.joined(separator: ":")] }
            if gop > 0 { a += ["-g", "\(gop)"] }
        case "libvpx-vp9":
            a += ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "\(VideoCodecTables.vp9CpuUsed[idx])", "-tile-columns", "2"]
            switch plan.rate {
            case .quality(let q): a += ["-crf", Self.num(q), "-b:v", "0"]
            case .bitrate(let k): a += ["-b:v", "\(k)k"]
            case .lossless: a += ["-lossless", "1"]
            case .none: break
            }
            if ["screen", "film"].contains(tune) { a += ["-tune-content", tune] }
            a += vbv()
            if gop > 0 { a += ["-g", "\(gop)"] }
        case "libvpx":
            a += ["-c:v", "libvpx", "-deadline", "good", "-cpu-used", "\(min(5, VideoCodecTables.vp9CpuUsed[idx]))"]
            switch plan.rate {
            case .quality(let q): a += ["-crf", Self.num(q), "-b:v", "20M"]
            case .bitrate(let k): a += ["-b:v", "\(k)k"]
            default: break
            }
            if gop > 0 { a += ["-g", "\(gop)"] }
        case "mpeg4":
            a += ["-c:v", "mpeg4"]
            switch plan.rate {
            case .quality(let q): a += ["-q:v", "\(Int(q))"]
            case .bitrate(let k): a += ["-b:v", "\(k)k"]
            default: a += ["-q:v", "4"]
            }
            if gop > 0 { a += ["-g", "\(gop)"] }
        case "prores_ks":
            a += ["-c:v", "prores_ks", "-profile:v", "\(VideoCodecTables.proresProfileIndex(profile))", "-vendor", "apl0"]
        case "prores_videotoolbox":
            a += ["-c:v", "prores_videotoolbox", "-profile:v", VideoCodecTables.proresProfileName(profile)]
        case "dnxhd":
            a += ["-c:v", "dnxhd", "-profile:v", VideoCodecTables.dnxhrProfile(profile)]
        case "ffv1":
            a += ["-c:v", "ffv1", "-level", "3", "-coder", "1", "-context", "1", "-g", "1", "-slicecrc", "1"]
        case "h264_videotoolbox", "hevc_videotoolbox":
            a += ["-c:v", enc]
            switch plan.rate {
            case .quality(let q): a += ["-q:v", "\(Int(q.rounded()))"]
            case .bitrate(let k): a += ["-b:v", "\(k)k"]
            default: break
            }
            if let p = vtProfile(profile, hevc: enc == "hevc_videotoolbox") { a += ["-profile:v", p] }
            if idx <= 4 { a += ["-prio_speed", "1"] }
            if gop > 0 { a += ["-g", "\(gop)"] }
            if bframes == 0 { a += ["-bf", "0"] } else if bframes > 0 { a += ["-bf", "\(bframes)"] }
            if refs > 0, enc == "hevc_videotoolbox" { a += ["-max_ref_frames", "\(refs)"] }
        default:
            break
        }
        if codec == "hevc", appleTag { a += ["-tag:v", "hvc1"] }
        if let pf = plan.pixelFormat { a += ["-pix_fmt", pf] }
        a += colorTags()
        plan.encoderOptions = a
    }

    func x264Profile(_ p: String) -> String? {
        guard depth <= 8, chromaKey == "4:2:0" else { return ["high10", "high422", "high444"].contains(p) ? p : nil }
        return ["baseline", "main", "high"].contains(p) ? p : nil
    }
    func x265Profile(_ p: String) -> String? {
        ["main", "main10", "main12", "main422-10", "main444-8"].contains(p) ? p : nil
    }
    func vtProfile(_ p: String, hevc: Bool) -> String? {
        if hevc { return ["main", "main10", "main42210"].contains(p) ? p : (depth >= 10 ? "main10" : nil) }
        return ["baseline", "constrained_baseline", "main", "high", "constrained_high", "extended"].contains(p) ? p : nil
    }

    /// Colour tags: kept for HDR sources, written for an explicit matrix choice, `-color_range` for a forced range.
    func colorTags() -> [String] {
        var t: [String] = []
        if wantsHDRKeep, let v = sv {
            t += ["-color_primaries", v.colorPrimaries ?? "bt2020", "-color_trc", v.colorTransfer ?? "smpte2084", "-colorspace", v.colorSpace ?? "bt2020nc", "-color_range", "tv"]
        } else if let cs = colorspaceFilter, sv?.isHDR != true {
            _ = cs
            switch o.s(VideoKeys.colorspace) {
            case "bt709": t += ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
            case "bt601": t += ["-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m"]
            case "bt2020": t += ["-colorspace", "bt2020nc", "-color_primaries", "bt2020", "-color_trc", "bt2020-10"]
            default: break
            }
        } else if o.s(VideoKeys.hdr) == "sdr", !toneMapFilters.isEmpty {
            t += ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
        }
        switch o.s(VideoKeys.colorRange) {
        case "limited": t += ["-color_range", "tv"]
        case "full": t += ["-color_range", "pc"]
        default: break
        }
        return t
    }
}
