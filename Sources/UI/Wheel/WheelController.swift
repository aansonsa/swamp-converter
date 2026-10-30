import Foundation
import AppKit
import Combine

/// What opens the wheel and how it behaves.
enum WheelPresentation: Equatable, Sendable {
    /// Files are being dragged now: the wheel is a pure drop target (cursor starts in the hub = cancel zone).
    case drag
    /// Items are already known (hotkey, menu bar, Dock, Services, clipboard): hover / arrows / Enter / digits, closes on deactivate.
    case click
}

/// Everything that belongs to ONE wheel on screen (reset by `close()`).
struct WheelSession {
    var mode: WheelPresentation = .click
    /// Files and / or links the wheel acts on. Drag mode holds placeholders until the drop materialises the real items.
    var input = IncomingInput()
    var wheel: WheelKind = .convert
    var isLink = false
    var isRepeat = false
    /// A screenshot saved from the clipboard for this wheel; deleted again when the wheel closes without a choice.
    var clipboardItem: FileItem?
    var consumed = false
}

/// The wheel: owner of the drag watcher, the hotkeys, the one reusable panel and the lifecycle of a presentation.
/// Lifecycle: `start()` arms two mouse-down monitors and the hotkeys (zero cost while idle) -> a drag gesture or a hotkey builds a `WheelSession` -> `open` places the lazily
/// created panel under the cursor -> a drop, a click, a key or Esc ends it with `close()` (idempotent; removes every monitor, hides the panel, discards an unused clipboard image).
/// Split over `WheelController+*.swift`: Panel (window, monitors), Present (content), Input (pointer, keys, drop), Run (what a choice starts), Hotkey (the two global shortcuts).
@MainActor
final class WheelController: ObservableObject {
    static let shared = WheelController()

    /// True while a wheel is on screen.
    @Published private(set) var isVisible = false
    /// "Pause gestures": disables only the drag gesture; hotkey, Services, Dock / menu-bar drop and watched folders keep working (spec/wheel.md 20.1).
    @Published private(set) var isPaused = false

    // MARK: State (internal so the extensions in the other files can use it; nothing outside the wheel module touches it)

    var panel: WheelPanel?
    var dropView: WheelDropView?
    var model: WheelModel?
    var session = WheelSession()
    var isStarted = false
    var settingsToken: AnyCancellable?
    var monitors: [Any] = []
    var graceWork: DispatchWorkItem?
    var dwellWork: DispatchWorkItem?
    var jobWatchers: [UUID: AnyCancellable] = [:]
    var hotkeyBusy = false
    /// Tests and the benchmark: the panel goes far off every display, takes no focus, plays no haptic.
    var offscreenForTesting = false
    /// Injection points for the tests: where the ring's content comes from and which pasteboard holds the drag.
    var contentBuilder: () -> WheelContentBuilder = { WheelContentBuilder() }
    var dragPasteboard: () -> NSPasteboard = { NSPasteboard(name: .drag) }
    var hotkeyResolver = WheelHotkeyResolver()
    var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var linkReader: BrowserLinkReader = .shared
    var startDownload: (LinkItem) async -> DownloadService.StartOutcome = { await DownloadService.shared.start(link: $0, mode: nil, origin: .hotkey) }
    /// The download-ui module confirms a started download itself when its hook is installed; without it (CLI, tests) the wheel says so.
    var confirmsDownloadItself: () -> Bool = { DownloadService.shared.hooks.started == nil }
    /// A drop inside this window after opening is ignored (a wheel that pops up under a still-held button must not fire at once).
    static let openGuard: TimeInterval = 0.15
    /// How long a finished drag keeps the wheel before it closes by itself (the mouse-up can arrive before the drop does).
    static let dragEndGrace: TimeInterval = 0.5

    // MARK: Lifecycle

    /// Installs the drag watcher and the hotkeys. Cheap at idle (event monitors only; no timers). Called by the app once launch finished.
    func start() {
        guard !isStarted else { applySettings(); return }
        isStarted = true
        applySettings()
        DragWatcher.shared.start { [weak self] event in self?.handleDragEvent(event) }
        // One subscription, no polling: settings publish a revision when ANYTHING changes; the work done per change is a few comparisons.
        settingsToken = AppSettings.shared.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        settingsToken = nil
        DragWatcher.shared.stop()
        HotkeyManager.shared.unregisterAll()
        close()
    }

    /// Pause / resume the drag gesture (the menu-bar item and Settings call this). Persisted in the settings; the hotkey keeps working.
    func setPaused(_ paused: Bool) {
        AppSettings.shared.update { $0.gesturesPaused = paused }
        applySettings()
    }

    /// Reads the settings once and (re)arms what depends on them: gesture configuration, pause, the two global shortcuts.
    func applySettings() {
        let s = AppSettings.shared.data
        if isPaused != s.gesturesPaused { isPaused = s.gesturesPaused }
        DragWatcher.shared.apply(settings: s)
        DragWatcher.shared.setSuspended(s.gesturesPaused)
        if s.gesturesPaused && isVisible && session.mode == .drag { close() }
        HotkeyManager.shared.apply(settings: s,
                                   onWheel: { [weak self] in Task { await self?.presentForHotkey() } },
                                   onDownload: { [weak self] in Task { await self?.downloadCurrentPageNow() } })
    }

    // MARK: Drag gesture

    func handleDragEvent(_ event: DragWatcher.Event) {
        switch event {
        case .dragBegan:
            // The wheel appears only after a tap or a shake, so build the (hidden) window now: the first SwiftUI pass would otherwise eat the 80 ms budget.
            _ = ensurePanel()
        case .modifierTap(let wheel):
            if isVisible, session.mode == .drag {
                if wheel == session.wheel && !session.isLink { toggleRepeat() } else { switchWheel(to: wheel) }
            } else {
                presentDrag(wheel: wheel)
            }
        case .shake:
            if !isVisible { presentDrag(wheel: .convert) }
        case .escape:
            if isVisible, session.mode == .drag { close() }
        case .dragEnded:
            if isVisible, session.mode == .drag { scheduleGraceClose() }
        }
    }

    // MARK: Closing

    func scheduleGraceClose() {
        graceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        graceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragEndGrace, execute: work)
    }

    /// Hides the wheel. Idempotent; safe to call from any callback of the wheel itself.
    func close() {
        graceWork?.cancel(); graceWork = nil
        dwellWork?.cancel(); dwellWork = nil
        removeMonitors()
        if let item = session.clipboardItem, !session.consumed { ClipboardSource.discard(item) }
        session = WheelSession()
        model?.setDropActive(false)
        model = nil
        dropView?.model = nil
        dropView?.setRoot(nil)
        panel?.allowsKey = false
        panel?.orderOut(nil)
        setVisible(false)
    }

    func setVisible(_ visible: Bool) { if isVisible != visible { isVisible = visible } }

    // MARK: Messages

    func toast(_ text: L10n, severity: UserMessage.Severity = .info, symbol: String? = nil) {
        MessageCenter.shared.post(text.text, severity: severity, symbol: symbol)
    }

    static let nothingToConvert = L10n(
        "Nothing to convert here. Select files in Finder or copy a picture or a link, then press the shortcut again.",
        "Здесь нечего преобразовывать. Выберите файлы в Finder или скопируйте изображение или ссылку и нажмите сочетание ещё раз.")
}
