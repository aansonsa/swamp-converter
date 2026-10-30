import Foundation
import AppKit

// The real panels and alerts behind `ActionsSystem.live`. Each alert is built from a plain content model (`ConflictAlertContent`, `TrashAlertContent`) so the
// wording is unit-tested and the snapshots draw exactly the same sentences.
//
// An accessory (menu-bar) app has no key window, so a panel opened from the wheel would appear behind everything. `ActionPanels.modal` activates the app for the
// moment the panel is up and gives the focus back to the app that had it (the drag source) afterwards.

@MainActor
enum ActionPanels {
    /// Runs `body` with the app active, then re-activates the app that was in front.
    static func modal<T>(_ body: () -> T) -> T {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        defer {
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate() }
        }
        return body()
    }

    // MARK: Folder picker

    static func chooseFolder(_ prompt: FolderPrompt) async -> URL? {
        modal {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            panel.title = prompt.title.text
            panel.message = prompt.message.text
            panel.prompt = prompt.buttonTitle.text
            if let start = prompt.startAt { panel.directoryURL = start }
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    // MARK: Conflict

    static func resolveConflict(_ info: ConflictInfo) -> ConflictAnswer {
        let content = ConflictAlertContent(info)
        return modal {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = content.title
            alert.informativeText = content.message + "\n\n" + content.existingLine + "\n" + content.newLine
            for (_, title) in content.buttons { alert.addButton(withTitle: title) }
            if let replace = alert.buttons[safe: 1] { replace.hasDestructiveAction = true }
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            if let all = content.applyToAllTitle {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = all
            }
            let response = alert.runModal()
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = content.buttons[safe: index]?.0 ?? .stop
            return ConflictAnswer(choice: choice, applyToAll: alert.suppressionButton?.state == .on)
        }
    }

    // MARK: Trash

    static func confirmTrash(_ c: TrashConfirmation) -> Bool {
        let content = TrashAlertContent(c)
        return modal {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = content.title
            alert.informativeText = content.message
            let trash = alert.addButton(withTitle: content.confirmTitle)
            trash.hasDestructiveAction = true
            let cancel = alert.addButton(withTitle: content.cancelTitle)
            cancel.keyEquivalent = "\u{1b}"
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: Open With

    /// A pop-up menu at the pointer: the apps that can open the items, default first, then "Other...". nil when the menu is dismissed.
    static func chooseApplication(candidates: [(name: String, url: URL)], at point: NSPoint) -> URL? {
        let picker = AppMenuPicker()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, c) in candidates.enumerated() {
            let item = NSMenuItem(title: i == 0 && candidates.count > 1 ? c.name + L(" (default)", " (по умолчанию)") : c.name, action: #selector(AppMenuPicker.picked(_:)), keyEquivalent: "")
            item.target = picker
            item.representedObject = c.url
            let icon = NSWorkspace.shared.icon(forFile: c.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !candidates.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: L("Other…", "Другое…"), action: #selector(AppMenuPicker.other(_:)), keyEquivalent: "")
        other.target = picker
        menu.addItem(other)
        menu.popUp(positioning: nil, at: point, in: nil)
        if picker.wantsOther { return chooseApplicationFromDisk() }
        return picker.chosen
    }

    private static func chooseApplicationFromDisk() -> URL? {
        modal {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.title = L("Choose an Application", "Выберите программу")
            panel.prompt = L("Open", "Открыть")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
}

/// Menu target for the Open With pop-up.
private final class AppMenuPicker: NSObject {
    var chosen: URL?
    var wantsOther = false
    @objc func picked(_ sender: NSMenuItem) { chosen = sender.representedObject as? URL }
    @objc func other(_ sender: NSMenuItem) { wantsOther = true }
}

// MARK: - Content models

/// The words of the Finder-style conflict alert.
struct ConflictAlertContent: Equatable {
    var title: String
    var message: String
    var existingLine: String
    var newLine: String
    var buttons: [(ConflictChoice, String)]
    var applyToAllTitle: String?

    static func == (a: ConflictAlertContent, b: ConflictAlertContent) -> Bool {
        a.title == b.title && a.message == b.message && a.existingLine == b.existingLine && a.newLine == b.newLine
            && a.buttons.map(\.1) == b.buttons.map(\.1) && a.applyToAllTitle == b.applyToAllTitle
    }

    init(_ info: ConflictInfo) {
        let moving = info.mode == .move
        title = L("“\(info.name)” already exists in “\(info.folderName)”.", "«\(info.name)» уже есть в папке «\(info.folderName)».")
        let verb = moving ? L("moving", "перемещаете") : L("copying", "копируете")
        message = L("Do you want to replace it with the one you’re \(verb)? The older item goes to the Trash.",
                    "Заменить его тем, который вы \(verb)? Прежний элемент будет перемещён в Корзину.")
        existingLine = L("Existing: ", "Сейчас: ") + Self.describe(isDirectory: info.existingIsDirectory, size: info.existingSize, date: info.existingDate)
        newLine = L("New: ", "Новый: ") + Self.describe(isDirectory: info.sourceIsDirectory, size: info.sourceSize, date: info.sourceDate)
        buttons = [(.keepBoth, L("Keep Both", "Оставить оба")), (.replace, L("Replace", "Заменить")),
                   (.skip, L("Skip", "Пропустить")), (.stop, L("Stop", "Остановить"))]
        applyToAllTitle = info.canApplyToAll ? L("Apply to all", "Применить ко всем") : nil
    }

    private static func describe(isDirectory: Bool, size: Int64?, date: Date?) -> String {
        var parts: [String] = []
        if isDirectory { parts.append(L("folder", "папка")) } else if let size { parts.append(Util.formatBytes(size)) }
        if let date {
            let f = DateFormatter()
            f.locale = Loc.shared.locale
            f.dateStyle = .medium
            f.timeStyle = .short
            parts.append(L("modified ", "изменён ") + f.string(from: date))
        }
        return parts.isEmpty ? "-" : parts.joined(separator: ", ")
    }
}

/// The words of the "Move to Trash?" alert.
struct TrashAlertContent: Equatable {
    var title: String
    var message: String
    var confirmTitle: String
    var cancelTitle: String

    init(_ c: TrashConfirmation) {
        if c.itemCount == 1 {
            title = L("Move “\(c.firstName)” to the Trash?", "Переместить «\(c.firstName)» в Корзину?")
        } else {
            title = L("Move \(ActionText.items(c.itemCount).en) to the Trash?", "Переместить в Корзину: \(ActionText.items(c.itemCount).ru)?")
        }
        message = c.includesFolder
            ? L("Folders are moved with everything inside them. You can put them back from the Trash.",
                "Папки перемещаются вместе со всем содержимым. Вернуть их можно из Корзины.")
            : L("You can put them back from the Trash.", "Вернуть их можно из Корзины.")
        confirmTitle = L("Move to Trash", "В Корзину")
        cancelTitle = L("Cancel", "Отмена")
    }
}
