import Foundation

/// Stable option keys of the `download.link` schema (preset JSON keys). Adding keys is free; renaming or removing breaks presets.
enum DownloadKeys {
    static let mode = "dl.mode"                  // best, max, universal, audio-m4a, audio-mp3
    static let maxHeight = "dl.maxHeight"        // 0 = best, 4320 ... 144
    static let audioFormat = "dl.audio.format"   // m4a, mp3, opus, flac
    static let audioQuality = "dl.audio.quality" // kbit/s for mp3, 0 = best VBR
    static let after = "dl.after"                // keep, best, universal, preset:<id>
    static let subtitles = "dl.subs.mode"        // none, soft, external, burn
    static let subtitleLanguages = "dl.subs.langs"
    static let sectionStart = "dl.section.start" // time field, seconds
    static let sectionEnd = "dl.section.end"
    static let embedMetadata = "dl.embed.meta"
    static let embedThumbnail = "dl.embed.thumb"
    static let filenameTemplate = "dl.template"
    static let playlist = "dl.playlist"          // single, all, items
    static let playlistItems = "dl.playlist.items"
    static let cookies = "dl.cookies"            // none, safari, chrome, firefox, edge, brave
    static let rateLimit = "dl.rate"             // KB/s, 0 = unlimited
    static let fragments = "dl.fragments"        // parts fetched at the same time, 1...8
    static let folder = "dl.folder"
}

/// Oracle ids of the schema: each names the self-test that proves the option changes what yt-dlp is asked to do (golden argv) or what lands
/// in the output folder (runs against the fake tool). `DownloaderTests` checks that every field's oracle is claimed by a test.
enum DownloadOracles {
    static let all: [String: [String]] = [
        DownloadKeys.mode: ["dl.mode.selector"],
        DownloadKeys.maxHeight: ["dl.height.cap"],
        DownloadKeys.audioFormat: ["dl.audio.format"],
        DownloadKeys.audioQuality: ["dl.audio.quality"],
        DownloadKeys.after: ["dl.after.convert"],
        DownloadKeys.subtitles: ["dl.subs.mode"],
        DownloadKeys.subtitleLanguages: ["dl.subs.langs"],
        DownloadKeys.sectionStart: ["dl.section.range"],
        DownloadKeys.sectionEnd: ["dl.section.range"],
        DownloadKeys.embedMetadata: ["dl.embed.flags"],
        DownloadKeys.embedThumbnail: ["dl.embed.flags"],
        DownloadKeys.filenameTemplate: ["dl.template.output"],
        DownloadKeys.playlist: ["dl.playlist.items"],
        DownloadKeys.playlistItems: ["dl.playlist.items"],
        DownloadKeys.cookies: ["dl.cookies.only-when-chosen"],
        DownloadKeys.rateLimit: ["dl.rate.limit"],
        DownloadKeys.fragments: ["dl.fragments.parallel"],
        DownloadKeys.folder: ["dl.folder.output"]
    ]
}

/// Pages Quality (mode, height cap, audio format), Subtitles, Range (sections), Output (folder, template, metadata, thumbnail), After download
/// (keep / Best for Apple / Universal / a Studio preset), Network (cookies, rate limit, playlist). `.oracle(...)` on every field.
/// Works for an empty items array. Defaults come from `AppSettings.shared.data.downloader` where they exist.
enum DownloadSchemas {
    static let linkID = "download.link"

    private static let audioModes: [OptionValue] = [.string(DownloadMode.audioM4A.rawValue), .string(DownloadMode.audioMP3.rawValue)]

    static func link(settings: DownloaderSettings = AppSettings.shared.data.downloader) -> OptionSchema {
        let isAudio = OptionExpr.in(DownloadKeys.mode, audioModes)
        let heights: [FieldOption] = [FieldOption("0", L10n("Best available", "Максимальное"))] + [
            (4320, "8K (4320p)"), (2160, "4K (2160p)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p"), (240, "240p"), (144, "144p")
        ].map { FieldOption(String($0.0), $0.1) }

        let quality = OptionPage.make("quality", symbol: "film", L10n("Quality", "Качество"), [
            .make("mode", [
                .picker(DownloadKeys.mode, L10n("What to get", "Что скачать"), [
                    FieldOption(DownloadMode.bestForApple.rawValue, DownloadMode.bestForApple.title,
                                hint: L10n("The best picture, converted to HEVC for Apple devices when needed.", "Лучшая картинка; при необходимости HEVC для устройств Apple.")),
                    FieldOption(DownloadMode.maximum.rawValue, DownloadMode.maximum.title,
                                hint: L10n("The best quality exactly as the site stores it. No conversion.", "Лучшее качество в том виде, как оно хранится на сайте. Без конвертации.")),
                    FieldOption(DownloadMode.universal.rawValue, DownloadMode.universal.title,
                                hint: L10n("H.264 up to 1080p with AAC sound: plays on anything.", "H.264 до 1080p со звуком AAC: играет везде.")),
                    FieldOption(DownloadMode.audioM4A.rawValue, L10n("Audio only", "Только звук"),
                                hint: L10n("Sound only, in the format chosen below.", "Только звук в выбранном ниже формате.")),
                    FieldOption(DownloadMode.audioMP3.rawValue, L10n("Audio only, MP3", "Только звук, MP3"))
                ], def: DownloadMode.bestForApple.rawValue)
                    .basic().oracle("dl.mode.selector").aliases(["video", "audio", "mp3", "hevc", "h264", "видео", "звук"]),
                .picker(DownloadKeys.maxHeight, L10n("Largest picture", "Максимальный размер картинки"), heights, def: "0")
                    .basic().visible(.not(isAudio)).oracle("dl.height.cap").aliases(["resolution", "4k", "8k", "1080p", "разрешение"])
                    .help(L10n("The page may offer less. Lower values download faster and take less space.", "Страница может предложить меньше. Меньшие значения скачиваются быстрее и занимают меньше места.")),
                .picker(DownloadKeys.audioFormat, L10n("Audio format", "Формат звука"), [
                    FieldOption("m4a", "M4A (AAC)"), FieldOption("mp3", "MP3"), FieldOption("opus", "Opus"), FieldOption("flac", "FLAC")
                ], def: "m4a")
                    .basic().visible(.eq(DownloadKeys.mode, .string(DownloadMode.audioM4A.rawValue))).oracle("dl.audio.format"),
                .picker(DownloadKeys.audioQuality, L10n("MP3 quality", "Качество MP3"), [
                    FieldOption("0", L10n("Best (variable)", "Лучшее (переменное)")), FieldOption("128", "128 kbit/s"), FieldOption("192", "192 kbit/s"),
                    FieldOption("256", "256 kbit/s"), FieldOption("320", "320 kbit/s")
                ], def: "0")
                    .visible(.any([.eq(DownloadKeys.mode, .string(DownloadMode.audioMP3.rawValue)),
                                   .all([.eq(DownloadKeys.mode, .string(DownloadMode.audioM4A.rawValue)), .eq(DownloadKeys.audioFormat, "mp3")])]))
                    .oracle("dl.audio.quality")
            ])
        ])

        let subtitles = OptionPage.make("subtitles", symbol: "captions.bubble", L10n("Subtitles", "Субтитры"), visible: .not(isAudio), [
            .make("subs", [
                .segmented(DownloadKeys.subtitles, L10n("Subtitles", "Субтитры"), [
                    FieldOption("none", L10n("None", "Нет")),
                    FieldOption("soft", L10n("Inside the video", "В видео"), hint: L10n("Switchable in the player.", "Можно включить в плеере.")),
                    FieldOption("external", L10n("Separate file", "Отдельный файл")),
                    FieldOption("burn", L10n("Burned in", "Вшить в картинку"), requires: ["ff.filter.subtitles"],
                                hint: L10n("Needs an ffmpeg with subtitle drawing (libass).", "Нужен ffmpeg с отрисовкой субтитров (libass)."))
                ], def: "none").basic().oracle("dl.subs.mode"),
                .text(DownloadKeys.subtitleLanguages, L10n("Languages", "Языки"), def: settings.subtitleLanguages,
                      placeholder: L10n("ru,en", "ru,en"), validation: .regex("^[A-Za-z0-9_*,\\- ]*$"))
                    .visible(.ne(DownloadKeys.subtitles, "none")).oracle("dl.subs.langs")
                    .help(L10n("Language codes separated by commas. Automatic captions are used when the author added none.", "Коды языков через запятую. Если автор не добавил субтитры, берутся автоматические."))
            ])
        ])

        let range = OptionPage.make("range", symbol: "scissors", L10n("Part of the video", "Часть видео"), [
            .make("section", L10n("Download only a part", "Скачать только часть"), footer: L10n("The cut snaps to the nearest keyframe, so it is fast and loses nothing.", "Вырезка округляется до ближайшего ключевого кадра: быстро и без потерь."), [
                .time(DownloadKeys.sectionStart, L10n("From", "От"), placeholder: L10n("start", "начало"))
                    .needs(["tool.ffmpeg"]).oracle("dl.section.range"),
                .time(DownloadKeys.sectionEnd, L10n("To", "До"), placeholder: L10n("end", "конец"))
                    .needs(["tool.ffmpeg"]).oracle("dl.section.range")
            ])
        ])

        let output = OptionPage.make("files", symbol: "folder", L10n("Files", "Файлы"), [
            .make("where", [
                .folder(DownloadKeys.folder, L10n("Save to", "Куда сохранять"), def: settings.folder ?? "")
                    .basic().oracle("dl.folder.output")
                    .help(L10n("Empty means Movies / Swamp Converter (Music / Swamp Converter for sound).", "Пусто — Фильмы / Swamp Converter (Музыка / Swamp Converter для звука).")),
                .text(DownloadKeys.filenameTemplate, L10n("File name", "Имя файла"), def: settings.filenameTemplate,
                      placeholder: L10n("%(title)s [%(id)s].%(ext)s", "%(title)s [%(id)s].%(ext)s"), validation: .regex("^(?!/|~)(?!(.*/)?\\.\\.(/|$)).+$"))
                    .oracle("dl.template.output").aliases(["template", "шаблон"])
                    .help(L10n("Fields: %(title)s %(id)s %(uploader)s %(upload_date)s %(ext)s. It can never point outside the folder.", "Поля: %(title)s %(id)s %(uploader)s %(upload_date)s %(ext)s. Файл не может оказаться вне папки.")),
                .toggle(DownloadKeys.embedMetadata, L10n("Add title and chapters to the file", "Записать название и главы в файл"), def: settings.embedMetadata)
                    .oracle("dl.embed.flags"),
                .toggle(DownloadKeys.embedThumbnail, L10n("Add the cover picture to the file", "Добавить обложку в файл"), def: settings.embedThumbnail)
                    .oracle("dl.embed.flags")
            ])
        ])

        let afterOptions: [FieldOption] = [
            FieldOption(AfterDownload.keepOriginal.stringValue, L10n("Keep as downloaded", "Оставить как скачано")),
            FieldOption(AfterDownload.bestForApple.stringValue, SmartMode.bestForApple.title, hint: SmartMode.bestForApple.subtitle),
            FieldOption(AfterDownload.universal.stringValue, SmartMode.universal.title, hint: SmartMode.universal.subtitle)
        ] + PresetStore.shared.presets(for: "video.convert").map {
            FieldOption(AfterDownload.preset($0.id).stringValue, L10n("Preset: ", "Шаблон: ") .asPrefix(of: $0.name), requires: [])
        }
        let after = OptionPage.make("after", symbol: "wand.and.stars", L10n("After download", "После загрузки"), visible: .not(isAudio), [
            .make("after", footer: L10n("A conversion needs ffmpeg. Without it the video is kept as downloaded.", "Для конвертации нужен ffmpeg. Без него видео остаётся как скачано."), [
                .picker(DownloadKeys.after, L10n("Then", "Затем"), afterOptions, def: settings.afterDownload.stringValue)
                    .basic().oracle("dl.after.convert")
                    .help(L10n("Best for Apple keeps the picture when the site’s video already plays on a Mac and otherwise converts it to HEVC.", "«Лучшее для Apple» не трогает картинку, если видео и так играет на Mac, иначе переводит в HEVC."))
            ])
        ])

        let network = OptionPage.make("network", symbol: "network", L10n("Network", "Сеть"), [
            .make("net", [
                .picker(DownloadKeys.playlist, L10n("If the link is a list", "Если ссылка — список"), [
                    FieldOption("single", L10n("Only this video", "Только это видео")),
                    FieldOption("all", L10n("Every video of the list", "Все видео списка")),
                    FieldOption("items", L10n("Chosen numbers", "Выбранные номера"))
                ], def: "single").oracle("dl.playlist.items"),
                .text(DownloadKeys.playlistItems, L10n("Numbers", "Номера"), def: "", placeholder: L10n("1,3,5-7", "1,3,5-7"), validation: .pageRange)
                    .visible(.eq(DownloadKeys.playlist, "items")).oracle("dl.playlist.items"),
                .picker(DownloadKeys.cookies, L10n("Use sign-in from", "Использовать вход из"),
                        CookieBrowser.allCases.map { FieldOption($0.rawValue, $0.title) }, def: settings.cookies.rawValue)
                    .oracle("dl.cookies.only-when-chosen")
                    .help(L10n("Only for sites that ask you to sign in. The app reads the cookies of your browser for that one download.", "Только для сайтов, которые просят войти. Приложение читает cookies браузера только для этой загрузки.")),
                .number(DownloadKeys.rateLimit, L10n("Speed limit", "Ограничение скорости"), min: 0, max: 1_000_000, step: 100, def: Double(settings.rateLimitKBps), unit: "KB/s")
                    .oracle("dl.rate.limit").help(L10n("0 means no limit.", "0 — без ограничения.")),
                .number(DownloadKeys.fragments, L10n("Parallel parts", "Параллельные части"), min: 1, max: 8, step: 1, def: Double(settings.fragments))
                    .oracle("dl.fragments.parallel").help(L10n("How many pieces of a video are fetched at once. More is faster on a good connection; 1 is gentler.", "Сколько кусков видео загружается одновременно. Больше — быстрее на хорошем соединении; 1 — бережнее."))
            ])
        ])

        return OptionSchema(id: linkID, title: L10n("Download", "Загрузка"), symbol: "arrow.down.circle", pages: [quality, subtitles, range, output, after, network])
    }
}

private extension L10n {
    /// "Preset: " + a preset name (both languages).
    func asPrefix(of name: L10n) -> L10n { L10n(en + name.en, ru + name.ru) }
}
