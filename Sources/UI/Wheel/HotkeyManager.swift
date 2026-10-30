import Foundation
import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` for the two global shortcuts (no permission needed): the wheel (default Control-Option-Space) and "download the current page" (Control-Option-D).
/// Conflicts: the enabled SYSTEM shortcuts are read with `CopySymbolicHotKeys()`; `HotkeyPolicy.resolve` (Core) picks the first free preset when the chosen chord is taken,
/// and `registrationNotes` tells Settings what happened ("Control-Option-Space is used by macOS (Input Sources); using Control-Option-Command-Space").
/// Registering twice in one process returns -9878 (eventHotKeyExistsErr), also when another app owns the chord.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    struct Registration: Equatable, Sendable {
        var requested: HotkeyCombo
        var effective: HotkeyCombo?
        var fellBack: Bool
        /// Carbon status: noErr = registered.
        var status: Int32
    }

    @Published private(set) var wheel: Registration?
    @Published private(set) var download: Registration?
    /// Human-readable lines for Settings > Shortcuts.
    @Published private(set) var registrationNotes: [L10n] = []

    private enum Slot: UInt32 { case wheel = 1, download = 2 }
    private static let signature: OSType = 0x53574D50          // 'SWMP'

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var onWheel: (@MainActor () -> Void)?
    private var onDownload: (@MainActor () -> Void)?
    private var lastApplied: (wheel: HotkeySetting, download: HotkeySetting)?
    /// Registered through Carbon in this process (tests can replace the Carbon calls).
    var registerOverride: ((HotkeyCombo) -> Int32)?

    // MARK: Public API

    /// (Re)registers from settings. `onWheel` / `onDownload` run on the main actor. Unregisters what is disabled. Idempotent; observes nothing itself (the wheel controller calls it
    /// when `AppSettings` changes).
    func apply(settings: SettingsData, onWheel: @escaping @MainActor () -> Void, onDownload: @escaping @MainActor () -> Void) {
        self.onWheel = onWheel
        self.onDownload = onDownload
        let want = (wheel: settings.hotkey, download: settings.downloadHotkey)
        if let last = lastApplied, last.wheel == want.wheel, last.download == want.download, handlerRef != nil || registerOverride != nil { return }
        lastApplied = want
        installHandlerIfNeeded()
        unregisterKeys()
        var notes: [L10n] = []
        let system = Self.systemCombos()

        wheel = nil; download = nil
        var taken = system
        if want.wheel.enabled {
            let r = register(slot: .wheel, setting: want.wheel, taken: taken, candidates: HotkeyPresets.wheelFallbacks, notes: &notes)
            wheel = r
            if let e = r.effective { taken.insert(e) }
        }
        if want.download.enabled {
            // The download shortcut must not collide with the wheel's effective chord either.
            if let e = wheel?.effective { taken.insert(e) }
            download = register(slot: .download, setting: want.download, taken: taken, candidates: HotkeyPresets.downloadFallbacks, notes: &notes)
        }
        registrationNotes = notes
    }

    func unregisterAll() {
        unregisterKeys()
        wheel = nil; download = nil
        registrationNotes = []
        lastApplied = nil
    }

    /// Enabled system shortcuts as combos (`CopySymbolicHotKeys`); falls back to `HotkeyPolicy.knownSystemCombos`.
    nonisolated static func systemCombos() -> Set<HotkeyCombo> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return HotkeyPolicy.knownSystemCombos }
        let parsed = parseSymbolicHotKeys(array)
        // An empty answer means the call did not work as documented on this system: stay on the safe side. Otherwise the live list is the truth: adding the
        // built-in list too made Control-Option-Space count as taken on every Mac, even where the person had turned "Select next input source" off.
        return parsed.isEmpty ? HotkeyPolicy.knownSystemCombos : parsed
    }

    /// Pure: turns the dictionaries `CopySymbolicHotKeys` returns into combos. Only ENABLED entries with a real key code count; the modifier mask keeps
    /// the four Carbon modifiers (command, shift, option, control) and drops the other bits system entries carry (fn, caps lock).
    nonisolated static func parseSymbolicHotKeys(_ entries: [[String: Any]]) -> Set<HotkeyCombo> {
        let mask = HotkeyModifier.command | HotkeyModifier.shift | HotkeyModifier.option | HotkeyModifier.control
        var out = Set<HotkeyCombo>()
        for e in entries {
            let enabled = (e["kHISymbolicHotKeyEnabled"] as? Bool) ?? ((e["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue ?? false)
            guard enabled, let code = (e["kHISymbolicHotKeyCode"] as? NSNumber)?.int64Value, code >= 0, code < 0xFFFF,
                  let mods = (e["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { continue }
            let m = mods & mask
            guard m != 0 else { continue }                           // a bare key (F-keys, Mission Control) can never collide with a chord
            out.insert(HotkeyCombo(keyCode: UInt32(code), modifiers: m))
        }
        return out
    }

    /// "Control-Option-Space" for the notes (words, not glyphs: the glyphs are small and unreadable in a sentence).
    nonisolated static func spokenName(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers & HotkeyModifier.control != 0 { parts.append("Control") }
        if combo.modifiers & HotkeyModifier.option != 0 { parts.append("Option") }
        if combo.modifiers & HotkeyModifier.shift != 0 { parts.append("Shift") }
        if combo.modifiers & HotkeyModifier.command != 0 { parts.append("Command") }
        parts.append(HotkeyCombo.keyName(combo.keyCode))
        return parts.joined(separator: "-")
    }

    nonisolated static func spokenNameRU(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers & HotkeyModifier.control != 0 { parts.append("Control") }
        if combo.modifiers & HotkeyModifier.option != 0 { parts.append("Option") }
        if combo.modifiers & HotkeyModifier.shift != 0 { parts.append("Shift") }
        if combo.modifiers & HotkeyModifier.command != 0 { parts.append("Command") }
        let key = HotkeyCombo.keyName(combo.keyCode)
        parts.append(key == "Space" ? "Пробел" : key)
        return parts.joined(separator: "-")
    }

    // MARK: Registration

    private func register(slot: Slot, setting: HotkeySetting, taken: Set<HotkeyCombo>, candidates: [HotkeyCombo], notes: inout [L10n]) -> Registration {
        let preferred = setting.combo
        let what = slot == .wheel ? L10n("the wheel", "колеса") : L10n("downloading the current page", "скачивания текущей страницы")
        var blocked = taken
        var firstReason: L10n?
        var attempts = 0
        while attempts < candidates.count + 1 {
            attempts += 1
            guard let pick = HotkeyPolicy.resolve(preferred: preferred, taken: blocked, candidates: candidates) else { break }
            let status = tryRegister(pick.combo, slot: slot)
            if status == noErr {
                if pick.fellBack {
                    let why = firstReason ?? L10n("\(Self.spokenName(preferred)) is used by macOS", "\(Self.spokenNameRU(preferred)) уже занято в macOS")
                    notes.append(L10n("\(why.en); using \(Self.spokenName(pick.combo)) for \(what.en).",
                                      "\(why.ru); для \(what.ru) используется \(Self.spokenNameRU(pick.combo))."))
                }
                return Registration(requested: preferred, effective: pick.combo, fellBack: pick.fellBack, status: status)
            }
            // Another app owns it (-9878) or Carbon refused: remember and try the next free candidate.
            if firstReason == nil, pick.combo == preferred {
                firstReason = L10n("\(Self.spokenName(preferred)) is used by another app", "\(Self.spokenNameRU(preferred)) уже занято другим приложением")
            }
            blocked.insert(pick.combo)
        }
        notes.append(L10n("No free shortcut was found for \(what.en). Choose another one in Settings > Shortcuts.",
                          "Для \(what.ru) не нашлось свободного сочетания. Выберите другое в Настройках > Сочетания клавиш."))
        return Registration(requested: preferred, effective: nil, fellBack: false, status: Int32(eventHotKeyExistsErr))
    }

    private func tryRegister(_ combo: HotkeyCombo, slot: Slot) -> Int32 {
        if let override = registerOverride { return override(combo) }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[slot.rawValue] = ref }
        return status
    }

    private func unregisterKeys() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    // MARK: Carbon event handler

    private func installHandlerIfNeeded() {
        guard handlerRef == nil, registerOverride == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let r = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard r == noErr, hotKeyID.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // Carbon delivers on the main thread; hop explicitly to be safe about actor isolation.
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyManager.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { handlerRef = nil }
    }

    fileprivate func fire(_ id: UInt32) {
        switch Slot(rawValue: id) {
        case .wheel?: onWheel?()
        case .download?: onDownload?()
        case nil: break
        }
    }

    /// Tests: pretend the shortcut was pressed.
    func simulatePress(wheel isWheel: Bool) { fire(isWheel ? Slot.wheel.rawValue : Slot.download.rawValue) }
}
