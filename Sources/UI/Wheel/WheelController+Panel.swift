import Foundation
import AppKit
import SwiftUI

// The window side of a presentation: the lazily created panel, placement under the cursor, and the event monitors that exist ONLY while a wheel is on screen.

extension WheelController {
    /// The panel and its drop view are created on first use (a drag beginning, or the first presentation) and reused for every later wheel: the idle app holds neither.
    @discardableResult
    func ensurePanel() -> (panel: WheelPanel, view: WheelDropView) {
        if let p = panel, let v = dropView { return (p, v) }
        let p = WheelPanel()
        let v = WheelDropView()
        v.controller = self
        p.contentView = v
        p.onResignKey = { [weak self] in MainActor.assumeIsolated { self?.panelResignedKey() } }
        panel = p
        dropView = v
        return (p, v)
    }

    /// Click mode closes when the panel is no longer the key window (the person clicked elsewhere or switched apps).
    func panelResignedKey() {
        guard isVisible, session.mode == .click, !offscreenForTesting else { return }
        close()
    }

    // MARK: Placement

    /// The screen that holds `point` (the one the cursor is on), else the main screen.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Where the panel goes for a wheel anchored at `anchor` (screen coordinates): the disc is centred under the cursor and kept 16 pt inside the visible frame of its screen.
    static func panelFrame(anchor: NSPoint, geometry: WheelGeometry, visibleFrame: CGRect?) -> NSRect {
        let visible = visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return WheelGeometry.placement(anchor: anchor, panelSize: geometry.panelSide, visibleFrame: visible, margin: 16, discInset: WheelGeometry.pad)
    }

    // MARK: Showing

    /// Puts `model` on screen. The previous wheel (if any) must already be closed.
    func show(_ m: WheelModel, session newSession: WheelSession, anchor: NSPoint) {
        let (p, v) = ensurePanel()
        session = newSession
        model = m
        var frame = Self.panelFrame(anchor: anchor, geometry: m.geometry, visibleFrame: Self.screen(containing: anchor)?.visibleFrame)
        if offscreenForTesting { frame.origin = NSPoint(x: -6000, y: -6000) }
        p.setFrame(frame, display: false)
        v.model = m
        v.setRoot(AnyView(WheelRingView(model: m, onActivate: { [weak self] i in self?.activate(index: i) }).appRoot()))
        p.allowsKey = newSession.mode == .click && !offscreenForTesting
        m.openedAt = ProcessInfo.processInfo.systemUptime
        p.orderFrontRegardless()
        if p.allowsKey { p.makeKey() }
        setVisible(true)
        installMonitors(mode: newSession.mode)
    }

    /// VoiceOver pressed a sector.
    func activate(index: Int) {
        guard let model, let s = model.sectors[safe: index] else { return }
        perform(model.decide(sector: s, customise: false))
    }

    // MARK: Monitors

    /// Event monitors for the open wheel. Drag mode: a global + local mouse-up (the drag session swallows the one that matters, so this is a second chance) closes after the
    /// grace period. Click mode: any mouse-down outside the panel closes; Esc closes even when another app is key (the global key monitor delivers only where the person
    /// allowed it, the local one always); the local monitor also runs the keyboard model and tracks Option / Command for "Customise...".
    func installMonitors(mode: WheelPresentation) {
        removeMonitors()
        switch mode {
        case .drag:
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleGraceClose() }
            }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
                MainActor.assumeIsolated { self?.scheduleGraceClose() }
                return event
            }) { monitors.append(l) }
        case .click:
            let down: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: down, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }) { monitors.append(g) }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
                let isEscape = event.keyCode == 53
                MainActor.assumeIsolated { if isEscape { self?.close() } }
            }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: down, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window !== self.panel { self.close() }
                }
                return event
            }) { monitors.append(l) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
                guard let self else { return event }
                nonisolated(unsafe) let e = event
                let consumed = MainActor.assumeIsolated { self.handleLocal(e) }
                return consumed ? nil : event
            }) { monitors.append(l) }
        }
    }

    func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    /// Number of event monitors alive (the self-test asserts it is 0 after `close()`).
    var activeMonitorCount: Int { monitors.count }
}
