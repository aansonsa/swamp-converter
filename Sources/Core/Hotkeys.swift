import Foundation

// Global shortcuts as pure values: a key code + a Carbon modifier mask, display text, the preset list offered in Settings, and the
// conflict policy (the wheel module reads the enabled system shortcuts and passes them as `taken`; this file decides what to use).
//
// Why a policy: on the owner's Mac Control+Option+Space is the enabled system shortcut "Select next source in Input menu"
// (ABC + Russian + Latvian input sources), so a Carbon hotkey registered for it would never fire. The default therefore is
// Control+Option+Space as asked, and `HotkeyPolicy.resolve` falls back to the first free preset and tells the user which one it chose.

/// Carbon modifier masks (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
enum HotkeyModifier {
    static let command: UInt32 = 0x100
    static let shift: UInt32 = 0x200
    static let option: UInt32 = 0x800
    static let control: UInt32 = 0x1000
}

struct HotkeyCombo: Codable, Hashable, Sendable {
    /// Carbon virtual key code (kVK_*).
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    static let space: UInt32 = 49

    /// "⌃⌥Space", "⌃⌥⌘W" (modifier glyphs in the macOS order: control, option, shift, command).
    var displayString: String {
        var s = ""
        if modifiers & HotkeyModifier.control != 0 { s += "\u{2303}" }
        if modifiers & HotkeyModifier.option != 0 { s += "\u{2325}" }
        if modifiers & HotkeyModifier.shift != 0 { s += "\u{21E7}" }
        if modifiers & HotkeyModifier.command != 0 { s += "\u{2318}" }
        return s + Self.keyName(keyCode)
    }

    /// Names for the ANSI keys, space and a few specials (the recorder shows anything else as "Key N").
    static func keyName(_ code: UInt32) -> String {
        let table: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return table[code] ?? "Key \(code)"
    }

    /// A shortcut needs at least one of control / option / command, so it can never be typed by accident.
    var isUsable: Bool { modifiers & (HotkeyModifier.control | HotkeyModifier.option | HotkeyModifier.command) != 0 }
}

/// Global shortcut setting (a field of SettingsData).
struct HotkeySetting: Codable, Equatable, Sendable {
    var enabled = true
    var keyCode: UInt32 = HotkeyCombo.space
    var modifiers: UInt32 = HotkeyModifier.control | HotkeyModifier.option

    var combo: HotkeyCombo { HotkeyCombo(keyCode: keyCode, modifiers: modifiers) }

    init(enabled: Bool = true, keyCode: UInt32 = HotkeyCombo.space, modifiers: UInt32 = HotkeyModifier.control | HotkeyModifier.option) {
        self.enabled = enabled; self.keyCode = keyCode; self.modifiers = modifiers
    }
    init(enabled: Bool = true, combo: HotkeyCombo) { self.init(enabled: enabled, keyCode: combo.keyCode, modifiers: combo.modifiers) }

    /// The default of the "download the current page now" shortcut: Control+Option+D.
    static let downloadDefault = HotkeySetting(enabled: true, keyCode: 2, modifiers: HotkeyModifier.control | HotkeyModifier.option)
}

enum HotkeyPresets {
    static let wheelDefault = HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control | HotkeyModifier.option)

    /// Offered in Settings and tried in this order when the preferred shortcut is taken.
    static let wheelFallbacks: [HotkeyCombo] = [
        HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control | HotkeyModifier.option | HotkeyModifier.command),
        HotkeyCombo(keyCode: 13, modifiers: HotkeyModifier.control | HotkeyModifier.option | HotkeyModifier.command),
        HotkeyCombo(keyCode: 3, modifiers: HotkeyModifier.control | HotkeyModifier.option | HotkeyModifier.command),
        HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control | HotkeyModifier.shift | HotkeyModifier.option)
    ]
    static let downloadFallbacks: [HotkeyCombo] = [
        HotkeyCombo(keyCode: 2, modifiers: HotkeyModifier.control | HotkeyModifier.option | HotkeyModifier.command),
        HotkeyCombo(keyCode: 2, modifiers: HotkeyModifier.control | HotkeyModifier.shift | HotkeyModifier.option)
    ]
}

enum HotkeyPolicy {
    struct Resolution: Equatable, Sendable {
        var combo: HotkeyCombo
        /// True when `combo` differs from what the user asked for (Settings shows "Control-Option-Space is taken by macOS; using ...").
        var fellBack: Bool
    }

    /// The combo to register: `preferred` unless it is in `taken` (enabled system shortcuts + our own other hotkey), then the first
    /// free candidate. nil when everything is taken. Candidates equal to `preferred` or in `taken` are skipped.
    static func resolve(preferred: HotkeyCombo, taken: Set<HotkeyCombo>, candidates: [HotkeyCombo]) -> Resolution? {
        if !taken.contains(preferred) { return Resolution(combo: preferred, fellBack: false) }
        for c in candidates where c != preferred && !taken.contains(c) { return Resolution(combo: c, fellBack: true) }
        return nil
    }

    /// The system shortcuts that collide with our defaults on a typical RU/EN/LV Mac. The wheel module replaces this with the
    /// live `CopySymbolicHotKeys()` result; the list is also the fallback when that call is unavailable.
    static let knownSystemCombos: Set<HotkeyCombo> = [
        HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control),                                         // previous input source
        HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control | HotkeyModifier.option),                // next input source
        HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.command),                                        // Spotlight
        HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.command | HotkeyModifier.option)                 // Finder search
    ]
}
