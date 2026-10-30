import SwiftUI
import AppKit

/// What may be recorded as a global shortcut. Pure and unit-tested; the recorder asks it for every chord.
enum HotkeyRecorderLogic {
    enum Verdict: Equatable {
        case ok
        /// Refused: the message says why and what to do.
        case refused(L10n)
        /// Accepted, but the person should know: macOS owns this chord, so `HotkeyManager` will register a free one instead.
        case warned(L10n)
    }

    /// `other` = the second global shortcut (a chord may not be used twice); `system` = the enabled macOS shortcuts (`HotkeyManager.systemCombos()`).
    static func evaluate(_ combo: HotkeyCombo, other: HotkeySetting?, system: Set<HotkeyCombo>) -> Verdict {
        guard combo.isUsable else {
            return .refused(L10n("Use Control, Option or Command together with the key, so the shortcut can’t be typed by accident.",
                                 "Используйте Control, Option или Command вместе с клавишей, чтобы сочетание не нажималось случайно."))
        }
        let hasLetterModifier = combo.modifiers & (HotkeyModifier.control | HotkeyModifier.option) != 0
        if !hasLetterModifier && !KeyCaptureEvents.isFunctionKey(combo.keyCode) {
            return .refused(L10n("Command alone is used by the shortcuts of every app. Add Control or Option.",
                                 "Один Command занят сочетаниями всех приложений. Добавьте Control или Option."))
        }
        if let other, other.enabled, other.combo == combo {
            return .refused(L10n("The other shortcut already uses this combination.", "Это сочетание уже используется другим сочетанием приложения."))
        }
        if system.contains(combo) {
            let en = HotkeyManager.spokenName(combo), ru = HotkeyManager.spokenNameRU(combo)
            return .warned(L10n("macOS already uses \(en). The app will register a free shortcut instead and tell you which one.",
                                "macOS уже использует \(ru). Приложение зарегистрирует свободное сочетание и сообщит, какое именно."))
        }
        return .ok
    }
}

/// The recorder control for a global shortcut: click, press the chord. It validates with `HotkeyRecorderLogic`, shows what `HotkeyManager` did with the chord
/// (a fallback because macOS owns it, or no free shortcut at all), and offers reset to the default and a few ready-made alternatives. Clearing the field switches the
/// shortcut off. Writes only the `HotkeySetting` it is bound to.
struct HotkeyRecorder: View {
    @Binding var setting: HotkeySetting
    /// The other global shortcut (for the duplicate check); nil when there is none.
    var other: HotkeySetting? = nil
    var defaultSetting = HotkeySetting()
    var presets: [HotkeyCombo] = []
    /// What `HotkeyManager` did with this chord (nil = nothing to report).
    var registration: HotkeyManager.Registration? = nil
    var title = L("Shortcut", "Сочетание")
    var system: () -> Set<HotkeyCombo> = { HotkeyManager.systemCombos() }

    @State private var message: (text: String, tone: StatusTone)?

    var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                KeyCaptureRepresentable(combo: setting.enabled ? setting.combo : nil, isEnabled: true, label: title,
                                        validate: { validate($0) },
                                        onCapture: { captured($0) },
                                        onRefuse: { message = ($0, .warning) })
                    .frame(width: 160, height: 24)
                if !presets.isEmpty {
                    Menu {
                        ForEach(presets, id: \.self) { c in
                            Button(KeyLayoutName.display(c)) { apply(c) }
                        }
                    } label: { Text(L("Alternatives", "Варианты")) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                Button(L("Reset", "Сбросить")) { message = nil; setting = defaultSetting }
                    .disabled(setting == defaultSetting)
                    .help(L("Back to the default shortcut", "Вернуть сочетание по умолчанию"))
            }
            if let message {
                InlineMessage(message.text, tone: message.tone, onDismiss: { self.message = nil })
            }
            if let note = registrationNote {
                InlineMessage(note, tone: .warning)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func validate(_ combo: HotkeyCombo) -> String? {
        if case .refused(let why) = HotkeyRecorderLogic.evaluate(combo, other: other, system: system()) { return why.text }
        return nil
    }

    private func captured(_ combo: HotkeyCombo?) {
        guard let combo else {
            message = nil
            setting.enabled = false
            return
        }
        apply(combo)
    }

    private func apply(_ combo: HotkeyCombo) {
        switch HotkeyRecorderLogic.evaluate(combo, other: other, system: system()) {
        case .refused(let why): message = (why.text, .warning)
        case .warned(let why): message = (why.text, .info); commit(combo)
        case .ok: message = nil; commit(combo)
        }
    }

    private func commit(_ combo: HotkeyCombo) {
        setting = HotkeySetting(enabled: true, combo: combo)
    }

    private var registrationNote: String? {
        guard setting.enabled, let r = registration else { return nil }
        if r.effective == nil {
            return L("No free shortcut was found. Record another one.", "Свободного сочетания не нашлось. Запишите другое.")
        }
        if r.fellBack, let e = r.effective {
            return L("\(HotkeyManager.spokenName(r.requested)) is taken; \(HotkeyManager.spokenName(e)) is in use instead.",
                     "\(HotkeyManager.spokenNameRU(r.requested)) занято; вместо него действует \(HotkeyManager.spokenNameRU(e)).")
        }
        return nil
    }
}

/// The AppKit recorder inside SwiftUI.
struct KeyCaptureRepresentable: NSViewRepresentable {
    var combo: HotkeyCombo?
    var isEnabled: Bool
    var label: String
    var validate: (HotkeyCombo) -> String?
    var onCapture: (HotkeyCombo?) -> Void
    var onRefuse: (String) -> Void

    func makeNSView(context: Context) -> KeyCaptureField {
        let field = KeyCaptureField()
        configure(field)
        return field
    }

    func updateNSView(_ field: KeyCaptureField, context: Context) { configure(field) }

    private func configure(_ field: KeyCaptureField) {
        field.combo = combo
        field.isEnabled = isEnabled
        field.validate = validate
        field.onCapture = onCapture
        field.onRefuse = onRefuse
        field.setAccessibilityLabel(label)
    }
}
