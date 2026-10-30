import SwiftUI

/// The content of a help popover: an optional title, the explanation (wraps, never truncates), an optional "learn more" link in Swamp Blue's ink.
struct HelpPopoverContent: View {
    var title: String?
    var help: String
    var learnMoreTitle: String?
    var onLearnMore: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let title { Text(title).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true) }
            Text(help).font(DS.Typo.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if let learnMoreTitle, let onLearnMore {
                Button(action: onLearnMore) { Text(learnMoreTitle).font(DS.Typo.callout.weight(.medium)).foregroundStyle(Brand.blueInk) }
                    .buttonStyle(.plain)
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(DS.Space.lg)
    }
}

/// A small "?" that opens a popover with the explanation. Help is NEVER tooltip-only (tooltips do not exist for keyboard, VoiceOver or touch-less use):
/// the popover is the real thing, a plain `.help` tooltip is only the pointer's shortcut to the same words.
struct HelpPopoverButton: View {
    var help: String
    var title: String?
    var learnMoreTitle: String?
    var onLearnMore: (() -> Void)?
    @State private var shown = false
    @Environment(\.a11y) private var a11y

    init(_ help: String, title: String? = nil, learnMoreTitle: String? = nil, onLearnMore: (() -> Void)? = nil) {
        self.help = help; self.title = title; self.learnMoreTitle = learnMoreTitle; self.onLearnMore = onLearnMore
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.callout.weight(DS.symbolWeight))
                .foregroundStyle(a11y.increaseContrast ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(SharedStrings.help.text))
        .accessibilityHint(Text(help))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            HelpPopoverContent(title: title, help: help, learnMoreTitle: learnMoreTitle, onLearnMore: onLearnMore)
        }
    }
}

/// A label with its help popover: the standard way to title a field. Wraps on long Russian titles; the "?" stays at the end of the text.
struct HelpLabel: View {
    var title: String
    var help: String?
    init(_ title: String, help: String? = nil) { self.title = title; self.help = help }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            if let help { HelpPopoverButton(help, title: title) }
        }
    }
}
