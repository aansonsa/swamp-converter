import AppKit
import SwiftUI

// MODULE app (owner: app + packaging engineer). Prefix for new top-level types: App* / MenuBar* / Services* / Onboarding* / About* / Login*.
// Files: Sources/App/*, Resources/Info.plist.template, Resources/*.lproj/*, Resources/tools/*, scripts/package.sh, scripts/install.sh, scripts/measure.sh (+ README packaging notes).
// Spec: spec/appfeatures.md 7 (menu bar, single instance, autostart, notifications, hotkey, drops), 2.9 (dialogs), 9 (Windows -> macOS map); spec/platform.md 7-9 (Services, login item,
//       notifications, packaging recipe, exFAT, icon, Info.plist keys), 10 (build facts); spec/ux.md 2 (menu bar), 5 (onboarding); the PERFORMANCE AND SIZE and BRAND blocks of the brief.
//
// What the app module owns: the entry point, AppDelegate (launch order, activation policy, Dock menu, `application(_:open:)`), the status item + menu, Services (NSServices), the URL scheme
// handler, Dock / menu-bar drops, single instance, login item, first-run onboarding, About, the main menu, Info.plist, the .lproj strings, packaging and the performance measurements.
// It calls the other modules ONLY through their skeleton APIs: WheelController.shared.start(), SettingsWindowController.shared.show(page:), JobsWindowController.shared.show(),
// StudioWindowController.shared.show(...), DownloadService.shared.start(...), EnginesBootstrap.registerAll(), ShelfController.shared.restoreIfNeeded(), AutomationEngine.start().

enum AppModule {
    #if !SC_SHIPPING
    @MainActor
    static func registerSnapshots() { AppSnapshots.register() }
    #endif
    #if !SC_SHIPPING
    /// Menu-bar icon legibility snapshot at 18 pt (template image on light / dark menu bar), onboarding, About, status menu states.
    static func registerSelfTests() { AppTests.register() }
    #endif
}

/// Process entry for the menu-bar app (called by main.swift).
enum AppMain {
    @MainActor
    static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
