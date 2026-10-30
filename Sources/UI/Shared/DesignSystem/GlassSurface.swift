import SwiftUI
import AppKit

// ONE place that knows how to draw Liquid Glass and what to draw instead when the person asked for less transparency.
//
// Glass APIs, verified against the macOS 26.5 SDK (SwiftUICore.swiftinterface, AppKit/NSGlassEffectView.h) and compiled with -target arm64-apple-macos26.0:
//   SwiftUI   View.glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())
//             Glass.regular / .clear / .identity,  Glass.tint(_ color: Color?),  Glass.interactive(_ isEnabled: Bool = true)
//             GlassEffectContainer(spacing: CGFloat? = nil) { ... }   merges neighbouring glass within `spacing`
//             View.glassEffectID(_:in:) / glassEffectUnion(id:namespace:) / glassEffectTransition(_:)   (wheel sector morphing; GlassEffectTransition is
//             .matchedGeometry / .materialize / .identity). A union applies the shape you gave to the COMBINED frame: give unioned neighbours a Capsule,
//             not a Circle (see GlassUnionDemo in the snapshots). Verified in the MacOSX26.5.sdk SwiftUICore.swiftinterface and exercised by the
//             self-test "shared/glass morphing APIs ...".
//             ButtonStyle .glass / .glassProminent  (never with the pink tint: see BrandButtonStyle)
//   AppKit    NSGlassEffectView { contentView, cornerRadius (uniform), tintColor, style .regular | .clear }
//             NSGlassEffectContainerView { contentView, spacing }
// The deployment target is macOS 26, so no availability checks are needed. The self-test "shared/glass APIs exist and behave" touches each of them at run time.
//
// Rules the design system keeps:
//   * Glass lives on the control layer only (wheel disc, floating cards, toasts, toolbars). Content stays on system backgrounds.
//   * Reduce Transparency: no glass. An opaque system fill with a hairline; a tint (drop target, hover) survives as a ring and a wash.
//   * Increase Contrast: a 1 pt outline on glass, 1.5 pt on the opaque fallback.
//   * Neighbouring glass shapes share a `GlassGroup` whose spacing is <= the gap between them, or they fuse into one blob.

/// The pure decisions behind glass: unit-tested, used by the SwiftUI modifier and the AppKit view alike.
enum GlassPlan {
    enum Surface: Equatable, Sendable { case glass, opaque }

    static func surface(reduceTransparency: Bool) -> Surface { reduceTransparency ? .opaque : .glass }

    /// Width of the outline drawn inside the shape: none on plain glass, a hairline on the opaque fallback, stronger with Increase Contrast.
    static func outlineWidth(surface: Surface, increaseContrast: Bool) -> CGFloat {
        switch (surface, increaseContrast) {
        case (.glass, false): return 0
        case (.glass, true): return 1
        case (.opaque, false): return 0.5
        case (.opaque, true): return 1.5
        }
    }

    /// Opacity of the tint over glass (a hint, not a coat of paint).
    static let glassTintOpacity = 0.35
    /// Opacity of the tint wash on the opaque fallback.
    static let opaqueTintOpacity = 0.16
    /// Width of the tint ring on the opaque fallback (the cue that survives Reduce Transparency).
    static let opaqueTintRing: CGFloat = 1.5
}

struct GlassSurfaceModifier<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.a11y) private var a11y

    func body(content: Content) -> some View {
        let surface = GlassPlan.surface(reduceTransparency: a11y.reduceTransparency)
        let outline = GlassPlan.outlineWidth(surface: surface, increaseContrast: a11y.increaseContrast)
        switch surface {
        case .glass:
            content
                .glassEffect(glass, in: shape)
                .overlay { if outline > 0 { inside(shape, Color.primary.opacity(0.5), outline) } }
        case .opaque:
            content
                .background {
                    // One layer, opaque first and the tint wash ON TOP of it (two stacked `.background`s would paint the wash behind the opaque fill).
                    ZStack {
                        shape.fill(DS.Surface.window)
                        if let tint { shape.fill(tint.opacity(GlassPlan.opaqueTintOpacity)) }
                    }
                }
                .overlay { inside(shape, Color.primary.opacity(a11y.increaseContrast ? 0.6 : 0.18), outline) }
                // The ring is the cue that survives Reduce Transparency, so it is a graphic that must read (>= 3:1): the brand TINT (deepened in light mode), not the pale glass tint.
                .overlay { if tint != nil { inside(shape, Brand.tint, GlassPlan.opaqueTintRing) } }
        }
    }

    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint.opacity(GlassPlan.glassTintOpacity)) }
        if interactive { g = g.interactive() }
        return g
    }

    /// A stroke that stays inside the shape (a centred stroke clipped to the shape: half the requested width... so ask for twice the width).
    private func inside(_ shape: S, _ color: Color, _ width: CGFloat) -> some View {
        shape.stroke(color, lineWidth: width * 2).clipShape(shape)
    }
}

extension View {
    /// A glass surface of any shape, with the Reduce Transparency / Increase Contrast fallbacks built in.
    /// `tint`: the active state only (hover, drop target), `Brand.pink` or nil. `interactive`: glass that reacts to the pointer (buttons).
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurfaceModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// A glass rounded rectangle (continuous corners).
    func glassSurface(cornerRadius: CGFloat = DS.Radius.panel, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive)
    }
}

/// Neighbouring glass shapes belong in one group: they are rendered together (cheaper) and may merge. Keep `spacing` <= the gap between the shapes
/// unless the merge is the point (the wheel's sector gap is 6 pt, so its group uses 6 or less).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content
    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) { self.spacing = spacing; self.content = content }
    var body: some View { GlassEffectContainer(spacing: spacing) { content() } }
}

// MARK: - AppKit

/// Watches the accessibility display options without polling (the workspace posts a notification when the person changes them).
@MainActor
final class AccessibilityObserver {
    private var token: NSObjectProtocol?
    init(_ onChange: @escaping @MainActor () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }
    deinit { if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}

/// The opaque layer under the content of the Reduce Transparency fallback. `NSVisualEffectView` is made opaque by the system when the person turns Reduce
/// Transparency on, but not when the app itself asks for the opaque look (a setting, a snapshot), so the fallback paints its own fill: the window background,
/// with the tint as a wash on top. The same recipe `glassSurface` uses for SwiftUI shapes. The outline lives in `OutlineOverlayView`.
@MainActor
final class OpaqueBackingFill: NSView {
    var cornerRadius: CGFloat = DS.Radius.panel { didSet { needsDisplay = true } }
    var tintColor: NSColor? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("OpaqueBackingFill is created in code") }

    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.windowBackgroundColor
            var fill = base
            if let tint = tintColor?.usingColorSpace(.sRGB), let b = base.usingColorSpace(.sRGB),
               let mixed = b.blended(withFraction: CGFloat(GlassPlan.opaqueTintOpacity), of: tint) { fill = mixed }
            layer.backgroundColor = fill.cgColor
        }
    }
}

/// A transparent view that only draws an outline, ABOVE everything else in its parent (a layer border on the parent itself would sit under the glass view's
/// own rendering). It never takes a click.
@MainActor
final class OutlineOverlayView: NSView {
    var cornerRadius: CGFloat = DS.Radius.panel { didSet { needsDisplay = true } }
    var width: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("OutlineOverlayView is created in code") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = width
        effectiveAppearance.performAsCurrentDrawingAppearance { layer.borderColor = width > 0 ? color.cgColor : nil }
    }
}

/// A rounded backdrop for AppKit panels (the wheel disc, the shelf, status-item popovers): `NSGlassEffectView` normally; with Reduce Transparency an
/// `NSVisualEffectView` over an opaque fill (see `OpaqueBackingFill`), so the look is the same whether the system or the app asked for it.
/// `contentView` survives a switch between the two. The outline follows `GlassPlan.outlineWidth`: none on plain glass, 1 pt with Increase Contrast, a hairline
/// on the opaque fallback, and the tint as a 1.5 pt ring there.
///
///     let disc = GlassBackingView(cornerRadius: 180, reduceTransparency: A11y.system.reduceTransparency)
///     disc.contentView = hostingView
///     disc.followSystemAccessibility()      // optional: re-evaluates when the person flips Reduce Transparency / Increase Contrast
@MainActor
final class GlassBackingView: NSView {
    enum Backing: Equatable { case glass, visualEffect }

    private(set) var backing: Backing
    private var backingView: NSView
    private var fill: OpaqueBackingFill?
    private let outline = OutlineOverlayView()
    private var accessibilityObserver: AccessibilityObserver?

    var cornerRadius: CGFloat { didSet { applyProperties() } }
    var tintColor: NSColor? { didSet { applyProperties() } }
    /// `.clear` is the see-through glass for HUDs over video; everything else uses `.regular`.
    var usesClearGlass = false { didSet { applyProperties() } }
    var reduceTransparency: Bool { didSet { if oldValue != reduceTransparency { rebuild() } } }
    var increaseContrast = false { didSet { if oldValue != increaseContrast { applyProperties() } } }
    var contentView: NSView? {
        didSet {
            guard oldValue !== contentView else { return }
            if backing == .visualEffect { oldValue?.removeFromSuperview() }
            place(contentView)
        }
    }

    init(cornerRadius: CGFloat = DS.Radius.panel, tintColor: NSColor? = nil, reduceTransparency: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.reduceTransparency = reduceTransparency
        let b: Backing = GlassPlan.surface(reduceTransparency: reduceTransparency) == .glass ? .glass : .visualEffect
        self.backing = b
        let made = Self.makeBacking(b)
        self.backingView = made.view
        self.fill = made.fill
        super.init(frame: .zero)
        embed(backingView)
        applyProperties()
    }

    required init?(coder: NSCoder) { fatalError("GlassBackingView is created in code") }

    /// Keeps `reduceTransparency` and `increaseContrast` equal to the system settings from now on (event-driven, no timer).
    func followSystemAccessibility() {
        apply(A11y.system)
        accessibilityObserver = AccessibilityObserver { [weak self] in self?.apply(A11y.system) }
    }

    private func apply(_ a11y: A11y) {
        increaseContrast = a11y.increaseContrast
        reduceTransparency = a11y.reduceTransparency
    }

    /// The outline drawn around the surface in front of the person (the pure rule lives in `GlassPlan`; the tint ring wins on the opaque fallback).
    var outlineWidth: CGFloat {
        switch backing {
        case .glass: return GlassPlan.outlineWidth(surface: .glass, increaseContrast: increaseContrast)
        case .visualEffect: return tintColor != nil ? GlassPlan.opaqueTintRing : GlassPlan.outlineWidth(surface: .opaque, increaseContrast: increaseContrast)
        }
    }

    private var outlineColor: NSColor {
        switch backing {
        case .glass: return NSColor.labelColor.withAlphaComponent(0.5)
        case .visualEffect: return tintColor != nil ? Brand.tintNSColor : (increaseContrast ? NSColor.labelColor.withAlphaComponent(0.6) : NSColor.separatorColor)
        }
    }

    private static func makeBacking(_ b: Backing) -> (view: NSView, fill: OpaqueBackingFill?) {
        switch b {
        case .glass:
            return (NSGlassEffectView(), nil)
        case .visualEffect:
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            let fill = OpaqueBackingFill()
            fill.frame = v.bounds
            fill.autoresizingMask = [.width, .height]
            v.addSubview(fill)
            return (v, fill)
        }
    }

    /// The backing goes in at the bottom, the outline overlay stays on top of everything.
    private func embed(_ v: NSView) {
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v, positioned: .below, relativeTo: outline.superview == nil ? nil : outline)
        if outline.superview == nil {
            outline.frame = bounds
            outline.autoresizingMask = [.width, .height]
            addSubview(outline)
        }
    }

    private func rebuild() {
        let content = contentView
        content?.removeFromSuperview()
        backingView.removeFromSuperview()
        backing = GlassPlan.surface(reduceTransparency: reduceTransparency) == .glass ? .glass : .visualEffect
        let made = Self.makeBacking(backing)
        backingView = made.view
        fill = made.fill
        embed(backingView)
        applyProperties()
        place(content)
    }

    private func applyProperties() {
        switch backing {
        case .glass:
            guard let glass = backingView as? NSGlassEffectView else { return }
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor.map { $0.withAlphaComponent($0.alphaComponent * CGFloat(GlassPlan.glassTintOpacity)) }
            glass.style = usesClearGlass ? .clear : .regular
        case .visualEffect:
            guard let effect = backingView as? NSVisualEffectView, let layer = effect.layer else { return }
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            fill?.cornerRadius = cornerRadius
            fill?.tintColor = tintColor
        }
        outline.cornerRadius = cornerRadius
        outline.width = outlineWidth
        outline.color = outlineColor
    }

    private func place(_ content: NSView?) {
        switch backing {
        case .glass:
            (backingView as? NSGlassEffectView)?.contentView = content
        case .visualEffect:
            guard let content else { return }
            content.removeFromSuperview()
            content.frame = backingView.bounds
            content.autoresizingMask = [.width, .height]
            backingView.addSubview(content)
        }
    }

    /// The outline overlay, for tests.
    var outlineView: OutlineOverlayView { outline }
}

/// `GlassBackingView` as a SwiftUI backdrop for one uniformly rounded shape (a disc: `cornerRadius = diameter / 2`). Honours the environment's Reduce Transparency
/// and Increase Contrast. For anything that is not a single rounded shape use `glassSurface(in:)`.
struct GlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat = DS.Radius.panel
    var tint: Color?
    var clear = false
    @Environment(\.a11y) private var a11y

    func makeNSView(context: Context) -> GlassBackingView { GlassBackingView(cornerRadius: cornerRadius, reduceTransparency: a11y.reduceTransparency) }

    func updateNSView(_ view: GlassBackingView, context: Context) {
        view.increaseContrast = a11y.increaseContrast
        view.reduceTransparency = a11y.reduceTransparency
        view.cornerRadius = cornerRadius
        view.tintColor = tint.map { NSColor($0) }
        view.usesClearGlass = clear
    }
}
