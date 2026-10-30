import Foundation

// Picture: orientation, crop, size, borders, frame rate and the filters of spec/handbrake.md 2.4 / 2.5, first as a typed plan
// (also read by the AVFoundation route), then as the ffmpeg filter chain in the documented fixed order:
// tone-map, deinterlace, IVTC, SAR, crop, rotate / flip, deblock, denoise, chroma, deband, scale, sharpen, pad, colour,
// stabilise, reverse, speed, fps, [overlays], fades.

extension VideoPlanner {
    static let limitBoxes: [String: (Int, Int)] = ["2160p": (3840, 2160), "1440p": (2560, 1440), "1080p": (1920, 1080), "720p": (1280, 720),
                                                  "576p": (1024, 576), "540p": (960, 540), "480p": (854, 480), "360p": (640, 360)]

    func even(_ v: Int) -> Int { max(2, (v / 2) * 2) }
    func roundTo(_ v: Double, _ m: Int) -> Int { max(m, Int((v / Double(m)).rounded(.down)) * m) }

    mutating func planPicture() {
        var p = VideoPicturePlan()
        p.speed = plan.picture.speed
        let respect = !(o.isActive(VideoKeys.respectMeta) && !o.b(VideoKeys.respectMeta))
        var dims: (w: Int, h: Int)? = respect ? sv?.rotatedSize.map { ($0.width, $0.height) } : (sv.flatMap { s in s.width.flatMap { w in s.height.map { (w, $0) } } })
        let m = max(2, Int(o.s(VideoKeys.sizeModulus)) ?? 2)
        p.modulus = m
        p.scaler = o.s(VideoKeys.sizeScaler).isEmpty ? "lanczos" : o.s(VideoKeys.sizeScaler)

        // Non-square pixels become square (the default; "keep" leaves them).
        if let v = sv, abs(v.sar - 1) > 0.005, o.s(VideoKeys.sizePar) != "keep", var d = dims {
            p.applySAR = true
            let rot = respect && (v.rotation == 90 || v.rotation == 270)
            let stored = (w: v.width ?? d.w, h: v.height ?? d.h)
            let w2 = Int((Double(stored.w) * v.sar / 2).rounded(.down)) * 2
            d = rot ? (stored.h, w2) : (w2, stored.h)
            dims = d
        }

        // HDR -> SDR (only with a capable ffmpeg).
        // Deinterlace / IVTC.
        let deint = o.s(VideoKeys.deinterlace)
        let interlaced = an.interlaced ?? sv?.interlaced ?? false
        if deint == "on" || (deint == "auto" && interlaced) {
            p.deinterlace = o.s(VideoKeys.deintMethod).isEmpty ? "bwdif" : o.s(VideoKeys.deintMethod)
            p.deinterlaceFields = o.s(VideoKeys.deintRate) == "field"
        }
        p.ivtc = o.s(VideoKeys.ivtc) == "auto"

        // Crop (display pixels).
        switch o.s(VideoKeys.cropMode) {
        case "custom":
            let l = o.i(VideoKeys.cropLeft), r = o.i(VideoKeys.cropRight), t = o.i(VideoKeys.cropTop), b = o.i(VideoKeys.cropBottom)
            if let d = dims, l + r > 0 || t + b > 0, l + r < d.w - 16, t + b < d.h - 16 {
                let x = (l / 2) * 2, y = (t / 2) * 2
                p.crop = .init(x: x, y: y, w: even(d.w - x - (r / 2) * 2), h: even(d.h - y - (b / 2) * 2))
            } else if dims == nil, l + r + t + b > 0 {
                p.crop = .init(x: l, y: t, w: -(l + r), h: -(t + b))   // negative = relative to iw / ih (unknown source size)
            }
        case "auto":
            if let c = an.crop, let d = dims, c.w < d.w || c.h < d.h { p.crop = c }
        default: break
        }
        if let c = p.crop, c.w > 0 { dims = (c.w, c.h) }

        // Rotate / flip.
        let rot = o.i(VideoKeys.rotate)
        p.rotate = [0, 90, 180, 270].contains(rot) ? rot : 0
        p.flipH = o.b(VideoKeys.flipH); p.flipV = o.b(VideoKeys.flipV)
        if p.rotate == 90 || p.rotate == 270, let d = dims { dims = (d.h, d.w) }

        // Clean-up filters.
        let deb = o.s(VideoKeys.deblock); p.deblock = deb == "weak" || deb == "strong" ? deb : nil
        p.denoise = ["light": 1, "medium": 2, "strong": 3][o.s(VideoKeys.denoise)] ?? 0
        p.denoiseMethod = o.s(VideoKeys.denoiseMethod).isEmpty ? "hqdn3d" : o.s(VideoKeys.denoiseMethod)
        p.chromaSmooth = ["light": 1, "medium": 2, "strong": 3][o.s(VideoKeys.chromaSmooth)] ?? 0
        p.deband = o.b(VideoKeys.deband)

        // Size.
        let mode = o.s(VideoKeys.sizeMode).isEmpty ? "source" : o.s(VideoKeys.sizeMode)
        let upscale = o.b(VideoKeys.sizeUpscale)
        p.anchor = o.s(VideoKeys.sizeAnchor).isEmpty ? "center" : o.s(VideoKeys.sizeAnchor)
        if p.anchor == "smart", let c = an.subjectCenter { p.anchorPoint = (c.x, c.y) }
        let boxW = o.i(VideoKeys.sizeW), boxH = o.i(VideoKeys.sizeH)
        switch mode {
        case "limit":
            var box = Self.limitBoxes[o.s(VideoKeys.sizeLimit)]
            if box == nil, boxW > 0 || boxH > 0 { box = (boxW > 0 ? boxW : 99_999, boxH > 0 ? boxH : 99_999) }
            if let bx = box, let d = dims {
                let landscape = d.w >= d.h
                let W = landscape ? bx.0 : bx.1, H = landscape ? bx.1 : bx.0
                var f = min(Double(W) / Double(d.w), Double(H) / Double(d.h))
                if !upscale { f = min(f, 1) }
                if abs(f - 1) > 0.0005 {
                    let nw = roundTo(Double(d.w) * f, m), nh = roundTo(Double(d.h) * f, m)
                    if nw != d.w || nh != d.h { p.scale = (nw, nh); dims = (nw, nh) }
                }
            }
        case "exact":
            if boxW > 0 || boxH > 0 {
                var nw = boxW, nh = boxH
                if let d = dims {
                    if nw == 0 { nw = roundTo(Double(d.w) * Double(nh) / Double(d.h), m) }
                    if nh == 0 { nh = roundTo(Double(d.h) * Double(nw) / Double(d.w), m) }
                }
                if nw > 0 && nh > 0 { p.scale = (nw, nh); dims = (nw, nh) }
            }
        case "percent":
            let pct = max(10, min(200, o.d(VideoKeys.sizePercent, 50))) / 100
            if let d = dims, abs(pct - 1) > 0.001 {
                let nw = roundTo(Double(d.w) * pct, m), nh = roundTo(Double(d.h) * pct, m)
                p.scale = (nw, nh); dims = (nw, nh)
            }
        case "fill":
            if boxW > 0, boxH > 0 { p.scale = (boxW, boxH); p.scaleCover = true; dims = (boxW, boxH) }
        case "fit":
            if boxW > 0, boxH > 0 {
                p.padCanvas = (boxW, boxH)
                if let d = dims {
                    var f = min(Double(boxW) / Double(d.w), Double(boxH) / Double(d.h))
                    if !upscale { f = min(f, 1) }
                    let nw = min(boxW, roundTo(Double(d.w) * f, 2)), nh = min(boxH, roundTo(Double(d.h) * f, 2))
                    if nw != d.w || nh != d.h { p.scale = (nw, nh) }
                }
                dims = (boxW, boxH)
            }
        default: break
        }

        // Borders.
        let padMode = o.s(VideoKeys.padMode)
        p.padColor = o.s(VideoKeys.padColor).isEmpty ? "#000000" : o.s(VideoKeys.padColor)
        if p.padCanvas != nil {
            p.pad = ["bars", "blur"].contains(padMode) ? padMode : "bars"
        } else if padMode == "border" {
            let t = o.i(VideoKeys.padTop), b = o.i(VideoKeys.padBottom), l = o.i(VideoKeys.padLeft), r = o.i(VideoKeys.padRight)
            if t + b + l + r > 0 {
                p.pad = "border"; p.padBorder = (t, b, l, r)
                if let d = dims { dims = (d.w + l + r, d.h + t + b) }
            }
        }

        // Enhance, colour, time.
        p.sharpen = ["light": 1, "medium": 2, "strong": 3][o.s(VideoKeys.sharpen)] ?? 0
        p.sharpenMethod = o.s(VideoKeys.sharpenMethod).isEmpty ? "unsharp" : o.s(VideoKeys.sharpenMethod)
        p.gray = o.b(VideoKeys.gray)
        p.brightness = o.d(VideoKeys.eqBrightness, 0)
        p.contrast = o.isActive(VideoKeys.eqContrast) ? o.d(VideoKeys.eqContrast, 1) : 1
        p.saturation = o.isActive(VideoKeys.eqSaturation) ? o.d(VideoKeys.eqSaturation, 1) : 1
        p.gamma = o.isActive(VideoKeys.eqGamma) ? o.d(VideoKeys.eqGamma, 1) : 1
        let temp = o.i(VideoKeys.colorTemp, 6500)
        p.colorTemp = o.isActive(VideoKeys.colorTemp) && temp != 6500 ? temp : nil
        p.stabilize = o.b(VideoKeys.stabilize)
        p.reverse = o.b(VideoKeys.reverse) && (plan.outputDuration ?? 0) <= 120
        p.fadeIn = max(0, o.d(VideoKeys.fadeIn)); p.fadeOut = max(0, o.d(VideoKeys.fadeOut))
        p.fpsInterp = o.s(VideoKeys.fpsInterp).isEmpty ? "drop" : o.s(VideoKeys.fpsInterp)
        p.outputSize = dims

        // Frame rate.
        let nominal = Double(o.s(VideoKeys.fps)) ?? 30
        let fpsMode = o.s(VideoKeys.fpsMode)
        plan.fpsMode = "vfr"
        switch fpsMode {
        case "constant":
            p.fps = nominal; plan.fpsMode = "cfr"
            if let v = sv?.fps, nominal < v - 0.5 {
                note("The frame rate is lowered from \(MediaSourceMapper.fpsText(v)) to \(MediaSourceMapper.fpsText(nominal)) fps.", "Частота кадров снижается с \(MediaSourceMapper.fpsText(v)) до \(MediaSourceMapper.fpsText(nominal)) к/с.")
            }
        case "peak":
            if let v = sv, let top = v.isVFR ? v.maxFps : v.fps, top > nominal + 0.01 { p.fps = nominal; plan.fpsMode = "cfr" }
        default: break
        }
        plan.picture = p
    }

    // MARK: Filter chain

    var needsEvenDimensions: Bool {
        ["libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox", "libsvtav1", "libx264rgb"].contains(plan.videoEncoder)
    }

    mutating func assembleFilters() {
        guard plan.videoCodec != "copy" else { plan.videoFilters = []; return }
        let (pre, post) = Self.filterChain(plan.picture, encoder: plan.videoEncoder, needsEven: needsEvenDimensions, source: sv, outputDuration: plan.outputDuration,
                                           toneMap: toneMapFilters, colorspace: colorspaceFilter, rangeFilter: rangeFilter)
        plan.videoFilters = pre + post
        plan.postOverlayFilterCount = post.count
    }

    var toneMapFilters: [String] {
        guard o.s(VideoKeys.hdr) == "sdr", sv?.isHDR == true, canToneMap else { return [] }
        return ["zscale=t=linear:npl=100", "format=gbrpf32le", "zscale=p=bt709", "tonemap=tonemap=hable:desat=0", "zscale=t=bt709:m=bt709:r=tv", "format=yuv420p"]
    }

    var colorspaceFilter: String? {
        let cs = o.s(VideoKeys.colorspace)
        guard !cs.isEmpty, cs != "auto", sv?.isHDR != true, tools.hasFilter("colorspace") || !tools.hasFFmpeg else { return nil }
        let target = ["bt709": "bt709", "bt601": "bt601-6-625", "bt2020": "bt2020"][cs] ?? "bt709"
        let srcSpace = sv?.colorSpace ?? ""
        let input: String
        switch srcSpace {
        case "bt709": input = "bt709"
        case "smpte170m": input = "smpte170m"
        case "bt470bg": input = "bt470bg"
        case "bt2020nc", "bt2020_ncl": input = "bt2020"
        default: input = (sv?.height ?? 1080) <= 576 ? "bt470bg" : "bt709"
        }
        let targetTag = cs == "bt601" ? "bt470bg" : cs
        if input == targetTag { return nil }
        return "colorspace=all=\(cs == "bt601" ? "bt470bg" : target):iall=\(input)"
    }

    var rangeFilter: String? {
        switch o.s(VideoKeys.colorRange) {
        case "limited": return "scale=out_range=limited"
        case "full": return "scale=out_range=full"
        default: return nil
        }
    }

    /// The pure chain builder: typed picture -> (filters before the overlays, filters after them). Unit-tested table-driven.
    static func filterChain(_ p: VideoPicturePlan, encoder: String, needsEven: Bool, source: MediaStreamInfo?, outputDuration: Double?,
                            toneMap: [String] = [], colorspace: String? = nil, rangeFilter: String? = nil) -> (pre: [String], post: [String]) {
        var f: [String] = toneMap
        if let d = p.deinterlace {
            let mode = p.deinterlaceFields ? "send_field" : "send_frame"
            switch d {
            case "yadif": f.append("yadif=mode=\(mode):parity=auto:deint=interlaced")
            case "w3fdif": f.append("w3fdif=filter=complex:mode=\(p.deinterlaceFields ? "field" : "frame"):parity=auto:deint=interlaced")
            default: f.append("bwdif=mode=\(mode):parity=auto:deint=interlaced")
            }
        }
        if p.ivtc { f += ["fieldmatch=order=auto:mode=pc", "yadif=deint=interlaced", "decimate"] }
        if p.applySAR { f += ["scale=trunc(iw*sar/2)*2:ih", "setsar=1"] }
        if let c = p.crop {
            if c.w > 0 { f.append("crop=\(c.w):\(c.h):\(c.x):\(c.y)") }
            else { f.append("crop=iw-\(-c.w):ih-\(-c.h):\(c.x):\(c.y)") }
        }
        switch p.rotate {
        case 90: f.append("transpose=1")
        case 270: f.append("transpose=2")
        case 180: f += ["hflip", "vflip"]
        default: break
        }
        if p.flipH { f.append("hflip") }
        if p.flipV { f.append("vflip") }
        if let d = p.deblock { f.append("deblock=filter=\(d)") }
        if p.denoise > 0 {
            switch p.denoiseMethod {
            case "nlmeans": f.append("nlmeans=s=\(["1.5", "3.0", "6.0"][p.denoise - 1]):p=7:r=15")
            case "atadenoise": f.append("atadenoise=0a=\(["0.02", "0.04", "0.08"][p.denoise - 1]):0b=\(["0.04", "0.08", "0.16"][p.denoise - 1])")
            default: f.append("hqdn3d=\(["2:1.5:3:3", "4:3:6:4.5", "8:6:9:7"][p.denoise - 1])")
            }
        }
        if p.chromaSmooth > 0 { f.append("unsharp=luma_amount=0:chroma_msize_x=7:chroma_msize_y=7:chroma_amount=\(["-0.6", "-1.2", "-2.0"][p.chromaSmooth - 1])") }
        if p.deband { f.append("gradfun=strength=1.2:radius=16") }
        if let s = p.scale {
            if p.scaleCover {
                f.append("scale=\(s.w):\(s.h):force_original_aspect_ratio=increase:flags=\(p.scaler)")
                f.append(cropToCanvas(s, p))
            } else {
                f.append("scale=\(s.w):\(s.h):flags=\(p.scaler)")
            }
        }
        if needsEven { f.append("scale=trunc(iw/2)*2:trunc(ih/2)*2") }
        if p.sharpen > 0 {
            if p.sharpenMethod == "cas" { f.append("cas=strength=\(["0.2", "0.4", "0.7"][p.sharpen - 1])") }
            else { f.append("unsharp=luma_msize_x=7:luma_msize_y=7:luma_amount=\(["0.25", "0.5", "1.0"][p.sharpen - 1])") }
        }
        if let canvas = p.padCanvas, let kind = p.pad {
            if kind == "blur" {
                f.append("split[a][b];[a]scale=\(canvas.w):\(canvas.h):force_original_aspect_ratio=increase,crop=\(canvas.w):\(canvas.h),boxblur=30:5[bg];[bg][b]overlay=(W-w)/2:(H-h)/2")
            } else {
                f.append("pad=\(canvas.w):\(canvas.h):(ow-iw)/2:(oh-ih)/2:\(ffColor(p.padColor))")
            }
        } else if p.pad == "border", let b = p.padBorder {
            f.append("pad=iw+\(b.l + b.r):ih+\(b.t + b.b):\(b.l):\(b.t):\(ffColor(p.padColor))")
        }
        if let cs = colorspace { f.append(cs) }
        if abs(p.brightness) > 0.0005 || abs(p.contrast - 1) > 0.0005 || abs(p.saturation - 1) > 0.0005 || abs(p.gamma - 1) > 0.0005 {
            var parts: [String] = []
            if abs(p.brightness) > 0.0005 { parts.append("brightness=\(VideoPlanner.num(p.brightness))") }
            if abs(p.contrast - 1) > 0.0005 { parts.append("contrast=\(VideoPlanner.num(p.contrast))") }
            if abs(p.saturation - 1) > 0.0005 { parts.append("saturation=\(VideoPlanner.num(p.saturation))") }
            if abs(p.gamma - 1) > 0.0005 { parts.append("gamma=\(VideoPlanner.num(p.gamma))") }
            f.append("eq=" + parts.joined(separator: ":"))
        }
        if p.gray { f.append("hue=s=0") }
        if let k = p.colorTemp { f.append("colortemperature=temperature=\(k)") }
        if p.stabilize { f.append("deshake") }
        if let r = rangeFilter { f.append(r) }
        if p.reverse { f.append("reverse") }
        if abs(p.speed - 1) > 0.0005 { f.append("setpts=PTS/\(VideoPlanner.num(p.speed))") }
        if let fps = p.fps {
            switch p.fpsInterp {
            case "blend": f.append("framerate=fps=\(VideoPlanner.rate(fps))")
            case "motion": f.append("minterpolate=fps=\(VideoPlanner.rate(fps)):mi_mode=mci")
            default: f.append("fps=\(VideoPlanner.rate(fps))")
            }
        }
        var post: [String] = []
        if p.fadeIn > 0 { post.append("fade=t=in:st=0:d=\(VideoPlanner.num(p.fadeIn))") }
        if p.fadeOut > 0, let dur = outputDuration, dur > p.fadeOut { post.append("fade=t=out:st=\(VideoPlanner.num(dur - p.fadeOut)):d=\(VideoPlanner.num(p.fadeOut))") }
        return (f, post)
    }

    static func cropToCanvas(_ s: (w: Int, h: Int), _ p: VideoPicturePlan) -> String {
        let x: String, y: String
        if let pt = p.anchorPoint, p.anchor == "smart" {
            // Centre the crop window on the subject, clamped to the picture.
            x = "max(0,min(iw-\(s.w),iw*\(VideoPlanner.num(pt.x))-\(s.w)/2))"
            y = "max(0,min(ih-\(s.h),ih*\(VideoPlanner.num(pt.y))-\(s.h)/2))"
        } else {
            switch p.anchor {
            case "top": x = "(iw-\(s.w))/2"; y = "0"
            case "bottom": x = "(iw-\(s.w))/2"; y = "ih-\(s.h)"
            case "left": x = "0"; y = "(ih-\(s.h))/2"
            case "right": x = "iw-\(s.w)"; y = "(ih-\(s.h))/2"
            default: x = "(iw-\(s.w))/2"; y = "(ih-\(s.h))/2"
            }
        }
        return "crop=\(s.w):\(s.h):\(x):\(y)"
    }

    /// "#RRGGBB" -> "0xRRGGBB".
    static func ffColor(_ hex: String) -> String {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return "0x" + (h.count == 6 ? h.uppercased() : "000000")
    }

    /// Frame rates as ffmpeg wants them: the NTSC family as exact fractions (29.97 -> 30000/1001), everything else as a plain number.
    static func rate(_ f: Double) -> String {
        for (nominal, text) in [(23.976, "24000/1001"), (29.97, "30000/1001"), (47.952, "48000/1001"), (59.94, "60000/1001"), (119.88, "120000/1001")] where abs(f - nominal) < 0.0051 { return text }
        return num(f)
    }

    /// Compact number: 2 -> "2", 0.5 -> "0.5", 1.25 -> "1.25" (never exponent notation).
    static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
