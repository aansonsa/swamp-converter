import Foundation

// Value types of the downloader: what `yt-dlp -J` tells us (formats, playlists), the quality ladder, and a download request.
// Pure data, no I/O. The JSON -> model mapping is `YtDlpInfoParser`; the model -> yt-dlp argv mapping is `YtDlpArguments`.

struct DownloadFormat: Identifiable, Hashable, Sendable {
    /// yt-dlp `format_id` ("137", "251", "hls-1080").
    var id: String
    var ext: String
    /// "avc1.640028", "vp09.00.40.08", "av01.0.12M.10", "hev1.1.6.L150", "none" for audio-only.
    var vcodec: String
    var acodec: String
    var width: Int?
    var height: Int?
    var fps: Double?
    /// "SDR", "HDR10", "HLG", "DV" (yt-dlp `dynamic_range`).
    var dynamicRange: String?
    var filesize: Int64?
    var filesizeApprox: Int64?
    /// Average bitrate in kbit/s.
    var tbr: Double?
    var note: String?
    /// Audio language ("en", "ru") when the page offers several dubbed tracks. Added by the downloader module.
    var language: String? = nil
    /// The page marks the format as DRM-protected: it is never offered and never selected.
    var hasDRM = false
    var isVideoOnly: Bool { vcodec != "none" && acodec == "none" }
    var isAudioOnly: Bool { vcodec == "none" && acodec != "none" }
    var isHDR: Bool { (dynamicRange ?? "SDR") != "SDR" }
    var bytes: Int64? { filesize ?? filesizeApprox }

    enum CodecFamily: String, Sendable { case av1 = "AV1", vp9 = "VP9", h264 = "H.264", hevc = "HEVC", other = "other", none = "none" }
    /// Family of the video codec string.
    var codecFamily: CodecFamily {
        let c = vcodec.lowercased()
        if c == "none" { return .none }
        if c.hasPrefix("av01") || c.hasPrefix("av1") { return .av1 }
        if c.hasPrefix("vp9") || c.hasPrefix("vp09") { return .vp9 }
        if c.hasPrefix("avc") || c.hasPrefix("h264") { return .h264 }
        if c.hasPrefix("hev") || c.hasPrefix("hvc") || c.hasPrefix("h265") { return .hevc }
        return .other
    }
}

struct DownloadSubtitleTrack: Hashable, Sendable {
    var language: String
    var name: String?
    /// True for automatic captions.
    var isAutomatic: Bool
}

/// One entry of a playlist / channel listing (`--flat-playlist`).
struct PlaylistEntry: Identifiable, Hashable, Sendable {
    var index: Int
    var id: String
    var title: String
    var url: URL?
    var duration: Double?
    var thumbnail: URL?
    var channel: String?
}

struct DownloadInfo: Sendable {
    var id: String
    var webpageURL: URL
    var title: String
    var channel: String?
    var duration: Double?
    var thumbnail: URL?
    var uploadDate: String?
    var extractor: String?
    var isLive: Bool = false
    var formats: [DownloadFormat] = []
    var subtitles: [DownloadSubtitleTrack] = []
    var chapters: [MediaChapterInfo] = []
    /// Non-empty for playlists and channels (then `formats` is empty: fetch each entry for its own formats).
    var entries: [PlaylistEntry] = []
    /// The page is a list (playlist, channel, album) even when it has no entries (an empty or fully private list).
    var isListing = false
    var isPlaylist: Bool { isListing || !entries.isEmpty }
}

/// One line of the quality picker ("2160p", codec, fps, HDR, estimated size) and the yt-dlp selector that gets it.
struct QualityOption: Identifiable, Hashable, Sendable {
    /// 4320, 2160, 1440, 1080, 720, 480, 360, 240, 144 (0 = best available / unknown).
    var height: Int
    var label: String
    var codec: DownloadFormat.CodecFamily
    var fps: Double?
    var isHDR: Bool
    var estimatedBytes: Int64?
    /// The `-f` expression capping the height (e.g. "bv*[height<=1080]+ba/b[height<=1080]").
    var selector: String
    var id: String { "\(height)-\(codec.rawValue)-\(isHDR)" }
}

enum DownloadSubtitleMode: String, Codable, Sendable { case none, soft, external, burn }
enum DownloadAudioFormat: String, Codable, Sendable { case m4a, mp3, opus, flac }

/// Everything `YtDlpArguments.build` needs. Built by `DownloadService.start(...)` from the mode + settings, or by the Studio/download sheet.
struct DownloadRequest: Equatable, Sendable {
    var url: URL
    var mode: DownloadMode = .bestForApple
    /// Quality cap in pixels (nil = best).
    var maxHeight: Int? = nil
    /// Overrides the selector derived from `mode` / `maxHeight` (advanced).
    var formatSelector: String? = nil
    var audioFormat: DownloadAudioFormat = .m4a
    /// Audio conversion quality: 0 = best (VBR), otherwise kbit/s.
    var audioQuality: Int = 0
    /// Playlist items "1,3,5-7"; nil = the single video (`--no-playlist`).
    var playlistItems: String? = nil
    var subtitles: DownloadSubtitleMode = .none
    var subtitleLanguages: [String] = []
    /// `--download-sections "*start-end"` in seconds.
    var sectionStart: Double? = nil
    var sectionEnd: Double? = nil
    var embedMetadata = true
    var embedThumbnail = true
    var filenameTemplate = "%(title).150B [%(id)s].%(ext)s"
    var cookies: CookieBrowser = .none
    var rateLimitKBps = 0
    /// Parts fetched at the same time (`--concurrent-fragments`); 1 = yt-dlp's default, no flag.
    var concurrentFragments = 1
    /// Every output path is confined to this folder (`-P`); nothing is ever written outside it.
    var outputDirectory: URL
    var after: AfterDownload = .bestForApple
    /// Where yt-dlp keeps partial files (`-P temp:`); nil = inside `outputDirectory`. The job runner sets a hidden folder next to the output.
    var workDirectory: URL? = nil
    /// File that receives the final path of every downloaded file (`--print-to-file after_move:filepath`).
    var resultListFile: URL? = nil
}

/// Progress of a yt-dlp run parsed from its output.
struct DownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case fetchingInfo, downloading, merging, extractingAudio, embedding, finished }
    var phase: Phase
    /// 0...1 of the current file (nil when unknown).
    var fraction: Double?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var eta: TimeInterval?
    /// Which file of a playlist (1-based) and how many.
    var itemIndex: Int?
    var itemCount: Int?
    var fileName: String?
}
