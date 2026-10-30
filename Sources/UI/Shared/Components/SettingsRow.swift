import SwiftUI

/// A settings line for `Form { }.formStyle(.grouped)`: title on the left, the control on the right, optional help under the title.
/// Nothing has a fixed width, so long Russian labels wrap instead of truncating. Give a Toggle its title as the label and hide it
/// (`Toggle(title, isOn:).labelsHidden()`), or use `SettingsToggleRow`, so VoiceOver can name the control.
struct SettingsRow<Control: View>: View {
    var title: String
    var help: String?
    var symbol: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, help: String? = nil, symbol: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.help = help; self.symbol = symbol; self.control = control
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            if let symbol { SymbolIcon(symbol, style: .secondary).frame(width: 22).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let help {
                    Text(help).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.md)
            control()
        }
        .accessibilityElement(children: .contain)
    }
}

/// The most common settings line: a title, an optional sentence of help, a switch on the right. The switch carries the title for VoiceOver.
struct SettingsToggleRow: View {
    var title: String
    var help: String?
    var symbol: String?
    @Binding var isOn: Bool

    init(_ title: String, help: String? = nil, symbol: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.help = help; self.symbol = symbol; self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, help: help, symbol: symbol) { Toggle(title, isOn: $isOn).labelsHidden() }
    }
}
