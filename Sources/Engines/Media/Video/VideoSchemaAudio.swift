import Foundation

// Schema page "Audio" (spec/handbrake.md 2.6): which source tracks are taken (rules), how every track is encoded, and the optional per-track table.
// The MP3 container (audio only) shows the encoding part only.

extension VideoSchemas {
    static let audioLossless = ["flac", "alac", "pcm16", "pcm24", "copy", "none"]

    static func audioCodecOption(_ v: String, _ label: L10n, containers: [String], requires: [String] = []) -> FieldOption {
        FieldOption(v, label, enabledWhen: vIn(VideoKeys.container, containers + ["same"]), requires: requires)
    }

    /// True when the VBR "quality" scale exists for the chosen codec: MP3 (LAME) and AAC through AudioToolbox.
    static var audioHasQualityScale: OptionExpr {
        .any([.eq(VideoKeys.container, "mp3"), .eq(VideoKeys.audioCodec, "mp3"), .all([.eq(VideoKeys.audioCodec, "aac"), .cap("ff.enc.aac_at")])])
    }

    static var audioIsLossy: OptionExpr { .any([.eq(VideoKeys.container, "mp3"), vNotIn(VideoKeys.audioCodec, audioLossless)]) }

    static let bitrateChoices = ["32", "48", "64", "96", "128", "160", "192", "224", "256", "320", "384", "448", "512", "640"]
    static let sampleRateChoices = ["8000", "11025", "12000", "16000", "22050", "24000", "32000", "44100", "48000", "88200", "96000"]

    static func audioPage() -> OptionPage {
        let codecs: [FieldOption] = [
            audioCodecOption("aac", "AAC", containers: ["mp4", "mov", "mkv", "avi"]),
            audioCodecOption("mp3", "MP3", containers: ["mp4", "mov", "mkv", "avi"], requires: ["ff.enc.libmp3lame"]),
            audioCodecOption("opus", "Opus", containers: ["mp4", "mov", "mkv", "webm"], requires: ["ff.enc.libopus"]),
            audioCodecOption("flac", "FLAC", containers: ["mp4", "mov", "mkv"], requires: ["ff.enc.flac"]),
            audioCodecOption("alac", L10n("Apple Lossless (ALAC)", "Apple Lossless (ALAC)"), containers: ["mp4", "mov", "mkv"]),
            audioCodecOption("ac3", "AC-3", containers: ["mp4", "mov", "mkv", "avi"], requires: ["ff.enc.ac3"]),
            audioCodecOption("eac3", "E-AC-3", containers: ["mp4", "mov", "mkv"], requires: ["ff.enc.eac3"]),
            audioCodecOption("pcm16", L10n("PCM 16-bit", "PCM 16 бит"), containers: ["mov", "mkv", "avi"]),
            audioCodecOption("pcm24", L10n("PCM 24-bit", "PCM 24 бита"), containers: ["mov", "mkv"]),
            audioCodecOption("vorbis", "Vorbis", containers: ["mkv", "webm"], requires: ["ff.enc.vorbis"]),
            FieldOption("copy", L10n("Copy, no re-encoding", "Копировать без перекодирования")),
            FieldOption("none", L10n("No audio", "Без звука"))
        ]
        let rowCodecs: [FieldOption] = [FieldOption("default", L10n("Default", "По умолчанию"))] + ["aac", "mp3", "opus", "flac", "alac", "ac3", "eac3", "copy"].map { FieldOption($0, $0.uppercased()) }
        let rowMix: [FieldOption] = [FieldOption("default", L10n("Default", "По умолчанию"))] + mixdownOptions().dropFirst()
        let rowRate: [FieldOption] = [FieldOption("default", L10n("Default", "По умолчанию"))] + sampleRateChoices.map { FieldOption($0, "\($0) Hz") }
        let table = TrackSpec(columns: [
            .stepper("src", L10n("Source track", "Исходная дорожка"), min: 0, max: 31, def: 0),
            .picker("codec", L10n("Codec", "Кодек"), rowCodecs, def: "default"),
            .picker("mixdown", L10n("Channels", "Каналы"), rowMix, def: "default"),
            .number("bitrate", L10n("Bitrate", "Битрейт"), min: 0, max: 640, step: 16, def: 0, unit: "kbit/s"),
            .picker("rate", L10n("Sample rate", "Частота"), rowRate, def: "default"),
            .number("gain", L10n("Volume", "Громкость"), min: -20, max: 20, step: 0.5, def: 0, unit: "dB", decimals: 1),
            .text("name", L10n("Name", "Название"))
        ], maxRows: 8, rowTitleKey: "src", addTitle: L10n("Add Audio Track", "Добавить звуковую дорожку"))

        return .make("audio", symbol: "speaker.wave.2", L10n("Audio", "Звук"), [
            .make("selection", L10n("Tracks", "Дорожки"), visible: notAudioOnly, [
                .segmented(VideoKeys.audioMode, L10n("Audio tracks", "Звуковые дорожки"), [
                    FieldOption("first", L10n("First", "Первая")), FieldOption("all", L10n("All", "Все")),
                    FieldOption("languages", L10n("By language", "По языку")), FieldOption("none", L10n("Remove audio", "Убрать звук"))
                ], def: "first").basic()
                    .help(L10n("Take all tracks, only the first, those in chosen languages, or remove the audio.", "Взять все дорожки, только первую, на выбранных языках или убрать звук."))
                    .aliases(["audio", "tracks", "mute", "дорожки", "без звука"]).oracle("a.mode.streams"),
                .text(VideoKeys.audioLangs, L10n("Languages", "Языки"), def: "eng", placeholder: L10n("eng, rus", "eng, rus"))
                    .standard().visible(.eq(VideoKeys.audioMode, "languages"))
                    .help(L10n("Three-letter codes separated by commas, for example rus, eng, lav.", "Трёхбуквенные коды через запятую, например rus, eng, lav.")).oracle("a.langs.streams"),
                .toggle(VideoKeys.audioLangFallback, L10n("If none match, use the first track", "Если нет совпадений, взять первую дорожку"), def: true)
                    .standard().visible(.eq(VideoKeys.audioMode, "languages")).oracle("a.langs.fallback")
            ]),
            .make("encoding", L10n("Encoding", "Кодирование"), visible: .ne(VideoKeys.audioMode, "none"), [
                .picker(VideoKeys.audioCodec, L10n("Audio codec", "Аудиокодек"), codecs, def: "aac").basic().visible(notAudioOnly)
                    .help(L10n("AAC is the safest. Opus has the best quality at low bitrates. Copy keeps the original sound untouched.",
                               "AAC - самый совместимый. Opus - лучшее качество на малых битрейтах. «Копировать» оставляет исходный звук без изменений."))
                    .aliases(["aac", "mp3", "opus", "codec", "кодек звука"]).oracle("a.codec.name"),
                .picker(VideoKeys.audioSecond, L10n("Extra surround track", "Дополнительная дорожка объёмного звука"), [
                    FieldOption("none", L10n("None", "Нет")), FieldOption("copySurround", L10n("Copy Dolby Digital", "Копия Dolby Digital"))
                ], def: "none").standard().visible(.all([notAudioOnly, vNotIn(VideoKeys.audioCodec, ["copy", "none"])]))
                    .help(L10n("Adds a copy of the original Dolby Digital track after the main one, when the source has it at 640 kbit/s or less.",
                               "Добавляет копию исходной дорожки Dolby Digital после основной, если она есть и не больше 640 кбит/с."))
                    .oracle("a.second.streams"),
                .picker(VideoKeys.audioPassMask, L10n("Formats that may be copied", "Форматы для копирования"), [
                    FieldOption(VideoPlanner.defaultPassMask, L10n("Common formats", "Распространённые форматы")),
                    FieldOption("aac,ac3,eac3", L10n("AAC and Dolby only", "Только AAC и Dolby")),
                    FieldOption("all", L10n("Everything the container can hold", "Всё, что вмещает контейнер"))
                ], def: VideoPlanner.defaultPassMask).standard().visible(.eq(VideoKeys.audioCodec, "copy"))
                    .help(L10n("Other formats are re-encoded with the fallback codec.", "Остальные форматы перекодируются запасным кодеком.")).oracle("a.passmask.copy"),
                .picker(VideoKeys.audioFallback, L10n("Fallback codec", "Запасной кодек"), [
                    FieldOption("aac", "AAC"), FieldOption("ac3", "AC-3", requires: ["ff.enc.ac3"]), FieldOption("opus", "Opus", requires: ["ff.enc.libopus"]),
                    FieldOption("mp3", "MP3", requires: ["ff.enc.libmp3lame"])
                ], def: "aac").standard().visible(.eq(VideoKeys.audioCodec, "copy")).oracle("a.fallback.codec"),
                .segmented(VideoKeys.audioRC, L10n("Rate control", "Управление битрейтом"), [
                    FieldOption("bitrate", L10n("Bitrate", "Битрейт")), FieldOption("quality", L10n("Quality (VBR)", "Качество (VBR)"))
                ], def: "bitrate").standard().visible(audioIsLossy).enabled(audioHasQualityScale, reason: L10n("Quality mode needs MP3 or AAC through AudioToolbox.", "Режим качества есть у MP3 и AAC через AudioToolbox."))
                    .help(L10n("Quality varies the bitrate with the sound; Bitrate keeps it fixed.", "«Качество» меняет битрейт по ходу звука; «Битрейт» держит его постоянным."))
                    .oracle("a.rc.mode"),
                .picker(VideoKeys.audioBitrate, L10n("Bitrate (kbit/s)", "Битрейт (кбит/с)"), bitrateChoices.map { FieldOption($0, $0) }, def: "160").basic()
                    .visible(.all([audioIsLossy, .ne(VideoKeys.audioRC, "quality")]))
                    .help(L10n("Per stereo pair. 128 is fine for speech, 192 to 256 for music.", "На стереопару. 128 хватает для речи, 192-256 - для музыки."))
                    .aliases(["bitrate", "битрейт"]).oracle("a.bitrate.kbps"),
                .slider(VideoKeys.audioQuality, L10n("Quality", "Качество"), min: 0, max: 100, def: 70, minLabel: L10n("Smaller", "Меньше"), maxLabel: L10n("Better", "Лучше"))
                    .standard().visible(.all([audioIsLossy, .eq(VideoKeys.audioRC, "quality")])).oracle("a.quality.size"),
                .picker(VideoKeys.audioMixdown, L10n("Channels", "Каналы"), mixdownOptions(), def: "stereo").basic()
                    .visible(.ne(VideoKeys.audioCodec, "copy"))
                    .help(L10n("Dolby Pro Logic II folds surround into stereo that keeps a surround feel on capable receivers.", "Dolby Pro Logic II сводит объёмный звук в стерео, сохраняя эффект на совместимых ресиверах."))
                    .aliases(["stereo", "mono", "5.1", "каналы"]).oracle("a.mixdown.channels"),
                .picker(VideoKeys.audioRate, L10n("Sample rate", "Частота дискретизации"),
                        [FieldOption("auto", L10n("Keep the source rate", "Как у исходника"))] + sampleRateChoices.map { FieldOption($0, "\($0) Hz") }, def: "auto").standard()
                    .visible(.ne(VideoKeys.audioCodec, "copy")).oracle("a.rate.hz"),
                .slider(VideoKeys.audioGain, L10n("Volume change", "Изменение громкости"), min: -20, max: 20, step: 0.5, def: 0, unit: "dB", decimals: 1).standard()
                    .visible(.ne(VideoKeys.audioCodec, "copy")).oracle("a.gain.db"),
                .slider(VideoKeys.audioDRC, L10n("Dynamic range compression", "Сжатие динамического диапазона"), min: 0, max: 4, step: 0.1, def: 0, decimals: 1).expert()
                    .visible(.all([.ne(VideoKeys.audioCodec, "copy"), .any([.source("audio.0.codec", .eq, "ac3"), .source("audio.0.codec", .eq, "eac3")])]))
                    .help(L10n("Makes quiet parts louder for night listening. Only for Dolby Digital sources.", "Подтягивает тихие места для ночного просмотра. Только для источников Dolby Digital.")).oracle("a.drc.argv"),
                .picker(VideoKeys.audioComp, L10n("Compressor", "Компрессор"), [
                    FieldOption("off", L10n("Off", "Выкл.")), FieldOption("light", L10n("Light", "Слабый")), FieldOption("moderate", L10n("Moderate", "Умеренный")),
                    FieldOption("strong", L10n("Strong", "Сильный")), FieldOption("nightmode", L10n("Night mode", "Ночной режим"))
                ], def: "off").expert().visible(.ne(VideoKeys.audioCodec, "copy")).needs(ffOnly)
                    .help(L10n("Evens out loud and quiet moments. Night mode keeps dialogue clear at low volume.", "Выравнивает громкие и тихие моменты. «Ночной режим» сохраняет разборчивость диалогов при малой громкости.")).oracle("a.comp.peak"),
                .picker(VideoKeys.audioNorm, L10n("Loudness", "Громкость"), [
                    FieldOption("off", L10n("Off", "Выкл.")), FieldOption("ebu", L10n("EBU R128 (-23 LUFS)", "EBU R128 (-23 LUFS)")),
                    FieldOption("podcast", L10n("Podcast (-16 LUFS)", "Подкаст (-16 LUFS)")), FieldOption("streaming", L10n("Streaming (-14 LUFS)", "Стриминг (-14 LUFS)")),
                    FieldOption("custom", L10n("Custom", "Своя"))
                ], def: "off").standard().visible(.ne(VideoKeys.audioCodec, "copy")).needs(ffOnly)
                    .help(L10n("Evens out the volume between clips. Measured first, then applied.", "Выравнивает громкость между роликами. Сначала измеряется, затем применяется.")).oracle("a.norm.lufs"),
                .number(VideoKeys.audioNormLUFS, L10n("Target loudness", "Целевая громкость"), min: -30, max: -5, def: -16, unit: "LUFS").expert()
                    .visible(.eq(VideoKeys.audioNorm, "custom"))
                    .help(L10n("Typical values: -23 broadcast, -16 podcasts, -14 streaming.", "Типичные значения: -23 вещание, -16 подкасты, -14 стриминг.")).oracle("a.norm.lufs"),
                .text(VideoKeys.audioName, L10n("Track name", "Название дорожки"), placeholder: L10n("Stereo", "Стерео")).expert().visible(notAudioOnly)
                    .help(L10n("Shown by players in the audio menu.", "Показывается плеерами в меню звука.")).oracle("a.name.tag"),
                .text(VideoKeys.audioLang, L10n("Language tag", "Язык дорожки"), placeholder: L10n("eng", "rus"), validation: .regex("^[a-z]{3}$")).expert().visible(notAudioOnly)
                    .help(L10n("Three letters, for example rus, eng, lav.", "Три буквы, например rus, eng, lav.")).oracle("a.lang.tag")
            ]),
            .make("tracks", L10n("Track table", "Таблица дорожек"), level: .expert, collapsed: true, visible: .all([notAudioOnly, .ne(VideoKeys.audioMode, "none")]), [
                .tracks(VideoKeys.audioTracks, L10n("Output audio tracks", "Звуковые дорожки результата"), table)
                    .expert().help(L10n("When the table has rows, it replaces the track rules above. Add a row to build a second track, for example AAC stereo plus AC-3.",
                                        "Если в таблице есть строки, они заменяют правила выше. Добавьте строку, чтобы сделать вторую дорожку, например AAC стерео и AC-3."))
                    .oracle("a.tracks.streams")
            ])
        ])
    }

    static func mixdownOptions() -> [FieldOption] {
        [FieldOption("auto", L10n("Keep the source layout", "Как у исходника")), FieldOption("mono", L10n("Mono", "Моно")), FieldOption("stereo", L10n("Stereo", "Стерео")),
         FieldOption("dpl2", L10n("Dolby Pro Logic II", "Dolby Pro Logic II")), FieldOption("5.1", "5.1"), FieldOption("7.1", "7.1")]
    }
}
