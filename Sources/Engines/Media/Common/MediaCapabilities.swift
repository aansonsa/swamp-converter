import Foundation
import AVFoundation
import VideoToolbox

/// Capability ids of the media modules, registered once (`MediaCapabilities.register()` from VideoEngine/AudioEngine; idempotent).
/// Ids: `native.av.export.<preset>`, `native.vt.h264`, `native.vt.hevc`, `native.vt.prores` (an encoder exists), `native.vt.hevc.hw` / `native.vt.h264.hw`
/// (a hardware encoder exists), `native.audio.encode.<codec>` (aac, alac, flac, pcm), `media.hdr2sdr`;
/// ffmpeg ids (`ff.enc.libx264`, `ff.filter.bwdif`, `ff.mux.webm`) come from Core's Capabilities automatically.
enum MediaCapabilities {
    /// Export presets that have a capability id (`native.av.export.<id>`); the id is the preset name without "AVAssetExportPreset", lower-cased.
    static let exportPresetNames = ["Passthrough", "LowQuality", "MediumQuality", "HighestQuality", "640x480", "960x540", "1280x720", "1920x1080", "3840x2160",
                                    "HEVC1920x1080", "HEVC3840x2160", "HEVC7680x4320", "HEVCHighestQuality", "AppleM4A", "AppleProRes422LPCM", "AppleProRes4444LPCM"]

    static func register() {
        let caps = Capabilities.shared
        caps.register("native.vt.h264") { VTAvailability.shared.has(kCMVideoCodecType_H264) }
        caps.register("native.vt.hevc") { VTAvailability.shared.has(kCMVideoCodecType_HEVC) }
        caps.register("native.vt.prores") { VTAvailability.shared.has(kCMVideoCodecType_AppleProRes422) }
        caps.register("native.vt.h264.hw") { VTAvailability.shared.hasHardware(kCMVideoCodecType_H264) }
        caps.register("native.vt.hevc.hw") { VTAvailability.shared.hasHardware(kCMVideoCodecType_HEVC) }
        caps.register("native.vt.prores.hw") { VTAvailability.shared.hasHardware(kCMVideoCodecType_AppleProRes422) }
        for name in exportPresetNames {
            let full = "AVAssetExportPreset" + name
            caps.register("native.av.export.\(name.lowercased())") { AVAssetExportSession.allExportPresets().contains(full) }
        }
        // AudioToolbox on macOS 26 encodes these natively (spec/handbrake.md 0.4); MP3, AC-3 and Vorbis need ffmpeg.
        for codec in ["aac", "alac", "flac", "pcm"] { caps.register("native.audio.encode.\(codec)") { true } }
        // HDR -> SDR needs zscale+tonemap or libplacebo in ffmpeg; the AVFoundation route is unverified and therefore not offered.
        caps.register("media.hdr2sdr") {
            guard let f = Capabilities.shared.ffmpeg() else { return false }
            return (f.filters.contains("zscale") && f.filters.contains("tonemap")) || f.filters.contains("libplacebo")
        }
    }

    // MARK: Container x codec compatibility (spec/handbrake.md 2.12)

    /// Video codec ids: h264 hevc av1 vp9 vp8 prores dnxhr ffv1 mpeg4 (and "copy", which depends on the source: true here).
    static func containerSupports(_ container: String, videoCodec: String) -> Bool {
        if videoCodec == "copy" { return true }
        switch container {
        case "mp4": return ["h264", "hevc", "av1", "vp9", "mpeg4"].contains(videoCodec)
        case "mov": return ["h264", "hevc", "prores", "dnxhr", "mpeg4"].contains(videoCodec)
        case "mkv": return ["h264", "hevc", "av1", "vp9", "vp8", "prores", "dnxhr", "ffv1", "mpeg4"].contains(videoCodec)
        case "webm": return ["vp8", "vp9", "av1"].contains(videoCodec)
        case "avi": return ["h264", "mpeg4"].contains(videoCodec)
        case "gif": return videoCodec == "gif"
        default: return true
        }
    }

    /// Audio codec ids: aac mp3 opus flac alac ac3 eac3 pcm16 pcm24 vorbis (ffprobe names such as `pcm_s16le` and `dts` are normalised).
    static func containerSupports(_ container: String, audioCodec codec: String) -> Bool {
        let c = normalizeAudio(codec)
        if c == "copy" || c == "none" { return true }
        switch container {
        case "mp4": return ["aac", "mp3", "opus", "flac", "alac", "ac3", "eac3"].contains(c)
        case "mov": return ["aac", "mp3", "opus", "flac", "alac", "ac3", "eac3", "pcm16", "pcm24"].contains(c)
        case "mkv": return true
        case "webm": return ["opus", "vorbis"].contains(c)
        case "avi": return ["aac", "mp3", "ac3", "pcm16", "pcm24"].contains(c)
        case "gif": return false
        default: return true
        }
    }

    static func normalizeAudio(_ codec: String) -> String {
        let c = codec.lowercased()
        if c.hasPrefix("pcm_s16") || c == "pcm_u8" { return "pcm16" }
        if c.hasPrefix("pcm_s24") || c.hasPrefix("pcm_s32") || c.hasPrefix("pcm_f") { return "pcm24" }
        return c
    }

    /// Text subtitle codec ffmpeg should write for a container (nil = the container cannot hold text subtitles).
    static func textSubtitleCodec(for container: String) -> String? {
        switch container {
        case "mp4", "mov": return "mov_text"
        case "mkv": return "srt"
        case "webm": return "webvtt"
        default: return nil
        }
    }

    /// Chapters can be stored (spec 2.12).
    static func supportsChapters(_ container: String) -> Bool { ["mp4", "mov", "mkv", "webm"].contains(container) }
}

/// VideoToolbox encoder inventory, queried once (a few milliseconds) on first use.
final class VTAvailability: @unchecked Sendable {
    static let shared = VTAvailability()
    private let lock = NSLock()
    private var all: Set<UInt32>?
    private var hardware: Set<UInt32>?

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard all == nil else { return }
        var list: CFArray?
        var a = Set<UInt32>(), h = Set<UInt32>()
        if VTCopyVideoEncoderList(nil, &list) == 0, let entries = list as? [[CFString: Any]] {
            for e in entries {
                guard let t = (e[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value else { continue }
                a.insert(t)
                if (e[kVTVideoEncoderList_IsHardwareAccelerated] as? NSNumber)?.boolValue == true { h.insert(t) }
            }
        }
        all = a; hardware = h
    }
    func has(_ codec: CMVideoCodecType) -> Bool { load(); return all?.contains(codec) ?? false }
    func hasHardware(_ codec: CMVideoCodecType) -> Bool { load(); return hardware?.contains(codec) ?? false }
}

/// A value snapshot of what this Mac can do: the located ffmpeg's encoders / filters / muxers plus native encoders.
/// Planners take it as a parameter so routing and fallbacks are testable without touching the real tools.
struct MediaToolset: Sendable {
    var hasFFmpeg = false
    var hasFFprobe = false
    var ffmpegVersion = ""
    var encoders: Set<String> = []
    var filters: Set<String> = []
    var muxers: Set<String> = []
    var nativeH264 = true
    var nativeHEVC = true
    var nativeProRes = true

    func hasEncoder(_ name: String) -> Bool { hasFFmpeg && encoders.contains(name) }
    func hasFilter(_ name: String) -> Bool { hasFFmpeg && filters.contains(name) }
    func hasMuxer(_ name: String) -> Bool { hasFFmpeg && muxers.contains(name) }

    /// Test hook: when set, replaces the detected toolset (self-tests of routing, the no-ffmpeg route and capability gating). Always restore it.
    static let override = Locked<MediaToolset?>(nil)

    static var current: MediaToolset { override.value ?? detect() }

    static func detect(capabilities: Capabilities = .shared, tools: ToolLocator = .shared) -> MediaToolset {
        var t = MediaToolset()
        t.hasFFprobe = tools.has(.ffprobe)
        t.nativeH264 = VTAvailability.shared.has(kCMVideoCodecType_H264)
        t.nativeHEVC = VTAvailability.shared.has(kCMVideoCodecType_HEVC)
        t.nativeProRes = VTAvailability.shared.has(kCMVideoCodecType_AppleProRes422)
        if tools.has(.ffmpeg), let f = capabilities.ffmpeg() {
            t.hasFFmpeg = true
            t.ffmpegVersion = f.version
            t.encoders = f.encoders; t.filters = f.filters; t.muxers = f.muxers
        }
        return t
    }

    /// ffprobe may be used (a test override can switch it off to exercise the AVFoundation probe).
    static func ffprobeUsable(_ tools: ToolLocator) -> Bool {
        if let o = override.value { return o.hasFFprobe && tools.has(.ffprobe) }
        return tools.has(.ffprobe)
    }
}
