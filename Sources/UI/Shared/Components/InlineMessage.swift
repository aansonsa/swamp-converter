import SwiftUI

/// A calm message that sits beside its cause: a Studio validation note under a field, a Settings warning, a download error with its way out.
/// Symbol + spoken name carry the meaning (never colour alone); the text is the normal label colour, so it stays readable on the faint wash.
/// Optional one-click fix and a dismiss button. If the fix button does not fit beside the text it drops below it (long Russian sentences).
///
///     InlineMessage(L("The target is larger than the source.", "Целевой размер больше исходного."), severity: .warning,
///                   fixTitle: L("Keep the Original Size", "Оставить исходный размер"), onFix: { ... })
///     InlineMessage(optionMessage) { fix in session.apply(fix) }        // Studio: straight from a schema validation result
struct InlineMessage: View {
    var tone: StatusTone
    var text: String
    var detail: String?
    var fixTitle: String?
    var onFix: (() -> Void)?
    var onDismiss: (() -> Void)?
    @Environment(\.a11y) private var a11y

    init(_ text: String, tone: StatusTone = .info, detail: String? = nil, fixTitle: String? = nil, onFix: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.tone = tone; self.text = text; self.detail = detail; self.fixTitle = fixTitle; self.onFix = onFix; self.onDismiss = onDismiss
    }

    init(_ text: String, severity: OptionSeverity, detail: String? = nil, fixTitle: String? = nil, onFix: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.init(text, tone: StatusTone(severity), detail: detail, fixTitle: fixTitle, onFix: onFix, onDismiss: onDismiss)
    }

    /// A schema validation result: its text, its severity, and its one-click fix (`onFix` receives the fix to apply).
    init(_ message: OptionMessage, onFix: ((OptionFix) -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        var action: (() -> Void)?
        if let fix = message.fix, let onFix { action = { onFix(fix) } }
        self.init(message.text.text, tone: StatusTone(message.severity), detail: nil, fixTitle: message.fix?.title.text, onFix: action, onDismiss: onDismiss)
    }

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                icon
                textBlock
                Spacer(minLength: 0)
                fixButton
                dismissButton
            }
            HStack(alignment: .top, spacing: DS.Space.md) {
                icon
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    textBlock
                    fixButton
                }
                Spacer(minLength: 0)
                dismissButton
            }
        }
        .padding(DS.Space.md)
        .background(tone.wash(increaseContrast: a11y.increaseContrast), in: Self.shape)
        .overlay { if a11y.increaseContrast { Self.shape.strokeBorder(tone.ink, lineWidth: 1) } }
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: tone.symbol)
            .symbolRenderingMode(.monochrome)
            .font(.body.weight(DS.symbolWeight))
            .foregroundStyle(tone.ink)
            .frame(width: 20)
            .accessibilityLabel(Text(tone.spokenName.text))
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(text).font(DS.Typo.callout).fixedSize(horizontal: false, vertical: true)
            if let detail { Text(detail).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .layoutPriority(1)
        .frame(minWidth: 0, alignment: .leading)
    }

    @ViewBuilder private var fixButton: some View {
        if let fixTitle, let onFix {
            Button(action: onFix) { Text(fixTitle).fixedSize(horizontal: false, vertical: true) }
                .buttonStyle(.bordered).controlSize(.small).tint(nil)
        }
    }

    @ViewBuilder private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 16, height: 16).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(Text(SharedStrings.dismiss.text))
        }
    }
}
