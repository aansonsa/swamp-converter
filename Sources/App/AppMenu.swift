import AppKit
import Combine

/// The main menu (`NSApp.mainMenu`), visible whenever the app has a Dock icon (a window is open): App (About, Settings Cmd-,, Services, Hide, Quit), Edit (so text fields get Undo / Cut /
/// Copy / Paste / Select All), Window. The Studio's own `StudioMenu` inserts itself before the Window menu while a Studio window is open; `rebuild()` (language change) takes it out and
/// puts it back so the two never fight.
@MainActor
final class AppMenu: NSObject {
    static let shared = AppMenu()
    private var bag = Set<AnyCancellable>()

    func install() {
        rebuild()
        guard bag.isEmpty else { return }
        Loc.shared.$revision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
    }

    func rebuild() {
        guard let app = NSApp else { return }
        let studioWasInstalled = StudioMenu.shared.isInstalled
        if studioWasInstalled { StudioMenu.shared.uninstall() }
        app.mainMenu = Self.makeMainMenu(target: self)
        if studioWasInstalled { StudioMenu.shared.install() }
    }

    /// Titles of the top-level menus (tested).
    var topLevelTitles: [String] { NSApp?.mainMenu?.items.map { $0.submenu?.title ?? $0.title } ?? [] }

    static func makeMainMenu(target: AnyObject?) -> NSMenu {
        let main = NSMenu(title: "Main")
        let appName = "Swamp Converter"

        // App
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(command(L("About \(appName)", "О программе \(appName)"), #selector(showAbout), "", target))
        appMenu.addItem(.separator())
        appMenu.addItem(command(L("Settings…", "Настройки…"), #selector(showSettings), ",", target))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: L("Services", "Службы"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: services.title)
        services.submenu = servicesMenu
        NSApp?.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Hide \(appName)", "Скрыть \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: L("Hide Others", "Скрыть остальные"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: L("Show All", "Показать все"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Quit \(appName)", "Выйти из \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        // Edit
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("Edit", "Правка"))
        edit.addItem(NSMenuItem(title: L("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Redo", "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Copy", "Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Delete", "Удалить"), action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: L("Select All", "Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit

        // Window
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: L("Window", "Окно"))
        // Command-W: the app has no File menu, so Close lives here (every window of the app closes with it).
        window.addItem(NSMenuItem(title: L("Close Window", "Закрыть окно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: L("Minimize", "Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: L("Zoom", "Масштаб"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(command(L("Jobs", "Задачи"), #selector(showJobs), "", target))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: L("Bring All to Front", "Все окна на передний план"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = window
        NSApp?.windowsMenu = window
        return main
    }

    private static func command(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @objc private func showAbout() { AppCommands.showAbout() }
    @objc private func showSettings() { AppCommands.showSettings() }
    @objc private func showJobs() { AppCommands.openJobs() }
}
