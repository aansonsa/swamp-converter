import SwiftUI
import AppKit
import Combine

/// The Settings window (Cmd-,). Single instance; reopening focuses it. Remembers the last page. Built on first `show`.
///
/// HIG: toolbar-style panes (`NSToolbar` with the preference style), the title is the name of the pane, the window fits the pane and changes size with it, the last pane is restored.
/// Pages are created when first shown (`SettingsPageDescriptor.make`) and released with the window, so a closed Settings window costs nothing.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    /// Everything that differs between the real app and a test run.
    struct Options {
        /// Bring the window forward and activate the app.
        var activates = true
        /// Tell `WindowPresence` (Dock icon while a window is open).
        var reportsPresence = true
        /// Where tests park the window so nothing appears on the person's screen.
        var parkOffscreen = false
        var settings: AppSettings = .shared
        /// nil = the shared registry (with the built-in pages ensured).
        var registry: SettingsPageRegistry?
    }

    static let presenceID = "settings"
    /// Key under `settings.studio.inspectorPage` that remembers the last pane.
    static let lastPageKey = "settings.lastPage"

    private let options: Options
    private var window: NSWindow?
    private var hosts: [String: NSViewController] = [:]
    private var toolbarIDs: [String] = []
    /// The pages the toolbar was built from (the registry publishes before it stores, so the delegate must not read the registry).
    private var toolbarPages: [SettingsPageDescriptor] = []
    private var bag = Set<AnyCancellable>()
    private(set) var currentPage: SettingsPageID?

    init(options: Options = Options()) {
        self.options = options
        super.init()
    }

    private var registry: SettingsPageRegistry { options.registry ?? .shared }

    var isVisible: Bool { window?.isVisible ?? false }
    /// The window, once built (tests and snapshots read its title and size).
    var currentWindow: NSWindow? { window }
    /// Number of page views built since the window opened (lazy-building test).
    var builtPageCount: Int { hosts.count }

    // MARK: Show / close

    /// Shows the window on `page` (nil = last page). Deep links: "Open Notification Settings" rows, `show(page: .downloader)` from the first-use sheet, "Edit in Studio..." returns here.
    func show(page: SettingsPageID? = nil) {
        if options.registry == nil { SettingsModule.ensureBuiltInPages() }
        let pages = registry.pages
        guard !pages.isEmpty else { return }
        let target = resolve(page, in: pages)
        let w = window ?? makeWindow()
        syncToolbar(pages)
        display(target, animated: w.isVisible && !options.parkOffscreen)
        if !options.parkOffscreen, options.activates {
            WindowPresence.shared.present(w, id: options.reportsPresence ? Self.presenceID : nil)
        } else {
            w.orderFront(nil)
            if options.reportsPresence { WindowPresence.shared.opened(Self.presenceID) }
        }
    }

    func close() { window?.close() }

    /// The page to show: the one asked for, else the remembered one, else the first.
    private func resolve(_ asked: SettingsPageID?, in pages: [SettingsPageDescriptor]) -> SettingsPageDescriptor {
        if let asked, let p = pages.first(where: { $0.id == asked }) { return p }
        if let raw = options.settings.data.studio.inspectorPage[Self.lastPageKey], let p = pages.first(where: { $0.id.raw == raw }) { return p }
        return pages[0]
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let size = SettingsPaneMetrics.size(for: .general)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.toolbarStyle = .preference
        w.titleVisibility = .visible
        w.setFrameAutosaveName("")   // the size follows the pane, only the position is remembered by hand
        if options.parkOffscreen { w.setFrameOrigin(NSPoint(x: -4000, y: -4000)) } else { w.center() }
        window = w
        Loc.shared.$revision.dropFirst().sink { [weak self] _ in self?.languageChanged() }.store(in: &bag)
        registry.$pages.dropFirst().sink { [weak self] pages in
            // `@Published` fires before the value is stored: read the new list from the notification.
            guard let self, self.window != nil else { return }
            self.syncToolbar(pages)
        }.store(in: &bag)
        return w
    }

    private func languageChanged() {
        guard let w = window else { return }
        rebuildToolbar(toolbarPages)
        if let id = currentPage, let p = toolbarPages.first(where: { $0.id == id }) { w.title = p.title.text }
    }

    func windowWillClose(_ notification: Notification) {
        // Release the pages: a closed Settings window keeps nothing alive.
        window?.contentViewController = nil
        window?.toolbar = nil
        hosts.removeAll()
        toolbarIDs = []
        toolbarPages = []
        bag.removeAll()
        currentPage = nil
        window = nil
        if options.reportsPresence { WindowPresence.shared.closed(Self.presenceID) }
    }

    // MARK: Panes

    private func display(_ page: SettingsPageDescriptor, animated: Bool) {
        guard let w = window else { return }
        let host: NSViewController
        if let cached = hosts[page.id.raw] { host = cached } else {
            let controller = NSHostingController(rootView: page.make())
            controller.sizingOptions = []
            hosts[page.id.raw] = controller
            host = controller
        }
        let size = SettingsPaneMetrics.clamped(SettingsPaneMetrics.size(for: page.id), visibleFrame: (w.screen ?? NSScreen.main)?.visibleFrame)
        let oldFrame = w.frame
        let content = NSRect(origin: .zero, size: size)
        var frame = w.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)   // the top-left corner stays where it is
        // The new pane arrives at the size the window has now and the window then animates to the pane's size. Assigning `contentViewController` sizes the window to the
        // view's own frame at once, and a hosting view that was never shown has an empty one: the window collapsed to a strip and grew back, as if it closed and reopened.
        host.view.setFrameSize(w.contentView?.bounds.size ?? size)
        w.contentViewController = host
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        w.setFrame(frame, display: true, animate: animated && !reduce)
        w.title = page.title.text
        w.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(page.id.raw)
        currentPage = page.id
        options.settings.update { $0.studio.inspectorPage[Self.lastPageKey] = page.id.raw }
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        let id = SettingsPageID(sender.itemIdentifier.rawValue)
        guard let p = registry.pages.first(where: { $0.id == id }) else { return }
        display(p, animated: true)
    }

    // MARK: Toolbar

    private func syncToolbar(_ pages: [SettingsPageDescriptor]) {
        let ids = pages.map(\.id.raw)
        if window?.toolbar == nil || ids != toolbarIDs { rebuildToolbar(pages) }
    }

    private func rebuildToolbar(_ pages: [SettingsPageDescriptor]) {
        guard let w = window else { return }
        toolbarIDs = pages.map(\.id.raw)
        toolbarPages = pages
        let tb = NSToolbar(identifier: "settings.panes")
        tb.delegate = self
        tb.allowsUserCustomization = false
        tb.displayMode = .iconAndLabel
        w.toolbar = tb
        if let id = currentPage { tb.selectedItemIdentifier = NSToolbarItem.Identifier(id.raw) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIDs.map { NSToolbarItem.Identifier($0) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = toolbarPages.first(where: { $0.id.raw == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.title.text
        item.paletteLabel = page.title.text
        item.toolTip = page.title.text
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title.text)
        item.target = self
        item.action = #selector(selectPane(_:))
        item.isBordered = true
        return item
    }
}
