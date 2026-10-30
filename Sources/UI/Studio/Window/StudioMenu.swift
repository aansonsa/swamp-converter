import AppKit
import SwiftUI

// The "Studio" menu: every toolbar item is also a menu command with its key (spec/handbrake.md 6.8). It is added to the main menu while a Studio window is open and removed when
// the last one closes. Validation asks the model of the front window, so a command is dimmed exactly when its toolbar button is.
// Plain-letter keys (Space, J, K, L, I, O) are NOT menu key equivalents: a menu key would steal the letter from every text field. They work while the preview has the focus.

@MainActor
final class StudioMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = StudioMenu()

    private final class CommandBox: NSObject {
        let command: StudioCommand
        init(_ c: StudioCommand) { command = c }
    }

    private(set) var topItem: NSMenuItem?
    private var createdMainMenu = false
    private var startItem: NSMenuItem?
    private var pageItems: [NSMenuItem] = []

    var isInstalled: Bool { topItem != nil }

    /// The model the menu acts on: the front Studio window.
    private var model: StudioWindowModel? { StudioWindowController.shared.frontModel }

    // MARK: Install

    func install() {
        guard topItem == nil, let app = NSApp else { return }
        let item = NSMenuItem(title: StudioWindowController.windowTitle, action: nil, keyEquivalent: "")
        item.submenu = buildMenu()
        topItem = item
        if app.mainMenu == nil {
            app.mainMenu = Self.minimalMainMenu()
            createdMainMenu = true
        }
        guard let main = app.mainMenu else { return }
        let windowIndex = main.items.firstIndex { $0.submenu === app.windowsMenu }
        let helpIndex = main.items.firstIndex { $0.submenu === app.helpMenu }
        main.insertItem(item, at: windowIndex ?? helpIndex ?? main.items.count)
    }

    func uninstall() {
        guard let item = topItem else { return }
        item.menu?.removeItem(item)
        topItem = nil
        startItem = nil
        pageItems = []
    }

    /// A bare application and Edit menu for a process that has none (a text field needs Edit's Copy / Paste / Undo to work).
    private static func minimalMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit", "Завершить"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("Edit", "Правка"))
        edit.addItem(withTitle: L("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo", "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy", "Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All", "Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }

    // MARK: Build

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: StudioWindowController.windowTitle)
        menu.delegate = self
        menu.autoenablesItems = true
        add(menu, .addFiles, "o", [.command])
        add(menu, .pasteLink, "l", [.command])
        menu.addItem(.separator())
        startItem = add(menu, .start, "\r", [.command])
        add(menu, .addToQueue, "\r", [.command, .shift])
        add(menu, .preview, "r", [.command])
        menu.addItem(.separator())
        add(menu, .searchOptions, "f", [.command])
        add(menu, .presetMenu, "p", [.command, .option])
        let pagesItem = NSMenuItem(title: L("Inspector Page", "Страница параметров"), action: nil, keyEquivalent: "")
        let pages = NSMenu(title: pagesItem.title)
        pageItems = (1...StudioCommands.maxPageShortcuts).map { n in
            let it = NSMenuItem(title: StudioCommands.title(.inspectorPage(n)).text, action: #selector(performCommand(_:)), keyEquivalent: String(n))
            it.keyEquivalentModifierMask = [.command]
            it.target = self
            it.representedObject = CommandBox(.inspectorPage(n))
            pages.addItem(it)
            return it
        }
        pagesItem.submenu = pages
        menu.addItem(pagesItem)
        menu.addItem(.separator())
        let transportItem = NSMenuItem(title: L("Preview", "Просмотр"), action: nil, keyEquivalent: "")
        let transport = NSMenu(title: transportItem.title)
        for c in [StudioCommand.playPause, .stepBackward, .stepForward, .setIn, .setOut] { add(transport, c, "", []) }
        transportItem.submenu = transport
        menu.addItem(transportItem)
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ command: StudioCommand, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: StudioCommands.title(command).text, action: #selector(performCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.representedObject = CommandBox(command)
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        model?.perform(box.command)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let box = item.representedObject as? CommandBox, let model else { return false }
        return model.isEnabled(box.command)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        let ctx = model.commandContext()
        startItem?.title = StudioCommands.startTitle(ctx).text
        for (i, item) in pageItems.enumerated() {
            if let page = model.state.pages[safe: i] {
                item.title = page.title
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
    }
}

// MARK: - Edit > Undo for option changes

/// Edit > Undo / Redo reach the session's option history while no text field is being edited (the window's undo manager is asked when the responder chain gets that far).
final class StudioUndoBridge: UndoManager, @unchecked Sendable {
    weak var model: StudioWindowModel?

    init(model: StudioWindowModel) {
        self.model = model
        super.init()
    }

    override var canUndo: Bool { MainActor.assumeIsolated { model?.isEnabled(.undoOption) ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { model?.isEnabled(.redoOption) ?? false } }
    override func undo() { MainActor.assumeIsolated { model?.undo() } }
    override func redo() { MainActor.assumeIsolated { model?.redo() } }
    override var undoMenuItemTitle: String { StudioCommands.title(.undoOption).text }
    override var redoMenuItemTitle: String { StudioCommands.title(.redoOption).text }

    @MainActor static func manager(for model: StudioWindowModel) -> UndoManager { model.undoBridge }
}

// MARK: - Finding controls that another module draws

enum StudioResponderFinder {
    @MainActor
    static func allViews(in window: NSWindow?) -> [NSView] {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return [] }
        var out: [NSView] = [], queue: [NSView] = [root]
        while let v = queue.popLast() { out.append(v); queue.append(contentsOf: v.subviews) }
        return out
    }

    /// Cmd-F: moves the keyboard to the inspector's search field.
    @MainActor @discardableResult
    static func focusSearchField(in window: NSWindow?) -> Bool {
        let views = allViews(in: window)
        let field = views.first { $0 is NSSearchField } ?? views.first { v in
            guard let f = v as? NSTextField, f.isEditable else { return false }
            let hint = (f.placeholderString ?? "") + (f.accessibilityLabel() ?? "")
            return hint.range(of: "search", options: .caseInsensitive) != nil || hint.range(of: "поиск", options: .caseInsensitive) != nil
        }
        guard let field, let window else { return false }
        return window.makeFirstResponder(field)
    }

    /// Cmd-Option-P: clicks the toolbar's preset pop-up (the preset bar tags itself with this accessibility identifier).
    @MainActor @discardableResult
    static func openPresetMenu(in window: NSWindow?) -> Bool {
        let views = allViews(in: window)
        guard let host = views.first(where: { $0.accessibilityIdentifier() == StudioIdentifiers.presetBar }) else { return false }
        var queue: [NSView] = [host]
        while let v = queue.popLast() {
            if let c = v as? NSControl, c.isEnabled { c.performClick(nil); return true }
            queue.append(contentsOf: v.subviews)
        }
        return false
    }
}

enum StudioIdentifiers {
    static let presetBar = "studio.presetBar"
    static let preview = "studio.preview"
    static let sidebar = "studio.sidebar"
}
