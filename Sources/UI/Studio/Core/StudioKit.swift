import SwiftUI
import AppKit

// A tiny kit of presentation helpers the renderer needs, written against the FROZEN skeleton of the design system only (Brand, DS, InfoChip, GlassPanel, secondaryButtonLook),
// so this module type-checks and tests in isolation. Everything is prefixed `Option` / `Studio` so it can never collide with the finished Shared components.

enum OptionStrings {
    static let modified = L10n("Modified", "Изменено")
    static let revertToDefault = L10n("Revert to default", "Вернуть значение по умолчанию")
    static let help = L10n("Help", "Справка")
    static let dismiss = L10n("Dismiss", "Скрыть")
}

// MARK: Tones

/// info / warning / error: symbol, spoken name and a text-grade ink (>= 4.5:1 on light and dark materials; deeper with Increase Contrast). Meaning never rests on colour alone.
enum OptionTone: Sendable {
    case info, warning, error

    init(_ severity: OptionSeverity) {
        switch severity { case .info: self = .info; case .warning: self = .warning; case .error: self = .error }
    }

    var symbol: String {
        switch self { case .info: return "info.circle"; case .warning: return "exclamationmark.triangle"; case .error: return "xmark.octagon" }
    }

    var spokenName: L10n {
        switch self {
        case .info: return L10n("Note", "Примечание")
        case .warning: return L10n("Warning", "Предупреждение")
        case .error: return L10n("Error", "Ошибка")
        }
    }

    /// (r, g, b) for an appearance.
    func rgb(dark: Bool, increaseContrast ic: Bool) -> (Int, Int, Int) {
        switch self {
        case .info: return dark ? (125, 167, 217) : (ic ? (36, 75, 123) : (49, 103, 168))
        case .warning: return dark ? (255, 190, 90) : (ic ? (120, 66, 0) : (138, 78, 0))
        case .error: return dark ? (255, 125, 115) : (ic ? (160, 20, 20) : (178, 26, 26))
        }
    }

    var ink: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = rgb(dark: dark, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        })
    }
}

// MARK: Message row

/// A calm message beside its cause: symbol + spoken name carry the meaning, the text keeps the normal label colour on a faint wash, an optional one-click fix (it drops below the
/// text when it does not fit, as Russian sentences are long) and an optional dismiss button.
struct OptionMessageRow: View {
    var tone: OptionTone
    var text: String
    var fixTitle: String?
    var onFix: (() -> Void)?
    var onDismiss: (() -> Void)?
    @Environment(\.a11y) private var a11y

    init(_ text: String, tone: OptionTone = .info, fixTitle: String? = nil, onFix: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.tone = tone; self.text = text; self.fixTitle = fixTitle; self.onFix = onFix; self.onDismiss = onDismiss
    }

    init(_ text: String, severity: OptionSeverity, onDismiss: (() -> Void)? = nil) {
        self.init(text, tone: OptionTone(severity), onDismiss: onDismiss)
    }

    /// A schema validation result with its fix.
    init(_ message: OptionMessage, onFix: ((OptionFix) -> Void)? = nil) {
        var action: (() -> Void)?
        if let fix = message.fix, let onFix { action = { onFix(fix) } }
        self.init(message.text.text, tone: OptionTone(message.severity), fixTitle: message.fix?.title.text, onFix: action)
    }

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                icon
                label
                Spacer(minLength: 0)
                fixButton
                dismissButton
            }
            HStack(alignment: .top, spacing: DS.Space.md) {
                icon
                VStack(alignment: .leading, spacing: DS.Space.sm) { label; fixButton }
                Spacer(minLength: 0)
                dismissButton
            }
        }
        .padding(DS.Space.md)
        .background(a11y.increaseContrast ? Color.clear : tone.ink.opacity(0.11), in: Self.shape)
        .overlay { if a11y.increaseContrast { Self.shape.strokeBorder(tone.ink, lineWidth: 1) } }
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: tone.symbol).symbolRenderingMode(.monochrome).font(.body.weight(DS.symbolWeight))
            .foregroundStyle(tone.ink).frame(width: 20)
            .accessibilityLabel(Text(tone.spokenName.text))
    }

    private var label: some View {
        Text(text).font(DS.Typo.callout).fixedSize(horizontal: false, vertical: true).layoutPriority(1).frame(minWidth: 0, alignment: .leading)
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
                .accessibilityLabel(Text(OptionStrings.dismiss.text))
        }
    }
}

// MARK: Help

/// The content of a help popover (wraps, never truncates).
struct OptionHelpContent: View {
    var title: String?
    var help: String
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let title { Text(title).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true) }
            Text(help).font(DS.Typo.callout).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280, alignment: .leading)
        .padding(DS.Space.lg)
    }
}

/// A label with its help popover. Help is NEVER tooltip-only: the popover works from the keyboard and VoiceOver; the tooltip is the pointer's shortcut to the same words.
struct OptionHelpLabel: View {
    var title: String
    var help: String?
    @State private var shown = false
    @Environment(\.a11y) private var a11y

    init(_ title: String, help: String? = nil) { self.title = title; self.help = help }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            if let help {
                Button { shown.toggle() } label: {
                    Image(systemName: "questionmark.circle").symbolRenderingMode(.hierarchical).font(.callout.weight(DS.symbolWeight))
                        .foregroundStyle(a11y.increaseContrast ? Color.primary : Color.secondary)
                        .frame(width: 20, height: 20).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel(Text(OptionStrings.help.text))
                .accessibilityHint(Text(help))
                .popover(isPresented: $shown, arrowEdge: .bottom) { OptionHelpContent(title: title, help: help) }
            }
        }
    }
}

// MARK: Modified badge

/// "Modified": the values now differ from the preset (or the quick recipe), with a revert button. Pink-tinted, ink text.
struct StudioModifiedBadge: View {
    var onRevert: (() -> Void)?
    @Environment(\.a11y) private var a11y

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(OptionStrings.modified.text)
            if let onRevert {
                Button(action: onRevert) { Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.bold)).frame(width: 14, height: 14).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(OptionStrings.revertToDefault.text))
                    .help(OptionStrings.revertToDefault.text)
            }
        }
        .font(DS.Typo.caption.weight(.semibold))
        .foregroundStyle(Brand.pinkInk)
        .padding(.horizontal, DS.Space.sm + 2).padding(.vertical, 2)
        .background(a11y.increaseContrast ? Color.clear : Brand.pink.opacity(0.14), in: Capsule())
        .overlay { if a11y.increaseContrast { Capsule().strokeBorder(Brand.pinkInk, lineWidth: 1) } }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Flow layout

/// Rows that wrap like text: whole chips move to the next line instead of truncating.
struct OptionFlow: Layout {
    var spacing: CGFloat = DS.Space.xs + 2
    var lineSpacing: CGFloat = DS.Space.xs + 2

    static func arrange(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in sizes {
            if x > 0, x + s.width > maxWidth { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: sizes.isEmpty ? 0 : y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)) }
        return Self.arrange(sizes: sizes, maxWidth: maxWidth, spacing: spacing, lineSpacing: lineSpacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        let arranged = Self.arrange(sizes: sizes, maxWidth: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (i, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + arranged.origins[i].x, y: bounds.minY + arranged.origins[i].y), proposal: ProposedViewSize(sizes[i]))
        }
    }
}

// MARK: Announcements

@MainActor
enum OptionAnnouncer {
    /// Politely tells VoiceOver (does nothing when it is off).
    static func announce(_ text: String) {
        guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSNumber(value: NSAccessibilityPriorityLevel.low.rawValue)])
    }
}

/// A sentence of explanation in secondary text.
struct OptionFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
