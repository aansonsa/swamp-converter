import Foundation

// The two schemas of the video family: `video.convert` (every Studio page of spec/handbrake.md section 2) and `video.frames` (thumbnails and
// contact sheets). Pages live in VideoSchema*.swift. The schema is built once; capabilities are evaluated when options are resolved.

enum VideoSchemas {
    static let convertID = "video.convert"
    static let framesID = "video.frames"

    private static let convertSchema: OptionSchema = OptionSchema(
        id: convertID, title: L10n("Video", "Видео"), symbol: "film",
        pages: [formatPage(), videoPage(), picturePage(), filtersPage(), audioPage(), subtitlesPage(), tagsPage(), rangePage(), gifPage()],
        rules: rules())

    private static let framesSchema: OptionSchema = OptionSchema(id: framesID, title: L10n("Frames", "Кадры"), symbol: "camera", pages: [framesPage()])

    static func convert(items: [FileItem]) -> OptionSchema { convertSchema }
    static func frames(items: [FileItem]) -> OptionSchema { framesSchema }

    // MARK: Frames

    static func framesPage() -> OptionPage {
        .make("frames", symbol: "camera", L10n("Frames", "Кадры"), [
            .make("frames", L10n("What to extract", "Что извлечь"), [
                .picker(VideoKeys.frameMode, L10n("Extract", "Извлечь"), [
                    FieldOption("best", L10n("The best frame near the start", "Лучший кадр в начале")),
                    FieldOption("at", L10n("A frame at a time", "Кадр в заданный момент")),
                    FieldOption("every", L10n("A frame every N seconds", "Кадр каждые N секунд")),
                    FieldOption("scene", L10n("A frame at every scene change", "Кадр на каждой смене сцены")),
                    FieldOption("sheet", L10n("A contact sheet", "Контактный лист"))
                ], def: "best").basic()
                    .help(L10n("The best frame skips black and blurry openings. Scene changes find cuts automatically.", "Лучший кадр пропускает чёрные и размытые заставки. Смены сцен находятся автоматически."))
                    .aliases(["thumbnail", "screenshot", "миниатюра", "скриншот"]).oracle("frame.mode.files"),
                .time(VideoKeys.frameTime, L10n("Time", "Момент"), placeholder: L10n("10% into the clip", "10 % от начала")).basic()
                    .visible(.eq(VideoKeys.frameMode, "at")).oracle("frame.time.pick"),
                .number(VideoKeys.frameEvery, L10n("Every", "Каждые"), min: 0.5, max: 3600, step: 0.5, def: 10, unit: "s", decimals: 1).basic()
                    .visible(.eq(VideoKeys.frameMode, "every")).oracle("frame.every.count"),
                .stepper(VideoKeys.frameCount, L10n("At most", "Не больше"), min: 1, max: 500, def: 24, unit: nil).standard()
                    .visible(vIn(VideoKeys.frameMode, ["every", "scene", "sheet"])).help(L10n("For a contact sheet this is the number of pictures on the sheet.", "Для контактного листа - число картинок на листе."))
                    .oracle("frame.count.max"),
                .slider(VideoKeys.frameSceneThreshold, L10n("Scene sensitivity", "Чувствительность к сменам сцен"), min: 0.1, max: 0.9, step: 0.05, def: 0.4,
                        minLabel: L10n("More scenes", "Больше сцен"), maxLabel: L10n("Fewer scenes", "Меньше сцен"), decimals: 2).standard()
                    .visible(.eq(VideoKeys.frameMode, "scene")).oracle("frame.scene.count")
            ]),
            .make("output", L10n("Picture", "Картинка"), [
                .segmented(VideoKeys.frameFormat, L10n("Format", "Формат"), [FieldOption("png", "PNG"), FieldOption("jpg", "JPEG")], def: "png").basic().oracle("frame.format.magic"),
                .number(VideoKeys.frameWidth, L10n("Width", "Ширина"), min: 0, max: 8192, step: 10, def: 0, unit: "px").standard()
                    .help(L10n("0 keeps the original size.", "0 оставляет исходный размер.")).oracle("frame.width.size")
            ])
        ])
    }

    // MARK: Cross-field rules that read only option values and source facts (the numeric ones live in `VideoOperation.validate`)

    static func rules() -> [ValidationRule] {
        let copy = OptionExpr.eq(VideoKeys.vcodec, "copy")
        let changes: [OptionExpr] = [
            .ne(VideoKeys.rotate, "0"), .isSet(VideoKeys.flipH), .isSet(VideoKeys.flipV), .ne(VideoKeys.cropMode, "none"), .ne(VideoKeys.sizeMode, "source"),
            .ne(VideoKeys.fpsMode, "source"), .eq(VideoKeys.deinterlace, "on"), .ne(VideoKeys.denoise, "off"), .ne(VideoKeys.sharpen, "off"), .isSet(VideoKeys.gray),
            .ne(VideoKeys.wmMode, "none"), .eq(VideoKeys.subMode, "burn"), .lt(VideoKeys.filterSpeed, 0.999), .gt(VideoKeys.filterSpeed, 1.001), .isSet(VideoKeys.reverse),
            .gt(VideoKeys.fadeIn, 0), .gt(VideoKeys.fadeOut, 0), .ne(VideoKeys.padMode, "none")
        ]
        return [
            .warning("V03", when: .all([.eq(VideoKeys.container, "mp4"), vIn(VideoKeys.vcodec, ["vp9", "av1"])]),
                     L10n("VP9 and AV1 in MP4 play in browsers, but QuickTime and older iPhones may refuse them.", "VP9 и AV1 в MP4 воспроизводятся в браузерах, но QuickTime и старые iPhone могут отказаться."),
                     field: VideoKeys.vcodec, fix: OptionFix(title: L10n("Use HEVC", "Выбрать HEVC"), set: [VideoKeys.vcodec: "hevc"])),
            .warning("V04", when: .all([.eq(VideoKeys.vcodec, "hevc"), vIn(VideoKeys.container, ["mp4", "mov"]), .not(.isSet(VideoKeys.appleTag))]),
                     L10n("Without the hvc1 tag QuickTime may not open this HEVC file. Turn on the Apple-compatible tag.", "Без тега hvc1 QuickTime может не открыть этот HEVC-файл. Включите тег совместимости с Apple."),
                     field: VideoKeys.appleTag, fix: OptionFix(title: L10n("Turn On the Tag", "Включить тег"), set: [VideoKeys.appleTag: true])),
            .error("V05", when: .all([copy, .any(changes)]),
                   L10n("Copying video can’t be combined with filters, resizing or burned-in subtitles. Turn off Copy or remove them.", "Копирование видео нельзя сочетать с фильтрами, изменением размера и вшитыми субтитрами. Отключите «Копировать» или уберите их."),
                   field: VideoKeys.vcodec, fix: OptionFix(title: L10n("Re-encode as H.264", "Перекодировать в H.264"), set: [VideoKeys.vcodec: "h264"])),
            .warning("V07", when: .all([.eq(VideoKeys.vcodec, "h264"), .eq(VideoKeys.bitdepth, "10")]),
                     L10n("10-bit H.264 doesn’t play on iPhone, Apple TV or most TVs. Use HEVC or 8 bit.", "10-битный H.264 не воспроизводится на iPhone, Apple TV и большинстве ТВ. Выберите HEVC или 8 бит."),
                     field: VideoKeys.bitdepth, fix: OptionFix(title: L10n("Use 8 Bit", "Выбрать 8 бит"), set: [VideoKeys.bitdepth: "8"])),
            .warning("V09", when: .all([.eq(VideoKeys.audioCodec, "opus"), vIn(VideoKeys.container, ["mp4", "mov"])]),
                     L10n("Opus in MP4 or MOV plays in browsers but not in QuickTime. Use AAC for Apple devices.", "Opus в MP4 или MOV воспроизводится в браузерах, но не в QuickTime. Для устройств Apple выберите AAC."),
                     field: VideoKeys.audioCodec, fix: OptionFix(title: L10n("Use AAC", "Выбрать AAC"), set: [VideoKeys.audioCodec: "aac"])),
            .warning("V13", when: .all([vIn(VideoKeys.container, ["mp4", "mov", "webm"]), .eq(VideoKeys.subMode, "keep"), .source("sub.0.bitmap", .eq, true)]),
                     L10n("Picture-based subtitles can’t be kept in this container. Switch to MKV, or turn the subtitles off.", "Графические субтитры нельзя сохранить в этом контейнере. Выберите MKV или отключите субтитры."),
                     field: VideoKeys.subMode, fix: OptionFix(title: L10n("Switch to MKV", "Перейти на MKV"), set: [VideoKeys.container: "mkv"])),
            .warning("V15", when: .all([.eq(VideoKeys.container, "gif"), .source("duration", .gt, 15)]),
                     L10n("A GIF this long will be large. Consider MP4, fewer colors or a shorter clip.", "GIF такой длины будет очень большим. Подумайте об MP4, меньшем числе цветов или более коротком фрагменте."),
                     field: VideoKeys.container),
            .info("V17", when: .all([.isSet(VideoKeys.sizeUpscale), vIn(VideoKeys.sizeMode, ["limit", "fit", "fill"])]),
                  L10n("Enlarging doesn’t add detail.", "Увеличение не добавляет деталей."), field: VideoKeys.sizeUpscale),
            .info("V22", when: .all([.source("video.hdr", .eq, true), .not(.cap("media.hdr2sdr")), .ne(VideoKeys.vcodec, "copy")]),
                  L10n("HDR is kept: converting HDR to SDR needs a newer ffmpeg, which isn’t available. Keep the file on HDR-capable screens.", "HDR сохранится: для перевода HDR в SDR нужен более новый ffmpeg, но его нет. Смотрите файл на экранах с поддержкой HDR."),
                  field: VideoKeys.hdr),
            .warning("V21", when: .all([.source("video.hdr", .eq, true), .eq(VideoKeys.hdr, "keep"), .eq(VideoKeys.vcodec, "h264")]),
                     L10n("HDR needs 10-bit HEVC. H.264 will look washed out. Choose HEVC to keep HDR.", "Для HDR нужен 10-битный HEVC. В H.264 картинка будет блёклой. Выберите HEVC, чтобы сохранить HDR."),
                     field: VideoKeys.vcodec, fix: OptionFix(title: L10n("Use HEVC", "Выбрать HEVC"), set: [VideoKeys.vcodec: "hevc"])),
            .warning("V26", when: .all([.isSet(VideoKeys.reverse), .source("duration", .gt, 120)]),
                     L10n("Playing backwards is limited to clips of 2 minutes. This clip plays forwards.", "Обратное воспроизведение возможно для роликов до 2 минут. Этот ролик останется как есть."),
                     field: VideoKeys.reverse),
            .warning("V28", when: .all([.eq(VideoKeys.deinterlace, "on"), .source("video.interlaced", .eq, false)]),
                     L10n("No interlacing was found in this clip. Deinterlacing a progressive picture softens it; Auto is the safe choice.", "В этом ролике нет чересстрочной развёртки. Деинтерлейсинг прогрессивной картинки делает её мягче; «Авто» безопаснее."),
                     field: VideoKeys.deinterlace, fix: OptionFix(title: L10n("Use Auto", "Выбрать «Авто»"), set: [VideoKeys.deinterlace: "auto"]))
        ]
    }
}
