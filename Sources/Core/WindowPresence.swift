import AppKit

// The app is a menu-bar app (LSUIElement, activation policy .accessory). While a real window is open (Studio, Settings, Jobs, About) a Dock icon and a Cmd-Tab entry are
// what people expect (HIG: keep the Dock icon while a document-style window is open, and mirror menu commands in the Dock menu). Windows report themselves here; this
// object counts them and switches the policy. Every window controller of the UI modules calls `opened` / `closed` (the Studio window is the one that matters most).

@MainActor
final class WindowPresence {
    static let shared = WindowPresence()
    private var open = Set<String>()

    /// Pure rule (unit-tested): regular (Dock icon) while any window is open AND the user keeps "show Dock icon with Studio" on; otherwise accessory.
    nonisolated static func desiredPolicy(openWindows: Int, showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        openWindows > 0 && showDockIcon ? .regular : .accessory
    }

    var openCount: Int { open.count }

    /// Puts a window of this menu-bar app in front of every other app. The Dock-icon policy switches first (switching it after activating left the window behind the app
    /// the person was in: "Download from Link…" opened in the background), then the app asks to be active, and `orderFrontRegardless` puts the window on top even when
    /// macOS turns the activation request down. A switch to the regular policy completes on the next turn of the run loop, so the window is made key once more then.
    func present(_ window: NSWindow, id: String?) {
        if let id { opened(id) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// `id` is any stable string per window ("studio-<uuid>", "settings", "jobs", "about").
    func opened(_ id: String) { open.insert(id); apply() }
    func closed(_ id: String) { open.remove(id); apply() }
    /// The Dock-icon setting changed (Settings > General): follow it at once, not only when the next window opens or closes.
    func settingChanged() { apply() }

    private func apply() {
        // Only an app that has an NSApplication (not the CLI or the self-test harness) changes policy.
        guard NSApplication.shared.delegate != nil else { return }
        let want = Self.desiredPolicy(openWindows: open.count, showDockIcon: AppSettings.shared.data.showDockIconWithStudio)
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }
}
