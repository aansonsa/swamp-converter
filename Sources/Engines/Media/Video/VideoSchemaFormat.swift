import Foundation

// Schema pages "Format" and "Video" (spec/handbrake.md 2.2, 2.3). Every field carries an oracle id (the probe that proves its effect:
// see VideoTests); levels follow the spec (B basic, S standard, E expert); conditions disable or hide, capabilities disable with a reason.

func vIn(_ key: String, _ values: [String]) -> OptionExpr { .in(key, values.map { OptionValue.string($0) }) }
func vNotIn(_ key: String, _ values: [String]) -> OptionExpr { .not(vIn(key, values)) }

extension VideoSchemas {
    /// Codecs with a quality/bitrate model (everything except stream copy and the profile-driven intermediate codecs).
    static let rateCodecs = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg4"]
    static let swTuneCodecs = ["h264", "hevc", "av1", "vp9"]

    static func formatPage() -> OptionPage {
        .make("format", symbol: "shippingbox", L10n("Format", "Формат"), [
            .make("container", L10n("Container", "Контейнер"), [
                .picker(VideoKeys.container, L10n("Container", "Контейнер"), [
                    FieldOption("mp4", "MP4"),
                    FieldOption("mov", "MOV"),
                    FieldOption("mkv", "MKV", requires: ["tool.ffmpeg"]),
                    FieldOption("webm", "WebM", requires: ["tool.ffmpeg"]),
                    FieldOption("gif", L10n("GIF animation", "GIF-анимация"), requires: ["tool.ffmpeg"]),
                    FieldOption("mp3", L10n("MP3, audio only", "MP3, только звук"), requires: ["tool.ffmpeg"]),
                    FieldOption("avi", L10n("AVI (old players)", "AVI (старые плееры)"), requires: ["tool.ffmpeg"]),
                    FieldOption("same", L10n("Same as the original", "Как у оригинала"))
                ], def: "mp4").basic()
                    .help(L10n("MP4 plays almost everywhere; MKV holds any codec and subtitle; WebM is for browsers; MOV is for editing.",
                               "MP4 открывается почти везде; MKV вмещает любые кодеки и субтитры; WebM - для браузеров; MOV - для монтажа."))
                    .aliases(["format", "формат", "mkv", "mp4", "webm", "mov"]).oracle("container.format"),
                .toggle(VideoKeys.faststart, L10n("Optimize for streaming", "Оптимизировать для потоковой передачи"), def: true)
                    .visible(vIn(VideoKeys.container, ["mp4", "mov", "same"]))
                    .help(L10n("Puts the index at the start so playback begins before the download ends.", "Индекс переносится в начало файла: воспроизведение начинается до окончания загрузки."))
                    .aliases(["faststart", "web optimized", "стриминг"]).oracle("faststart.moov"),
                .toggle(VideoKeys.appleTag, L10n("Apple-compatible HEVC tag", "Тег совместимости с Apple"), def: true)
                    .visible(.all([.eq(VideoKeys.vcodec, "hevc"), vIn(VideoKeys.container, ["mp4", "mov", "same"])]))
                    .help(L10n("Writes the hvc1 tag so QuickTime, Safari and iPhone open the file.", "Записывает тег hvc1, чтобы файл открывался в QuickTime, Safari и на iPhone."))
                    .aliases(["hvc1", "hev1"]).oracle("tag.hvc1"),
                .toggle(VideoKeys.alignAV, L10n("Fix audio / video start offset", "Выровнять начало звука и видео"))
                    .expert().visible(.ne(VideoKeys.container, "gif"))
                    .help(L10n("Use only if the result is out of sync.", "Включайте, только если звук уходит от картинки.")).oracle("alignav.offset")
            ])
        ])
    }

    static func videoPage() -> OptionPage {
        let codecAll = ["h264", "hevc", "vp9", "av1", "prores", "vp8", "mpeg4", "ffv1", "dnxhr", "copy"]
        let noRate: [String] = ["copy", "prores", "ffv1", "dnxhr"]
        let softOnlyTwoPass = OptionExpr.any([.all([vIn(VideoKeys.vcodec, ["h264", "hevc"]), .ne(VideoKeys.venc, "hardware")]), .eq(VideoKeys.vcodec, "vp9")])
        func codecOption(_ v: String, _ label: L10n, containers: [String], requires: [String] = []) -> FieldOption {
            FieldOption(v, label, enabledWhen: vIn(VideoKeys.container, containers + ["same"]), requires: requires)
        }
        _ = codecAll
        return .make("video", symbol: "film", L10n("Video", "Видео"), visible: vNotIn(VideoKeys.container, ["gif", "mp3"]), [
            .make("codec", L10n("Codec", "Кодек"), [
                .picker(VideoKeys.vcodec, L10n("Video codec", "Видеокодек"), [
                    codecOption("h264", "H.264", containers: ["mp4", "mov", "mkv", "avi"]),
                    codecOption("hevc", "HEVC (H.265)", containers: ["mp4", "mov", "mkv"]),
                    codecOption("vp9", "VP9", containers: ["mp4", "mkv", "webm"], requires: ["ff.enc.libvpx-vp9"]),
                    codecOption("av1", "AV1", containers: ["mp4", "mkv", "webm"], requires: ["ff.enc.libsvtav1"]),
                    codecOption("prores", "ProRes", containers: ["mov", "mkv"]),
                    codecOption("vp8", "VP8", containers: ["mkv", "webm"], requires: ["ff.enc.libvpx"]),
                    codecOption("mpeg4", "MPEG-4", containers: ["mp4", "mov", "mkv", "avi"], requires: ["ff.enc.mpeg4"]),
                    codecOption("ffv1", "FFV1", containers: ["mkv"], requires: ["ff.enc.ffv1"]),
                    codecOption("dnxhr", "DNxHR", containers: ["mov", "mkv"], requires: ["ff.enc.dnxhd"]),
                    FieldOption("copy", L10n("Copy, no re-encoding", "Копировать без перекодирования"))
                ], def: "h264").basic()
                    .help(L10n("H.264 is the safest. HEVC is about 40% smaller but needs newer devices. AV1 is the smallest and the slowest.",
                               "H.264 - самый совместимый. HEVC примерно на 40 % компактнее, но нужны новые устройства. AV1 - самый компактный и самый медленный."))
                    .aliases(["codec", "кодек", "x264", "x265", "h265"]).oracle("vcodec.codec"),
                .segmented(VideoKeys.venc, L10n("Encoder", "Кодировщик"), [
                    FieldOption("auto", L10n("Auto", "Авто")),
                    FieldOption("hardware", L10n("Hardware", "Аппаратный")),
                    FieldOption("software", L10n("Software", "Программный"))
                ], def: "auto").enabled(vIn(VideoKeys.vcodec, ["h264", "hevc", "prores"]))
                    .help(L10n("Hardware (Apple media engine) is several times faster; software gives smaller files at the same quality.",
                               "Аппаратный (медиа-движок Apple) в несколько раз быстрее; программный даёт файл меньше при том же качестве."))
                    .aliases(["videotoolbox", "hardware", "gpu"]).oracle("venc.encoder"),
                .segmented(VideoKeys.bitdepth, L10n("Color depth", "Глубина цвета"), [
                    FieldOption("auto", L10n("Auto", "Авто")),
                    FieldOption("8", L10n("8 bit", "8 бит")),
                    FieldOption("10", L10n("10 bit", "10 бит")),
                    FieldOption("12", L10n("12 bit", "12 бит"), enabledWhen: vIn(VideoKeys.vcodec, ["hevc", "vp9"]))
                ], def: "auto").standard().enabled(vNotIn(VideoKeys.vcodec, ["copy", "mpeg4", "vp8", "prores", "dnxhr"]))
                    .help(L10n("10-bit avoids banding and is required for HDR; some older TVs cannot play 10-bit H.264.",
                               "10 бит убирает полосы в градиентах и нужны для HDR; часть старых телевизоров не воспроизводит 10-бит H.264."))
                    .aliases(["10 bit", "pix_fmt", "hdr"]).oracle("bitdepth.pixfmt"),
                .picker(VideoKeys.chroma, L10n("Chroma subsampling", "Цветовая субдискретизация"), [
                    FieldOption("4:2:0", "4:2:0"), FieldOption("4:2:2", "4:2:2"), FieldOption("4:4:4", "4:4:4")
                ], def: "4:2:0").expert().enabled(vIn(VideoKeys.vcodec, ["h264", "hevc", "vp9"]))
                    .help(L10n("Leave at 4:2:0 for playback; 4:2:2 / 4:4:4 for editing.", "Для просмотра оставьте 4:2:0; 4:2:2 и 4:4:4 - для монтажа."))
                    .oracle("chroma.pixfmt")
            ]),
            .make("quality", L10n("Quality", "Качество"), visible: vNotIn(VideoKeys.vcodec, ["copy"]), [
                .segmented(VideoKeys.rateControl, L10n("Quality mode", "Режим качества"), [
                    FieldOption("cq", L10n("Constant quality", "Постоянное качество")),
                    FieldOption("abr", L10n("Average bitrate", "Средний битрейт")),
                    FieldOption("size", L10n("Target size", "Целевой размер")),
                    FieldOption("lossless", L10n("Lossless", "Без потерь"), enabledWhen: .all([vIn(VideoKeys.vcodec, ["h264", "hevc", "vp9"]), .ne(VideoKeys.venc, "hardware")]))
                ], def: "cq").basic().enabled(vNotIn(VideoKeys.vcodec, noRate))
                    .help(L10n("Constant quality keeps the picture even and lets the size vary. Average bitrate and target size control the file size instead.",
                               "Постоянное качество держит картинку ровной, размер меняется. Средний битрейт и целевой размер задают размер файла."))
                    .aliases(["crf", "bitrate", "битрейт", "размер"]).oracle("rc.mode"),
                .slider(VideoKeys.cq, L10n("Quality (RF)", "Качество (RF)"), min: 0, max: 63, def: 23, minLabel: L10n("Better quality", "Лучше качество"), maxLabel: L10n("Smaller file", "Меньше файл"))
                    .basic().visible(.all([.eq(VideoKeys.rateControl, "cq"), .ne(VideoKeys.venc, "hardware"), vNotIn(VideoKeys.vcodec, noRate)]))
                    .help(L10n("Lower RF means better quality and a bigger file. 18-24 is the sweet spot for H.264 and HEVC; AV1 and VP9 accept higher values.",
                               "Меньше RF - лучше картинка и крупнее файл. Для H.264 и HEVC оптимально 18-24; AV1 и VP9 допускают более высокие значения."))
                    .aliases(["crf", "rf", "quality", "качество"]).oracle("cq.size"),
                .slider(VideoKeys.cqHardware, L10n("Quality (hardware)", "Качество (аппаратное)"), min: 20, max: 100, def: 60, minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество"))
                    .basic().visible(.all([.eq(VideoKeys.rateControl, "cq"), .eq(VideoKeys.venc, "hardware"), vIn(VideoKeys.vcodec, ["h264", "hevc"])]))
                    .help(L10n("VideoToolbox quality: higher means better and bigger.", "Качество VideoToolbox: больше - лучше и крупнее."))
                    .aliases(["videotoolbox quality"]).oracle("cq.hw.size"),
                .number(VideoKeys.vbitrate, L10n("Video bitrate", "Битрейт видео"), min: 100, max: 200_000, step: 100, def: 2500, unit: "kbit/s")
                    .basic().visible(.eq(VideoKeys.rateControl, "abr"))
                    .defaultFromSource(.int(2500)) { src in
                        guard let w = src?.number("video.width"), let h = src?.number("video.height") else { return nil }
                        let fps = src?.number("video.fps") ?? 30
                        return .int(max(300, Int((w * h * fps * 0.07 / 1000 / 100).rounded()) * 100))
                    }
                    .help(L10n("Higher is better and bigger.", "Больше - лучше и крупнее.")).oracle("abr.bitrate"),
                .number(VideoKeys.targetMB, L10n("Target file size", "Целевой размер файла"), min: 0.1, max: 100_000, step: 0.1, def: 25, unit: "MB", decimals: 1)
                    .basic().visible(.eq(VideoKeys.rateControl, "size"))
                    .help(L10n("Quality is chosen to fit; very small sizes force a lower resolution.", "Качество подбирается под размер; при очень малом размере уменьшается разрешение."))
                    .aliases(["fit to size", "whatsapp", "telegram", "mail"]).oracle("size.target"),
                .toggle(VideoKeys.sizeLadder, L10n("Lower the resolution if needed", "Уменьшать разрешение при необходимости"), def: true)
                    .visible(.eq(VideoKeys.rateControl, "size"))
                    .help(L10n("Steps down 1080p, 720p, 540p, 360p until the picture stays clean.", "Шаги: 1080p, 720p, 540p, 360p, пока картинка остаётся чистой.")).oracle("size.ladder"),
                .toggle(VideoKeys.twoPass, L10n("Two-pass encoding", "Двухпроходное кодирование"), def: true)
                    .visible(.all([vIn(VideoKeys.rateControl, ["abr", "size"]), softOnlyTwoPass]))
                    .help(L10n("Slower (up to twice) but spreads bits better when the bitrate is fixed.", "Медленнее (до 2 раз), но точнее распределяет биты при фиксированном битрейте.")).oracle("twopass.passes"),
                .toggle(VideoKeys.turbo1, L10n("Fast first pass", "Быстрый первый проход"), def: true)
                    .expert().visible(.all([.isSet(VideoKeys.twoPass), vIn(VideoKeys.vcodec, ["h264", "hevc"])]))
                    .help(L10n("Makes the first pass faster at a small cost in quality.", "Ускоряет первый проход ценой небольшой потери качества.")).oracle("turbo1.argv"),
                .number(VideoKeys.vbvMaxrate, L10n("Maximum bitrate", "Максимальный битрейт"), min: 0, max: 200_000, step: 100, def: 0, unit: "kbit/s")
                    .expert().visible(.all([vIn(VideoKeys.vcodec, ["h264", "hevc", "vp9"]), .ne(VideoKeys.venc, "hardware")]))
                    .help(L10n("For devices with a hard limit. 0 means off.", "Для устройств с жёстким пределом. 0 - выключено.")).oracle("vbv.maxrate"),
                .number(VideoKeys.vbvBuffer, L10n("Buffer size", "Размер буфера"), min: 0, max: 400_000, step: 100, def: 0, unit: "kbit")
                    .expert().visible(.gt(VideoKeys.vbvMaxrate, 0))
                    .help(L10n("How much data the player may buffer. 0 uses twice the maximum bitrate.", "Сколько данных плеер может держать в буфере. 0 - вдвое больше максимального битрейта.")).oracle("vbv.buffer")
            ]),
            .make("tuning", L10n("Encoder tuning", "Настройка кодировщика"), level: .standard, collapsed: true, visible: vNotIn(VideoKeys.vcodec, ["copy"]), [
                .picker(VideoKeys.speed, L10n("Encoding speed", "Скорость кодирования"), VideoCodecTables.stops.map { s in
                    FieldOption(s, L10n(speedLabelEN(s), speedLabelRU(s)))
                }, def: "medium").standard().visible(vNotIn(VideoKeys.vcodec, ["prores", "ffv1", "dnxhr", "mpeg4"]))
                    .help(L10n("Slower means a smaller file at the same quality.", "Медленнее - файл меньше при том же качестве."))
                    .aliases(["preset", "пресет", "скорость"]).oracle("speed.preset"),
                .picker(VideoKeys.tune, L10n("Content tuning", "Настройка под контент"), [
                    FieldOption("none", L10n("None", "Нет")),
                    FieldOption("film", L10n("Film", "Фильм"), enabledWhen: vIn(VideoKeys.vcodec, ["h264", "vp9"])),
                    FieldOption("animation", L10n("Animation", "Анимация"), enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc"])),
                    FieldOption("grain", L10n("Grain", "Зерно"), enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc"])),
                    FieldOption("stillimage", L10n("Still image", "Слайды"), enabledWhen: .eq(VideoKeys.vcodec, "h264")),
                    FieldOption("psnr", "PSNR", enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc", "av1"])),
                    FieldOption("ssim", "SSIM", enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc", "av1"])),
                    FieldOption("fastdecode", L10n("Fast decoding", "Быстрое декодирование"), enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc"])),
                    FieldOption("zerolatency", L10n("Low latency", "Малая задержка"), enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc"])),
                    FieldOption("vq", L10n("Visual quality", "Визуальное качество"), enabledWhen: .eq(VideoKeys.vcodec, "av1")),
                    FieldOption("screen", L10n("Screen content", "Запись экрана"), enabledWhen: .eq(VideoKeys.vcodec, "vp9"))
                ], def: "none").standard().visible(.all([vIn(VideoKeys.vcodec, swTuneCodecs), .ne(VideoKeys.venc, "hardware")]))
                    .help(L10n("Pick Animation for cartoons, Grain to keep film grain.", "«Анимация» - для мультфильмов, «Зерно» - чтобы сохранить киноплёнку."))
                    .oracle("tune.argv"),
                .picker(VideoKeys.profile, L10n("Profile", "Профиль"), [
                    FieldOption("auto", L10n("Auto", "Авто")),
                    FieldOption("baseline", "Baseline", enabledWhen: .eq(VideoKeys.vcodec, "h264")),
                    FieldOption("main", "Main", enabledWhen: vIn(VideoKeys.vcodec, ["h264", "hevc"])),
                    FieldOption("high", "High", enabledWhen: .eq(VideoKeys.vcodec, "h264")),
                    FieldOption("high10", "High 10", enabledWhen: .all([.eq(VideoKeys.vcodec, "h264"), .ne(VideoKeys.venc, "hardware")])),
                    FieldOption("high422", "High 4:2:2", enabledWhen: .all([.eq(VideoKeys.vcodec, "h264"), .ne(VideoKeys.venc, "hardware")])),
                    FieldOption("high444", "High 4:4:4", enabledWhen: .all([.eq(VideoKeys.vcodec, "h264"), .ne(VideoKeys.venc, "hardware")])),
                    FieldOption("main10", "Main 10", enabledWhen: .eq(VideoKeys.vcodec, "hevc")),
                    FieldOption("main12", "Main 12", enabledWhen: .all([.eq(VideoKeys.vcodec, "hevc"), .ne(VideoKeys.venc, "hardware")])),
                    FieldOption("main422-10", "Main 4:2:2 10", enabledWhen: .all([.eq(VideoKeys.vcodec, "hevc"), .ne(VideoKeys.venc, "hardware")])),
                    FieldOption("main444-8", "Main 4:4:4", enabledWhen: .all([.eq(VideoKeys.vcodec, "hevc"), .ne(VideoKeys.venc, "hardware")])),
                    FieldOption("proxy", "Proxy", enabledWhen: .eq(VideoKeys.vcodec, "prores")),
                    FieldOption("lt", "LT", enabledWhen: .eq(VideoKeys.vcodec, "prores")),
                    FieldOption("standard", "422", enabledWhen: .eq(VideoKeys.vcodec, "prores")),
                    FieldOption("hq", "HQ", enabledWhen: vIn(VideoKeys.vcodec, ["prores", "dnxhr"])),
                    FieldOption("4444", "4444", enabledWhen: .eq(VideoKeys.vcodec, "prores")),
                    FieldOption("xq", "4444 XQ", enabledWhen: .eq(VideoKeys.vcodec, "prores")),
                    FieldOption("lb", "LB", enabledWhen: .eq(VideoKeys.vcodec, "dnxhr")),
                    FieldOption("sq", "SQ", enabledWhen: .eq(VideoKeys.vcodec, "dnxhr")),
                    FieldOption("hqx", "HQX", enabledWhen: .eq(VideoKeys.vcodec, "dnxhr")),
                    FieldOption("444", "444", enabledWhen: .eq(VideoKeys.vcodec, "dnxhr"))
                ], def: "auto").standard().visible(vIn(VideoKeys.vcodec, ["h264", "hevc", "prores", "dnxhr"]))
                    .help(L10n("Leave on Auto unless a device demands one.", "Оставьте «Авто», если устройство не требует иного."))
                    .oracle("profile.codec"),
                .picker(VideoKeys.level, L10n("Level", "Уровень"), ["auto", "3.0", "3.1", "3.2", "4.0", "4.1", "4.2", "5.0", "5.1", "5.2"].map {
                    FieldOption($0, $0 == "auto" ? L10n("Auto", "Авто") : L10n($0))
                }, def: "auto").expert().visible(.all([vIn(VideoKeys.vcodec, ["h264", "hevc"]), .ne(VideoKeys.venc, "hardware")]))
                    .help(L10n("Limits resolution and bitrate for old devices; Auto is right for almost everyone.", "Ограничивает разрешение и битрейт для старых устройств; «Авто» подходит почти всем."))
                    .oracle("level.codec"),
                .number(VideoKeys.keyint, L10n("Key frame interval", "Интервал ключевых кадров"), min: 0, max: 20, step: 0.5, def: 0, unit: "s", decimals: 1)
                    .expert().visible(vIn(VideoKeys.vcodec, ["h264", "hevc", "av1", "vp9", "vp8", "mpeg4"]))
                    .help(L10n("Shorter helps seeking and streaming, larger saves space. 0 means automatic.", "Короче - быстрее перемотка и стриминг, длиннее - компактнее. 0 - автоматически.")).oracle("keyint.gop"),
                .picker(VideoKeys.bframes, L10n("B-frames", "B-кадры"), ["auto", "0", "1", "2", "3", "4", "6", "8", "16"].map { FieldOption($0, $0 == "auto" ? L10n("Auto", "Авто") : L10n($0)) }, def: "auto")
                    .expert().visible(vIn(VideoKeys.vcodec, ["h264", "hevc"]))
                    .help(L10n("More means a smaller file and slightly slower encoding.", "Больше - файл меньше, кодирование чуть медленнее.")).oracle("bframes.count"),
                .stepper(VideoKeys.refs, L10n("Reference frames", "Опорные кадры"), min: 0, max: 16, def: 0)
                    .expert().visible(vIn(VideoKeys.vcodec, ["h264", "hevc"])).help(L10n("0 means automatic.", "0 - автоматически.")).oracle("refs.count"),
                .slider(VideoKeys.filmgrain, L10n("Film-grain synthesis", "Синтез зерна"), min: 0, max: 50, def: 0)
                    .expert().visible(.eq(VideoKeys.vcodec, "av1"))
                    .help(L10n("Keeps the grain look at a much lower bitrate.", "Сохраняет вид плёнки при заметно меньшем битрейте.")).oracle("filmgrain.argv"),
                .text(VideoKeys.extra, L10n("Additional encoder options", "Дополнительные параметры кодировщика"), placeholder: L10n("key=value:key=value", "ключ=значение:ключ=значение"),
                      validation: .regex(#"^([A-Za-z0-9_.-]+=[^\s:=]+)(:[A-Za-z0-9_.-]+=[^\s:=]+)*$"#))
                    .expert().visible(.all([vIn(VideoKeys.vcodec, ["h264", "hevc", "av1"]), .ne(VideoKeys.venc, "hardware")]))
                    .help(L10n("Validated; passed to x264, x265 or SVT-AV1.", "Проверяются; передаются в x264, x265 или SVT-AV1.")).oracle("extra.params")
            ]),
            .make("hdr", L10n("HDR and color", "HDR и цвет"), level: .standard, collapsed: true, visible: vNotIn(VideoKeys.vcodec, ["copy"]), [
                .picker(VideoKeys.hdr, L10n("HDR", "HDR"), [
                    FieldOption("keep", L10n("Keep HDR", "Сохранить HDR")),
                    FieldOption("sdr", L10n("Convert to SDR", "Перевести в SDR"), requires: ["media.hdr2sdr"]),
                    FieldOption("ignore", L10n("Treat as normal video", "Как обычное видео"))
                ], def: "keep").standard().visible(.source("video.hdr", .eq, true))
                    .help(L10n("Keeping HDR needs 10-bit and an HDR-capable player; Convert to SDR makes it look right everywhere (needs a newer ffmpeg).",
                               "Сохранение HDR требует 10 бит и совместимого плеера; «В SDR» - выглядит правильно везде (нужен более новый ffmpeg)."))
                    .oracle("hdr.tags"),
                .picker(VideoKeys.colorspace, L10n("Color matrix", "Цветовая матрица"), [
                    FieldOption("auto", L10n("Auto", "Авто")), FieldOption("bt709", "BT.709"), FieldOption("bt601", "BT.601"), FieldOption("bt2020", "BT.2020")
                ], def: "auto").expert().needs(["tool.ffmpeg"])
                    .help(L10n("The color matrix the picture is tagged with. BT.709 is right for HD, BT.601 for old SD video.", "Цветовая матрица, которой помечается картинка. BT.709 - для HD, BT.601 - для старого SD-видео.")).oracle("colorspace.tag"),
                .picker(VideoKeys.colorRange, L10n("Color range", "Диапазон цвета"), [
                    FieldOption("auto", L10n("Auto", "Авто")), FieldOption("limited", L10n("Limited", "Ограниченный")), FieldOption("full", L10n("Full", "Полный"))
                ], def: "auto").expert().needs(["tool.ffmpeg"])
                    .help(L10n("Limited is normal for video. Full uses every brightness level and suits screen recordings.", "«Ограниченный» - обычный для видео. «Полный» использует все уровни яркости, подходит для записи экрана.")).oracle("range.tag")
            ])
        ])
    }

    static func speedLabelEN(_ s: String) -> String {
        ["ultrafast": "Fastest", "superfast": "Super fast", "veryfast": "Very fast", "faster": "Faster", "fast": "Fast", "medium": "Balanced", "slow": "Slow", "slower": "Slower", "veryslow": "Very slow"][s] ?? s
    }
    static func speedLabelRU(_ s: String) -> String {
        ["ultrafast": "Максимально быстро", "superfast": "Очень быстро", "veryfast": "Быстро+", "faster": "Быстрее", "fast": "Быстро", "medium": "Сбалансированно", "slow": "Медленно", "slower": "Медленнее", "veryslow": "Очень медленно"][s] ?? s
    }
}
