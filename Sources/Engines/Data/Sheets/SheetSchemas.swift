import Foundation

/// The `sheet.convert` schema (spec/handbrake.md 3.6): Format, Text and encoding, Cells and layout, PDF. Every field has an oracle id (proven by
/// `DataTestsSheets` / `DataConformanceSheets`); defaults equal the quick recipes of `SheetCatalog`. Works for an empty `items` array and reads no files.
enum SheetSchemas {
    static let convertID = "sheet.convert"
    private typealias K = SheetKeys

    static let inputDelimiters: [FieldOption] = [
        FieldOption("auto", L10n("Detect automatically", "Определить автоматически")),
        FieldOption("comma", L10n("Comma ,", "Запятая ,")),
        FieldOption("semicolon", L10n("Semicolon ;", "Точка с запятой ;")),
        FieldOption("tab", L10n("Tab", "Табуляция")),
        FieldOption("pipe", L10n("Pipe |", "Вертикальная черта |"))
    ]

    private static func encodings(auto: Bool, bomChoice: Bool) -> [FieldOption] {
        var o: [FieldOption] = []
        if auto { o.append(FieldOption("auto", L10n("Detect automatically", "Определить автоматически"))) }
        if bomChoice {
            o.append(FieldOption("utf-8-bom", L10n("UTF-8 with BOM (Excel)", "UTF-8 с BOM (для Excel)")))
            o.append(FieldOption("utf-8", "UTF-8"))
            o.append(FieldOption("utf-16", L10n("UTF-16 (Excel “Unicode text”)", "UTF-16 (Excel «Юникод»)")))
        } else {
            o.append(FieldOption("utf-8", "UTF-8"))
            o.append(FieldOption("utf-16", "UTF-16"))
        }
        o.append(FieldOption("windows-1251", L10n("Windows-1251 (Cyrillic)", "Windows-1251 (кириллица)")))
        o.append(FieldOption("windows-1257", L10n("Windows-1257 (Baltic)", "Windows-1257 (балтийская)")))
        o.append(FieldOption("windows-1250", L10n("Windows-1250 (Central European)", "Windows-1250 (центральноевропейская)")))
        o.append(FieldOption("windows-1252", L10n("Windows-1252 (Western European)", "Windows-1252 (западноевропейская)")))
        o.append(FieldOption("koi8-r", "KOI8-R"))
        o.append(FieldOption("cp866", L10n("CP866 (DOS Cyrillic)", "CP866 (DOS, кириллица)")))
        return o
    }

    private static func oneOf(_ key: String, _ values: String...) -> OptionExpr { .in(key, values.map { .string($0) }) }
    private static let delimited = oneOf(K.format, "csv", "tsv")
    private static let tableFile = oneOf(K.format, "xlsx", "ods")
    private static let nativePDF: OptionExpr = .all([.eq(K.format, "pdf"), .eq(K.pdfEngine, "native")])

    static func convert(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: convertID, title: L10n("Spreadsheet", "Таблица"), symbol: "tablecells", pages: [formatPage, textPage, cellsPage, pdfPage], rules: rules)
    }

    // MARK: Pages

    private static var formatPage: OptionPage {
        OptionPage.make("format", symbol: "tablecells", L10n("Format", "Формат"), [
            OptionGroup.make("format.main", [
                .picker(K.format, L10n("Convert to", "Конвертировать в"), [
                    FieldOption("xlsx", L10n("Excel (XLSX)", "Excel (XLSX)")),
                    FieldOption("csv", L10n("CSV (comma-separated text)", "CSV (текст с разделителями)")),
                    FieldOption("tsv", L10n("TSV (tab-separated text)", "TSV (текст с табуляцией)")),
                    FieldOption("ods", L10n("OpenDocument spreadsheet (ODS)", "Таблица OpenDocument (ODS)")),
                    FieldOption("pdf", L10n("PDF (table printout)", "PDF (печатная таблица)"))
                ], def: "xlsx")
                    .basic().affects([.estimate, .plan])
                    .help(L10n("XLSX and ODS keep several sheets and typed cells. CSV and TSV are plain text, one file per sheet.",
                               "XLSX и ODS хранят несколько листов и типы ячеек. CSV и TSV - обычный текст, по файлу на лист."))
                    .aliases(["format", "формат", "excel", "csv", "xlsx", "ods", "pdf"]).oracle("sheet.format.sniff"),
                .segmented(K.sheets, L10n("Sheets", "Листы"), [
                    FieldOption("all", L10n("All", "Все")),
                    FieldOption("first", L10n("First", "Первый")),
                    FieldOption("names", L10n("By name", "По имени"))
                ], def: "all")
                    .basic()
                    .help(L10n("For CSV and TSV every chosen sheet becomes its own file named “name - sheet”.",
                               "Для CSV и TSV каждый выбранный лист становится отдельным файлом «имя - лист»."))
                    .aliases(["sheets", "листы", "worksheet"]).oracle("sheet.sheets.files"),
                .text(K.sheetNames, L10n("Sheet names", "Имена листов"), placeholder: L10n("Sales, Costs", "Продажи, Расходы"))
                    .standard().visible(.eq(K.sheets, "names"))
                    .help(L10n("Separate names with commas. Names are compared without regard to case.", "Имена через запятую. Регистр не важен."))
                    .oracle("sheet.sheets.names")
            ])
        ])
    }

    private static var textPage: OptionPage {
        OptionPage.make("text", symbol: "textformat", L10n("Text and encoding", "Текст и кодировка"), [
            OptionGroup.make("text.read", L10n("Reading CSV and TSV", "Чтение CSV и TSV"), [
                .picker(K.delimiter, L10n("Delimiter in the source", "Разделитель в исходнике"), inputDelimiters, def: "auto")
                    .basic().affects([.estimate])
                    .help(L10n("Automatic detection looks at the first lines and ignores quoted text.", "Автоопределение смотрит на первые строки и не учитывает текст в кавычках."))
                    .oracle("sheet.delim.in.parse"),
                .picker(K.encodingIn, L10n("Encoding of the source", "Кодировка исходника"), encodings(auto: true, bomChoice: false), def: "auto")
                    .basic().affects([.estimate])
                    .help(L10n("Automatic detection reads a byte order mark, then UTF-8, then guesses Windows-1251, KOI8-R, CP866, Baltic or Central European text.",
                               "Автоопределение учитывает BOM, затем UTF-8, затем угадывает Windows-1251, KOI8-R, CP866, балтийскую или центральноевропейскую кодировку."))
                    .aliases(["encoding", "кодировка", "cp1251", "1251", "koi8", "mojibake", "кракозябры"]).oracle("sheet.enc.in.decode"),
                .picker(K.decimalIn, L10n("Decimal mark in the source", "Десятичный знак в исходнике"), [
                    FieldOption("dot", L10n("Dot (1.5)", "Точка (1.5)")),
                    FieldOption("comma", L10n("Comma (1,5)", "Запятая (1,5)"))
                ], def: "dot")
                    .standard().affects([.estimate])
                    .help(L10n("Tells which text counts as a number: with a comma, 1,5 becomes the number 1.5 in XLSX and ODS and is rewritten in CSV.",
                               "Определяет, какой текст считать числом: при запятой 1,5 станет числом 1.5 в XLSX и ODS и будет переписано в CSV."))
                    .oracle("sheet.decimal.in.parse")
            ]),
            OptionGroup.make("text.write", L10n("Writing CSV and TSV", "Запись CSV и TSV"), visible: delimited, [
                .picker(K.delimiterOut, L10n("Delimiter", "Разделитель"), [
                    FieldOption("comma", L10n("Comma ,", "Запятая ,")),
                    FieldOption("semicolon", L10n("Semicolon ;", "Точка с запятой ;")),
                    FieldOption("pipe", L10n("Pipe |", "Вертикальная черта |"))
                ], def: "comma")
                    .basic().visible(.eq(K.format, "csv"))
                    .help(L10n("Excel with Russian or Latvian settings expects a semicolon.", "Excel с русскими или латышскими настройками ожидает точку с запятой."))
                    .oracle("sheet.delim.out.bytes"),
                .picker(K.encodingOut, L10n("Encoding", "Кодировка"), encodings(auto: false, bomChoice: true), def: "utf-8-bom")
                    .basic()
                    .help(L10n("UTF-8 with BOM lets Excel show diacritics and Cyrillic correctly. Older programs may want Windows-1251 or Windows-1257.",
                               "UTF-8 с BOM позволяет Excel правильно показать диакритику и кириллицу. Старые программы могут требовать Windows-1251 или Windows-1257."))
                    .aliases(["encoding", "кодировка", "bom"]).oracle("sheet.enc.out.bytes"),
                .segmented(K.lineEnding, L10n("Line endings", "Концы строк"), [
                    FieldOption("crlf", L10n("Windows (CRLF)", "Windows (CRLF)")),
                    FieldOption("lf", L10n("Unix (LF)", "Unix (LF)"))
                ], def: "crlf").standard().oracle("sheet.eol.bytes"),
                .toggle(K.quoteAll, L10n("Quote every field", "Все поля в кавычках"))
                    .standard()
                    .help(L10n("Without this, only fields that contain the delimiter, a quote or a line break are quoted.",
                               "Без этого в кавычки берутся только поля с разделителем, кавычкой или переводом строки."))
                    .oracle("sheet.quoteAll.bytes"),
                .picker(K.decimal, L10n("Decimal mark", "Десятичный знак"), [
                    FieldOption("keep", L10n("Keep as in the source", "Как в исходнике")),
                    FieldOption("dot", L10n("Dot (1.5)", "Точка (1.5)")),
                    FieldOption("comma", L10n("Comma (1,5)", "Запятая (1,5)"))
                ], def: "keep")
                    .standard()
                    .help(L10n("Rewrites numbers such as 1.5 or 1,5 (the source mark is set on the Reading side). Dates, codes and text are left alone.",
                               "Переписывает числа вроде 1.5 или 1,5 (знак исходника задаётся в разделе «Чтение»). Даты, коды и текст не меняются."))
                    .aliases(["decimal", "десятичный", "comma", "запятая"]).oracle("sheet.decimal.out.text")
            ])
        ])
    }

    private static var cellsPage: OptionPage {
        OptionPage.make("cells", symbol: "square.grid.3x3", L10n("Cells and layout", "Ячейки и вид"), [
            OptionGroup.make("cells.clean", L10n("Content", "Содержимое"), [
                .toggle(K.trimCells, L10n("Trim spaces around values", "Убрать пробелы по краям значений"))
                    .standard().oracle("sheet.trim.cells"),
                .toggle(K.skipEmpty, L10n("Skip empty rows", "Пропускать пустые строки"))
                    .standard().help(L10n("Rows without any value are left out of the result.", "Строки без значений не попадут в результат.")).oracle("sheet.skipEmpty.rows")
            ]),
            OptionGroup.make("cells.layout", L10n("Layout", "Вид"), visible: oneOf(K.format, "xlsx", "ods", "pdf"), [
                .toggle(K.headerRow, L10n("First row is a header", "Первая строка - заголовок"), def: true)
                    .basic()
                    .help(L10n("Bold in XLSX, ODS and PDF; repeated on every PDF page.", "Жирным в XLSX, ODS и PDF; в PDF повторяется на каждой странице."))
                    .oracle("sheet.header.style"),
                .toggle(K.autoFit, L10n("Fit column widths to the content", "Подогнать ширину столбцов"), def: true)
                    .standard().visible(tableFile).oracle("sheet.autofit.cols"),
                .toggle(K.freeze, L10n("Freeze the header row", "Закрепить строку заголовка"), def: true)
                    .standard().visible(.eq(K.format, "xlsx")).enabled(.isSet(K.headerRow), reason: L10n("Turn on “First row is a header”.", "Включите «Первая строка - заголовок»."))
                    .oracle("sheet.freeze.pane"),
                .toggle(K.filter, L10n("Add filter buttons to the header", "Добавить кнопки фильтра в заголовок"))
                    .standard().visible(.eq(K.format, "xlsx")).oracle("sheet.filter.autofilter"),
                .toggle(K.allText, L10n("Keep every cell as text", "Хранить все ячейки как текст"))
                    .standard().visible(tableFile)
                    .help(L10n("Phone numbers, codes and ZIP codes keep every digit. Without this, plain numbers become real numbers and ISO dates become dates.",
                               "Телефоны, коды и индексы сохраняют каждую цифру. Без этого обычные числа становятся числами, а даты ISO - датами."))
                    .oracle("sheet.allText.types"),
                .toggle(K.dates, L10n("Turn ISO dates into real dates", "Превращать даты ISO в настоящие даты"), def: true)
                    .standard().visible(tableFile).enabled(.not(.isSet(K.allText)), reason: L10n("Cells are kept as text.", "Ячейки хранятся как текст."))
                    .help(L10n("2024-01-05 and 2024-01-05 13:45 become date cells.", "2024-01-05 и 2024-01-05 13:45 становятся ячейками с датой."))
                    .oracle("sheet.dates.types")
            ])
        ])
    }

    private static var pdfPage: OptionPage {
        OptionPage.make("pdf", symbol: "doc.richtext", L10n("PDF", "PDF"), visible: .eq(K.format, "pdf"), [
            OptionGroup.make("pdf.engine", [
                .segmented(K.pdfEngine, L10n("Layout", "Вёрстка"), [
                    FieldOption("native", L10n("Table (built in)", "Таблица (встроенная)")),
                    FieldOption("soffice", L10n("LibreOffice (keeps cell formatting)", "LibreOffice (сохраняет оформление)"), requires: ["tool.soffice"], hint: Tool.soffice.installHint)
                ], def: "native")
                    .basic()
                    .help(L10n("The built-in layout prints the values as a plain table with a header row. LibreOffice also keeps fonts, colors and widths of XLSX, XLS and ODS files.",
                               "Встроенная вёрстка печатает значения простой таблицей с заголовком. LibreOffice сохраняет шрифты, цвета и ширины файлов XLSX, XLS и ODS."))
                    .oracle("sheet.pdf.engine.soffice")
            ]),
            OptionGroup.make("pdf.page", L10n("Page", "Страница"), visible: .eq(K.pdfEngine, "native"), [
                .picker(K.pdfPageSize, L10n("Paper size", "Размер бумаги"), [
                    FieldOption("a4", "A4"), FieldOption("a3", "A3"), FieldOption("a5", "A5"),
                    FieldOption("letter", "Letter"), FieldOption("legal", "Legal")
                ], def: "a4").basic().oracle("sheet.pdf.mediabox"),
                .segmented(K.pdfOrientation, L10n("Orientation", "Ориентация"), [
                    FieldOption("auto", L10n("Automatic", "Авто")),
                    FieldOption("portrait", L10n("Portrait", "Книжная")),
                    FieldOption("landscape", L10n("Landscape", "Альбомная"))
                ], def: "auto")
                    .standard().help(L10n("Automatic chooses landscape for wide tables.", "Автоматически выбирает альбомную для широких таблиц."))
                    .oracle("sheet.pdf.orient.mediabox"),
                .stepper(K.pdfFontSize, L10n("Font size", "Размер шрифта"), min: 6, max: 14, def: 9, unit: "pt")
                    .standard().help(L10n("Longer cells wrap onto several lines.", "Длинные ячейки переносятся на несколько строк.")).oracle("sheet.pdf.fontSize.pages")
            ])
        ])
    }

    // MARK: Rules

    private static var rules: [ValidationRule] {
        [
            .warning("sheet.csv.decimalComma", when: .all([.eq(K.format, "csv"), .eq(K.decimal, "comma"), .eq(K.delimiterOut, "comma")]),
                     L10n("Numbers with a decimal comma and a comma delimiter run together. Use a semicolon.", "Числа с десятичной запятой и разделитель-запятая сливаются. Выберите точку с запятой."),
                     field: K.delimiterOut, fix: OptionFix(title: L10n("Use a Semicolon", "Выбрать точку с запятой"), set: [K.delimiterOut: "semicolon"])),
            .info("sheet.enc.lossy", when: .all([delimited, oneOf(K.encodingOut, "windows-1251", "windows-1250", "windows-1252", "windows-1257", "koi8-r", "cp866")]),
                  L10n("Characters this code page does not have are replaced by a similar letter or a question mark.", "Символы, которых нет в этой кодовой странице, заменяются похожей буквой или знаком вопроса."),
                  field: K.encodingOut),
            .warning("sheet.names.empty", when: .all([.eq(K.sheets, "names"), .not(.isSet(K.sheetNames))]),
                     L10n("Type the names of the sheets to convert.", "Введите имена листов для конвертации."), field: K.sheetNames)
        ]
    }
}
