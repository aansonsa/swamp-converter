import Foundation

// Option schemas of the PDF targets (spec/handbrake.md 3.3). Every field has an oracle id: the self-test that reads the output back and proves the effect
// (see PdfTests.oracles). Schemas are built when asked (Studio, quick sheet), never at launch; the language pickers use a static list so Vision is not loaded for it.

extension OcrService {
    /// "Russian (Russia)" in both languages, for pickers that must not depend on the live UI language.
    static func displayL10n(_ id: String) -> L10n {
        func name(_ lang: String) -> String {
            let n = Locale(identifier: lang).localizedString(forIdentifier: id) ?? id
            return n.prefix(1).uppercased() + n.dropFirst()
        }
        return L10n(name("en"), name("ru"))
    }
}

enum PdfSchemas {
    // MARK: Shared fields

    static func pageRangeField(_ key: String = PdfKeys.pages, label: L10n = L10n("Pages", "Страницы"), def: String = "all",
                               help: L10n = L10n("All pages, or a range such as 1-3, 5, 8-.", "Все страницы или диапазон, например 1-3, 5, 8-."),
                               oracle: String = "pdf.pages.range") -> OptionField {
        .text(key, label, def: def, placeholder: L10n("all, or 1-3, 5, 8-", "все или 1-3, 5, 8-"), validation: .pageRange)
            .basic().help(help).oracle(oracle).aliases(["range", "диапазон", "pages", "страницы"])
    }

    static func stripMetaField() -> OptionField {
        .toggle(PdfKeys.stripMeta, L10n("Remove document info", "Удалить сведения о документе"))
            .help(L10n("Removes author, creator, producer, dates, keywords and the XMP packet.", "Удаляет автора, программу, даты, ключевые слова и пакет XMP."))
            .oracle("pdf.meta.strip").affects([]).aliases(["privacy", "метаданные", "metadata", "author"])
    }

    static var languageOptions: [FieldOption] {
        OcrService.knownLanguageCodes.map { FieldOption($0, OcrService.displayL10n($0), requires: ["native.vision.lang.\($0)"]) }
    }

    /// The four recognition fields (languages, automatic detection, resolution) shared by OCR, optimise, text and export.
    static func recognitionFields(visible: OptionExpr? = nil, includeSkipText: Bool = false) -> [OptionField] {
        let track = TrackSpec(columns: [.picker("lang", L10n("Language", "Язык"), languageOptions, def: "en-US")], maxRows: 6, rowTitleKey: "lang",
                              addTitle: L10n("Add Language", "Добавить язык"), allowReorder: true)
        var fields: [OptionField] = [
            .tracks(PdfKeys.ocrLanguages, L10n("Languages", "Языки"), track, defaultRows: { _ in OcrService.defaultLanguages().map { ["lang": .string($0)] } })
                .basic().help(L10n("The first language is tried first. macOS cannot read Latvian, Lithuanian or Estonian: Latvian text loses its diacritics.",
                                   "Первый язык проверяется первым. macOS не читает латышский, литовский и эстонский: у латышского текста пропадают диакритические знаки."))
                .oracle("pdf.ocr.langs").aliases(["ocr", "язык", "latvian", "russian"]),
            .toggle(PdfKeys.ocrAuto, L10n("Detect the language automatically", "Определять язык автоматически"), def: true)
                .help(L10n("Vision picks the language of each line itself; the list above stays as a hint.", "Vision сам определяет язык каждой строки; список выше остаётся подсказкой."))
                .oracle("pdf.ocr.auto").expert().affects([.plan]),
            .slider(PdfKeys.ocrDPI, L10n("Scan resolution", "Разрешение распознавания"), min: 150, max: 400, step: 50, def: 300, unit: "dpi")
                .help(L10n("Pages are drawn at this resolution before recognition. Higher is slower and reads small print better.",
                           "Перед распознаванием страницы рисуются с этим разрешением. Больше значит медленнее, но мелкий шрифт читается лучше."))
                .oracle("pdf.ocr.dpi").expert().affects([.estimate])
        ]
        if includeSkipText {
            fields.insert(.toggle(PdfKeys.ocrSkipText, L10n("Keep pages that already have text", "Не трогать страницы с готовым текстом"), def: true)
                .help(L10n("Pages whose text is already selectable are copied as they are and not recognized again.",
                           "Страницы с готовым выделяемым текстом копируются как есть и не распознаются заново."))
                .oracle("pdf.ocr.skipText").standard().affects([.plan]), at: 2)
        }
        if let visible { fields = fields.map { $0.visible(visible) } }
        return fields
    }

    // MARK: Images

    static func images(items: [FileItem]) -> OptionSchema {
        let fmt = [FieldOption("png", "PNG"), FieldOption("jpeg", "JPEG"), FieldOption("heic", "HEIC"), FieldOption("tiff", "TIFF")]
        return OptionSchema(id: PdfTargets.images, title: L10n("PDF to images", "PDF в изображения"), symbol: "photo", pages: [
            .make("image", symbol: "photo", L10n("Images", "Изображения"), [
                .make("format", L10n("Format", "Формат"), [
                    .picker(PdfKeys.rasterFormat, L10n("Image format", "Формат изображений"), fmt, def: "png").basic().oracle("pdf.raster.format"),
                    .slider(PdfKeys.rasterDPI, L10n("Resolution", "Разрешение"), min: 36, max: 1200, step: 1, def: 200, unit: "dpi",
                            minLabel: L10n("Smaller", "Меньше"), maxLabel: L10n("Sharper", "Чётче")).basic()
                        .help(L10n("Pixels per inch of the page. 300 suits printing; 150 suits the screen.", "Пикселей на дюйм страницы. 300 подходит для печати, 150 для экрана."))
                        .oracle("pdf.raster.dpi").affects([.estimate, .preview]),
                    .slider(PdfKeys.rasterQuality, L10n("Quality", "Качество"), min: 1, max: 100, step: 1, def: 85, minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество"))
                        .visible(.`in`(PdfKeys.rasterFormat, ["jpeg", "heic"])).oracle("pdf.raster.quality").affects([.estimate, .preview])
                ]),
                .make("pages", L10n("Pages", "Страницы"), [pageRangeField(oracle: "pdf.raster.pages")])
            ]),
            .make("look", symbol: "paintpalette", L10n("Appearance", "Вид"), [
                .make("look", [
                    .color(PdfKeys.rasterBackground, L10n("Background", "Фон"), def: "#FFFFFF").visible(.not(.all([.isSet(PdfKeys.rasterTransparent), .`in`(PdfKeys.rasterFormat, ["png", "tiff", "heic"])])))
                        .oracle("pdf.raster.bg").affects([.preview]),
                    .toggle(PdfKeys.rasterTransparent, L10n("Transparent background", "Прозрачный фон"))
                        .visible(.`in`(PdfKeys.rasterFormat, ["png", "tiff", "heic"])).help(L10n("Keeps the paper see-through instead of white.", "Бумага остаётся прозрачной, а не белой."))
                        .oracle("pdf.raster.alpha").affects([.preview]),
                    .toggle(PdfKeys.rasterGray, L10n("Grayscale", "Оттенки серого")).oracle("pdf.raster.gray").affects([.estimate, .preview]),
                    .toggle(PdfKeys.rasterAnnotations, L10n("Draw comments and form fields", "Рисовать комментарии и поля форм"), def: true)
                        .oracle("pdf.raster.annots").affects([.preview])
                ])
            ])
        ])
    }

    // MARK: Text

    static func text(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.text, title: L10n("PDF to text", "PDF в текст"), symbol: "text.alignleft", pages: [
            .make("text", symbol: "text.alignleft", L10n("Text", "Текст"), [
                .make("format", L10n("Result", "Результат"), [
                    .picker(PdfKeys.textFormat, L10n("Text format", "Формат текста"), [FieldOption("txt", L10n("Plain text", "Простой текст")), FieldOption("md", "Markdown")], def: "txt")
                        .basic().oracle("pdf.text.format"),
                    pageRangeField(oracle: "pdf.text.pages.range"),
                    .toggle(PdfKeys.textReflow, L10n("Join wrapped lines into paragraphs", "Склеивать строки в абзацы"))
                        .help(L10n("Markdown always breaks paragraphs at blank lines; with this off every line break is kept.", "Абзацы разделяются пустой строкой; если выключить, сохраняется каждый перенос строки."))
                        .oracle("pdf.text.reflow"),
                    .toggle(PdfKeys.textLayout, L10n("Keep the layout (columns, tables)", "Сохранять вёрстку (колонки, таблицы)"))
                        .needs(["tool.pdftotext"]).help(L10n("Uses pdftotext to keep text where it sits on the page.", "Использует pdftotext, чтобы текст оставался на своих местах."))
                        .oracle("pdf.text.layout").visible(.eq(PdfKeys.textFormat, "txt"))
                ]),
                .make("pages", L10n("Pages and encoding", "Страницы и кодировка"), [
                    .picker(PdfKeys.textSeparators, L10n("Page separators", "Разделители страниц"), [
                        FieldOption("auto", L10n("Blank line (rule in Markdown)", "Пустая строка (линия в Markdown)")),
                        FieldOption("marker", L10n("Page number line", "Строка с номером страницы")),
                        FieldOption("formfeed", L10n("Form feed", "Разрыв страницы (FF)")),
                        FieldOption("none", L10n("None", "Нет"))
                    ], def: "auto").standard().oracle("pdf.text.separators"),
                    .picker(PdfKeys.textEncoding, L10n("Encoding", "Кодировка"), [
                        FieldOption("utf8", "UTF-8"), FieldOption("utf8bom", L10n("UTF-8 with BOM", "UTF-8 с BOM")), FieldOption("utf16", "UTF-16"), FieldOption("cp1251", "Windows-1251")
                    ], def: "utf8").expert().oracle("pdf.text.encoding").affects([])
                ])
            ]),
            .make("scan", symbol: "text.viewfinder", L10n("Scans", "Сканы"), [
                .make("ocr", L10n("Pages without text", "Страницы без текста"), footer: L10n("Pages that are only pictures are recognized; pages with text are read directly.",
                                                                                       "Страницы-картинки распознаются, страницы с текстом читаются напрямую."), [
                    .toggle(PdfKeys.ocr, L10n("Recognize scanned pages", "Распознавать сканы"), def: true).basic().oracle("pdf.text.ocr").affects([.estimate, .plan])
                ] + recognitionFields(visible: .isSet(PdfKeys.ocr)))
            ])
        ])
    }

    // MARK: Export (docx, html, epub, pptx)

    static func export(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.export, title: L10n("PDF to document", "PDF в документ"), symbol: "doc.text", pages: [
            .make("document", symbol: "doc.text", L10n("Document", "Документ"), [
                .make("format", L10n("Result", "Результат"), footer: L10n("The text is exported with its paragraphs; page layout and pictures are not reproduced.",
                                                                          "Экспортируется текст с абзацами; вёрстка страниц и картинки не переносятся."), [
                    .picker(PdfKeys.exportFormat, L10n("Format", "Формат"), [
                        FieldOption("docx", L10n("Word (DOCX)", "Word (DOCX)")), FieldOption("html", L10n("Web page (HTML)", "Веб-страница (HTML)")),
                        FieldOption("epub", L10n("E-book (EPUB)", "Электронная книга (EPUB)")),
                        FieldOption("pptx", L10n("PowerPoint (PPTX)", "PowerPoint (PPTX)"), requires: ["tool.soffice"])
                    ], def: "docx").basic().oracle("pdf.export.format"),
                    pageRangeField(oracle: "pdf.export.pages"),
                    .picker(PdfKeys.textSeparators, L10n("Page separators", "Разделители страниц"), [
                        FieldOption("auto", L10n("Rule between pages", "Линия между страницами")), FieldOption("marker", L10n("Page headings", "Заголовки страниц")), FieldOption("none", L10n("None", "Нет"))
                    ], def: "auto").standard().oracle("pdf.export.separators").enabled(.ne(PdfKeys.exportFormat, "pptx"), reason: L10n("PowerPoint keeps one slide per page.", "В PowerPoint каждая страница становится слайдом.")),
                    .toggle(PdfKeys.textReflow, L10n("Join wrapped lines into paragraphs", "Склеивать строки в абзацы"), def: true)
                        .oracle("pdf.export.reflow").enabled(.ne(PdfKeys.exportFormat, "pptx"))
                ])
            ]),
            .make("scan", symbol: "text.viewfinder", L10n("Scans", "Сканы"), [
                .make("ocr", L10n("Pages without text", "Страницы без текста"), [
                    .toggle(PdfKeys.ocr, L10n("Recognize scanned pages", "Распознавать сканы"), def: true).basic().oracle("pdf.export.ocr")
                        .enabled(.ne(PdfKeys.exportFormat, "pptx"))
                ] + recognitionFields(visible: .isSet(PdfKeys.ocr)))
            ])
        ])
    }

    // MARK: OCR

    static func ocr(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.ocr, title: L10n("Text recognition", "Распознавание текста"), symbol: "text.viewfinder", pages: [
            .make("ocr", symbol: "text.viewfinder", L10n("Recognition", "Распознавание"), [
                .make("result", L10n("Result", "Результат"), [
                    .picker(PdfKeys.ocrOutput, L10n("Save as", "Сохранить как"), [
                        FieldOption("searchablePdf", L10n("Searchable PDF", "PDF с поиском")), FieldOption("txt", L10n("Plain text", "Простой текст")),
                        FieldOption("md", "Markdown"), FieldOption("json", L10n("JSON with positions", "JSON с координатами"))
                    ], def: "searchablePdf").basic().oracle("pdf.ocr.out"),
                    pageRangeField(oracle: "pdf.ocr.pages"),
                    .toggle(PdfKeys.ocrClipboard, L10n("Also copy the text to the clipboard", "Скопировать текст в буфер обмена"), def: true)
                        .oracle("pdf.ocr.clipboard").affects([]),
                    stripMetaField().visible(.eq(PdfKeys.ocrOutput, "searchablePdf"))
                ]),
                .make("recognition", L10n("Recognition", "Распознавание"), recognitionFields(includeSkipText: true).map { f in
                    f.key == PdfKeys.ocrSkipText ? f.help(L10n("Pages whose text is already selectable are copied (or read) as they are and not recognized again.",
                                                               "Страницы с готовым выделяемым текстом копируются (или читаются) как есть и не распознаются заново.")) : f
                })
            ])
        ])
    }

    // MARK: Lookup

    /// Schema for an operation's `schemaID`.
    static func schema(id: String, items: [FileItem]) -> OptionSchema {
        switch id {
        case PdfTargets.images: return images(items: items)
        case PdfTargets.text: return text(items: items)
        case PdfTargets.export: return export(items: items)
        case PdfTargets.merge: return merge(items: items)
        case PdfTargets.split: return split(items: items)
        case PdfTargets.pages: return pages(items: items)
        case PdfTargets.optimize: return optimize(items: items)
        case PdfTargets.protect: return protect(items: items)
        case PdfTargets.unlock: return unlock(items: items)
        case PdfTargets.extract: return extract(items: items)
        default: return ocr(items: items)
        }
    }

    /// Every schema id of the engine (tests walk this list).
    static let allIDs = [PdfTargets.images, PdfTargets.text, PdfTargets.export, PdfTargets.merge, PdfTargets.split, PdfTargets.pages, PdfTargets.optimize,
                         PdfTargets.protect, PdfTargets.unlock, PdfTargets.extract, PdfTargets.ocr]
}
