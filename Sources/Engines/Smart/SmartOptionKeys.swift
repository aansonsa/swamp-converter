import Foundation

/// Stable option keys of the `smart.transcode` schema. Adding keys is free; renaming or removing breaks presets.
enum SmartKeys {
    static let mode = "smart.mode"                  // best, max, universal
    static let slowMaxQuality = "smart.x265"        // libx265 "maximum quality (slow)"
    static let losslessAudio = "smart.alac"
    static let audioBitrate = "smart.abr"           // kbit/s for AAC
    static let keepAllAudio = "smart.audio.all"
    static let keepSubtitles = "smart.subs"
    static let downscale = "smart.downscale"        // scale very large pictures down
    static let downscaleHeight = "smart.downscale.h"
    static let container = "smart.container"        // auto, mp4, mov, mkv
    static let faststart = "smart.faststart"
    static let stripMetadata = "smart.strip"
    static let qualityOffset = "smart.q.offset"     // -10 ... +10 around the documented target (expert)
}

enum SmartSchemas {
    static let transcodeID = "smart.transcode"

    private static let isBest: OptionExpr = .eq(SmartKeys.mode, "best")
    private static let reEncodes: OptionExpr = .ne(SmartKeys.mode, "max")

    /// Pages Mode (segmented control with the one-line explanation of each), Video (software encoder, quality offset, size limit), Audio, Subtitles and
    /// metadata, Container. Every field has an `.oracle(...)` proven by SmartTests; defaults reproduce the quick recipe of `smart.best`.
    /// Works for an empty items array (nothing here depends on the source).
    static func transcode(items: [FileItem]) -> OptionSchema {
        let mode = OptionPage.make("mode", symbol: "apple.logo", L10n("Mode", "Режим"), [
            OptionGroup.make("mode.main", [
                .segmented(SmartKeys.mode, L10n("Result", "Результат"), [
                    FieldOption("best", L10n("Best for Apple", "Лучшее для Apple"), symbol: "apple.logo",
                                hint: L10n("Keeps what already plays on Apple devices; re-encodes the rest to HEVC with the original size, frame rate and HDR.",
                                           "Оставляет то, что уже играет на устройствах Apple; остальное кодирует в HEVC с исходным размером, частотой кадров и HDR.")),
                    FieldOption("max", L10n("Maximum quality", "Макс. качество"), symbol: "sparkles",
                                hint: L10n("Never re-encodes. Copies every stream into MP4, MOV, WebM or MKV, whichever holds them.",
                                           "Ничего не перекодирует. Копирует все потоки в MP4, MOV, WebM или MKV, в зависимости от того, что их вмещает.")),
                    FieldOption("universal", L10n("Universal", "Универсальный"), symbol: "globe",
                                hint: L10n("H.264 up to 1080p with AAC in MP4: plays on any phone, TV or browser.",
                                           "H.264 до 1080p со звуком AAC в MP4: играет на любом телефоне, телевизоре и в браузере."))
                ], def: "best")
                .basic()
                .help(L10n("Best for Apple: keeps what already plays on Apple devices and re-encodes the rest to HEVC. Maximum quality: copies the streams without re-encoding. Universal: H.264 up to 1080p, plays anywhere.",
                           "Лучшее для Apple: оставляет то, что уже играет на устройствах Apple, остальное кодирует в HEVC. Макс. качество: копирует потоки без перекодирования. Универсальный: H.264 до 1080p, играет везде."))
                .aliases(["apple", "hevc", "h264", "remux", "совместимость", "ремукс"])
                .oracle("smart.mode")
            ])
        ])
        let video = OptionPage.make("video", symbol: "film", L10n("Video", "Видео"), [
            OptionGroup.make("video.encoder", L10n("Encoder", "Кодировщик"), level: .standard, [
                .toggle(SmartKeys.slowMaxQuality, L10n("Maximum quality encoder (slow)", "Кодировщик максимального качества (медленно)"), def: false)
                    .standard()
                    .help(L10n("Uses the software encoder libx265 instead of the hardware one: a little smaller or sharper, several times slower.",
                               "Использует программный кодировщик libx265 вместо аппаратного: файл чуть меньше или чётче, но в несколько раз медленнее."))
                    .enabled(isBest, reason: L10n("Only used by Best for Apple.", "Используется только режимом «Лучшее для Apple»."))
                    .needs(["ff.enc.libx265"], reason: L10n("Needs an ffmpeg with libx265.", "Нужен ffmpeg с libx265."))
                    .aliases(["x265", "slow", "software", "медленно"])
                    .oracle("smart.x265"),
                .stepper(SmartKeys.qualityOffset, L10n("Quality offset", "Смещение качества"), min: -10, max: 10, def: 0)
                    .expert()
                    .help(L10n("Moves the documented quality target. Positive is better and larger; one step is 2 points on the hardware scale or 1 CRF step.",
                               "Сдвигает документированную цель качества. Плюс - лучше и больше; один шаг - 2 пункта аппаратной шкалы или 1 шаг CRF."))
                    .enabled(reEncodes, reason: L10n("Nothing is re-encoded in this mode.", "В этом режиме ничего не перекодируется."))
                    .aliases(["crf", "q", "качество"])
                    .oracle("smart.q.offset")
            ]),
            OptionGroup.make("video.size", L10n("Picture size", "Размер картинки"), level: .standard, footer:
                                L10n("Without this switch the picture keeps its size: 4K and 8K stay as they are. Very large pictures use the software encoder.",
                                     "Без этой опции картинка сохраняет размер: 4K и 8K остаются как есть. Очень большие картинки кодируются программным кодировщиком."), [
                .toggle(SmartKeys.downscale, L10n("Scale down large pictures", "Уменьшать большие картинки"), def: false)
                    .standard()
                    .enabled(isBest, reason: L10n("Only used by Best for Apple (Universal always fits 1080p).", "Используется только режимом «Лучшее для Apple» (Универсальный всегда укладывается в 1080p)."))
                    .aliases(["resolution", "downscale", "разрешение"])
                    .oracle("smart.downscale"),
                .picker(SmartKeys.downscaleHeight, L10n("Largest height", "Максимальная высота"), [
                    FieldOption("2160", L10n("2160p (4K)")), FieldOption("1440", L10n("1440p")), FieldOption("1080", L10n("1080p")),
                    FieldOption("720", L10n("720p")), FieldOption("480", L10n("480p"))
                ], def: "2160")
                    .standard()
                    .visible(.eq(SmartKeys.downscale, true))
                    .oracle("smart.downscale.h")
            ])
        ])
        let audio = OptionPage.make("audio", symbol: "waveform", L10n("Audio", "Звук"), [
            OptionGroup.make("audio.main", L10n("Tracks", "Дорожки"), level: .basic, [
                .toggle(SmartKeys.keepAllAudio, L10n("Keep all audio tracks", "Сохранить все звуковые дорожки"), def: true)
                    .basic()
                    .help(L10n("Off keeps only the main track.", "Выключено: остаётся только основная дорожка."))
                    .oracle("smart.audio.all"),
                .picker(SmartKeys.audioBitrate, L10n("AAC bitrate", "Битрейт AAC"), [
                    FieldOption("128", L10n("128 kbit/s")), FieldOption("160", L10n("160 kbit/s")), FieldOption("192", L10n("192 kbit/s")),
                    FieldOption("256", L10n("256 kbit/s")), FieldOption("320", L10n("320 kbit/s")), FieldOption("384", L10n("384 kbit/s"))
                ], def: "256")
                    .standard()
                    .help(L10n("For tracks that have to be re-encoded (stereo figure; surround gets more). AAC, ALAC and MP3 tracks are copied.",
                               "Для дорожек, которые приходится перекодировать (значение для стерео; для объёмного звука больше). Дорожки AAC, ALAC и MP3 копируются."))
                    .enabled(.all([reEncodes, .not(.eq(SmartKeys.losslessAudio, true))]), reason: L10n("Not used when audio is copied or lossless.", "Не используется, если звук копируется или кодируется без потерь."))
                    .aliases(["kbps", "битрейт"])
                    .oracle("smart.abr"),
                .toggle(SmartKeys.losslessAudio, L10n("Lossless audio (ALAC)", "Звук без потерь (ALAC)"), def: false)
                    .standard()
                    .help(L10n("Tracks that have to be re-encoded become ALAC instead of AAC. Larger files.", "Дорожки, которые приходится перекодировать, сохраняются в ALAC вместо AAC. Файлы больше."))
                    .enabled(reEncodes, reason: L10n("Nothing is re-encoded in Maximum quality.", "В режиме максимального качества ничего не перекодируется."))
                    .aliases(["alac", "lossless", "без потерь"])
                    .oracle("smart.alac")
            ])
        ])
        let extras = OptionPage.make("extras", symbol: "captions.bubble", L10n("Subtitles and metadata", "Субтитры и метаданные"), [
            OptionGroup.make("extras.main", [
                .toggle(SmartKeys.keepSubtitles, L10n("Keep subtitles", "Сохранить субтитры"), def: true)
                    .basic()
                    .help(L10n("Text subtitles stay selectable. Picture-based ones (DVD, Blu-ray) cannot go into MP4 and are left out.",
                               "Текстовые субтитры остаются переключаемыми. Графические (DVD, Blu-ray) нельзя поместить в MP4, они пропускаются."))
                    .oracle("smart.subs"),
                .toggle(SmartKeys.stripMetadata, L10n("Remove location and camera data", "Удалить геопозицию и данные камеры"), def: false)
                    .standard()
                    .help(L10n("Drops tags such as GPS position, device and creation dates from the result.", "Убирает из результата теги: геопозицию, устройство и даты создания."))
                    .aliases(["privacy", "gps", "приватность"])
                    .oracle("smart.strip")
            ])
        ])
        let container = OptionPage.make("container", symbol: "shippingbox", L10n("Container", "Контейнер"), [
            OptionGroup.make("container.main", [
                .picker(SmartKeys.container, L10n("File type", "Тип файла"), [
                    FieldOption("auto", L10n("Automatic", "Автоматически"), hint: L10n("MP4, or MOV for MOV sources", "MP4, а для MOV-файлов MOV")),
                    FieldOption("mp4", L10n("MP4")), FieldOption("mov", L10n("MOV")), FieldOption("mkv", L10n("MKV"))
                ], def: "auto")
                    .standard()
                    .help(L10n("Automatic picks the container that holds all kept streams and plays on Apple devices.", "Автоматически выбирается контейнер, который вмещает все потоки и играет на устройствах Apple."))
                    .enabled(.ne(SmartKeys.mode, "universal"), reason: L10n("Universal is always MP4.", "Универсальный режим всегда даёт MP4."))
                    .oracle("smart.container"),
                .toggle(SmartKeys.faststart, L10n("Optimize for streaming", "Оптимизировать для потоковой передачи"), def: true)
                    .standard()
                    .help(L10n("Moves the index to the start so playback begins before the download ends.", "Индекс переносится в начало файла: воспроизведение начинается до окончания загрузки."))
                    .enabled(.ne(SmartKeys.container, "mkv"), reason: L10n("Not used by MKV or WebM.", "Не используется для MKV и WebM."))
                    .oracle("smart.faststart")
            ])
        ])
        return OptionSchema(id: transcodeID, title: L10n("Best for Apple", "Лучшее для Apple"), symbol: "apple.logo", pages: [mode, video, audio, extras, container])
    }
}
