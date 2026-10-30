import SwiftUI
import AppKit

// The friendly sheets in front of the two Automation permissions (spec/ux.md 5): a short explanation BEFORE macOS shows its own dialog (one "Continue" button, never
// imitating the system alert), and, after a refusal, a way back into System Settings. They appear only as the direct result of the hotkey, never at launch.

enum WheelPermissionKind: Equatable, Sendable {
    case explainBrowser(BrowserKind)
    case explainFinder
    /// Reading a link the person has selected, in any app (the Accessibility permission).
    case explainAccessibility
    case deniedBrowser(BrowserKind)
    case deniedFinder

    var isExplanation: Bool {
        switch self { case .explainBrowser, .explainFinder, .explainAccessibility: return true; case .deniedBrowser, .deniedFinder: return false }
    }
}

enum WheelPermissionChoice: Equatable, Sendable { case primary, notNow }

/// The words of a sheet. Pure and bilingual, so the tests and the snapshots read the same strings.
struct WheelPermissionCopy: Equatable {
    var symbol: String
    var title: L10n
    var message: L10n
    var primary: L10n

    static func copy(for kind: WheelPermissionKind) -> WheelPermissionCopy {
        switch kind {
        case .explainBrowser(let b):
            return WheelPermissionCopy(symbol: "safari",
                                       title: L10n("Read the page address from \(b.displayName)?", "Читать адрес страницы из \(b.displayName)?"),
                                       message: BrowserLinkProblem.needsAutomationExplanation(b).message,
                                       primary: L10n("Continue", "Продолжить"))
        case .explainFinder:
            return WheelPermissionCopy(symbol: "folder", title: L10n("Read your Finder selection?", "Читать выбор в Finder?"),
                                       message: FinderSelectionReader.explanation, primary: L10n("Continue", "Продолжить"))
        case .explainAccessibility:
            return WheelPermissionCopy(symbol: "text.cursor",
                                       title: L10n("Read a link you have selected?", "Читать ссылку, которую вы выделили?"),
                                       message: L10n("Select a link anywhere, press the shortcut, and Swamp Converter picks it up. This is the most reliable way to get an address from browsers that do not share their open tab, such as Dia and Firefox. macOS will ask you to switch this on in System Settings > Privacy & Security > Accessibility. It may ask again after an update, because this build is not signed with a paid Developer ID.",
                                                     "Выделите ссылку где угодно, нажмите сочетание, и Swamp Converter её подхватит. Это самый надёжный способ получить адрес из браузеров, которые не сообщают открытую вкладку, например Dia и Firefox. macOS попросит включить это в Системных настройках > Конфиденциальность и безопасность > Универсальный доступ. После обновления он может спросить снова, потому что эта сборка не подписана платным Developer ID."),
                                       primary: L10n("Continue", "Продолжить"))
        case .deniedBrowser(let b):
            return WheelPermissionCopy(symbol: "hand.raised", title: L10n("Access to \(b.displayName) is off", "Доступ к \(b.displayName) выключен"),
                                       message: BrowserLinkProblem.automationDenied(b).message,
                                       primary: L10n("Open Automation Settings", "Открыть настройки автоматизации"))
        case .deniedFinder:
            return WheelPermissionCopy(symbol: "hand.raised", title: L10n("Access to Finder is off", "Доступ к Finder выключен"),
                                       message: L10n("Swamp Converter cannot read your Finder selection. Allow it in System Settings > Privacy & Security > Automation.",
                                                     "Swamp Converter не может прочитать выбор в Finder. Разрешите это в Системных настройках > Конфиденциальность и безопасность > Автоматизация."),
                                       primary: L10n("Open Automation Settings", "Открыть настройки автоматизации"))
        }
    }
}

struct WheelPermissionSheet: View {
    var copy: WheelPermissionCopy
    var onChoice: (WheelPermissionChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                SymbolIcon(copy.symbol, size: 26)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(copy.title.text).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
                    Text(copy.message.text).font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.sm) {
                Spacer(minLength: 0)
                Button(L("Not Now", "Не сейчас")) { onChoice(.notNow) }
                    .secondaryButtonLook()
                    .keyboardShortcut(.cancelAction)
                Button(copy.primary.text) { onChoice(.primary) }
                    .buttonStyle(.brandProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 420)
        .glassSurface(cornerRadius: DS.Radius.sheet)
        .appRoot()
    }
}

/// Shows one sheet at a time in a small floating panel and waits for the answer. Closing the panel is "Not Now".
@MainActor
final class WheelPermissionPrompt: NSObject, NSWindowDelegate {
    static let shared = WheelPermissionPrompt()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<WheelPermissionChoice, Never>?
    /// Tests answer without a window.
    var stub: ((WheelPermissionKind) -> WheelPermissionChoice)?

    func ask(_ kind: WheelPermissionKind) async -> WheelPermissionChoice {
        if let stub { return stub(kind) }
        finish(.notNow)                                                 // a second sheet replaces the first
        let copy = WheelPermissionCopy.copy(for: kind)
        return await withCheckedContinuation { (cont: CheckedContinuation<WheelPermissionChoice, Never>) in
            continuation = cont
            let host = NSHostingView(rootView: WheelPermissionSheet(copy: copy) { [weak self] choice in self?.finish(choice) })
            let size = host.fittingSize
            let p = PermissionPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentView = host
            p.delegate = self
            let mouse = NSEvent.mouseLocation
            let visible = WheelController.screen(containing: mouse)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            p.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.12))
            panel = p
            p.orderFrontRegardless()
            p.makeKey()
        }
    }

    private func finish(_ choice: WheelPermissionChoice) {
        let cont = continuation
        continuation = nil
        let p = panel
        panel = nil
        p?.delegate = nil
        p?.orderOut(nil)
        cont?.resume(returning: choice)
    }

    func windowWillClose(_ notification: Notification) { finish(.notNow) }
}

/// A borderless panel does not become key by itself; the permission sheet needs Return and Esc.
private final class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
