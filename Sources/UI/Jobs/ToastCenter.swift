import SwiftUI
import AppKit

/// Time as the toast center needs it: a monotonic clock and one-shot blocks. The real one wraps `DispatchQueue.main.asyncAfter`; tests inject a fake and move time by hand.
@MainActor
protocol ToastScheduler: AnyObject {
    var now: TimeInterval { get }
    /// Runs `block` once after `seconds`; the returned closure cancels it.
    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
final class DispatchToastScheduler: ToastScheduler {
    nonisolated init() {}

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> () -> Void {
        let work = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return { work.cancel() }
    }
}

/// The window side of the toasts. The real one is `ToastPanelSurface`; tests count the calls.
@MainActor
protocol ToastSurface: AnyObject {
    var onHover: ((Bool) -> Void)? { get set }
    func present(model: ToastModel)
    func refit()
    func dismiss()
    func announce(_ text: String)
}

/// Short-lived confirmations ("Path copied", "Downloading ...", errors that are not a job): a glass toast near the bottom of the screen with the pointer that never takes focus, three seconds, queued
/// one after another, paused while the pointer is over it, announced to VoiceOver; Reduce Motion = fade. The panel is created at the first toast, not before.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private enum Phase { case idle, showing, fading }

    private(set) var queue = ToastQueue()
    let model = ToastModel()
    private var phase = Phase.idle
    private var clock = ToastClock(duration: 0)
    private var cancelDismissal: (() -> Void)?
    private let scheduler: ToastScheduler
    private let makeSurface: @MainActor () -> ToastSurface
    private lazy var surface: ToastSurface = {
        let s = makeSurface()
        s.onHover = { [weak self] inside in self?.hover(inside) }
        return s
    }()
    /// Whether the system asks for less motion (tests override it).
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(scheduler: ToastScheduler = DispatchToastScheduler(), surface: @escaping @MainActor () -> ToastSurface = { ToastPanelSurface() }) {
        self.scheduler = scheduler
        self.makeSurface = surface
    }

    /// True while a toast is on screen or fading.
    var isShowing: Bool { phase != .idle }
    var currentText: String? { queue.current?.text }

    func show(_ message: UserMessage) { show(item: ToastItem(message)) }

    func show(_ text: String, symbol: String? = nil, severity: UserMessage.Severity = .info, action: (title: String, handler: @MainActor () -> Void)? = nil) {
        show(item: ToastItem(text: text, symbol: symbol, severity: severity, action: action))
    }

    func show(item: ToastItem) {
        switch queue.enqueue(item) {
        case .startNow: present()
        case .merged:
            // The same sentence again while it is up: it stays a little longer instead of stacking.
            if phase == .showing, queue.current?.text == item.text { rearmDismissal() }
        case .queued: break
        }
    }

    // MARK: Flow

    private func present() {
        guard let item = queue.current else { return }
        phase = .showing
        model.item = item
        model.shown = false
        model.onTap = { [weak self] in self?.dismissCurrent() }
        model.onAction = { [weak self] in
            guard let self, self.phase == .showing else { return }
            let handler = self.queue.current?.handler
            self.dismissCurrent()
            handler?()
        }
        surface.present(model: model)
        _ = scheduler.after(0.02) { [weak self] in
            guard let self, self.phase == .showing else { return }
            self.model.shown = true
            self.surface.refit()
        }
        surface.announce(item.spoken)
        clock = ToastClock(duration: ToastTiming.duration(item))
        armDismissal()
    }

    private func armDismissal() {
        cancelDismissal?()
        let wait = clock.start(now: scheduler.now)
        cancelDismissal = scheduler.after(wait) { [weak self] in self?.dismissCurrent() }
    }

    private func rearmDismissal() {
        guard let item = queue.current else { return }
        cancelDismissal?()
        clock.restart(duration: ToastTiming.duration(item))
        armDismissal()
    }

    /// The pointer entered or left the toast.
    func hover(_ inside: Bool) {
        guard phase == .showing else { return }
        if inside {
            clock.pause(now: scheduler.now)
            cancelDismissal?()
            cancelDismissal = nil
        } else if !clock.isRunning {
            armDismissal()
        }
    }

    /// Time is up, the toast was clicked, or its button was pressed.
    func dismissCurrent() {
        guard phase == .showing else { return }
        cancelDismissal?()
        cancelDismissal = nil
        phase = .fading
        model.shown = false
        let fade = reduceMotion() ? ToastTiming.fadeOutReduced : ToastTiming.fadeOut
        _ = scheduler.after(fade) { [weak self] in self?.finishCurrent() }
    }

    private func finishCurrent() {
        guard phase == .fading else { return }
        model.item = nil
        if queue.advance() != nil {
            present()
        } else {
            phase = .idle
            surface.dismiss()
        }
    }
}

// MARK: - The real window

@MainActor
final class ToastPanelSurface: ToastSurface {
    var onHover: ((Bool) -> Void)?
    private var panel: JobsFloatingPanel?
    private var host: HoverHostingView<AnyView>?

    func present(model: ToastModel) {
        if panel == nil {
            let view = HoverHostingView(rootView: AnyView(ToastHost(model: model).appRoot()))
            view.onHoverChange = { [weak self] inside in self?.onHover?(inside) }
            let p = JobsFloatingPanel(contentSize: NSSize(width: 200, height: 80))
            p.contentView = view
            panel = p
            host = view
        }
        refit()
        panel?.orderFrontRegardless()
    }

    func refit() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let screen = FloatingPlacement.screen(containing: NSEvent.mouseLocation)
        let origin = FloatingPlacement.bottomCenter(in: screen?.visibleFrame ?? NSRect(origin: .zero, size: size), size: size, inset: 48)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func dismiss() { panel?.orderOut(nil) }

    func announce(_ text: String) {
        guard let panel else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
