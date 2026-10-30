import SwiftUI

/// The toast itself: a glass card with the tone's glyph, one to three lines of text and an optional button. Used by the panel and by the snapshots.
struct ToastBubble: View {
    var item: ToastItem
    var onAction: (() -> Void)?

    init(item: ToastItem, onAction: (() -> Void)? = nil) { self.item = item; self.onAction = onAction }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            glyph
            Text(item.text)
                .font(DS.Typo.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let title = item.actionTitle {
                Button(title) { onAction?() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(nil)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: 440, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.spoken))
    }

    @ViewBuilder private var glyph: some View {
        let image = Image(systemName: item.effectiveSymbol).symbolRenderingMode(.hierarchical).font(.body.weight(DS.symbolWeight)).accessibilityHidden(true)
        if item.severity == .info { image.foregroundStyle(.secondary) } else { image.foregroundStyle(item.tone.ink) }
    }
}

/// The content of the toast panel: the bubble fades (Reduce Motion) or rises a few points with a fade, and leaves the same way.
struct ToastHost: View {
    @ObservedObject var model: ToastModel
    @Environment(\.a11y) private var a11y

    var body: some View {
        ZStack {
            if let item = model.item, model.shown {
                ToastBubble(item: item, onAction: { model.onAction?() })
                    .contentShape(Rectangle())
                    .onTapGesture { model.onTap?() }
                    .transition(a11y.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
        .animation(DS.Motion.animation(DS.Motion.open, reduceMotion: a11y.reduceMotion), value: model.shown)
        .padding(DS.Space.sm)   // room for the glass edge
    }
}
