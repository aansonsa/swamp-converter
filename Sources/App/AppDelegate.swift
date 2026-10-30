import AppKit
import SwiftUI

/// Launch order (the contract; budget: ready <= 0.8 s, nothing heavy before the first event):
///   1. language + appearance from settings  2. `EnginesBootstrap.registerAll()` (descriptors only)  3. `SettingsModule.install()`, `DownloadUIModule.install()`, About page
///   4. main menu + status item + menu  5. `JobsModule.start()`  6. `WheelController.shared.start()`  7. `AutomationEngine.start()`  8. `ShelfController.shared.restoreIfNeeded()`
///   9. services provider + `NSUpdateDynamicServices()`  10. Studio restored when it was open at quit  11. first-run onboarding (once, after the app is ready)
///   12. open at login switched on once (`LoginItem.applyDefaultOnce`; macOS shows its "Login item added" notice, not a permission prompt).
/// Windows and SwiftUI hierarchies are built lazily on first use. `applicationShouldTerminate` confirms when jobs run (`settings.confirmQuitWithJobs`). No permission prompt appears at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: MenuBarController?
    private let services = ServicesProvider()
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsEffects.applyAppearance(AppSettings.shared.data.appearance)
        EnginesBootstrap.registerAll()
        SettingsModule.install()
        DownloadUIModule.install()
        AboutWindowController.registerSettingsPage()
        AppMenu.shared.install()
        statusController = MenuBarController()
        statusController?.install()
        JobsModule.start()
        WheelController.shared.start()
        AutomationEngine.start()
        ShelfController.shared.restoreIfNeeded()
        DispatchQueue.global(qos: .background).async { AppPaths.sweepStaleTemp() }      // leftovers of a crashed run, never a running job's folder
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        SingleInstance.startListening { urls in
            if urls.isEmpty { AppLifecycle.showMainWindow() } else { URLRouter.handle(urls, origin: .dock) }
        }
        installTerminationSignal()
        StudioWindowController.shared.restoreIfNeeded()
        AppBench.writeReadyMarkerIfRequested()
        // The first-run window waits for the run loop, so the status item is on screen before it appears.
        DispatchQueue.main.async {
            OnboardingController.shared.showIfNeeded()
            LoginItem.applyDefaultOnce()
        }
    }

    /// Files dropped on the Dock icon / `open` events and `swampconverter://` URLs. Coalesced over 350 ms into ONE wheel (spec/wheel.md 19.9). A web link that macOS also hands over
    /// here is routed to the link wheel; whether it does for a drag onto the Dock icon is for the owner to confirm by hand (the supported ways are the menu-bar icon, the wheel, Services and the URL scheme).
    func application(_ application: NSApplication, open urls: [URL]) { URLRouter.handle(urls, origin: .dock) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { AppTermination.shouldTerminate(sender) }
    func applicationWillTerminate(_ notification: Notification) { AppTermination.willTerminate() }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { statusController?.dockMenu() }

    /// Clicking the Dock icon / opening the app again while no window is visible: Studio when it was open, else the Jobs window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppLifecycle.showMainWindow() }
        return true
    }

    /// SIGTERM (`kill`, the measurement script) quits like the Quit command, without the interactive confirmation. A dispatch source: zero cost while idle.
    private func installTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppTermination.systemInitiated = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        termSource = source
    }
}

@MainActor
enum AppLifecycle {
    /// Studio when one is open (brought forward) or was open at quit (restored); otherwise the Jobs window.
    static func showMainWindow() {
        let studio = StudioWindowController.shared
        if studio.openSessionCount > 0 { studio.show() }
        else if studio.wasOpenAtQuit { studio.restoreIfNeeded() }
        else { JobsWindowController.shared.show() }
    }
}
