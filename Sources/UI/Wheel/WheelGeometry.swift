import Foundation
import CoreGraphics

/// Pure geometry of the wheel (spec/wheel.md 4, 18.2): unit-tested for n in 0...13, scalable (ring thickness derives the concentric radii).
/// Sector 0 is centred at 12 o'clock, sectors run clockwise; the hub is the cancel zone; the 6 pt visual gaps are NOT dead zones.
///
/// Coordinates are relative to the wheel centre with Y pointing UP (the AppKit convention); `WheelSectorShape` flips them for SwiftUI.
/// Angles are radians measured clockwise from 12 o'clock unless a name says "degrees".
struct WheelGeometry: Equatable, Sendable {
    /// Outer radius of the disc in points (default 180 x scale). Hub radius = 1/3 of it.
    var outerRadius: CGFloat = 180
    var hubRadius: CGFloat = 60
    var gap: CGFloat = 6
    var sectorCount: Int
    /// Extra hit slop beyond the outer edge (the original's 9 pt rim): a drop on the very edge of a sector still counts.
    var rim: CGFloat = 8

    /// Transparent margin around the disc inside the panel: room for the 7 pt hover pop, the outline and antialiasing.
    static let pad: CGFloat = 24
    /// The hover translation along the sector's mid-angle.
    static let popDistance: CGFloat = 7
    /// Reference radius the default numbers belong to.
    static let referenceOuterRadius: CGFloat = 180

    init(outerRadius: CGFloat = 180, hubRadius: CGFloat = 60, gap: CGFloat = 6, sectorCount: Int, rim: CGFloat = 8) {
        self.outerRadius = outerRadius; self.hubRadius = hubRadius; self.gap = gap; self.sectorCount = sectorCount; self.rim = rim
    }

    /// The geometry for the `wheelScale` setting (0.8 ... 1.2): radii scale, the gap and pop stay readable.
    static func scaled(_ scale: Double, sectorCount: Int) -> WheelGeometry {
        let s = CGFloat(min(max(scale, 0.8), 1.2))
        return WheelGeometry(outerRadius: referenceOuterRadius * s, hubRadius: referenceOuterRadius * s / 3, gap: 6, sectorCount: sectorCount)
    }

    // MARK: Derived numbers

    var ringThickness: CGFloat { outerRadius - hubRadius }
    /// Nine or more sectors: neighbouring labels are closer than a label is tall, so the labels move outwards (where the sectors are wider), lose their second line
    /// (the hub shows it while the sector is hovered) and use a smaller symbol.
    var isCrowded: Bool { sectorCount >= 9 }
    /// Radius of the label centres: the middle of the ring (120 at scale 1), further out when the wheel is crowded (134 with 12 sectors).
    var labelRadius: CGFloat { hubRadius + ringThickness * (isCrowded ? 0.62 : 0.5) }
    /// Size of the (square) panel that holds the disc: disc diameter plus the transparent pad on every side.
    var panelSide: CGFloat { 2 * (outerRadius + Self.pad) }
    /// Angular width of one sector in radians (the full circle for n <= 1).
    var step: CGFloat { sectorCount <= 1 ? 2 * .pi : 2 * .pi / CGFloat(sectorCount) }
    /// Outer corner radius (11 pt at scale 1): the same proportion of the ring as in the original, so inner and outer curves stay concentric.
    var outerCorner: CGFloat { ringThickness * 0.095 }
    var innerCorner: CGFloat { outerCorner * 0.7 }

    /// Width available to a sector's label (spec 4.5): 120 for one or two sectors, otherwise the chord at the label radius, clamped to 48...110.
    var labelWidth: CGFloat {
        if sectorCount <= 2 { return 120 * outerRadius / Self.referenceOuterRadius }
        let chord = 2 * labelRadius * sin(step / 2) * (isCrowded ? 0.92 : 0.84)
        return min(max(chord, 48), 110 * outerRadius / Self.referenceOuterRadius)
    }

    // MARK: Hit testing

    /// Index of the sector under `point` (relative to the wheel centre, y up), or -1 for the hub, outside the rim, or n == 0.
    func hitTest(_ point: CGPoint) -> Int {
        guard sectorCount > 0 else { return -1 }
        let r = hypot(point.x, point.y)
        if r < hubRadius || r > outerRadius + rim { return -1 }
        if sectorCount == 1 { return 0 }
        var angle = atan2(point.x, point.y)            // clockwise from 12 o'clock when y points up
        if angle < 0 { angle += 2 * .pi }
        let shifted = (angle + step / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return min(Int(shifted / step), sectorCount - 1)
    }

    /// True when the point lies on the disc or its hit rim (hub included): the area that belongs to the wheel; anything else is "outside".
    func containsDisc(_ point: CGPoint) -> Bool { hypot(point.x, point.y) <= outerRadius + rim }
    func inHub(_ point: CGPoint) -> Bool { hypot(point.x, point.y) < hubRadius }

    // MARK: Angles and positions

    /// Centre angle of sector `index` in radians clockwise from 12 o'clock.
    func centerAngle(of index: Int) -> CGFloat { sectorCount <= 1 ? 0 : CGFloat(index) * step }

    /// Where the label of sector `index` sits (label radius 120 at scale 1).
    /// For a single full-ring sector the label sits at 12 o'clock on the label radius (never inside the hub).
    func labelCenter(of index: Int) -> CGPoint { Self.polar(labelRadius, centerAngle(of: index)) }

    /// The unit direction of the hover pop of sector `index` (screen Y down, ready for `.offset`).
    func popDirection(of index: Int) -> CGSize {
        guard sectorCount > 1 else { return .zero }
        let a = centerAngle(of: index)
        return CGSize(width: sin(a), height: -cos(a))
    }

    /// Point at radius `r` and clockwise angle `a` (radians), Y up.
    static func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: r * sin(a), y: r * cos(a)) }

    // MARK: Sector path

    /// The ring-sector path (outer / inner arcs, concentric corner radii derived from the ring thickness) for the glass shape and the hit area.
    /// Each side edge is shifted sideways by `gap / 2` (constant-width gap: the edges are parallel straight lines, not radial lines). `popOut` translates
    /// the whole sector along its mid-angle. For n == 1 the sector is the full annulus; for n == 0 the path is empty.
    func sectorPath(_ index: Int, popOut: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        guard sectorCount > 0, index >= 0, index < sectorCount else { return path }
        let outer = outerRadius, inner = hubRadius
        if sectorCount == 1 {
            path.move(to: CGPoint(x: outer, y: 0))
            // A clockwise arc must sweep to a smaller angle: 0 -> +2pi clockwise collapses to a zero-length arc (an empty ring and a filled hub).
            path.addArc(center: .zero, radius: outer, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
            path.closeSubpath()
            path.move(to: CGPoint(x: inner, y: 0))
            path.addArc(center: .zero, radius: inner, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            return path
        }
        let mid = centerAngle(of: index)
        let a0 = mid - step / 2, a1 = mid + step / 2
        let half = gap / 2
        // Angle of a side edge at radius r: shifted inwards by asin((gap / 2) / r) so the gap has constant width.
        func edge(_ r: CGFloat, _ a: CGFloat, _ side: CGFloat) -> CGFloat { a + side * asin(min(half / r, 1)) }
        let outerStart = edge(outer, a0, +1), outerEnd = edge(outer, a1, -1)
        let innerStart = edge(inner, a0, +1), innerEnd = edge(inner, a1, -1)
        let cOut = min(outerCorner, (outerEnd - outerStart) * outer * 0.45)
        let cIn = min(innerCorner, (innerEnd - innerStart) * inner * 0.45)
        let dOut = cOut / outer, dIn = cIn / inner

        func arc(_ radius: CGFloat, from: CGFloat, to: CGFloat, clockwise: Bool) {
            // clockwise-from-12 angle a  ->  mathematical angle pi/2 - a
            path.addArc(center: .zero, radius: radius, startAngle: .pi / 2 - from, endAngle: .pi / 2 - to, clockwise: clockwise)
        }
        path.move(to: Self.polar(outer, outerStart + dOut))
        arc(outer, from: outerStart + dOut, to: outerEnd - dOut, clockwise: true)
        path.addQuadCurve(to: Self.polar(outer - cOut, edge(outer - cOut, a1, -1)), control: Self.polar(outer, outerEnd))
        path.addLine(to: Self.polar(inner + cIn, edge(inner + cIn, a1, -1)))
        path.addQuadCurve(to: Self.polar(inner, innerEnd - dIn), control: Self.polar(inner, innerEnd))
        arc(inner, from: innerEnd - dIn, to: innerStart + dIn, clockwise: false)
        path.addQuadCurve(to: Self.polar(inner + cIn, edge(inner + cIn, a0, +1)), control: Self.polar(inner, innerStart))
        path.addLine(to: Self.polar(outer - cOut, edge(outer - cOut, a0, +1)))
        path.addQuadCurve(to: Self.polar(outer, outerStart + dOut), control: Self.polar(outer, outerStart))
        path.closeSubpath()

        guard popOut != 0 else { return path }
        let d = Self.polar(popOut, mid)
        var t = CGAffineTransform(translationX: d.x, y: d.y)
        return path.copy(using: &t) ?? path
    }

    // MARK: Placement

    /// Panel frame for a wheel anchored at `anchor` (screen coordinates): centred under the cursor, clamped so the DISC stays >= `margin` points inside
    /// `visibleFrame`. `discInset` is the transparent pad between the panel edge and the disc (`WheelGeometry.pad`): the panel itself may protrude by
    /// `discInset - margin`, the visible disc never does. When the screen is smaller than the disc the panel is centred on it.
    static func placement(anchor: CGPoint, panelSize: CGFloat, visibleFrame: CGRect, margin: CGFloat = 16, discInset: CGFloat = 0) -> CGRect {
        let half = panelSize / 2
        let reach = half - discInset                       // radius of the visible disc
        func clampCentre(_ c: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let low = lo + margin + reach, high = hi - margin - reach
            return low > high ? (lo + hi) / 2 : min(max(c, low), high)
        }
        let cx = clampCentre(anchor.x, visibleFrame.minX, visibleFrame.maxX)
        let cy = clampCentre(anchor.y, visibleFrame.minY, visibleFrame.maxY)
        return CGRect(x: cx - half, y: cy - half, width: panelSize, height: panelSize)
    }
}

// MARK: - Slots

/// Which list position lands on which slot of the ring. Without favourites the order is the list order clockwise from 12 o'clock. With favourites, and when the
/// ring has slots exactly on the four axes (12, 3, 6, 9 o'clock: 4 or 8 slots), the first favourites take the axes in star order: the easiest directions to hit
/// without looking (spec/ux.md 1). `fixedLast` keeps the final slot (the "More..." / "Back" sector) where it is.
enum WheelSlotting {
    /// `ids` in list order; returns them in slot order.
    static func slotOrder(ids: [String], favorites: [String], fixedLast: Bool) -> [String] {
        let movable = fixedLast ? Array(ids.dropLast()) : ids
        let tail = fixedLast ? Array(ids.suffix(1)) : []
        let n = ids.count
        let favs = favorites.filter { movable.contains($0) }
        guard !favs.isEmpty, n >= 4, n % 4 == 0 else { return ids }
        let axisSlots = stride(from: 0, to: n, by: n / 4).filter { !(fixedLast && $0 == n - 1) }
        var result = [String?](repeating: nil, count: n)
        var placed = Set<String>()
        for (k, id) in favs.prefix(axisSlots.count).enumerated() { result[axisSlots[k]] = id; placed.insert(id) }
        var rest = movable.filter { !placed.contains($0) }.makeIterator()
        for slot in 0..<(fixedLast ? n - 1 : n) where result[slot] == nil { result[slot] = rest.next() }
        if fixedLast, let last = tail.first { result[n - 1] = last }
        return result.compactMap { $0 }
    }
}
