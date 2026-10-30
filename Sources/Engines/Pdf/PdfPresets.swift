import Foundation

enum PdfPresets {
    private static let ruEn: OptionValue = .rows([["lang": "ru-RU"], ["lang": "en-US"]])

    /// spec/handbrake.md 4.5: "Small for e-mail", "Print quality", "Make searchable", "Pages as PNG 200 dpi" ...
    static let builtins: [Preset] = [
        .builtin("pdf.small", target: PdfTargets.optimize, L10n("Reduce size, standard", "Уменьшить размер, стандарт"),
                 notes: L10n("Keeps text sharp, recompresses images.", "Текст остаётся чётким, изображения пересжимаются."), symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize,
                 [PdfKeys.mode: "keepText", PdfKeys.level: "standard"]),
        .builtin("pdf.tiny", target: PdfTargets.optimize, L10n("Reduce size, screen", "Уменьшить размер, экран"),
                 notes: L10n("The smallest file that keeps the text.", "Самый маленький файл с сохранением текста."), symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize,
                 [PdfKeys.mode: "keepText", PdfKeys.level: "screen"]),
        .builtin("pdf.print", target: PdfTargets.optimize, L10n("Print quality", "Качество для печати"),
                 notes: L10n("Images are recompressed with a light touch.", "Изображения пересжимаются бережно."), symbol: "printer", group: .smallSize,
                 [PdfKeys.mode: "keepText", PdfKeys.level: "high"]),
        .builtin("pdf.scan.small", target: PdfTargets.optimize, L10n("Shrink a scan (searchable)", "Сжать скан (с поиском)"),
                 notes: L10n("Pages become 150 dpi pictures with an invisible text layer.", "Страницы становятся картинками 150 dpi с невидимым текстовым слоем."), symbol: "doc.viewfinder", group: .smallSize,
                 [PdfKeys.mode: "raster", PdfKeys.level: "custom", PdfKeys.imageDPI: 150, PdfKeys.imageQuality: 65, PdfKeys.ocr: true, PdfKeys.ocrLanguages: ruEn, PdfKeys.ocrSkipText: true]),
        .builtin("pdf.clean", target: PdfTargets.optimize, L10n("Remove document info", "Удалить сведения о документе"),
                 notes: L10n("Author, program, dates and keywords are removed before sharing.", "Автор, программа, даты и ключевые слова удаляются перед отправкой."), symbol: "eye.slash", group: .archive,
                 [PdfKeys.mode: "keepText", PdfKeys.level: "high", PdfKeys.stripMeta: true]),
        .builtin("pdf.ocr", target: PdfTargets.ocr, L10n("Make searchable (OCR ru + en)", "Сделать с поиском (OCR ru + en)"),
                 symbol: "text.viewfinder", group: .custom, [PdfKeys.ocrOutput: "searchablePdf", PdfKeys.ocrLanguages: ruEn]),
        .builtin("pdf.png", target: PdfTargets.images, L10n("Pages to PNG, 200 dpi", "Страницы в PNG, 200 dpi"), symbol: "photo", group: .lossless,
                 [PdfKeys.rasterFormat: "png", PdfKeys.rasterDPI: 200]),
        .builtin("pdf.jpg", target: PdfTargets.images, L10n("Pages to JPEG, 150 dpi", "Страницы в JPEG, 150 dpi"), symbol: "photo", group: .web,
                 [PdfKeys.rasterFormat: "jpeg", PdfKeys.rasterDPI: 150, PdfKeys.rasterQuality: 85]),
        .builtin("pdf.txt", target: PdfTargets.text, L10n("Extract text (UTF-8)", "Извлечь текст (UTF-8)"), symbol: "text.alignleft", group: .web,
                 [PdfKeys.textFormat: "txt", PdfKeys.textLayout: false, PdfKeys.textEncoding: "utf8"]),
        .builtin("pdf.merge", target: PdfTargets.merge, L10n("Merge, natural order", "Объединить по порядку"), symbol: "arrow.triangle.merge", group: .custom,
                 [PdfKeys.mergeOrder: "name", PdfKeys.mergeBookmarks: true]),
        .builtin("pdf.split", target: PdfTargets.split, L10n("Split into pages", "Разделить на страницы"), symbol: "rectangle.split.2x1", group: .custom,
                 [PdfKeys.splitMode: "eachPage"]),
        .builtin("pdf.protect", target: PdfTargets.protect, L10n("Password-protect (printing allowed)", "Защитить паролем (печать разрешена)"),
                 notes: L10n("You type the password when you run it; it is never stored.", "Пароль вводится при запуске и нигде не сохраняется."), symbol: "lock", group: .archive,
                 [PdfKeys.allowPrint: true, PdfKeys.allowCopy: false, PdfKeys.allowEdit: false]),
        .builtin("pdf.a4", target: PdfTargets.pages, L10n("Fit to A4", "Привести к A4"), symbol: "doc.plaintext", group: .devices,
                 [PdfKeys.rotate: "0", PdfKeys.pageSize: "a4", PdfKeys.pageSizeFit: "fit"])
    ]
}
