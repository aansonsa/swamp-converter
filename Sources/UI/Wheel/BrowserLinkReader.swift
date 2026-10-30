import Foundation
import AppKit
import ApplicationServices

// BrowserLinkReader: "one keystroke from the browser". Works out the link by itself: no opening, copying or pasting.
// Link resolution priority (spec: the ONE-KEYSTROKE block): (1) a URL inside the SELECTED text (Accessibility AXSelectedText when the permission is granted,
// otherwise skipped silently); (2) the URL of the active tab of the front window of the frontmost browser via AppleScript on a BACKGROUND thread with a short timeout
// and a graceful failure; (3) a URL on the clipboard. The tab title is fetched too (wheel header). Firefox: (1), then the clipboard, then a hint. A browser outside the named
// list (`BrowserKind.probeOther`, by what Launch Services says it can open, not by name) gets the same treatment as a named Chromium browser; if its own dictionary does
// not understand the request it gets the same copy-the-address hint as Firefox instead of a misleading "no window".
// Automation consent is per browser: Info.plist NSAppleEventsUsageDescription (both languages), a friendly first-use explanation BEFORE the system prompt, and a recovery path
// when denied (a button that opens System Settings > Privacy & Security > Automation).

enum BrowserLinkProblem: Equatable, Sendable {
    /// The user has not decided yet / is about to see the system prompt: show the friendly explanation first (once per browser).
    case needsAutomationExplanation(BrowserKind)
    case automationDenied(BrowserKind)
    /// This browser's reported "current page" cannot be trusted at all: Firefox shares no address; Dia's dictionary answers but, for a page reached by
    /// client-side navigation inside an existing tab (a YouTube video opened from its own homepage tab, say), keeps reporting the tab's very first full
    /// page load — confirmed live, three different ways, all stale — so a wrong-but-valid-looking link would silently replace whatever the person actually
    /// meant. Always go straight to the honest "copy the address" path for these rather than trusting an answer that might quietly be wrong.
    case noReliableTabURL(BrowserKind)
    /// The browser is open and reachable, but its own AppleScript dictionary does not understand the request (an unrecognised browser guessed at the
    /// Chromium words and guessed wrong, or a real browser's current build has no AppleScript support at all): copy the address instead.
    case notUnderstood(BrowserKind)
    case noWindow(BrowserKind)
    case timedOut(BrowserKind)
    /// The page is not downloadable (about:, file:, chrome://, private host ...): the reason to show.
    case notDownloadable(LinkRejection)
    case noLinkFound

    var message: L10n {
        switch self {
        case .needsAutomationExplanation(let b):
            return L10n("Swamp Converter asks \(b.displayName) for the address of the page you are looking at, so the shortcut can download it. macOS will ask you to allow this once.",
                        "Swamp Converter запрашивает у \(b.displayName) адрес страницы, на которую вы смотрите, чтобы сочетание клавиш могло её скачать. macOS один раз попросит разрешения.")
        case .automationDenied(let b):
            return L10n("Access to \(b.displayName) is turned off. Allow it in System Settings > Privacy & Security > Automation.", "Доступ к \(b.displayName) выключен. Разрешите его в Системных настройках > Конфиденциальность и безопасность > Автоматизация.")
        case .noReliableTabURL(let b):
            return L10n("\(b.displayName) does not share the page address reliably. Copy it (Command-L, then Command-C) and press the shortcut again.",
                        "\(b.displayName) не сообщает адрес страницы надёжно. Скопируйте его (Command-L, затем Command-C) и нажмите сочетание ещё раз.")
        case .notUnderstood(let b):
            return L10n("\(b.displayName) does not share the page address this way. Copy it (Command-L, then Command-C) and press the shortcut again.",
                        "\(b.displayName) не передаёт адрес страницы таким способом. Скопируйте его (Command-L, затем Command-C) и нажмите сочетание ещё раз.")
        case .noWindow(let b): return L10n("\(b.displayName) has no open window.", "В \(b.displayName) нет открытого окна.")
        case .timedOut(let b): return L10n("\(b.displayName) did not answer in time.", "\(b.displayName) не ответил вовремя.")
        case .notDownloadable(let r): return r.message
        case .noLinkFound: return L10n("No link found. Select a link or copy an address.", "Ссылка не найдена. Выделите ссылку или скопируйте адрес.")
        }
    }
}

struct BrowserLinkResult: Sendable {
    enum Source: String, Sendable { case selection, activeTab, clipboard }
    var link: LinkItem?
    /// The tab / page title for the wheel header (nil when unknown).
    var pageTitle: String?
    var source: Source?
    var problem: BrowserLinkProblem?
}

@MainActor
final class BrowserLinkReader {
    static let shared = BrowserLinkReader()

    /// Swift-side limit for the tab script (the script limits itself to 1 s as well).
    static let scriptTimeout: TimeInterval = 1.5

    /// Injection points for tests; the defaults talk to the real system.
    struct Environment {
        var selectedText: () async -> String? = { await Task.detached(priority: .userInitiated) { BrowserLinkReader.readSelectedText() }.value }
        var clipboardText: @MainActor () -> String? = { BrowserLinkReader.readClipboardText() }
        var automation: @MainActor (BrowserKind) -> Automation = { BrowserLinkReader.shared.systemAutomationStatus(for: $0) }
        var isExplained: @MainActor (BrowserKind) -> Bool = { BrowserLinkReader.explainedDefaults(for: $0) }
        var runScript: (String, TimeInterval) async -> AppleScriptOutcome = { await AppleScriptRunner.run($0, timeout: $1) }
        var askConsent: (BrowserKind) async -> AppleScriptRunner.Consent = { await AppleScriptRunner.consent(for: $0.bundleID, ask: true) }
        /// A real but unrecognised browser, found by what the system says it can do rather than by name (see `BrowserKind.probeOther`).
        var genericBrowser: (String) -> BrowserKind? = { BrowserKind.probeOther(bundleID: $0) }
    }
    var environment = Environment()

    /// The whole procedure for the hotkey / "download this page" shortcut. `frontmostBundleID` defaults to `NSWorkspace.shared.frontmostApplication`.
    /// Never blocks the main thread: AppleScript runs on a background queue with a ~1.5 s timeout. Returns a result with `problem` set instead of throwing.
    func readCurrent(frontmostBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier) async -> BrowserLinkResult {
        let browser = BrowserKind(bundleID: frontmostBundleID) ?? frontmostBundleID.flatMap(environment.genericBrowser)
        var problem: BrowserLinkProblem?

        // (1) A link inside the selected text.
        if let text = await environment.selectedText(), let link = LinkParsing.downloadableLinks(in: text, source: L("Selection", "Выделение")).first {
            return BrowserLinkResult(link: link, pageTitle: nil, source: .selection, problem: nil)
        }

        // (2) The active tab of the front window.
        if let browser {
            if browser.exposesTabURL, let script = BrowserScripts.activeTabScript(for: browser) {
                let tab = await readActiveTab(browser: browser, script: script)
                if let link = tab.link { return BrowserLinkResult(link: link, pageTitle: tab.title, source: .activeTab, problem: nil) }
                if let p = tab.problem {
                    // No clipboard fallback when access is the problem: an old address on the clipboard was opened (or downloaded by Control-Option-D) instead of
                    // saying that the browser is not allowed, and the person never learned why the page in front of them was ignored.
                    switch p {
                    case .needsAutomationExplanation, .automationDenied: return BrowserLinkResult(link: nil, pageTitle: nil, source: nil, problem: p)
                    default: problem = p
                    }
                }
            } else {
                problem = .noReliableTabURL(browser)
            }
        }

        // (3) A link on the clipboard.
        if let text = environment.clipboardText(), let link = LinkParsing.downloadableLinks(in: text, source: L("Clipboard", "Буфер обмена")).first {
            return BrowserLinkResult(link: link, pageTitle: nil, source: .clipboard, problem: problem)
        }
        return BrowserLinkResult(link: nil, pageTitle: nil, source: nil, problem: problem ?? .noLinkFound)
    }

    private struct TabRead { var link: LinkItem?; var title: String?; var problem: BrowserLinkProblem? }

    private func readActiveTab(browser: BrowserKind, script: String) async -> TabRead {
        switch environment.automation(browser) {
        case .browserNotRunning: return TabRead(problem: .noWindow(browser))
        case .denied: return TabRead(problem: .automationDenied(browser))
        case .notDetermined:
            // Our own explanation comes first (once per browser); only then the system dialog.
            if !environment.isExplained(browser) { return TabRead(problem: .needsAutomationExplanation(browser)) }
            switch await environment.askConsent(browser) {
            case .granted: break
            case .denied: return TabRead(problem: .automationDenied(browser))
            case .targetNotRunning: return TabRead(problem: .noWindow(browser))
            default: return TabRead(problem: .timedOut(browser))
            }
        case .granted: break
        }
        switch await environment.runScript(script, Self.scriptTimeout) {
        case .timedOut: return TabRead(problem: .timedOut(browser))
        case .failure(let number, _):
            switch number {
            case AppleScriptOutcome.notPermitted: return TabRead(problem: .automationDenied(browser))
            case AppleScriptOutcome.appleEventTimedOut: return TabRead(problem: .timedOut(browser))
            case AppleScriptOutcome.eventNotHandled: return TabRead(problem: .notUnderstood(browser))
            default: return TabRead(problem: .noWindow(browser))
            }
        case .text(let text):
            if BrowserScripts.isNoWindow(text) { return TabRead(problem: .noWindow(browser)) }
            guard let parsed = BrowserScripts.parseResult(text) else { return TabRead(problem: .noLinkFound) }
            switch LinkParsing.validate(parsed.url.absoluteString) {
            case .success(let clean): return TabRead(link: LinkItem(url: clean, title: parsed.title, sourceName: browser.displayName), title: parsed.title)
            case .failure(let rejection): return TabRead(title: parsed.title, problem: .notDownloadable(rejection))
            }
        }
    }

    // MARK: Selection and clipboard

    /// (1) Accessibility `AXSelectedText` of the focused element, only when `AXIsProcessTrusted()`; nil otherwise (silent). Never asks for the permission by itself.
    func selectedText() -> String? { Self.readSelectedText() }

    nonisolated static func readSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The clipboard as text, only as the direct result of the shortcut (macOS 15.4+ may ask "Paste from other apps"); nil when empty, denied or not text.
    nonisolated static func readClipboardText() -> String? {
        let pb = NSPasteboard.general
        if #available(macOS 15.4, *), pb.accessBehavior == .alwaysDeny { return nil }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL],
           let web = urls.first(where: { !$0.isFileURL }) { return web.absoluteString }
        return pb.string(forType: .string)
    }

    // MARK: Automation consent

    /// Consent state without prompting (`AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`).
    enum Automation: Equatable, Sendable { case granted, denied, notDetermined, browserNotRunning }
    func automationStatus(for browser: BrowserKind) -> Automation { environment.automation(browser) }

    func systemAutomationStatus(for browser: BrowserKind) -> Automation {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first != nil else { return .browserNotRunning }
        switch AppleScriptRunner.consentSync(bundleID: browser.bundleID, ask: false) {
        case .granted: return .granted
        case .denied: return .denied
        case .targetNotRunning: return .browserNotRunning
        case .notDetermined, .failed: return .notDetermined
        }
    }

    /// Shows the system consent dialog (after our own explanation) and waits for the answer.
    func requestAutomation(for browser: BrowserKind) async -> Automation {
        switch await environment.askConsent(browser) {
        case .granted: return .granted
        case .denied: return .denied
        case .targetNotRunning: return .browserNotRunning
        default: return .notDetermined
        }
    }

    /// Opens System Settings > Privacy & Security > Automation (deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`).
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }

    // MARK: "Explained once per browser"

    private nonisolated static let explainedKey = "app.swampconverter.wheel.automationExplained"

    nonisolated static func explainedDefaults(for browser: BrowserKind) -> Bool {
        (UserDefaults.standard.stringArray(forKey: explainedKey) ?? []).contains(browser.bundleID)
    }

    /// Records that the explanation was shown for `browser` (and the global flag in the settings, which Settings > Downloader reads).
    func markExplained(_ browser: BrowserKind) {
        var list = UserDefaults.standard.stringArray(forKey: Self.explainedKey) ?? []
        if !list.contains(browser.bundleID) { list.append(browser.bundleID); UserDefaults.standard.set(list, forKey: Self.explainedKey) }
        AppSettings.shared.update { $0.downloader.browserAutomationExplained = true }
    }
}
