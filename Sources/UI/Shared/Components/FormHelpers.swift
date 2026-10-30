import SwiftUI

/// A section of a `Form { }.formStyle(.grouped)` in the house style: an optional symbol and title, the rows, an optional footer sentence in secondary text.
/// Headers and footers wrap (long Russian titles never truncate) and never sit on a fixed width.
struct FormSection<Content: View>: View {
    var title: String?
    var symbol: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, symbol: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.footer = footer; self.content = content
    }

    var body: some View {
        Section {
            content()
        } header: {
            if let title {
                HStack(spacing: DS.Space.sm) {
                    if let symbol { SymbolIcon(symbol, style: .secondary).accessibilityHidden(true) }
                    Text(title).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if let footer { Text(footer).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A row of explanatory text inside a form section (a sentence, not a setting).
struct FormFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A read-only line: a title on the left, a value on the right in fixed-width digits so changing numbers (sizes, ETAs) do not make the layout jitter.
/// The value can be selected and copied.
struct ValueRow: View {
    var title: String
    var value: String
    var help: String?
    init(_ title: String, value: String, help: String? = nil) { self.title = title; self.value = value; self.help = help }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            HelpLabel(title, help: help)
            Spacer(minLength: DS.Space.md)
            Text(value).font(DS.Typo.numeric(.body)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
