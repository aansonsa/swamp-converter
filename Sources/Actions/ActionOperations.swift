import Foundation
import AppKit

// The ten Actions-wheel operations. Each is an `AppAction`: it runs on the main actor inside the app, shows no progress card (a big copy or move is the one
// exception: it becomes a card in the Jobs window), is never offered to watched folders, and reports problems as calm `ConversionError.message` sentences that
// QuickRun turns into toasts. Order on the wheel is the registration order in `ActionsCatalog.operations()`.
// Folders work everywhere. Nothing here is offered for link inputs. Nothing here ever deletes data except Move to Trash, and that goes to the Trash.

final class CopyAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.copy", .actions, .app, L10n("Copy", "Копировать"), sub: L10n("to folder…", "в папку…"), symbol: "doc.on.doc", schema: "action.copy", anyFile: true)) }

    /// Folder picker (starts in the last copy folder, else next to the first item; remembered), then `FileManager`-class copying (APFS clones are instant), a
    /// Finder-like conflict alert (Keep Both / Replace (old to Trash) / Skip / Stop, apply to all), same path skipped. Big copies become a Jobs card.
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        try await TransferService.pickAndRun(mode: .copy, items: items, origin: origin)
    }
}

final class MoveAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.move", .actions, .app, L10n("Move", "Переместить"), sub: L10n("to folder…", "в папку…"), symbol: "folder", schema: "action.move", anyFile: true)) }

    /// Like Copy with its own remembered folder. Same volume: one rename. Across volumes (the exFAT drive to the Mac): copy, verify size and member count, and only
    /// then the original goes to the Trash.
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        try await TransferService.pickAndRun(mode: .move, items: items, origin: origin)
    }
}

final class CopyPathAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.path", .actions, .app, L10n("Copy path", "Копировать путь"), symbol: "link", schema: "action.path", anyFile: true)) }

    /// The one setting of this action, editable like any quick recipe (Settings > Wheels > Actions).
    static let styleKey = "path.style"

    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: meta.schemaID, title: meta.label, symbol: meta.symbol, pages: [
            .make("main", symbol: "link", meta.label, [
                .make("format", [
                    .picker(Self.styleKey, L10n("Path format", "Формат пути"),
                            ResultActions.PathStyle.allCases.map { FieldOption($0.rawValue, $0.title) }, def: ResultActions.PathStyle.posix.rawValue)
                        .basic()
                        .help(L10n("How the paths are written to the clipboard, one per line.", "Как пути записываются в буфер обмена, по одному в строке."))
                        .oracle("action.path.style")
                ])
            ])
        ])
    }

    /// Full paths, one per line, to the clipboard (five tries 50 ms apart when it is busy); style from the saved quick recipe (default: plain path).
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        let recipe = AppSettings.shared.data.quickRecipes[meta.id]
        let style = ResultActions.PathStyle(rawValue: recipe?.string(Self.styleKey) ?? "") ?? .posix
        let urls = items.map(\.url)
        guard ResultActions.copyPaths(urls, style: style) else {
            throw ConversionError.message(L10n(ResultActions.clipboardBusyMessage))
        }
        let n = urls.count
        return ActionResult(note: n == 1 ? L10n("Path copied", "Путь скопирован")
                                         : L10n("\(n) paths copied", "Скопировано путей: \(n)"))
    }
}

final class TerminalAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.terminal", .actions, .app, L10n("Terminal", "Терминал"), sub: L10n("open here", "открыть здесь"), symbol: "terminal", schema: "action.terminal", anyFile: true)) }

    /// Opens the terminal of `settings.terminalApp` (Terminal, iTerm, Ghostty, Warp, kitty) at the folder: the item if it is a folder, else its parent.
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        try TerminalRunner.run(items: items, setting: AppSettings.shared.data.terminalApp)
    }
}

final class ShelfAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.float", .actions, .app, L10n("Shelf", "Полка"), sub: L10n("keep for later", "оставить на потом"), symbol: "tray.and.arrow.down", schema: "action.float", anyFile: true)) }

    /// A floating shelf near the pointer holding the items for a later drag-out.
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        ShelfController.shared.show(items: items, near: nil)
        return ActionResult()
    }
}

final class ShareAction: AppAction, @unchecked Sendable {
    init() {
        var m = OperationMeta.make("action.share", .actions, .app, L10n("Share", "Поделиться"), symbol: "square.and.arrow.up", schema: "action.share", anyFile: true)
        m.acceptsDirectories = true   // AirDrop accepts folders
        super.init(meta: m)
    }

    /// The system Share menu (AirDrop, Messages, Mail, Notes ...) at the pointer. Files and folders.
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        ResultActions.share(items.map(\.url), from: nil, anchor: .zero)
        return ActionResult()
    }
}

final class RevealAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.reveal", .actions, .app, L10n("Show in Finder", "Показать в Finder"), symbol: "magnifyingglass", schema: "action.reveal", anyFile: true)) }

    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        ResultActions.reveal(items.map(\.url))
        return ActionResult()
    }
}

final class OpenWithAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.openwith", .actions, .app, L10n("Open with", "Открыть в"), sub: L10n("choose an app…", "выбрать программу…"), symbol: "arrow.up.forward.app", schema: "action.openwith", anyFile: true)) }

    /// A menu at the pointer with the apps that can open all the items (default first) and "Other...".
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        let system = ActionsSystem.current
        let urls = ResultActions.existing(items.map(\.url))
        guard !urls.isEmpty else {
            throw ConversionError.message(L10n("The file is no longer where it was.", "Файла больше нет на прежнем месте."))
        }
        let candidates = ResultActions.openWithApps(forAll: urls)
        guard let app = system.chooseApplication(candidates, system.mouseLocation()) else { throw CancellationError() }
        ResultActions.open(urls, with: app)
        return ActionResult()
    }
}

final class QuickLookAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.quicklook", .actions, .app, L10n("Quick Look", "Быстрый просмотр"), symbol: "eye", schema: "action.quicklook", anyFile: true)) }

    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        ResultActions.quickLook(items.map(\.url))
        return ActionResult()
    }
}

final class TrashAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("action.trash", .actions, .app, L10n("Move to Trash", "В Корзину"), symbol: "trash", schema: "action.trash", anyFile: true)) }

    /// `FileManager.trashItem` per item; asks first for more than five items or any folder; never `removeItem`.
    override func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        try TrashService.run(items: items)
    }
}
