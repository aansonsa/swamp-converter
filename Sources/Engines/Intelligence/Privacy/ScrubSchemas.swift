import Foundation

enum ScrubKeys {
    static let removeGPS = "scrub.gps"
    static let removeCamera = "scrub.camera"
    static let removeDates = "scrub.dates"
    static let removeAuthor = "scrub.author"
    static let removeAll = "scrub.all"
    static let keepColorProfile = "scrub.profile"
    static let keepOrientation = "scrub.orientation"
}

enum ScrubSchemas {
    static let imageID = "scrub.image", videoID = "scrub.video", audioID = "scrub.audio", pdfID = "scrub.pdf"
    static let allIDs = [imageID, videoID, audioID, pdfID]

    /// One schema per kind. The quick recipe ("share-safe") equals the defaults: location, camera, lens, serial numbers and software out; dates and author
    /// stay; the picture looks exactly as before. Every field has an oracle (see `IntelligenceScrubTests`).
    static func schema(id: String) -> OptionSchema {
        let isImage = id == imageID, isPDF = id == pdfID, isAudio = id == audioID
        let everythingOff = OptionExpr.ne(ScrubKeys.removeAll, true)

        let cameraLabel: L10n = isPDF ? L10n("Creating program", "Программа, создавшая файл")
            : (isAudio ? L10n("Device and software", "Устройство и программа") : L10n("Camera, lens and software", "Камера, объектив и программа"))
        let cameraHelp: L10n = isPDF
            ? L10n("Removes the Creator and Producer entries, which name the program and the macOS version that made the file.",
                   "Убирает поля «Создатель» и «Производитель»: они называют программу и версию macOS, создавшие файл.")
            : (isAudio
               ? L10n("Removes the recording device, its serial numbers and the encoder name.", "Убирает устройство записи, серийные номера и название кодировщика.")
               : L10n("Removes make, model, lens, serial numbers, maker notes, the embedded preview and the name of the software.",
                      "Убирает производителя, модель, объектив, серийные номера, служебные данные, встроенный эскиз и название программы."))

        var fields: [OptionField] = []
        if !isPDF {
            fields.append(.toggle(ScrubKeys.removeGPS, L10n("Location (GPS)", "Геопозиция (GPS)"), def: true).basic()
                .help(L10n("Removes where the file was made: coordinates, altitude, city and country tags.", "Убирает место создания файла: координаты, высоту, город и страну."))
                .enabled(everythingOff, reason: L10n("Everything is removed already.", "Уже удаляется всё.")).affects([.plan]).oracle("scrub.gps.removed"))
        }
        fields.append(.toggle(ScrubKeys.removeCamera, cameraLabel, def: true).basic().help(cameraHelp)
            .enabled(everythingOff, reason: L10n("Everything is removed already.", "Уже удаляется всё.")).affects([.plan]).oracle("scrub.camera.removed"))
        fields.append(.toggle(ScrubKeys.removeDates, L10n("Dates", "Даты"), def: false).basic()
            .help(L10n("Removes the time the file was taken, created or changed.", "Убирает время съёмки, создания и изменения файла."))
            .enabled(everythingOff, reason: L10n("Everything is removed already.", "Уже удаляется всё.")).affects([.plan]).oracle("scrub.dates.removed"))
        fields.append(.toggle(ScrubKeys.removeAuthor, L10n("Author and copyright", "Автор и авторские права"), def: false).standard()
            .help(L10n("Removes the artist, owner and copyright fields.", "Убирает поля исполнителя, владельца и авторских прав."))
            .enabled(everythingOff, reason: L10n("Everything is removed already.", "Уже удаляется всё.")).affects([.plan]).oracle("scrub.author.removed"))

        var groups: [OptionGroup] = [
            .make("what", L10n("Remove", "Удалить"), footer: L10n("The original is never changed: you get a copy named “… (clean)”.", "Оригинал не изменяется: вы получаете копию с пометкой «… (чисто)»."), fields),
            .make("all", [
                .toggle(ScrubKeys.removeAll, L10n("Remove all metadata", "Удалить все метаданные"), def: false).standard()
                    .help(L10n("Also removes titles, comments, embedded previews, cover art, chapters and every other tag.", "Также убирает названия, комментарии, встроенные эскизы, обложки, главы и все остальные теги."))
                    .affects([.plan]).oracle("scrub.all.removed")
            ])
        ]
        if isImage {
            groups.append(.make("picture", L10n("Picture", "Изображение"), footer: L10n("Pixels are copied without re-compression whenever the picture does not need to change.",
                                                                                      "Пиксели копируются без повторного сжатия, если изображение менять не нужно."), [
                .toggle(ScrubKeys.keepOrientation, L10n("Turn the picture upright", "Повернуть изображение вертикально"), def: true).standard()
                    .help(L10n("Applies the rotation stored in the file to the pixels, so the picture looks the same after the tag is gone.",
                               "Применяет сохранённый в файле поворот к пикселям, чтобы после удаления тега картинка выглядела так же."))
                    .affects([.plan]).oracle("scrub.orientation.baked"),
                .toggle(ScrubKeys.keepColorProfile, L10n("Keep the color profile", "Сохранить цветовой профиль"), def: true).standard()
                    .help(L10n("Off converts the colors to sRGB and drops the profile.", "Выключено: цвета переводятся в sRGB, профиль удаляется."))
                    .affects([.plan]).oracle("scrub.profile.kept")
            ]))
        }
        let title: L10n
        switch id {
        case imageID: title = L10n("Share-safe picture", "Безопасное изображение")
        case videoID: title = L10n("Share-safe video", "Безопасное видео")
        case audioID: title = L10n("Share-safe audio", "Безопасное аудио")
        default: title = L10n("Share-safe PDF", "Безопасный PDF")
        }
        return OptionSchema(id: id, title: title, symbol: "hand.raised", pages: [
            .make("scrub", symbol: "hand.raised", L10n("Privacy", "Конфиденциальность"), groups)
        ])
    }
}
