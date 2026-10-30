import Foundation
import AppKit

/// The zero-permission gesture detector (spec/platform.md 6, spec/wheel.md 18.1a option A). A global MOUSE monitor (no permission) only arms a short poll while a button is down;
/// each tick samples `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags`, the drag pasteboard change count + types (file URLs / promises / image data) and Esc.
/// Triggers: shake the dragged files (sensitivity setting) or tap one of the wheel modifier keys (Shift = Convert, Control = Tools, Option = Actions, user-configurable) during a drag.
/// When the permission-free path cannot work the gesture is disabled with a one-line explanation in Settings (not a modal) and everything else keeps working.
///
/// COST AT IDLE: two mouse-DOWN monitors and nothing else. No timer exists until a button goes down; it dies when the button is released (or after 20 s without a drag
/// session). While only waiting to see whether a drag session begins it ticks at 20 Hz; during a real drag at 60 Hz.
///
/// UNVERIFIED LIVE (nobody may drive the desktop; owner checklist in WheelModule.swift): that `pressedMouseButtons`, `modifierFlags` and the drag pasteboard
/// keep updating for a background app while Finder / Safari / Mail own an AppKit drag session. The poll is the DEFAULT precisely because it needs no event delivery.
@MainActor
final class DragWatcher {
    static let shared = DragWatcher()

    enum Event: Equatable, Sendable {
        /// A file drag began (button down, moved > 8 pt, drag pasteboard holds files).
        case dragBegan
        /// A wheel key was TAPPED (pressed and released alone) during a drag.
        case modifierTap(WheelKind)
        /// The shake gesture fired.
        case shake
        case escape
        case dragEnded
    }

    // MARK: State

    private var handler: (@MainActor (Event) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval = 0
    private var session = DragSession()
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var changeCountAtDown = 0
    private var payloadVerdict: (changeCount: Int, has: Bool)?

    /// True between `start` and `stop` (monitors may still be removed by `suspend`).
    private(set) var isRunning = false
    /// "Pause gestures": the monitors are removed, nothing at all runs.
    private(set) var isSuspended = false
    /// The phase of the state machine (tests and the controller's prewarm decision read it).
    var phase: DragSession.Phase { session.phase }
    /// Number of samples taken since `start` (the idle test asserts it does not grow without a button).
    private(set) var sampleCount = 0

    // MARK: Lifecycle

    /// Installs the global mouse monitor (idempotent). Nothing runs until a button goes down. `handler` receives events on the main actor.
    func start(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
        isRunning = true
        if !isSuspended { installMonitors() }
    }

    func stop() {
        isRunning = false
        removeMonitors()
        stopTimer()
        session.cancel()
        handler = nil
    }

    /// Pause / resume the gesture only (hotkey, Services, Dock and menu-bar drops are not affected).
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { removeMonitors(); stopTimer(); session.cancel() } else if isRunning { installMonitors() }
    }

    /// Applies the gesture settings (modifier keys, shake, sensitivity). Safe to call at any time.
    func apply(settings: SettingsData) {
        session.configuration = Self.configuration(from: settings)
    }

    /// The pure mapping from settings (unit-tested): one wheel per modifier, the first wheel wins when two share a key, `none` maps to nothing.
    static func configuration(from s: SettingsData) -> DragSession.Configuration {
        var keys: [ModifierKey: WheelKind] = [:]
        for (key, wheel) in [(s.convertKey, WheelKind.convert), (s.toolsKey, .tools), (s.actionsKey, .actions)] where key != .none && keys[key] == nil {
            keys[key] = wheel
        }
        return DragSession.Configuration(modifierTap: s.gestures.modifierTap, shake: s.gestures.shake, shakeSensitivity: s.gestures.shakeSensitivity, wheelKeys: keys)
    }

    // MARK: Monitors

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.buttonWentDown() }
        }
        // A drag that starts inside this app (a result dragged out of the Jobs window) is not seen by the global monitor.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.buttonWentDown() }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil
    }

    // MARK: Polling

    private func buttonWentDown() {
        guard !isSuspended else { return }
        changeCountAtDown = dragPasteboard.changeCount
        payloadVerdict = nil
        session.mouseDown(at: NSEvent.mouseLocation, changeCount: changeCountAtDown, time: now())
        ensureTimer()
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func ensureTimer() {
        let interval = session.suggestedInterval
        guard interval > 0 else { stopTimer(); return }
        if timer != nil && abs(timerInterval - interval) < 0.0001 { return }
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(3))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
        timerInterval = interval
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerInterval = 0
    }

    private func tick() {
        let events = session.feed(takeSample())
        ensureTimer()                                        // the phase may have changed the cadence, or ended the session
        guard let handler else { return }
        for e in events { handler(e) }
    }

    private func takeSample() -> DragSample {
        sampleCount += 1
        let cc = dragPasteboard.changeCount
        var has = false
        if cc != changeCountAtDown {
            if let v = payloadVerdict, v.changeCount == cc { has = v.has } else {
                has = DragPasteboardReader.hasPayload(dragPasteboard)
                payloadVerdict = (cc, has)
            }
        }
        let dragging = session.phase == .dragging
        return DragSample(time: now(), leftDown: NSEvent.pressedMouseButtons & 1 != 0, location: NSEvent.mouseLocation,
                          pasteboardChangeCount: cc, hasPayload: has,
                          modifiers: dragging ? Self.currentModifiers() : [], escapeDown: dragging && Self.escapeIsDown())
    }

    /// The modifiers held right now, from two independent sources OR-ed together (either one alone would do; both guard against one going stale mid-drag).
    static func currentModifiers() -> [ModifierKey] {
        let f = NSEvent.modifierFlags
        let cg = CGEventSource.flagsState(.combinedSessionState)
        var keys: [ModifierKey] = []
        if f.contains(.shift) || cg.contains(.maskShift) { keys.append(.shift) }
        if f.contains(.control) || cg.contains(.maskControl) { keys.append(.control) }
        if f.contains(.option) || cg.contains(.maskAlternate) { keys.append(.option) }
        if f.contains(.command) || cg.contains(.maskCommand) { keys.append(.command) }
        return keys
    }

    /// Esc (virtual key 53) through the session key state: no Accessibility or Input Monitoring needed to read a key's state.
    static func escapeIsDown() -> Bool { CGEventSource.keyState(.combinedSessionState, key: 53) }

    /// Feed a sample straight into the state machine (tests drive the watcher without the system).
    func injectForTesting(_ sample: DragSample) -> [Event] {
        let events = session.feed(sample)
        return events
    }
}
