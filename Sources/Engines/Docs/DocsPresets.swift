import Foundation

// Built-in presets of the documents target (spec/handbrake.md 4.5). Values are sparse over the schema defaults. The ids are prefixed "builtin." by the store.

enum DocsPresets {
    static let builtins: [Preset] = [
        .builtin("doc.word", target: DocSchemas.convertID, L10n("Word (DOCX)", "Word (DOCX)"), notes: L10n("A Word document with real headings, lists and tables.", "Документ Word с настоящими заголовками, списками и таблицами."),
                 symbol: "doc.text", group: .devices, operation: "doc.to.docx", [DocKeys.format: "docx"]),
        .builtin("doc.pdf.a4", target: DocSchemas.convertID, L10n("PDF A4", "PDF A4"), notes: L10n("A4 pages with 20 mm margins; the text stays selectable.", "Страницы A4 с полями 20 мм; текст остаётся выделяемым."),
                 symbol: "doc.richtext", group: .devices, operation: "doc.to.pdf", [DocKeys.format: "pdf", DocKeys.pageSize: "a4", DocKeys.margins: 20]),
        .builtin("doc.txt.utf8", target: DocSchemas.convertID, L10n("Plain text UTF-8", "Простой текст UTF-8"), notes: L10n("Text only, in UTF-8, line breaks as on a Mac.", "Только текст в UTF-8, переносы строк как на Mac."),
                 symbol: "text.alignleft", group: .archive, operation: "doc.to.txt", [DocKeys.format: "txt", DocKeys.encodingOut: "utf-8", DocKeys.bom: false, DocKeys.eol: "lf"]),
        .builtin("doc.epub", target: DocSchemas.convertID, L10n("E-book EPUB", "Электронная книга EPUB"), notes: L10n("An e-book with a table of contents; a new chapter starts at every Heading 1.", "Книга с оглавлением; новая глава начинается с каждого Заголовка 1."),
                 symbol: "book", group: .devices, operation: "doc.to.epub", [DocKeys.format: "epub", DocKeys.epubSplit: "h1"]),
        .builtin("doc.html.single", target: DocSchemas.convertID, L10n("Web page (single file)", "Веб-страница (один файл)"), notes: L10n("One HTML file with the pictures inside.", "Один файл HTML с картинками внутри."),
                 symbol: "globe", group: .web, operation: "doc.to.html", [DocKeys.format: "html", DocKeys.htmlSingleFile: true]),
        .builtin("doc.fixcyr", target: DocSchemas.convertID, L10n("Fix Cyrillic (to UTF-8)", "Починить кириллицу (в UTF-8)"),
                 notes: L10n("Detects the old encoding of a text file (Windows-1251, KOI8-R, DOS 866) and writes UTF-8.", "Определяет старую кодировку текстового файла (Windows-1251, KOI8-R, DOS 866) и записывает UTF-8."),
                 symbol: "textformat", group: .archive, operation: "doc.to.txt", [DocKeys.format: "txt", DocKeys.encodingIn: "auto", DocKeys.encodingOut: "utf-8"])
    ]
}
