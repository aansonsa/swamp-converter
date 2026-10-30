import Foundation
import AppKit
import ServiceManagement

/// Self-tests of the menus, termination, single instance, login item, onboarding, About and the Info.plist contract.
enum AppShellTests {
    static func register(_ t: SelfTestRegistry) {
        registerMenus(t)
        registerLifecycle(t)
        registerWindows(t)
        registerPlist(t)
    }

    // MARK: Menus

    private static func registerMenus(_ t: SelfTestRegistry) {
        t.register("app.menu", "the status menu has the planned structure, in order, with a Cmd-, Settings item") {
            let builder = MenuBarMenu()            // kept alive: the items' targets are weak
            let menu = builder.makeMenu()
            let ids = menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? "?") }
            try expectEqual(ids, ["status", "-", "recent", "-", "addFiles", "openStudio", "downloadLink", "wheelClipboard", "newShelf", "-", "pauseGestures", "-", "settings", "about", "-", "quit"])
            let settings = try unwrap(menu.items.first { $0.identifier?.rawValue == "settings" })
            try expectEqual(settings.keyEquivalent, ","); try expect(settings.isEnabled)
            try expect(menu.items.allSatisfy { $0.isSeparatorItem || !$0.title.isEmpty })
            let recent = try unwrap(menu.items.first { $0.identifier?.rawValue == "recent" }?.submenu)
            try expect(!recent.items.isEmpty, "an empty history still shows a placeholder row")
        }
        t.register("app.menu", "the Dock menu mirrors the commands and a menu opened later is rebuilt, not cached") {
            let dockBuilder = MenuBarMenu(isDock: true)
            let dock = dockBuilder.makeMenu()
            try expectEqual(dock.items.compactMap { $0.identifier?.rawValue }, ["recent", "openStudio", "downloadLink"])
            let m = MenuBarMenu()
            let menu = m.makeMenu()
            defer { Loc.shared.set(.system) }
            Loc.shared.set(.english); m.menuNeedsUpdate(menu)
            let english = menu.items.first { $0.identifier?.rawValue == "openStudio" }?.title
            Loc.shared.set(.russian); m.menuNeedsUpdate(menu)
            let russian = menu.items.first { $0.identifier?.rawValue == "openStudio" }?.title
            try expect(english != nil && russian != nil && english != russian, "the next time the menu opens it speaks the new language")
            try expectEqual(menu.items.count, 16, "rebuilding keeps exactly one copy of every item")
        }
        t.register("app.menu", "status texts: idle, running, waiting, paused; recent results come from finished jobs, newest first") {
            Loc.shared.set(.english); defer { Loc.shared.set(.system) }
            try expectEqual(MenuBarMenu.statusTitle(running: 0, waiting: 0, paused: false, line: ""), "No jobs running")
            try expectEqual(MenuBarMenu.statusTitle(running: 2, waiting: 0, paused: false, line: ""), "2 running")
            try expectEqual(MenuBarMenu.statusTitle(running: 1, waiting: 3, paused: false, line: ""), "1 running, 3 waiting")
            try expectEqual(MenuBarMenu.statusTitle(running: 1, waiting: 0, paused: false, line: "Converting 2 of 5 \u{2013} 42%"), "Converting 2 of 5 \u{2013} 42%")
            try expectEqual(MenuBarMenu.statusTitle(running: 0, waiting: 2, paused: true, line: ""), "Queue paused")
            func rec(_ title: String, _ state: JobState, _ out: [String]) -> JobRecord {
                JobRecord(id: UUID(), title: title, operationID: "x", state: state, origin: .wheel, itemNames: [], outputs: out, errorMessage: nil, note: nil, startedAt: nil, finishedAt: nil, bytesIn: 0)
            }
            let history = [rec("c", .failed, ["/o/c.png"]), rec("b", .done, []), rec("a", .done, ["/o/a.png", "/o/a2.png"])] + (0..<14).map { rec("n\($0)", .done, ["/o/n\($0).png"]) }
            let recents = MenuBarMenu.recentOutputs(from: history)
            try expectEqual(recents.count, 10); try expectEqual(recents.first?.url.path, "/o/a.png")
        }
        t.register("app.menu", "the main menu has App, Edit and Window with Cmd-, and the editing commands text fields need") {
            let main = AppMenu.makeMainMenu(target: nil)
            try expectEqual(main.items.count, 3)
            let app = try unwrap(main.items[0].submenu)
            try expect(app.items.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }, "Settings Cmd-,")
            try expect(app.items.contains { $0.keyEquivalent == "q" && $0.action == #selector(NSApplication.terminate(_:)) })
            try expect(app.items.contains { $0.action == #selector(NSApplication.hide(_:)) })
            let edit = try unwrap(main.items[1].submenu)
            let keys = Set(edit.items.map(\.keyEquivalent))
            try expect(["z", "x", "c", "v", "a"].allSatisfy(keys.contains), "undo, cut, copy, paste, select all")
            try expect(edit.items.contains { $0.action == Selector(("undo:")) } && edit.items.contains { $0.action == Selector(("redo:")) })
            let window = try unwrap(main.items[2].submenu)
            try expect(window.items.contains { $0.action == #selector(NSApplication.arrangeInFront(_:)) })
        }
        t.register("app.menu", "the badge follows the job model: pink only while something runs or an error is unseen") {
            try expectEqual(MenuBarBadgeState.from(fraction: nil, running: 0, waiting: 0, hasUnseenError: false), .none)
            try expectEqual(MenuBarBadgeState.from(fraction: nil, running: 1, waiting: 0, hasUnseenError: false), .busy)
            try expectEqual(MenuBarBadgeState.from(fraction: 0.5, running: 1, waiting: 0, hasUnseenError: true), .progress(0.5), "running wins over an old error")
            try expectEqual(MenuBarBadgeState.from(fraction: 7, running: 1, waiting: 0, hasUnseenError: false), .progress(1))
            try expectEqual(MenuBarBadgeState.from(fraction: nil, running: 0, waiting: 0, hasUnseenError: true), .error)
            let view = MenuBarBadgeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            try expect(view.isHidden)
            view.apply(.progress(0.3)); try expect(!view.isHidden)
            view.apply(.none); try expect(view.isHidden)
        }
    }

    // MARK: Lifecycle

    private static func registerLifecycle(_ t: SelfTestRegistry) {
        t.register("app.lifecycle", "quit asks only when jobs are active, the setting is on and the quit is interactive") {
            try expect(AppTermination.needsConfirmation(activeJobs: 2, confirmSetting: true, systemInitiated: false))
            try expect(!AppTermination.needsConfirmation(activeJobs: 0, confirmSetting: true, systemInitiated: false))
            try expect(!AppTermination.needsConfirmation(activeJobs: 2, confirmSetting: false, systemInitiated: false))
            try expect(!AppTermination.needsConfirmation(activeJobs: 2, confirmSetting: true, systemInitiated: true), "log out / SIGTERM never block")
            for code in ["logo", "rlgo", "shut", "rest", "quia"] { try expect(AppTermination.isSystemQuitReason(AppTermination.fourCC(code)), code) }
            try expect(!AppTermination.isSystemQuitReason(AppTermination.fourCC("quit")))
            let runner = JobRunner(persistence: false)
            let settings = AppSettings(fileURL: AppPaths.makeTempDirectory(purpose: "app-term").appendingPathComponent("s.json"), autosave: false)
            var asked = false
            let saved = AppTermination.presenter
            AppTermination.presenter = { _, _ in asked = true; return .wait }
            defer { AppTermination.presenter = saved }
            let reply = AppTermination.shouldTerminate(NSApplication.shared, runner: runner, settings: settings)
            try expect(reply == .terminateNow && !asked, "an idle queue quits without a question")
        }
        t.register("app.lifecycle", "a second launch forwards only files and web / scheme URLs; the instance lock is exclusive and records the pid") {
            let (dir, file) = try AppTests.tempFile("clip.mp4")
            defer { AppPaths.removeTemp(dir) }
            let payload = SingleInstance.payload(from: ["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES", file.path, "clip.mp4", "https://example.com/v", "swampconverter://download?url=https%3A%2F%2Fexample.com",
                                                        "javascript:alert(1)", "/no/such/file.png", ""], currentDirectory: dir.path)
            try expectEqual(payload.count, 4, "\(payload)")
            try expect(payload[0].hasPrefix("file://") && payload[1].hasPrefix("file://"))
            let urls = SingleInstance.urls(fromUserInfo: ["urls": payload + ["ssh://host/x", "javascript:alert(1)", "not a url"]])
            try expectEqual(urls.count, 4, "other schemes are dropped on the receiving side too")
            try expect(SingleInstance.urls(fromUserInfo: nil).isEmpty && SingleInstance.urls(fromUserInfo: ["urls": 5]).isEmpty)
            let lock = dir.appendingPathComponent("test.lock")
            try expect(SingleInstance.acquireLock(at: lock), "first launch gets the lock")
            try expect(!SingleInstance.acquireLock(at: lock), "a second one does not")
            try expectEqual(SingleInstance.ownerPID(at: lock), getpid())
            SingleInstance.releaseLock()
            try expect(SingleInstance.acquireLock(at: lock), "the lock can be taken again once released")
            SingleInstance.releaseLock()
        }
        t.register("app.lifecycle", "login item: status mapping, and a bare executable can never register itself") {
            try expectEqual(LoginItem.state(for: .enabled, bundled: true), .enabled)
            try expectEqual(LoginItem.state(for: .notRegistered, bundled: true), .disabled)
            try expectEqual(LoginItem.state(for: .requiresApproval, bundled: true), .requiresApproval)
            try expectEqual(LoginItem.state(for: .notFound, bundled: true), .disabled, "a bundle the system has never been asked about (every fresh install) reads as off, not unavailable, so the one-shot default still tries to register it")
            try expectEqual(LoginItem.state(for: .enabled, bundled: false), .unavailable)
            if !LoginItem.isBundled {
                try expectEqual(LoginItem.state, .unavailable)
                var threw = false
                do { try LoginItem.set(enabled: true) } catch { threw = true }
                try expect(threw, "no registration from a build folder")
            }
        }
        t.register("app.lifecycle", "measurement hooks: process start time is sane, the wheel benchmark reports honestly when not connected") {
            let ms = try unwrap(AppBench.millisecondsSinceProcessStart())
            try expect(ms > 0 && ms < 3_600_000, "\(ms)")
            let saved = AppBench.wheelRunner
            defer { AppBench.wheelRunner = saved }
            AppBench.wheelRunner = nil
            let notConnected = await AppBench.run("wheel")
            AppBench.wheelRunner = { 0 }
            let connected = await AppBench.run("wheel")
            let unknown = await AppBench.run("nonsense")
            try expectEqual(notConnected, 2); try expectEqual(connected, 0); try expectEqual(unknown, 2)
        }
    }

    // MARK: Windows

    private static func registerWindows(_ t: SelfTestRegistry) {
        t.register("app.onboarding", "shown only on the first run; closing it in any way marks it done and it is never reshown") {
            try expect(OnboardingController.shouldShow(onboardingDone: false)); try expect(!OnboardingController.shouldShow(onboardingDone: true))
            let settings = AppSettings(fileURL: AppPaths.makeTempDirectory(purpose: "app-onb").appendingPathComponent("s.json"), autosave: false)
            let done = OnboardingController(settings: settings)
            settings.update { $0.onboardingDone = true }
            done.showIfNeeded()
            try expect(!done.isVisible, "a finished onboarding never opens by itself")
            settings.update { $0.onboardingDone = false }
            let fresh = OnboardingController(settings: settings)
            fresh.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            try expect(settings.data.onboardingDone && settings.data.firstRunDone)
        }
        t.register("app.onboarding", "four pages navigate forwards and back and the last Continue finishes; the wheel page shows the configured keys") {
            let m = OnboardingModel()
            var finished = 0
            m.onFinish = { finished += 1 }
            try expect(m.isFirst && !m.isLast)
            m.next(); try expectEqual(m.page, .hotkeys); m.next(); try expectEqual(m.page, .permissions); try expect(!m.isLast)
            m.next(); try expectEqual(m.page, .tools); try expect(m.isLast)
            m.back(); try expectEqual(m.page, .permissions); m.next(); m.next()
            try expectEqual(finished, 1); m.back(); m.back(); m.back(); m.back(); try expectEqual(m.page, .wheel)
            try expectEqual(OnboardingPage.allCases.map(\.rawValue), [0, 1, 2, 3], "the page dots and Page N of M follow the enum")
            var s = SettingsData()
            try expectEqual(OnboardingKeys.wheelKeys(s).map(\.glyph), ["\u{21E7}", "\u{2303}", "\u{2325}"])
            s.toolsKey = .none; s.actionsKey = .command
            try expectEqual(OnboardingKeys.wheelKeys(s).map(\.glyph), ["\u{21E7}", "\u{2318}"])
        }
        t.register("app.about", "About names the inspiration in both languages, knows its version and registers the Settings page") {
            for lang in [LanguageSetting.english, .russian] {
                Loc.shared.set(lang); defer { Loc.shared.set(.system) }
                let credit = AboutText.credit.text
                try expect(credit.contains("Sweetch") && credit.contains("@mmmorozov") && credit.contains("HandBrake"), credit)
                try expect(AboutText.requirement.text.contains("26"), "macOS 26 or later, no upper bound")
                try expect(!AboutText.requirement.text.lowercased().contains("only"))
            }
            Loc.shared.set(.english); defer { Loc.shared.set(.system) }
            try expectEqual(AboutInfo(version: "1.2", build: "34").versionLine, "Version 1.2 (34)")
            try expectEqual(AboutInfo(version: "dev", build: "0").versionLine, "Version dev")
            AboutWindowController.registerSettingsPage()
            try expect(SettingsPageRegistry.shared.pages.contains { $0.id == .about })
            // The owner's credit at the foot of About links to their own Instagram, over https.
            try expectEqual(MadeByLink.url.absoluteString, "https://www.instagram.com/aaa.aaa.aaa.aaa.aaa.aaaaaa")
            try expectEqual(AuthorGitHubLink.url.absoluteString, "https://github.com/aansonsa")
        }
    }

    // MARK: Info.plist contract

    private static func registerPlist(_ t: SelfTestRegistry) {
        t.register("app.plist", "Info.plist template: menu-bar app, one instance, URL scheme, both Services handlers exist, usage strings in Russian") {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let template = root.appendingPathComponent("Resources/Info.plist.template")
            guard let data = try? Data(contentsOf: template) else { try skipTest("source tree not available") }
            let plist = try unwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            try expectEqual(plist["LSUIElement"] as? Bool, true)
            try expectEqual(plist["LSMultipleInstancesProhibited"] as? Bool, true)
            try expectEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
            let urlTypes = try unwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
            try expect(urlTypes.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(DownloadURLScheme.scheme) == true })
            let services = try unwrap(plist["NSServices"] as? [[String: Any]])
            try expectEqual(services.count, 2)
            let provider = ServicesProvider()
            for service in services {
                let message = try unwrap(service["NSMessage"] as? String)
                try expect(provider.responds(to: Selector("\(message):userData:error:")), "ServicesProvider must implement \(message)")
                let title = try unwrap(service["NSMenuItem"] as? [String: String])
                try expect(title["default"]?.isEmpty == false && title["ru"]?.isEmpty == false, "Services titles in both languages")
            }
            let ru = try String(contentsOf: root.appendingPathComponent("Resources/ru.lproj/InfoPlist.strings"), encoding: .utf8)
            for key in plist.keys where key.hasSuffix("UsageDescription") { try expect(ru.contains("\"\(key)\""), "\(key) needs a Russian string") }
        }
    }
}
