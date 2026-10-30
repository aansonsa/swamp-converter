import Foundation

// MODULE media-video owns Sources/Engines/Media/Common (shared by media-audio, smart, sizefit, intelligence). Prefix: Media* / FFmpeg* / Vid*.
// Spec: spec/handbrake.md 5.2 (pipeline), 2.14; spec/backends.md 3.2 (ffprobe, progress), 7.
// FROZEN API: the existing members of MediaStreamInfo / MediaChapterInfo / MediaInfo and the two MediaProbe functions. New members are additive.

enum MediaStreamKind: String, Codable, Sendable { case video, audio, subtitle, data, attachment }

struct MediaStreamInfo: Identifiable, Hashable, Sendable {
    var kind: MediaStreamKind
    /// Index in the container (the `0:N` of ffmpeg).
    var index: Int
    var codec: String
    var profile: String? = nil
    /// Coded size (before the rotation stored in the file is applied).
    var width: Int? = nil
    var height: Int? = nil
    var fps: Double? = nil
    var pixelFormat: String? = nil
    var bitDepth: Int? = nil
    var channels: Int? = nil
    var channelLayout: String? = nil
    var sampleRate: Int? = nil
    var bitRate: Int? = nil
    var language: String? = nil
    var title: String? = nil
    var isDefault = false
    var isForced = false
    var isAttachedPicture = false
    /// Degrees clockwise from the display matrix (phone footage): 0, 90, 180 or 270.
    var rotation: Int = 0
    var interlaced = false
    var isHDR = false
    var id: Int { index }

    // Additive members (defaults keep every existing initialiser call valid).
    /// `r_frame_rate` (the highest rate that represents every timestamp); equals `fps` for constant-rate footage.
    var maxFps: Double? = nil
    /// Frame rate is not constant (average differs from the base rate).
    var isVFR = false
    /// ffprobe `field_order`: progressive, tt, bb, tb, bt.
    var fieldOrder: String? = nil
    var colorPrimaries: String? = nil
    var colorTransfer: String? = nil
    var colorSpace: String? = nil
    var colorRange: String? = nil
    /// Sample aspect ratio (1 = square pixels).
    var sar: Double = 1
    /// Codec tag as ffprobe prints it (`hvc1`, `avc1`, `mp4a` ...).
    var codecTag: String? = nil
    var frameCount: Int? = nil
    var level: Int? = nil

    /// Picture size as it appears after the stored rotation is applied (square pixels NOT assumed: see `displaySize`).
    var rotatedSize: (width: Int, height: Int)? {
        guard let w = width, let h = height else { return nil }
        return rotation == 90 || rotation == 270 ? (h, w) : (w, h)
    }
    /// Picture size on screen: rotation applied and non-square pixels stretched to square ones (what ffmpeg produces with autorotate + setsar=1).
    var displaySize: (width: Int, height: Int)? {
        guard let w = width, let h = height else { return nil }
        // SAR describes the stored pixels: the stretch is applied to the width before the rotation.
        let sw = abs(sar - 1) < 0.005 ? w : Int((Double(w) * sar).rounded())
        return rotation == 90 || rotation == 270 ? (h, sw) : (sw, h)
    }
    /// Bitmap (picture) subtitle formats cannot be turned into text.
    var isBitmapSubtitle: Bool { kind == .subtitle && ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub", "pgssub", "dvdsub", "dvbsub"].contains(codec) }
}

struct MediaChapterInfo: Hashable, Sendable {
    var start: Double
    var end: Double
    var title: String
}

struct MediaInfo: Sendable {
    var url: URL
    var container: String
    var duration: Double?
    var bitRate: Int?
    var size: Int64?
    var streams: [MediaStreamInfo] = []
    var chapters: [MediaChapterInfo] = []
    var tags: [String: String] = [:]
    /// Additive: ffprobe `format_name` ("mov,mp4,m4a,3gp,3g2,mj2") or "avfoundation" when the fallback probe was used.
    var formatName = ""
    /// Additive: where the numbers came from.
    var viaFFprobe = true

    var videoStreams: [MediaStreamInfo] { streams.filter { $0.kind == .video && !$0.isAttachedPicture } }
    var audioStreams: [MediaStreamInfo] { streams.filter { $0.kind == .audio } }
    var subtitleStreams: [MediaStreamInfo] { streams.filter { $0.kind == .subtitle } }
    var hasAudio: Bool { !audioStreams.isEmpty }

    // Additive conveniences.
    var primaryVideo: MediaStreamInfo? { videoStreams.first }
    var hasVideo: Bool { primaryVideo != nil }
    var attachedPictures: [MediaStreamInfo] { streams.filter { $0.kind == .video && $0.isAttachedPicture } }
}

enum MediaProbe {
    /// ffprobe JSON (`-show_format -show_streams -show_chapters`) when ffprobe exists, else AVFoundation (mp4, mov, m4a, mp3, wav, flac ...).
    /// Never throws for "odd" files: unknown fields stay nil. Throws `ConversionError.fileUnreadable` when nothing can read the file.
    /// Caching is done by SourceProbeRegistry.
    static func probe(_ url: URL, tools: ToolLocator = .shared) async throws -> MediaInfo {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.fileUnreadable(url) }
        try Task.checkCancellation()
        if MediaToolset.ffprobeUsable(tools), let ffprobe = tools.url(.ffprobe) {
            do {
                if let info = try await probeWithFFprobe(url, ffprobe: ffprobe) { return info }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // fall through to AVFoundation: ffprobe failing on an odd file must not end the probe
            }
        }
        try Task.checkCancellation()
        if let info = await probeWithAVFoundation(url) { return info }
        throw ConversionError.fileUnreadable(url)
    }

    /// Maps MediaInfo onto the conventional SourceInfo facts (video.*, audio.<N>.*, sub.*, chapters.count ...), chips and streams
    /// (see the header of Core/SourceInfo.swift). Used by the audio AND video probes. Implemented in MediaSourceInfo.swift.
    static func sourceInfo(from info: MediaInfo, kind: FileKind) -> SourceInfo {
        MediaSourceMapper.map(info, kind: kind)
    }
}
