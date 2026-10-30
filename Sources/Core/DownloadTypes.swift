import Foundation

// Small value types shared by the downloader, the smart-transcode engine, the wheel, the URL scheme, the CLI and Settings.
// They live in Core so that settings and the URL scheme can mention them without depending on an engine.

/// How the Apple-friendly conversion treats a video (the "smart transcode" modes).
enum SmartMode: String, Codable, CaseIterable, Sendable {
    /// Default. Remux when the streams are already Apple-friendly, otherwise HEVC (hvc1, 10-bit/HDR kept) + AAC/ALAC in MP4.
    case bestForApple = "best"
    /// Keep the source quality: no transcode, MKV/WebM remux where needed.
    case maximum = "max"
    /// H.264 up to 1080p + AAC in MP4: plays on anything.
    case universal = "universal"

    var title: L10n {
        switch self {
        case .bestForApple: return L10n("Best for Apple", "Лучшее для Apple")
        case .maximum: return L10n("Maximum quality", "Максимальное качество")
        case .universal: return L10n("Universal", "Универсальный")
        }
    }
    var subtitle: L10n {
        switch self {
        case .bestForApple: return L10n("HEVC, plays on Apple devices", "HEVC, играет на устройствах Apple")
        case .maximum: return L10n("keep the source, no re-encoding", "как в источнике, без перекодирования")
        case .universal: return L10n("H.264 up to 1080p, plays anywhere", "H.264 до 1080p, играет везде")
        }
    }
    /// One or two sentences for a form: what the mode does and when to pick it.
    var explanation: L10n {
        switch self {
        case .bestForApple: return L10n("HEVC, plays on Apple devices. Converted only when the video would not play on a Mac as it is.", "HEVC, играет на устройствах Apple. Конвертируется, только если видео иначе не играет на Mac.")
        case .maximum: return L10n("Exactly what the site stores, with no re-encoding (MKV or WebM when needed).", "Ровно то, что хранит сайт, без перекодирования (при необходимости MKV или WebM).")
        case .universal: return L10n("H.264 up to 1080p with AAC sound: plays on anything.", "H.264 до 1080p со звуком AAC: играет везде.")
        }
    }
    var symbol: String {
        switch self {
        case .bestForApple: return "apple.logo"
        case .maximum: return "sparkles"
        case .universal: return "globe"
        }
    }
}

/// The sectors of the LINK wheel (and the values of `swampconverter://download?mode=`).
enum DownloadMode: String, Codable, CaseIterable, Sendable {
    case bestForApple = "best"
    case maximum = "max"
    case universal = "universal"
    case audioM4A = "audio-m4a"
    case audioMP3 = "audio-mp3"

    /// Parses the `mode` URL parameter / CLI value; accepts the raw values plus a few friendly aliases. Unknown -> nil.
    init?(parameter: String?) {
        guard let p = parameter?.trimmingCharacters(in: .whitespaces).lowercased(), !p.isEmpty else { return nil }
        switch p {
        case "best", "apple", "best-for-apple", "mac": self = .bestForApple
        case "max", "maximum", "source", "original": self = .maximum
        case "universal", "compat", "h264": self = .universal
        case "audio-m4a", "m4a", "audio", "aac": self = .audioM4A
        case "audio-mp3", "mp3": self = .audioMP3
        default: return nil
        }
    }

    /// The post-download conversion this mode implies (nil for audio-only modes: the audio is extracted by yt-dlp/ffmpeg).
    var smartMode: SmartMode? {
        switch self {
        case .bestForApple: return .bestForApple
        case .maximum: return .maximum
        case .universal: return .universal
        case .audioM4A, .audioMP3: return nil
        }
    }
    var isAudioOnly: Bool { self == .audioM4A || self == .audioMP3 }

    var title: L10n {
        switch self {
        case .bestForApple: return L10n("Best for Apple", "Лучшее для Apple")
        case .maximum: return L10n("Maximum quality", "Максимальное качество")
        case .universal: return L10n("Universal", "Универсальный")
        case .audioM4A: return L10n("Audio M4A", "Аудио M4A")
        case .audioMP3: return L10n("Audio MP3", "Аудио MP3")
        }
    }
    var symbol: String {
        switch self {
        case .bestForApple: return "apple.logo"
        case .maximum: return "sparkles"
        case .universal: return "globe"
        case .audioM4A, .audioMP3: return "waveform"
        }
    }
}

/// What happens after a download finished (the optional second stage of a download job).
enum AfterDownload: Codable, Equatable, Hashable, Sendable {
    case keepOriginal
    case bestForApple
    case universal
    /// A Studio preset id (any `video.convert` preset, built-in or user).
    case preset(String)

    var smartMode: SmartMode? {
        switch self { case .bestForApple: return .bestForApple; case .universal: return .universal; default: return nil }
    }

    // Stored as a plain string ("keep", "best", "universal", "preset:<id>") so settings files stay readable.
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = AfterDownload(string: s) ?? .bestForApple
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
    init?(string: String) {
        switch string {
        case "keep": self = .keepOriginal
        case "best": self = .bestForApple
        case "universal": self = .universal
        default:
            guard string.hasPrefix("preset:"), string.count > 7 else { return nil }
            self = .preset(String(string.dropFirst(7)))
        }
    }
    var stringValue: String {
        switch self {
        case .keepOriginal: return "keep"
        case .bestForApple: return "best"
        case .universal: return "universal"
        case .preset(let id): return "preset:" + id
        }
    }
}

enum CookieBrowser: String, Codable, CaseIterable, Sendable {
    case none, safari, chrome, firefox, edge, brave
    var title: L10n {
        switch self {
        case .none: return L10n("Don’t use cookies", "Не использовать cookies")
        case .safari: return L10n("Safari")
        case .chrome: return L10n("Google Chrome")
        case .firefox: return L10n("Firefox")
        case .edge: return L10n("Microsoft Edge")
        case .brave: return L10n("Brave")
        }
    }
    /// The value of yt-dlp's `--cookies-from-browser` (nil = no cookies).
    var ytDlpName: String? { self == .none ? nil : rawValue }
}

/// Settings of the link downloader (a field of `SettingsData`). Nothing here is used until the user has given consent.
struct DownloaderSettings: Codable, Equatable, Sendable {
    /// The user read the first-use notice (network + third-party tool) and agreed. Nothing downloads before this is true.
    var consentGiven = false
    /// Folder for finished downloads; nil = ~/Movies/Swamp Converter (video) / ~/Music/Swamp Converter (audio).
    var folder: String? = nil
    var afterDownload: AfterDownload = .bestForApple
    var cookies: CookieBrowser = .none
    /// KB/s; 0 = unlimited.
    var rateLimitKBps = 0
    /// Parts of one video fetched at the same time (yt-dlp `--concurrent-fragments`); nil = the default (4). YouTube serves 1080p and above as many small pieces, so a few in
    /// parallel is much faster. Optional on purpose: a settings file written before this field existed still decodes.
    var concurrentFragments: Int? = nil
    /// The value in use, always 1...8.
    var fragments: Int { min(max(concurrentFragments ?? 4, 1), 8) }
    /// What the app checked when it installed or updated yt-dlp itself: the release version and the SHA-256 that matched the official checksum file. nil for a copy managed elsewhere
    /// (Homebrew, PATH) and before the first install. Settings shows it and re-checks that the file on disk is still the one that was verified.
    var verifiedInstall: VerifiedInstall? = nil

    struct VerifiedInstall: Codable, Equatable, Sendable {
        var version: String
        var sha256: String
        /// Seconds since 1970.
        var date: Double
    }
    /// yt-dlp output template WITHOUT directory ("%(title)s [%(id)s].%(ext)s").
    var filenameTemplate = "%(title).150B [%(id)s].%(ext)s"
    var embedMetadata = true
    var embedThumbnail = true
    var subtitles = false
    var subtitleLanguages = "en"
    var burnSubtitles = false
    /// Check GitHub for a newer yt-dlp when the downloader is used (off by default: it is a network call).
    var checkForUpdates = false
    /// Mode used by the one-key "download the current page" hotkey and by `swampconverter://download` without `mode`.
    var defaultMode: DownloadMode = .bestForApple
    /// Last time the update check ran (seconds since 1970), for throttling to once a day.
    var lastUpdateCheck: Double = 0
    /// The first-use sheet for the Automation permission of the browser readers was shown.
    var browserAutomationExplained = false
}
