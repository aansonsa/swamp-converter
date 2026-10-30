import Foundation

/// PURE planner: probe + mode + capabilities + options -> plan. No I/O, fully table-tested (SmartTests "planner ...").
///
/// Decision table:
///  Best for Apple
///   1. H.264 / HEVC (8-bit or 10-bit 4:2:0) or ProRes-in-MOV -> video stream COPY; HEVC is tagged `hvc1` (a `hev1` file is re-tagged by the remux).
///   2. everything else (VP9, AV1, MPEG-2, MPEG-4, VC-1, H.264 High 10 / 4:2:2, ...) -> HEVC `hvc1`: 10-bit when the source is 10-bit or HDR, HDR10 / HLG
///      tags and mastering metadata kept, size and frame rate kept (4K and 8K stay), hardware encoder unless "maximum quality (slow)" and libx265 exist.
///      A picture the hardware encoder cannot do goes to libx265 (or is scaled when the user asked for a limit); interlaced sources are deinterlaced.
///   3. audio: AAC / ALAC / MP3 / AC-3 / E-AC-3 are copied; the rest becomes AAC (256 kbit/s stereo, more for surround) or ALAC when the user picks lossless.
///   4. text subtitles -> `mov_text`; bitmap subtitles are dropped with a warning. Container MP4 (MOV when the source is MOV), faststart.
///  Maximum: nothing is re-encoded. MP4 / MOV when every stream fits, WebM for VP8 / VP9 / AV1 with Opus / Vorbis, otherwise MKV.
///  Universal: H.264 High 8-bit 4:2:0 inside 1920x1080 + AAC (stereo / 5.1) in MP4; copied when the source already complies. HDR is tone-mapped to SDR
///   when ffmpeg can (zscale + tonemap); otherwise it is KEPT (HEVC 10-bit) with a warning, never turned into a washed-out picture.
enum TranscodePlanner {
    static func plan(probe: MediaInfo, mode: SmartMode, capabilities: SmartCapabilities, options: SmartOptions,
                     facts: SmartVideoFacts = SmartVideoFacts()) -> TranscodePlan {
        var opt = options
        opt.mode = mode
        let src = PlanSource(info: probe, facts: facts)
        var p = TranscodePlan(mode: mode, container: "mp4", video: .copy, targetWidth: nil, targetHeight: nil, targetFPS: nil, pixelFormat: nil,
                              color: SmartColorInfo(), videoTag: nil, audio: [], audioStreamIndexes: [], subtitleStreamIndexes: [], faststart: opt.faststart,
                              qualityValue: nil)
        p.stripMetadata = opt.stripMetadata
        p.sourceDuration = probe.duration
        p.sourceFPS = src.video?.fps
        if ["ts", "avi", "other"].contains(src.container) { p.inputOptions = ["-fflags", "+genpts"] }
        guard let v = src.video else {
            p.problems.append(L10n("The file has no video track.", "В файле нет видеодорожки."))
            return p
        }
        p.videoStreamIndex = v.index
        switch mode {
        case .bestForApple: planBest(src, v, capabilities, opt, &p)
        case .maximum: planMaximum(src, v, capabilities, opt, &p)
        case .universal: planUniversal(src, v, capabilities, opt, &p)
        }
        p.faststart = p.faststart && SmartContainer.isQuickTimeFamily(p.container)
        return p
    }

    // MARK: Best for Apple

    private static func planBest(_ s: PlanSource, _ v: MediaStreamInfo, _ caps: SmartCapabilities, _ opt: SmartOptions, _ p: inout TranscodePlan) {
        let codec = SmartCodec.video(v.codec)
        let friendly = SmartApple.videoIsFriendly(v, sourceContainer: s.container, facts: s.facts)
        let scaleTo = opt.downscaleWhenUnsupported ? scaledSize(s, shortSide: opt.fallbackHeight) : nil
        // Container: auto = MOV for MOV sources (ProRes needs it), else MP4.
        var container = opt.container == "auto" || opt.container.isEmpty ? (s.container == "mov" ? "mov" : "mp4") : opt.container
        if codec == "prores" && friendly && container == "mp4" { container = "mov"; p.notes.append(L10n("ProRes needs the MOV container.", "ProRes требует контейнер MOV.")) }
        p.container = container

        if friendly && scaleTo == nil {
            p.video = .copy
            p.color = s.color
            p.targetWidth = s.width > 0 ? s.width : nil; p.targetHeight = s.height > 0 ? s.height : nil
            setCopyTag(s, codec, container, &p)
            p.notes.append(L10n("The picture is already in an Apple-friendly format and is copied without re-encoding.",
                                "Видео уже в формате, удобном для Apple, и копируется без перекодирования."))
        } else {
            planHEVC(s, v, caps, opt, scaleTo: scaleTo, container: container, &p)
        }
        planAudio(s, container: container, opt, forceAAC: false, maxChannels: nil, &p)
        planSubtitles(s, container: container, opt, &p)
    }

    /// HEVC re-encode shared by Best for Apple and the HDR branch of Universal.
    private static func planHEVC(_ s: PlanSource, _ v: MediaStreamInfo, _ caps: SmartCapabilities, _ opt: SmartOptions, scaleTo: (Int, Int)?,
                                 container: String, _ p: inout TranscodePlan) {
        let ten = s.tenBit
        let (w, h) = scaleTo ?? (s.width, s.height)
        buildFilters(s, scaleTo: scaleTo, deinterlace: s.interlaced, caps: caps, &p)
        let outW = scaleTo?.0 ?? evenDown(s.width), outH = scaleTo?.1 ?? evenDown(s.height)
        p.targetWidth = outW > 0 ? outW : nil; p.targetHeight = outH > 0 ? outH : nil
        p.color = s.color
        if s.isHDR { p.masteringDisplay = s.facts.masteringDisplay; p.maxCLL = s.facts.maxCLL }
        p.pixelFormat = ten ? "yuv420p10le" : "yuv420p"
        if scaleTo != nil {
            p.notes.append(L10n("The picture is scaled down to \(outW)x\(outH).", "Картинка уменьшается до \(outW)x\(outH)."))
        }
        // Encoder.
        let wantSlow = opt.maximumQualitySlow && !opt.preferHardware
        if opt.maximumQualitySlow && opt.preferHardware {
            p.notes.append(L10n("Low Power Mode or battery: the fast hardware encoder is used instead of the slow one.",
                                "Режим энергосбережения или батарея: вместо медленного кодировщика используется быстрый аппаратный."))
        }
        var encoder: String?
        if wantSlow && caps.libx265 {
            encoder = "libx265"
        } else if caps.hevcHardwareSupports(width: w, height: h) {
            encoder = "hevc_videotoolbox"
            if wantSlow && !caps.libx265 {
                p.warnings.append(L10n("libx265 is not installed; the hardware encoder is used.", "libx265 не установлен; используется аппаратный кодировщик."))
            }
        } else if caps.libx265 {
            encoder = "libx265"
            p.notes.append(caps.hevcHardware
                ? L10n("This picture is larger than the hardware encoder handles; the software encoder is used (slower).",
                       "Картинка больше, чем поддерживает аппаратный кодировщик; используется программный (медленнее).")
                : L10n("The hardware encoder is not available; the software encoder is used (slower).",
                       "Аппаратный кодировщик недоступен; используется программный (медленнее)."))
        } else if caps.hevcHardware {
            encoder = "hevc_videotoolbox"
            p.warnings.append(L10n("This picture may be too large for the hardware encoder. Turn on “Scale down large pictures” if the conversion fails.",
                                   "Картинка может быть слишком большой для аппаратного кодировщика. Если конвертация не удастся, включите «Уменьшать большие картинки»."))
        } else {
            p.problems.append(L10n("This Mac’s ffmpeg has no HEVC encoder.", "В ffmpeg на этом Mac нет кодировщика HEVC."))
        }
        let encName = encoder ?? "hevc_videotoolbox"
        p.video = .hevc(encoder: encName, tenBit: ten)
        if encName == "libx265" {
            p.qualityValue = SmartQuality.software(SmartQuality.hevcSoftwareCRF(height: h, tenBit: ten, slow: opt.maximumQualitySlow && !opt.preferHardware), offset: opt.qualityOffset)
            p.encoderPreset = opt.maximumQualitySlow && !opt.preferHardware ? "slow" : "medium"
        } else {
            p.qualityValue = SmartQuality.hardware(SmartQuality.hevcHardwareQuality(height: h, tenBit: ten), offset: opt.qualityOffset)
            p.videoProfile = ten ? "main10" : "main"
        }
        p.videoTag = SmartContainer.isQuickTimeFamily(container) ? "hvc1" : nil
        if s.isHDR {
            p.notes.append(L10n("HDR is kept: 10-bit HEVC with the original color tags and mastering data.", "HDR сохраняется: 10-бит HEVC с исходными цветовыми тегами и данными мастеринга."))
        }
        if s.facts.dolbyVisionProfile != nil {
            p.warnings.append(L10n("Dolby Vision layers cannot be kept when re-encoding; the HDR10 base layer is used.", "Слои Dolby Vision нельзя сохранить при перекодировании; используется базовый слой HDR10."))
        }
    }

    private static func setCopyTag(_ s: PlanSource, _ codec: String, _ container: String, _ p: inout TranscodePlan) {
        guard SmartContainer.isQuickTimeFamily(container) else { p.videoTag = nil; return }
        if codec == "hevc" {
            // Dolby Vision streams keep their own tag (dvh1); everything else becomes hvc1 so QuickTime opens it.
            if s.facts.dolbyVisionProfile != nil, let tag = s.facts.codecTag, tag.hasPrefix("dv") {
                p.videoTag = nil
                p.notes.append(L10n("Dolby Vision signalling is kept.", "Сигнализация Dolby Vision сохранена."))
            } else {
                p.videoTag = "hvc1"
            }
        } else {
            p.videoTag = nil
        }
    }

    // MARK: Maximum quality

    private static func planMaximum(_ s: PlanSource, _ v: MediaStreamInfo, _ caps: SmartCapabilities, _ opt: SmartOptions, _ p: inout TranscodePlan) {
        let codec = SmartCodec.video(v.codec)
        let audioCodecs = keptAudio(s, opt).map { SmartCodec.audio($0.codec) }
        let subs = opt.keepSubtitles ? s.info.subtitleStreams : []
        let anyBitmapSubs = subs.contains { !SmartCodec.isTextSubtitle($0.codec) }
        let mp4Video: Set<String> = ["h264", "hevc", "mpeg4", "av1", "vp9"]
        let movVideo = mp4Video.union(["prores"])
        let fitsMP4 = mp4Video.contains(codec) && audioCodecs.allSatisfy { SmartApple.audioIsFriendly($0, container: "mp4") } && !anyBitmapSubs
        let fitsMOV = movVideo.contains(codec) && audioCodecs.allSatisfy { SmartApple.audioIsFriendly($0, container: "mov") } && !anyBitmapSubs
        let webmVideo: Set<String> = ["vp8", "vp9", "av1"]
        let fitsWebM = webmVideo.contains(codec) && !audioCodecs.isEmpty && audioCodecs.allSatisfy { $0 == "opus" || $0 == "vorbis" }
            && subs.allSatisfy { ($0.codec).lowercased() == "webvtt" } && s.info.audioStreams.count == audioCodecs.count
        let webmNoAudioOK = webmVideo.contains(codec) && audioCodecs.isEmpty && subs.isEmpty

        var container: String
        switch opt.container {
        case "mkv": container = "mkv"
        case "mov", "mp4":
            let fits = opt.container == "mov" ? fitsMOV : fitsMP4
            if fits { container = opt.container } else {
                container = "mkv"
                p.warnings.append(L10n("These streams do not fit into \(opt.container.uppercased()); they are kept in MKV instead.",
                                       "Эти потоки не помещаются в \(opt.container.uppercased()); они сохранены в MKV."))
            }
        default:
            if fitsMP4 || fitsMOV {
                container = (codec == "prores" || audioCodecs.contains("pcm") || (s.container == "mov" && fitsMOV)) && fitsMOV ? "mov" : (fitsMP4 ? "mp4" : "mov")
            } else if fitsWebM || webmNoAudioOK {
                container = "webm"
            } else {
                container = "mkv"
            }
        }
        p.container = container
        p.video = .copy
        p.color = s.color
        p.targetWidth = s.width > 0 ? s.width : nil; p.targetHeight = s.height > 0 ? s.height : nil
        setCopyTag(s, codec, container, &p)
        p.notes.append(L10n("Nothing is re-encoded: the streams are copied as they are.", "Ничего не перекодируется: потоки копируются как есть."))
        planAudio(s, container: container, opt, forceAAC: false, maxChannels: nil, copyAll: true, &p)
        planSubtitles(s, container: container, opt, &p)
    }

    // MARK: Universal

    private static func planUniversal(_ s: PlanSource, _ v: MediaStreamInfo, _ caps: SmartCapabilities, _ opt: SmartOptions, _ p: inout TranscodePlan) {
        p.container = "mp4"
        let codec = SmartCodec.video(v.codec)
        // HDR cannot be shown correctly as plain 8-bit H.264: tone-map when possible, otherwise keep it as HEVC 10-bit and say so.
        if s.isHDR && !caps.hdrToSDR {
            p.warnings.append(L10n("This is an HDR video. Converting it to SDR needs tone mapping, which this ffmpeg lacks, so the HDR is kept (HEVC 10-bit). It will not play on every device.",
                                   "Это HDR-видео. Для преобразования в SDR нужен тон-маппинг, которого нет в этом ffmpeg, поэтому HDR сохраняется (HEVC 10-бит). Оно воспроизводится не на всех устройствах."))
            planHEVC(s, v, caps, opt, scaleTo: nil, container: "mp4", &p)
            planAudio(s, container: "mp4", opt, forceAAC: true, maxChannels: 6, &p)
            planSubtitles(s, container: "mp4", opt, &p)
            return
        }
        // Non-square pixels (DVD material) are rendered square: devices differ in honouring the flag.
        let ratio = s.facts.pixelAspectRatio
        let squared = !s.facts.isSquarePixels && s.width > 0
        let displayWidth = squared ? Int((Double(s.width) * ratio).rounded()) : s.width
        let fit = fitInBox(width: displayWidth, height: s.height, long: 1920, short: 1080) ?? (squared ? (evenDown(displayWidth), evenDown(s.height)) : nil)
        let pix = (v.pixelFormat ?? s.facts.pixelFormat ?? "").lowercased()
        let profile = (v.profile ?? "").lowercased()
        let compliant = codec == "h264" && !s.isHDR && s.depth <= 8 && fit == nil && s.facts.isSquarePixels
            && (pix.isEmpty || pix == "yuv420p" || pix == "yuvj420p") && !profile.contains("high 10") && !profile.contains("4:2:2") && !profile.contains("4:4:4")
        if compliant {
            p.video = .copy
            p.targetWidth = s.width > 0 ? s.width : nil; p.targetHeight = s.height > 0 ? s.height : nil
            p.color = s.color
            p.notes.append(L10n("The video already plays everywhere and is copied without re-encoding.", "Видео уже воспроизводится везде и копируется без перекодирования."))
        } else {
            buildFilters(s, scaleTo: fit, deinterlace: s.interlaced, caps: caps, &p, toneMap: s.isHDR && caps.hdrToSDR, squarePixels: squared)
            let outW = fit?.0 ?? evenDown(s.width), outH = fit?.1 ?? evenDown(s.height)
            p.targetWidth = outW > 0 ? outW : nil; p.targetHeight = outH > 0 ? outH : nil
            p.pixelFormat = "yuv420p"
            p.videoProfile = "high"
            // SDR keeps its colour tags; tone-mapped HDR becomes plain BT.709.
            p.color = s.isHDR ? SmartColorInfo(primaries: "bt709", transfer: "bt709", matrix: "bt709", range: "tv") : s.color
            let useHW = (opt.preferHardware && caps.h264Hardware) || !caps.libx264
            if useHW && caps.h264Hardware {
                p.video = .h264(encoder: "h264_videotoolbox")
                p.qualityValue = SmartQuality.hardware(SmartQuality.h264HardwareQuality(height: outH), offset: opt.qualityOffset)
            } else if caps.libx264 {
                p.video = .h264(encoder: "libx264")
                p.qualityValue = SmartQuality.software(SmartQuality.h264CRF(height: outH), offset: opt.qualityOffset)
                p.encoderPreset = "medium"
            } else {
                p.video = .h264(encoder: "libx264")
                p.problems.append(L10n("This Mac’s ffmpeg has no H.264 encoder.", "В ffmpeg на этом Mac нет кодировщика H.264."))
            }
            p.videoTag = "avc1"
            if fit != nil, let w = p.targetWidth, let h = p.targetHeight {
                p.notes.append(L10n("The picture is scaled down to \(w)x\(h) (1080p) so it plays on any device.", "Картинка уменьшается до \(w)x\(h) (1080p), чтобы воспроизводиться на любом устройстве."))
            }
            if s.isHDR { p.notes.append(L10n("HDR is tone-mapped to SDR.", "HDR преобразуется в SDR.")) }
        }
        planAudio(s, container: "mp4", opt, forceAAC: true, maxChannels: 6, &p)
        planSubtitles(s, container: "mp4", opt, &p)
    }

    // MARK: Filters, sizes

    private static func buildFilters(_ s: PlanSource, scaleTo: (Int, Int)?, deinterlace: Bool, caps: SmartCapabilities, _ p: inout TranscodePlan,
                                    toneMap: Bool = false, squarePixels: Bool = false) {
        var f: [String] = []
        if deinterlace {
            p.deinterlace = true
            f.append(caps.bwdif ? "bwdif=mode=send_frame:parity=auto:deint=interlaced" : "yadif=mode=0:parity=-1:deint=1")
        }
        if toneMap {
            f.append("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p")
        }
        if let (w, h) = scaleTo {
            f.append("scale=\(w):\(h):flags=lanczos" + (squarePixels ? ",setsar=1" : ""))
        } else if s.oddSize {
            f.append("crop=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        p.videoFilters = f
    }

    /// Size after "limit the shorter side to `shortSide`", or nil when the picture already fits. Even numbers, aspect kept.
    private static func scaledSize(_ s: PlanSource, shortSide: Int) -> (Int, Int)? {
        guard s.width > 0, s.height > 0, min(s.width, s.height) > shortSide else { return nil }
        let f = Double(shortSide) / Double(min(s.width, s.height))
        return (evenDown(Int((Double(s.width) * f).rounded())), evenDown(Int((Double(s.height) * f).rounded())))
    }

    /// Size after fitting into a `long` x `short` box (orientation-aware), or nil when it already fits.
    static func fitInBox(width: Int, height: Int, long: Int, short: Int) -> (Int, Int)? {
        guard width > 0, height > 0 else { return nil }
        let landscape = width >= height
        let boxW = landscape ? long : short, boxH = landscape ? short : long
        let f = min(Double(boxW) / Double(width), Double(boxH) / Double(height))
        if f >= 1 { return nil }
        return (max(2, evenDown(Int((Double(width) * f).rounded()))), max(2, evenDown(Int((Double(height) * f).rounded()))))
    }

    static func evenDown(_ v: Int) -> Int { v - (v % 2) }

    // MARK: Audio

    private static func keptAudio(_ s: PlanSource, _ opt: SmartOptions) -> [MediaStreamInfo] {
        let all = s.info.audioStreams
        if opt.keepAllAudioTracks || all.count <= 1 { return all }
        return [all.first(where: { $0.isDefault }) ?? all[0]]
    }

    /// AAC bitrate for a track: `base` is the stereo figure; mono gets half, surround more.
    static func aacBitrate(base: Int, channels: Int?) -> Int {
        let ch = channels ?? 2
        if ch <= 1 { return max(64, base / 2) }
        if ch == 2 { return base }
        if ch <= 6 { return min(512, base * 3 / 2) }
        return min(640, base * 2)
    }

    private static func planAudio(_ s: PlanSource, container: String, _ opt: SmartOptions, forceAAC: Bool, maxChannels: Int?, copyAll: Bool = false,
                                  _ p: inout TranscodePlan) {
        for a in keptAudio(s, opt) {
            let codec = SmartCodec.audio(a.codec)
            let ch = a.channels
            p.audioStreamIndexes.append(a.index)
            p.audioLanguages.append(a.language)
            let tooWide = (maxChannels != nil && (ch ?? 2) > maxChannels!)
            let friendly = copyAll || SmartApple.audioIsFriendly(codec, container: container)
            let canCopy = friendly && !tooWide && (!forceAAC || codec == "aac")
            if canCopy {
                p.audio.append(.copy); p.audioChannels.append(nil)
            } else {
                p.audio.append(opt.losslessAudio ? .alac : .aac(kbps: aacBitrate(base: opt.audioBitrateKbps, channels: tooWide ? maxChannels : ch)))
                p.audioChannels.append(tooWide ? maxChannels : nil)
            }
        }
        if s.info.audioStreams.count > p.audio.count {
            p.notes.append(L10n("Only the main audio track is kept.", "Сохраняется только основная звуковая дорожка."))
        }
    }

    // MARK: Subtitles

    private static func planSubtitles(_ s: PlanSource, container: String, _ opt: SmartOptions, _ p: inout TranscodePlan) {
        guard opt.keepSubtitles else { return }
        var dropped = 0
        for sub in s.info.subtitleStreams {
            let text = SmartCodec.isTextSubtitle(sub.codec)
            switch container {
            case "mkv":
                p.subtitleStreamIndexes.append(sub.index)
            case "webm":
                if sub.codec.lowercased() == "webvtt" { p.subtitleStreamIndexes.append(sub.index) } else { dropped += 1 }
            default:
                if text { p.subtitleStreamIndexes.append(sub.index) } else { dropped += 1 }
            }
        }
        if !p.subtitleStreamIndexes.isEmpty { p.subtitleCodec = container == "mkv" ? "copy" : (container == "webm" ? "webvtt" : "mov_text") }
        if dropped > 0 {
            p.warnings.append(L10n("\(dropped) picture-based subtitle track(s) cannot be kept in \(container.uppercased()) and were left out.",
                                   "Графические субтитры (\(dropped)) нельзя сохранить в \(container.uppercased()), они пропущены."))
        }
    }
}

/// The source stream summarised once for the planner.
struct PlanSource {
    let info: MediaInfo
    let facts: SmartVideoFacts
    let video: MediaStreamInfo?
    let container: String
    /// Displayed size (rotation applied); 0 when unknown.
    let width: Int
    let height: Int
    let depth: Int
    let color: SmartColorInfo
    let interlaced: Bool

    init(info: MediaInfo, facts: SmartVideoFacts) {
        self.info = info
        self.facts = facts
        let v = info.videoStreams.first
        video = v
        container = SmartContainer.kind(of: info)
        var w = v?.width ?? 0, h = v?.height ?? 0
        let r = ((v?.rotation ?? 0) % 360 + 360) % 360
        if r == 90 || r == 270 { swap(&w, &h) }
        width = w; height = h
        let pix = (v?.pixelFormat ?? facts.pixelFormat ?? "")
        depth = v?.bitDepth ?? SmartVideoFacts.bitDepth(ofPixelFormat: pix) ?? 8
        color = facts.colorInfo(stream: v)
        let fo = (facts.fieldOrder ?? "").lowercased()
        interlaced = (v?.interlaced ?? false) || ["tt", "bb", "tb", "bt"].contains(fo)
    }

    var isHDR: Bool { color.isHDR }
    var tenBit: Bool { depth >= 10 || isHDR }
    var oddSize: Bool { width % 2 == 1 || height % 2 == 1 }
}
