import Foundation

/// Schema builders for the image family (spec/handbrake.md 3.1): `image.convert` (Format, Size and crop, Colour, Metadata) and
/// `image.pdf` (images to one PDF). Every field has an oracle id; defaults equal the quick recipes of `ImageQuick`.
/// Both builders work for an empty `items` array and never read the file system.
enum ImageSchemas {
    static let convertID = "image.convert"
    static let pdfID = "image.pdf"

    private typealias K = ImageKeys

    private static func oneOf(_ key: String, _ values: String...) -> OptionExpr { .in(key, values.map { .string($0) }) }

    // MARK: image.convert

    static func convert(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: convertID, title: L10n("Image", "Изображение"), symbol: "photo", pages: [formatPage, sizePage, colourPage, metadataPage], rules: convertRules)
    }

    private static let lossyFormats = oneOf(K.format, "same", "jpeg", "heic", "avif", "webp", "jp2", "pdf")
    private static let sizeTargetFormats = oneOf(K.format, "same", "jpeg", "heic", "avif", "webp")
    private static let losslessWebP: OptionExpr = .all([.eq(K.format, "webp"), .isSet(K.lossless)])

    private static var formatPage: OptionPage {
        OptionPage.make("format", symbol: "photo", L10n("Format", "Формат"), [
            OptionGroup.make("format.main", [
                .picker(K.format, L10n("Format", "Формат"), [
                    FieldOption("same", L10n("Same as source", "Как у исходника")),
                    FieldOption("jpeg", "JPEG"),
                    FieldOption("png", "PNG"),
                    FieldOption("heic", "HEIC", requires: ["native.imageio.write.heic"]),
                    FieldOption("avif", "AVIF", requires: ["native.imageio.write.avif"]),
                    FieldOption("webp", "WebP", requires: ["tool.cwebp"], hint: Tool.cwebp.installHint),
                    FieldOption("tiff", "TIFF"),
                    FieldOption("gif", "GIF"),
                    FieldOption("bmp", "BMP"),
                    FieldOption("jp2", "JPEG 2000", requires: ["native.imageio.write.jp2"]),
                    FieldOption("tga", "TGA", requires: ["native.imageio.write.tga"]),
                    FieldOption("ico", L10n("ICO (Windows icon)", "ICO (значок Windows)"), requires: ["native.imageio.write.ico"]),
                    FieldOption("icns", L10n("ICNS (macOS icon)", "ICNS (значок macOS)"), requires: ["tool.iconutil"]),
                    FieldOption("pdf", L10n("PDF (one page)", "PDF (одна страница)"))
                ], def: "jpeg")
                    .basic().affects([.estimate, .preview, .plan])
                    .help(L10n("JPEG for photos, PNG for graphics and screenshots, HEIC / AVIF / WebP for the smallest files.",
                               "JPEG для фото, PNG для графики и скриншотов, HEIC / AVIF / WebP дают самые компактные файлы."))
                    .aliases(["format", "формат", "jpg", "convert"]).oracle("image.format.type"),
                .slider(K.quality, L10n("Quality", "Качество"), min: 1, max: 100, def: 90,
                        minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество"))
                    .basic().visible(.all([lossyFormats, .not(losslessWebP)])).affects([.estimate, .preview])
                    .help(L10n("Higher is sharper and larger. 80 to 90 is practically indistinguishable from the original for photos. In a PDF, 100 stores the picture without any loss.",
                               "Больше значит чётче и крупнее. 80-90 для фото практически неотличимо от оригинала. В PDF значение 100 сохраняет картинку без потерь."))
                    .aliases(["quality", "качество", "compression", "сжатие"]).oracle("image.quality.bytes"),
                .number(K.targetKB, L10n("Fit to file size", "Уложиться в размер"), min: 0, max: 1_000_000, def: 0, unit: "KB")
                    .standard().visible(.all([sizeTargetFormats, .not(losslessWebP)])).affects([.estimate, .preview])
                    .help(L10n("Finds the quality that fits the limit, and shrinks the picture if quality alone is not enough. 0 means off.",
                               "Подбирает качество под ограничение, а если его мало, уменьшает картинку. 0 - выключено."))
                    .aliases(["size limit", "kb", "мб", "ограничение размера", "upload"]).oracle("image.targetKB.size"),
                .toggle(K.lossless, L10n("Lossless", "Без потерь"))
                    .standard().visible(.eq(K.format, "webp")).needs(["tool.cwebp"], reason: Tool.cwebp.installHint)
                    .help(L10n("Exact pixels, bigger file.", "Точные пиксели, файл больше."))
                    .oracle("image.lossless.webp")
            ]),
            OptionGroup.make("format.jpeg", L10n("JPEG", "JPEG"), level: .standard, visible: oneOf(K.format, "jpeg", "same"), [
                .toggle(K.progressive, L10n("Progressive JPEG", "Прогрессивный JPEG"))
                    .standard().enabled(.ne(K.subsampling, "444"), reason: L10n("Not available with full color detail (4:4:4).", "Недоступно при полной цветовой детализации (4:4:4)."))
                    .help(L10n("Loads blurry first, then sharp: nicer on the web.", "На сайтах сначала загружается размытым, потом чётким."))
                    .oracle("image.jpeg.sof2"),
                .picker(K.subsampling, L10n("Color detail", "Цветовая детализация"), [
                    FieldOption("420", L10n("Standard (4:2:0)", "Стандартная (4:2:0)")),
                    FieldOption("444", L10n("Full (4:4:4)", "Полная (4:4:4)"), requires: ["tool.ffmpeg"], hint: Tool.ffmpeg.installHint)
                ], def: "420")
                    .expert().help(L10n("4:4:4 keeps sharp colored edges (text, logos). It needs ffmpeg and makes bigger files.",
                                        "4:4:4 сохраняет чёткие цветные края (текст, логотипы). Нужен ffmpeg, файлы получаются больше."))
                    .oracle("image.jpeg.sampling")
            ]),
            OptionGroup.make("format.png", L10n("PNG", "PNG"), level: .standard, visible: oneOf(K.format, "png", "same"), [
                .toggle(K.pngInterlace, L10n("Interlaced PNG", "Чересстрочный PNG")).expert().oracle("image.png.interlace"),
                .toggle(K.pngPalette, L10n("Reduce to 256 colors", "Палитра из 256 цветов"))
                    .standard().help(L10n("Much smaller for flat graphics and screenshots. Pictures with transparency stay full color.",
                                          "Заметно меньше для плоской графики и скриншотов. Картинки с прозрачностью остаются полноцветными."))
                    .oracle("image.png.palette")
            ]),
            OptionGroup.make("format.tiff", L10n("TIFF", "TIFF"), level: .standard, visible: oneOf(K.format, "tiff", "same"), [
                .picker(K.tiffCompression, L10n("Compression", "Сжатие"), [
                    FieldOption("none", L10n("None", "Без сжатия")),
                    FieldOption("lzw", "LZW"),
                    FieldOption("deflate", "Deflate (ZIP)"),
                    FieldOption("packbits", "PackBits")
                ], def: "lzw").standard().help(L10n("All of them are lossless.", "Все варианты без потерь.")).oracle("image.tiff.compression")
            ]),
            OptionGroup.make("format.ico", L10n("Icon", "Значок"), level: .standard, visible: oneOf(K.format, "ico", "same"), [
                .text(K.icoSizes, L10n("Icon sizes (px)", "Размеры значка (px)"), def: "256,128,64,48,32,16", validation: .integerList)
                    .standard().help(L10n("Whole numbers up to 256, separated by commas. The picture is fitted into each square.",
                                          "Целые числа до 256 через запятую. Картинка вписывается в каждый квадрат."))
                    .oracle("image.ico.sizes")
            ]),
            OptionGroup.make("format.alpha", L10n("Transparency", "Прозрачность"), level: .standard, visible: oneOf(K.format, "jpeg", "bmp", "pdf", "same"), [
                .color(K.alphaBackground, L10n("Background for transparency", "Фон под прозрачность"), def: "#FFFFFF")
                    .standard().help(L10n("This format has no transparency, so transparent areas are filled with this color.",
                                          "В этом формате нет прозрачности, поэтому прозрачные места заливаются этим цветом."))
                    .affects([.preview]).oracle("image.alpha.pixel")
            ])
        ])
    }

    private static var sizePage: OptionPage {
        let geometry: OptionAffects = [.estimate, .preview]
        return OptionPage.make("size", symbol: "arrow.up.left.and.arrow.down.right", L10n("Size and crop", "Размер и обрезка"), [
            OptionGroup.make("size.size", L10n("Size", "Размер"), [
                .picker(K.sizeMode, L10n("Size", "Размер"), [
                    FieldOption("original", L10n("Original size", "Исходный размер")),
                    FieldOption("longEdge", L10n("Longest side", "Длинная сторона")),
                    FieldOption("fit", L10n("Fit inside a frame", "Вписать в рамку")),
                    FieldOption("exact", L10n("Exact size (stretch)", "Точный размер (растянуть)")),
                    FieldOption("fill", L10n("Fill a frame and crop", "Заполнить рамку и обрезать")),
                    FieldOption("percent", L10n("Percent", "Процент")),
                    FieldOption("megapixels", L10n("Megapixels", "Мегапиксели"))
                ], def: "original").basic().affects(geometry)
                    .help(L10n("Longest side keeps the proportions; Fill crops to an exact frame.",
                               "«Длинная сторона» сохраняет пропорции, «Заполнить» обрезает под точный кадр."))
                    .aliases(["resize", "scale", "размер", "уменьшить"]).oracle("image.size.pixels"),
                .number(K.sizeLong, L10n("Longest side", "Длинная сторона"), min: 16, max: 32768, def: 2048, unit: "px")
                    .basic().visible(.eq(K.sizeMode, "longEdge")).affects(geometry).oracle("image.size.long"),
                .number(K.sizeWidth, L10n("Width", "Ширина"), min: 0, max: 32768, def: 1080, unit: "px")
                    .basic().visible(oneOf(K.sizeMode, "fit", "exact", "fill")).affects(geometry)
                    .help(L10n("0 leaves this side free.", "0 оставляет сторону свободной.")).oracle("image.size.frame"),
                .number(K.sizeHeight, L10n("Height", "Высота"), min: 0, max: 32768, def: 1080, unit: "px")
                    .basic().visible(oneOf(K.sizeMode, "fit", "exact", "fill")).affects(geometry)
                    .help(L10n("0 leaves this side free.", "0 оставляет сторону свободной.")).oracle("image.size.frame"),
                .slider(K.sizePercent, L10n("Scale", "Масштаб"), min: 5, max: 200, def: 50, unit: "%")
                    .basic().visible(.eq(K.sizeMode, "percent")).affects(geometry).oracle("image.size.percent"),
                .number(K.sizeMegapixels, L10n("Megapixels", "Мегапиксели"), min: 0.1, max: 200, step: 0.1, def: 4, unit: "MP", decimals: 1)
                    .standard().visible(.eq(K.sizeMode, "megapixels")).affects(geometry).oracle("image.size.megapixels"),
                .toggle(K.upscale, L10n("Allow enlarging", "Разрешить увеличение"))
                    .standard().visible(oneOf(K.sizeMode, "longEdge", "fit", "megapixels")).affects(geometry)
                    .help(L10n("Off: smaller pictures are left as they are.", "Выключено: маленькие картинки остаются как есть.")).oracle("image.size.upscale"),
                .picker(K.dpi, L10n("Print resolution", "Разрешение печати"), [
                    FieldOption("keep", L10n("Keep", "Не менять")),
                    FieldOption("72", "72"), FieldOption("96", "96"), FieldOption("144", "144"), FieldOption("150", "150"),
                    FieldOption("200", "200"), FieldOption("300", "300"), FieldOption("600", "600")
                ], def: "keep").standard().affects([])
                    .help(L10n("DPI changes the tag (and the page size of a PDF), not the pixels.", "DPI меняет метку (и размер страницы PDF), а не пиксели."))
                    .aliases(["dpi", "print", "печать"]).oracle("image.dpi.tag")
            ]),
            OptionGroup.make("size.orient", L10n("Orientation", "Ориентация"), [
                .toggle(K.autoOrient, L10n("Apply camera rotation", "Применить поворот камеры"), def: true)
                    .standard().affects(geometry)
                    .help(L10n("Bakes the rotation stored by the camera into the pixels.", "Вшивает поворот, записанный камерой, в пиксели."))
                    .oracle("image.orient.bake"),
                .segmented(K.rotate, L10n("Rotate", "Повернуть"), [
                    FieldOption("0", "0°"), FieldOption("90", "90°"), FieldOption("180", "180°"), FieldOption("270", "270°")
                ], def: "0").basic().affects(geometry).help(L10n("Clockwise.", "По часовой стрелке.")).aliases(["rotate", "поворот"]).oracle("image.rotate.quadrants"),
                .toggle(K.flipH, L10n("Mirror horizontally", "Отразить по горизонтали")).standard().affects(geometry).aliases(["mirror", "flip", "зеркало"]).oracle("image.flip.quadrants"),
                .toggle(K.flipV, L10n("Mirror vertically", "Отразить по вертикали")).standard().affects(geometry).oracle("image.flip.quadrants")
            ]),
            OptionGroup.make("size.crop", L10n("Crop", "Обрезка"), [
                .picker(K.cropMode, L10n("Crop", "Обрезка"), [
                    FieldOption("none", L10n("None", "Нет")),
                    FieldOption("ratio", L10n("Aspect ratio", "Соотношение сторон")),
                    FieldOption("autoTrim", L10n("Trim uniform borders", "Убрать однотонные поля")),
                    FieldOption("rect", L10n("Rectangle", "Прямоугольник"))
                ], def: "none").basic().affects(geometry).aliases(["crop", "square", "обрезка", "квадрат"]).oracle("image.crop.pixels"),
                .picker(K.cropRatio, L10n("Aspect ratio", "Соотношение сторон"),
                        ["1:1", "4:3", "3:2", "16:9", "9:16", "4:5", "5:4", "2:3", "3:4", "2:1", "1:2", "21:9"].map { FieldOption($0, $0) }, def: "1:1")
                    .basic().visible(.eq(K.cropMode, "ratio")).affects(geometry).oracle("image.crop.ratio"),
                .picker(K.cropAnchor, L10n("Keep", "Что оставить"), [
                    FieldOption("center", L10n("Center", "Центр")),
                    FieldOption("top", L10n("Top", "Верх")),
                    FieldOption("bottom", L10n("Bottom", "Низ")),
                    FieldOption("left", L10n("Left", "Лево")),
                    FieldOption("right", L10n("Right", "Право")),
                    FieldOption("subject", L10n("Main subject", "Главный объект"))
                ], def: "center").standard().visible(.eq(K.cropMode, "ratio")).affects(geometry)
                    .help(L10n("Main subject looks for the most eye-catching area on this Mac.", "«Главный объект» ищет самое заметное место на этом Mac."))
                    .oracle("image.crop.anchor"),
                .number(K.cropTrim, L10n("Tolerance", "Допуск"), min: 0, max: 50, def: 8, unit: "%")
                    .standard().visible(.eq(K.cropMode, "autoTrim")).affects(geometry).oracle("image.crop.trim"),
                .number(K.cropX, L10n("Left", "Слева"), min: 0, max: 100_000, def: 0, unit: "px").standard().visible(.eq(K.cropMode, "rect")).affects(geometry).oracle("image.crop.rect"),
                .number(K.cropY, L10n("Top", "Сверху"), min: 0, max: 100_000, def: 0, unit: "px").standard().visible(.eq(K.cropMode, "rect")).affects(geometry).oracle("image.crop.rect"),
                .number(K.cropW, L10n("Width", "Ширина"), min: 0, max: 100_000, def: 0, unit: "px").standard().visible(.eq(K.cropMode, "rect")).affects(geometry)
                    .help(L10n("0 means up to the right edge.", "0 - до правого края.")).oracle("image.crop.rect"),
                .number(K.cropH, L10n("Height", "Высота"), min: 0, max: 100_000, def: 0, unit: "px").standard().visible(.eq(K.cropMode, "rect")).affects(geometry)
                    .help(L10n("0 means down to the bottom edge.", "0 - до нижнего края.")).oracle("image.crop.rect")
            ])
        ])
    }

    private static var colourPage: OptionPage {
        OptionPage.make("colour", symbol: "paintpalette", L10n("Color", "Цвет"), [
            OptionGroup.make("colour.main", [
                .picker(K.colorSpace, L10n("Color space", "Цветовое пространство"), [
                    FieldOption("keep", L10n("Keep the original", "Оставить исходное")),
                    FieldOption("srgb", "sRGB"),
                    FieldOption("p3", "Display P3"),
                    FieldOption("adobe", "Adobe RGB"),
                    FieldOption("gray", L10n("Grayscale", "Оттенки серого"))
                ], def: "keep").standard().affects([.estimate, .preview])
                    .help(L10n("sRGB looks right everywhere. Wide-gamut photos keep their profile unless you change it here.",
                               "sRGB выглядит правильно везде. Фото с широким охватом сохраняют свой профиль, пока вы не смените его здесь."))
                    .aliases(["icc", "profile", "профиль", "srgb"]).oracle("image.cs.profile"),
                .toggle(K.gray, L10n("Black and white", "Чёрно-белое")).standard().affects([.estimate, .preview])
                    .help(L10n("Rec. 709 luminance.", "Яркость по Rec. 709.")).aliases(["grayscale", "bw", "ч/б"]).oracle("image.gray.pixels")
            ])
        ])
    }

    private static var metadataPage: OptionPage {
        OptionPage.make("metadata", symbol: "tag", L10n("Metadata", "Метаданные"), [
            OptionGroup.make("metadata.main", [
                .picker(K.mdMode, L10n("Metadata", "Метаданные"), [
                    FieldOption("keep", L10n("Keep everything", "Оставить всё")),
                    FieldOption("noGPS", L10n("Remove location", "Убрать геолокацию")),
                    FieldOption("strip", L10n("Remove all", "Убрать всё"))
                ], def: "keep").basic().affects([.estimate])
                    .help(L10n("Camera, date and location tags. The color profile always stays, so colors do not shift.",
                               "Теги камеры, даты и места съёмки. Цветовой профиль остаётся всегда, цвета не сдвигаются."))
                    .aliases(["exif", "gps", "privacy", "location", "приватность", "геолокация"]).oracle("image.md.exif"),
                .picker(K.frames, L10n("Several frames", "Несколько кадров"), [
                    FieldOption("first", L10n("First frame only", "Только первый кадр")),
                    FieldOption("all", L10n("Every frame as a file", "Каждый кадр отдельным файлом")),
                    FieldOption("animated", L10n("Keep the animation (GIF)", "Сохранить анимацию (GIF)"))
                ], def: "first").standard().visible(.source("image.frames", .gt, 1)).affects([.estimate, .plan])
                    .help(L10n("For animated GIF / WebP / multi-page TIFF sources.", "Для анимированных GIF / WebP и многостраничных TIFF."))
                    .aliases(["gif", "animation", "анимация"]).oracle("image.frames.count")
            ])
        ])
    }

    private static var convertRules: [ValidationRule] {
        [
            .info("image.rule.alphaLost", when: .all([oneOf(K.format, "jpeg", "bmp", "pdf"), .source("image.alpha", .eq, true)]),
                  L10n("The picture has transparency; the background color fills it.", "В картинке есть прозрачность, её заменит цвет фона."), field: K.alphaBackground),
            .info("image.rule.animation", when: .all([.source("image.frames", .gt, 1), .eq(K.frames, "first")]),
                  L10n("This file has several frames; only the first one is used.", "В файле несколько кадров, используется только первый."), field: K.frames),
            .warning("image.rule.cropRect", when: .all([.eq(K.cropMode, "rect"), .lte(K.cropW, 0), .lte(K.cropH, 0), .lte(K.cropX, 0), .lte(K.cropY, 0)]),
                     L10n("The rectangle covers the whole picture, nothing is cropped.", "Прямоугольник занимает всю картинку, обрезки нет."), field: K.cropMode)
        ]
    }

    // MARK: image.pdf

    /// "Images to PDF": order, page size, orientation, fit, margins, JPEG quality. Output `{first page}.pdf`.
    static func mergePDF(items: [FileItem]) -> OptionSchema {
        let fixedPage: OptionExpr = .ne(K.pdfPageSize, "image")
        return OptionSchema(id: pdfID, title: L10n("Images to PDF", "Изображения в PDF"), symbol: "doc.richtext", pages: [
            OptionPage.make("pages", symbol: "doc.richtext", L10n("Pages", "Страницы"), [
                OptionGroup.make("pages.order", [
                    .picker(K.pdfOrder, L10n("Page order", "Порядок страниц"), [
                        FieldOption("natural", L10n("By name (1, 2, 10)", "По имени (1, 2, 10)")),
                        FieldOption("name", L10n("By name, as text", "По имени, как текст")),
                        FieldOption("date", L10n("By date modified", "По дате изменения")),
                        FieldOption("selection", L10n("As selected", "Как выбрано"))
                    ], def: "natural").basic().affects([.plan])
                        .help(L10n("The PDF is named after the first page.", "PDF называется по первой странице.")).oracle("imgpdf.order.pages"),
                    .picker(K.pdfPageSize, L10n("Page size", "Размер страницы"), [
                        FieldOption("image", L10n("Same as the picture", "По размеру картинки")),
                        FieldOption("a4", "A4"), FieldOption("a5", "A5"), FieldOption("a3", "A3"), FieldOption("letter", "Letter")
                    ], def: "image").basic().affects([.estimate, .plan]).aliases(["a4", "letter", "paper", "бумага"]).oracle("imgpdf.mediabox"),
                    .picker(K.dpi, L10n("Picture resolution", "Разрешение картинки"), [
                        FieldOption("keep", L10n("Keep", "Не менять")),
                        FieldOption("72", "72"), FieldOption("96", "96"), FieldOption("150", "150"), FieldOption("300", "300")
                    ], def: "keep").standard().visible(.eq(K.pdfPageSize, "image")).affects([.plan])
                        .help(L10n("The page equals the picture at this resolution: 300 dpi makes a 12 MP photo a small page.",
                                   "Страница равна картинке при этом разрешении: при 300 dpi фото в 12 Мпикс. - небольшая страница.")).oracle("imgpdf.mediabox.dpi"),
                    .picker(K.pdfOrientation, L10n("Page orientation", "Ориентация страницы"), [
                        FieldOption("auto", L10n("Follow each picture", "По картинке")),
                        FieldOption("portrait", L10n("Portrait", "Книжная")),
                        FieldOption("landscape", L10n("Landscape", "Альбомная"))
                    ], def: "auto").standard().visible(fixedPage).affects([.plan]).oracle("imgpdf.orientation"),
                    .picker(K.pdfFit, L10n("Picture on the page", "Картинка на странице"), [
                        FieldOption("contain", L10n("Fit inside", "Вписать")),
                        FieldOption("cover", L10n("Fill and crop", "Заполнить и обрезать"))
                    ], def: "contain").standard().visible(fixedPage).affects([.plan]).oracle("imgpdf.fit"),
                    .slider(K.pdfMargin, L10n("Margin", "Поля"), min: 0, max: 50, def: 10, unit: "mm")
                        .standard().visible(fixedPage).affects([.plan]).oracle("imgpdf.margin")
                ]),
                OptionGroup.make("pages.quality", L10n("Pictures", "Картинки"), [
                    .slider(K.quality, L10n("JPEG quality", "Качество JPEG"), min: 1, max: 100, def: 90,
                            minLabel: L10n("Smaller PDF", "Меньше PDF"), maxLabel: L10n("Better quality", "Лучше качество"))
                        .basic().affects([.estimate])
                        .help(L10n("Pictures are stored as JPEG at this quality. 100 stores them without any loss (bigger file).",
                                   "Картинки сохраняются как JPEG с этим качеством. 100 сохраняет их без потерь (файл больше)."))
                        .oracle("imgpdf.quality.bytes"),
                    .color(K.alphaBackground, L10n("Background for transparency", "Фон под прозрачность"), def: "#FFFFFF")
                        .standard().oracle("imgpdf.alpha.pixel")
                ])
            ])
        ])
    }
}
