import Foundation

/// Built-in presets of the data module (spec/handbrake.md 4.5). Every value is a field of the matching schema, so Studio shows exactly what the preset sets.
enum DataPresets {
    private static func sheet(_ id: String, _ name: L10n, _ note: L10n, op: String, group: PresetGroup, _ v: OptionValues) -> Preset {
        .builtin(id, target: SheetSchemas.convertID, name, notes: note, symbol: "tablecells", group: group, operation: op, v)
    }
    private static func subs(_ id: String, _ name: L10n, _ note: L10n, op: String, group: PresetGroup = .web, _ v: OptionValues) -> Preset {
        .builtin(id, target: SubsSchemas.convertID, name, notes: note, symbol: "captions.bubble", group: group, operation: op, v)
    }
    private static func pack(_ id: String, _ name: L10n, _ note: L10n, op: String? = nil, group: PresetGroup = .archive, _ v: OptionValues) -> Preset {
        .builtin(id, target: ArchiveSchemas.packID, name, notes: note, symbol: "archivebox", group: group, operation: op, v)
    }

    static let builtins: [Preset] = [
        // Spreadsheets
        sheet("sheet.csv.excel", L10n("CSV for Excel (RU / LV)", "CSV для Excel (RU / LV)"),
              L10n("Semicolon, UTF-8 with BOM and decimal commas: opens correctly in Excel with Russian or Latvian settings.", "Точка с запятой, UTF-8 с BOM и десятичные запятые: правильно открывается в Excel с русскими или латышскими настройками."),
              op: "sheet.to.csv", group: .devices, [SheetKeys.format: "csv", SheetKeys.delimiterOut: "semicolon", SheetKeys.encodingOut: "utf-8-bom", SheetKeys.decimal: "comma"]),
        sheet("sheet.csv.plain", L10n("CSV, plain (UTF-8, comma)", "CSV обычный (UTF-8, запятая)"),
              L10n("The format programmers and databases expect: UTF-8 without BOM, commas, LF line ends.", "Формат для программистов и баз данных: UTF-8 без BOM, запятые, переводы строки LF."),
              op: "sheet.to.csv", group: .web, [SheetKeys.format: "csv", SheetKeys.delimiterOut: "comma", SheetKeys.encodingOut: "utf-8", SheetKeys.lineEnding: "lf", SheetKeys.decimal: "dot"]),
        sheet("sheet.csv.1251", L10n("CSV for old programs (Windows-1251)", "CSV для старых программ (Windows-1251)"),
              L10n("Semicolon and Windows-1251 for accounting programs and old Windows software.", "Точка с запятой и Windows-1251 для бухгалтерских и старых программ Windows."),
              op: "sheet.to.csv", group: .devices, [SheetKeys.format: "csv", SheetKeys.delimiterOut: "semicolon", SheetKeys.encodingOut: "windows-1251"]),
        sheet("sheet.xlsx.csv", L10n("XLSX to CSV, every sheet", "XLSX в CSV, каждый лист"),
              L10n("One CSV file per sheet.", "По файлу CSV на каждый лист."), op: "sheet.to.csv", group: .web, [SheetKeys.format: "csv", SheetKeys.sheets: "all"]),
        sheet("sheet.xlsx.text", L10n("Excel, everything as text", "Excel, всё как текст"),
              L10n("Keeps phone numbers, ZIP codes and long ids exactly as written.", "Сохраняет телефоны, индексы и длинные номера точно как написано."),
              op: "sheet.to.xlsx", group: .lossless, [SheetKeys.format: "xlsx", SheetKeys.allText: true]),
        sheet("sheet.pdf.a4", L10n("Table to PDF (A4)", "Таблица в PDF (A4)"),
              L10n("A printable table, landscape when it is wide.", "Печатная таблица, альбомная, если она широкая."), op: "sheet.to.pdf", group: .web, [SheetKeys.format: "pdf", SheetKeys.pdfPageSize: "a4", SheetKeys.pdfOrientation: "auto"]),

        // Subtitles
        subs("sub.srt.utf8", L10n("SRT, fix encoding (UTF-8)", "SRT, починить кодировку (UTF-8)"),
             L10n("Detects the old encoding (Windows-1251, KOI8-R, Baltic …) and saves readable UTF-8; overlapping cues are repaired.", "Определяет старую кодировку (Windows-1251, KOI8-R, балтийскую …) и сохраняет читаемый UTF-8; пересекающиеся реплики исправляются."),
             op: "subs.to.srt", [SubsKeys.format: "srt", SubsKeys.encodingIn: "auto", SubsKeys.encodingOut: "utf-8", SubsKeys.overlap: true]),
        subs("sub.srt.1251", L10n("SRT for old TVs (Windows-1251)", "SRT для старых телевизоров (Windows-1251)"),
             L10n("Cyrillic subtitles in the encoding old players expect.", "Кириллические субтитры в кодировке, которую ждут старые плееры."), op: "subs.to.srt", group: .devices,
             [SubsKeys.format: "srt", SubsKeys.encodingOut: "windows-1251", SubsKeys.eol: "crlf"]),
        subs("sub.vtt.web", L10n("WebVTT for the web", "WebVTT для сайта"), L10n("For HTML5 video players.", "Для HTML5-плееров."), op: "subs.to.vtt", [SubsKeys.format: "vtt", SubsKeys.encodingOut: "utf-8"]),
        subs("sub.shift.2s", L10n("Shift timings +2 s", "Сдвинуть время на +2 с"), L10n("Subtitles that appear too early: shows every cue 2 seconds later.", "Субтитры появляются слишком рано: каждая реплика показывается на 2 секунды позже."),
             op: "subs.to.srt", [SubsKeys.format: "srt", SubsKeys.offset: 2.0]),
        subs("sub.fps.2397to25", L10n("Fix drift 23.976 to 25 fps", "Исправить уход 23.976 -> 25"),
             L10n("For subtitles made for a 23.976 fps film that play too late or early on the 25 fps version.", "Для субтитров к фильму 23.976 к/с, которые отстают или спешат на версии 25 к/с."),
             op: "subs.to.srt", [SubsKeys.format: "srt", SubsKeys.fpsFrom: "23.976", SubsKeys.fpsTo: "25"]),
        subs("sub.clean.sdh", L10n("Clean up (tags and sound notes)", "Очистить (теги и описания звуков)"),
             L10n("Removes formatting tags, [music] / (laughs) notes and speaker labels; repairs overlaps.", "Убирает теги, описания звуков [музыка] / (смех) и подписи говорящих; исправляет пересечения."),
             op: "subs.to.srt", [SubsKeys.format: "srt", SubsKeys.removeTags: true, SubsKeys.removeSDH: true, SubsKeys.overlap: true]),
        subs("sub.txt", L10n("Text only", "Только текст"), L10n("The words without times, one line per cue.", "Слова без времени, строка на реплику."), op: "subs.to.txt", [SubsKeys.format: "txt", SubsKeys.removeTags: true]),

        // Archives
        pack("arc.zip", L10n("ZIP, compatible", "ZIP, совместимо"), L10n("Opens everywhere. Mac system files are left out.", "Открывается везде. Системные файлы Mac не включаются."),
             op: "pack.zip", [ArchiveKeys.format: "zip", ArchiveKeys.level: 6, ArchiveKeys.excludeHidden: true]),
        pack("arc.zip.max", L10n("ZIP, maximum", "ZIP, максимум"), L10n("Smallest ZIP the format allows.", "Самый маленький ZIP, который позволяет формат."),
             op: "pack.zip", group: .smallSize, [ArchiveKeys.format: "zip", ArchiveKeys.level: 9]),
        pack("arc.zip.clean", L10n("ZIP without Mac junk and dates", "ZIP без мусора Mac и дат"),
             L10n("No .DS_Store, ._ files or timestamps: safe to share and the same files always give the same archive.", "Без .DS_Store, файлов ._ и дат: безопасно передавать, а одни и те же файлы дают один и тот же архив."),
             op: "pack.zip", [ArchiveKeys.format: "zip", ArchiveKeys.excludeHidden: true, ArchiveKeys.keepDates: false]),
        pack("arc.targz.fast", L10n("TAR.GZ, fast", "TAR.GZ, быстро"), L10n("Light compression for backups and servers.", "Лёгкое сжатие для резервных копий и серверов."),
             op: "pack.tar.gz", [ArchiveKeys.format: "tar.gz", ArchiveKeys.level: 1]),
        pack("arc.7z", L10n("7z, small", "7z, компактно"), L10n("Smallest archives; needs 7-Zip or The Unarchiver on the other side.", "Самые маленькие архивы; на другой стороне нужен 7-Zip или The Unarchiver."),
             group: .smallSize, [ArchiveKeys.format: "7z", ArchiveKeys.level: 9]),
        pack("arc.tarzst", L10n("TAR.ZST, fast", "TAR.ZST, быстро"), L10n("Very fast with good compression.", "Очень быстро, с хорошим сжатием."), group: .smallSize,
             [ArchiveKeys.format: "tar.zst", ArchiveKeys.level: 3]),
        .builtin("arc.extract.safe", target: ArchiveSchemas.extractID, L10n("Extract safely", "Распаковать безопасно"),
                 notes: L10n("Smart placement, Windows-Russian names repaired, Mac system files skipped, unsafe paths refused.", "Умное размещение, русские имена из Windows исправляются, системные файлы Mac пропускаются, небезопасные пути отклоняются."),
                 symbol: "archivebox", group: .archive, operation: "archive.extract", [ArchiveKeys.extractTo: "smart", ArchiveKeys.nameEncoding: "auto", ArchiveKeys.excludeHidden: true])
    ]
}
