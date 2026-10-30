import Foundation

enum ImagePresets {
    private typealias K = ImageKeys

    /// Built-in presets (spec/handbrake.md 4.4) for the targets `image.convert` and `image.pdf`. Values are sparse over the schema defaults.
    static let builtins: [Preset] = [
        .builtin("img.web.jpeg", target: ImageSchemas.convertID, L10n("Web JPEG", "Веб JPEG"), notes: L10n("Progressive JPEG, 2048 px, sRGB, no location.", "Прогрессивный JPEG, 2048 px, sRGB, без геолокации."),
                 symbol: "globe", group: .web, [K.format: "jpeg", K.quality: 82, K.progressive: true, K.sizeMode: "longEdge", K.sizeLong: 2048, K.colorSpace: "srgb", K.mdMode: "noGPS"]),
        .builtin("img.web.webp", target: ImageSchemas.convertID, L10n("Web WebP", "Веб WebP"), notes: L10n("Needs cwebp. 2048 px, sRGB, no metadata.", "Нужен cwebp. 2048 px, sRGB, без метаданных."),
                 symbol: "globe", group: .web, [K.format: "webp", K.quality: 80, K.sizeMode: "longEdge", K.sizeLong: 2048, K.colorSpace: "srgb", K.mdMode: "strip"]),
        .builtin("img.web.avif", target: ImageSchemas.convertID, L10n("Web AVIF", "Веб AVIF"), notes: L10n("Very small files for modern browsers.", "Очень маленькие файлы для современных браузеров."),
                 symbol: "globe", group: .web, [K.format: "avif", K.quality: 60, K.sizeMode: "longEdge", K.sizeLong: 2048, K.colorSpace: "srgb", K.mdMode: "noGPS"]),
        .builtin("img.heic", target: ImageSchemas.convertID, L10n("HEIC, compact", "HEIC, компактно"), notes: L10n("Half the size of JPEG at the same look.", "Вдвое меньше JPEG при том же виде."),
                 symbol: "photo", group: .smallSize, [K.format: "heic", K.quality: 80]),
        .builtin("img.email", target: ImageSchemas.convertID, L10n("Email and chat (1600 px)", "Для почты и чатов (1600 px)"), notes: L10n("Small, no location.", "Небольшой файл, без геолокации."),
                 symbol: "envelope", group: .social, [K.format: "jpeg", K.quality: 75, K.sizeMode: "longEdge", K.sizeLong: 1600, K.colorSpace: "srgb", K.mdMode: "strip"]),
        .builtin("img.upload1mb", target: ImageSchemas.convertID, L10n("Under 1 MB", "Меньше 1 МБ"), notes: L10n("Finds the best quality that fits one megabyte.", "Подбирает лучшее качество, которое укладывается в мегабайт."),
                 symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize, [K.format: "jpeg", K.targetKB: 1024, K.colorSpace: "srgb", K.mdMode: "strip"]),
        .builtin("img.thumb", target: ImageSchemas.convertID, L10n("Thumbnail 256", "Миниатюра 256"), symbol: "square.grid.3x3", group: .smallSize,
                 [K.format: "jpeg", K.quality: 80, K.sizeMode: "fit", K.sizeWidth: 256, K.sizeHeight: 256, K.mdMode: "strip"]),
        .builtin("img.png", target: ImageSchemas.convertID, L10n("PNG, lossless", "PNG без потерь"), symbol: "checkmark.seal", group: .lossless, [K.format: "png"]),
        .builtin("img.print", target: ImageSchemas.convertID, L10n("Print TIFF 300 dpi", "TIFF для печати 300 dpi"), notes: L10n("Lossless LZW, keeps the color profile.", "LZW без потерь, цветовой профиль сохраняется."),
                 symbol: "printer", group: .archive, [K.format: "tiff", K.tiffCompression: "lzw", K.dpi: "300", K.mdMode: "keep"]),
        .builtin("img.square", target: ImageSchemas.convertID, L10n("Square 1080", "Квадрат 1080"), notes: L10n("Crops around the main subject.", "Обрезает вокруг главного объекта."),
                 symbol: "square", group: .social, [K.format: "jpeg", K.quality: 85, K.cropMode: "ratio", K.cropRatio: "1:1", K.cropAnchor: "subject", K.sizeMode: "longEdge", K.sizeLong: 1080,
                                                    K.colorSpace: "srgb", K.mdMode: "noGPS"]),
        .builtin("img.story", target: ImageSchemas.convertID, L10n("Story 1080 x 1920", "Сторис 1080 x 1920"), notes: L10n("Vertical 9:16 around the main subject.", "Вертикальный кадр 9:16 вокруг главного объекта."),
                 symbol: "rectangle.portrait", group: .social, [K.format: "jpeg", K.quality: 85, K.cropMode: "ratio", K.cropRatio: "9:16", K.cropAnchor: "subject", K.sizeMode: "longEdge", K.sizeLong: 1920,
                                                               K.colorSpace: "srgb", K.mdMode: "noGPS"]),
        .builtin("img.favicon", target: ImageSchemas.convertID, L10n("Favicon (ICO 16 / 32 / 48)", "Фавикон (ICO 16 / 32 / 48)"), symbol: "app", group: .web,
                 [K.format: "ico", K.icoSizes: "48,32,16", K.cropMode: "ratio", K.cropRatio: "1:1"]),
        .builtin("img.icns", target: ImageSchemas.convertID, L10n("App icon (ICNS)", "Значок приложения (ICNS)"), notes: L10n("Best from a square picture of 1024 px or more.", "Лучше всего из квадратной картинки от 1024 px."),
                 symbol: "app.badge", group: .devices, [K.format: "icns", K.cropMode: "ratio", K.cropRatio: "1:1"]),
        .builtin("img.screenshot", target: ImageSchemas.convertID, L10n("Screenshot, compact (HEIC)", "Скриншот, компактно (HEIC)"), symbol: "camera.viewfinder", group: .smallSize,
                 [K.format: "heic", K.quality: 85, K.mdMode: "strip"]),
        .builtin("img.bw", target: ImageSchemas.convertID, L10n("Black and white", "Чёрно-белое"), symbol: "circle.lefthalf.filled", group: .custom,
                 [K.format: "jpeg", K.quality: 88, K.gray: true]),
        .builtin("img.private", target: ImageSchemas.convertID, L10n("Share-safe (no metadata)", "Безопасно для отправки (без метаданных)"),
                 notes: L10n("Same format and look; location, camera and dates are removed.", "Тот же формат и вид; геолокация, камера и даты удаляются."),
                 symbol: "eraser", group: .social, [K.format: "same", K.mdMode: "strip"]),
        .builtin("img.pdf.a4", target: ImageSchemas.pdfID, L10n("Images to PDF (A4)", "Изображения в PDF (A4)"), symbol: "doc.richtext", group: .archive,
                 [K.pdfPageSize: "a4", K.pdfFit: "contain", K.pdfMargin: 10, K.pdfOrientation: "auto", K.quality: 85]),
        .builtin("img.pdf.photos", target: ImageSchemas.pdfID, L10n("Photo album PDF", "PDF-альбом из фото"), notes: L10n("One picture per page, same size as the picture.", "Одна картинка на странице, размер как у картинки."),
                 symbol: "doc.richtext", group: .archive, [K.pdfPageSize: "image", K.quality: 90])
    ]
}
