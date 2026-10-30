import Foundation
import SwiftUI

// The logic behind the wheel layout editor (no drawing): which operations an editor list shows for a (wheel, kind) pair, how they map to the 7 + 8 slots of the ring,
// reordering, hiding, starring and resetting. Everything is written through `WheelLayout`, which the wheel itself reads, so an edit is live at once.

/// Representative selections of each kind of file: the editor lists an operation when the wheel would offer it for at least one of them.
enum LayoutSamples {
    static func sets(for profile: WheelProfile) -> [[FileItem]] {
        func file(_ ext: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/sample/file." + ext), isDirectory: false) }
        func many(_ exts: [String]) -> [[FileItem]] { exts.map { [file($0)] } }
        switch profile {
        case .image: return many(["jpg", "png", "heic", "webp", "tiff", "gif", "bmp"])
        case .video: return many(["mp4", "mov", "mkv", "avi", "webm"])
        case .audio: return many(["mp3", "wav", "m4a", "flac", "ogg"])
        case .pdf: return many(["pdf"])
        case .document: return many(["docx", "txt", "md", "html", "rtf", "odt"])
        case .slides: return many(["pptx", "odp", "key"])
        case .spreadsheet: return many(["xlsx", "csv", "xls", "ods"])
        case .subtitle: return many(["srt", "vtt", "ass"])
        case .archive: return many(["zip", "tar", "tar.gz", "7z"])
        case .folder: return [[FileItem(url: URL(fileURLWithPath: "/sample/folder", isDirectory: true), isDirectory: true)]]
        case .mixed: return [[file("jpg"), file("mp4")], [file("pdf"), file("docx")], [file("mp3"), file("png")]]
        case .any: return many(["xyz"])
        case .link: return []
        }
    }
}

/// Where a visible row lands on the ring.
enum LayoutSlot: Equatable {
    /// On the first ring, at this list position.
    case ring(Int)
    /// Behind "More...", at this position of the second ring.
    case more(Int)
    /// Beyond the 7 + 8 slots: reachable from the Studio only.
    case studioOnly
    /// Hidden by the person.
    case hidden
}

struct LayoutRow: Identifiable, Equatable {
    var id: String
    var label: L10n
    var symbol: String
    var family: OperationFamily
    var hidden: Bool
    var favorite: Bool
    var slot: LayoutSlot
}

@MainActor
final class LayoutEditorModel: ObservableObject {
    let layout: WheelLayout
    let registry: OperationRegistry
    private let settingsProvider: () -> SettingsData
    @Published var wheel: WheelKind = .convert { didSet { if wheel != oldValue { wheelChanged() } } }
    @Published var profile: WheelProfile = .image
    /// The row the pointer is on (the preview ring lights its sector).
    @Published var highlighted: String?
    @Published private(set) var revision = 0
    private var cache: [String: [Operation]] = [:]

    init(layout: WheelLayout = .shared, registry: OperationRegistry = .shared, settings: @escaping () -> SettingsData = { AppSettings.shared.data }) {
        self.layout = layout; self.registry = registry; self.settingsProvider = settings
    }

    // MARK: Catalogue

    /// The kinds listed for `wheel` (the link wheel has one kind, the file wheels the others).
    static func profiles(for wheel: WheelKind) -> [WheelProfile] {
        wheel == .link ? [.link] : WheelProfile.allCases.filter { $0 != .link }
    }

    /// Forget the cached operation lists (the registry changed, for example after a preset was added to a wheel).
    func invalidate() { cache.removeAll(); revision += 1 }

    func operations(wheel: WheelKind, profile: WheelProfile) -> [Operation] {
        let key = WheelLayout.key(wheel, profile)
        if let hit = cache[key] { return hit }
        let all = registry.allOperations(settings: settingsProvider())
        var list: [Operation]
        if profile == .link {
            list = wheel == .link ? all.filter { $0.meta.acceptsLinks && $0.meta.wheel == .link && !$0.meta.studioOnly } : []
        } else if WheelKind.fileWheels.contains(wheel) {
            let samples = LayoutSamples.sets(for: profile)
            list = all.filter { op in op.meta.wheel == wheel && !op.meta.studioOnly && !op.meta.acceptsLinks && samples.contains { op.appliesTo($0) } }
        } else {
            list = []
        }
        cache[key] = list
        return list
    }

    /// Operations the wheel would show for this kind (hidden ones not counted).
    func visibleCount(wheel: WheelKind, profile: WheelProfile) -> Int {
        let ops = operations(wheel: wheel, profile: profile)
        let hidden = Set(layout.data.hidden[WheelLayout.key(wheel, profile)] ?? [])
        return ops.filter { !hidden.contains($0.meta.id) }.count
    }

    // MARK: Rows

    /// Slot of the visible position `index` out of `count` visible rows (the ring holds 8; with more, 7 + "More..." and a second ring of 8).
    static func slot(forVisibleIndex index: Int, of count: Int) -> LayoutSlot {
        let cap = WheelLayout.maxPerRing
        if count <= cap { return .ring(index) }
        if index < cap - 1 { return .ring(index) }
        if index < (cap - 1) + cap { return .more(index - (cap - 1)) }
        return .studioOnly
    }

    func rows() -> [LayoutRow] { rows(wheel: wheel, profile: profile) }

    func rows(wheel: WheelKind, profile: WheelProfile) -> [LayoutRow] {
        let ops = operations(wheel: wheel, profile: profile)
        let order = layout.editorOrder(ops, wheel: wheel, profile: profile)
        let byID = Dictionary(ops.map { ($0.meta.id, $0) }, uniquingKeysWith: { a, _ in a })
        let favorites = Set(layout.data.favorites)
        var out: [LayoutRow] = []
        for (i, id) in order.visible.enumerated() {
            guard let op = byID[id] else { continue }
            out.append(LayoutRow(id: id, label: op.meta.label, symbol: op.meta.symbol, family: op.meta.family, hidden: false, favorite: favorites.contains(id),
                                 slot: Self.slot(forVisibleIndex: i, of: order.visible.count)))
        }
        for id in order.hidden {
            guard let op = byID[id] else { continue }
            out.append(LayoutRow(id: id, label: op.meta.label, symbol: op.meta.symbol, family: op.meta.family, hidden: true, favorite: false, slot: .hidden))
        }
        return out
    }

    // MARK: Editing

    /// `ids` after moving the rows at `source` so they end before position `destination` of the ORIGINAL list (the semantics of `onMove`).
    static func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        let moving = source.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
        guard !moving.isEmpty else { return ids }
        let before = source.filter { $0 < destination }.count
        var rest = ids
        for i in source.sorted(by: >) where rest.indices.contains(i) { rest.remove(at: i) }
        let at = Util.clamp(destination - before, 0, rest.count)
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    /// Drag-and-drop of rows inside the visible part of the list.
    func move(from source: IndexSet, to destination: Int) {
        let visible = rows().filter { !$0.hidden }.map(\.id)
        commit(order: Self.moved(visible, from: source, to: destination))
    }

    /// A row dragged onto another takes that row's place (the target moves one step toward where the dragged row came from).
    func move(id: String, onto target: String) {
        let visible = rows().filter { !$0.hidden }.map(\.id)
        guard let i = visible.firstIndex(of: id), let j = visible.firstIndex(of: target), i != j else { return }
        commit(order: Self.moved(visible, from: IndexSet(integer: i), to: j > i ? j + 1 : j))
    }

    /// Context-menu and VoiceOver moves: one step up or down, or to an end.
    enum Step { case up, down, top, bottom }
    func move(id: String, _ step: Step) {
        let visible = rows().filter { !$0.hidden }.map(\.id)
        guard let i = visible.firstIndex(of: id) else { return }
        let target: Int
        switch step {
        case .up: target = i - 1
        case .down: target = i + 1
        case .top: target = 0
        case .bottom: target = visible.count - 1
        }
        guard target >= 0, target < visible.count, target != i else { return }
        commit(order: Self.moved(visible, from: IndexSet(integer: i), to: target > i ? target + 1 : target))
    }

    private func commit(order: [String]) {
        layout.setOrder(order, wheel: wheel, profile: profile)
        revision += 1
    }

    func setHidden(_ hidden: Bool, id: String) {
        layout.setHidden(hidden, id: id, wheel: wheel, profile: profile)
        revision += 1
    }

    func toggleFavorite(id: String) {
        layout.setFavorite(!layout.isFavorite(id), id: id)
        revision += 1
    }

    func resetCurrent() { layout.reset(wheel: wheel, profile: profile); revision += 1 }
    func resetAll() { layout.resetAll(); revision += 1 }

    private func wheelChanged() {
        let allowed = Self.profiles(for: wheel)
        if !allowed.contains(profile) { profile = allowed[0] }
    }

    // MARK: Preview

    /// What the live ring shows: the first ring in slot order (favourites take the axes), "More..." when the list overflows.
    struct RingSector: Identifiable, Equatable {
        var id: String
        var label: L10n
        var symbol: String
        var favorite: Bool
        var isMore: Bool
    }

    func previewRing() -> [RingSector] {
        let visible = rows().filter { !$0.hidden }
        let hasMore = visible.count > WheelLayout.maxPerRing
        let first = hasMore ? Array(visible.prefix(WheelLayout.maxPerRing - 1)) : visible
        var sectors = first.map { RingSector(id: $0.id, label: $0.label, symbol: $0.symbol, favorite: $0.favorite, isMore: false) }
        if hasMore { sectors.append(RingSector(id: "more", label: L10n("More…", "Ещё…"), symbol: "ellipsis", favorite: false, isMore: true)) }
        let order = WheelSlotting.slotOrder(ids: sectors.map(\.id), favorites: layout.data.favorites, fixedLast: hasMore)
        let byID = Dictionary(sectors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byID[$0] }
    }
}
