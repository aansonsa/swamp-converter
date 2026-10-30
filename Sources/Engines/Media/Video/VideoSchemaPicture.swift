import Foundation

// Schema page "Picture" (spec/handbrake.md 2.4): orientation, crop, size, borders, frame rate.
// GIF output has its own size and frame rate (gif.*), so the size and frame-rate groups are inactive for it.

extension VideoSchemas {
    static let notAudioOnly = OptionExpr.ne(VideoKeys.container, "mp3")
    static let notGifOrAudio = vNotIn(VideoKeys.container, ["gif", "mp3"])
    static let sizeBoxModes = ["exact", "fill", "fit"]

    /// Standard heights offered by the size limit, highest first.
    static let limitHeights = [2160, 1440, 1080, 720, 576, 540, 480, 360]

    static func nearestLimit(_ src: SourceInfo?) -> OptionValue? {
        guard let w = src?.number("video.width"), let h = src?.number("video.height") else { return nil }
        let short = Int(min(w, h))
        let pick = limitHeights.first { $0 <= short } ?? limitHeights.last ?? 360
        return .string("\(pick)p")
    }

    static let fpsChoices = ["5", "10", "12", "15", "20", "23.976", "24", "25", "29.97", "30", "48", "50", "59.94", "60", "72", "90", "100", "120"]

    static func picturePage() -> OptionPage {
        .make("picture", symbol: "crop", L10n("Picture", "Картинка"), visible: notAudioOnly, [
            .make("orientation", L10n("Orientation and crop", "Ориентация и обрезка"), [
                .segmented(VideoKeys.rotate, L10n("Rotate", "Поворот"), [
                    FieldOption("0", L10n("None", "Нет")), FieldOption("90", "90°"), FieldOption("180", "180°"), FieldOption("270", "270°")
                ], def: "0").basic()
                    .help(L10n("Turns the picture clockwise.", "Поворачивает картинку по часовой стрелке."))
                    .aliases(["rotate", "поворот", "повернуть"]).oracle("rotate.quadrants"),
                .toggle(VideoKeys.flipH, L10n("Flip horizontally", "Отразить по горизонтали")).standard()
                    .aliases(["mirror", "зеркало"]).oracle("flip.quadrants"),
                .toggle(VideoKeys.flipV, L10n("Flip vertically", "Отразить по вертикали")).standard().oracle("flip.quadrants"),
                .toggle(VideoKeys.respectMeta, L10n("Apply rotation stored in the file", "Учитывать поворот из метаданных"), def: true).expert()
                    .help(L10n("Phones store rotated footage as a note in the file. Turn this off to see the picture as it was recorded.",
                               "Телефоны хранят поворот кадра как пометку в файле. Выключите, чтобы увидеть кадр таким, каким он записан."))
                    .oracle("respectMeta.noautorotate"),
                .segmented(VideoKeys.cropMode, L10n("Crop", "Обрезка"), [
                    FieldOption("none", L10n("None", "Нет")), FieldOption("auto", L10n("Automatic", "Авто")), FieldOption("custom", L10n("Custom", "Вручную"))
                ], def: "none").basic()
                    .help(L10n("Automatic removes black bars; Custom lets you set each edge.", "«Авто» убирает чёрные полосы; «Вручную» задаёт каждый край."))
                    .aliases(["crop", "обрезать", "чёрные полосы"]).oracle("crop.dimensions"),
                cropField(VideoKeys.cropTop, L10n("Top", "Сверху")),
                cropField(VideoKeys.cropBottom, L10n("Bottom", "Снизу")),
                cropField(VideoKeys.cropLeft, L10n("Left", "Слева")),
                cropField(VideoKeys.cropRight, L10n("Right", "Справа"))
            ]),
            .make("size", L10n("Size", "Размер"), visible: notGifOrAudio, [
                .picker(VideoKeys.sizeMode, L10n("Size", "Размер"), [
                    FieldOption("source", L10n("Original", "Исходный")),
                    FieldOption("limit", L10n("No larger than", "Не больше")),
                    FieldOption("exact", L10n("Exact", "Точный")),
                    FieldOption("percent", L10n("Percent", "Проценты")),
                    FieldOption("fill", L10n("Fill the frame (crop)", "Заполнить кадр (с обрезкой)")),
                    FieldOption("fit", L10n("Fit the frame (add bars)", "Вписать в кадр (с полями)"))
                ], def: "source").basic()
                    .help(L10n("Original keeps the picture size; No larger than fits inside a maximum; Fill crops to an exact frame; Fit adds bars.",
                               "«Исходный» сохраняет размер кадра; «Не больше» вписывает в максимум; «Заполнить» обрезает под точный кадр; «Вписать» добавляет поля."))
                    .aliases(["resolution", "scale", "разрешение", "масштаб"]).oracle("size.dimensions"),
                .picker(VideoKeys.sizeLimit, L10n("Maximum size", "Максимальный размер"), limitHeights.map { FieldOption("\($0)p", "\($0)p") }, def: "1080p").basic()
                    .visible(.eq(VideoKeys.sizeMode, "limit"))
                    .defaultFromSource(.string("1080p")) { nearestLimit($0) }
                    .help(L10n("The short side never exceeds this height. Smaller pictures are not enlarged unless you allow it.",
                               "Короткая сторона не превысит эту высоту. Меньшие кадры не увеличиваются, если это не разрешено."))
                    .oracle("size.limit"),
                .number(VideoKeys.sizeW, L10n("Width", "Ширина"), min: 0, max: 16384, step: 2, def: 0, unit: "px")
                    .standard().visible(vIn(VideoKeys.sizeMode, sizeBoxModes))
                    .help(L10n("Leave one of width and height at 0 to keep the proportions.", "Оставьте ширину или высоту равной 0, чтобы сохранить пропорции."))
                    .oracle("size.exact"),
                .number(VideoKeys.sizeH, L10n("Height", "Высота"), min: 0, max: 16384, step: 2, def: 0, unit: "px")
                    .standard().visible(vIn(VideoKeys.sizeMode, sizeBoxModes)).oracle("size.exact"),
                .slider(VideoKeys.sizePercent, L10n("Scale", "Масштаб"), min: 10, max: 200, def: 50, unit: "%")
                    .standard().visible(.eq(VideoKeys.sizeMode, "percent")).oracle("size.percent"),
                .toggle(VideoKeys.sizeUpscale, L10n("Allow enlarging", "Разрешить увеличение"))
                    .standard().visible(vIn(VideoKeys.sizeMode, ["limit", "fit", "fill"]))
                    .help(L10n("Enlarging never adds detail.", "Увеличение не добавляет деталей.")).oracle("size.upscale"),
                .picker(VideoKeys.sizeAnchor, L10n("Crop focus", "Центр кадрирования"), [
                    FieldOption("center", L10n("Center", "Центр")), FieldOption("top", L10n("Top", "Верх")), FieldOption("bottom", L10n("Bottom", "Низ")),
                    FieldOption("left", L10n("Left", "Слева")), FieldOption("right", L10n("Right", "Справа")),
                    FieldOption("smart", L10n("Smart (faces and subject)", "Умный (лица и объект)"))
                ], def: "center").standard().visible(.eq(VideoKeys.sizeMode, "fill"))
                    .help(L10n("Smart follows faces and the main subject.", "«Умный» следует за лицами и главным объектом.")).oracle("size.anchor"),
                .picker(VideoKeys.sizeModulus, L10n("Round size to a multiple of", "Округлять размер до кратного"),
                        ["2", "4", "8", "16"].map { FieldOption($0, $0) }, def: "2").expert().visible(vIn(VideoKeys.sizeMode, ["limit", "percent"]))
                    .help(L10n("Width and height become multiples of this number. Some old devices and editors want 16.", "Ширина и высота станут кратными этому числу. Некоторым старым устройствам и редакторам нужно 16."))
                    .oracle("size.modulus"),
                .picker(VideoKeys.sizeScaler, L10n("Scaling method", "Метод масштабирования"), [
                    FieldOption("lanczos", "Lanczos"), FieldOption("bicubic", L10n("Bicubic", "Бикубический")), FieldOption("bilinear", L10n("Bilinear", "Билинейный")),
                    FieldOption("spline", "Spline"), FieldOption("neighbor", L10n("Nearest neighbor", "Ближайший сосед"))
                ], def: "lanczos").expert().visible(.ne(VideoKeys.sizeMode, "source"))
                    .help(L10n("Nearest neighbor keeps pixel art crisp.", "«Ближайший сосед» сохраняет резкость пиксель-арта.")).oracle("size.scaler"),
                .picker(VideoKeys.sizePar, L10n("Pixel shape", "Форма пикселя"), [
                    FieldOption("square", L10n("Square pixels (recommended)", "Квадратные (рекомендуется)")), FieldOption("keep", L10n("Keep as stored", "Как записано"))
                ], def: "square").expert()
                    .help(L10n("Square pixels are right unless you know otherwise. Some DVD and broadcast files store stretched pixels.",
                               "Квадратные пиксели подходят почти всегда. Часть DVD и телеэфира хранит растянутые пиксели."))
                    .oracle("size.par")
            ]),
            .make("borders", L10n("Borders", "Поля"), level: .standard, collapsed: true, visible: notGifOrAudio, [
                .picker(VideoKeys.padMode, L10n("Background for empty areas", "Фон пустых областей"), [
                    FieldOption("none", L10n("None", "Нет")),
                    FieldOption("bars", L10n("Solid bars", "Однотонные поля"), enabledWhen: .eq(VideoKeys.sizeMode, "fit")),
                    FieldOption("border", L10n("Add a border", "Добавить рамку")),
                    FieldOption("blur", L10n("Blurred picture", "Размытая копия кадра"), enabledWhen: .eq(VideoKeys.sizeMode, "fit"))
                ], def: "none").standard()
                    .help(L10n("Blur fills the bars with a blurred copy of the picture. It applies when Size is Fit; Add a border works with any size.",
                               "«Размытая копия» заполняет поля размытым кадром. Работает при размере «Вписать»; рамка - при любом размере."))
                    .aliases(["pad", "letterbox", "поля"]).oracle("pad.pixels"),
                .color(VideoKeys.padColor, L10n("Color", "Цвет"), def: "#000000").standard().visible(vIn(VideoKeys.padMode, ["bars", "border"])).oracle("pad.color"),
                padField(VideoKeys.padTop, L10n("Top border", "Рамка сверху")), padField(VideoKeys.padBottom, L10n("Bottom border", "Рамка снизу")),
                padField(VideoKeys.padLeft, L10n("Left border", "Рамка слева")), padField(VideoKeys.padRight, L10n("Right border", "Рамка справа"))
            ]),
            .make("fps", L10n("Frame rate", "Частота кадров"), visible: notGifOrAudio, [
                .segmented(VideoKeys.fpsMode, L10n("Frame rate", "Частота кадров"), [
                    FieldOption("source", L10n("Same as source", "Как у исходника")),
                    FieldOption("peak", L10n("No higher than", "Не выше")),
                    FieldOption("constant", L10n("Constant", "Постоянная"))
                ], def: "source").basic()
                    .help(L10n("No higher than keeps slower footage as it is and limits faster footage; Constant forces one rate, which some editors need.",
                               "«Не выше» сохраняет медленное видео и ограничивает быстрое; «Постоянная» задаёт одну частоту (нужно некоторым редакторам)."))
                    .aliases(["fps", "кадры", "framerate"]).oracle("fps.rate"),
                .picker(VideoKeys.fps, L10n("Frames per second", "Кадров в секунду"), fpsChoices.map { FieldOption($0, $0) }, def: "30").basic()
                    .visible(.ne(VideoKeys.fpsMode, "source")).oracle("fps.rate"),
                .picker(VideoKeys.fpsInterp, L10n("When adding frames", "При добавлении кадров"), [
                    FieldOption("drop", L10n("Repeat frames", "Повторять кадры")), FieldOption("blend", L10n("Blend", "Смешивать")),
                    FieldOption("motion", L10n("Motion interpolation (slow)", "Интерполяция движения (медленно)"), requires: ["ff.filter.minterpolate"])
                ], def: "drop").expert().visible(.eq(VideoKeys.fpsMode, "constant"))
                    .help(L10n("Motion looks smooth but is slow and can show artifacts.", "«Движение» даёт плавность, но медленно, возможны артефакты.")).oracle("fps.interp")
            ])
        ])
    }

    private static func cropField(_ key: String, _ label: L10n) -> OptionField {
        .number(key, label, min: 0, max: 8000, step: 2, def: 0, unit: "px").standard().visible(.eq(VideoKeys.cropMode, "custom")).oracle("crop.dimensions")
    }

    private static func padField(_ key: String, _ label: L10n) -> OptionField {
        .number(key, label, min: 0, max: 4000, step: 2, def: 0, unit: "px").expert().visible(.eq(VideoKeys.padMode, "border")).oracle("pad.pixels")
    }
}
