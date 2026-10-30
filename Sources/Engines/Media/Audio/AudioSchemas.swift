import Foundation
import UniformTypeIdentifiers

// The option pages of the audio targets (spec/handbrake.md 3.2): Format, Sound, Range, Tags and artwork.
// Every field carries an oracle id; AudioTests proves each one by reading real output back.
// Defaults are NEUTRAL wherever a field is inactive or "off": the engine may read any key without asking `isActive`.

enum AudioSchemas {
    static let convertID = "audio.convert"
    static let joinID = "audio.join"

    // Option value sets used by several conditions.
    static let lossyTargets: [OptionValue] = ["auto", "same", "mp3", "aac", "opus", "ogg", "ac3", "eac3", "m4b", "m4r"]
    static let qualityTargets: [OptionValue] = ["auto", "same", "mp3", "aac", "ogg", "m4b", "m4r"]
    static let aacTargets: [OptionValue] = ["auto", "same", "aac", "m4b", "m4r"]
    static let ffmpegOnly = ["ff.present"]

    static func convert(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: convertID, title: L10n("Audio", "Аудио"), symbol: "waveform", pages: [formatPage, soundPage, rangePage, tagsPage])
    }

    /// Join: output rate and channel layout default to the BEST input (spec/backends.md fact 11); order, gap, crossfade.
    static func join(items: [FileItem]) -> OptionSchema {
        var target = convertField(AudioKeys.target)
        target.kind = .picker(targetOptions(excluding: [.auto, .caf, .ac3, .eac3, .m4r]))
        target.defaultValue = .value("same")
        target.help = L10n("The format of the joined file. “Keep the format” uses the format of the first file in the order.",
                           "Формат итогового файла. «Тот же формат» берёт формат первого файла в порядке склейки.")
        var tagsMode = convertField(AudioKeys.tagsMode)
        tagsMode.help = L10n("Keep copies the tags and cover of the first file.", "«Оставить» копирует теги и обложку первого файла.")
        let format = OptionPage.make("format", symbol: "waveform", L10n("Format", "Формат"), [
            .make("target", [target, convertField(AudioKeys.rateControl), convertField(AudioKeys.bitrate), convertField(AudioKeys.quality)]),
        ])
        let joinGroup = OptionGroup.make("join", L10n("Joining", "Склейка"), [
            .picker(AudioKeys.joinOrder, L10n("Order", "Порядок"), [
                FieldOption("natural", L10n("By name (natural order)", "По имени (естественный порядок)")),
                FieldOption("selection", L10n("As selected", "Как выбрано"))
            ], def: "natural").basic()
                .help(L10n("Natural order puts track2 before track10.", "Естественный порядок ставит track2 перед track10."))
                .oracle("audjoin.o.order"),
            .picker(AudioKeys.joinRate, L10n("Sample rate", "Частота дискретизации"),
                    [FieldOption("auto", L10n("Best of the inputs", "Лучшая из исходных"))] + AudRates.standard.map { FieldOption(String($0), AudRates.label($0)) }, def: "auto")
                .standard()
                .help(L10n("Every file is converted to this rate. Automatic uses the highest rate among the files, so nothing is downgraded.",
                           "Все файлы приводятся к этой частоте. «Лучшая» берёт наибольшую частоту среди файлов, чтобы ничего не ухудшалось."))
                .oracle("audjoin.o.rate"),
            .picker(AudioKeys.joinChannels, L10n("Channels", "Каналы"), [
                FieldOption("auto", L10n("Best of the inputs", "Лучшие из исходных")),
                FieldOption("mono", L10n("Mono", "Моно")),
                FieldOption("stereo", L10n("Stereo", "Стерео"))
            ], def: "auto").standard()
                .help(L10n("Automatic gives stereo when any file is stereo.", "Автоматически: стерео, если хотя бы один файл стерео."))
                .oracle("audjoin.o.channels"),
            .number(AudioKeys.joinGap, L10n("Silence between files", "Пауза между файлами"), min: 0, max: 30, step: 0.5, def: 0, unit: "s", decimals: 1)
                .standard()
                .enabled(.lte(AudioKeys.joinCrossfade, 0))
                .oracle("audjoin.o.gap"),
            .number(AudioKeys.joinCrossfade, L10n("Crossfade", "Перекрытие (кроссфейд)"), min: 0, max: 15, step: 0.5, def: 0, unit: "s", decimals: 1)
                .standard()
                .help(L10n("The end of one file fades out while the next fades in.", "Конец одного файла затихает, пока начинается следующий."))
                .oracle("audjoin.o.crossfade")
        ])
        let tags = OptionPage.make("tags", symbol: "tag", L10n("Tags and artwork", "Теги и обложка"), [
            .make("tags", [tagsMode] + AudioKeys.tagFields.map { convertField($0.key) }),
            .make("cover", [convertField(AudioKeys.coverMode), convertField(AudioKeys.coverFile), convertField(AudioKeys.coverMax)])
        ])
        return OptionSchema(id: joinID, title: L10n("Join audio", "Склейка аудио"), symbol: "arrow.triangle.merge",
                            pages: [format, OptionPage.make("join", symbol: "arrow.triangle.merge", L10n("Join", "Склейка"), [joinGroup]), tags])
    }

    /// One field of the convert schema by key (the join schema reuses them).
    static func convertField(_ key: String) -> OptionField { fieldIndex[key]! }
    private static let fieldIndex: [String: OptionField] = Dictionary(uniqueKeysWithValues: convert(items: []).allFields.map { ($0.key, $0) })

    static func targetOptions(excluding: Set<AudTarget> = []) -> [FieldOption] {
        func req(_ t: AudTarget) -> [String] {
            switch t {
            case .mp3: return ["native.audio.enc.mp3"]
            case .opus: return ["native.audio.enc.opus"]
            case .ogg: return ["native.audio.enc.ogg"]
            case .ac3: return ["native.audio.enc.ac3"]
            case .eac3: return ["native.audio.enc.eac3"]
            default: return []
            }
        }
        let hints: [AudTarget: L10n] = [
            .auto: L10n("Keeps the family of the source (MP3 stays MP3, AAC stays AAC) and never re-encodes a small file into a worse one.",
                        "Сохраняет семейство формата (MP3 остаётся MP3, AAC остаётся AAC) и не пережимает уже лёгкий файл в худший."),
            .mp3: L10n("Plays everywhere. Needs ffmpeg or lame.", "Играет везде. Нужен ffmpeg или lame."),
            .opus: L10n("The most efficient lossy codec. Needs ffmpeg.", "Самый эффективный кодек с потерями. Нужен ffmpeg."),
            .ogg: L10n("Ogg Vorbis. Uses libvorbis when ffmpeg has it, otherwise ffmpeg’s built-in encoder (stereo only). Needs ffmpeg.", "Ogg Vorbis. Использует libvorbis, если он есть в ffmpeg, иначе встроенный кодировщик ffmpeg (только стерео). Нужен ffmpeg."),
            .ac3: L10n("For video players and home theatre. Needs ffmpeg.", "Для видеоплееров и домашнего кинотеатра. Нужен ffmpeg.")
        ]
        return AudTarget.allCases.filter { !excluding.contains($0) }.map {
            FieldOption($0.rawValue, $0.title, requires: req($0), hint: hints[$0])
        }
    }

    // MARK: Format

    static var formatPage: OptionPage {
        let bitrateOptions = [FieldOption("0", L10n("Automatic", "Автоматически"))] + AudBitrates.extended.map { FieldOption(String($0), "\($0) kbit/s") }
        let rateOptions = [FieldOption("keep", L10n("Keep", "Как в исходнике"))] + AudRates.standard.map { FieldOption(String($0), AudRates.label($0)) }
        return OptionPage.make("format", symbol: "waveform", L10n("Format", "Формат"), [
            .make("target", [
                .picker(AudioKeys.target, L10n("Format", "Формат"), targetOptions(), def: "aac").basic()
                    .help(L10n("MP3 and AAC play everywhere; FLAC, ALAC and WAV lose nothing; Opus is the most efficient.",
                               "MP3 и AAC воспроизводятся везде; FLAC, ALAC и WAV без потерь; Opus — самый эффективный."))
                    .aliases(["codec", "кодек", "format", "mp3", "aac", "m4a", "flac", "формат"])
                    .affects([.estimate, .plan, .preview]).oracle("aud.o.target"),
                .segmented(AudioKeys.rateControl, L10n("Bit rate mode", "Режим битрейта"), [
                    FieldOption("bitrate", L10n("Bit rate", "Битрейт")), FieldOption("quality", L10n("Quality (VBR)", "Качество (VBR)"))
                ], def: "bitrate").basic()
                    .enabled(.in(AudioKeys.target, qualityTargets))
                    .help(L10n("Quality mode lets the encoder spend more bits on hard passages.", "В режиме качества кодек тратит больше бит на сложные фрагменты."))
                    .oracle("aud.o.rc"),
                .picker(AudioKeys.bitrate, L10n("Bit rate", "Битрейт"), bitrateOptions, def: "0").basic()
                    .enabled(.all([.in(AudioKeys.target, lossyTargets), .eq(AudioKeys.rateControl, "bitrate")]))
                    .help(L10n("Automatic picks a bit rate that keeps the quality of the source.", "Автоматический выбор сохраняет качество исходника."))
                    .aliases(["kbps", "битрейт", "bitrate"]).oracle("aud.o.bitrate"),
                .slider(AudioKeys.quality, L10n("Quality", "Качество"), min: 0, max: 100, step: 1, def: 78,
                        minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better sound", "Лучше звук")).basic()
                    .enabled(.all([.in(AudioKeys.target, qualityTargets), .eq(AudioKeys.rateControl, "quality")]))
                    .help(L10n("78 matches MP3 V2 (about 190 kbit/s).", "78 соответствует MP3 V2 (около 190 кбит/с)."))
                    .oracle("aud.o.quality"),
                .picker(AudioKeys.aacProfile, L10n("AAC profile", "Профиль AAC"), [
                    FieldOption("lc", L10n("AAC-LC (standard)", "AAC-LC (стандарт)")),
                    FieldOption("he", L10n("HE-AAC (below 64 kbit/s)", "HE-AAC (ниже 64 кбит/с)")),
                    FieldOption("hev2", L10n("HE-AAC v2 (below 40 kbit/s)", "HE-AAC v2 (ниже 40 кбит/с)"))
                ], def: "lc").expert()
                    .enabled(.all([.in(AudioKeys.target, aacTargets), .eq(AudioKeys.rateControl, "bitrate")]))
                    .help(L10n("HE profiles sound better at very low bit rates. Encoded with the macOS encoder.", "Профили HE лучше звучат на очень низких битрейтах. Кодируются средствами macOS."))
                    .oracle("aud.o.profile")
            ]),
            .make("wave", L10n("Sound format", "Параметры звука"), [
                .picker(AudioKeys.sampleRate, L10n("Sample rate", "Частота дискретизации"), rateOptions, def: "keep").standard()
                    .help(L10n("Some formats accept only certain rates and are adjusted automatically.", "Некоторые форматы принимают не все частоты, значение подбирается автоматически."))
                    .oracle("aud.o.rate"),
                .picker(AudioKeys.channels, L10n("Channels", "Каналы"), [
                    FieldOption("keep", L10n("Keep", "Как в исходнике")), FieldOption("mono", L10n("Mono", "Моно")), FieldOption("stereo", L10n("Stereo", "Стерео"))
                ], def: "keep").basic().aliases(["mono", "stereo", "моно", "стерео", "downmix"]).oracle("aud.o.channels"),
                .picker(AudioKeys.bitDepth, L10n("Bit depth", "Разрядность"), [
                    FieldOption("keep", L10n("Keep", "Как в исходнике")), FieldOption("16", L10n("16-bit", "16 бит")),
                    FieldOption("24", L10n("24-bit", "24 бита")), FieldOption("32f", L10n("32-bit float", "32 бита (float)"))
                ], def: "keep").standard()
                    .enabled(.any([.in(AudioKeys.target, ["same", "wav", "aiff", "caf", "alac"]), .all([.eq(AudioKeys.target, "flac"), .cap("ff.present")])]),
                             reason: L10n("Bit depth applies to lossless formats (FLAC needs ffmpeg).", "Разрядность относится к форматам без потерь (для FLAC нужен ffmpeg)."))
                    .oracle("aud.o.bits"),
                .picker(AudioKeys.dither, L10n("Dither", "Дизеринг"), [
                    FieldOption("triangular", L10n("Triangular (recommended)", "Треугольный (рекомендуется)")),
                    FieldOption("rectangular", L10n("Rectangular", "Прямоугольный")),
                    FieldOption("none", L10n("None", "Нет"))
                ], def: "triangular").expert()
                    .enabled(.any([.in(AudioKeys.target, ["same", "wav", "aiff", "caf", "alac"]), .all([.eq(AudioKeys.target, "flac"), .cap("ff.present")])]),
                             reason: L10n("Dither applies to lossless formats.", "Дизеринг относится к форматам без потерь."))
                    .help(L10n("When the sound is written with 16 bits, a whisper of noise hides the rounding error. Files that are already 16-bit and untouched are never dithered.",
                               "При записи в 16 бит лёгкий шум скрывает ошибку округления. Файлы, которые уже 16-битные и не менялись, не обрабатываются."))
                    .aliases(["dither", "дизеринг"]).oracle("aud.o.dither")
            ]),
            OptionGroup.make("encoder", L10n("Encoder details", "Параметры кодека"), level: .expert, collapsed: true, [
                .slider(AudioKeys.flacLevel, L10n("FLAC compression level", "Уровень сжатия FLAC"), min: 0, max: 12, step: 1, def: 5,
                        minLabel: L10n("Faster", "Быстрее"), maxLabel: L10n("Smaller", "Меньше")).expert()
                    .enabled(.eq(AudioKeys.target, "flac")).needs(ffmpegOnly, reason: L10n("Needs ffmpeg.", "Нужен ffmpeg."))
                    .help(L10n("Higher is slower and a little smaller. The sound is identical.", "Выше — медленнее и чуть меньше. Звук идентичен."))
                    .oracle("aud.o.flacLevel"),
                .picker(AudioKeys.opusApp, L10n("Opus mode", "Режим Opus"), [
                    FieldOption("audio", L10n("Music", "Музыка")), FieldOption("voip", L10n("Voice", "Голос")), FieldOption("lowdelay", L10n("Low delay", "Малая задержка"))
                ], def: "audio").expert().enabled(.eq(AudioKeys.target, "opus")).needs(["native.audio.enc.opus"])
                    .help(L10n("Voice favors speech intelligibility.", "«Голос» оптимизирован под разборчивость речи."))
                    .oracle("aud.o.opusApp"),
                .picker(AudioKeys.opusVBR, L10n("Opus rate mode", "Режим битрейта Opus"), [
                    FieldOption("on", L10n("Variable", "Переменный")), FieldOption("constrained", L10n("Constrained variable", "Ограниченный переменный")), FieldOption("off", L10n("Constant", "Постоянный"))
                ], def: "on").expert().enabled(.eq(AudioKeys.target, "opus")).needs(["native.audio.enc.opus"]).oracle("aud.o.opusVbr"),
                .toggle(AudioKeys.mp3Joint, L10n("Joint stereo", "Joint stereo"), def: true).expert()
                    .enabled(.eq(AudioKeys.target, "mp3")).needs(["native.audio.enc.mp3"])
                    .help(L10n("Saves bits on near-identical channels. Turn off for the widest stereo image.", "Экономит биты, когда каналы близки. Выключите для максимально широкой стереопанорамы."))
                    .oracle("aud.o.mp3Joint"),
                .picker(AudioKeys.mp3ID3, L10n("ID3 tag version", "Версия тегов ID3"), [
                    FieldOption("v23", L10n("ID3v2.3 (most compatible)", "ID3v2.3 (самая совместимая)")), FieldOption("v24", L10n("ID3v2.4", "ID3v2.4"))
                ], def: "v23").expert().enabled(.eq(AudioKeys.target, "mp3")).needs(["native.audio.enc.mp3"]).oracle("aud.o.mp3Id3")
            ]),
            OptionGroup.make("fit", L10n("Size limit", "Ограничение размера"), level: .standard, [
                .number(AudioKeys.fitMB, L10n("Fit under", "Уложить в"), min: 0, max: 4096, step: 0.5, def: 0, unit: "MB", decimals: 1).standard()
                    .enabled(.in(AudioKeys.target, lossyTargets))
                    .help(L10n("0 means no limit. The bit rate is chosen so that the file stays just under this size.", "0 — без ограничения. Битрейт подбирается так, чтобы файл оказался чуть меньше этого размера."))
                    .aliases(["size", "размер", "whatsapp", "telegram", "discord", "limit"]).oracle("aud.o.fit")
            ])
        ])
    }

    // MARK: Sound

    static var soundPage: OptionPage {
        OptionPage.make("sound", symbol: "slider.vertical.3", L10n("Sound", "Звук"), [
            .make("level", L10n("Loudness", "Громкость"), [
                .slider(AudioKeys.gain, L10n("Volume", "Громкость"), min: -30, max: 30, step: 0.5, def: 0, unit: "dB", decimals: 1).standard()
                    .oracle("aud.o.gain"),
                .picker(AudioKeys.normalize, L10n("Normalize", "Нормализация"), [
                    FieldOption("off", L10n("Off", "Выкл.")),
                    FieldOption("peak", L10n("Peak (-1 dBFS)", "По пику (-1 dBFS)")),
                    FieldOption("ebu", L10n("Broadcast (-23 LUFS)", "Вещание (-23 LUFS)")),
                    FieldOption("podcast", L10n("Podcast and music (-16 LUFS)", "Подкасты и музыка (-16 LUFS)")),
                    FieldOption("streaming", L10n("Streaming (-14 LUFS)", "Стриминг (-14 LUFS)")),
                    FieldOption("custom", L10n("Custom…", "Свои значения…"))
                ], def: "off").basic()
                    .help(L10n("Brings the perceived loudness of the file to a standard level (EBU R128).", "Приводит воспринимаемую громкость файла к стандартному уровню (EBU R128)."))
                    .aliases(["loudness", "lufs", "r128", "громкость", "нормализовать"]).oracle("aud.o.norm"),
                .number(AudioKeys.normLUFS, L10n("Target loudness", "Целевая громкость"), min: -30, max: -5, step: 0.5, def: -16, unit: "LUFS", decimals: 1).expert()
                    .enabled(.eq(AudioKeys.normalize, "custom")).oracle("aud.o.normLufs"),
                .number(AudioKeys.normTP, L10n("True peak limit", "Предел истинного пика"), min: -9, max: 0, step: 0.5, def: -1.5, unit: "dBTP", decimals: 1).expert()
                    .enabled(.eq(AudioKeys.normalize, "custom")).oracle("aud.o.normTp"),
                .number(AudioKeys.normLRA, L10n("Loudness range", "Диапазон громкости"), min: 1, max: 20, step: 1, def: 11, unit: "LU").expert()
                    .enabled(.eq(AudioKeys.normalize, "custom")).needs(ffmpegOnly, reason: L10n("Needs ffmpeg.", "Нужен ffmpeg."))
                    .help(L10n("How much louder and quieter parts may differ. A small value evens out the dynamics; 11 leaves them alone.", "Насколько могут отличаться громкие и тихие места. Малое значение выравнивает динамику; 11 оставляет её как есть."))
                    .oracle("aud.o.normLra"),
                .toggle(AudioKeys.normTwoPass, L10n("Measure first (two passes)", "Сначала измерить (два прохода)"), def: true).expert()
                    .enabled(.in(AudioKeys.normalize, ["ebu", "podcast", "streaming", "custom"])).needs(ffmpegOnly, reason: L10n("Needs ffmpeg.", "Нужен ffmpeg."))
                    .help(L10n("More accurate and keeps the dynamics. A single pass is faster.", "Точнее и сохраняет динамику. Один проход быстрее."))
                    .oracle("aud.o.normTwoPass"),
                .toggle(AudioKeys.limiter, L10n("Limiter (prevent clipping)", "Лимитер (защита от клиппинга)"), def: false).expert()
                    .needs(["ff.filter.alimiter"], reason: L10n("Needs ffmpeg.", "Нужен ffmpeg.")).oracle("aud.o.limiter")
            ]),
            .make("fades", L10n("Fades", "Плавные переходы"), [
                .number(AudioKeys.fadeIn, L10n("Fade in", "Нарастание"), min: 0, max: 30, step: 0.5, def: 0, unit: "s", decimals: 1).standard().oracle("aud.o.fadeIn"),
                .number(AudioKeys.fadeOut, L10n("Fade out", "Затухание"), min: 0, max: 30, step: 0.5, def: 0, unit: "s", decimals: 1).standard().oracle("aud.o.fadeOut")
            ]),
            OptionGroup.make("clean", L10n("Clean up", "Очистка"), level: .expert, [
                .number(AudioKeys.highpass, L10n("High-pass filter", "Фильтр низких частот"), min: 0, max: 400, step: 10, def: 0, unit: "Hz").expert()
                    .needs(["ff.filter.highpass"], reason: L10n("Needs ffmpeg.", "Нужен ffmpeg."))
                    .help(L10n("Removes rumble below this frequency. 80 Hz suits voice. 0 is off.", "Убирает гул ниже этой частоты. 80 Гц подходит для голоса. 0 — выключено."))
                    .oracle("aud.o.hp"),
                .picker(AudioKeys.eq, L10n("Tone", "Тембр"), [
                    FieldOption("flat", L10n("Flat", "Без изменений")), FieldOption("bass", L10n("More bass", "Больше баса")),
                    FieldOption("treble", L10n("More treble", "Больше верхов")), FieldOption("voice", L10n("Voice clarity", "Чёткость голоса"))
                ], def: "flat").expert()
                    .needs(["ff.filter.bass", "ff.filter.treble", "ff.filter.equalizer"], reason: L10n("Needs ffmpeg.", "Нужен ffmpeg."))
                    .help(L10n("Voice cuts rumble below 80 Hz and lifts the 3 kHz presence band.", "«Голос» убирает гул ниже 80 Гц и поднимает область присутствия около 3 кГц."))
                    .aliases(["eq", "equalizer", "bass", "treble", "тембр"]).oracle("aud.o.eq"),
                .toggle(AudioKeys.silence, L10n("Trim silence at the ends", "Обрезать тишину по краям"), def: false).expert()
                    .needs(["ff.filter.silenceremove"], reason: L10n("Needs ffmpeg.", "Нужен ffmpeg.")).oracle("aud.o.silence"),
                .slider(AudioKeys.silenceDB, L10n("Silence threshold", "Порог тишины"), min: -80, max: -20, step: 1, def: -50, unit: "dB").expert()
                    .enabled(.isSet(AudioKeys.silence)).oracle("aud.o.silenceDb")
            ]),
            OptionGroup.make("tempo", L10n("Tempo", "Темп"), level: .standard, [
                .slider(AudioKeys.speed, L10n("Speed", "Скорость"), min: 0.5, max: 2.0, step: 0.05, def: 1.0, unit: "×", minLabel: L10n("Slower", "Медленнее"), maxLabel: L10n("Faster", "Быстрее"), decimals: 2).standard()
                    .needs(["ff.filter.atempo"], reason: L10n("Needs ffmpeg.", "Нужен ffmpeg."))
                    .help(L10n("The pitch stays the same.", "Высота тона сохраняется.")).oracle("aud.o.speed")
            ])
        ])
    }

    // MARK: Range

    static var rangePage: OptionPage {
        OptionPage.make("range", symbol: "timer", L10n("Range", "Фрагмент"), [
            .make("range", [
                .time(AudioKeys.trimStart, L10n("Start", "Начало"), def: nil, placeholder: L10n("0:00", "0:00")).basic()
                    .help(L10n("For example 0:30 or 1:02:03.", "Например, 0:30 или 1:02:03.")).oracle("aud.o.trimStart"),
                .time(AudioKeys.trimEnd, L10n("End", "Конец"), def: nil, placeholder: L10n("until the end", "до конца")).basic()
                    .help(L10n("A time in the file, not a length. Empty means until the end.", "Момент в файле, а не длительность. Пусто — до конца.")).oracle("aud.o.trimEnd"),
                .segmented(AudioKeys.trimMode, L10n("Cutting", "Способ обрезки"), [
                    FieldOption("accurate", L10n("Exact", "Точно")),
                    FieldOption("copy", L10n("Fast copy", "Быстрая копия"), requires: ffmpegOnly,
                                hint: L10n("No re-encoding, the cut snaps to the nearest audio frame. Needs ffmpeg.", "Без перекодирования, обрезка по границе аудиокадра. Нужен ffmpeg."))
                ], def: "accurate").standard().oracle("aud.o.trimMode")
            ])
        ])
    }

    // MARK: Tags and artwork

    static var tagsPage: OptionPage {
        func tag(_ key: String, _ en: String, _ ru: String, oracle: String) -> OptionField {
            .text(key, L10n(en, ru)).visible(.eq(AudioKeys.tagsMode, "custom")).expert().affects([.plan]).oracle(oracle)
        }
        return OptionPage.make("tags", symbol: "tag", L10n("Tags and artwork", "Теги и обложка"), [
            .make("tags", L10n("Tags", "Теги"), [
                .picker(AudioKeys.tagsMode, L10n("Tags", "Теги"), [
                    FieldOption("keep", L10n("Keep", "Оставить")), FieldOption("strip", L10n("Remove all", "Удалить все")), FieldOption("custom", L10n("Edit…", "Изменить…"))
                ], def: "keep").basic().affects([.plan])
                    .help(L10n("Remove all also drops the encoder name, so nothing about you or your software stays in the file.", "«Удалить все» убирает и название кодировщика: в файле не остаётся ничего о вас или вашей программе."))
                    .oracle("aud.o.tagsMode"),
                tag(AudioKeys.tagTitle, "Title", "Название", oracle: "aud.o.tag.title"),
                tag(AudioKeys.tagArtist, "Artist", "Исполнитель", oracle: "aud.o.tag.artist"),
                tag(AudioKeys.tagAlbum, "Album", "Альбом", oracle: "aud.o.tag.album"),
                tag(AudioKeys.tagAlbumArtist, "Album artist", "Исполнитель альбома", oracle: "aud.o.tag.albumArtist"),
                tag(AudioKeys.tagYear, "Year", "Год", oracle: "aud.o.tag.year"),
                tag(AudioKeys.tagTrack, "Track number", "Номер трека", oracle: "aud.o.tag.track"),
                tag(AudioKeys.tagTrackTotal, "Tracks in album", "Треков в альбоме", oracle: "aud.o.tag.trackTotal"),
                tag(AudioKeys.tagDisc, "Disc number", "Номер диска", oracle: "aud.o.tag.disc"),
                tag(AudioKeys.tagGenre, "Genre", "Жанр", oracle: "aud.o.tag.genre"),
                tag(AudioKeys.tagComposer, "Composer", "Композитор", oracle: "aud.o.tag.composer"),
                tag(AudioKeys.tagComment, "Comment", "Комментарий", oracle: "aud.o.tag.comment")
            ]),
            .make("cover", L10n("Cover art", "Обложка"), [
                .picker(AudioKeys.coverMode, L10n("Cover art", "Обложка"), [
                    FieldOption("keep", L10n("Keep", "Оставить")), FieldOption("remove", L10n("Remove", "Удалить")),
                    FieldOption("replace", L10n("Replace…", "Заменить…")), FieldOption("extract", L10n("Save as a picture", "Сохранить картинкой"))
                ], def: "keep").standard().affects([.plan])
                    .help(L10n("Save as a picture writes the cover next to the audio file and leaves it out of the audio.", "«Сохранить картинкой» кладёт обложку рядом с аудиофайлом и убирает её из аудио."))
                    .oracle("aud.o.coverMode"),
                .file(AudioKeys.coverFile, L10n("Picture", "Картинка"), types: [.image]).standard()
                    .visible(.eq(AudioKeys.coverMode, "replace")).affects([.plan]).oracle("aud.o.coverFile"),
                .picker(AudioKeys.coverMax, L10n("Cover size", "Размер обложки"), [
                    FieldOption("0", L10n("Original", "Исходный")), FieldOption("500", "500 px"), FieldOption("1000", "1000 px"),
                    FieldOption("1400", "1400 px"), FieldOption("3000", "3000 px")
                ], def: "0").expert().enabled(.in(AudioKeys.coverMode, ["keep", "replace"])).affects([.plan, .estimate])
                    .help(L10n("Larger covers are scaled down. Smaller ones are never enlarged.", "Большие обложки уменьшаются, маленькие не увеличиваются."))
                    .oracle("aud.o.coverMax")
            ])
        ])
    }
}
