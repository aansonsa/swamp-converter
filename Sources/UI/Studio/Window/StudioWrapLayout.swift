import SwiftUI

/// Wraps whole items onto new lines like text, like the shared `FlowLayout`, with one difference that matters inside stacks: SwiftUI measures a column's MINIMUM size by proposing a width
/// of zero, and a plain flow layout then puts every item on its own line (a control bar that is "1000 pt tall at least"). This layout never lays out narrower than `minimumWidth`.
struct StudioWrapLayout: Layout {
    var spacing: CGFloat = DS.Space.xs + 2
    var lineSpacing: CGFloat = DS.Space.xs + 2
    static let minimumWidth: CGFloat = 280

    /// The width the arrangement uses for a proposal (pure, tested).
    static func effectiveWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let p = proposed else { return .infinity }
        return max(p, minimumWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = Self.effectiveWidth(proposal.width)
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w.isFinite ? w : nil, height: nil)) }
        return FlowLayout.arrange(sizes: sizes, maxWidth: w, spacing: spacing, lineSpacing: lineSpacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = max(bounds.width, Self.minimumWidth)
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)) }
        let arranged = FlowLayout.arrange(sizes: sizes, maxWidth: w, spacing: spacing, lineSpacing: lineSpacing)
        for (i, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + arranged.origins[i].x, y: bounds.minY + arranged.origins[i].y), proposal: ProposedViewSize(sizes[i]))
        }
    }
}
