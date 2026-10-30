import SwiftUI
import AppKit

/// A flat secondary button for use INSIDE a glass surface (a notice, a toast, the shelf): glass on glass looks muddy and the system warns against it.
/// A neutral capsule at 8 percent, the normal label colour, pressed 16 percent. Never tinted; one pink call to action per window stays `.brandProminent`.
struct FlatSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.a11y) private var a11y

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs + 1)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .overlay { if a11y.increaseContrast { Capsule().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1) } }
            .overlay { if isFocused { Capsule().strokeBorder(Brand.tint, lineWidth: 2).padding(-3) } }
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == FlatSecondaryButtonStyle {
    static var flatSecondary: FlatSecondaryButtonStyle { FlatSecondaryButtonStyle() }
}

struct NoticeAction {
    var title: String
    var handler: @MainActor () -> Void
    init(_ title: String, handler: @escaping @MainActor () -> Void) { self.title = title; self.handler = handler }
}

/// What a notice card shows. The jobs and download UI modules turn their events into this and host `NoticeCard` in a panel; the card itself never
/// decides how long it stays or where it sits.
struct NoticeCardContent: Identifiable {
    enum Progress: Equatable { case determinate(Double), indeterminate }

    var id = UUID()
    var tone: StatusTone = .info
    /// Overrides the tone's symbol (a job's kind icon, "arrow.down.circle" for a download).
    var symbol: String?
    var title: String
    var message: String?
    var progress: Progress?
    var primary: NoticeAction?
    var secondary: NoticeAction?
    var onClose: (@MainActor () -> Void)?

    init(title: String, message: String? = nil, tone: StatusTone = .info, symbol: String? = nil, progress: Progress? = nil,
         primary: NoticeAction? = nil, secondary: NoticeAction? = nil, onClose: (@MainActor () -> Void)? = nil) {
        self.title = title; self.message = message; self.tone = tone; self.symbol = symbol; self.progress = progress
        self.primary = primary; self.secondary = secondary; self.onClose = onClose
    }

    /// The one-line messages of `MessageCenter` ("Path copied", "Nothing selected").
    init(_ message: UserMessage, onClose: (@MainActor () -> Void)? = nil) {
        self.init(title: message.text, tone: StatusTone(message.severity), symbol: message.symbol, onClose: onClose)
    }
}

extension NoticeCardContent {
    /// What VoiceOver should say when the card appears without taking focus: the tone's name for problems ("Warning", "Error"), then the title and the message.
    /// Calm outcomes ("Converted 5 files") are not prefixed.
    var spokenAnnouncement: String {
        var parts: [String] = []
        if tone == .warning || tone == .error { parts.append(tone.spokenName.text) }
        parts.append(title)
        if let message, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: ". ")
    }
}

/// Speaks a line through VoiceOver without moving focus (a toast that appears while the person works elsewhere). Does nothing when VoiceOver is off.
@MainActor
enum AccessibilityAnnouncer {
    /// The notification payload (pure, unit-tested).
    static func userInfo(for text: String, priority: NSAccessibilityPriorityLevel = .medium) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        [.announcement: text, .priority: NSNumber(value: priority.rawValue)]
    }

    static func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: userInfo(for: text, priority: priority))
    }

    static func announce(_ content: NoticeCardContent) {
        announce(content.spokenAnnouncement, priority: content.tone == .error ? .high : .medium)
    }
}

/// The toast / HUD card: a glass panel with a symbol, a title, an optional second line, an optional progress bar, up to two actions and a close button.
/// Wraps (never truncates) at a fixed width, so the hosting panel can size itself from `fittingSize`. Reduce Transparency: opaque; Increase Contrast: outline.
struct NoticeCard: View {
    /// Every card is this wide, so a stack of toasts lines up (text wraps inside it).
    static let width: CGFloat = 360

    var content: NoticeCardContent
    @Environment(\.a11y) private var a11y

    init(_ content: NoticeCardContent) { self.content = content }

    var body: some View {
        GlassPanel(cornerRadius: DS.Radius.panel, padding: DS.Space.md) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: content.symbol ?? content.tone.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 20, weight: DS.symbolWeight))
                    .foregroundStyle(content.tone.ink)
                    .frame(width: 24)
                    .accessibilityLabel(Text(content.tone.spokenName.text))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(content.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let message = content.message {
                        Text(message).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress = content.progress {
                        SlantedProgressBar(value: { if case .determinate(let v) = progress { return v } else { return nil } }())
                            .padding(.vertical, DS.Space.xxs)
                    }
                    if content.primary != nil || content.secondary != nil {
                        HStack(spacing: DS.Space.sm) {
                            if let a = content.primary { Button(a.title) { a.handler() }.buttonStyle(.flatSecondary) }
                            if let a = content.secondary { Button(a.title) { a.handler() }.buttonStyle(.flatSecondary) }
                        }
                        .padding(.top, DS.Space.xxs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let close = content.onClose {
                    Button { close() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 18, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(Text(SharedStrings.close.text))
                }
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
