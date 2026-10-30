import Foundation

// MODULE downloader (owner: downloader engineer). Prefix for new top-level types: Download* / YtDlp*.
// Files: Sources/Engines/Downloader/*  and the fixtures in Tests/Fixtures/downloader/* (fake yt-dlp, JSON samples).
// Spec: the DOWNLOADER block of the project brief (see docs/ARCHITECTURE.md "Downloader"), spec/platform.md 8 (login items / notifications are NOT yours),
//       spec/wheel.md 18.3 item 6 (the original rejected URLs; this app downloads ONLY on explicit action and consent).
//
// THE ONLY CODE ALLOWED TO TOUCH THE NETWORK, and only after `NetworkGate.authorize(...)`:
//   * `YtDlpToolManager` (explicit install / update check)  -> URLSession to github.com
//   * the spawned yt-dlp process (info fetch + download)    -> the app itself opens no socket
// YOU, the engineer, must NOT make a real request, download a binary or contact YouTube while developing: test with a fake yt-dlp
// (zsh script printing realistic `-J` JSON and progress lines, kept in Tests/Fixtures/downloader) and JSON fixtures you write.

enum Downloader {
    /// Registers the LINK-wheel operations (`link.best`, `link.max`, `link.universal`, `link.audio.m4a`, `link.audio.mp3`), the built-in
    /// download presets and the capability ids `dl.ytdlp`, `dl.js-runtime`. Called by EnginesBootstrap.registerAll (after smart).
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(DownloadCatalog.operations())
        PresetStore.shared.registerBuiltins(DownloadPresets.builtins)
        Capabilities.shared.register("dl.ytdlp") { ToolLocator.shared.has(.ytdlp) }
        Capabilities.shared.register("dl.js-runtime") { JSRuntimeDetector.detect() != nil }
    }

    #if !SC_SHIPPING
    /// Called by `--self-test`: URL validation fixtures, info-JSON parsing, format selection, argv golden tests, progress-line parsing,
    /// SHA-256 verification, the full flow against the FAKE yt-dlp (progress, cancel with partial clean-up, resume, playlist, sections),
    /// consent gating, "no network in tests". Never a real request.
    static func registerSelfTests() { DownloaderTests.register() }
    #endif
}

/// Built-in presets of the `download.link` target (spec: handbrake.md 4.1 style). Values are sparse over the schema defaults.
enum DownloadPresets {
    static let target = DownloadSchemas.linkID

    static let builtins: [Preset] = [
        .builtin("dl.best", target: target, L10n("Best for Apple", "Лучшее для Apple"),
                 notes: L10n("The best picture; converted to HEVC only when the video would not play on a Mac as it is.", "Лучшая картинка; в HEVC переводится, только если видео иначе не играет на Mac."),
                 symbol: "apple.logo", group: .devices,
                 [DownloadKeys.mode: "best", DownloadKeys.after: "best"]),
        .builtin("dl.max", target: target, L10n("Maximum quality", "Максимальное качество"),
                 notes: L10n("Exactly what the site stores, no conversion (MKV or WebM when needed).", "Ровно то, что хранит сайт, без конвертации (при необходимости MKV или WebM)."),
                 symbol: "sparkles", group: .archive,
                 [DownloadKeys.mode: "max", DownloadKeys.after: "keep"]),
        .builtin("dl.universal1080", target: target, L10n("Universal 1080p", "Универсальный 1080p"),
                 notes: L10n("H.264 and AAC in MP4, up to 1080p: plays on anything.", "H.264 и AAC в MP4 до 1080p: играет везде."),
                 symbol: "globe", group: .web,
                 [DownloadKeys.mode: "universal", DownloadKeys.maxHeight: "1080", DownloadKeys.after: "universal"]),
        .builtin("dl.small720", target: target, L10n("Small 720p", "Компактный 720p"),
                 notes: L10n("720p in H.264: a small file for a phone or a messenger.", "720p в H.264: небольшой файл для телефона или мессенджера."),
                 symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize,
                 [DownloadKeys.mode: "universal", DownloadKeys.maxHeight: "720", DownloadKeys.after: "universal"]),
        .builtin("dl.lecture", target: target, L10n("Lecture with subtitles", "Лекция с субтитрами"),
                 notes: L10n("720p with subtitles inside the video.", "720p с субтитрами внутри видео."),
                 symbol: "captions.bubble", group: .devices,
                 [DownloadKeys.mode: "best", DownloadKeys.maxHeight: "720", DownloadKeys.after: "best", DownloadKeys.subtitles: "soft", DownloadKeys.subtitleLanguages: "ru,en"]),
        .builtin("dl.podcast", target: target, L10n("Podcast (audio M4A)", "Подкаст (аудио M4A)"),
                 notes: L10n("Sound only as AAC in an M4A file, with the cover.", "Только звук: AAC в файле M4A, с обложкой."),
                 symbol: "waveform", group: .devices,
                 [DownloadKeys.mode: "audio-m4a", DownloadKeys.audioFormat: "m4a", DownloadKeys.embedThumbnail: true]),
        .builtin("dl.music", target: target, L10n("Music (MP3 320)", "Музыка (MP3 320)"),
                 notes: L10n("Sound only as MP3 at 320 kbit/s.", "Только звук: MP3, 320 кбит/с."),
                 symbol: "music.note", group: .devices,
                 [DownloadKeys.mode: "audio-mp3", DownloadKeys.audioFormat: "mp3", DownloadKeys.audioQuality: "320"])
    ]
}
