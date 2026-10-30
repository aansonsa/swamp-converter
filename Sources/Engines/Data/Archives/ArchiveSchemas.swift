import Foundation

/// The archive schemas (spec/handbrake.md 3.7): `archive.extract` (where, names, dates, clean-up) and `archive.pack` (format, level, what goes in, folders, dates, check).
/// Every field has an oracle id (proven by `DataTestsArchives`). Works for an empty `items` array.
enum ArchiveSchemas {
    static let extractID = "archive.extract"
    static let packID = "archive.pack"
    private typealias K = ArchiveKeys

    private static func oneOf(_ key: String, _ values: String...) -> OptionExpr { .in(key, values.map { .string($0) }) }

    // MARK: Extract

    static func extract(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: extractID, title: L10n("Extract", "Распаковка"), symbol: "archivebox", pages: [
            OptionPage.make("where", symbol: "folder", L10n("Where", "Куда"), [
                OptionGroup.make("where.main", [
                    .segmented(K.extractTo, L10n("Put the contents", "Куда положить содержимое"), [
                        FieldOption("smart", L10n("Smart", "Умно")),
                        FieldOption("folder", L10n("In a folder", "В папку")),
                        FieldOption("here", L10n("Next to the archive", "Рядом с архивом"))
                    ], def: "smart")
                        .basic()
                        .help(L10n("Smart: one file or folder comes out as it is, several items go into a folder named like the archive. Next to the archive: every item separately, no folder.",
                                   "Умно: один файл или папка выходит как есть, несколько элементов попадают в папку с именем архива. Рядом с архивом: каждый элемент отдельно, без папки."))
                        .aliases(["destination", "folder", "куда", "папка"]).oracle("arc.extract.layout"),
                    .picker(K.overwrite, L10n("If a name is taken", "Если имя занято"), [
                        FieldOption("number", L10n("Add a number", "Добавить номер")),
                        FieldOption("skip", L10n("Skip it", "Пропустить")),
                        FieldOption("replace", L10n("Replace (old one goes to the Trash)", "Заменить (старый уйдёт в Корзину)"))
                    ], def: "number")
                        .standard().visible(.eq(K.extractTo, "here")).oracle("arc.overwrite.policy"),
                    .toggle(K.flatten, L10n("Put all files in one folder", "Сложить все файлы в одну папку"))
                        .standard().help(L10n("Sub-folders are not created; files with the same name get a number.", "Подпапки не создаются; файлы с одинаковыми именами получают номер."))
                        .oracle("arc.flatten.layout"),
                    .toggle(K.deleteAfter, L10n("Move the archive to the Trash afterwards", "После распаковки переместить архив в Корзину"))
                        .standard().oracle("arc.trash.source")
                ])
            ]),
            OptionPage.make("names", symbol: "textformat", L10n("Names and files", "Имена и файлы"), [
                OptionGroup.make("names.main", [
                    .picker(K.nameEncoding, L10n("File names in ZIP archives", "Имена файлов в ZIP"), [
                        FieldOption("auto", L10n("Detect automatically", "Определить автоматически")),
                        FieldOption("utf-8", "UTF-8"),
                        FieldOption("cp866", L10n("CP866 (DOS, Windows Russian)", "CP866 (DOS, русский Windows)")),
                        FieldOption("cp1251", L10n("Windows-1251", "Windows-1251")),
                        FieldOption("cp437", L10n("CP437 (DOS Western)", "CP437 (DOS, западная)"))
                    ], def: "auto")
                        .basic()
                        .help(L10n("Archives made by older Windows programs store Russian names in CP866 or Windows-1251, and other tools show them as gibberish. Automatic detection fixes it; choose one if the letters still look wrong.",
                                   "Архивы старых программ Windows хранят русские имена в CP866 или Windows-1251, а другие инструменты показывают их как кракозябры. Автоопределение это исправляет; выберите вручную, если буквы всё ещё неверны."))
                        .aliases(["encoding", "кодировка", "cp866", "кракозябры", "mojibake"]).oracle("arc.names.decode"),
                    .toggle(K.excludeHidden, L10n("Skip Mac system files", "Пропускать системные файлы Mac"), def: true)
                        .standard().help(L10n("__MACOSX folders, ._ files and .DS_Store that Mac archives carry along are left out.", "Папки __MACOSX, файлы ._ и .DS_Store, которые тянут за собой архивы с Mac, не распаковываются."))
                        .oracle("arc.junk.skipped"),
                    .toggle(K.keepDates, L10n("Restore modification dates", "Восстановить даты изменения"), def: true)
                        .standard().oracle("arc.dates.restore"),
                    .toggle(K.permissions, L10n("Restore permissions", "Восстановить права доступа"), def: true)
                        .standard().help(L10n("Scripts and programs stay executable.", "Скрипты и программы остаются исполняемыми.")).oracle("arc.perms.restore")
                ])
            ])
        ])
    }

    // MARK: Pack

    private static let compressed = oneOf(K.format, "zip", "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "7z")

    static func pack(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: packID, title: L10n("Archive", "Архив"), symbol: "archivebox", pages: [
            OptionPage.make("format", symbol: "archivebox", L10n("Format", "Формат"), [
                OptionGroup.make("format.main", [
                    .picker(K.format, L10n("Archive type", "Тип архива"), [
                        FieldOption("zip", L10n("ZIP (opens everywhere)", "ZIP (открывается везде)")),
                        FieldOption("tar", L10n("TAR (no compression)", "TAR (без сжатия)")),
                        FieldOption("tar.gz", L10n("TAR.GZ", "TAR.GZ")),
                        FieldOption("tar.bz2", L10n("TAR.BZ2", "TAR.BZ2"), requires: ["native.archive.write.bz2"]),
                        FieldOption("tar.xz", L10n("TAR.XZ (smaller)", "TAR.XZ (меньше)"), requires: ["native.archive.write.xz"]),
                        FieldOption("tar.zst", L10n("TAR.ZST (fast)", "TAR.ZST (быстро)"), requires: ["native.archive.write.zst"]),
                        FieldOption("7z", L10n("7-Zip", "7-Zip"), requires: ["native.archive.write.7z"])
                    ], def: "zip")
                        .basic()
                        .help(L10n("ZIP opens on every computer. 7z and XZ make smaller files; ZST is very fast. Names are stored as Unicode.", "ZIP открывается на любом компьютере. 7z и XZ дают файлы меньше, ZST очень быстрый. Имена хранятся в Юникоде."))
                        .aliases(["format", "формат", "zip", "7z", "tar"]).oracle("arc.format.sniff"),
                    .slider(K.level, L10n("Compression", "Сжатие"), min: 0, max: 9, def: 6,
                            minLabel: L10n("None (fastest)", "Нет (быстрее)"), maxLabel: L10n("Smallest", "Минимум размера"))
                        .basic().visible(compressed).affects([.estimate, .plan])
                        .help(L10n("0 stores the files without compressing them. Photos, music and video are stored as they are in ZIP: they do not shrink anyway.",
                                   "0 кладёт файлы без сжатия. Фото, музыка и видео в ZIP кладутся как есть: они всё равно не сжимаются."))
                        .aliases(["level", "compression", "сжатие", "уровень"]).oracle("arc.level.size"),
                    .toggle(K.verify, L10n("Check the archive before saving", "Проверить архив перед сохранением"), def: true)
                        .standard().help(L10n("Reads the finished archive back and compares the number of items.", "Читает готовый архив и сверяет число элементов.")).oracle("arc.verify.log")
                ])
            ]),
            OptionPage.make("content", symbol: "doc.on.doc", L10n("What goes in", "Что включить"), [
                OptionGroup.make("content.filter", [
                    .toggle(K.excludeHidden, L10n("Leave out Mac system files", "Не включать системные файлы Mac"), def: true)
                        .basic().help(L10n(".DS_Store, ._ sidecar files, __MACOSX, Spotlight and Trash folders. Folders from external drives are full of them.", ".DS_Store, служебные файлы ._, __MACOSX, папки Spotlight и Корзины. Папки с внешних дисков полны такого."))
                        .oracle("arc.exclude.listing"),
                    .toggle(K.includeHidden, L10n("Include hidden files", "Включать скрытые файлы"), def: true)
                        .standard().help(L10n("Files whose name starts with a dot.", "Файлы, имя которых начинается с точки.")).oracle("arc.hidden.listing"),
                    .text(K.excludePatterns, L10n("Also leave out", "Ещё не включать"), placeholder: L10n("*.tmp, node_modules", "*.tmp, node_modules"))
                        .standard().help(L10n("Names or patterns separated by commas: * matches any characters, ? one character.", "Имена или шаблоны через запятую: * заменяет любые символы, ? один символ."))
                        .oracle("arc.patterns.listing")
                ]),
                OptionGroup.make("content.layout", L10n("Folders and names", "Папки и имена"), [
                    .segmented(K.rootFolder, L10n("Top level", "Верхний уровень"), [
                        FieldOption("keep", L10n("As dropped", "Как выбрано")),
                        FieldOption("add", L10n("In a new folder", "В новой папке")),
                        FieldOption("strip", L10n("Contents only", "Только содержимое"))
                    ], def: "keep")
                        .standard().help(L10n("As dropped: files and folders keep their names. In a new folder: everything sits inside one folder named like the archive (a single dropped folder already is one). Contents only: the files of dropped folders without the folder itself.",
                                              "Как выбрано: файлы и папки сохраняют имена. В новой папке: всё лежит в одной папке с именем архива (одна выбранная папка уже такая). Только содержимое: файлы выбранных папок без самой папки."))
                        .oracle("arc.root.listing"),
                    .toggle(K.normalise, L10n("Fix accents for Windows (Unicode NFC)", "Исправить диакритику для Windows (Unicode NFC)"), def: true)
                        .standard().help(L10n("Mac stores accented letters as two characters; Windows shows them apart from the letter unless the name is normalized.",
                                              "Mac хранит буквы с диакритикой из двух символов; Windows показывает их отдельно от буквы, если имя не нормализовано."))
                        .oracle("arc.nfc.names"),
                    .toggle(K.keepDates, L10n("Keep modification dates", "Сохранить даты изменения"), def: true)
                        .standard().help(L10n("Off writes 1 January 1980 for every item: no dates leave your Mac and the same files always give the same archive.",
                                              "Если выключено, у всех элементов дата 1 января 1980: даты не выходят с вашего Mac, а одни и те же файлы дают один и тот же архив."))
                        .oracle("arc.dates.mtime")
                ])
            ])
        ])
    }
}
