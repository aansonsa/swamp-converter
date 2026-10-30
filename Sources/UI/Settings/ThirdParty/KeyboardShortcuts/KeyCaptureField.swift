// Adapted from KeyboardShortcuts 3.1.0 (https://github.com/sindresorhus/KeyboardShortcuts), files RecorderCocoa.swift and Shortcut.swift.
// Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com). MIT License: see LICENSE in this folder.
//
// What was kept: the recorder as a native search field (rounded field with a clear button), recording that starts when the field becomes the first responder and ends when it
// resigns, a local key-down monitor that swallows the keys while recording, the rules for Escape / Tab / Delete without modifiers, the "Shift alone is not a shortcut" rule,
// the field that does not grab the focus when its window opens, and the lookup of a key's character in the current ASCII-capable keyboard layout (UCKeyTranslate).
// What was changed: no `Name` / `UserDefaults` storage, no global registration (our `HotkeyManager` registers), no menu or system-shortcut alerts (the caller validates and
// shows its own calm message), the model is our `HotkeyCombo` (Carbon key code + Carbon modifier mask), strings go through `L()`, no `Bundle.module`, no notifications.

import AppKit
import Carbon.HIToolbox

/// The key name used in the field and in the keycaps when the table of `HotkeyCombo.keyName` has none: the character the key types in the current layout.
enum KeyLayoutName {
    /// "Ё"-like characters are returned in upper case; nil when the layout has no printable character for the key.
    @MainActor
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<CoreServices.UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        let maxLength = 4
        var length = 0
        var characters = [UniChar](repeating: 0, count: maxLength)
        let error = CoreServices.UCKeyTranslate(keyLayout, UInt16(keyCode), UInt16(CoreServices.kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                                OptionBits(CoreServices.kUCKeyTranslateNoDeadKeysBit), &deadKeyState, maxLength, &length, &characters)
        guard error == noErr else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.count == 1 ? string.uppercased() : nil
    }

    /// "⌃⌥Space", "⌃⌥⌘W"; a key without a table name falls back to its layout character, then to "Key N".
    @MainActor
    static func display(_ combo: HotkeyCombo) -> String {
        let base = combo.displayString
        let name = HotkeyCombo.keyName(combo.keyCode)
        guard name.hasPrefix("Key "), let ch = character(for: combo.keyCode) else { return base }
        return String(base.dropLast(name.count)) + ch
    }
}

enum KeyCaptureEvents {
    /// Carbon modifier mask of an event (command, shift, option, control only; fn and caps lock are dropped).
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= HotkeyModifier.command }
        if flags.contains(.shift) { m |= HotkeyModifier.shift }
        if flags.contains(.option) { m |= HotkeyModifier.option }
        if flags.contains(.control) { m |= HotkeyModifier.control }
        return m
    }

    /// F1 ... F20 and the other function-row keys: usable without a modifier.
    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].contains(keyCode)
    }

    enum Intent: Equatable {
        /// A key pressed with no modifier: Escape ends recording, Delete clears, Tab moves on (the event is passed on).
        case cancel, clear, tab
        /// Shift (and fn) alone cannot be a shortcut.
        case needsModifier
        case combo(HotkeyCombo)
    }

    /// Pure decision for one key press (unit-tested).
    static func intent(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Intent {
        let relevant = flags.intersection([.command, .shift, .option, .control])
        if relevant.isEmpty {
            switch Int(keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            case kVK_Tab: return .tab
            default: break
            }
        }
        // The shift key is not allowed without other modifiers or a function key, since it doesn't actually work as a global shortcut.
        if relevant.subtracting(.shift).isEmpty && !isFunctionKey(keyCode) { return .needsModifier }
        return .combo(HotkeyCombo(keyCode: keyCode, modifiers: carbonModifiers(flags)))
    }
}

/// Carries an `NSEvent` through the main-actor hop of the local monitor (AppKit calls the monitor on the main thread; `NSEvent` is simply not marked Sendable).
private struct EventBox: @unchecked Sendable { var event: NSEvent? }

/// A native search field that records one keyboard shortcut. Click it, press the chord. Escape cancels, Delete or the clear button empties it, Tab moves on.
@MainActor
final class KeyCaptureField: NSSearchField, NSSearchFieldDelegate {
    /// The shortcut shown (nil = none).
    var combo: HotkeyCombo? { didSet { if combo != oldValue { updateStringValue() } } }
    /// Called with the new shortcut, or nil when it was cleared.
    var onCapture: ((HotkeyCombo?) -> Void)?
    /// Returns a message to refuse the chord (shown by the caller), nil to accept it.
    var validate: ((HotkeyCombo) -> String?)?
    var onRefuse: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var monitor: Any?
    private var canBecomeKey = false
    private var cancelButton: NSButtonCell?
    private var windowResignObserver: NSObjectProtocol?
    private var windowKeyObserver: NSObjectProtocol?

    override var canBecomeKeyView: Bool { canBecomeKey }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = 150
        return size
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        delegate = self
        placeholderString = idlePlaceholder
        alignment = .center
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        cancelButton = (cell as? NSSearchFieldCell)?.cancelButtonCell
        updateStringValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let o = windowResignObserver { NotificationCenter.default.removeObserver(o) }
        if let o = windowKeyObserver { NotificationCenter.default.removeObserver(o) }
    }

    private var idlePlaceholder: String { L("Click to record", "Нажмите, чтобы записать") }
    private var recordingPlaceholder: String { L("Press the shortcut", "Нажмите сочетание") }

    private var showsCancelButton: Bool {
        get { (cell as? NSSearchFieldCell)?.cancelButtonCell != nil }
        set { (cell as? NSSearchFieldCell)?.cancelButtonCell = newValue ? cancelButton : nil }
    }

    private func updateStringValue() {
        stringValue = combo.map { KeyLayoutName.display($0) } ?? ""
        showsCancelButton = !stringValue.isEmpty
    }

    // MARK: Focus

    override func viewDidMoveToWindow() {
        if let o = windowResignObserver { NotificationCenter.default.removeObserver(o); windowResignObserver = nil }
        if let o = windowKeyObserver { NotificationCenter.default.removeObserver(o); windowKeyObserver = nil }
        guard let window else { endRecording(); return }
        // Recording stops when the window loses the key status (the Settings window may only hide).
        windowResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.endRecording()
                window.makeFirstResponder(nil)
            }
        }
        // The field must not take the initial focus when the window opens.
        windowKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preventBecomingKey() }
        }
        preventBecomingKey()
    }

    private func preventBecomingKey() {
        canBecomeKey = false
        Task { @MainActor [weak self] in self?.canBecomeKey = true }
    }

    override func becomeFirstResponder() -> Bool {
        guard window != nil else { return false }
        let ok = super.becomeFirstResponder()
        guard ok else { return ok }
        placeholderString = recordingPlaceholder
        showsCancelButton = !stringValue.isEmpty
        hideCaret()
        onRecordingChanged?(true)
        startMonitor()
        return ok
    }

    func controlTextDidChange(_ obj: Notification) {
        if stringValue.isEmpty { combo = nil; onCapture?(nil) }
        showsCancelButton = !stringValue.isEmpty
        if stringValue.isEmpty { focus() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        restoreCaret()
        // AppKit ends and restarts editing internally; decide on the next turn whether it was a real end.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let editor = self.currentEditor(), self.window?.firstResponder === editor { self.hideCaret(); return }
            self.endRecording()
        }
    }

    private func endRecording() {
        let was = monitor != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        placeholderString = idlePlaceholder
        showsCancelButton = !stringValue.isEmpty
        restoreCaret()
        if was { onRecordingChanged?(false) }
    }

    private func blur() { window?.makeFirstResponder(nil) }
    private func focus() { window?.makeFirstResponder(self) }
    private func hideCaret() { (currentEditor() as? NSTextView)?.insertionPointColor = .clear }
    private func restoreCaret() { (currentEditor() as? NSTextView)?.insertionPointColor = .controlTextColor }

    // MARK: Recording

    private func startMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            return MainActor.assumeIsolated { EventBox(event: self.handle(box.event!)) }.event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Mouse-up only ends recording when the click lands outside the field. It is never swallowed: the clear button fires on mouse-up.
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            let point = convert(event.locationInWindow, from: nil)
            if !bounds.insetBy(dx: -3, dy: -3).contains(point) { blur() }
            return event
        }
        switch KeyCaptureEvents.intent(keyCode: UInt32(event.keyCode), flags: event.modifierFlags) {
        case .cancel:
            blur(); return nil
        case .clear:
            stringValue = ""; combo = nil; showsCancelButton = false
            onCapture?(nil); blur(); return nil
        case .tab:
            blur(); return event   // bubbles up so the key view loop moves on
        case .needsModifier:
            NSSound.beep()
            onRefuse?(L("Hold Control, Option or Command together with the key.", "Удерживайте Control, Option или Command вместе с клавишей."))
            return nil
        case .combo(let c):
            if let problem = validate?(c) {
                NSSound.beep()
                onRefuse?(problem)
                return nil
            }
            combo = c
            onCapture?(c)
            blur()
            return nil
        }
    }
}
