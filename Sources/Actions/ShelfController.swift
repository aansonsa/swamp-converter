import Foundation
import AppKit
import SwiftUI

/// The floating shelf ("Float" in the original): a small always-on-top panel that keeps files for later drag-out. Several shelves may coexist.
/// Spec: spec/appfeatures.md 3 (details): 290 pt wide, never takes focus, drop adds (de-duplicated), drag rows out (copy / move / link), double-click opens,
/// Delete removes from the shelf (not from disk), Space = Quick Look, hint text, empty shelf closes itself, optional persistence (`settings.shelfPersist`).
///
/// Nothing runs while no shelf is open: no timers, no observers. A shelf is a window plus a `ShelfModel`; the controller only keeps them in a dictionary.
@MainActor
final class ShelfController {
    static let shared = ShelfController()

    private struct Shelf {
        var model: ShelfModel
        var window: ShelfWindowing
    }

    private var shelves: [UUID: Shelf] = [:]
    /// Creation order, for stable persistence.
    private var order: [UUID] = []

    // Seams (tests replace them; the defaults are the real thing).
    var persistEnabled: () -> Bool = { AppSettings.shared.data.shelfPersist }
    var storeProvider: () -> ShelfStore = { ShelfStore() }
    var windowFactory: ShelfWindowFactory = { ShelfWindowController.make(model: $0, frame: $1, callbacks: $2) }
    var pointerLocation: () -> NSPoint = { ActionsSystem.current.mouseLocation() }
    var visibleFrameProvider: (NSPoint) -> NSRect = { point in
        (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {}

    var openShelfCount: Int { shelves.count }

    /// URLs on every open shelf (tests and "is this file already parked" checks).
    var allURLs: [[URL]] { order.compactMap { shelves[$0]?.model.urls } }

    // MARK: Opening

    /// Opens a new shelf near `point` (screen coordinates; nil = near the pointer) holding `items`.
    func show(items: [FileItem], near point: NSPoint? = nil) {
        guard !items.isEmpty else { return showEmpty() }
        open(urls: items.map(\.url), near: point ?? pointerLocation())
    }

    /// "Empty floating shelf" menu item.
    func showEmpty() { open(urls: [], near: pointerLocation()) }

    /// Restores persisted shelves at launch when `settings.shelfPersist` (files that vanished are pruned). Cheap: nothing is built when there are none.
    func restoreIfNeeded() {
        guard persistEnabled() else { return }
        let store = storeProvider()
        let stored = store.load()
        guard !stored.isEmpty else { return }
        var changed = false
        for shelf in stored {
            guard let kept = shelf.pruned(exists: { var st = stat(); return lstat($0, &st) == 0 }) else { changed = true; continue }
            if kept.paths.count != shelf.paths.count { changed = true }
            let urls = kept.paths.map { URL(fileURLWithPath: $0) }
            if let x = kept.x, let y = kept.y, let frame = restoredFrame(topLeft: NSPoint(x: x, y: y), rows: urls.count) {
                open(urls: urls, frame: frame, id: kept.id)
            } else {
                open(urls: urls, near: pointerLocation(), id: kept.id)
            }
        }
        if changed { persist() }
    }

    /// Closes every shelf and forgets the saved ones.
    func closeAll() {
        for id in order { shelves[id]?.window.close() }
        shelves = [:]
        order = []
        storeProvider().clear()
    }

    // MARK: Internals

    @discardableResult
    private func open(urls: [URL], near point: NSPoint, id: UUID = UUID()) -> UUID {
        let size = ShelfPlacement.size(rows: urls.count)
        let occupied = order.compactMap { shelves[$0]?.window.frame }
        let frame = ShelfPlacement.frame(near: point, size: size, visible: visibleFrameProvider(point), occupied: occupied)
        return open(urls: urls, frame: frame, id: id)
    }

    /// Moving a shelf reports every step of the drag; the positions are written once the shelf has been still for a moment, not once per frame.
    private var persistWork: DispatchWorkItem?
    private func persistSoon() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.persist() } }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @discardableResult
    private func open(urls: [URL], frame: NSRect, id: UUID) -> UUID {
        let model = ShelfModel(id: id, urls: urls)
        model.onChange = { [weak self] in self?.modelChanged(id) }
        let callbacks = ShelfWindowCallbacks(
            close: { [weak self] in self?.closeShelf(id) },
            moved: { [weak self] in self?.persistSoon() },
            windowClosed: { [weak self] in self?.forgetWindow(id) })
        let window = windowFactory(model, frame, callbacks)
        shelves[id] = Shelf(model: model, window: window)
        order.append(id)
        window.show(animated: !reduceMotion())
        persist()
        return id
    }

    private func restoredFrame(topLeft: NSPoint, rows: Int) -> NSRect? {
        let size = ShelfPlacement.size(rows: rows)
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        let visible = visibleFrameProvider(topLeft)
        return visible.intersects(frame) ? ShelfPlacement.clamped(frame, to: visible) : nil
    }

    private func modelChanged(_ id: UUID) {
        guard let shelf = shelves[id] else { return }
        if shelf.model.isEmpty, shelf.model.hadItems { return closeShelf(id) }
        shelf.window.setFrame(ShelfPlacement.resized(shelf.window.frame, rows: shelf.model.entries.count), animated: !reduceMotion())
        persist()
    }

    /// The person closed it (X) or it emptied itself: gone for good, also from the saved list.
    private func closeShelf(_ id: UUID) {
        guard let shelf = shelves.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        shelf.window.close()
        persist()
    }

    /// The window went away by itself (app quit, system): no persistence change, so a quit keeps the saved shelves.
    private func forgetWindow(_ id: UUID) {
        shelves[id] = nil
        order.removeAll { $0 == id }
    }

    private func persist() {
        let store = storeProvider()
        guard persistEnabled() else { return store.clear() }
        let list: [StoredShelf] = order.compactMap { id in
            guard let s = shelves[id], !s.model.isEmpty else { return nil }
            let f = s.window.frame
            return StoredShelf(id: id, paths: s.model.urls.map(\.path), x: Double(f.minX), y: Double(f.maxY))
        }
        store.save(list)
    }
}

// MARK: - Windows

struct ShelfWindowCallbacks {
    var close: () -> Void
    var moved: () -> Void
    var windowClosed: () -> Void
}

@MainActor
protocol ShelfWindowing: AnyObject {
    var frame: NSRect { get }
    func show(animated: Bool)
    func setFrame(_ frame: NSRect, animated: Bool)
    func close()
}

typealias ShelfWindowFactory = @MainActor (_ model: ShelfModel, _ frame: NSRect, _ callbacks: ShelfWindowCallbacks) -> ShelfWindowing

/// The panel: floating, on every Space and over full-screen apps, and it takes keys without ever activating the app, so whatever the person was doing keeps its focus.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Only the header moves the panel (`WindowDragArea`). Moving by the background made every drag that started on a row move the whole shelf instead of the file.
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = L("Floating shelf", "Плавающая полка")
        setAccessibilityLabel(title)
    }

    /// Esc closes the Quick Look panel if it is up, otherwise nothing.
    override func cancelOperation(_ sender: Any?) {
        if QuickLookCoordinator.shared.isVisible { QuickLookCoordinator.shared.close() }
    }
}

@MainActor
final class ShelfWindowController: NSObject, ShelfWindowing, NSWindowDelegate {
    let panel: ShelfPanel
    private let callbacks: ShelfWindowCallbacks

    var frame: NSRect { panel.frame }

    static func make(model: ShelfModel, frame: NSRect, callbacks: ShelfWindowCallbacks) -> ShelfWindowing {
        ShelfWindowController(model: model, frame: frame, callbacks: callbacks)
    }

    init(model: ShelfModel, frame: NSRect, callbacks: ShelfWindowCallbacks) {
        self.panel = ShelfPanel(frame: frame)
        self.callbacks = callbacks
        super.init()
        let root = ShelfContentView(model: model, handlers: .live, onClose: callbacks.close).appRoot()
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.delegate = self
    }

    func show(animated: Bool) {
        if animated {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func setFrame(_ frame: NSRect, animated: Bool) { panel.setFrame(frame, display: true, animate: animated) }

    func close() {
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    func windowDidEndLiveResize(_ notification: Notification) {}

    func windowDidMove(_ notification: Notification) { callbacks.moved() }

    func windowWillClose(_ notification: Notification) { callbacks.windowClosed() }
}
