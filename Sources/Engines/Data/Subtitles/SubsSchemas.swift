import Foundation

/// The `subs.convert` schema (spec/handbrake.md 3.5): Format, Text and encoding, Timing, Clean-up. Every field has an oracle id (proven by `DataTestsSubs`);
/// defaults equal the quick recipes of `SubsCatalog`. Works for an empty `items` array.
enum SubsSchemas {
    static let convertID = "subs.convert"
    private typealias K = SubsKeys

    static let fpsOptions: [FieldOption] = [FieldOption("off", L10n("Unchanged", "Без изменений")), FieldOption("23.976", "23.976"), FieldOption("24", "24"), FieldOption("25", "25"),
                                            FieldOption("29.97", "29.97"), FieldOption("30", "30"), FieldOption("50", "50"), FieldOption("59.94", "59.94"), FieldOption("60", "60")]

    private static func encodings(auto: Bool) -> [FieldOption] {
        var o: [FieldOption] = []
        if auto { o.append(FieldOption("auto", L10n("Detect automatically", "Определить автоматически"))) }
        o += [FieldOption("utf-8", "UTF-8"), FieldOption("utf-16", "UTF-16"),
              FieldOption("windows-1251", L10n("Windows-1251 (Cyrillic)", "Windows-1251 (кириллица)")),
              FieldOption("windows-1257", L10n("Windows-1257 (Baltic)", "Windows-1257 (балтийская)")),
              FieldOption("windows-1250", L10n("Windows-1250 (Central European)", "Windows-1250 (центральноевропейская)")),
              FieldOption("windows-1252", L10n("Windows-1252 (Western European)", "Windows-1252 (западноевропейская)")),
              FieldOption("koi8-r", "KOI8-R"), FieldOption("cp866", L10n("CP866 (DOS Cyrillic)", "CP866 (DOS, кириллица)"))]
        return o
    }

    static func convert(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: convertID, title: L10n("Subtitles", "Субтитры"), symbol: "captions.bubble", pages: [formatPage, textPage, timingPage, cleanupPage], rules: rules)
    }

    private static var formatPage: OptionPage {
        OptionPage.make("format", symbol: "captions.bubble", L10n("Format", "Формат"), [
            OptionGroup.make("format.main", [
                .picker(K.format, L10n("Convert to", "Конвертировать в"), [
                    FieldOption("srt", L10n("SubRip (SRT)", "SubRip (SRT)")),
                    FieldOption("vtt", L10n("WebVTT (VTT)", "WebVTT (VTT)")),
                    FieldOption("ass", L10n("Advanced SubStation Alpha (ASS)", "Advanced SubStation Alpha (ASS)")),
                    FieldOption("ssa", L10n("SubStation Alpha (SSA)", "SubStation Alpha (SSA)")),
                    FieldOption("sbv", L10n("YouTube (SBV)", "YouTube (SBV)")),
                    FieldOption("txt", L10n("Plain text (no times)", "Простой текст (без времени)"))
                ], def: "srt")
                    .basic()
                    .help(L10n("SRT works nearly everywhere, VTT is for web players. ASS and SSA are written with a simple default style. Plain text keeps only the words.",
                               "SRT работает почти везде, VTT нужен веб-плеерам. ASS и SSA записываются с простым стилем по умолчанию. Простой текст сохраняет только слова."))
                    .aliases(["format", "формат", "srt", "vtt", "ass"]).oracle("subs.format.sniff"),
                .segmented(K.txtJoin, L10n("Text layout", "Раскладка текста"), [
                    FieldOption("cue", L10n("One line per cue", "Строка на реплику")),
                    FieldOption("paragraphs", L10n("Paragraphs", "Абзацы"))
                ], def: "cue")
                    .standard().visible(.eq(K.format, "txt"))
                    .help(L10n("Paragraphs start where the pause between two cues is longer than 2 seconds.", "Новый абзац начинается там, где пауза между репликами длиннее 2 секунд."))
                    .oracle("subs.txt.join.lines")
            ])
        ])
    }

    private static var textPage: OptionPage {
        OptionPage.make("text", symbol: "textformat", L10n("Text and encoding", "Текст и кодировка"), [
            OptionGroup.make("text.main", [
                .picker(K.encodingIn, L10n("Encoding of the source", "Кодировка исходника"), encodings(auto: true), def: "auto")
                    .basic()
                    .help(L10n("Automatic detection reads a byte order mark, then UTF-8, then guesses Windows-1251, KOI8-R, CP866, Baltic or Central European text. Choose one when letters look wrong.",
                               "Автоопределение учитывает BOM, затем UTF-8, затем угадывает Windows-1251, KOI8-R, CP866, балтийскую или центральноевропейскую кодировку. Выберите вручную, если буквы выглядят неверно."))
                    .aliases(["encoding", "кодировка", "cp1251", "1251", "koi8", "кракозябры", "mojibake"]).oracle("subs.enc.in.decode"),
                .picker(K.encodingOut, L10n("Encoding of the result", "Кодировка результата"), encodings(auto: false), def: "utf-8")
                    .basic()
                    .help(L10n("UTF-8 is right for nearly every player. Older TVs and players may need Windows-1251 or Windows-1257.",
                               "UTF-8 подходит почти всем плеерам. Старым телевизорам и плеерам может понадобиться Windows-1251 или Windows-1257."))
                    .oracle("subs.enc.out.bytes"),
                .toggle(K.bom, L10n("Add a byte order mark (BOM)", "Добавить метку порядка байтов (BOM)"))
                    .standard().visible(.eq(K.encodingOut, "utf-8"))
                    .help(L10n("A few Windows programs need it to recognize UTF-8. UTF-16 always has one.", "Некоторым программам Windows она нужна, чтобы распознать UTF-8. В UTF-16 она есть всегда."))
                    .oracle("subs.bom.bytes"),
                .segmented(K.eol, L10n("Line endings", "Концы строк"), [
                    FieldOption("auto", L10n("Automatic", "Авто")),
                    FieldOption("lf", "LF"), FieldOption("crlf", "CRLF")
                ], def: "auto")
                    .expert().help(L10n("Automatic uses CRLF for SRT and LF for the other formats.", "Авто: CRLF для SRT и LF для остальных форматов."))
                    .oracle("subs.eol.bytes")
            ])
        ])
    }

    private static var timingPage: OptionPage {
        OptionPage.make("timing", symbol: "clock", L10n("Timing", "Время"), [
            OptionGroup.make("timing.shift", L10n("Shift", "Сдвиг"), [
                .number(K.offset, L10n("Shift all cues by", "Сдвинуть все реплики на"), min: -36_000, max: 36_000, step: 0.1, def: 0, unit: "s", decimals: 3)
                    .basic().visible(.not(.eq(K.format, "txt")))
                    .help(L10n("Positive values show the text later, negative earlier. Cues that would end before 0:00 are dropped.",
                               "Положительное значение показывает текст позже, отрицательное - раньше. Реплики, которые закончились бы до 0:00, удаляются."))
                    .aliases(["offset", "shift", "sync", "сдвиг", "синхронизация"]).oracle("subs.offset.timing"),
                .picker(K.fpsFrom, L10n("Frame rate of the subtitles", "Частота кадров субтитров"), fpsOptions, def: "off")
                    .standard().visible(.not(.eq(K.format, "txt")))
                    .help(L10n("Fixes drift when the video was re-timed: choose the frame rate the subtitles were made for and the frame rate of your video.",
                               "Исправляет уход, если видео изменило скорость: выберите частоту кадров, для которой сделаны субтитры, и частоту вашего видео."))
                    .aliases(["fps", "frame rate", "drift", "кадры", "уход"]).oracle("subs.fps.timing"),
                .picker(K.fpsTo, L10n("Frame rate of the video", "Частота кадров видео"), fpsOptions, def: "off")
                    .standard().visible(.not(.eq(K.format, "txt")))
                    .enabled(.ne(K.fpsFrom, "off"), reason: L10n("Choose the frame rate of the subtitles first.", "Сначала выберите частоту кадров субтитров."))
                    .oracle("subs.fps.timing")
            ]),
            OptionGroup.make("timing.fix", L10n("Repair", "Исправление"), visible: .not(.eq(K.format, "txt")), [
                .toggle(K.overlap, L10n("Fix overlapping cues", "Исправить пересекающиеся реплики"))
                    .standard().help(L10n("A cue that runs into the next one ends where the next begins. Cues are sorted by time.", "Реплика, заходящая на следующую, заканчивается там, где начинается следующая. Реплики сортируются по времени."))
                    .oracle("subs.overlap.timing")
            ])
        ])
    }

    private static var cleanupPage: OptionPage {
        OptionPage.make("cleanup", symbol: "wand.and.sparkles", L10n("Clean-up", "Очистка"), [
            OptionGroup.make("cleanup.text", [
                .toggle(K.removeTags, L10n("Remove formatting tags", "Убрать теги форматирования"))
                    .basic().help(L10n("Removes <i>, <b>, <font>, voice and class tags and ASS codes such as {\\an8}. Plain text always has them removed.",
                                       "Убирает теги <i>, <b>, <font>, голоса и классы, а также коды ASS вроде {\\an8}. В простом тексте они убираются всегда."))
                    .oracle("subs.tags.text"),
                .toggle(K.removeSDH, L10n("Remove sound descriptions", "Убрать описания звуков"))
                    .basic().help(L10n("Removes [music], (door slams), lines with music notes and speaker labels such as JOHN: . Cues left empty disappear.",
                                       "Убирает [музыка], (хлопок двери), строки с нотами и подписи говорящих вроде ИВАН: . Пустые реплики удаляются."))
                    .oracle("subs.sdh.text"),
                .toggle(K.mergeShort, L10n("Join flickering short cues", "Склеить мерцающие короткие реплики"))
                    .standard().visible(.not(.eq(K.format, "txt")))
                    .help(L10n("A very short cue that is followed at once by another one is joined with it; no text is lost.", "Очень короткая реплика, за которой сразу идёт следующая, склеивается с ней; текст не теряется."))
                    .oracle("subs.merge.cues"),
                .number(K.mergeMin, L10n("Shorter than", "Короче чем"), min: 0.1, max: 5, step: 0.1, def: 0.7, unit: "s", decimals: 1)
                    .expert().visible(.all([.isSet(K.mergeShort), .not(.eq(K.format, "txt"))])).oracle("subs.merge.min")
            ])
        ])
    }

    private static var rules: [ValidationRule] {
        [
            .warning("subs.fps.same", when: .all([.ne(K.fpsFrom, "off"), .ne(K.fpsTo, "off")]).evaluateSame(K.fpsFrom, K.fpsTo),
                     L10n("Both frame rates are the same, so the timing will not change.", "Частоты кадров одинаковы, время не изменится."), field: K.fpsTo)
        ]
    }
}

private extension OptionExpr {
    /// `self` AND the two keys hold the same value (OptionExpr has no key-to-key comparison).
    func evaluateSame(_ a: String, _ b: String) -> OptionExpr {
        .any(SubsSchemas.fpsOptions.map { o in .all([self, .eq(a, .string(o.value)), .eq(b, .string(o.value))]) })
    }
}
