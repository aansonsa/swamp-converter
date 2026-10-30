import Foundation
import AppKit

// Every contact the actions have with the outside world (panels, alerts, Finder, other apps, the pasteboard, the Trash) goes through `ActionsSystem.current`.
// The live value does the real thing; the self-tests swap in a recording one, so a test run never opens a Finder window, an alert or touches the real Trash.

/// What the "Copy to..." / "Move to..." folder picker shows.
struct FolderPrompt: Sendable, Equatable {
    var mode: TransferMode
    var startAt: URL?
    var itemCount: Int

    var title: L10n {
        mode == .copy ? L10n("Copy to…", "Копировать в…") : L10n("Move to…", "Переместить в…")
    }
    var message: L10n {
        let items = ActionText.items(itemCount)
        switch mode {
        case .copy: return L10n("Choose the folder to copy \(items.en) to.", "Выберите папку, в которую нужно скопировать: \(items.ru).")
        case .move: return L10n("Choose the folder to move \(items.en) to.", "Выберите папку, в которую нужно переместить: \(items.ru).")
        }
    }
    var buttonTitle: L10n { mode == .copy ? L10n("Copy", "Копировать") : L10n("Move", "Переместить") }
}

/// "Move N items to the Trash?" (asked for more than five items or any folder).
struct TrashConfirmation: Sendable, Equatable {
    var itemCount: Int
    var firstName: String
    var includesFolder: Bool
}

@MainActor
struct ActionsSystem {
    var chooseFolder: (FolderPrompt) async -> URL?
    var resolveConflict: ConflictResolver
    var confirmTrash: (TrashConfirmation) -> Bool
    var revealInFinder: ([URL]) -> Void
    var openWithDefaultApp: ([URL]) -> Void
    var openWithApp: (_ urls: [URL], _ app: URL) -> Void
    /// Where an application with this bundle identifier lives (nil = not installed).
    var applicationURL: (String) -> URL?
    /// Opens `folder` in the terminal application at `app`.
    var openFolderInTerminal: (_ folder: URL, _ app: URL) -> Void
    /// Which app the person picks for "Open with" (nil = cancelled). Gets the candidates, default first.
    var chooseApplication: (_ candidates: [(name: String, url: URL)], _ anchor: NSPoint) -> URL?
    var mouseLocation: () -> NSPoint
    var fs: TransferFS
    /// Copies and moves at least this big become a card in the Jobs window; smaller ones finish with a toast. nil = never a job.
    var jobThresholdBytes: Int64?
    var availableSpace: (URL) -> Int64?
    var supportsCloning: (URL) -> Bool

    static let defaultJobThreshold: Int64 = 256 * 1_048_576

    static var live = ActionsSystem(
        chooseFolder: { await ActionPanels.chooseFolder($0) },
        resolveConflict: { ActionPanels.resolveConflict($0) },
        confirmTrash: { ActionPanels.confirmTrash($0) },
        revealInFinder: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
        openWithDefaultApp: { urls in
            for url in urls { if !NSWorkspace.shared.open(url) { MessageCenter.shared.post(ResultActions.cannotOpenMessage(url), severity: .warning, symbol: "exclamationmark.triangle") } }
        },
        openWithApp: { urls, app in
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, error in
                guard let error else { return }
                Task { @MainActor in MessageCenter.shared.post(ConversionError.describe(error), severity: .warning, symbol: "exclamationmark.triangle") }
            }
        },
        applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        openFolderInTerminal: { folder, app in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: config) { _, error in
                guard let error else { return }
                Task { @MainActor in MessageCenter.shared.post(ConversionError.describe(error), severity: .warning, symbol: "exclamationmark.triangle") }
            }
        },
        chooseApplication: { ActionPanels.chooseApplication(candidates: $0, at: $1) },
        mouseLocation: { NSEvent.mouseLocation },
        fs: .live,
        jobThresholdBytes: ActionsSystem.defaultJobThreshold,
        availableSpace: { TransferSpace.available(in: $0) },
        supportsCloning: { TransferSpace.supportsCloning($0) })

    /// The value every action reads. Tests assign a recording copy and restore `.live` afterwards.
    static var current = ActionsSystem.live
}
