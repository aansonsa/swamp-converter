import AppKit
import UniformTypeIdentifiers

/// The commands the menu bar, the Dock menu and the main menu share. One implementation, so a command behaves the same wherever it is chosen.
@MainActor
enum AppCommands {
    static func openStudio() { StudioWindowController.shared.show() }

    static func openJobs() { JobsWindowController.shared.show() }

    static func showSettings(page: SettingsPageID? = nil) { SettingsWindowController.shared.show(page: page) }

    static func showAbout() { AboutWindowController.shared.show() }

    static func downloadFromLink() { DownloadSheetController.shared.show(link: nil, prefillFromClipboard: true) }

    /// "Add Files...": an open panel, then the wheel at the pointer (Studio when Option is held).
    static func addFiles(anchor: NSPoint? = nil) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = L("Add Files", "Добавить файлы")
        panel.prompt = L("Add", "Добавить")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor in URLRouter.present(files: urls, origin: .menubar, anchor: anchor, forceStudio: optionHeld) }
        }
    }

    /// "Wheel for clipboard": the wheel module reads the clipboard (files, then links, then a picture saved as a PNG in the incoming folder) and opens the matching wheel.
    static func wheelForClipboard(anchor: NSPoint? = nil) {
        WheelController.shared.presentClipboardWheel(anchor: anchor)
    }

    static func toggleGesturesPaused() { setGesturesPaused(!AppSettings.shared.data.gesturesPaused) }

    static func setGesturesPaused(_ paused: Bool) {
        AppSettings.shared.update { $0.gesturesPaused = paused }
        WheelController.shared.setPaused(paused)
    }

    static func quit() { NSApp.terminate(nil) }
}
