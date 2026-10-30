import SwiftUI

// The built-in pages, one file each: GeneralPage, WheelPage (+ WheelLayoutEditor), ShortcutsPage (+ HotkeyRecorder), RecipesPage (+ QuickRecipeEditor, PresetsSection),
// FoldersPage (+ FolderRuleEditor), ToolsPage, AboutSettingsPage. Each is a `Form { ... }.formStyle(.grouped)` bound to `AppSettings.shared` through
// `settings.binding(...)`; no page keeps its own copy of a setting. This file only maps a page id to its view.

@MainActor
enum SettingsPageFactory {
    /// The view of a built-in page; nil for an id that another module provides.
    static func make(_ id: SettingsPageID) -> AnyView? {
        switch id {
        case .general: return AnyView(GeneralPage())
        case .wheel: return AnyView(WheelPage())
        case .shortcuts: return AnyView(ShortcutsPage())
        case .recipes: return AnyView(RecipesPage())
        case .folders: return AnyView(FoldersPage())
        case .tools: return AnyView(ToolsPage())
        case .about: return AnyView(AboutSettingsPage())
        default: return nil
        }
    }
}
