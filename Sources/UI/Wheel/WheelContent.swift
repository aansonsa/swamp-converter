import Foundation
import UniformTypeIdentifiers

// What the wheel shows: plain data built from the operation registry (which operations apply, in what order, which are dimmed). No UI here, so the same builder serves
// the live wheel, the snapshots and the tests.

/// One sector of the ring.
struct WheelSector: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// Run (or customise) this operation.
        case operation(String)
        /// "More..." and "Back": switch to the other ring page.
        case more, back
        /// "Choose in Studio..." on the link wheel.
        case studio
        /// The single sector of the repeat view.
        case repeatLast
    }

    var id: String
    var role: Role
    var title: L10n
    var subtitle: L10n?
    var symbol: String
    /// Format targets on the Convert wheel ("JPG", "TAR.GZ") are drawn as text only at 19 pt.
    var isFormatTile: Bool
    /// False = dimmed, not selectable (the tool it needs is missing); `hint` says what to install.
    var enabled = true
    var hint: L10n?
    var isFavorite = false

    var operationID: String? { if case .operation(let id) = role { return id } else { return nil } }
    var isPaging: Bool { role == .more || role == .back }

    /// The label rule of spec 19.15: Convert wheel, at most six characters, all upper case, at least one letter ("JPG", "PDF", "TAR.GZ", a preset named "JPG").
    static func isFormatLabel(_ label: String, wheel: WheelKind) -> Bool {
        wheel == .convert && label.count <= 6 && label == label.uppercased() && label.contains(where: \.isLetter)
    }
}

/// Everything the wheel needs to draw one presentation.
struct WheelContent: Equatable, Sendable {
    var wheel: WheelKind
    /// Ring pages: page 0 is the ring the person sees first (with "More..." in the last slot when there are more), page 1 the overflow plus "Back".
    var pages: [[WheelSector]]
    var isRepeatView = false
    /// Link wheel header.
    var linkTitle: String?
    var linkHost: String?
    /// Shown in the hub instead of the generic text when the ring is empty (nil = the default "Nothing for this selection").
    var emptyMessage: L10n?

    var first: [WheelSector] { pages.first ?? [] }
    var hasMore: Bool { pages.count > 1 }
    var isEmpty: Bool { first.isEmpty }
}

struct WheelContentBuilder {
    var registry: OperationRegistry = .shared
    var layout: WheelLayout = .shared
    var settings: SettingsData = AppSettings.shared.data
    var tools: ToolLocator = .shared

    // MARK: Files

    /// The ring of `wheel` for `items`: applicable operations in catalogue order, then the user's layout (hidden / order / favourites), 7 + "More..." and a second page of 8.
    func fileContent(items: [FileItem], wheel: WheelKind) -> WheelContent {
        guard !items.isEmpty else { return WheelContent(wheel: wheel, pages: [[]]) }
        let entries = registry.entries(wheel: wheel, items: items, tools: tools, settings: settings)
        let profile = WheelProfile.profile(for: items)
        let arranged = layout.arrange(entries, wheel: wheel, profile: profile)
        return paged(arranged, wheel: wheel)
    }

    /// The link wheel: download modes from the registry, then "Choose in Studio...". Headed by the page title and host.
    func linkContent(links: [LinkItem], pageTitle: String? = nil) -> WheelContent {
        let entries = registry.linkEntries(links: links, tools: tools, settings: settings)
        let arranged = layout.arrange(entries, wheel: .link, profile: .link)
        var content = paged(arranged, wheel: .link, trailing: [Self.studioSector])
        let first = links.first
        content.linkHost = first?.host
        content.linkTitle = (pageTitle?.isEmpty == false ? pageTitle : nil) ?? first?.title
        return content
    }

    static var studioSector: WheelSector {
        WheelSector(id: "studio", role: .studio, title: L10n("Choose in Studio…", "Выбрать в Студии…"), subtitle: L10n("all options", "все параметры"),
                    symbol: "slider.horizontal.3", isFormatTile: false)
    }

    /// The clipboard-image wheel: the operations `ClipboardSource.wheelOperationIDs` names, in that order, those that apply.
    func clipboardContent(item: FileItem, operationIDs: [String]) -> WheelContent {
        var entries: [OperationEntry] = []
        for id in operationIDs {
            guard let op = registry.operation(id: id), op.appliesTo([item]) else { continue }
            entries.append(OperationEntry(operation: op, availability: op.availability(for: [item], tools: tools)))
        }
        return paged(entries, wheel: .convert, applyFavorites: false)
    }

    /// The repeat view: one full-ring sector with the last operation, or an empty ring with the "doesn't fit" message.
    func repeatContent(last: Operation?, wheel: WheelKind) -> WheelContent {
        guard let last else {
            return WheelContent(wheel: wheel, pages: [[]], isRepeatView: true, emptyMessage: L10n("Last action doesn’t fit", "Последнее действие не подходит"))
        }
        let sector = WheelSector(id: "repeat", role: .repeatLast, title: last.meta.label, subtitle: last.meta.subtitle, symbol: "arrow.trianglehead.counterclockwise",
                                 isFormatTile: false)
        return WheelContent(wheel: wheel, pages: [[sector]], isRepeatView: true)
    }

    // MARK: Paging

    func paged(_ arranged: [OperationEntry], wheel: WheelKind, trailing: [WheelSector] = [], applyFavorites: Bool = true) -> WheelContent {
        let pages = layout.pages(arranged)
        let favorites = applyFavorites ? layout.data.favorites : []
        func sector(_ e: OperationEntry) -> WheelSector {
            let m = e.operation.meta
            return WheelSector(id: m.id, role: .operation(m.id), title: m.label, subtitle: m.subtitle, symbol: m.symbol,
                               isFormatTile: WheelSector.isFormatLabel(m.label.en, wheel: m.wheel) && WheelSector.isFormatLabel(m.label.ru, wheel: m.wheel),
                               enabled: e.availability.isAvailable, hint: e.availability.reason, isFavorite: favorites.contains(m.id))
        }
        var first = pages.primary.map(sector) + trailing
        var result: [[WheelSector]] = []
        if pages.hasMore {
            first += [WheelSector(id: "more", role: .more, title: L10n("More…", "Ещё…"), subtitle: nil, symbol: "ellipsis", isFormatTile: false)]
            var second = pages.secondary.map(sector)
            second += [WheelSector(id: "back", role: .back, title: L10n("Back", "Назад"), subtitle: nil, symbol: "chevron.backward", isFormatTile: false)]
            result = [Self.slotted(first, favorites: favorites, fixedLast: true), Self.slotted(second, favorites: favorites, fixedLast: true)]
        } else {
            result = [Self.slotted(first, favorites: favorites, fixedLast: false)]
        }
        return WheelContent(wheel: wheel, pages: result)
    }

    /// Puts favourites on the axes when the ring has them (see `WheelSlotting`).
    static func slotted(_ sectors: [WheelSector], favorites: [String], fixedLast: Bool) -> [WheelSector] {
        let order = WheelSlotting.slotOrder(ids: sectors.map(\.id), favorites: favorites, fixedLast: fixedLast)
        let byID = Dictionary(sectors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byID[$0] }
    }
}

// MARK: - Hub summary

/// What the hub says about the dropped items while no sector is hovered: up to three fanned icons and a count line.
struct WheelInputSummary: Equatable, Sendable {
    enum Icon: Equatable, Sendable { case file(URL), type(UTType), symbol(String) }
    var icons: [Icon] = []
    /// "photo.jpg", "12 images", "9 images · 2 PDFs · 1 video".
    var text = ""
    var count = 0
    var isLinks = false

    static let empty = WheelInputSummary()

    static func make(_ input: IncomingInput) -> WheelInputSummary {
        if !input.files.isEmpty { return make(files: input.files) }
        if let link = input.links.first {
            return WheelInputSummary(icons: [.symbol("link")], text: input.links.count == 1 ? link.host : Loc.plural(input.links.count, enOne: "\(input.links.count) link", enOther: "\(input.links.count) links", ruOne: "\(input.links.count) ссылка", ruFew: "\(input.links.count) ссылки", ruMany: "\(input.links.count) ссылок"), count: input.links.count, isLinks: true)
        }
        return .empty
    }

    static func make(files: [FileItem]) -> WheelInputSummary {
        guard !files.isEmpty else { return .empty }
        let icons: [Icon] = files.prefix(3).map { f in
            if FileManager.default.fileExists(atPath: f.url.path) { return .file(f.url) }
            if f.isDirectory { return .type(.folder) }
            return .type(UTType(filenameExtension: f.url.pathExtension) ?? .data)
        }
        let text = files.count == 1 ? files[0].name : kindSummary(files)
        return WheelInputSummary(icons: icons, text: text, count: files.count)
    }

    /// "12 images" for one kind, "9 images · 2 PDFs · 1 video" for several (at most three kinds, then an ellipsis).
    static func kindSummary(_ files: [FileItem]) -> String {
        var counts: [FileKind: Int] = [:]
        var order: [FileKind] = []
        for f in files {
            let k: FileKind = f.kind == .raw ? .image : f.kind
            if counts[k] == nil { order.append(k) }
            counts[k, default: 0] += 1
        }
        if order.count == 1, let k = order.first, k == .other || k == .folder { return k == .folder ? folderPhrase(files.count) : Loc.files(files.count) }
        let parts = order.prefix(3).map { kindPhrase($0, counts[$0] ?? 0) }
        return parts.joined(separator: " \u{00B7} ") + (order.count > 3 ? " \u{2026}" : "")
    }

    static func folderPhrase(_ n: Int) -> String {
        Loc.plural(n, enOne: "\(n) folder", enOther: "\(n) folders", ruOne: "\(n) папка", ruFew: "\(n) папки", ruMany: "\(n) папок")
    }

    /// "1 image / 5 images", "1 PDF / 3 PDFs", Russian one / few / many.
    static func kindPhrase(_ k: FileKind, _ n: Int) -> String {
        func p(_ eo: String, _ ee: String, _ ro: String, _ rf: String, _ rm: String) -> String {
            Loc.plural(n, enOne: "\(n) \(eo)", enOther: "\(n) \(ee)", ruOne: "\(n) \(ro)", ruFew: "\(n) \(rf)", ruMany: "\(n) \(rm)")
        }
        switch k {
        case .image, .raw: return p("image", "images", "изображение", "изображения", "изображений")
        case .audio: return p("audio file", "audio files", "аудиофайл", "аудиофайла", "аудиофайлов")
        case .video: return p("video", "videos", "видео", "видео", "видео")
        case .pdf: return p("PDF", "PDFs", "PDF", "PDF", "PDF")
        case .document: return p("document", "documents", "документ", "документа", "документов")
        case .slides: return p("presentation", "presentations", "презентация", "презентации", "презентаций")
        case .spreadsheet: return p("spreadsheet", "spreadsheets", "таблица", "таблицы", "таблиц")
        case .subtitle: return p("subtitle file", "subtitle files", "файл субтитров", "файла субтитров", "файлов субтитров")
        case .archive: return p("archive", "archives", "архив", "архива", "архивов")
        case .folder: return folderPhrase(n)
        case .other: return Loc.files(n)
        }
    }
}
