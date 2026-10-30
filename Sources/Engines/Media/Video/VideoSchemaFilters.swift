import Foundation

// Schema page "Filters" (spec/handbrake.md 2.5): clean-up, enhance, time, overlay. Fields that only exist in ffmpeg are disabled with the
// standard "Needs ffmpeg" hint when it is missing, never hidden.

extension VideoSchemas {
    static let ffOnly = ["tool.ffmpeg"]

    static func strengthOptions(off: Bool = true) -> [FieldOption] {
        [FieldOption("off", L10n("Off", "Выкл."))] + [FieldOption("light", L10n("Light", "Слабо")), FieldOption("medium", L10n("Medium", "Средне")), FieldOption("strong", L10n("Strong", "Сильно"))]
    }

    static func filtersPage() -> OptionPage {
        .make("filters", symbol: "wand.and.stars", L10n("Filters", "Фильтры"), [
            .make("cleanup", L10n("Clean-up", "Очистка"), visible: notAudioOnly, [
                .segmented(VideoKeys.deinterlace, L10n("Deinterlace", "Деинтерлейсинг"), [
                    FieldOption("off", L10n("Off", "Выкл.")), FieldOption("auto", L10n("Auto", "Авто")), FieldOption("on", L10n("On", "Вкл."))
                ], def: "auto").basic().needs(ffOnly)
                    .help(L10n("Auto checks the clip first and only fixes interlaced video.", "«Авто» сначала анализирует ролик и исправляет только чересстрочное видео."))
                    .aliases(["interlace", "comb", "деинтерлейс", "гребёнка"]).oracle("deint.idet"),
                .picker(VideoKeys.deintMethod, L10n("Method", "Метод"), [
                    FieldOption("bwdif", L10n("bwdif (best balance)", "bwdif (лучший баланс)"), requires: ["ff.filter.bwdif"]),
                    FieldOption("yadif", "yadif", requires: ["ff.filter.yadif"]),
                    FieldOption("w3fdif", L10n("w3fdif (smooth)", "w3fdif (плавный)"), requires: ["ff.filter.w3fdif"])
                ], def: "bwdif").standard().visible(.ne(VideoKeys.deinterlace, "off")).oracle("deint.method"),
                .segmented(VideoKeys.deintRate, L10n("Output rate", "Частота на выходе"), [
                    FieldOption("frame", L10n("One frame per frame", "Кадр на кадр")), FieldOption("field", L10n("One frame per field", "Кадр на поле"))
                ], def: "frame").standard().visible(.ne(VideoKeys.deinterlace, "off"))
                    .help(L10n("Per field doubles the frame rate for smoother motion.", "«Кадр на поле» удваивает частоту кадров - движение плавнее.")).oracle("deint.rate"),
                .picker(VideoKeys.ivtc, L10n("Remove 3:2 pulldown", "Убрать 3:2 pulldown"), [
                    FieldOption("off", L10n("Off", "Выкл.")), FieldOption("auto", L10n("Auto", "Авто"))
                ], def: "off").standard().needs(ffOnly, reason: nil)
                    .help(L10n("For film that was shown on TV at 30 fps.", "Для киноплёнки, показанной по ТВ с частотой 30 к/с.")).oracle("ivtc.argv"),
                .picker(VideoKeys.deblock, L10n("Deblock", "Удаление блочности"), [
                    FieldOption("off", L10n("Off", "Выкл.")), FieldOption("weak", L10n("Weak", "Слабо")), FieldOption("strong", L10n("Strong", "Сильно"))
                ], def: "off").standard().needs(ffOnly)
                    .help(L10n("Smooths blocky compression in poor sources.", "Сглаживает «квадраты» сжатия в плохих исходниках.")).oracle("deblock.argv"),
                .picker(VideoKeys.denoise, L10n("Noise reduction", "Шумоподавление"), strengthOptions(), def: "off").basic()
                    .help(L10n("Cleans grain and sensor noise. Stronger also softens detail and helps compression.", "Убирает зерно и шум сенсора. Сильнее - мягче детали, но лучше сжатие."))
                    .aliases(["denoise", "noise", "шум"]).oracle("denoise.noise"),
                .picker(VideoKeys.denoiseMethod, L10n("Method", "Метод"), [
                    FieldOption("hqdn3d", L10n("hqdn3d (fast)", "hqdn3d (быстрый)"), requires: ["ff.filter.hqdn3d"]),
                    FieldOption("nlmeans", L10n("nlmeans (best, slow)", "nlmeans (лучший, медленный)"), requires: ["ff.filter.nlmeans"]),
                    FieldOption("atadenoise", L10n("atadenoise (temporal)", "atadenoise (временной)"), requires: ["ff.filter.atadenoise"])
                ], def: "hqdn3d").standard().visible(.ne(VideoKeys.denoise, "off")).oracle("denoise.method"),
                .picker(VideoKeys.chromaSmooth, L10n("Chroma smoothing", "Сглаживание цветности"), strengthOptions(), def: "off").expert().needs(ffOnly)
                    .help(L10n("Reduces color blotches in low-quality sources.", "Уменьшает цветовые пятна в плохих исходниках.")).oracle("chroma.argv"),
                .toggle(VideoKeys.deband, L10n("Reduce banding in gradients", "Убрать полосы в градиентах")).expert().needs(ffOnly)
                    .help(L10n("Smooths the stripes that appear in skies and shadows of compressed video.", "Сглаживает полосы, которые появляются на небе и в тенях сжатого видео.")).oracle("deband.argv")
            ]),
            .make("enhance", L10n("Enhance", "Улучшение"), visible: notAudioOnly, [
                .picker(VideoKeys.sharpen, L10n("Sharpen", "Резкость"), strengthOptions(), def: "off").basic().aliases(["sharp", "резкость"]).oracle("sharpen.edges"),
                .picker(VideoKeys.sharpenMethod, L10n("Method", "Метод"), [
                    FieldOption("unsharp", L10n("Unsharp mask", "Нерезкая маска")), FieldOption("cas", L10n("CAS (adaptive)", "CAS (адаптивный)"), requires: ["ff.filter.cas"])
                ], def: "unsharp").expert().visible(.ne(VideoKeys.sharpen, "off"))
                    .help(L10n("CAS is adaptive and avoids halos.", "CAS адаптивный и не даёт ореолов.")).oracle("sharpen.method"),
                .toggle(VideoKeys.gray, L10n("Black and white", "Чёрно-белое")).standard().aliases(["grayscale", "монохром"]).oracle("gray.saturation"),
                .slider(VideoKeys.eqBrightness, L10n("Brightness", "Яркость"), min: -1, max: 1, step: 0.02, def: 0, decimals: 2).standard().oracle("eq.brightness"),
                .slider(VideoKeys.eqContrast, L10n("Contrast", "Контраст"), min: 0, max: 2, step: 0.02, def: 1, decimals: 2).standard().oracle("eq.contrast"),
                .slider(VideoKeys.eqSaturation, L10n("Saturation", "Насыщенность"), min: 0, max: 3, step: 0.02, def: 1, decimals: 2).standard().oracle("eq.saturation"),
                .slider(VideoKeys.eqGamma, L10n("Gamma", "Гамма"), min: 0.1, max: 3, step: 0.02, def: 1, decimals: 2).standard().oracle("eq.gamma"),
                .slider(VideoKeys.colorTemp, L10n("Color temperature", "Цветовая температура"), min: 2500, max: 10000, step: 100, def: 6500, unit: "K").expert()
                    .help(L10n("Lower is warmer (more orange), higher is colder (more blue). 6500 K leaves the picture as it is.", "Меньше - теплее (оранжевее), больше - холоднее (синее). 6500 K оставляет картинку как есть."))
                    .oracle("temp.argv")
            ]),
            .make("time", L10n("Time", "Время"), [
                .slider(VideoKeys.filterSpeed, L10n("Speed", "Скорость"), min: 0.25, max: 4, step: 0.05, def: 1, unit: "×", decimals: 2, logarithmic: true).standard()
                    .help(L10n("Audio keeps its pitch.", "Высота звука сохраняется.")).aliases(["speed", "slow motion", "ускорить", "замедлить"]).oracle("speed.duration"),
                .toggle(VideoKeys.reverse, L10n("Play backwards", "Воспроизвести задом наперёд")).expert().needs(ffOnly)
                    .help(L10n("Loads the whole clip into memory, so it is limited to 2 minutes.", "Весь ролик загружается в память, поэтому лимит - 2 минуты.")).oracle("reverse.frames"),
                .number(VideoKeys.fadeIn, L10n("Fade in", "Появление"), min: 0, max: 10, step: 0.5, def: 0, unit: "s", decimals: 1).standard().needs(ffOnly)
                    .help(L10n("Applies to picture and sound.", "Относится к картинке и звуку.")).oracle("fade.in"),
                .number(VideoKeys.fadeOut, L10n("Fade out", "Затухание"), min: 0, max: 10, step: 0.5, def: 0, unit: "s", decimals: 1).standard().needs(ffOnly).oracle("fade.out")
            ]),
            .make("overlay", L10n("Watermark", "Водяной знак"), level: .standard, collapsed: true, visible: notAudioOnly, [
                .picker(VideoKeys.wmMode, L10n("Watermark", "Водяной знак"), [
                    FieldOption("none", L10n("None", "Нет")), FieldOption("image", L10n("Image", "Изображение")), FieldOption("text", L10n("Text", "Текст"))
                ], def: "none").standard().needs(ffOnly).aliases(["logo", "watermark", "логотип"]).oracle("wm.region"),
                .file(VideoKeys.wmFile, L10n("Image", "Изображение"), types: [.png, .jpeg, .svg]).standard().visible(.eq(VideoKeys.wmMode, "image")).oracle("wm.region"),
                .text(VideoKeys.wmText, L10n("Text", "Текст"), placeholder: L10n("Your name or site", "Ваше имя или сайт")).standard().visible(.eq(VideoKeys.wmMode, "text")).oracle("wm.region"),
                .picker(VideoKeys.wmPos, L10n("Position", "Положение"), [
                    FieldOption("tl", L10n("Top left", "Сверху слева")), FieldOption("tr", L10n("Top right", "Сверху справа")), FieldOption("bl", L10n("Bottom left", "Снизу слева")),
                    FieldOption("br", L10n("Bottom right", "Снизу справа")), FieldOption("center", L10n("Center", "По центру"))
                ], def: "br").standard().visible(.ne(VideoKeys.wmMode, "none")).oracle("wm.pos"),
                .slider(VideoKeys.wmOpacity, L10n("Opacity", "Непрозрачность"), min: 0, max: 100, def: 70, unit: "%").standard().visible(.ne(VideoKeys.wmMode, "none")).oracle("wm.opacity"),
                .slider(VideoKeys.wmScale, L10n("Size (% of width)", "Размер (% ширины)"), min: 3, max: 60, def: 15, unit: "%").standard().visible(.ne(VideoKeys.wmMode, "none")).oracle("wm.scale"),
                .number(VideoKeys.wmMargin, L10n("Margin", "Отступ"), min: 0, max: 400, def: 24, unit: "px").expert().visible(.ne(VideoKeys.wmMode, "none"))
                    .help(L10n("Distance from the edge of the picture.", "Расстояние до края картинки.")).oracle("wm.margin"),
                .toggle(VideoKeys.stabilize, L10n("Basic stabilisation", "Базовая стабилизация")).expert().needs(ffOnly)
                    .help(L10n("Mild: this ffmpeg has no vidstab.", "Слабая: в этом ffmpeg нет vidstab.")).oracle("stab.argv")
            ])
        ])
    }
}
