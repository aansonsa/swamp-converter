import Foundation
import AppKit

// MODULE actions (owner: actions engineer). Prefix for new top-level types: Action* / Shelf* / Result*.
// Files: Sources/Actions/*.
// Spec: spec/appfeatures.md 3 (Actions wheel + shelf), 4 (Jobs window result handling), 7.6 (where files come from); spec/catalog.md 3.10; spec/platform.md 8 (sharing, preview, reveal);
//       LIFE-IMPROVER block J (result handling) of the project brief.
//
// The Actions wheel is the third ring: app-side operations that run in the app, show no progress card and are never offered to watched folders.
// `ResultActions` (ResultActions.swift) is the SAME functionality for finished jobs: the Jobs window, the notification actions and the menu-bar menu call it.
//
//   ActionOperations.swift          the ten wheel sectors
//   ActionTransfer*.swift           Copy / Move: planner (conflicts), runner (atomic, verified), service (inline or Jobs card), job operation
//   ActionCopyEngine.swift          clonefile / copyfile(3) with progress and cancellation
//   ActionPanels.swift              folder picker, conflict alert, Trash alert, Open With menu
//   ActionsSystem.swift             the one seam to Finder, panels, other apps, the Trash (tests swap it)
//   ActionShareQuickLook.swift      Share menu and Quick Look panel
//   Shelf*.swift                    the floating shelf
//   ActionsTests*.swift, ActionsSnapshots.swift

enum ActionsEngine {
    /// Registers the Actions wheel in its fixed order: Copy, Move, Copy path, Terminal, Shelf ("Float"), Share, then the macOS extras Reveal, Open With, Quick Look and
    /// Move to Trash. ("Paste as file" for clipboard results is `ResultActions.pasteAsFile`, offered by the Jobs UI next to a finished clipboard job.)
    /// Registered after the conversions but before presets.
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(ActionsCatalog.operations())
    }

    #if !SC_SHIPPING
    /// Acceptance of spec/wheel.md 19.13 (default order, folders hide Share), copy / move into a temp folder with conflicts, path formats, shelf model.
    static func registerSelfTests() {
        ActionsTests.register()
        ActionsTransferTests.register()
        ActionsShelfTests.register()
    }
    #endif

    #if !SC_SHIPPING
    /// Shelf (empty, three files, many files, long Russian names) and the conflict / Trash alert wording, light and dark, English and Russian.
    @MainActor
    static func registerSnapshots() { ActionsSnapshots.register() }
    #endif
}

enum ActionsCatalog {
    /// The ten wheel sectors in their fixed order, then the hidden operation that carries a big copy or move as a Jobs card (never on a wheel, never in the Studio).
    @MainActor
    static func operations() -> [Operation] {
        [CopyAction(), MoveAction(), CopyPathAction(), TerminalAction(), ShelfAction(), ShareAction(), RevealAction(), OpenWithAction(), QuickLookAction(), TrashAction(),
         TransferJobOperation()]
    }
}
