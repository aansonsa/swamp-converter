import Foundation
import UniformTypeIdentifiers

// The option schemas `doc.convert` and `slides.convert`. Pages: Format (target, engine), Text (encodings, line endings, wrapping), Page (paper, margins, fonts), Content
// (Markdown, web page, e-book, pictures), Metadata. Conditions only look at option values (never at the probed source), so a quick run without a probe resolves the same
// way as the Studio. Every field names the oracle test that proves its effect (DocOracles).

enum DocSchemaBuilder {
    static func formatOptions() -> [FieldOption] {
        [FieldOption("docx", L10n("Word (DOCX)", "Word (DOCX)")),
         FieldOption("pdf", L10n("PDF", "PDF")),
         FieldOption("odt", L10n("OpenDocument (ODT)", "OpenDocument (ODT)")),
         FieldOption("md", L10n("Markdown (MD)", "Markdown (MD)")),
         FieldOption("html", L10n("Web page (HTML)", "Веб-страница (HTML)")),
         FieldOption("txt", L10n("Plain text (TXT)", "Простой текст (TXT)")),
         FieldOption("epub", L10n("E-book (EPUB)", "Электронная книга (EPUB)")),
         FieldOption("rtf", L10n("Rich Text (RTF)", "Rich Text (RTF)"))]
    }

    static func fontOptions() -> [FieldOption] {
        [FieldOption("auto", L10n("Automatic", "Автоматически"), hint: L10n("The usual font of the chosen format.", "Обычный шрифт выбранного формата.")),
         FieldOption("Helvetica Neue", "Helvetica Neue"), FieldOption("Arial", "Arial"), FieldOption("Times New Roman", "Times New Roman"),
         FieldOption("Georgia", "Georgia"), FieldOption("Palatino", "Palatino"), FieldOption("Menlo", "Menlo")]
    }

    static func encodingOptions(_ ids: [String]) -> [FieldOption] { ids.map { FieldOption($0, DocTextCodec.displayName($0)) } }

    private static let pageFormats: OptionExpr = .in(DocKeys.format, ["pdf", "docx", "odt", "rtf"])
    private static let textFormats: OptionExpr = .in(DocKeys.format, ["txt", "md", "html"])

    static func convert(items: [FileItem]) -> OptionSchema {
        let format = OptionPage.make("format", symbol: "doc.text", L10n("Format", "Формат"), [
            .make("target", [
                .picker(DocKeys.format, L10n("Convert to", "Конвертировать в"), formatOptions(), def: "pdf").basic()
                    .help(L10n("The format of the result. Pages, text and content options below follow this choice.", "Формат результата. Параметры страницы, текста и содержимого ниже зависят от этого выбора."))
                    .affects([.estimate, .plan, .preview]).oracle("doc.format.sniff"),
                .picker(DocKeys.engine, L10n("Engine", "Движок"), [
                    FieldOption("auto", L10n("Automatic", "Автоматически")),
                    FieldOption("native", L10n("Built-in", "Встроенный")),
                    FieldOption("pandoc", L10n("Pandoc", "Pandoc"), requires: ["tool.pandoc"]),
                    FieldOption("soffice", L10n("LibreOffice", "LibreOffice"), requires: ["tool.soffice"])
                ], def: "auto").standard()
                    .help(L10n("Automatic uses the built-in engine, and LibreOffice or Pandoc when they are installed and the options you set allow it. The line below the options says who converts.",
                               "Автоматически: встроенный движок, а при наличии LibreOffice или Pandoc и если позволяют заданные параметры, — они. Строка под параметрами показывает, кто конвертирует."))
                    .aliases(["pandoc", "libreoffice", "soffice", "движок"]).oracle("doc.engine.route")
            ])
        ])

        let text = OptionPage.make("text", symbol: "textformat", L10n("Text", "Текст"), [
            .make("text.in", L10n("Source text", "Исходный текст"), footer: L10n("These two options read plain-text, Markdown and web page sources.", "Эти два параметра касаются исходных файлов TXT, MD и HTML."), [
                .picker(DocKeys.encodingIn, L10n("Source encoding", "Кодировка исходника"), encodingOptions(DocTextCodec.inputIDs), def: "auto").standard()
                    .help(L10n("Fixes garbled Cyrillic or Latvian letters. Automatic looks at the file’s first bytes.", "Исправляет «кракозябры» в кириллице и латышском. «Автоматически» смотрит на первые байты файла."))
                    .aliases(["cp1251", "кракозябры", "windows-1251", "koi8", "кодировка"]).oracle("doc.enc.in.decode"),
                .picker(DocKeys.reflow, L10n("Line breaks in plain text", "Переносы строк в простом тексте"), [
                    FieldOption("auto", L10n("Detect hard-wrapped text", "Определять жёсткие переносы")),
                    FieldOption("keep", L10n("Keep every line break", "Сохранять все переносы")),
                    FieldOption("join", L10n("Join lines into paragraphs", "Склеивать строки в абзацы"))
                ], def: "auto").standard()
                    .help(L10n("Old text files break every line at about 70 characters. Joining makes real paragraphs; blank lines always separate paragraphs.",
                               "В старых текстовых файлах строка обрывается примерно на 70 знаках. Склейка превращает их в настоящие абзацы; пустая строка всегда разделяет абзацы."))
                    .oracle("doc.txt.reflow")
            ]),
            .make("text.out", L10n("Text file", "Текстовый файл"), visible: textFormats, [
                .picker(DocKeys.encodingOut, L10n("Encoding", "Кодировка"), encodingOptions(DocTextCodec.outputIDs), def: "utf-8").standard()
                    .help(L10n("UTF-8 opens everywhere. Pick a code page only for old programs; letters it cannot hold are replaced.", "UTF-8 открывается везде. Кодовую страницу выбирайте только для старых программ; буквы, которых в ней нет, заменяются."))
                    .oracle("doc.enc.out.bytes"),
                .toggle(DocKeys.bom, L10n("Add a byte order mark (BOM)", "Добавить метку порядка байтов (BOM)"))
                    .standard().visible(.eq(DocKeys.encodingOut, "utf-8"))
                    .help(L10n("Lets Excel and old Windows programs recognize UTF-8.", "Помогает Excel и старым программам Windows распознать UTF-8."))
                    .oracle("doc.bom.bytes"),
                .segmented(DocKeys.eol, L10n("Line endings", "Концы строк"), [FieldOption("lf", "LF (macOS, Linux)"), FieldOption("crlf", "CRLF (Windows)")], def: "lf").standard()
                    .oracle("doc.eol.bytes"),
                .picker(DocKeys.wrap, L10n("Wrap lines at", "Переносить строки по"), [
                    FieldOption("0", L10n("No wrapping", "Не переносить")), FieldOption("72", L10n("72 characters", "72 знака")),
                    FieldOption("80", L10n("80 characters", "80 знаков")), FieldOption("100", L10n("100 characters", "100 знаков"))
                ], def: "0").standard().visible(.eq(DocKeys.format, "txt"))
                    .oracle("doc.txt.wrap")
            ])
        ])

        let page = OptionPage.make("page", symbol: "doc.richtext", L10n("Page", "Страница"), visible: pageFormats, [
            .make("page.paper", L10n("Paper", "Бумага"), [
                .picker(DocKeys.pageSize, L10n("Paper size", "Размер бумаги"), [
                    FieldOption("a4", "A4"), FieldOption("letter", "Letter"), FieldOption("a5", "A5"), FieldOption("legal", "Legal"),
                    FieldOption("auto", L10n("By region", "По региону"), hint: L10n("Letter in the US, Canada and Mexico, A4 elsewhere.", "Letter в США, Канаде и Мексике, A4 в остальных странах."))
                ], def: "a4").basic().oracle("doc.pdf.mediabox"),
                .number(DocKeys.margins, L10n("Margins", "Поля"), min: 5, max: 50, step: 1, def: 20, unit: "mm").standard().oracle("doc.pdf.margins"),
                .toggle(DocKeys.pageNumbers, L10n("Page numbers", "Номера страниц")).standard().visible(.eq(DocKeys.format, "pdf")).oracle("doc.pdf.numbers")
            ]),
            .make("page.type", L10n("Type", "Шрифт"), [
                .picker(DocKeys.font, L10n("Font", "Шрифт"), fontOptions(), def: "auto").standard().oracle("doc.pdf.font"),
                .stepper(DocKeys.fontSize, L10n("Size", "Размер"), min: 6, max: 48, def: 11, unit: "pt").standard().oracle("doc.pdf.fontsize"),
                .slider(DocKeys.lineSpacing, L10n("Line spacing", "Межстрочный интервал"), min: 1.0, max: 2.0, step: 0.05, def: 1.15, minLabel: L10n("Tight", "Плотно"),
                        maxLabel: L10n("Loose", "Свободно"), decimals: 2).standard().oracle("doc.pdf.spacing")
            ])
        ])

        let content = OptionPage.make("content", symbol: "list.bullet.rectangle", L10n("Content", "Содержимое"), [
            .make("content.md", L10n("Markdown", "Markdown"), visible: .eq(DocKeys.format, "md"), [
                .segmented(DocKeys.mdFlavor, L10n("Flavour", "Диалект"), [FieldOption("gfm", "GitHub (GFM)"), FieldOption("commonmark", "CommonMark")], def: "gfm").standard()
                    .help(L10n("CommonMark has no pipe tables or strike-through; they are written as HTML instead.", "В CommonMark нет таблиц с чертой и зачёркивания; они записываются как HTML."))
                    .oracle("doc.md.flavor"),
                .toggle(DocKeys.extractMedia, L10n("Save pictures in a folder", "Сохранить картинки в папке")).standard()
                    .help(L10n("Creates a folder “name - media” next to the file and links the pictures. Off: pictures are left out and only their descriptions remain.",
                               "Создаёт рядом папку «имя - media» и ссылается на картинки. Выключено: картинок в результате нет, остаются только их описания."))
                    .oracle("doc.md.media"),
                .toggle(DocKeys.mdFrontMatter, L10n("Title and author as front matter", "Название и автор в начале файла")).expert().oracle("doc.md.front")
            ]),
            .make("content.html", L10n("Web page", "Веб-страница"), visible: .eq(DocKeys.format, "html"), [
                .toggle(DocKeys.htmlSingleFile, L10n("Single file (pictures inside)", "Один файл (картинки внутри)"), def: true).standard()
                    .help(L10n("Off: pictures go to a folder “name - media” next to the page.", "Выключено: картинки сохраняются в папке «имя - media» рядом со страницей."))
                    .oracle("doc.html.embed")
            ]),
            .make("content.epub", L10n("E-book", "Электронная книга"), visible: .eq(DocKeys.format, "epub"), [
                .picker(DocKeys.epubSplit, L10n("Start a new chapter at", "Новая глава с"), [
                    FieldOption("h1", L10n("Heading 1", "Заголовка 1")), FieldOption("h2", L10n("Heading 1 and 2", "Заголовков 1 и 2")), FieldOption("none", L10n("Never (one chapter)", "Никогда (одна глава)"))
                ], def: "h1").standard().oracle("doc.epub.split"),
                .file(DocKeys.epubCover, L10n("Cover picture", "Обложка"), types: [.image]).standard().oracle("doc.epub.cover")
            ]),
            .make("content.pictures", L10n("Pictures", "Картинки"), visible: .ne(DocKeys.format, "txt"), [
                .segmented(DocKeys.images, L10n("Pictures", "Картинки"), [FieldOption("keep", L10n("Keep", "Оставить")), FieldOption("remove", L10n("Remove", "Убрать"))], def: "keep").standard()
                    .help(L10n("Removing pictures makes the file much smaller.", "Без картинок файл становится значительно меньше.")).oracle("doc.images")
            ])
        ])

        let meta = OptionPage.make("meta", symbol: "info.circle", L10n("Metadata", "Метаданные"), [
            .make("meta", [
                .segmented(DocKeys.metaMode, L10n("Title, author and dates", "Название, автор и даты"), [FieldOption("keep", L10n("Keep", "Оставить")), FieldOption("strip", L10n("Remove", "Убрать"))], def: "keep").standard()
                    .help(L10n("Remove makes a file that says nothing about who wrote it and when.", "«Убрать» делает файл, который не сообщает, кто и когда его написал.")).oracle("doc.meta.mode"),
                .text(DocKeys.title, L10n("Title", "Название"), placeholder: L10n("From the document", "Из документа")).standard()
                    .enabled(.ne(DocKeys.metaMode, "strip")).oracle("doc.meta.title"),
                .text(DocKeys.author, L10n("Author", "Автор"), placeholder: L10n("From the document", "Из документа")).standard()
                    .enabled(.ne(DocKeys.metaMode, "strip")).oracle("doc.meta.author"),
                .text(DocKeys.language, L10n("Language", "Язык"), placeholder: L10n("en, ru, lv …", "en, ru, lv …")).expert()
                    .enabled(.ne(DocKeys.metaMode, "strip")).oracle("doc.meta.lang")
            ])
        ])
        return OptionSchema(id: DocSchemas.convertID, title: L10n("Document", "Документ"), symbol: "doc.text", pages: [format, text, page, content, meta])
    }

    // MARK: Slides

    static func slides(items: [FileItem]) -> OptionSchema {
        let slideFormats: OptionExpr = .in(DocKeys.format, ["png", "jpg"])
        let format = OptionPage.make("format", symbol: "rectangle.on.rectangle.angled", L10n("Format", "Формат"), requires: ["tool.soffice"], [
            .make("target", [
                .picker(DocKeys.format, L10n("Convert to", "Конвертировать в"), [
                    FieldOption("pdf", "PDF"), FieldOption("png", L10n("PNG pictures", "Картинки PNG")), FieldOption("jpg", L10n("JPG pictures", "Картинки JPG")),
                    FieldOption("pptx", "PowerPoint (PPTX)"), FieldOption("odp", "OpenDocument (ODP)")
                ], def: "pdf").basic().oracle("slides.format.sniff")
                    .help(L10n("PNG and JPG make one picture per slide (a folder when there are several).", "PNG и JPG создают по картинке на слайд (папку, если слайдов несколько).")),
                .text(DocKeys.slideRange, L10n("Slides", "Слайды"), placeholder: L10n("All, or 1-3, 5", "Все или 1-3, 5"), validation: .pageRange).standard()
                    .visible(.in(DocKeys.format, ["pdf", "png", "jpg"]))
                    .help(L10n("Leave empty for every slide.", "Оставьте пустым, чтобы взять все слайды.")).oracle("slides.range")
            ])
        ])
        let pictures = OptionPage.make("pictures", symbol: "photo", L10n("Pictures", "Картинки"), visible: slideFormats, [
            .make("pictures", [
                .slider(DocKeys.slideDPI, L10n("Resolution", "Разрешение"), min: 72, max: 600, step: 1, def: 300, unit: "dpi", minLabel: L10n("Smaller", "Меньше"), maxLabel: L10n("Sharper", "Чётче")).basic()
                    .oracle("slides.dpi"),
                .slider(DocKeys.slideFormatQuality, L10n("JPG quality", "Качество JPG"), min: 50, max: 100, step: 1, def: 90, minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество")).standard()
                    .visible(.eq(DocKeys.format, "jpg")).oracle("slides.quality"),
                .color(DocKeys.slideBackground, L10n("Background", "Фон"), def: "#FFFFFF").standard()
                    .help(L10n("Shown behind transparent parts of a slide.", "Виден за прозрачными частями слайда.")).oracle("slides.background")
            ])
        ])
        return OptionSchema(id: DocSchemas.slidesID, title: L10n("Presentation", "Презентация"), symbol: "rectangle.on.rectangle.angled", pages: [format, pictures])
    }
}
