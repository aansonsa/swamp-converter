import AppKit

/// Builds the status-item menu and the Dock menu. Items are created when a menu opens (`menuNeedsUpdate`) and never on a timer, so a language change or a finished job shows up the
/// next time the menu opens at no idle cost. Every item carries a stable identifier (`ID`) that tests and accessibility use.
@MainActor
final class MenuBarMenu: NSObject, NSMenuDelegate {
    enum ID: String, CaseIterable {
        case status, recent, recentEmpty, addFiles, openStudio, downloadLink, wheelClipboard, newShelf, pauseGestures, settings, about, quit
    }

    /// Where the wheel opens for commands chosen in the menu (below the status item); nil = at the pointer.
    var anchorProvider: () -> NSPoint? = { nil }
    private let isDock: Bool

    init(isDock: Bool = false) { self.isDock = isDock; super.init() }

    // MARK: Pure texts (tested)

    /// "No jobs", "2 running", "2 running, 3 waiting", "Queue paused".
    nonisolated static func statusTitle(running: Int, waiting: Int, paused: Bool, line: String, unseenError: Bool = false) -> String {
        if running + waiting > 0 && !line.isEmpty { return line }
        if paused && running + waiting > 0 { return L("Queue paused", "Очередь приостановлена") }
        if running > 0 {
            let r = Loc.plural(running, enOne: "\(running) running", enOther: "\(running) running", ruOne: "\(running) выполняется", ruFew: "\(running) выполняются", ruMany: "\(running) выполняются")
            return waiting > 0 ? r + L(", \(waiting) waiting", ", в ожидании: \(waiting)") : r
        }
        if waiting > 0 { return L("\(waiting) waiting", "В ожидании: \(waiting)") }
        if unseenError { return L("A job failed: Show Jobs", "Задача завершилась ошибкой: показать задачи") }
        return L("No jobs running", "Нет активных задач")
    }

    /// The last finished outputs, newest first (the history is newest first), at most `limit`.
    nonisolated static func recentOutputs(from history: [JobRecord], limit: Int = 10) -> [(title: String, url: URL)] {
        var out: [(String, URL)] = []
        for rec in history where rec.state == .done {
            guard let first = rec.outputs.first else { continue }
            out.append((rec.title, URL(fileURLWithPath: first)))
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Menus

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Swamp Converter")
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let runner = JobRunner.shared
        let model = MenuBarProgressModel.shared
        if !isDock {
            let failed = model.isIdle && model.hasUnseenError
            let status = item(.status, MenuBarMenu.statusTitle(running: model.running, waiting: model.waiting, paused: runner.queuePaused, line: model.statusLine, unseenError: model.hasUnseenError),
                              symbol: failed ? "exclamationmark.triangle" : (model.isIdle ? "checkmark.circle" : "arrow.triangle.2.circlepath"), action: #selector(showJobs))
            menu.addItem(status)
            menu.addItem(.separator())
        }
        menu.addItem(recentItem(history: runner.history))
        menu.addItem(.separator())
        if !isDock { menu.addItem(item(.addFiles, L("Add Files…", "Добавить файлы…"), symbol: "plus.circle", action: #selector(addFiles))) }
        menu.addItem(item(.openStudio, L("Open Studio", "Открыть студию"), symbol: "slider.horizontal.3", action: #selector(openStudio)))
        menu.addItem(item(.downloadLink, L("Download from Link…", "Скачать по ссылке…"), symbol: "arrow.down.circle", action: #selector(downloadLink)))
        if !isDock {
            menu.addItem(item(.wheelClipboard, L("Wheel for Clipboard", "Колесо для буфера обмена"), symbol: "doc.on.clipboard", action: #selector(wheelClipboard)))
            menu.addItem(item(.newShelf, L("New Floating Shelf", "Новая плавающая полка"), symbol: "tray", action: #selector(newShelf)))
            menu.addItem(.separator())
            let pause = item(.pauseGestures, L("Pause Gestures", "Приостановить жесты"), symbol: "hand.raised", action: #selector(toggleGestures))
            pause.toolTip = L("Also pauses watched folders. The shortcut, Services and the Dock icon keep working.",
                              "Также приостанавливает отслеживаемые папки. Сочетание клавиш, Службы и значок в Dock продолжают работать.")
            pause.state = AppSettings.shared.data.gesturesPaused ? .on : .off
            menu.addItem(pause)
            menu.addItem(.separator())
            menu.addItem(item(.settings, L("Settings…", "Настройки…"), symbol: "gearshape", action: #selector(showSettings), key: ","))
            menu.addItem(item(.about, L("About Swamp Converter", "О программе Swamp Converter"), symbol: "info.circle", action: #selector(showAbout)))
            menu.addItem(.separator())
            let quit = item(.quit, L("Quit Swamp Converter", "Выйти из Swamp Converter"), symbol: nil, action: #selector(quit), key: "q")
            menu.addItem(quit)
        }
    }

    private func item(_ id: ID, _ title: String, symbol: String?, action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        if let symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return it
    }

    private func recentItem(history: [JobRecord]) -> NSMenuItem {
        let parent = NSMenuItem(title: L("Recent Results", "Недавние результаты"), action: nil, keyEquivalent: "")
        parent.identifier = NSUserInterfaceItemIdentifier(ID.recent.rawValue)
        parent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu(title: parent.title)
        sub.autoenablesItems = false
        let recents = Self.recentOutputs(from: history)
        if recents.isEmpty {
            let empty = NSMenuItem(title: L("No Results Yet", "Результатов пока нет"), action: nil, keyEquivalent: "")
            empty.identifier = NSUserInterfaceItemIdentifier(ID.recentEmpty.rawValue)
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for r in recents {
                let it = NSMenuItem(title: r.url.lastPathComponent, action: #selector(revealResult(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = r.url
                it.toolTip = r.title
                if let icon = NSWorkspace.shared.icon(forFile: r.url.path).copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); it.image = icon }
                sub.addItem(it)
            }
        }
        parent.submenu = sub
        return parent
    }

    // MARK: Actions

    @objc private func showJobs() { AppCommands.openJobs() }
    @objc private func addFiles() { AppCommands.addFiles(anchor: anchorProvider()) }
    @objc private func openStudio() { AppCommands.openStudio() }
    @objc private func downloadLink() { AppCommands.downloadFromLink() }
    @objc private func wheelClipboard() { AppCommands.wheelForClipboard(anchor: anchorProvider()) }
    @objc private func newShelf() { ShelfController.shared.showEmpty() }
    @objc private func toggleGestures() { AppCommands.toggleGesturesPaused() }
    @objc private func showSettings() { AppCommands.showSettings() }
    @objc private func showAbout() { AppCommands.showAbout() }
    @objc private func quit() { AppCommands.quit() }
    @objc private func revealResult(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { ResultActions.reveal([url]) }
    }
}
