import SwiftUI

/// One key of a shortcut as drawn on a keycap, with the words VoiceOver speaks for it.
struct KeyCap: Equatable, Sendable {
    var glyph: String
    var spoken: String
}

/// Pure formatting of shortcuts into keycaps (unit-tested): modifier order is the macOS order (control, option, shift, command), then the key.
enum KeyCapFormat {
    static func caps(for combo: HotkeyCombo) -> [KeyCap] {
        var caps: [KeyCap] = []
        if combo.modifiers & HotkeyModifier.control != 0 { caps.append(KeyCap(glyph: "\u{2303}", spoken: "Control")) }
        if combo.modifiers & HotkeyModifier.option != 0 { caps.append(KeyCap(glyph: "\u{2325}", spoken: "Option")) }
        if combo.modifiers & HotkeyModifier.shift != 0 { caps.append(KeyCap(glyph: "\u{21E7}", spoken: "Shift")) }
        if combo.modifiers & HotkeyModifier.command != 0 { caps.append(KeyCap(glyph: "\u{2318}", spoken: "Command")) }
        caps.append(key(combo.keyCode))
        return caps
    }

    /// The key itself: letters upper-case, a few named keys localised ("Space" / "Пробел"), anything unknown as "Key N" / "Клавиша N".
    static func key(_ code: UInt32) -> KeyCap {
        let name = HotkeyCombo.keyName(code)
        switch name {
        case "Space": return KeyCap(glyph: SharedStrings.space.text, spoken: SharedStrings.space.text)
        case "Return": return KeyCap(glyph: "\u{21A9}", spoken: "Return")
        case "Tab": return KeyCap(glyph: "\u{21E5}", spoken: "Tab")
        case "Esc": return KeyCap(glyph: "\u{238B}", spoken: "Escape")
        case "Delete": return KeyCap(glyph: "\u{232B}", spoken: "Delete")
        default:
            if name.hasPrefix("Key ") { return KeyCap(glyph: "#\(code)", spoken: SharedStrings.unnamedKey(code)) }
            return KeyCap(glyph: name.uppercased(), spoken: name)
        }
    }

    /// "Control Option Space" for VoiceOver.
    static func spoken(for combo: HotkeyCombo) -> String { caps(for: combo).map(\.spoken).joined(separator: " ") }
}

/// A shortcut drawn as keycaps: flat rounded tiles in a neutral fill (no bevels, no shadows), SF Pro medium, widening for words ("Space", "Пробел").
struct KeyCapView: View {
    var caps: [KeyCap]
    var spoken: String
    @Environment(\.a11y) private var a11y

    init(_ combo: HotkeyCombo) { caps = KeyCapFormat.caps(for: combo); spoken = KeyCapFormat.spoken(for: combo) }
    init(keys: [String]) { caps = keys.map { KeyCap(glyph: $0, spoken: $0) }; spoken = keys.joined(separator: " ") }

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap.glyph)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.xs + 2)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.primary.opacity(0.08), in: Self.shape)
                    .overlay { Self.shape.strokeBorder(Color.primary.opacity(a11y.increaseContrast ? 0.6 : 0.12), lineWidth: a11y.increaseContrast ? 1 : 0.5) }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }
}
