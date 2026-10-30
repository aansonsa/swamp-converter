import Foundation

/// A named size limit. Numbers of real services change: they are data (editable, with a date in `note`), not logic.
struct SizeTarget: Identifiable, Hashable, Sendable {
    var id: String
    var name: L10n
    var bytes: Int64
    /// Kinds it makes sense for (video, audio, image, pdf).
    var kinds: Set<FileKind>
    var note: L10n?
    var symbol: String = "paperplane"
}

extension SizeTarget {
    static let customID = "custom"

    /// The limit in SI megabytes (1 MB = 1,000,000 bytes, the way Finder and every upload form count).
    var megabytes: Double { Double(bytes) / 1_000_000 }

    /// "WhatsApp (16 MB)": the name plus the limit, unless the name already carries a number ("Discord 10 MB") or the size is unknown (custom).
    var label: L10n {
        if id == Self.customID || name.en.contains(where: \.isNumber) { return name }
        return L10n("\(name.en) (\(Self.formatMB(megabytes, russian: false)))", "\(name.ru) (\(Self.formatMB(megabytes, russian: true)))")
    }

    /// Short file-name suffix: "WhatsApp", "Discord 10 MB". Safe as a component of `name (suffix).ext`.
    var suffix: L10n { L10n(Util.safeSuffix(name.en), Util.safeSuffix(name.ru)) }

    /// "16 MB" / "0,5 МБ" (one decimal at most, no trailing zero).
    static func formatMB(_ mb: Double, russian: Bool) -> String {
        // Under 1 MB two decimals ("0.05 MB"): a custom size of 50 KB must not read as "0.1 MB".
        let step = mb < 1 ? 100.0 : 10.0
        let rounded = (mb * step).rounded() / step
        var number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: mb < 1 ? "%.2f" : "%.1f", rounded)
        if number.contains("."), number.hasSuffix("0") { number.removeLast() }
        return russian ? number.replacingOccurrences(of: ".", with: ",") + " МБ" : number + " MB"
    }
}

enum SizeTargetCatalog {
    private static let all: Set<FileKind> = [.video, .audio, .image, .raw, .pdf]
    private static let media: Set<FileKind> = [.video, .audio, .image, .raw]
    private static let pictures: Set<FileKind> = [.image, .raw]

    /// WhatsApp, Telegram, Discord 10 / 25 / 50 MB, e-mail 20 / 25 MB, Instagram, a few "under N MB" web limits, plus "Custom" (id "custom", size from `FitKeys.customMB`).
    /// Sizes are SI megabytes (1,000,000 bytes), the way Finder and upload forms count; services that count in MiB are therefore met with a small margin.
    /// The numbers belong to the services and change: every note carries the date it was last checked (2026-10). Edit here, nothing else depends on them.
    /// The "custom" entry has `bytes == 0`: its size comes from the `customMB` option (see `bytes(forID:customMB:)`); it is listed last so pickers can offer it.
    static let presets: [SizeTarget] = [
        SizeTarget(id: "whatsapp", name: L10n("WhatsApp"), bytes: 16_000_000, kinds: media,
                   note: L10n("Checked 2026-10: videos, photos and voice messages sent as media are limited to about 16 MB. Documents can be much larger.",
                              "Проверено 2026-10: видео, фото и голосовые сообщения, отправляемые как медиа, ограничены примерно 16 МБ. Документы могут быть намного больше."),
                   symbol: "message"),
        SizeTarget(id: "telegram", name: L10n("Telegram"), bytes: 50_000_000, kinds: all,
                   note: L10n("Checked 2026-10: free accounts can send files up to 2 GB. 50 MB is the size bots and quick shares handle comfortably.",
                              "Проверено 2026-10: бесплатные аккаунты отправляют файлы до 2 ГБ. 50 МБ - размер, с которым комфортно работают боты и быстрая отправка."),
                   symbol: "paperplane"),
        SizeTarget(id: "telegramPhoto", name: L10n("Telegram photo", "Фото в Telegram"), bytes: 10_000_000, kinds: pictures,
                   note: L10n("Checked 2026-10: pictures sent as photos (not as files) are limited to 10 MB.",
                              "Проверено 2026-10: картинки, отправляемые как фото (не как файл), ограничены 10 МБ."),
                   symbol: "paperplane"),
        SizeTarget(id: "discord10", name: L10n("Discord 10 MB", "Discord 10 МБ"), bytes: 10_000_000, kinds: all,
                   note: L10n("Checked 2026-10: the free upload limit on Discord is 10 MB.", "Проверено 2026-10: бесплатный лимит загрузки в Discord - 10 МБ."),
                   symbol: "gamecontroller"),
        SizeTarget(id: "discord25", name: L10n("Discord 25 MB", "Discord 25 МБ"), bytes: 25_000_000, kinds: all,
                   note: L10n("Checked 2026-10: the former free limit; some servers and older clients still use it.",
                              "Проверено 2026-10: прежний бесплатный лимит; его ещё используют некоторые серверы и старые клиенты."),
                   symbol: "gamecontroller"),
        SizeTarget(id: "discord50", name: L10n("Discord 50 MB", "Discord 50 МБ"), bytes: 50_000_000, kinds: all,
                   note: L10n("Checked 2026-10: the limit with Nitro Basic and on boosted servers.", "Проверено 2026-10: лимит с Nitro Basic и на серверах с бустом."),
                   symbol: "gamecontroller"),
        SizeTarget(id: "email20", name: L10n("E-mail 20 MB", "Почта 20 МБ"), bytes: 20_000_000, kinds: all,
                   note: L10n("Checked 2026-10: a common limit of mail providers. Mail encoding adds about a third, so choose a smaller size if the provider counts the whole message.",
                              "Проверено 2026-10: распространённый лимит почтовых сервисов. Кодирование письма добавляет около трети, поэтому выбирайте меньше, если сервис считает всё письмо."),
                   symbol: "envelope"),
        SizeTarget(id: "email25", name: L10n("E-mail 25 MB", "Почта 25 МБ"), bytes: 25_000_000, kinds: all,
                   note: L10n("Checked 2026-10: the attachment limit of Gmail and several other providers. Larger files travel as a link.",
                              "Проверено 2026-10: лимит вложений в Gmail и у ряда других сервисов. Файлы больше уходят ссылкой."),
                   symbol: "envelope"),
        SizeTarget(id: "instagram", name: L10n("Instagram", "Instagram"), bytes: 30_000_000, kinds: [.video, .image, .raw],
                   note: L10n("Checked 2026-10: photos up to about 30 MB; the limit differs between feed, stories and messages and changes over time.",
                              "Проверено 2026-10: фото примерно до 30 МБ; предел различается для ленты, историй и сообщений и со временем меняется."),
                   symbol: "camera"),
        SizeTarget(id: "mb1", name: L10n("Under 1 MB", "До 1 МБ"), bytes: 1_000_000, kinds: [.image, .raw, .pdf],
                   note: L10n("Typical limit of web forms, profile pictures and job portals.", "Типичный лимит веб-форм, аватарок и порталов вакансий."),
                   symbol: "globe"),
        SizeTarget(id: "mb2", name: L10n("Under 2 MB", "До 2 МБ"), bytes: 2_000_000, kinds: [.image, .raw, .pdf],
                   note: L10n("Typical limit of web forms and CMS uploads.", "Типичный лимит веб-форм и загрузок в CMS."), symbol: "globe"),
        SizeTarget(id: "mb5", name: L10n("Under 5 MB", "До 5 МБ"), bytes: 5_000_000, kinds: [.image, .raw, .pdf],
                   note: L10n("Typical limit of government portals and application forms.", "Типичный лимит госпорталов и форм заявок."), symbol: "globe"),
        SizeTarget(id: SizeTarget.customID, name: L10n("Custom size…", "Свой размер…"), bytes: 0, kinds: all,
                   note: L10n("Any size in megabytes.", "Любой размер в мегабайтах."), symbol: "slider.horizontal.3")
    ]

    static func target(id: String) -> SizeTarget? { presets.first { $0.id == id } }

    /// The byte target for `id`, or `customMB` megabytes for "custom". nil for unknown ids.
    static func bytes(forID id: String, customMB: Double) -> Int64? {
        if id == "custom" { return customMB > 0 && customMB.isFinite ? Int64(customMB * 1_000_000) : nil }
        return target(id: id)?.bytes
    }

    static func presets(for kind: FileKind) -> [SizeTarget] { presets.filter { $0.kinds.contains(kind) } }

    /// The ready-made targets (no "custom") for `kind`: what the built-in presets are generated from.
    static func fixedTargets(for kind: FileKind) -> [SizeTarget] { presets(for: kind).filter { $0.id != SizeTarget.customID } }
}
