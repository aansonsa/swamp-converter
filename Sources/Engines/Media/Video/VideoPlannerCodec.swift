import Foundation

// Codec, encoder routing, bit depth, rate control and the encoder argument list (spec/handbrake.md 2.1, 2.3, Table 2.3a).

enum VideoCodecTables {
    /// Named encoder-speed stops shared by every codec (`speed`), and their native meaning.
    static let stops = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]
    /// SVT-AV1 preset (0 slowest ... 13 fastest) per stop: fast = 8, balanced = 6, slow = 4 (spec).
    static let av1Presets = [13, 12, 11, 10, 8, 6, 4, 3, 2]
    /// libvpx-vp9 `-cpu-used` (0 slowest ... 8 fastest): fast = 5, balanced = 2, slow = 0 (spec) -> adjusted to 9 stops.
    static let vp9CpuUsed = [8, 7, 6, 5, 4, 2, 1, 0, 0]

    static func stopIndex(_ name: String) -> Int { stops.firstIndex(of: name) ?? 5 }

    static let x264Tunes = ["film", "animation", "grain", "stillimage", "psnr", "ssim", "fastdecode", "zerolatency"]
    static let x265Tunes = ["animation", "grain", "psnr", "ssim", "fastdecode", "zerolatency"]
    static let av1Tunes = ["vq": 0, "psnr": 1, "ssim": 2]

    static func proresProfileName(_ p: String) -> String { ["proxy", "lt", "standard", "hq", "4444", "xq"].contains(p) ? p : "hq" }
    static func proresProfileIndex(_ p: String) -> Int { ["proxy", "lt", "standard", "hq", "4444", "xq"].firstIndex(of: proresProfileName(p)) ?? 3 }
    static func dnxhrProfile(_ p: String) -> String {
        switch p {
        case "lb": return "dnxhr_lb"
        case "sq": return "dnxhr_sq"
        case "hqx": return "dnxhr_hqx"
        case "444": return "dnxhr_444"
        default: return "dnxhr_hq"
        }
    }

    /// CRF-like value (software scale) -> VideoToolbox quality 0...100 (documented fallback when the hardware encoder is chosen automatically).
    static func vtQuality(fromCRF crf: Double) -> Int { Int(max(20, min(95, (65 + (22 - crf) * 2.5).rounded()))) }
    /// CRF-like value -> MPEG-4 part 2 `-q:v` (2...31, lower = better): 23 -> 4.
    static func mpeg4Q(fromCRF crf: Double) -> Int { Int(max(2, min(31, (crf * 0.18).rounded()))) }

    static func pixFmt(chroma: String, depth: Int) -> String {
        let base: String
        switch chroma { case "4:2:2": base = "yuv422p"; case "4:4:4": base = "yuv444p"; default: base = "yuv420p" }
        return depth >= 10 ? base + "\(depth)le" : base
    }
}

extension VideoPlanner {
    // MARK: Codec and encoder

    mutating func planCodec() throws {
        var codec = o.s(VideoKeys.vcodec)
        if codec.isEmpty { codec = "h264" }
        let container = plan.container
        if codec == "copy" || plan.copyTrim {
            // Automatic clean-ups (deinterlace "auto", automatic crop, square pixels) never block a stream copy.
            if o.s(VideoKeys.deinterlace) == "auto" { plan.picture.deinterlace = nil }
            if o.s(VideoKeys.cropMode) == "auto" { plan.picture.crop = nil }
            plan.picture.applySAR = false
        }
        if plan.copyTrim {
            if plan.picture.changesPicture {
                // Filters need decoded pictures: the cut becomes frame-accurate.
                plan.copyTrim = false
                note("Copying cuts at key frames, so the cut is made frame-accurate because filters are on.", "При копировании обрезка идёт по ключевым кадрам, поэтому из-за фильтров обрезка сделана покадровой.")
            } else { codec = "copy" }   // "fast cut": streams are copied between the trim points
        }
        if codec == "copy", let v = sv, !canCopyVideo(v.codec, into: container) {
            note("The \(MediaSourceMapper.codecDisplay(v.codec)) picture cannot be copied into \(container.uppercased()), so it is re-encoded as H.264.",
                 "Картинку \(MediaSourceMapper.codecDisplay(v.codec)) нельзя скопировать в \(container.uppercased()), поэтому она перекодируется в H.264.")
            codec = "h264"; plan.copyTrim = false
        }
        if !MediaCapabilities.containerSupports(container, videoCodec: codec) {
            switch (container, codec) {
            case ("webm", _): throw fail(VideoKeys.vcodec, "WebM can only hold VP8, VP9 or AV1. Choose one of them or switch the container.", "В WebM можно только VP8, VP9 или AV1. Выберите один из них или смените контейнер.")
            case (_, "prores") where container != "mov":
                throw fail(VideoKeys.vcodec, "ProRes belongs in MOV. Switch the container to MOV.", "ProRes сохраняется в MOV. Смените контейнер на MOV.")
            default:
                throw fail(VideoKeys.vcodec, "\(container.uppercased()) cannot hold this video codec. Choose another codec or container.", "\(container.uppercased()) не вмещает этот видеокодек. Выберите другой кодек или контейнер.")
            }
        }
        if codec == "copy", plan.picture.changesPicture || !plan.overlays.isEmpty || o.s(VideoKeys.subMode) == "burn" {
            throw fail(VideoKeys.vcodec, "Copying video can't be combined with filters, resizing or burned-in subtitles. Turn off Copy or remove them.",
                       "Копирование видео нельзя сочетать с фильтрами, изменением размера и вшитыми субтитрами. Отключите «Копировать» или уберите их.")
        }
        plan.videoCodec = codec
        if codec == "copy" {
            plan.videoEncoder = "copy"; plan.rate = .none
            plan.hardware = false
            if o.b(VideoKeys.appleTag) || (sv?.codec == "hevc" && ["mp4", "mov"].contains(container)) { plan.encoderOptions += ["-tag:v", "hvc1"] }
            return
        }
        if !tools.hasFFmpeg { try resolveNativeEncoder(codec); return }
        try resolveFFmpegEncoder(codec)
    }

    func canCopyVideo(_ srcCodec: String, into container: String) -> Bool {
        let c = srcCodec.lowercased()
        let known = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "prores", "ffv1", "dnxhd"]
        guard known.contains(c) else { return false }
        return MediaCapabilities.containerSupports(container, videoCodec: c == "dnxhd" ? "dnxhr" : c)
    }

    /// Desired bit depth and chroma before the encoder is known.
    func desiredDepth(_ codec: String) -> Int {
        switch o.s(VideoKeys.bitdepth) {
        case "8": return 8
        case "10": return 10
        case "12": return 12
        default:
            // A 10-bit or 12-bit profile asks for that depth when the depth itself is left on Auto.
            switch o.s(VideoKeys.profile) {
            case "main10", "high10", "main422-10": if ["h264", "hevc"].contains(codec) { return 10 }
            case "main12": if codec == "hevc" { return 12 }
            default: break
            }
            if codec == "prores" || codec == "dnxhr" { return 10 }
            guard ["hevc", "av1", "vp9"].contains(codec) else { return 8 }
            return ((sv?.bitDepth ?? 8) >= 10 || (sv?.isHDR ?? false)) ? 10 : 8
        }
    }

    var wantsHDRKeep: Bool {
        guard let v = sv, v.isHDR else { return false }
        let h = o.s(VideoKeys.hdr)
        return h.isEmpty || h == "keep" || (h == "sdr" && !canToneMap)
    }
    var canToneMap: Bool { (tools.hasFilter("zscale") && tools.hasFilter("tonemap")) || tools.hasFilter("libplacebo") }

    mutating func resolveFFmpegEncoder(_ codec: String) throws {
        let venc = o.s(VideoKeys.venc).isEmpty ? "auto" : o.s(VideoKeys.venc)
        var depth = desiredDepth(codec)
        if wantsHDRKeep && depth < 10 && codec != "h264" { depth = 10 }
        var chroma = o.s(VideoKeys.chroma).isEmpty ? "4:2:0" : o.s(VideoKeys.chroma)
        // A 4:2:2 or 4:4:4 profile asks for that chroma format when the chroma field is left on 4:2:0.
        if chroma == "4:2:0" {
            switch o.s(VideoKeys.profile) {
            case "high422", "main422-10": chroma = "4:2:2"
            case "high444", "main444-8": chroma = "4:4:4"
            default: break
            }
        }
        let rcValue = o.s(VideoKeys.rateControl)
        let lossless = rcValue == "lossless"
        let abrLike = rcValue == "abr" || rcValue == "size"
        let wantsTwoPass = abrLike && o.b(VideoKeys.twoPass)

        let swName: String?, hwName: String?
        switch codec {
        case "h264": swName = "libx264"; hwName = "h264_videotoolbox"
        case "hevc": swName = "libx265"; hwName = "hevc_videotoolbox"
        case "prores": swName = "prores_ks"; hwName = "prores_videotoolbox"
        case "av1": swName = "libsvtav1"; hwName = nil
        case "vp9": swName = "libvpx-vp9"; hwName = nil
        case "vp8": swName = "libvpx"; hwName = nil
        case "mpeg4": swName = "mpeg4"; hwName = nil
        case "ffv1": swName = "ffv1"; hwName = nil
        case "dnxhr": swName = "dnxhd"; hwName = nil
        default: throw fail(VideoKeys.vcodec, "Unknown video codec \(codec).", "Неизвестный видеокодек \(codec).")
        }
        let hasSW = swName.map { tools.hasEncoder($0) } ?? false
        let hasHW = hwName.map { tools.hasEncoder($0) } ?? false
        // Things a hardware encoder cannot do force the software one.
        var hwBlocked = false
        if codec == "h264" && depth > 8 { hwBlocked = true }
        if codec == "hevc" && (depth > 10 || chroma == "4:4:4") { hwBlocked = true }
        if codec == "hevc" && chroma == "4:2:2" && depth < 10 { hwBlocked = true }
        if lossless || wantsTwoPass || o.i(VideoKeys.vbvMaxrate) > 0 { hwBlocked = true }
        if codec == "prores", chroma != "4:2:2", !["4444", "xq"].contains(o.s(VideoKeys.profile)) { chroma = "4:2:2" }

        var useHW = false
        switch venc {
        case "hardware":
            if hasHW && !hwBlocked { useHW = true }
            else if hasSW {
                note("The hardware encoder cannot do this combination or is missing; the software encoder is used.", "Аппаратный кодировщик не умеет такую комбинацию или недоступен; используется программный.")
            } else if hasHW { useHW = true }
        case "software":
            if hasSW { useHW = false }
            else if hasHW && !hwBlocked { useHW = true; note("The software encoder is not installed; the Apple hardware encoder is used.", "Программный кодировщик не установлен; используется аппаратный кодировщик Apple.") }
        default:
            if codec == "prores" { useHW = hasHW && !hwBlocked }
            else if hasHW && !hwBlocked && (preferHW || !hasSW) {
                useHW = true
                if !hasSW { note("The software encoder is not installed; the Apple hardware encoder is used.", "Программный кодировщик не установлен; используется аппаратный кодировщик Apple.") }
            }
            else { useHW = false }
        }
        if codec == "prores", venc == "software", hasSW { useHW = false }
        if !useHW && !hasSW {
            if hasHW && !hwBlocked { useHW = true }
            else { throw ConversionError.unsupported(L10n("The installed ffmpeg has no \(codec.uppercased()) encoder. Install a full ffmpeg (Settings > Tools) or choose another codec.",
                                                          "В установленном ffmpeg нет кодировщика \(codec.uppercased()). Установите полный ffmpeg (Настройки > Инструменты) или выберите другой кодек.")) }
        }
        plan.hardware = useHW
        plan.videoEncoder = (useHW ? hwName : swName) ?? "libx264"
        // Depth and chroma limits of the chosen encoder.
        if depth == 12 && !(codec == "hevc" && !useHW) && codec != "vp9" { depth = 10; note("12-bit is only available with x265 and VP9; 10-bit is used.", "12 бит доступны только в x265 и VP9; используется 10 бит.") }
        if depth >= 10 && ["mpeg4", "vp8"].contains(codec) { depth = 8 }
        if chroma != "4:2:0" && (useHW && codec != "prores" || ["av1", "vp8", "mpeg4"].contains(codec)) { chroma = "4:2:0"; note("This encoder only writes 4:2:0 colour; 4:2:0 is used.", "Этот кодировщик пишет только цвет 4:2:0; используется 4:2:0.") }
        self.depth = depth; self.chromaKey = chroma
        plan.pixelFormat = pixelFormat(codec: codec, hardware: useHW, depth: depth, chroma: chroma)
        if plan.hardware && codec == "hevc" && plan.container == "mkv" { /* tag hvc1 only applies to mp4/mov */ }
    }

    func pixelFormat(codec: String, hardware: Bool, depth: Int, chroma: String) -> String {
        switch codec {
        case "prores":
            let p = o.s(VideoKeys.profile)
            let is4444 = p == "4444" || p == "xq"
            if hardware { return is4444 ? "p416le" : "p210le" }
            return is4444 ? "yuv444p10le" : "yuv422p10le"
        case "dnxhr":
            switch o.s(VideoKeys.profile) { case "hqx": return "yuv422p10le"; case "444": return "yuv444p10le"; default: return "yuv422p" }
        case "h264": return hardware ? "yuv420p" : VideoCodecTables.pixFmt(chroma: chroma, depth: depth)
        case "hevc":
            if hardware { return depth >= 10 ? (chroma == "4:2:2" ? "p210le" : "p010le") : "yuv420p" }
            return VideoCodecTables.pixFmt(chroma: chroma, depth: depth)
        case "mpeg4", "vp8": return "yuv420p"
        default: return VideoCodecTables.pixFmt(chroma: chroma, depth: depth)
        }
    }

    /// No ffmpeg: AVFoundation / VideoToolbox writes H.264, HEVC and ProRes into MP4 / MOV.
    mutating func resolveNativeEncoder(_ codec: String) throws {
        guard ["h264", "hevc", "prores"].contains(codec) else { throw ConversionError.toolMissing(.ffmpeg) }
        switch codec {
        case "h264" where !tools.nativeH264, "hevc" where !tools.nativeHEVC, "prores" where !tools.nativeProRes:
            throw ConversionError.toolMissing(.ffmpeg)
        default: break
        }
        plan.hardware = true
        plan.videoEncoder = "avf." + codec
        var depth = desiredDepth(codec)
        if codec == "h264" { depth = 8 }
        self.depth = min(depth, 10)
        plan.pixelFormat = nil
        note("ffmpeg is not installed: the built-in macOS encoder is used.", "ffmpeg не установлен: используется встроенный кодировщик macOS.")
    }

    // MARK: Rate control

    mutating func planRate() throws {
        let codec = plan.videoCodec
        guard codec != "copy" else { return }
        if ["prores", "dnxhr", "ffv1"].contains(codec) { plan.rate = .none; return }
        let rc = o.s(VideoKeys.rateControl).isEmpty ? "cq" : o.s(VideoKeys.rateControl)
        switch rc {
        case "lossless":
            plan.rate = .lossless
        case "abr":
            let k = max(100, o.i(VideoKeys.vbitrate, defaultBitrate()))
            plan.rate = .bitrate(k)
            plan.passes = wantsTwoPassNow ? 2 : 1
        case "size":
            try planTargetSize()
        default:
            plan.rate = .quality(qualityValue())
        }
    }

    var wantsTwoPassNow: Bool {
        guard o.b(VideoKeys.twoPass), !plan.hardware else { return false }
        return ["libx264", "libx265", "libvpx-vp9", "libvpx"].contains(plan.videoEncoder)
    }

    /// Native quality for the chosen encoder.
    func qualityValue() -> Double {
        if plan.hardware {
            if o.isActive(VideoKeys.cqHardware) { return o.d(VideoKeys.cqHardware, 60) }
            return Double(VideoCodecTables.vtQuality(fromCRF: o.d(VideoKeys.cq, 23)))
        }
        let cq = o.d(VideoKeys.cq, 23)
        switch plan.videoCodec {
        case "mpeg4": return Double(VideoCodecTables.mpeg4Q(fromCRF: cq))
        case "h264", "hevc": return max(0, min(51, cq))
        case "vp8": return max(4, min(63, cq))
        default: return max(0, min(63, cq))
        }
    }

    /// 0.07 bits per pixel per frame (spec: `vbitrate` default rule).
    func defaultBitrate() -> Int {
        let size = plan.picture.outputSize ?? sv?.displaySize.map { ($0.width, $0.height) } ?? (1280, 720)
        let fps = plan.picture.fps ?? sv?.fps ?? 30
        return max(300, Int(Double(size.0 * size.1) * fps * 0.07 / 1000))
    }

    mutating func planTargetSize() throws {
        let mb = max(0.1, o.d(VideoKeys.targetMB, 25))
        let target = Int64(mb * 1_000_000)
        plan.targetBytes = target
        guard let dur = plan.outputDuration, dur > 0.5 else {
            plan.rate = .bitrate(defaultBitrate()); return
        }
        let audioKbps = plan.audioTracks.reduce(0) { $0 + ($1.bitrateKbps ?? 128) }
        let ladder = o.b(VideoKeys.sizeLadder)
        let dispSize = sv?.displaySize ?? (1920, 1080)
        let w0 = plan.picture.outputSize?.w ?? dispSize.width, h0 = plan.picture.outputSize?.h ?? dispSize.height
        let fps0 = plan.picture.fps ?? sv?.fps ?? 30
        let hasAudio = !plan.audioTracks.isEmpty
        // The shared planner of the size-fit module decides bitrate and ladder; its stub (kbps 0) falls back to the local one.
        let shared = VideoFit.plan(durationSeconds: dur, targetBytes: target, audioKbps: audioKbps, sourceWidth: w0, sourceHeight: h0, sourceFPS: fps0, hasAudio: hasAudio,
                                   allowDownscale: ladder, preferTwoPass: wantsTwoPassNow)
        let local = VideoSizePlanner.plan(durationSeconds: dur, targetBytes: target, audioKbps: audioKbps, sourceWidth: w0, sourceHeight: h0, fps: fps0, hasAudio: hasAudio, allowDownscale: ladder)
        let useShared = shared.videoKbps > 0
        let kbps = max(50, Int((Double(useShared ? shared.videoKbps : local.videoKbps) * max(0.2, an.bitrateScale)).rounded(.down)))
        let maxHeight = useShared ? shared.maxHeight : local.maxHeight
        let unreachable = useShared ? shared.unreachable : local.unreachable
        let fit = (videoKbps: kbps, maxHeight: maxHeight, unreachable: unreachable)
        // Sound never takes more than its share of a small budget (the planner's own audio figure is the limit).
        let audioBudget = useShared ? shared.audioKbps : audioKbps
        if hasAudio, audioKbps > audioBudget, audioBudget > 0 {
            for i in plan.audioTracks.indices where plan.audioTracks[i].codec != "copy" {
                let k = plan.audioTracks[i].bitrateKbps ?? 128
                plan.audioTracks[i].bitrateKbps = max(24, Int((Double(k) * Double(audioBudget) / Double(audioKbps)).rounded(.down)))
                plan.audioTracks[i].vbr = false; plan.audioTracks[i].quality = nil
            }
            note("The sound bitrate is lowered to fit the size.", "Битрейт звука снижен, чтобы уложиться в размер.")
        }
        plan.rate = .bitrate(fit.videoKbps)
        plan.passes = wantsTwoPassNow ? 2 : 1
        if let h = fit.maxHeight, let cur = plan.picture.outputSize, min(cur.w, cur.h) > h {
            // Downscale so the bits per pixel stay watchable: the short side is capped at the ladder rung.
            let short = Double(min(cur.w, cur.h))
            let f = Double(h) / short
            let w = max(2, Int((Double(cur.w) * f / 2).rounded()) * 2), hh = max(2, Int((Double(cur.h) * f / 2).rounded()) * 2)
            plan.picture.scale = (w, hh); plan.picture.scaleCover = false
            plan.picture.outputSize = (w, hh)
            note("The target is small, so the picture is reduced to \(h)p to stay clean.", "Размер небольшой, поэтому картинка уменьшена до \(h)p, чтобы оставаться чистой.")
        }
        if fit.unreachable { note("This size is very small for the clip; the picture will look rough.", "Такой размер очень мал для этого ролика; картинка будет грубой.") }
    }
}

/// Pure planner for "fit to size" (the sizefit module's `VideoFit.plan` is preferred when it is implemented).
enum VideoSizePlanner {
    struct Result: Equatable { var videoKbps: Int; var maxHeight: Int?; var unreachable: Bool }
    static let ladder = [2160, 1440, 1080, 720, 540, 480, 360]
    /// Bits per pixel per frame below which H.264 looks blocky.
    static let bppFloor = 0.04

    static func plan(durationSeconds: Double, targetBytes: Int64, audioKbps: Int, sourceWidth: Int, sourceHeight: Int, fps: Double, hasAudio: Bool, allowDownscale: Bool) -> Result {
        // Container overhead and rate-control slack: spend 95% of the budget.
        let totalKbps = Double(targetBytes) * 8 / max(durationSeconds, 0.1) / 1000 * 0.95
        let audio = hasAudio ? Double(audioKbps) : 0
        let video = max(50, Int((totalKbps - audio).rounded(.down)))
        guard allowDownscale, sourceHeight > 0, sourceWidth > 0 else { return Result(videoKbps: video, maxHeight: nil, unreachable: false) }
        func bpp(_ h: Int) -> Double {
            let w = Double(sourceWidth) * Double(h) / Double(sourceHeight)
            return Double(video) * 1000 / (w * Double(h) * max(fps, 1))
        }
        if bpp(sourceHeight) >= bppFloor { return Result(videoKbps: video, maxHeight: nil, unreachable: false) }
        for h in ladder where h < sourceHeight {
            if bpp(h) >= bppFloor { return Result(videoKbps: video, maxHeight: h, unreachable: false) }
        }
        return Result(videoKbps: video, maxHeight: ladder.last, unreachable: true)
    }
}
