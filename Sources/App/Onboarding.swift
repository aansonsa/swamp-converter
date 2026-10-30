import SwiftUI
import AppKit

/// First-run window: four short pages (how the wheel works, the hotkeys incl. the browser download flow, the few switches worth turning on, optional tools). Optional, never reshown
/// once it was closed or finished (`settings.onboardingDone`). Nothing is asked of the system until the person presses a button on the permissions page (or, later, at the first use that needs it).
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    static let presenceID = "onboarding"

    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings = .shared) { self.settings = settings; super.init() }

    /// Pure rule (tested): the window opens only on the very first run.
    nonisolated static func shouldShow(onboardingDone: Bool) -> Bool { !onboardingDone }

    var isVisible: Bool { window?.isVisible ?? false }

    func showIfNeeded() {
        guard Self.shouldShow(onboardingDone: settings.data.onboardingDone) else { return }
        show()
    }

    /// Opens the window (also reachable from About for people who want to see it again).
    func show() {
        if let w = window { WindowPresence.shared.present(w, id: Self.presenceID); return }
        let model = OnboardingModel()
        model.onFinish = { [weak self] in self?.window?.close() }
        model.openToolSettings = { AppCommands.showSettings(page: .tools) }
        let host = NSHostingController(rootView: OnboardingView(model: model, tools: { OnboardingToolRow.live() }).appRoot())
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(OnboardingView.size)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        WindowPresence.shared.present(w, id: Self.presenceID)
    }

    /// Closing in any way (Done, Skip, the close button, Esc) counts: the first-run window is never shown again by itself.
    func windowWillClose(_ notification: Notification) {
        settings.update { $0.onboardingDone = true; $0.firstRunDone = true }
        window?.contentViewController = nil
        window = nil
        WindowPresence.shared.closed(Self.presenceID)
    }
}

enum OnboardingPage: Int, CaseIterable {
    case wheel, hotkeys, permissions, tools
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage
    var onFinish: () -> Void = {}
    var openToolSettings: () -> Void = {}

    init(page: OnboardingPage = .wheel) { self.page = page }

    var isFirst: Bool { page == .wheel }
    var isLast: Bool { page == .tools }

    func next() {
        if let n = OnboardingPage(rawValue: page.rawValue + 1) { page = n } else { onFinish() }
    }

    func back() {
        if let p = OnboardingPage(rawValue: page.rawValue - 1) { page = p }
    }
}

/// One optional tool on the last page.
struct OnboardingToolRow: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var purpose: L10n
    var found: Bool
    var hint: L10n

    /// ffmpeg (video and audio), yt-dlp (downloads, installed only on request), LibreOffice (office documents). Looks tools up on the first call only, when the last page is shown.
    @MainActor
    static func live(_ locator: ToolLocator = .shared) -> [OnboardingToolRow] {
        [
            row(.ffmpeg, L10n("Video and audio", "Видео и аудио"), locator),
            row(.ytdlp, L10n("Downloads from links; installed only if you ask", "Скачивание по ссылкам; ставится только по вашему запросу"), locator),
            row(.soffice, L10n("Word, Excel and PowerPoint files", "Файлы Word, Excel и PowerPoint"), locator),
        ]
    }

    @MainActor
    private static func row(_ tool: Tool, _ purpose: L10n, _ locator: ToolLocator) -> OnboardingToolRow {
        OnboardingToolRow(name: tool.displayName, purpose: purpose, found: locator.has(tool), hint: tool.installHint)
    }
}
