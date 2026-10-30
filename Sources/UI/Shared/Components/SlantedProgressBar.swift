import SwiftUI
import AppKit

/// Progress bar with the brand's slanted leading edge. Pink fill on a quaternary track; `secondary` swaps to Swamp Blue (second
/// stage, preview scrubber). `value == nil` is indeterminate: a short fixed segment that gently slides back and forth.
///
/// The fill is drawn and animated by Core Animation (`SlantedBarLayerView`): every update of `value` sets one layer transform with a 0.25 s linear glide
/// that the RENDER SERVER interpolates, and the indeterminate slide is one repeating animation that also lives there. Nothing runs in this process between
/// updates (measured: eight bars updated at 10 Hz cost about 1.5 s of CPU per 1.5 s as a SwiftUI animation and a few milliseconds like this; the
/// self-tests "shared/... cost almost no CPU" keep it that way). Reduce Motion: no glide, no slide (a static segment).
///
/// The fill is a meaning-carrying graphic, so it uses `Brand.tint` (pure pink in dark mode, the deepened pink in light mode) and `Brand.blueFill`:
/// >= 3:1 against the track on every material (self-test "shared/progress fill"). Updates arrive at <= 10 Hz from the job layer.
struct SlantedProgressBar: View {
    var value: Double?
    var secondary = false
    var height: CGFloat = 6
    @Environment(\.a11y) private var a11y

    init(value: Double?, secondary: Bool = false, height: CGFloat = 6) { self.value = value; self.secondary = secondary; self.height = height }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            SlantedBar(fraction: value, secondary: secondary).allowsHitTesting(false)
        }
        .overlay { if a11y.increaseContrast { Capsule().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1) } }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text(SharedStrings.progress.text))
        .accessibilityValue(Text(value.map { Loc.percent(Int(($0 * 100).rounded())) } ?? SharedStrings.inProgress.text))
    }
}

/// Rectangle covering `fraction` of the width whose right edge leans by `slant` degrees (the brand motif). The SwiftUI shape of the bar's fill: the layer
/// view below draws the same outline (the self-test compares both).
struct SlantedFill: Shape {
    var fraction: CGFloat
    var slant: Double
    var animatableData: CGFloat { get { fraction } set { fraction = newValue } }

    func path(in rect: CGRect) -> Path {
        let lean = rect.height * CGFloat(tan(slant * .pi / 180))
        let right = rect.width * fraction
        var p = Path()
        guard right > 0 else { return p }
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: min(right + lean, rect.width + lean), y: 0))
        p.addLine(to: CGPoint(x: max(right - lean, 0), y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Core Animation drawing

/// The fill of a slanted progress bar. The view clips to a capsule and owns ONE `CAShapeLayer`.
///   determinate (`fraction` 0...1): a fixed parallelogram twice the bar's width, translated so its slanted right edge sits at `fraction x width`;
///                                   changing the fraction animates the translation (0.25 s, linear) in the render server;
///   indeterminate (`fraction == nil`): a 28 percent segment that slides to the far end and back, forever, only while the view is in a window.
@MainActor
final class SlantedBarLayerView: NSView {
    /// nil = indeterminate. NaN counts as 0, values outside 0...1 are clamped.
    var fraction: Double? { didSet { if fraction != oldValue { fractionChanged(from: oldValue) } } }
    var secondary = false { didSet { if secondary != oldValue { updateColors() } } }
    var reduceMotion = false { didSet { if reduceMotion != oldValue { updateAnimation() } } }
    /// Set by the SwiftUI wrapper; plain AppKit users leave it nil and get the system value.
    var increaseContrastOverride: Bool? { didSet { if increaseContrastOverride != oldValue { updateColors() } } }

    private let fill = CAShapeLayer()
    static let slideKey = "swp.slide"
    /// Width of the indeterminate segment and how far it travels (fractions of the bar width): it ends flush with the right end.
    static let segmentFraction = 0.28
    static let travelFraction = 1 - segmentFraction
    static let slideDuration = 1.1
    /// The glide between two progress values.
    static let glideDuration = 0.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        fill.fillColor = nil
        layer?.addSublayer(fill)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("SlantedBarLayerView is created in code") }

    var isSliding: Bool { fill.animation(forKey: Self.slideKey) != nil }
    var isIndeterminate: Bool { fraction == nil }

    /// The value actually drawn: nil stays nil, NaN becomes 0, the rest is clamped to 0...1.
    static func normalized(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value.isNaN { return 0 }
        return min(max(value, 0), 1)
    }

    /// The determinate shape for a bar `size` points big: from one bar-width left of the origin to the slanted right edge at the bar's width
    /// (AppKit layers are y-up: the TOP edge leans right, like `SlantedFill`). Translating it by `(f - 1) x width` puts the edge at `f x width`.
    static func fillPath(in size: CGSize, slant: Double = Brand.edgeSlant) -> CGPath {
        let lean = size.height * CGFloat(tan(slant * .pi / 180))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -size.width, y: 0))
        p.addLine(to: CGPoint(x: size.width - lean, y: 0))
        p.addLine(to: CGPoint(x: size.width + lean, y: size.height))
        p.addLine(to: CGPoint(x: -size.width, y: size.height))
        p.closeSubpath()
        return p
    }

    /// The indeterminate segment's outline: 28 percent of the width plus the lean of the top edge.
    static func segmentPath(in size: CGSize, slant: Double = Brand.edgeSlant) -> CGPath {
        let lean = size.height * CGFloat(tan(slant * .pi / 180))
        let right = size.width * CGFloat(segmentFraction)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: max(right - lean, 0), y: 0))
        p.addLine(to: CGPoint(x: right + lean, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    /// The horizontal translation of the determinate shape for `fraction` (0 puts the slanted edge at the left end).
    static func translation(forFraction f: Double, width: CGFloat) -> CGFloat { CGFloat((normalized(f) ?? 0) - 1) * width }

    override func layout() {
        super.layout()
        geometryChanged()
    }

    /// AppKit does not run `layout()` after every resize of a plain view (SwiftUI resizes this one after creating it), so the size is also watched directly.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { geometryChanged() }
    }

    private func geometryChanged() {
        layer?.cornerRadius = bounds.height / 2
        rebuildShape()
        if isSliding { fill.removeAnimation(forKey: Self.slideKey) }   // the travel distance depends on the width
        if let f = fraction { applyFraction(f, animated: false) }
        updateAnimation()
    }

    /// The layer's frame and outline for the current size and mode (no implicit animation).
    private func rebuildShape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // NOT `fill.frame = bounds`: the frame of a layer with a non-identity transform is undefined (it would bake the old translation into the position).
        fill.bounds = CGRect(origin: .zero, size: bounds.size)
        fill.position = CGPoint(x: bounds.midX, y: bounds.midY)
        fill.path = isIndeterminate ? Self.segmentPath(in: bounds.size) : Self.fillPath(in: bounds.size)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func fractionChanged(from old: Double?) {
        if (old == nil) != (fraction == nil) {
            // Switching between the two looks: new shape, no glide, the slide starts or stops.
            fill.removeAnimation(forKey: Self.slideKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.transform = CATransform3DIdentity
            fill.isHidden = false
            CATransaction.commit()
            rebuildShape()
            if let f = fraction { applyFraction(f, animated: false) }
            updateAnimation()
        } else if let f = fraction {
            applyFraction(f, animated: window != nil)
        }
    }

    private func applyFraction(_ value: Double, animated: Bool) {
        let f = Self.normalized(value) ?? 0
        CATransaction.begin()
        if animated && !reduceMotion {
            CATransaction.setAnimationDuration(Self.glideDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.transform = CATransform3DMakeTranslation(Self.translation(forFraction: f, width: bounds.width), 0, 0)
        CATransaction.commit()
        // At 0 nothing is drawn (the shape's top edge would leave a sliver).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.isHidden = f <= 0
        CATransaction.commit()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let role: BrandRole = secondary ? .blueFill : .tint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.fillColor = role.rgb(dark: dark, increaseContrast: increaseContrastOverride ?? Brand.increaseContrast).nsColor.cgColor
        CATransaction.commit()
    }

    private func updateAnimation() {
        let wants = isIndeterminate && !reduceMotion && window != nil && bounds.width > 1
        if wants, !isSliding {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = bounds.width * CGFloat(Self.travelFraction)
            slide.duration = Self.slideDuration
            slide.autoreverses = true
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slide.isRemovedOnCompletion = false
            fill.add(slide, forKey: Self.slideKey)
        } else if !wants, isSliding {
            fill.removeAnimation(forKey: Self.slideKey)
        }
    }
}

struct SlantedBar: NSViewRepresentable {
    var fraction: Double?
    var secondary = false
    @Environment(\.a11y) private var a11y

    func makeNSView(context: Context) -> SlantedBarLayerView {
        let v = SlantedBarLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 6))
        v.fraction = fraction
        return v
    }

    func updateNSView(_ view: SlantedBarLayerView, context: Context) {
        view.secondary = secondary
        view.reduceMotion = a11y.reduceMotion
        view.increaseContrastOverride = a11y.increaseContrast
        view.fraction = fraction
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SlantedBarLayerView, context: Context) -> CGSize? {
        // Like a Shape: take the offered room, fall back to a small default when none is offered (or an unbounded one).
        func finite(_ v: CGFloat?, _ fallback: CGFloat) -> CGFloat { v.flatMap { $0.isFinite ? $0 : nil } ?? fallback }
        return CGSize(width: finite(proposal.width, 100), height: finite(proposal.height, 6))
    }
}
