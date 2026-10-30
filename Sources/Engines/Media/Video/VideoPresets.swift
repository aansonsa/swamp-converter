import Foundation

// Built-in presets of the video target (spec/handbrake.md 4.2) and the quick recipes of the wheel operations (4.6, catalog 6.2).
// Values are sparse over the schema defaults. The rest of every preset is: MP4, optimised for streaming, first audio track as AAC 160 kbit/s stereo,
// chapters and metadata kept, no subtitles added by the preset itself unless it says so.

enum VideoPresets {
    private static func p(_ id: String, _ en: String, _ ru: String, note: L10n? = nil, symbol: String = "film", group: PresetGroup, _ values: OptionValues) -> Preset {
        .builtin(id, target: VideoSchemas.convertID, L10n(en, ru), notes: note, symbol: symbol, group: group, values)
    }

    /// The common web recipe: H.264 High with the software encoder, never above `height` and `fps`.
    private static func web(_ cq: Int, limit: String, fps: String = "30", abr: String = "160", extra: OptionValues = [:]) -> OptionValues {
        var v: OptionValues = [VideoKeys.vcodec: "h264", VideoKeys.venc: "software", VideoKeys.cq: .int(cq), VideoKeys.speed: "medium", VideoKeys.profile: "high",
                               VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: .string(limit), VideoKeys.fpsMode: "peak", VideoKeys.fps: .string(fps), VideoKeys.audioBitrate: .string(abr)]
        for (k, x) in extra.storage { v[k] = x }
        return v
    }

    private static func fit(_ mb: Double, abr: String = "96", extra: OptionValues = [:]) -> OptionValues {
        var v: OptionValues = [VideoKeys.rateControl: "size", VideoKeys.targetMB: .double(mb), VideoKeys.sizeLadder: true, VideoKeys.twoPass: true, VideoKeys.vcodec: "h264",
                               VideoKeys.venc: "software", VideoKeys.speed: "medium", VideoKeys.profile: "main", VideoKeys.audioBitrate: .string(abr), VideoKeys.fpsMode: "peak",
                               VideoKeys.fps: "30", VideoKeys.metadataNoGPS: true]
        for (k, x) in extra.storage { v[k] = x }
        return v
    }

    static let builtins: [Preset] = [
        p("vid.web.1080", "Web 1080p", "Веб 1080p", note: L10n("Plays everywhere. Never larger than 1080p or 30 fps.", "Открывается везде. Не больше 1080p и 30 к/с."), group: .web, web(22, limit: "1080p")),
        p("vid.web.1080p60", "Web 1080p, 60 fps", "Веб 1080p, 60 к/с", group: .web, web(20, limit: "1080p", fps: "60", abr: "256", extra: [VideoKeys.audioRate: "48000"])),
        p("vid.web.720", "Web 720p", "Веб 720p", group: .web, web(21, limit: "720p", abr: "128")),
        p("vid.web.480", "Small web 480p", "Лёгкий 480p", group: .smallSize, web(21, limit: "480p", abr: "96")),
        p("vid.balanced", "Compress, compatible", "Сжать, совместимо", note: L10n("The wheel’s Compress recipe: H.264, plays everywhere.", "Рецепт «Сжать» с колеса: H.264, открывается везде."), symbol: "arrow.down.right.and.arrow.up.left",
          group: .smallSize, web(24, limit: "1080p", abr: "128", extra: [VideoKeys.speed: "slow"])),
        p("vid.small", "Smallest size (HEVC)", "Минимальный размер (HEVC)", note: L10n("About 40% smaller than H.264; needs newer devices.", "Примерно на 40 % меньше H.264; нужны новые устройства."),
          symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize,
          [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.cq: 28, VideoKeys.speed: "medium", VideoKeys.bitdepth: "10", VideoKeys.appleTag: true, VideoKeys.sizeMode: "limit",
           VideoKeys.sizeLimit: "1080p", VideoKeys.fpsMode: "peak", VideoKeys.fps: "30", VideoKeys.audioBitrate: "96"]),
        p("vid.4k.hevc", "4K HEVC", "4K HEVC", group: .devices,
          [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.cq: 24, VideoKeys.speed: "medium", VideoKeys.bitdepth: "10", VideoKeys.appleTag: true, VideoKeys.sizeMode: "limit",
           VideoKeys.sizeLimit: "2160p", VideoKeys.fpsMode: "peak", VideoKeys.fps: "60", VideoKeys.audioBitrate: "192"]),
        p("vid.archive", "Archive quality (HEVC 10-bit)", "Архивное качество (HEVC 10 бит)", note: L10n("Keeps every audio and subtitle track, the resolution and the frame rate.", "Сохраняет все звуковые дорожки и субтитры, разрешение и частоту кадров."),
          symbol: "archivebox", group: .archive,
          [VideoKeys.container: "mkv", VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.cq: 18, VideoKeys.speed: "slow", VideoKeys.bitdepth: "10", VideoKeys.audioMode: "all",
           VideoKeys.audioCodec: "copy", VideoKeys.audioPassMask: "all", VideoKeys.audioFallback: "aac", VideoKeys.subMode: "keep", VideoKeys.deinterlace: "off"]),
        p("vid.master", "Master, ProRes 422 HQ", "Мастер, ProRes 422 HQ", note: L10n("About 220 Mbit/s at 1080p30. For editing and archives.", "Около 220 Мбит/с при 1080p30. Для монтажа и архива."), symbol: "film.stack", group: .lossless,
          [VideoKeys.container: "mov", VideoKeys.faststart: false, VideoKeys.vcodec: "prores", VideoKeys.profile: "hq", VideoKeys.venc: "auto", VideoKeys.bitdepth: "10", VideoKeys.chroma: "4:2:2",
           VideoKeys.audioMode: "all", VideoKeys.audioCodec: "pcm24", VideoKeys.audioRate: "48000", VideoKeys.audioMixdown: "auto"]),
        p("vid.proxy", "Edit proxy, ProRes Proxy 540p", "Прокси для монтажа, ProRes Proxy 540p", symbol: "film.stack", group: .lossless,
          [VideoKeys.container: "mov", VideoKeys.faststart: false, VideoKeys.vcodec: "prores", VideoKeys.profile: "proxy", VideoKeys.sizeMode: "exact", VideoKeys.sizeW: 960, VideoKeys.sizeH: 540,
           VideoKeys.audioCodec: "pcm16", VideoKeys.audioRate: "48000"]),
        p("vid.apple.hd", "iPhone, iPad, Apple TV (H.264)", "iPhone, iPad, Apple TV (H.264)", symbol: "applelogo", group: .devices,
          web(22, limit: "1080p", fps: "60", extra: [VideoKeys.audioSecond: "copySurround"])),
        p("vid.apple.4k", "Apple 4K (HEVC)", "Apple 4K (HEVC)", symbol: "applelogo", group: .devices,
          [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.cq: 24, VideoKeys.speed: "medium", VideoKeys.bitdepth: "10", VideoKeys.appleTag: true, VideoKeys.sizeMode: "limit",
           VideoKeys.sizeLimit: "2160p", VideoKeys.fpsMode: "peak", VideoKeys.fps: "60", VideoKeys.audioBitrate: "192", VideoKeys.audioSecond: "copySurround"]),
        p("vid.tv", "Smart TV or USB stick", "Смарт-ТВ или флешка", symbol: "tv", group: .devices,
          web(21, limit: "1080p", abr: "192", extra: [VideoKeys.level: "4.1", VideoKeys.audioSecond: "copySurround"])),
        p("vid.telegram", "Telegram (up to 2 GB)", "Telegram (до 2 ГБ)", symbol: "paperplane", group: .social, web(24, limit: "720p", abr: "128", extra: [VideoKeys.audioRate: "48000", VideoKeys.metadataNoGPS: true])),
        p("vid.telegram.circle", "Telegram video message (circle)", "Видеосообщение Telegram (кружок)", symbol: "circle", group: .social,
          [VideoKeys.vcodec: "h264", VideoKeys.venc: "software", VideoKeys.cq: 24, VideoKeys.sizeMode: "fill", VideoKeys.sizeW: 640, VideoKeys.sizeH: 640, VideoKeys.sizeAnchor: "smart",
           VideoKeys.fpsMode: "peak", VideoKeys.fps: "30", VideoKeys.audioBitrate: "96", VideoKeys.audioMixdown: "mono", VideoKeys.trimEnd: 60, VideoKeys.metadataNoGPS: true]),
        p("vid.whatsapp", "WhatsApp (about 16 MB)", "WhatsApp (около 16 МБ)", symbol: "paperplane", group: .social, fit(15)),
        p("vid.email25", "Email (up to 25 MB)", "Для почты (до 25 МБ)", symbol: "envelope", group: .social, fit(24, extra: [VideoKeys.profile: "high"])),
        p("vid.discord10", "Chat, under 10 MB", "Для чата, до 10 МБ", symbol: "bubble.left", group: .social, fit(9.5, abr: "64")),
        p("vid.fit", "Fit to size...", "Уложить в размер...", symbol: "scalemass", group: .smallSize, fit(25, extra: [VideoKeys.profile: "high"])),
        p("vid.social.square", "Square 1:1, 1080 (social)", "Квадрат 1:1, 1080 (соцсети)", symbol: "square", group: .social,
          [VideoKeys.vcodec: "h264", VideoKeys.venc: "software", VideoKeys.cq: 21, VideoKeys.speed: "medium", VideoKeys.profile: "high", VideoKeys.sizeMode: "fill", VideoKeys.sizeW: 1080, VideoKeys.sizeH: 1080,
           VideoKeys.sizeAnchor: "smart", VideoKeys.fpsMode: "peak", VideoKeys.fps: "30", VideoKeys.audioBitrate: "128", VideoKeys.audioRate: "48000"]),
        p("vid.vertical", "Vertical 9:16, 1080x1920 (Reels, Shorts, TikTok)", "Вертикальное 9:16, 1080x1920 (Reels, Shorts, TikTok)", symbol: "rectangle.portrait", group: .social,
          [VideoKeys.vcodec: "h264", VideoKeys.venc: "software", VideoKeys.cq: 21, VideoKeys.speed: "medium", VideoKeys.profile: "high", VideoKeys.sizeMode: "fit", VideoKeys.sizeW: 1080, VideoKeys.sizeH: 1920,
           VideoKeys.padMode: "blur", VideoKeys.fpsMode: "peak", VideoKeys.fps: "30", VideoKeys.audioBitrate: "128"]),
        p("vid.youtube", "YouTube upload", "Загрузка на YouTube", symbol: "play.rectangle", group: .social,
          [VideoKeys.vcodec: "h264", VideoKeys.venc: "software", VideoKeys.cq: 18, VideoKeys.speed: "slow", VideoKeys.profile: "high", VideoKeys.chroma: "4:2:0", VideoKeys.bframes: "2", VideoKeys.keyint: 0.5,
           VideoKeys.colorspace: "bt709", VideoKeys.fpsMode: "source", VideoKeys.audioBitrate: "384", VideoKeys.audioRate: "48000"]),
        p("vid.webm.vp9", "WebM VP9", "WebM VP9", symbol: "globe", group: .web,
          [VideoKeys.container: "webm", VideoKeys.vcodec: "vp9", VideoKeys.cq: 32, VideoKeys.speed: "medium", VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "1080p", VideoKeys.fpsMode: "peak", VideoKeys.fps: "30",
           VideoKeys.audioCodec: "opus", VideoKeys.audioBitrate: "128", VideoKeys.audioRate: "48000"]),
        p("vid.webm.av1", "WebM AV1 (smallest)", "WebM AV1 (самый компактный)", symbol: "globe", group: .smallSize,
          [VideoKeys.container: "webm", VideoKeys.vcodec: "av1", VideoKeys.cq: 34, VideoKeys.speed: "medium", VideoKeys.bitdepth: "10", VideoKeys.audioCodec: "opus", VideoKeys.audioBitrate: "128",
           VideoKeys.audioRate: "48000"]),
        p("vid.gif", "GIF animation", "GIF-анимация", symbol: "photo.on.rectangle", group: .web,
          [VideoKeys.container: "gif", VideoKeys.gifFps: 15, VideoKeys.gifWidth: "480", VideoKeys.gifColors: 256, VideoKeys.gifDither: "bayer", VideoKeys.gifLoop: "forever"]),
        p("vid.rewrap.mp4", "Rewrap to MP4, no re-encoding", "В MP4 без перекодирования", note: L10n("Instant and lossless. Not possible with filters.", "Мгновенно и без потерь. С фильтрами невозможно."), symbol: "shippingbox", group: .lossless,
          [VideoKeys.vcodec: "copy", VideoKeys.audioCodec: "copy", VideoKeys.audioFallback: "aac", VideoKeys.subMode: "keep"]),
        p("vid.rewrap.mkv", "Rewrap to MKV, no re-encoding", "В MKV без перекодирования", symbol: "shippingbox", group: .lossless,
          [VideoKeys.container: "mkv", VideoKeys.vcodec: "copy", VideoKeys.audioCodec: "copy", VideoKeys.audioPassMask: "all", VideoKeys.audioMode: "all", VideoKeys.subMode: "keep"]),
        p("vid.mute", "Remove audio", "Убрать звук", symbol: "speaker.slash", group: .lossless, [VideoKeys.vcodec: "copy", VideoKeys.audioMode: "none"]),
        p("vid.legacy", "Old players (MPEG-4, AVI)", "Старые плееры (MPEG-4, AVI)", symbol: "tv", group: .devices,
          [VideoKeys.container: "avi", VideoKeys.vcodec: "mpeg4", VideoKeys.cq: 23, VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "576p", VideoKeys.audioCodec: "mp3", VideoKeys.audioBitrate: "128"]),
        p("vid.hdr10", "HDR10 keep (HEVC 10-bit)", "Сохранить HDR10 (HEVC 10 бит)", symbol: "sun.max", group: .archive,
          [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.cq: 22, VideoKeys.speed: "slow", VideoKeys.bitdepth: "10", VideoKeys.hdr: "keep", VideoKeys.appleTag: true, VideoKeys.audioSecond: "copySurround"])
    ]
}

/// Quick recipes (spec/handbrake.md 4.6, catalog 6.2): sparse overrides over the one `video.convert` schema. CRF 23 / 28 and the AAC rates come from
/// SettingsData.quality and the schema defaults.
enum VideoQuick {
    static func convert(to key: String, settings s: SettingsData) -> OptionValues {
        switch key {
        case "webm":
            return [VideoKeys.container: "webm", VideoKeys.vcodec: "vp9", VideoKeys.cq: 32, VideoKeys.speed: "fast", VideoKeys.audioCodec: "opus", VideoKeys.audioBitrate: "128"]
        case "gif":
            return [VideoKeys.container: "gif", VideoKeys.gifFps: 12, VideoKeys.gifWidth: "640", VideoKeys.gifColors: 256, VideoKeys.gifDither: "bayer", VideoKeys.gifLoop: "forever"]
        case "mp3":
            return [VideoKeys.container: "mp3", VideoKeys.audioRC: "quality", VideoKeys.audioQuality: 78, VideoKeys.audioMixdown: "stereo"]
        default:
            return [VideoKeys.container: .string(key), VideoKeys.vcodec: "h264", VideoKeys.cq: .int(s.quality.videoCrf)]
        }
    }
    static func compress(settings s: SettingsData) -> OptionValues {
        [VideoKeys.container: "mp4", VideoKeys.vcodec: "h264", VideoKeys.cq: .int(s.quality.compressVideoCrf), VideoKeys.speed: "slow", VideoKeys.audioBitrate: "128"]
    }
    static func p720(settings s: SettingsData) -> OptionValues {
        [VideoKeys.container: "mp4", VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "720p", VideoKeys.cq: .int(s.quality.videoCrf)]
    }
    /// Stream copy into the same container (legacy containers become MP4). Only the sound goes: soft subtitle tracks stay (the original dropped them);
    /// picture subtitles a container cannot hold are left out with a note.
    static func mute() -> OptionValues { [VideoKeys.container: "same", VideoKeys.vcodec: "copy", VideoKeys.audioMode: "none", VideoKeys.subMode: "keep"] }
    static func trim(settings s: SettingsData) -> OptionValues { [VideoKeys.container: "mp4", VideoKeys.vcodec: "h264", VideoKeys.cq: .int(s.quality.videoCrf), VideoKeys.trimAccurate: true] }
    static func rotate(settings s: SettingsData) -> OptionValues { [VideoKeys.container: "mp4", VideoKeys.rotate: "90", VideoKeys.cq: .int(s.quality.videoCrf)] }
    static func speed2(settings s: SettingsData) -> OptionValues { [VideoKeys.container: "mp4", VideoKeys.filterSpeed: 2.0, VideoKeys.cq: .int(s.quality.videoCrf)] }
    static func thumbnail() -> OptionValues { [VideoKeys.frameMode: "best", VideoKeys.frameFormat: "png"] }
}
