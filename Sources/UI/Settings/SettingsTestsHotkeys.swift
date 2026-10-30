import Foundation
import AppKit

extension SettingsTests {
    static func registerHotkeyTests(_ t: SelfTestRegistry) {
        let ctrlOpt = HotkeyModifier.control | HotkeyModifier.option
        t.register("settings.hotkeys", "a key press becomes a chord, Escape / Delete / Tab do what the recorder promises, Shift alone is refused") {
            try expectEqual(KeyCaptureEvents.intent(keyCode: 53, flags: []), .cancel)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 51, flags: []), .clear)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 117, flags: []), .clear)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 48, flags: []), .tab)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 0, flags: []), .needsModifier)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 0, flags: [.shift]), .needsModifier)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 0, flags: [.shift, .function]), .needsModifier)
            try expectEqual(KeyCaptureEvents.intent(keyCode: 96, flags: []), .combo(HotkeyCombo(keyCode: 96, modifiers: 0)), "F5 needs no modifier")
            try expectEqual(KeyCaptureEvents.intent(keyCode: 2, flags: [.control, .option]), .combo(HotkeyCombo(keyCode: 2, modifiers: ctrlOpt)))
            try expectEqual(KeyCaptureEvents.intent(keyCode: 2, flags: [.command, .shift]), .combo(HotkeyCombo(keyCode: 2, modifiers: HotkeyModifier.command | HotkeyModifier.shift)))
            try expectEqual(KeyCaptureEvents.intent(keyCode: 49, flags: [.control, .option, .capsLock, .function]), .combo(HotkeyCombo(keyCode: 49, modifiers: ctrlOpt)),
                            "caps lock and fn are not part of a chord")
            try expectEqual(KeyCaptureEvents.intent(keyCode: 53, flags: [.command]), .combo(HotkeyCombo(keyCode: 53, modifiers: HotkeyModifier.command)), "Escape with a modifier is a chord")
        }
        t.register("settings.hotkeys", "the recorder refuses chords that can be typed by accident or belong to apps, and warns about macOS shortcuts") {
            func verdict(_ code: UInt32, _ mods: UInt32, other: HotkeySetting? = nil, system: Set<HotkeyCombo> = []) -> HotkeyRecorderLogic.Verdict {
                HotkeyRecorderLogic.evaluate(HotkeyCombo(keyCode: code, modifiers: mods), other: other, system: system)
            }
            func isRefused(_ v: HotkeyRecorderLogic.Verdict) -> Bool { if case .refused = v { return true } else { return false } }
            func isWarned(_ v: HotkeyRecorderLogic.Verdict) -> Bool { if case .warned = v { return true } else { return false } }
            try expect(isRefused(verdict(0, 0)), "a bare letter")
            try expect(isRefused(verdict(0, HotkeyModifier.shift)), "shift + letter")
            try expect(isRefused(verdict(0, HotkeyModifier.command)), "command + letter belongs to apps")
            try expect(isRefused(verdict(0, HotkeyModifier.command | HotkeyModifier.shift)), "command + shift + letter belongs to apps")
            try expectEqual(verdict(2, ctrlOpt), .ok)
            try expectEqual(verdict(0, HotkeyModifier.control), .ok)
            try expectEqual(verdict(96, HotkeyModifier.command), .ok, "command + F5 is fine")
            try expect(isRefused(verdict(2, ctrlOpt, other: HotkeySetting(enabled: true, keyCode: 2, modifiers: ctrlOpt))), "the other shortcut uses it")
            try expectEqual(verdict(2, ctrlOpt, other: HotkeySetting(enabled: false, keyCode: 2, modifiers: ctrlOpt)), .ok, "a disabled shortcut frees its chord")
            try expect(isWarned(verdict(HotkeyCombo.space, ctrlOpt, system: HotkeyPolicy.knownSystemCombos)), "Control-Option-Space is the macOS input-source switch")
            if case .warned(let why) = verdict(HotkeyCombo.space, ctrlOpt, system: HotkeyPolicy.knownSystemCombos) {
                try expect(why.en.contains("Control-Option-Space") && why.ru.contains("Пробел"), "the warning names the chord in both languages")
            }
            // The defaults and every ready-made alternative must themselves be acceptable.
            for c in [HotkeyPresets.wheelDefault, HotkeyCombo(keyCode: 2, modifiers: ctrlOpt)] + HotkeyPresets.wheelFallbacks + HotkeyPresets.downloadFallbacks {
                try expect(!isRefused(HotkeyRecorderLogic.evaluate(c, other: nil, system: [])), "\(c.displayString) is offered but refused")
            }
        }
        t.register("settings.hotkeys", "a display name falls back to the layout character for keys without a table name, and keycaps agree with it") {
            let combo = HotkeyCombo(keyCode: 13, modifiers: ctrlOpt)
            try expectEqual(KeyLayoutName.display(combo), combo.displayString)
            let odd = HotkeyCombo(keyCode: 10, modifiers: ctrlOpt)   // the key left of Z on ISO keyboards: no entry in the table
            let shown = KeyLayoutName.display(odd)
            try expect(shown.hasPrefix("\u{2303}\u{2325}") && shown.count >= 3, "got \(shown)")
        }
        t.register("settings.hotkeys", "each wheel keeps its own modifier key: choosing a taken key swaps, none may repeat") {
            typealias K = WheelKeyLogic.Keys
            let start = K(convert: .shift, tools: .control, actions: .option)
            var next = WheelKeyLogic.assign(.control, to: .convert, in: start)
            try expectEqual(next, K(convert: .control, tools: .shift, actions: .option))
            next = WheelKeyLogic.assign(.command, to: .actions, in: start)
            try expectEqual(next, K(convert: .shift, tools: .control, actions: .command))
            next = WheelKeyLogic.assign(.none, to: .tools, in: start)
            try expectEqual(next, K(convert: .shift, tools: .none, actions: .option))
            next = WheelKeyLogic.assign(.none, to: .actions, in: next)
            try expectEqual(next, K(convert: .shift, tools: .none, actions: .none), "none may be shared")
            try expectEqual(WheelKeyLogic.assign(.shift, to: .convert, in: start), start, "no change")
            try expectEqual(WheelKeyLogic.assign(.shift, to: .link, in: start), start, "the link wheel has no key")
        }
    }
}
