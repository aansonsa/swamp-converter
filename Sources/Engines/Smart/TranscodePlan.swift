import Foundation

// The typed result of planning. Pure data: the planner builds it, the engine executes it, tests compare it.

/// What this Mac's ffmpeg / VideoToolbox can do. Built from `Capabilities.shared` (`SmartCapabilities.current`) or by hand in tests.
struct SmartCapabilities: Equatable, Sendable {
    var hasFFmpeg = true
    var hevcHardware = true          // hevc_videotoolbox
    var h264Hardware = true          // h264_videotoolbox
    var libx265 = false
    var libx264 = false
    var aacAudioToolbox = true       // aac_at
    var libmp3lame = false
    /// Largest picture the hardware HEVC encoder is trusted with (8K needs the software encoder or a downscale offer).
    var hevcHardwareMaxHeight = 4320
    /// zscale + tonemap exist, so HDR can be tone-mapped to SDR (this Mac's ffmpeg has no zscale: false there).
    var hdrToSDR = false
    /// bwdif (better) or yadif for deinterlacing.
    var bwdif = true

    /// Reads `ff.enc.*` / `ff.filter.*` from `Capabilities.shared` (cached after the first call, about 150 ms the very first time).
    static var current: SmartCapabilities {
        let c = Capabilities.shared
        var s = SmartCapabilities()
        s.hasFFmpeg = c.has("ff.present")
        s.hevcHardware = c.has("ff.enc.hevc_videotoolbox")
        s.h264Hardware = c.has("ff.enc.h264_videotoolbox")
        s.libx265 = c.has("ff.enc.libx265")
        s.libx264 = c.has("ff.enc.libx264")
        s.aacAudioToolbox = c.has("ff.enc.aac_at")
        s.libmp3lame = c.has("ff.enc.libmp3lame")
        s.hdrToSDR = c.has("ff.filter.zscale") && c.has("ff.filter.tonemap")
        s.bwdif = c.has("ff.filter.bwdif")
        return s
    }

    /// Can the hardware HEVC encoder be trusted with a picture of this size? (8K 7680x4320 yes on Apple silicon; wider than 16:9 x height no.)
    func hevcHardwareSupports(width: Int, height: Int) -> Bool {
        guard hevcHardware else { return false }
        return height <= hevcHardwareMaxHeight && width <= hevcHardwareMaxHeight * 16 / 9 + 1
    }
}

/// The user-facing knobs of the schema `smart.transcode` as a typed value (built by `SmartOptions(options:)`).
struct SmartOptions: Equatable, Sendable {
    var mode: SmartMode = .bestForApple
    /// libx265 instead of the hardware encoder (slower, a little smaller / better).
    var maximumQualitySlow = false
    /// ALAC instead of AAC for audio that has to be re-encoded.
    var losslessAudio = false
    var audioBitrateKbps = 256
    var keepAllAudioTracks = true
    var keepSubtitles = true
    /// Scale pictures whose shorter side exceeds `fallbackHeight` down to it (aspect kept). Off: the picture keeps its size; a picture the
    /// hardware encoder cannot handle goes to the software encoder (or gets a warning when there is none).
    var downscaleWhenUnsupported = false
    var fallbackHeight = 2160
    /// auto (the planner decides), mp4, mov, mkv.
    var container = "auto"
    var faststart = true
    /// Drop location, camera and date metadata.
    var stripMetadata = false
    /// -10...+10 steps around the documented quality target; positive = better / larger.
    var qualityOffset = 0
    /// Low Power Mode / battery / warm Mac: hardware encoders only, no slow software encodes.
    var preferHardware = false

    init(mode: SmartMode = .bestForApple) { self.mode = mode }

    /// Maps the keys of `SmartKeys` (Core resolves defaults, so every key is normally present; missing keys keep the defaults above).
    init(options v: OptionValues) {
        if let m = v[SmartKeys.mode]?.asString, let mode = SmartMode(rawValue: m) { self.mode = mode }
        maximumQualitySlow = v.bool(SmartKeys.slowMaxQuality, maximumQualitySlow)
        losslessAudio = v.bool(SmartKeys.losslessAudio, losslessAudio)
        audioBitrateKbps = Util.clamp(v.int(SmartKeys.audioBitrate, audioBitrateKbps), 64, 640)
        keepAllAudioTracks = v.bool(SmartKeys.keepAllAudio, keepAllAudioTracks)
        keepSubtitles = v.bool(SmartKeys.keepSubtitles, keepSubtitles)
        downscaleWhenUnsupported = v.bool(SmartKeys.downscale, downscaleWhenUnsupported)
        fallbackHeight = Util.clamp(v.int(SmartKeys.downscaleHeight, fallbackHeight), 240, 4320)
        container = v.string(SmartKeys.container, container)
        faststart = v.bool(SmartKeys.faststart, faststart)
        stripMetadata = v.bool(SmartKeys.stripMetadata, stripMetadata)
        qualityOffset = Util.clamp(v.int(SmartKeys.qualityOffset, qualityOffset), -10, 10)
    }

    /// The same options as plain option values (the CLI, presets and the downloader's convert stage use this).
    var optionValues: OptionValues {
        [SmartKeys.mode: .string(mode.rawValue), SmartKeys.slowMaxQuality: .bool(maximumQualitySlow), SmartKeys.losslessAudio: .bool(losslessAudio),
         SmartKeys.audioBitrate: .int(audioBitrateKbps), SmartKeys.keepAllAudio: .bool(keepAllAudioTracks), SmartKeys.keepSubtitles: .bool(keepSubtitles),
         SmartKeys.downscale: .bool(downscaleWhenUnsupported), SmartKeys.downscaleHeight: .int(fallbackHeight), SmartKeys.container: .string(container),
         SmartKeys.faststart: .bool(faststart), SmartKeys.stripMetadata: .bool(stripMetadata), SmartKeys.qualityOffset: .int(qualityOffset)]
    }
}

enum SmartVideoAction: Equatable, Sendable {
    /// Stream copy (lossless remux).
    case copy
    case hevc(encoder: String, tenBit: Bool)
    case h264(encoder: String)
}

enum SmartAudioAction: Equatable, Sendable {
    case copy
    case aac(kbps: Int)
    case alac
}

struct SmartColorInfo: Equatable, Sendable {
    var primaries: String?       // bt709, bt2020
    var transfer: String?        // bt709, smpte2084 (HDR10 PQ), arib-std-b67 (HLG)
    var matrix: String?
    var range: String?           // tv, pc
    var isHDR: Bool { transfer == "smpte2084" || transfer == "arib-std-b67" }
    var isEmpty: Bool { primaries == nil && transfer == nil && matrix == nil && range == nil }
}

struct TranscodePlan: Equatable, Sendable {
    var mode: SmartMode
    /// mp4, mov, mkv or webm.
    var container: String
    var video: SmartVideoAction
    /// Output picture size as displayed (nil = keep the source size; 4K and 8K stay as they are unless the user opted into a downscale).
    /// Odd sizes are cropped by one pixel to the even size every encoder accepts (321x241 -> 320x240).
    var targetWidth: Int?
    var targetHeight: Int?
    var targetFPS: Double?
    var pixelFormat: String?
    var color: SmartColorInfo
    /// `hvc1` for HEVC in MP4/MOV (QuickTime refuses `hev1`), `avc1` for H.264, nil for copy of other codecs.
    var videoTag: String?
    var audio: [SmartAudioAction]
    /// Source stream indexes kept, parallel to `audio`.
    var audioStreamIndexes: [Int]
    /// Subtitle stream indexes kept as `mov_text` (MP4); bitmap subtitles are dropped with a warning.
    var subtitleStreamIndexes: [Int]
    var faststart: Bool
    /// Quality target of the encoder: constant-quality value in the encoder's native scale (documented in SmartQuality) or nil for copy.
    var qualityValue: Double?
    var warnings: [L10n] = []
    var notes: [L10n] = []

    // MARK: Added detail (all defaulted)

    /// Source stream index of the video that is kept; nil when the file has no video.
    var videoStreamIndex: Int? = nil
    /// Encoder profile argument: main, main10 (HEVC), high (H.264).
    var videoProfile: String? = nil
    /// x265 / x264 preset ("medium", "slow").
    var encoderPreset: String? = nil
    var deinterlace = false
    /// The complete video filter chain in order (deinterlace, scale, crop to even, tone map).
    var videoFilters: [String] = []
    /// Output channel limit per kept audio track (nil = keep the layout).
    var audioChannels: [Int?] = []
    /// Language tag per kept audio track (re-applied after a metadata strip).
    var audioLanguages: [String?] = []
    /// `mov_text` (text subtitles into MP4 / MOV) or `copy` (Matroska); nil when no subtitles are kept.
    var subtitleCodec: String? = nil
    /// x265 `master-display` / `max-cll` strings of the source (libx265 gets them explicitly; VideoToolbox carries them itself).
    var masteringDisplay: String? = nil
    var maxCLL: String? = nil
    var stripMetadata = false
    var sourceDuration: Double? = nil
    var sourceFPS: Double? = nil
    /// Options placed before `-i` (`-fflags +genpts` for transport streams and AVI).
    var inputOptions: [String] = []
    /// Reasons the plan cannot be executed (no HEVC encoder at all, no video track). The engine throws the first one.
    var problems: [L10n] = []

    var isPureRemux: Bool { video == .copy && audio.allSatisfy { $0 == .copy } }
    var isHDR: Bool { color.isHDR }
    var encoderName: String? {
        switch video { case .copy: return nil; case .hevc(let e, _): return e; case .h264(let e): return e }
    }
    var isHardwareEncode: Bool { encoderName?.hasSuffix("_videotoolbox") == true }
    var isTenBit: Bool { if case .hevc(_, let ten) = video { return ten } else { return false } }

    /// Short chips for the Studio summary ("HEVC 10-bit", "Remux", "AAC 256", "hvc1").
    var chips: [String] {
        var out: [String] = []
        switch video {
        case .copy: out.append(isPureRemux ? "Remux" : L("Video copy", "Видео без перекодирования"))
        case .hevc(_, let ten): out.append(ten ? "HEVC 10-bit" : "HEVC")
        case .h264: out.append("H.264")
        }
        if isHDR { out.append(color.transfer == "arib-std-b67" ? "HLG" : "HDR10") }
        if let tag = videoTag { out.append(tag) }
        if let first = audio.first {
            switch first {
            case .copy: out.append(L("Audio copy", "Звук без изменений"))
            case .aac(let k): out.append("AAC \(k)")
            case .alac: out.append("ALAC")
            }
        }
        out.append(container.uppercased())
        return out
    }
}
