import Foundation

// Schemas of the PDF -> PDF targets: merge, split, pages (rotate / paper size / trim), extract, optimise, protect, unlock.

extension PdfSchemas {
    // MARK: Merge

    static func merge(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.merge, title: L10n("Merge PDFs", "Объединение PDF"), symbol: "arrow.triangle.merge", pages: [
            .make("merge", symbol: "arrow.triangle.merge", L10n("Merge", "Объединение"), [
                .make("order", L10n("Order", "Порядок"), [
                    .picker(PdfKeys.mergeOrder, L10n("Order", "Порядок"), [
                        FieldOption("name", L10n("By name (1, 2, 10)", "По имени (1, 2, 10)")), FieldOption("date", L10n("By date modified", "По дате изменения")),
                        FieldOption("selection", L10n("As selected", "Как выбрано"))
                    ], def: "name").basic().oracle("pdf.merge.order").affects([.plan]),
                    .toggle(PdfKeys.mergeBookmarks, L10n("One bookmark per file", "Закладка на каждый файл"), def: true).oracle("pdf.merge.bookmarks").affects([]),
                    .toggle(PdfKeys.mergeNormalize, L10n("Make all pages the size of the first page", "Привести все страницы к размеру первой"))
                        .help(L10n("Pages are redrawn onto sheets of the first page’s size. Links and comments are not kept.", "Страницы перерисовываются на листы размера первой страницы. Ссылки и комментарии не сохраняются."))
                        .oracle("pdf.merge.norm").expert()
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ])
        ])
    }

    // MARK: Split

    static func split(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.split, title: L10n("Split PDF", "Разделение PDF"), symbol: "rectangle.split.2x1", pages: [
            .make("split", symbol: "rectangle.split.2x1", L10n("Split", "Разделение"), [
                .make("mode", L10n("Split by", "Разделить по"), footer: L10n("The files go into a folder next to the original.", "Файлы попадают в папку рядом с оригиналом."), [
                    .picker(PdfKeys.splitMode, L10n("Split by", "Разделить по"), [
                        FieldOption("eachPage", L10n("Each page", "Каждой странице")), FieldOption("everyN", L10n("Every N pages", "Каждые N страниц")),
                        FieldOption("ranges", L10n("Ranges", "Диапазонам")), FieldOption("bySize", L10n("File size", "Размеру файла")),
                        FieldOption("byBookmark", L10n("Bookmarks", "Закладкам"))
                    ], def: "eachPage").basic().oracle("pdf.split.mode").affects([.plan, .estimate]),
                    .stepper(PdfKeys.splitEvery, L10n("Pages per file", "Страниц в файле"), min: 1, max: 1000, def: 10).visible(.eq(PdfKeys.splitMode, "everyN")).oracle("pdf.split.n"),
                    .text(PdfKeys.splitRanges, L10n("Ranges, one file each", "Диапазоны, по файлу на каждый"), def: "1-3, 4-6", placeholder: L10n("1-3, 4-6, 7-", "1-3, 4-6, 7-"), validation: .pageRange)
                        .visible(.eq(PdfKeys.splitMode, "ranges")).oracle("pdf.split.ranges"),
                    .number(PdfKeys.splitMegabytes, L10n("Largest file", "Максимальный размер файла"), min: 0.1, max: 2000, step: 1, def: 10, unit: "MB", decimals: 1)
                        .visible(.eq(PdfKeys.splitMode, "bySize")).oracle("pdf.split.mb")
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ])
        ])
    }

    // MARK: Pages (rotate, paper size, trim)

    static func pages(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.pages, title: L10n("PDF pages", "Страницы PDF"), symbol: "doc.on.doc", pages: [
            .make("rotate", symbol: "rotate.right", L10n("Rotate", "Поворот"), [
                .make("rotate", L10n("Rotate pages", "Повернуть страницы"), [
                    .picker(PdfKeys.rotate, L10n("Rotate", "Повернуть"), [
                        FieldOption("0", L10n("Do not rotate", "Не поворачивать")), FieldOption("90", L10n("90° right", "На 90° вправо")),
                        FieldOption("180", L10n("180°", "На 180°")), FieldOption("270", L10n("90° left", "На 90° влево"))
                    ], def: "90").basic().oracle("pdf.rotate.angle"),
                    .picker(PdfKeys.rotateScope, L10n("Apply to", "Применить к"), [
                        FieldOption("all", L10n("All pages", "Всем страницам")), FieldOption("odd", L10n("Odd pages", "Нечётным")),
                        FieldOption("even", L10n("Even pages", "Чётным")), FieldOption("selected", L10n("Chosen pages", "Выбранным"))
                    ], def: "all").standard().oracle("pdf.rotate.scope").enabled(.ne(PdfKeys.rotate, "0")),
                    pageRangeField(def: "1", oracle: "pdf.rotate.pages").visible(.eq(PdfKeys.rotateScope, "selected")).enabled(.ne(PdfKeys.rotate, "0"))
                ])
            ]),
            .make("size", symbol: "doc.plaintext", L10n("Paper size", "Размер бумаги"), [
                .make("size", L10n("Paper", "Бумага"), footer: L10n("Resizing redraws the pages: text stays sharp, links and comments are not kept.",
                                                                    "Смена размера перерисовывает страницы: текст остаётся чётким, ссылки и комментарии не сохраняются."), [
                    .picker(PdfKeys.pageSize, L10n("Page size", "Размер страницы"), [
                        FieldOption("keep", L10n("Keep", "Оставить")), FieldOption("a3", "A3"), FieldOption("a4", "A4"), FieldOption("a5", "A5"),
                        FieldOption("letter", "Letter"), FieldOption("legal", "Legal")
                    ], def: "keep").basic().oracle("pdf.size.paper"),
                    .picker(PdfKeys.pageSizeFit, L10n("Content", "Содержимое"), [
                        FieldOption("fit", L10n("Fit inside", "Вписать")), FieldOption("fill", L10n("Fill and crop", "Заполнить с обрезкой")), FieldOption("none", L10n("Keep size, center", "Не менять размер, по центру"))
                    ], def: "fit").standard().oracle("pdf.size.fit").visible(.ne(PdfKeys.pageSize, "keep")),
                    .number(PdfKeys.margins, L10n("Margins", "Поля"), min: 0, max: 50, step: 1, def: 0, unit: "mm").standard().oracle("pdf.size.margins").visible(.ne(PdfKeys.pageSize, "keep"))
                ]),
                .make("trim", L10n("Trim", "Обрезка"), [
                    .number(PdfKeys.trim, L10n("Trim every side by", "Обрезать со всех сторон"), min: 0, max: 50, step: 1, def: 0, unit: "mm").expert().oracle("pdf.trim")
                        .help(L10n("Cuts the same amount from every edge of every page, for example scanner borders.", "Обрезает одинаково со всех краёв каждой страницы, например рамки сканера."))
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ])
        ])
    }

    // MARK: Extract

    static func extract(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.extract, title: L10n("Extract pages", "Извлечение страниц"), symbol: "doc.on.doc", pages: [
            .make("extract", symbol: "doc.on.doc", L10n("Pages", "Страницы"), [
                .make("pages", L10n("Pages", "Страницы"), [
                    pageRangeField(def: "1", help: L10n("The pages to keep or remove: 1-3, 5, 8- (or “all”).", "Страницы, которые нужно оставить или удалить: 1-3, 5, 8- (или «все»)."),
                                   oracle: "pdf.extract.pages"),
                    .segmented(PdfKeys.extractMode, L10n("These pages", "Эти страницы"), [FieldOption("keep", L10n("Keep", "Оставить")), FieldOption("remove", L10n("Remove", "Удалить"))], def: "keep")
                        .basic().oracle("pdf.extract.mode"),
                    .segmented(PdfKeys.extractOrder, L10n("Order", "Порядок"), [FieldOption("keep", L10n("As in the file", "Как в файле")), FieldOption("reverse", L10n("Reversed", "В обратном порядке"))], def: "keep")
                        .standard().oracle("pdf.extract.order")
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ])
        ])
    }

    // MARK: Optimise

    static func optimize(items: [FileItem]) -> OptionSchema {
        let raster = OptionExpr.eq(PdfKeys.mode, "raster")
        return OptionSchema(id: PdfTargets.optimize, title: L10n("Optimize PDF", "Оптимизация PDF"), symbol: "arrow.down.right.and.arrow.up.left", pages: [
            .make("optimize", symbol: "arrow.down.right.and.arrow.up.left", L10n("Optimize", "Оптимизация"), [
                .make("level", L10n("Reduce size", "Уменьшить размер"), [
                    .picker(PdfKeys.mode, L10n("Method", "Способ"), [
                        FieldOption("keepText", L10n("Keep text sharp", "Сохранить текст")), FieldOption("raster", L10n("Turn pages into pictures", "Превратить страницы в картинки"))
                    ], def: "keepText").basic().oracle("pdf.optimize.mode")
                        .help(L10n("“Keep text” shrinks only the images. “Pictures” gives the smallest file but text becomes pixels (add recognition to keep it searchable).",
                                   "«Сохранить текст» сжимает только изображения. «Картинки» дают самый маленький файл, но текст становится пикселями (добавьте распознавание, чтобы сохранить поиск).")),
                    .picker(PdfKeys.level, L10n("Level", "Уровень"), [
                        FieldOption("screen", L10n("Screen (smallest)", "Экран (самый маленький)")), FieldOption("standard", L10n("Standard", "Стандарт")),
                        FieldOption("high", L10n("High (print)", "Высокое (печать)")), FieldOption("custom", L10n("Custom", "Свои значения"))
                    ], def: "standard").basic().oracle("pdf.optimize.level"),
                    .slider(PdfKeys.imageDPI, L10n("Image resolution", "Разрешение изображений"), min: 36, max: 600, step: 1, def: 150, unit: "dpi")
                        .visible(.eq(PdfKeys.level, "custom")).oracle("pdf.optimize.dpi")
                        .help(L10n("Pictures above this resolution are scaled down; lower ones stay as they are.", "Изображения с большим разрешением уменьшаются, меньшие остаются как есть.")),
                    .slider(PdfKeys.imageQuality, L10n("JPEG quality", "Качество JPEG"), min: 10, max: 100, step: 1, def: 75)
                        .visible(.eq(PdfKeys.level, "custom")).oracle("pdf.optimize.quality"),
                    .toggle(PdfKeys.imageGray, L10n("Convert to grayscale", "Преобразовать в оттенки серого")).visible(raster).oracle("pdf.optimize.gray"),
                    .toggle(PdfKeys.flatten, L10n("Flatten comments and form fields", "Вшить комментарии и поля форм")).visible(.eq(PdfKeys.mode, "keepText"))
                        .oracle("pdf.optimize.flatten").expert()
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ]),
            .make("ocr", symbol: "text.viewfinder", L10n("Recognition", "Распознавание"), visible: raster, [
                .make("ocr", L10n("Keep the file searchable", "Сохранить поиск по тексту"), [
                    .toggle(PdfKeys.ocr, L10n("Recognize text", "Распознать текст")).basic().oracle("pdf.optimize.ocr").affects([.estimate, .plan])
                ] + recognitionFields(visible: .isSet(PdfKeys.ocr), includeSkipText: false)),
                .make("keep", [
                    .toggle(PdfKeys.ocrSkipText, L10n("Keep pages that already have text as they are", "Не трогать страницы с готовым текстом"), def: true)
                        .help(L10n("Such pages stay sharp text; only picture pages are turned into JPEG.", "Такие страницы остаются чётким текстом; в JPEG превращаются только страницы-картинки."))
                        .oracle("pdf.optimize.keeptext").standard()
                ])
            ])
        ])
    }

    // MARK: Protect, unlock

    static func protect(items: [FileItem]) -> OptionSchema {
        let secret = L10n("Typed here, used once and never saved in presets, the queue or logs. Latin letters, digits and symbols only: PDF passwords cannot hold other scripts.",
                          "Вводится здесь, используется один раз и не сохраняется в шаблонах, очереди и журналах. Только латинские буквы, цифры и символы: пароли PDF не поддерживают другие алфавиты.")
        let asciiPattern = "^[\\x20-\\x7E]*$"
        return OptionSchema(id: PdfTargets.protect, title: L10n("Protect PDF", "Защита PDF"), symbol: "lock", pages: [
            .make("protect", symbol: "lock", L10n("Protection", "Защита"), [
                .make("passwords", L10n("Passwords", "Пароли"), footer: secret, [
                    .text(PdfKeys.openPassword, L10n("Password to open", "Пароль для открытия"), validation: .regex(asciiPattern), secure: true).basic().oracle("pdf.protect.open").affects([]),
                    .text(PdfKeys.ownerPassword, L10n("Owner password", "Пароль владельца"), validation: .regex(asciiPattern), secure: true).standard().oracle("pdf.protect.owner").affects([])
                        .help(L10n("Needed to change the permissions below. Left empty, the opening password is used.", "Нужен, чтобы менять права ниже. Если пусто, используется пароль для открытия."))
                ]),
                .make("permissions", L10n("Allow", "Разрешить"), [
                    .toggle(PdfKeys.allowPrint, L10n("Printing", "Печать"), def: true).oracle("pdf.protect.print").affects([]),
                    .toggle(PdfKeys.allowCopy, L10n("Copying text and images", "Копирование текста и изображений"), def: true).oracle("pdf.protect.copy").affects([]),
                    .toggle(PdfKeys.allowEdit, L10n("Editing and page changes", "Правку и изменение страниц"), def: true).oracle("pdf.protect.edit").affects([])
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ])
        ], rules: [
            .error("pdf.protect.nopassword", when: .all([.not(.isSet(PdfKeys.openPassword)), .not(.isSet(PdfKeys.ownerPassword))]),
                   L10n("Enter a password to open the file or an owner password.", "Введите пароль для открытия файла или пароль владельца."), field: PdfKeys.openPassword),
            .warning("pdf.protect.weakrestrict",
                     when: .all([.isSet(PdfKeys.openPassword), .not(.isSet(PdfKeys.ownerPassword)),
                                 .any([.eq(PdfKeys.allowPrint, .bool(false)), .eq(PdfKeys.allowCopy, .bool(false)), .eq(PdfKeys.allowEdit, .bool(false))])]),
                     L10n("Without an owner password, anyone who knows the opening password also lifts these restrictions.",
                          "Без пароля владельца любой, кто знает пароль для открытия, снимет и эти ограничения."), field: PdfKeys.ownerPassword)
        ])
    }

    static func unlock(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: PdfTargets.unlock, title: L10n("Remove PDF password", "Снятие пароля PDF"), symbol: "lock.open", pages: [
            .make("unlock", symbol: "lock.open", L10n("Password", "Пароль"), [
                .make("password", L10n("Password", "Пароль"), footer: L10n("Typed here, used once and never saved.", "Вводится здесь, используется один раз и не сохраняется."), [
                    .text(PdfKeys.openPassword, L10n("Password of the file", "Пароль файла"), secure: true).basic().oracle("pdf.unlock.password").affects([])
                        .help(L10n("The password you know. Files that only restrict printing or copying need their owner password.", "Известный вам пароль. Для файлов с запретом печати или копирования нужен пароль владельца."))
                ]),
                .make("info", L10n("Document info", "Сведения"), [stripMetaField()])
            ])
        ])
    }
}
