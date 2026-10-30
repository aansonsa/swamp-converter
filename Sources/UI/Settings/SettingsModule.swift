import SwiftUI

// MODULE settings (owner: settings engineer). Prefix for new top-level types: Settings* / Layout* / Param*.
// Files: Sources/UI/Settings/*.
// Spec: spec/appfeatures.md 1 (every key), 2 (pages and dialogs), 6 (presets), 5.7 (watch-folder editor); spec/wheel.md 13 (customisation model), 14.1, 18.3 item 2 (layout editor);
//       spec/ux.md 4 (settings), 5 (onboarding and permissions), 6 (errors); spec/catalog.md 2.3 (parameter dialog), 6 (settings that change results);
//       spec/handbrake.md 6.3 (presets UI: the editor lives in Studio, Settings deep-links into it).
//
// Window rules (HIG): Cmd-, toolbar-style panes, the window fits the pane, title = pane, last pane restored, native `Form { }.formStyle(.grouped)` controls only, no fixed-width labels
// (Russian is 30-40% longer). Every page is built lazily when first shown (idle memory budget). EVERY option in `SettingsData` that a person can reasonably change has a control here;
// network-related settings live on the Downloader page (download-ui module) through the extension point below.

/// Stable page ids. Extensions add their own ids (`SettingsPageRegistry.register`).
struct SettingsPageID: Hashable, Sendable, ExpressibleByStringLiteral {
    var raw: String
    init(stringLiteral value: String) { raw = value }
    init(_ raw: String) { self.raw = raw }

    static let general: SettingsPageID = "general"          // language, appearance, menu-bar icon, login item, output folder rules, notifications, performance (concurrency, battery, free-space guard)
    static let wheel: SettingsPageID = "wheel"              // triggers (modifier keys, shake), size, haptics, per-kind layout editor with live preview wheel, link wheel order
    static let shortcuts: SettingsPageID = "shortcuts"      // the two global hotkeys with a recorder, presets, conflict notes (HotkeyManager.registrationNotes), the browser permission status rows
    static let recipes: SettingsPageID = "recipes"          // quick recipes per operation ("Edit in Studio..."), quality knobs, presets list (import / export), multi-output packs, "always strip metadata"
    static let folders: SettingsPageID = "folders"          // watched folders + one-click templates (all off by default), drop folder
    static let tools: SettingsPageID = "tools"              // detected tools (ffmpeg, cwebp, pandoc, soffice ...), versions, "Locate...", install hints (copyable commands), caps
    static let downloader: SettingsPageID = "downloader"    // provided by the download-ui module (install / update / consent / cookies / JS runtime / network activity)
    static let about: SettingsPageID = "about"              // provided by the app module (wordmark, version, credit line)
}

struct SettingsPageDescriptor: Identifiable {
    var id: SettingsPageID
    var title: L10n
    var symbol: String
    /// Sidebar / toolbar order (general 0, wheel 10, shortcuts 20, recipes 30, folders 40, tools 50, downloader 60, about 100).
    var order: Int
    /// Builds the page content lazily (called when the page is first shown).
    var make: @MainActor () -> AnyView
}

/// THE extension point for pages owned by other modules (download-ui registers "downloader", app registers "about").
@MainActor
final class SettingsPageRegistry: ObservableObject {
    static let shared = SettingsPageRegistry()
    @Published private(set) var pages: [SettingsPageDescriptor] = []
    func register(_ page: SettingsPageDescriptor) {
        pages.removeAll { $0.id == page.id }
        pages.append(page)
        pages.sort { $0.order < $1.order }
    }
}

enum SettingsModule {
    /// Registers the built-in pages and installs the quick-run parameter sheet. Called by the app at launch (cheap: no views are built).
    @MainActor
    static func install() {
        ensureBuiltInPages()
        installParameterSheet()
    }

    /// Registers the built-in pages (general ... tools, and a fallback About) once; pages owned by other modules (downloader, about) register themselves and replace the
    /// fallback. Idempotent: a page that is already registered (for example replaced by a richer one) is left alone. Page views are built lazily when first shown.
    @MainActor
    static func ensureBuiltInPages(registry: SettingsPageRegistry? = nil) {
        let registry = registry ?? SettingsPageRegistry.shared
        let builtIn: [(SettingsPageID, L10n, String, Int)] = [
            (.general, L10n("General", "Основные"), "gearshape", 0),
            (.wheel, L10n("Wheel", "Колесо"), "circle.hexagongrid", 10),
            (.shortcuts, L10n("Shortcuts", "Сочетания клавиш"), "keyboard", 20),
            (.recipes, L10n("Recipes", "Рецепты"), "slider.horizontal.3", 30),
            (.folders, L10n("Folders", "Папки"), "folder", 40),
            (.tools, L10n("Tools", "Инструменты"), "wrench.and.screwdriver", 50),
            (.about, L10n("About", "О программе"), "info.circle", 100),
        ]
        for (id, title, symbol, order) in builtIn where !registry.pages.contains(where: { $0.id == id }) {
            registry.register(SettingsPageDescriptor(id: id, title: title, symbol: symbol, order: order, make: {
                SettingsPageFactory.make(id) ?? AnyView(EmptyView())
            }))
        }
    }

    /// Sets `QuickRun.parameterPrompt`: the small sheet that asks only the fields named in `OperationMeta.quickPromptKeys` (trim start / end, fit-to-size target, a password)
    /// with the same field renderer Studio uses (`OptionFieldView` from studio-core): title = operation label, first line = file name or count, Run / Cancel, Enter runs, Esc cancels,
    /// remembered values per operation (never a password). Returns nil to `QuickRun` when the person cancels.
    @MainActor
    static func installParameterSheet(on quickRun: QuickRun? = nil, presenter: ParameterSheetPresenter? = nil) {
        let presenter = presenter ?? .shared
        (quickRun ?? .shared).parameterPrompt = { operation, items, fields, current in
            await presenter.ask(operation: operation, items: items, fields: fields, current: current)
        }
    }

    #if !SC_SHIPPING
    static func registerSelfTests() { SettingsTests.register() }
    #endif
}
