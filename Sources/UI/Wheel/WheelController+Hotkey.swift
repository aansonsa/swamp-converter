import Foundation
import AppKit

// The two global shortcuts. The wheel shortcut works out WHAT to act on (`WheelHotkeyResolver`: pure order in `WheelHotkeyPlan`, readers injectable), then opens a click-mode
// wheel. The download shortcut skips the wheel and starts the default download of the page in front (or, when the front browser could not share its tab and
// the link came off the clipboard, opens the link wheel so that link is confirmed rather than downloaded blind).

/// The result of looking around: something to act on, a permission step, or a calm message.
enum WheelHotkeyOutcome {
    case link(LinkItem, pageTitle: String?)
    case files([FileItem])
    case clipboardImage(FileItem)
    case clipboardLinks([LinkItem])
    case needsPermission(WheelPermissionKind)
    case message(L10n)
}

/// Resolves the hotkey's context. The readers default to the real system; tests replace them.
@MainActor
struct WheelHotkeyResolver {
    var browser: (String?) async -> BrowserLinkResult = { await BrowserLinkReader.shared.readCurrent(frontmostBundleID: $0) }
    var finder: () async -> FinderSelectionReader.Outcome = { await FinderSelectionReader.shared.read() }
    var clipboard: () -> ClipboardContent = { ClipboardSource.read(incomingFolder: AppPaths.incomingFolder(custom: AppSettings.shared.data.incomingFolder)) }
    /// A real but unrecognised browser, found by what the system says it can do rather than by name (see `BrowserKind.probeOther`).
    var genericBrowser: (String) -> BrowserKind? = { BrowserKind.probeOther(bundleID: $0) }

    func resolve(frontmostBundleID: String?, settings: SettingsData) async -> WheelHotkeyOutcome {
        let steps = WheelHotkeyPlan.steps(frontmostBundleID: frontmostBundleID, hotkeyReadsBrowser: settings.hotkeyReadsBrowser,
                                          usesFinderSelection: settings.gestures.hotkeyUsesFinderSelection, genericBrowser: genericBrowser)
        var denied: WheelPermissionKind?
        var note: L10n?
        for step in steps {
            switch step {
            case .browserLink:
                let r = await browser(frontmostBundleID)
                if let link = r.link { return .link(link, pageTitle: r.pageTitle ?? link.title) }
                switch r.problem {
                case .needsAutomationExplanation(let b)?: return .needsPermission(.explainBrowser(b))
                case .automationDenied(let b)?: denied = .deniedBrowser(b)
                case let p?: note = p.message
                case nil: break
                }
            case .finderSelection:
                switch await finder() {
                case .files(let items): return .files(items)
                case .needsExplanation: return .needsPermission(.explainFinder)
                case .denied: denied = .deniedFinder
                case .failed(let message): note = L10n(message, message)
                case .empty: break
                }
            case .clipboard:
                switch clipboard() {
                case .files(let items): return .files(items)
                case .image(let item):
                    if settings.offerClipboardImage { return .clipboardImage(item) }
                    ClipboardSource.discard(item)
                case .links(let links): return .clipboardLinks(links)
                case .denied: note = ClipboardContent.denied.hint
                case .empty: break
                }
            }
        }
        if let denied { return .needsPermission(denied) }
        return .message(note ?? WheelController.nothingToConvert)
    }
}

extension WheelController {
    // MARK: Wheel shortcut

    /// The global hotkey: reads the context (see `WheelContext.decide`): front app a known browser -> `BrowserLinkReader.readCurrent` -> link wheel (header = page title + host);
    /// Finder -> the Finder selection (`FinderSelectionReader`) -> file wheel; nothing there but an image on the clipboard -> the clipboard wheel.
    /// Shows the first-use Automation explanation before the system prompt and a recovery path when denied (`BrowserLinkProblem`).
    func presentForHotkey() async {
        guard !hotkeyBusy else { return }
        hotkeyBusy = true
        defer { hotkeyBusy = false }
        // Pressing the shortcut again while the wheel is open closes it (a toggle).
        if isVisible { close(); return }
        let front = frontmostBundleID()
        let anchor = NSEvent.mouseLocation                                // where the pointer is NOW, not after the slow readers return
        var outcome = await hotkeyResolver.resolve(frontmostBundleID: front, settings: AppSettings.shared.data)
        if case .needsPermission(let kind) = outcome, kind.isExplanation {
            // First use: explain, remember that we did, then read again; the system dialog follows from the reader.
            guard await WheelPermissionPrompt.shared.ask(kind) == .primary else { return }
            markExplained(kind)
            outcome = await hotkeyResolver.resolve(frontmostBundleID: front, settings: AppSettings.shared.data)
        }
        await show(outcome, anchor: anchor)
    }

    /// "Wheel for clipboard" (menu bar / Dock menu): the clipboard step of the shortcut on its own. Files, then links, then a picture; the picture goes through `ClipboardSource`,
    /// so closing the wheel without a choice discards the saved screenshot and a result can be pasted back as a file.
    func presentClipboardWheel(anchor: NSPoint? = nil) {
        close()
        let point = anchor ?? NSEvent.mouseLocation
        switch hotkeyResolver.clipboard() {
        case .files(let items):
            present(IncomingInput(files: items, origin: .clipboard), anchor: point)
        case .links(let links):
            present(IncomingInput(files: [], links: links, origin: .clipboard, pageTitle: links.first?.title), anchor: point, preferLinks: true)
        case .image(let item):
            if AppSettings.shared.data.offerClipboardImage {
                presentClipboard(image: item, anchor: point)
            } else {
                ClipboardSource.discard(item)
                toast(Self.clipboardEmptyMessage, symbol: "doc.on.clipboard")
            }
        case .denied:
            toast(ClipboardContent.denied.hint ?? Self.clipboardEmptyMessage, severity: .warning, symbol: "doc.on.clipboard")
        case .empty:
            toast(Self.clipboardEmptyMessage, symbol: "doc.on.clipboard")
        }
    }

    static let clipboardEmptyMessage = L10n("Copy a file, a link or a picture first.", "Сначала скопируйте файл, ссылку или картинку.")

    func markExplained(_ kind: WheelPermissionKind) {
        switch kind {
        case .explainBrowser(let b): linkReader.markExplained(b)
        case .explainFinder: FinderSelectionReader.shared.markExplained()
        case .explainAccessibility, .deniedBrowser, .deniedFinder: break
        }
    }

    /// Opens whatever `outcome` calls for.
    func show(_ outcome: WheelHotkeyOutcome, anchor: NSPoint) async {
        switch outcome {
        case .link(let link, let title):
            present(IncomingInput(files: [], links: [link], origin: .hotkey, pageTitle: title), anchor: anchor, preferLinks: true)
        case .clipboardLinks(let links):
            present(IncomingInput(files: [], links: links, origin: .hotkey, pageTitle: links.first?.title), anchor: anchor, preferLinks: true)
        case .files(let items):
            present(IncomingInput(files: items, origin: .hotkey), anchor: anchor)
        case .clipboardImage(let item):
            presentClipboard(image: item, anchor: anchor)
        case .needsPermission(let kind):
            if await WheelPermissionPrompt.shared.ask(kind) == .primary { openPermissionTarget(kind) }
        case .message(let text):
            toast(text, symbol: "tray")
        }
    }

    /// "Open Automation settings" (denied) or the system dialog (a second explanation never happens: `markExplained` was recorded).
    func openPermissionTarget(_ kind: WheelPermissionKind) {
        switch kind {
        case .deniedBrowser, .deniedFinder: SettingsLinks.open(SettingsLinks.automation)
        case .explainBrowser, .explainFinder, .explainAccessibility: break
        }
    }

    // MARK: Download shortcut

    /// The second hotkey: resolves the current page link and starts `DownloadService.shared.start(link:mode:)` with `settings.downloader.defaultMode` WITHOUT a wheel;
    /// the download-ui toast confirms. Unusable context -> a calm toast (`MessageCenter`). One exception: a clipboard link picked up only because the front
    /// browser could not share its tab opens the link wheel, since nothing proves that clipboard address is the page on screen.
    func downloadCurrentPageNow() async {
        guard !hotkeyBusy else { return }
        hotkeyBusy = true
        defer { hotkeyBusy = false }
        let front = frontmostBundleID()
        var result = await linkReader.readCurrent(frontmostBundleID: front)
        if case .needsAutomationExplanation(let b)? = result.problem {
            guard await WheelPermissionPrompt.shared.ask(.explainBrowser(b)) == .primary else { return }
            linkReader.markExplained(b)
            result = await linkReader.readCurrent(frontmostBundleID: front)
        }
        guard var link = result.link else {
            if case .automationDenied(let b)? = result.problem {
                if await WheelPermissionPrompt.shared.ask(.deniedBrowser(b)) == .primary { openPermissionTarget(.deniedBrowser(b)) }
            } else {
                toast(result.problem?.message ?? BrowserLinkProblem.noLinkFound.message, severity: .warning, symbol: "link.badge.plus")
            }
            return
        }
        if link.title == nil { link.title = result.pageTitle }
        // A browser was in front but could not hand over its own tab (Dia, Firefox, a refusing or slow one), so the link came off the clipboard — which may
        // hold an address copied long ago. Starting that silently would download something the person is not looking at; show the link wheel instead (its
        // header names the page and site) so one click confirms what actually gets downloaded.
        if result.source == .clipboard, result.problem != nil {
            await show(.link(link, pageTitle: link.title), anchor: NSEvent.mouseLocation)
            return
        }
        let outcome = await startDownload(link)
        switch outcome {
        case .started:
            // The download-ui module's "started" hook shows the confirmation when it is installed; without it (CLI, tests) say it here.
            if !confirmsDownloadItself() {
                let name = link.displayTitle
                toast(L10n("Download started: \(name)", "Загрузка началась: \(name)"), symbol: "arrow.down.circle")
            }
        case .failed(let message):
            toast(L10n(message, message), severity: .error, symbol: "exclamationmark.octagon")
        case .needsConsent, .needsInstall, .rejected:
            break                                                          // the service's hooks have already told the person (or the person declined)
        }
    }
}
