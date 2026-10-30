import Foundation

// The typed middle layer of the video engine (spec/handbrake.md 5.2): options -> VideoEncodePlan -> back end.
// Keeping the plan separate makes "every option changes the argv/plan" testable without encoding anything (golden tests).
// The builder is PURE: probe results and analyses (crop detection, deinterlace verdict, loudness, subtitle cues) are inputs.

/// How the video stream is rate controlled.
enum VideoRate: Equatable, Sendable {
    /// No video encoder rate control (stream copy, ProRes, DNxHR, FFV1).
    case none
    /// Native quality of the encoder: CRF for software encoders, `-q:v` for VideoToolbox, `-q:v` for MPEG-4.
    case quality(Double)
    /// Average bitrate in kbit/s.
    case bitrate(Int)
    case lossless
}

/// One audio track of the output.
struct VideoAudioTrackPlan: Equatable, Sendable {
    /// ffmpeg stream index in the input (`0:N`).
    var sourceStream: Int
    /// ffmpeg encoder name ("aac_at", "libmp3lame", "copy" ...).
    var encoder: String
    /// The `a.codec` id ("aac", "mp3", "opus", "flac", "alac", "ac3", "eac3", "pcm16", "pcm24", "vorbis", "copy").
    var codec: String
    var bitrateKbps: Int? = nil
    /// Native VBR quality value (`-q:a`) when `vbr`.
    var quality: Int? = nil
    var vbr = false
    var channels: Int? = nil
    var matrixDPL2 = false
    var sampleRate: Int? = nil
    /// Per-track filter chain (gain, compressor, loudness, speed, fades ...).
    var filters: [String] = []
    var name: String? = nil
    var language: String? = nil
    /// AC-3 decoder dynamic range compression (`-drc_scale`, an INPUT option of this stream).
    var drc: Double? = nil
}

struct VideoSubtitleTrackPlan: Equatable, Sendable {
    var sourceStream: Int
    /// "mov_text", "srt", "ass", "webvtt" or "copy" (bitmap tracks into MKV).
    var codec: String
    var language: String? = nil
    var isDefault = false
    var isForced = false
}

struct VideoExternalSubtitle: Equatable, Sendable {
    var file: URL
    var offsetMs: Int = 0
    /// "auto" or an IANA / Foundation encoding name ("windows-1251").
    var charset = "auto"
    var language: String? = nil
    var codec: String = "srt"
}

struct VideoChapter: Equatable, Sendable {
    var start: Double
    var title: String
}

enum VideoChapterPlan: Equatable, Sendable {
    case keepSource
    case none
    case custom([VideoChapter])
}

struct VideoMetadataPlan: Equatable, Sendable {
    /// keep, strip, custom
    var mode = "keep"
    var noGPS = false
    var keepCreationDate = true
    var tags: [String: String] = [:]
    var cover: URL? = nil
}

/// Everything the geometry / colour filters do, typed (the ffmpeg filter strings are derived from it; the AVFoundation route reads it directly).
struct VideoPicturePlan: Equatable, Sendable {
    struct Crop: Equatable, Sendable { var x: Int, y: Int, w: Int, h: Int }
    var applySAR = false
    var deinterlace: String? = nil          // bwdif / yadif / w3fdif
    var deinterlaceFields = false
    var ivtc = false
    var crop: Crop? = nil
    var rotate = 0
    var flipH = false
    var flipV = false
    var deblock: String? = nil              // weak / strong
    var denoise = 0                         // 0 off, 1 light, 2 medium, 3 strong
    var denoiseMethod = "hqdn3d"
    var chromaSmooth = 0
    var deband = false
    var scale: (w: Int, h: Int)? = nil      // target of the scale step (fill: the canvas; fit: the picture inside the canvas)
    var padCanvas: (w: Int, h: Int)? = nil  // fit / bars: the canvas the picture is centred on
    var scaleCover = false                  // fill: scale to cover, then crop to the canvas
    var anchor = "center"
    var anchorPoint: (x: Double, y: Double)? = nil
    var sharpen = 0
    var sharpenMethod = "unsharp"
    var pad: String? = nil                  // bars / border / blur
    var padColor = "#000000"
    var padBorder: (t: Int, b: Int, l: Int, r: Int)? = nil
    var gray = false
    var brightness = 0.0, contrast = 1.0, saturation = 1.0, gamma = 1.0
    var colorTemp: Int? = nil
    var stabilize = false
    var reverse = false
    var speed = 1.0
    var fps: Double? = nil                  // constant output rate (nil = keep)
    var fpsInterp = "drop"
    var scaler = "lanczos"
    var modulus = 2
    var fadeIn = 0.0, fadeOut = 0.0
    /// Final picture size when known (used by overlays, estimates and the AVFoundation route).
    var outputSize: (w: Int, h: Int)? = nil

    static func == (a: VideoPicturePlan, b: VideoPicturePlan) -> Bool {
        a.crop == b.crop && a.rotate == b.rotate && a.flipH == b.flipH && a.flipV == b.flipV && a.scale?.w == b.scale?.w && a.scale?.h == b.scale?.h
            && a.denoise == b.denoise && a.sharpen == b.sharpen && a.gray == b.gray && a.speed == b.speed && a.fps == b.fps
    }
}

/// Things drawn on top of the picture (rendered to PNG by VideoOverlayRenderer and composited with `overlay`).
enum VideoOverlay: Sendable {
    case watermarkImage(file: URL, widthPercent: Double, opacity: Double, position: String, margin: Int)
    case watermarkText(text: String, widthPercent: Double, opacity: Double, position: String, margin: Int)
    case burnIn(cues: [VideoCue], style: VideoBurnStyle)
}

struct VideoEncodePlan: Sendable {
    enum Backend: String, Sendable { case avfoundation, ffmpeg }
    var backend: Backend = .ffmpeg
    var container = "mp4"
    var videoCodec = "h264"
    var videoEncoder = "libx264"
    var audioCodec = "aac"
    /// Fixed filter order of spec/handbrake.md 2.5 (deinterlace, crop, rotate/flip, denoise, scale, sharpen, pad, colour, speed, fps, fades).
    var videoFilters: [String] = []
    /// How many of the LAST `videoFilters` (fades) must run after overlays (watermark, burned-in subtitles) are composited.
    var postOverlayFilterCount = 0
    var audioFilters: [String] = []
    var passes = 1
    var notes: [L10n] = []
    var estimatedDuration: Double?

    // MARK: additive members
    var hardware = false
    var rate: VideoRate = .quality(23)
    /// Encoder-specific arguments, complete (preset, tune, profile, level, keyframes, tag, x265 / SVT params ...), without the filter chain.
    var encoderOptions: [String] = []
    var pixelFormat: String? = nil
    var picture = VideoPicturePlan()
    var trimStart = 0.0
    var trimEnd: Double? = nil
    /// Copy the streams between the trim points (snaps to key frames).
    var copyTrim = false
    var noAutoRotate = false
    /// `-fps_mode` value: vfr, cfr or passthrough.
    var fpsMode = "vfr"
    var movFlagsFaststart = false
    var alignAV = false
    var noVideo = false
    var sourceVideoStream: Int? = nil
    var audioTracks: [VideoAudioTrackPlan] = []
    var subtitleTracks: [VideoSubtitleTrackPlan] = []
    var externalSubtitles: [VideoExternalSubtitle] = []
    var chapters: VideoChapterPlan = .keepSource
    var metadata = VideoMetadataPlan()
    var overlays: [VideoOverlay] = []
    /// Output duration (after trim and speed), seconds; drives progress and fades.
    var outputDuration: Double? = nil
    /// Target size requested (rate control "size"): the file must come out at or below it.
    var targetBytes: Int64? = nil
    var sourceDuration: Double? = nil
    var sourceSize: Int64? = nil
    var gif: VideoGifPlan? = nil
    /// Total bitrate budget bookkeeping for the size estimate.
    var audioKbpsTotal = 0
    var isRemux: Bool { videoCodec == "copy" }
}

struct VideoGifPlan: Equatable, Sendable {
    var fps = 15
    var width = 480
    var colors = 256
    var dither = "bayer"
    /// "forever", "once" or a count.
    var loop = "forever"
}

/// Results of the cheap analysis passes run before planning (all optional: the planner works without them).
struct VideoAnalysis: Sendable {
    /// Letterbox crop found by `cropdetect` (in display pixels).
    var crop: VideoPicturePlan.Crop? = nil
    /// `idet` verdict (true = interlaced).
    var interlaced: Bool? = nil
    /// `loudnorm` first-pass measurement for the two-pass normalisation.
    var loudness: LoudnessMeasurement? = nil
    /// Cues of the track to burn in, in SOURCE time.
    var burnCues: [VideoCue]? = nil
    /// Normalised (0...1, top-left origin) centre of the main subject for `size.anchor = smart`.
    var subjectCenter: (x: Double, y: Double)? = nil
    /// Key frame times near the trim start (for the V20 warning).
    var keyframeNearStart: Double? = nil
    /// Multiplier on the bitrate of a "target size" plan: the runner lowers it when a result came out over the target and raises it when far below.
    var bitrateScale = 1.0
}

struct LoudnessMeasurement: Equatable, Sendable {
    var inputI: Double, inputTP: Double, inputLRA: Double, inputThresh: Double, targetOffset: Double
}
