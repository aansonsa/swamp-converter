import SwiftUI

/// A parallelogram with softly rounded corners, leaning like the logo (`Brand.slant`, about 6 degrees). The brand's motif for tiny badges.
struct SlantedBadgeShape: Shape {
    var slant: Double = Brand.slant
    var cornerRadius: CGFloat = 4

    /// How far the top edge sits to the right of the bottom edge for a given height.
    static func lean(height: CGFloat, slant: Double = Brand.slant) -> CGFloat { height * CGFloat(tan(slant * .pi / 180)) }

    func path(in rect: CGRect) -> Path {
        let lean = Self.lean(height: rect.height, slant: slant)
        let base = Path(roundedRect: CGRect(x: lean / 2, y: 0, width: max(rect.width - lean, 0), height: rect.height), cornerRadius: cornerRadius, style: .continuous)
        // Shear about the vertical centre so the top leans right and the bottom left (italic).
        let shear = CGAffineTransform(a: 1, b: 0, c: -CGFloat(tan(slant * .pi / 180)), d: 1, tx: rect.midY * CGFloat(tan(slant * .pi / 180)), ty: 0)
        return base.applying(shear)
    }
}

/// "Modified": a preset or field now differs from its default / quick recipe. Optionally carries a revert button.
/// Pink-tinted slanted badge with `pinkChipInk` text (>= 4.5:1 on the fill); the text is a short word, the revert glyph has a spoken label.
struct ModifiedBadge: View {
    var title: String
    var onRevert: (() -> Void)?
    @Environment(\.a11y) private var a11y

    init(title: String = SharedStrings.modified.text, onRevert: (() -> Void)? = nil) { self.title = title; self.onRevert = onRevert }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            if let onRevert {
                Button(action: onRevert) {
                    Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.bold)).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(SharedStrings.revertToDefault.text))
                .help(SharedStrings.revertToDefault.text)
            }
        }
        .font(DS.Typo.caption.weight(.semibold))
        .foregroundStyle(Brand.pinkChipInk)
        .padding(.horizontal, DS.Space.sm + 2)
        .padding(.vertical, 2)
        .background(a11y.increaseContrast ? Color.clear : Brand.pink.opacity(ChipStyle.fillOpacity), in: SlantedBadgeShape())
        .overlay { if a11y.increaseContrast { SlantedBadgeShape().stroke(Brand.pinkChipInk, lineWidth: 1) } }
        .accessibilityElement(children: .contain)
    }
}
