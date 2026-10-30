import Foundation
import UniformTypeIdentifiers

// Schema pages "Subtitles" (2.7), "Chapters and tags" (2.8), "Range" (2.9) and the GIF branch (2.10).

extension VideoSchemas {
    static var subtitleTypes: [UTType] {
        ["srt", "vtt", "ass", "ssa", "sub", "ttml"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
    }

    static func subtitlesPage() -> OptionPage {
        let burn = OptionExpr.eq(VideoKeys.subMode, "burn")
        let hasExt = OptionExpr.isSet(VideoKeys.extFile)
        let fonts = ["SF Pro Text", "Helvetica Neue", "Arial", "Avenir Next", "Georgia", "Menlo"]
        return .make("subtitles", symbol: "captions.bubble", L10n("Subtitles", "Субтитры"), visible: vNotIn(VideoKeys.container, ["gif", "mp3", "avi"]), [
            .make("mode", L10n("Subtitles", "Субтитры"), [
                .segmented(VideoKeys.subMode, L10n("Subtitles", "Субтитры"), [
                    FieldOption("none", L10n("None", "Нет")),
                    FieldOption("keep", L10n("Keep", "Сохранить")),
                    FieldOption("burn", L10n("Burn in", "Вшить"), enabledWhen: .ne(VideoKeys.vcodec, "copy")),
                    FieldOption("external", L10n("From a file", "Из файла"))
                ], def: "keep").basic()
                    .help(L10n("Keep adds selectable tracks; Burn in draws the text into the picture for every player; From a file adds your own subtitle file.",
                               "«Сохранить» добавляет выбираемые дорожки; «Вшить» рисует текст на картинке для любого плеера; «Из файла» добавляет ваш файл субтитров."))
                    .aliases(["subtitles", "captions", "субтитры", "burn"]).oracle("s.mode.streams"),
                .text(VideoKeys.subLangs, L10n("Languages to keep", "Языки для сохранения"), placeholder: L10n("All languages", "Все языки"))
                    .standard().visible(.eq(VideoKeys.subMode, "keep"))
                    .help(L10n("Three-letter codes separated by commas. Empty keeps every language.", "Трёхбуквенные коды через запятую. Пусто - сохранить все языки.")).oracle("s.langs.streams"),
                .toggle(VideoKeys.subForcedOnly, L10n("Forced only", "Только форсированные")).standard().visible(.eq(VideoKeys.subMode, "keep"))
                    .help(L10n("Keeps only the lines for foreign-language speech.", "Оставляет только реплики на иностранном языке.")).oracle("s.forced.streams"),
                .picker(VideoKeys.subDefault, L10n("Turn on by default", "Включать по умолчанию"), [
                    FieldOption("none", L10n("No track", "Ни одну")), FieldOption("first", L10n("First track", "Первую")), FieldOption("forced", L10n("Forced track", "Форсированную"))
                ], def: "none").standard().visible(.eq(VideoKeys.subMode, "keep")).oracle("s.default.disposition")
            ]),
            .make("file", L10n("Subtitle file", "Файл субтитров"), visible: vIn(VideoKeys.subMode, ["keep", "burn", "external"]), [
                .file(VideoKeys.extFile, L10n("Subtitle file", "Файл субтитров"), types: subtitleTypes).standard()
                    .help(L10n("SRT, WebVTT, ASS or SSA. The text encoding is detected automatically.", "SRT, WebVTT, ASS или SSA. Кодировка определяется автоматически.")).oracle("s.ext.track"),
                .number(VideoKeys.extOffset, L10n("Time offset", "Сдвиг по времени"), min: -600_000, max: 600_000, step: 100, def: 0, unit: "ms").standard().visible(hasExt)
                    .help(L10n("Positive delays the text.", "Положительное значение задерживает текст.")).oracle("s.ext.offset"),
                .picker(VideoKeys.extCharset, L10n("Text encoding", "Кодировка текста"), [
                    FieldOption("auto", L10n("Detect automatically", "Определить автоматически")), FieldOption("utf-8", "UTF-8"), FieldOption("utf-16", "UTF-16"),
                    FieldOption("windows-1251", "Windows-1251"), FieldOption("windows-1257", "Windows-1257"), FieldOption("windows-1252", "Windows-1252"),
                    FieldOption("koi8-r", "KOI8-R"), FieldOption("cp866", "CP866"), FieldOption("iso-8859-13", "ISO-8859-13")
                ], def: "auto").standard().visible(hasExt)
                    .help(L10n("A wrong choice shows garbage letters.", "Неверный выбор даёт «кракозябры».")).oracle("s.ext.charset"),
                .text(VideoKeys.extLang, L10n("Language", "Язык"), def: "und", validation: .regex("^[a-z]{3}$")).standard().visible(.all([hasExt, .not(burn)]))
                    .oracle("s.ext.lang")
            ]),
            .make("burn", L10n("Burned-in text", "Вшитый текст"), visible: burn, [
                .picker(VideoKeys.burnTrack, L10n("Track to burn in", "Какую дорожку вшить"),
                        [FieldOption("auto", L10n("First text track", "Первая текстовая дорожка"))] + (0..<8).map { FieldOption("\($0)", L10n("Track \($0 + 1)", "Дорожка \($0 + 1)")) },
                        def: "auto").standard().visible(.not(hasExt)).oracle("s.burn.window"),
                .picker(VideoKeys.burnFont, L10n("Font", "Шрифт"), fonts.map { FieldOption($0, $0) }, def: "SF Pro Text").standard().oracle("s.burn.font"),
                .slider(VideoKeys.burnSize, L10n("Size (% of picture height)", "Размер (% высоты кадра)"), min: 3, max: 10, step: 0.5, def: 5.5, decimals: 1).standard().oracle("s.burn.size"),
                .color(VideoKeys.burnColor, L10n("Text color", "Цвет текста"), def: "#FFFFFF").standard().oracle("s.burn.color"),
                .color(VideoKeys.burnOutlineColor, L10n("Outline color", "Цвет обводки"), def: "#000000").standard().oracle("s.burn.outline"),
                .slider(VideoKeys.burnOutline, L10n("Outline", "Обводка"), min: 0, max: 6, step: 0.5, def: 2, decimals: 1).standard().oracle("s.burn.outline"),
                .slider(VideoKeys.burnShadow, L10n("Shadow", "Тень"), min: 0, max: 4, step: 0.5, def: 1, decimals: 1).standard().oracle("s.burn.shadow"),
                .toggle(VideoKeys.burnBox, L10n("Background box", "Плашка под текстом")).expert()
                    .help(L10n("A dark box behind the text keeps it readable on busy pictures.", "Тёмная плашка под текстом делает его читаемым на пёстрой картинке.")).oracle("s.burn.box"),
                .slider(VideoKeys.burnBoxOpacity, L10n("Box opacity", "Непрозрачность плашки"), min: 0, max: 100, def: 50, unit: "%").expert().visible(.isSet(VideoKeys.burnBox))
                    .help(L10n("0 is invisible, 100 is solid black.", "0 - невидимая, 100 - сплошная чёрная.")).oracle("s.burn.box"),
                .picker(VideoKeys.burnPos, L10n("Position", "Положение"), [
                    FieldOption("bottom", L10n("Bottom", "Внизу")), FieldOption("middle", L10n("Middle", "По центру")), FieldOption("top", L10n("Top", "Вверху"))
                ], def: "bottom").standard().oracle("s.burn.pos"),
                .slider(VideoKeys.burnMargin, L10n("Margin", "Отступ"), min: 0, max: 20, step: 0.5, def: 6, unit: "%", decimals: 1).standard().oracle("s.burn.pos")
            ])
        ])
    }

    static func tagsPage() -> OptionPage {
        let custom = OptionExpr.eq(VideoKeys.metadataMode, "custom")
        let chapterBoxes = ["mp4", "mov", "mkv", "webm", "same"]
        func tag(_ key: String, _ en: String, _ ru: String) -> OptionField {
            .text(key, L10n(en, ru)).expert().visible(custom).oracle("md.tags")
        }
        return .make("tags", symbol: "tag", L10n("Chapters and tags", "Главы и теги"), visible: notAudioOnly, [
            .make("chapters", L10n("Chapters", "Главы"), visible: vIn(VideoKeys.container, chapterBoxes), [
                .segmented(VideoKeys.chapterMode, L10n("Chapters", "Главы"), [
                    FieldOption("keep", L10n("Keep", "Сохранить")), FieldOption("none", L10n("Remove", "Убрать")),
                    FieldOption("auto", L10n("Every N minutes", "Каждые N минут")), FieldOption("custom", L10n("Custom list", "Свой список"))
                ], def: "keep").basic()
                    .aliases(["chapters", "главы"]).oracle("ch.list"),
                .number(VideoKeys.chapterInterval, L10n("Chapter every", "Глава каждые"), min: 1, max: 60, def: 5, unit: "min").standard().visible(.eq(VideoKeys.chapterMode, "auto")).oracle("ch.list"),
                .tracks(VideoKeys.chapterRows, L10n("Chapter list", "Список глав"), TrackSpec(columns: [
                    .time("start", L10n("Start", "Начало"), def: 0, allowEmpty: false),
                    .text("title", L10n("Title", "Название"))
                ], maxRows: 200, rowTitleKey: "title", addTitle: L10n("Add Chapter", "Добавить главу")), defaultRows: { src in
                    (src?.streams(of: .chapter) ?? []).map { s in ["start": .double(s.facts["start"]?.asDouble ?? 0), "title": .string(s.title)] }
                }).standard().visible(.eq(VideoKeys.chapterMode, "custom"))
                    .help(L10n("Starts with the chapters of the file. Edit, add or remove rows.", "Начинается с глав файла. Меняйте, добавляйте и удаляйте строки.")).oracle("ch.list")
            ]),
            .make("metadata", L10n("Tags", "Теги"), [
                .segmented(VideoKeys.metadataMode, L10n("Metadata", "Метаданные"), [
                    FieldOption("keep", L10n("Keep", "Сохранить")), FieldOption("strip", L10n("Remove all", "Удалить всё")), FieldOption("custom", L10n("Edit", "Изменить"))
                ], def: "keep").basic()
                    .help(L10n("Keep copies titles, dates and tags; Remove all cleans everything personal, including location and camera.",
                               "«Сохранить» копирует названия, даты и теги; «Удалить всё» очищает всё личное, включая геолокацию и камеру."))
                    .aliases(["metadata", "privacy", "exif", "gps", "метаданные", "приватность"]).oracle("md.strip"),
                .toggle(VideoKeys.metadataNoGPS, L10n("Remove the location only", "Удалить только геолокацию")).standard().visible(.eq(VideoKeys.metadataMode, "keep"))
                    .oracle("md.noGPS"),
                tag(VideoKeys.mdTitle, "Title", "Название"), tag(VideoKeys.mdArtist, "Artist", "Автор"), tag(VideoKeys.mdAlbum, "Album", "Альбом"),
                tag(VideoKeys.mdYear, "Year", "Год"), tag(VideoKeys.mdGenre, "Genre", "Жанр"), tag(VideoKeys.mdComment, "Comment", "Комментарий"),
                tag(VideoKeys.mdDescription, "Description", "Описание"), tag(VideoKeys.mdCopyright, "Copyright", "Авторские права"), tag(VideoKeys.mdLanguage, "Language", "Язык"),
                .file(VideoKeys.mdCover, L10n("Cover image", "Обложка"), types: [.png, .jpeg]).standard().visible(vIn(VideoKeys.container, ["mp4", "mov", "mkv", "same"]))
                    .help(L10n("Shown as the poster of the file.", "Показывается как постер файла.")).oracle("md.cover"),
                .toggle(VideoKeys.mdKeepDates, L10n("Keep the original creation date", "Сохранить исходную дату создания"), def: true).expert().visible(.ne(VideoKeys.metadataMode, "strip"))
                    .oracle("md.dates")
            ])
        ])
    }

    static func rangePage() -> OptionPage {
        .make("range", symbol: "scissors", L10n("Range", "Фрагмент"), [
            .make("range", L10n("Cut", "Вырезать"), [
                .time(VideoKeys.trimStart, L10n("Start", "Начало"), def: 0, allowEmpty: true, placeholder: L10n("0:00", "0:00")).basic()
                    .help(L10n("For example 0:30 or 1:02:03.", "Например, 0:30 или 1:02:03.")).aliases(["trim", "cut", "обрезать", "начало"]).oracle("t.duration"),
                .time(VideoKeys.trimEnd, L10n("End", "Конец"), placeholder: L10n("Until the end", "До конца")).basic()
                    .help(L10n("An absolute time, not a length. Empty means until the end.", "Абсолютное время, а не длительность. Пусто - до конца.")).oracle("t.duration"),
                .toggle(VideoKeys.trimAccurate, L10n("Frame-accurate cut", "Точная по кадрам обрезка"), def: true).standard()
                    .help(L10n("Off copies the streams and snaps to key frames: instant, but the start can move a second or two earlier.",
                               "Выключено: потоки копируются и привязываются к ключевым кадрам - мгновенно, но начало может сдвинуться на секунду-две."))
                    .oracle("t.copy")
            ])
        ])
    }

    static func gifPage() -> OptionPage {
        .make("gif", symbol: "photo.on.rectangle", L10n("Animation", "Анимация"), visible: .eq(VideoKeys.container, "gif"), [
            .make("gif", L10n("GIF", "GIF"), [
                .slider(VideoKeys.gifFps, L10n("Frames per second", "Кадров в секунду"), min: 5, max: 30, def: 15).basic().oracle("gif.frames"),
                .picker(VideoKeys.gifWidth, L10n("Width", "Ширина"), ["240", "320", "480", "640", "800", "1080"].map { FieldOption($0, "\($0) px") }, def: "480").basic()
                    .help(L10n("Never larger than the video.", "Не больше ширины видео.")).oracle("gif.size"),
                .slider(VideoKeys.gifColors, L10n("Colors", "Цвета"), min: 16, max: 256, def: 256).standard().oracle("gif.colors"),
                .picker(VideoKeys.gifDither, L10n("Dithering", "Дизеринг"), [
                    FieldOption("none", L10n("None", "Нет")), FieldOption("bayer", "Bayer"), FieldOption("floyd_steinberg", "Floyd-Steinberg"), FieldOption("sierra2_4a", "Sierra")
                ], def: "bayer").standard().oracle("gif.dither"),
                .picker(VideoKeys.gifLoop, L10n("Repeat", "Повторы"), [
                    FieldOption("forever", L10n("Forever", "Бесконечно")), FieldOption("once", L10n("Once", "Один раз")), FieldOption("3", L10n("3 times", "3 раза")), FieldOption("5", L10n("5 times", "5 раз"))
                ], def: "forever").standard().oracle("gif.loop")
            ])
        ])
    }
}
