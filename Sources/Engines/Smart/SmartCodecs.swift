import Foundation

// Pure vocabulary of the smart-transcode planner: codec / container names normalised to one spelling, and the "what plays on Apple software"
// tables. ffprobe says "h264" / "hevc" / "mpeg2video"; AVFoundation says "avc1" / "hvc1" / "mp4a"; this file maps both onto one set.

enum SmartCodec {
    /// h264, hevc, vp9, av1, vp8, mpeg2, mpeg4, vc1, prores, mjpeg, ... (unknown names come back lower-cased).
    static func video(_ raw: String?) -> String {
        let s = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch s {
        case "h264", "avc", "avc1", "avc3", "x264", "h.264": return "h264"
        case "hevc", "h265", "hvc1", "hev1", "dvh1", "dvhe", "h.265", "x265": return "hevc"
        case "vp9", "vp09": return "vp9"
        case "vp8", "vp08": return "vp8"
        case "av1", "av01": return "av1"
        case "mpeg2video", "mpeg2", "mp2v", "mpeg-2": return "mpeg2"
        case "mpeg4", "mp4v", "xvid", "divx", "dx50": return "mpeg4"
        case "mpeg1video", "mpeg1": return "mpeg1"
        case "vc1", "wvc1", "wmv3", "wmv1", "wmv2", "msmpeg4v3", "msmpeg4v2": return "vc1"
        case "prores", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "prores"
        default: return s
        }
    }

    /// aac, alac, mp3, ac3, eac3, flac, opus, vorbis, dts, truehd, pcm, ...
    static func audio(_ raw: String?) -> String {
        let s = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("pcm_") || s == "lpcm" || s == "sowt" || s == "twos" || s == "in24" || s == "lpcm " { return "pcm" }
        switch s {
        case "aac", "mp4a", "aac_latm", "aac_at": return "aac"
        case "alac": return "alac"
        case "mp3", "mp3float", ".mp3", "mp3adu", "mp3adufloat": return "mp3"
        case "ac3", "ac-3", "a52": return "ac3"
        case "eac3", "ec-3", "e-ac-3": return "eac3"
        case "flac": return "flac"
        case "opus": return "opus"
        case "vorbis": return "vorbis"
        case "dts", "dca", "dtsh", "dtsc", "dtse", "dtsl": return "dts"
        case "truehd", "mlp": return "truehd"
        case "wmav1", "wmav2", "wmapro": return "wma"
        default: return s
        }
    }

    /// Lossless audio codecs: re-encoding them to AAC would throw quality away (they go to ALAC when the track has to change).
    static func isLosslessAudio(_ codec: String) -> Bool { ["flac", "alac", "pcm", "truehd"].contains(codec) }

    private static let textSubs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "subviewer", "subviewer1", "microdvd", "ttml",
                                                "sami", "realtext", "stl", "jacosub", "mpl2", "pjs", "vplayer", "tx3g"]
    private static let bitmapSubs: Set<String> = ["hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub", "xsub", "dvb_teletext"]

    static func isTextSubtitle(_ raw: String?) -> Bool { textSubs.contains((raw ?? "").lowercased()) }
    static func isBitmapSubtitle(_ raw: String?) -> Bool { bitmapSubs.contains((raw ?? "").lowercased()) }
}

/// Container vocabulary. ffprobe reports "mov,mp4,m4a,3gp,3g2,mj2" for the whole QuickTime family and "matroska,webm" for both Matroska flavours,
/// so the file extension decides between the siblings.
enum SmartContainer {
    /// mp4, mov, mkv, webm, avi, ts, other
    static func kind(of info: MediaInfo) -> String {
        let name = info.container.lowercased()
        let ext = info.url.pathExtension.lowercased()
        if name.contains("matroska") || name.contains("webm") {
            if ext == "webm" { return "webm" }
            if ext == "mkv" || ext == "mka" { return "mkv" }
            return name == "webm" ? "webm" : "mkv"
        }
        if name.contains("mov") || name.contains("mp4") || name.contains("m4a") || name.contains("3gp") {
            return ext == "mov" || ext == "qt" ? "mov" : "mp4"
        }
        if name.contains("avi") { return "avi" }
        if name.contains("mpegts") || name == "mpegts" { return "ts" }
        switch ext {
        case "mp4", "m4v", "3gp", "3g2": return "mp4"
        case "mov", "qt": return "mov"
        case "mkv": return "mkv"
        case "webm": return "webm"
        case "avi": return "avi"
        case "ts", "mts", "m2ts": return "ts"
        default: return "other"
        }
    }

    static func fileExtension(_ container: String) -> String {
        switch container {
        case "mov": return "mov"
        case "mkv": return "mkv"
        case "webm": return "webm"
        default: return "mp4"
        }
    }

    static func isQuickTimeFamily(_ container: String) -> Bool { container == "mp4" || container == "mov" }
}

/// What Apple software (QuickTime Player, Safari, iPhone, Apple TV) opens without help.
enum SmartApple {
    /// Audio that can be stream-copied into `container` and still plays on Apple devices.
    static func audioIsFriendly(_ codec: String, container: String) -> Bool {
        switch container {
        case "mkv", "webm": return true               // Matroska holds anything; "friendly" is moot there
        case "mov": return ["aac", "alac", "mp3", "ac3", "eac3", "pcm"].contains(codec)
        default: return ["aac", "alac", "mp3", "ac3", "eac3"].contains(codec)
        }
    }

    /// The source video stream can be copied into an Apple-friendly MP4 / MOV as it is.
    static func videoIsFriendly(_ v: MediaStreamInfo, sourceContainer: String, facts: SmartVideoFacts) -> Bool {
        let codec = SmartCodec.video(v.codec)
        let pix = (v.pixelFormat ?? facts.pixelFormat ?? "").lowercased()
        let depth = v.bitDepth ?? SmartVideoFacts.bitDepth(ofPixelFormat: pix)
        let chromaOK = pix.isEmpty || pix.contains("420") || pix.contains("nv12") || pix.contains("nv21") || pix.hasPrefix("p010") || pix.hasPrefix("yuvj420")
        let profile = (v.profile ?? "").lowercased()
        switch codec {
        case "h264":
            if let d = depth, d > 8 { return false }
            if profile.contains("high 10") || profile.contains("4:2:2") || profile.contains("4:4:4") || profile.contains("intra") || profile.contains("hi10") { return false }
            return chromaOK
        case "hevc":
            if let d = depth, d > 10 { return false }
            if profile.contains("rext") || profile.contains("4:2:2") || profile.contains("4:4:4") || profile.contains("12") || profile.contains("scc") { return false }
            return chromaOK
        case "prores":
            return sourceContainer == "mov"
        default:
            return false
        }
    }
}
