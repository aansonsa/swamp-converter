import SwiftUI
import AppKit

/// A thin progress ring drawn by Core Animation: two `CAShapeLayer`s. It costs nothing between updates (no timers, no SwiftUI animation loop):
/// a determinate value sets `strokeEnd` (the render server interpolates a 0.25 s linear glide), an indeterminate ring is one repeating rotation that
/// also runs in the render server and is removed as soon as the view leaves its window. Reduce Motion: no glide, no spin (a static arc).
///
/// Used for the menu-bar status item (pink only while jobs run: add this view to `statusItem.button` at 18 x 18 pt) and, through `ProgressRing`, in windows.
/// The ring is `Brand.tint` (pure pink in dark mode, the deepened pink in light mode, >= 3:1 on both); an error turns it into a full ring in the error ink.
@MainActor
final class ProgressRingLayerView: NSView {
    /// 0...1, or nil for indeterminate. NaN counts as 0, values outside the range are clamped.
    var progress: Double? { didSet { if progress != oldValue { applyProgress() } } }
    var lineWidth: CGFloat = 2 { didSet { needsLayout = true } }
    var showsTrack = true { didSet { updateColors() } }
    var isError = false { didSet { updateColors(); applyProgress() } }
    var reduceMotion = false { didSet { applyProgress() } }
    /// Set by the SwiftUI wrapper; plain AppKit users (the status item) leave it nil and get the system value.
    var increaseContrastOverride: Bool? { didSet { if increaseContrastOverride != oldValue { updateColors() } } }

    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    static let spinKey = "swp.spin"
    /// Length of the indeterminate arc (fraction of the circle).
    static let indeterminateArc = 0.28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, ring] {
            l.fillColor = nil
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        ring.strokeEnd = 0
        updateColors()
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("ProgressRingLayerView is created in code") }

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { SharedStrings.progress.text }
    override func accessibilityValue() -> Any? {
        if isError { return StatusTone.error.spokenName.text }
        guard let v = Self.normalized(progress) else { return SharedStrings.inProgress.text }
        return Loc.percent(Int((v * 100).rounded()))
    }

    /// The value actually drawn: nil stays nil, NaN becomes 0, the rest is clamped to 0...1.
    static func normalized(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value.isNaN { return 0 }
        return min(max(value, 0), 1)
    }

    /// `strokeEnd` for the current state (an error is a full ring, indeterminate a short arc).
    var strokeEnd: Double {
        if isError { return 1 }
        guard let v = Self.normalized(progress) else { return Self.indeterminateArc }
        return v
    }

    var isSpinning: Bool { ring.animation(forKey: Self.spinKey) != nil }

    override func layout() {
        super.layout()
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        // From 12 o'clock, clockwise (AppKit layers are y-up).
        let path = CGMutablePath()
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [track, ring] { l.frame = bounds; l.path = path; l.lineWidth = lineWidth }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ic = increaseContrastOverride ?? Brand.increaseContrast
        let color = isError ? StatusTone.error.rgb(dark: dark, increaseContrast: ic) : BrandRole.tint.rgb(dark: dark, increaseContrast: ic)
        ring.strokeColor = color.nsColor.cgColor
        track.strokeColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(ic ? 0.35 : 0.18).cgColor
        track.isHidden = !showsTrack
    }

    private func applyProgress() {
        CATransaction.begin()
        if reduceMotion { CATransaction.setDisableActions(true) } else { CATransaction.setAnimationDuration(0.25); CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear)) }
        ring.strokeEnd = CGFloat(strokeEnd)
        CATransaction.commit()
        updateSpin()
    }

    private func updateSpin() {
        let wantsSpin = Self.normalized(progress) == nil && !isError && !reduceMotion && window != nil
        if wantsSpin, !isSpinning {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.0
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ring.add(spin, forKey: Self.spinKey)
        } else if !wantsSpin, isSpinning {
            ring.removeAnimation(forKey: Self.spinKey)
        }
    }
}

/// `ProgressRingLayerView` for SwiftUI. `value == nil` is indeterminate. The ring is a graphic (the state is also in the accessibility value): give it
/// a label next to it when it stands alone.
struct ProgressRing: NSViewRepresentable {
    var value: Double?
    var size: CGFloat = 16
    var lineWidth: CGFloat?
    var isError = false
    var showsTrack = true
    @Environment(\.a11y) private var a11y

    init(value: Double?, size: CGFloat = 16, lineWidth: CGFloat? = nil, isError: Bool = false, showsTrack: Bool = true) {
        self.value = value; self.size = size; self.lineWidth = lineWidth; self.isError = isError; self.showsTrack = showsTrack
    }

    func makeNSView(context: Context) -> ProgressRingLayerView { ProgressRingLayerView(frame: NSRect(x: 0, y: 0, width: size, height: size)) }

    func updateNSView(_ view: ProgressRingLayerView, context: Context) {
        view.lineWidth = lineWidth ?? min(max((size / 8).rounded(.up), 1.5), 4)
        view.showsTrack = showsTrack
        view.isError = isError
        view.reduceMotion = a11y.reduceMotion
        view.increaseContrastOverride = a11y.increaseContrast
        view.progress = value
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProgressRingLayerView, context: Context) -> CGSize? { CGSize(width: size, height: size) }
}
