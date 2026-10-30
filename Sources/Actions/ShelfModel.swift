import Foundation
import AppKit

// The data side of the floating shelf: the list of files on one shelf, where a shelf opens, and how shelves survive a restart. No windows in this file, so all of
// it is unit-tested.

struct ShelfEntry: Identifiable, Equatable {
    let id: UUID
    var url: URL
    init(url: URL, id: UUID = UUID()) { self.id = id; self.url = url }
}

/// The files on ONE shelf. Adding is de-duplicated (the same path in any letter case counts once); nothing here touches the disk except `pruneVanished`.
@MainActor
final class ShelfModel: ObservableObject {
    let id: UUID
    @Published private(set) var entries: [ShelfEntry] = []
    /// True once the shelf has held something: an emptied shelf closes itself, a shelf that was opened empty on purpose does not.
    private(set) var hadItems = false
    /// Called after every change (the controller resizes the window, saves and closes an emptied shelf).
    var onChange: (() -> Void)?

    init(id: UUID = UUID(), urls: [URL] = []) {
        self.id = id
        _ = add(urls, notify: false)
    }

    var isEmpty: Bool { entries.isEmpty }
    var urls: [URL] { entries.map(\.url) }

    /// Header text: "3 items" / "Empty shelf".
    var title: String {
        entries.isEmpty ? L("Empty shelf", "Пустая полка") : ActionText.items(entries.count).text
    }

    /// Adds the URLs that are not on the shelf yet; returns how many were really added.
    @discardableResult
    func add(_ urls: [URL], notify: Bool = true) -> Int {
        var known = Set(entries.map { Self.key($0.url) })
        var added = 0
        for url in urls where url.isFileURL {
            guard known.insert(Self.key(url)).inserted else { continue }
            entries.append(ShelfEntry(url: url.standardizedFileURL))
            added += 1
        }
        if added > 0 { hadItems = true; if notify { onChange?() } }
        return added
    }

    func remove(ids: Set<UUID>) {
        let before = entries.count
        entries.removeAll { ids.contains($0.id) }
        if entries.count != before { onChange?() }
    }

    func remove(urls: [URL]) {
        let keys = Set(urls.map(Self.key))
        let before = entries.count
        entries.removeAll { keys.contains(Self.key($0.url)) }
        if entries.count != before { onChange?() }
    }

    /// Drops entries whose file no longer exists (after a Move drag-out, or when a persisted shelf is restored). Returns how many went.
    @discardableResult
    func pruneVanished(exists: (URL) -> Bool = { var st = stat(); return lstat($0.path, &st) == 0 }) -> Int {
        let before = entries.count
        entries.removeAll { !exists($0.url) }
        let removed = before - entries.count
        if removed > 0 { onChange?() }
        return removed
    }

    func urls(for ids: Set<UUID>) -> [URL] { entries.filter { ids.contains($0.id) }.map(\.url) }

    /// De-duplication key: standardised path, lower-cased (macOS volumes are case-insensitive by default, and the original app compared names that way).
    static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
}

// MARK: - Placement

enum ShelfPlacement {
    static let width: CGFloat = 290
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 40
    static let listInset: CGFloat = 4
    /// The list never grows beyond this; longer lists scroll.
    static let maxListHeight: CGFloat = 360
    /// Empty-state body (icon and room to drop).
    static let emptyBodyHeight: CGFloat = 64
    /// Two lines of hint text even in Russian.
    static let footerHeight: CGFloat = 48
    static let screenMargin: CGFloat = 8

    static func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? emptyBodyHeight : min(CGFloat(rows) * rowHeight + 2 * listInset, maxListHeight)
    }

    static func height(rows: Int) -> CGFloat { headerHeight + listHeight(rows: rows) + footerHeight }

    static func size(rows: Int) -> CGSize { CGSize(width: width, height: height(rows: rows)) }

    /// Where a new shelf goes: its top-left corner 24 pt right of and 40 pt above the pointer, kept on the screen, moved down-right in 24 pt steps while another
    /// shelf already sits within 12 pt of that spot (AppKit coordinates, y up).
    static func frame(near cursor: NSPoint, size: CGSize, visible: NSRect, occupied: [NSRect]) -> NSRect {
        var topLeft = NSPoint(x: cursor.x + 24, y: cursor.y + 40)
        var frame = clamped(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), to: visible)
        var guardCount = 0
        while occupied.contains(where: { abs($0.minX - frame.minX) < 12 && abs($0.maxY - frame.maxY) < 12 }), guardCount < 24 {
            topLeft = NSPoint(x: frame.minX + 24, y: frame.maxY - 24)
            frame = clamped(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), to: visible)
            guardCount += 1
        }
        return frame
    }

    static func clamped(_ rect: NSRect, to visible: NSRect) -> NSRect {
        var r = rect
        let m = screenMargin
        r.origin.x = min(max(r.origin.x, visible.minX + m), max(visible.maxX - r.width - m, visible.minX + m))
        r.origin.y = min(max(r.origin.y, visible.minY + m), max(visible.maxY - r.height - m, visible.minY + m))
        return r
    }

    /// The same window after its row count changed: top-left corner stays where it is.
    static func resized(_ frame: NSRect, rows: Int) -> NSRect {
        let s = size(rows: rows)
        return NSRect(x: frame.minX, y: frame.maxY - s.height, width: s.width, height: s.height)
    }
}

// MARK: - Persistence

struct StoredShelf: Codable, Equatable {
    var id: UUID
    var paths: [String]
    /// Top-left corner of the window when it was last seen (screen coordinates).
    var x: Double?
    var y: Double?

    /// The shelf without files that vanished; nil when nothing is left.
    func pruned(exists: (String) -> Bool) -> StoredShelf? {
        let kept = paths.filter(exists)
        guard !kept.isEmpty else { return nil }
        var copy = self
        copy.paths = kept
        return copy
    }
}

/// `shelves.json` in Application Support, written only while "keep shelves across launches" is on.
struct ShelfStore {
    var fileURL: URL

    init(fileURL: URL? = nil) { self.fileURL = fileURL ?? AppPaths.supportDir.appendingPathComponent("shelves.json") }

    func load() -> [StoredShelf] {
        guard let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([StoredShelf].self, from: data) else { return [] }
        return list
    }

    func save(_ shelves: [StoredShelf]) {
        guard !shelves.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(shelves) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes the file this store itself wrote.
    func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
