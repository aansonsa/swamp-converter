import Foundation
import Combine

// User customisation of the wheels: order and visibility per (wheel, file profile), plus global favourites.
// Muscle memory is the payoff of a radial menu, so positions are static: the same profile always yields the same
// order. Hidden operations are removed; favourites sort first among operations that have no explicit position.
// Persisted in wheel-layout.json.

/// Which "kind of selection" a layout belongs to. Mixed selections get their own layout.
enum WheelProfile: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, mixed, any
    /// Web links: the download wheel (`WheelKind.link`).
    case link

    var title: L10n {
        switch self {
        case .image: return L10n("Images", "Изображения")
        case .video: return L10n("Video", "Видео")
        case .audio: return L10n("Audio", "Аудио")
        case .pdf: return L10n("PDF", "PDF")
        case .document: return L10n("Documents", "Документы")
        case .slides: return L10n("Presentations", "Презентации")
        case .spreadsheet: return L10n("Spreadsheets", "Таблицы")
        case .subtitle: return L10n("Subtitles", "Субтитры")
        case .archive: return L10n("Archives", "Архивы")
        case .folder: return L10n("Folders", "Папки")
        case .mixed: return L10n("Mixed files", "Разные файлы")
        case .any: return L10n("Anything else", "Другие файлы")
        case .link: return L10n("Links", "Ссылки")
        }
    }

    /// Profile of a selection: one profile when all items share a kind (RAW counts as image), `.mixed` otherwise, `.any` for unknown files.
    static func profile(for items: [FileItem]) -> WheelProfile {
        let kinds = Set(items.map { $0.kind.isImageLike ? FileKind.image : $0.kind })
        guard kinds.count == 1, let k = kinds.first else { return items.isEmpty ? .any : .mixed }
        switch k {
        case .image, .raw: return .image
        case .video: return .video
        case .audio: return .audio
        case .pdf: return .pdf
        case .document: return .document
        case .slides: return .slides
        case .spreadsheet: return .spreadsheet
        case .subtitle: return .subtitle
        case .archive: return .archive
        case .folder: return .folder
        case .other: return .any
        }
    }
}

/// What the wheel view draws: one ring of up to 8 slots; when there are more operations, slot 8 becomes "More..."
/// which fans out `secondary` (at most 8). Depth is capped at 2.
struct WheelPages {
    var primary: [OperationEntry]
    var secondary: [OperationEntry]
    var hasMore: Bool { !secondary.isEmpty }
    /// Operations that did not fit in 7 + 8 slots (the Wheels editor warns about them).
    var dropped: Int
}

struct WheelLayoutData: Codable, Equatable, Sendable {
    var version = 1
    /// key "convert|image" -> operation ids in the user's order
    var order: [String: [String]] = [:]
    /// key -> hidden operation ids
    var hidden: [String: [String]] = [:]
    /// Starred operations (global, in star order).
    var favorites: [String] = []
}

final class WheelLayout: ObservableObject, @unchecked Sendable {
    static let shared = WheelLayout()
    static let maxPerRing = 8

    @Published private(set) var revision = 0
    private let lock = NSLock()
    private var _data = WheelLayoutData()
    private let fileURL: URL
    private let autosave: Bool

    var data: WheelLayoutData { lock.lock(); defer { lock.unlock() }; return _data }

    init(fileURL: URL? = nil, autosave: Bool = true) {
        self.fileURL = fileURL ?? AppPaths.layoutFile
        self.autosave = autosave
        reload()
    }

    static func key(_ wheel: WheelKind, _ profile: WheelProfile) -> String { "\(wheel.rawValue)|\(profile.rawValue)" }

    // MARK: Arranging

    /// Applies hidden / explicit order / favourites to already filtered entries. Stable: ties keep catalogue order.
    func arrange(_ entries: [OperationEntry], wheel: WheelKind, profile: WheelProfile) -> [OperationEntry] {
        let d = data
        let k = Self.key(wheel, profile)
        let hidden = Set(d.hidden[k] ?? [])
        let order = d.order[k] ?? []
        let orderIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let favIndex = Dictionary(d.favorites.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = entries.enumerated().filter { !hidden.contains($0.element.id) }
        let sorted = visible.sorted { a, b in
            let oa = orderIndex[a.element.id] ?? Int.max, ob = orderIndex[b.element.id] ?? Int.max
            if oa != ob { return oa < ob }
            let fa = favIndex[a.element.id] ?? Int.max, fb = favIndex[b.element.id] ?? Int.max
            if fa != fb { return fa < fb }
            return a.offset < b.offset
        }
        return sorted.map(\.element)
    }

    /// Splits an arranged list into the main ring and the "More..." ring.
    func pages(_ arranged: [OperationEntry]) -> WheelPages {
        let cap = Self.maxPerRing
        if arranged.count <= cap { return WheelPages(primary: arranged, secondary: [], dropped: 0) }
        let primary = Array(arranged.prefix(cap - 1))
        let rest = Array(arranged.dropFirst(cap - 1))
        let secondary = Array(rest.prefix(cap))
        return WheelPages(primary: primary, secondary: secondary, dropped: max(0, rest.count - cap))
    }

    /// Ids in the order the editor shows them for this (wheel, profile): the same sort as `arrange`, hidden ones last.
    func editorOrder(_ ops: [Operation], wheel: WheelKind, profile: WheelProfile) -> (visible: [String], hidden: [String]) {
        let entries = ops.map { OperationEntry(operation: $0, availability: .available) }
        let visible = arrange(entries, wheel: wheel, profile: profile).map(\.id)
        let hidden = Set(data.hidden[Self.key(wheel, profile)] ?? [])
        return (visible, ops.map(\.meta.id).filter { hidden.contains($0) })
    }

    // MARK: Editing

    func setOrder(_ ids: [String], wheel: WheelKind, profile: WheelProfile) {
        mutate { $0.order[Self.key(wheel, profile)] = ids }
    }

    func move(id: String, to newIndex: Int, in currentOrder: [String], wheel: WheelKind, profile: WheelProfile) {
        var ids = currentOrder
        guard let i = ids.firstIndex(of: id) else { return }
        ids.remove(at: i)
        ids.insert(id, at: Util.clamp(newIndex, 0, ids.count))
        setOrder(ids, wheel: wheel, profile: profile)
    }

    func isHidden(_ id: String, wheel: WheelKind, profile: WheelProfile) -> Bool {
        (data.hidden[Self.key(wheel, profile)] ?? []).contains(id)
    }

    /// Hiding an operation un-stars it; starring un-hides it everywhere it is hidden.
    func setHidden(_ hidden: Bool, id: String, wheel: WheelKind, profile: WheelProfile) {
        mutate { d in
            let k = Self.key(wheel, profile)
            var list = d.hidden[k] ?? []
            list.removeAll { $0 == id }
            if hidden { list.append(id); d.favorites.removeAll { $0 == id } }
            d.hidden[k] = list.isEmpty ? nil : list
        }
    }

    func isFavorite(_ id: String) -> Bool { data.favorites.contains(id) }

    func setFavorite(_ on: Bool, id: String) {
        mutate { d in
            d.favorites.removeAll { $0 == id }
            if on {
                d.favorites.append(id)
                for k in d.hidden.keys { d.hidden[k]?.removeAll { $0 == id }; if d.hidden[k]?.isEmpty == true { d.hidden[k] = nil } }
            }
        }
    }

    func reset(wheel: WheelKind, profile: WheelProfile) {
        mutate { d in let k = Self.key(wheel, profile); d.order[k] = nil; d.hidden[k] = nil }
    }

    func resetAll() { mutate { $0 = WheelLayoutData() } }

    // MARK: Persistence

    func reload() {
        var loaded = WheelLayoutData()
        if let bytes = try? Data(contentsOf: fileURL), let d = try? JSONDecoder().decode(WheelLayoutData.self, from: bytes) { loaded = d }
        lock.lock(); _data = loaded; lock.unlock()
        publish()
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? enc.encode(data) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: fileURL, options: .atomic)
    }

    private func mutate(_ change: (inout WheelLayoutData) -> Void) {
        lock.lock(); let before = _data; change(&_data); let changed = _data != before; lock.unlock()
        guard changed else { return }
        if autosave { save() }
        publish()
    }

    private func publish() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }
}
