import SwiftUI

/// Lays views out in rows that wrap like text: whole chips move to the next line instead of truncating. For chip rows, tag lists, summary capsules.
/// Rows are leading-aligned; every view keeps its ideal size (a view wider than the container gets its own row and is proposed the container's width).
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.Space.xs + 2
    var lineSpacing: CGFloat = DS.Space.xs + 2

    /// The pure arrangement (unit-tested): origins of the items and the total size for `maxWidth`.
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
