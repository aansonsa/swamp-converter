import SwiftUI

/// Small capsule in Swamp Blue: file-kind chips ("Video"), info chips ("HEVC", "1080p30"), quick-recipe / default markers.
/// The capsule is the brand blue at about 14 percent over the material; the text and glyph use `blueChipInk` (>= 4.5:1 on that fill over every material,
/// checked by the "shared/chip inks" self-test). `emphasized` marks "the quick recipe / default" with a 1 pt outline instead of a heavier fill, so the text contrast
/// never changes. With Increase Contrast the fill goes away and every chip gets an outline. A chip that does not fit wraps to a second line instead of truncating;
/// put chips in a `FlowLayout` so whole chips wrap.
/// The one number every tinted chip and badge shares, so the contrast test and the views cannot drift apart.
enum ChipStyle {
    /// Opacity of the brand colour behind chip text.
    static let fillOpacity = 0.14
}

struct InfoChip: View {
    var text: String
    var symbol: String?
    /// Marks "the quick recipe / default" value in Studio.
    var emphasized = false
    @Environment(\.a11y) private var a11y

    init(_ text: String, symbol: String? = nil, emphasized: Bool = false) { self.text = text; self.symbol = symbol; self.emphasized = emphasized }

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let symbol { Image(systemName: symbol).symbolRenderingMode(.hierarchical).imageScale(.small).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(DS.Typo.caption.weight(.medium))
        .foregroundStyle(Brand.blueChipInk)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(a11y.increaseContrast ? Color.clear : Brand.blue.opacity(ChipStyle.fillOpacity), in: Self.shape)
        .overlay {
            if a11y.increaseContrast { Self.shape.strokeBorder(Brand.blueChipInk, lineWidth: emphasized ? 1.5 : 1) }
            else if emphasized { Self.shape.strokeBorder(Brand.blueChipInk.opacity(0.6), lineWidth: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct KindChip: View {
    var kind: FileKind
    var body: some View { InfoChip(kind.title.text, symbol: kind.symbol) }
}
