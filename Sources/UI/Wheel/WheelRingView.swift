import SwiftUI
import AppKit

// The wheel ring as SwiftUI (spec/wheel.md 4, 5, 8, 18.2). One `GlassEffectContainer` holds a glass shape per sector plus the hub disc; the labels, the hub text and the
// highlight ring are drawn above it. Everything is cheap vector drawing: a few paths, no blurs, no per-frame allocation (the highlight changes ONE sector view).
//
// Coordinates: the view is `geometry.panelSide` square, the wheel centre is the view centre. `WheelGeometry` works y-up around the centre; `WheelSectorShape` flips it.
// Pointer input is NOT handled here (the AppKit `WheelDropView` above this view hit-tests with `WheelGeometry`), so this view never takes events.

/// The annular sector of `WheelGeometry.sectorPath` as a SwiftUI shape (the glass shape, the highlight ring and the dwell progress share it).
struct WheelSectorShape: Shape {
    var geometry: WheelGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        // y up around the centre  ->  SwiftUI's y down around the rect centre.
        let flip = CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return Path(geometry.sectorPath(index)).applying(flip)
    }
}

/// The open animation shared by the ring: opacity 0 -> 1 and scale 0.9 -> 1 with the design-system spring; only the fade with Reduce Motion; nothing in a snapshot.
struct WheelOpenEffect<Content: View>: View {
    var isStatic: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.a11y) private var a11y
    @State private var shown = false

    var body: some View {
        let visible = shown || isStatic
        content()
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible || a11y.reduceMotion ? 1 : 0.9)
            .onAppear {
                guard !isStatic else { return }
                withAnimation(DS.Motion.animation(DS.Motion.open, reduceMotion: a11y.reduceMotion)) { shown = true }
            }
    }
}

struct WheelRingView: View {
    @ObservedObject var model: WheelModel
    /// VoiceOver "press" on a sector (the AppKit view handles real pointer input).
    var onActivate: (Int) -> Void = { _ in }
    @Environment(\.a11y) private var a11y

    var body: some View {
        let g = model.geometry
        let side = g.panelSide
        WheelOpenEffect(isStatic: model.isStatic) {
            ZStack {
                glassLayer(g, side: side)
                labelLayer(g)
                WheelHubContentView(model: model, geometry: g)
                if model.dropActive { dropGlow(g) }
            }
            .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Swamp Converter wheel", "Колесо Swamp Converter"))
    }

    // MARK: Layers

    private func glassLayer(_ g: WheelGeometry, side: CGFloat) -> some View {
        // Spacing 2 (< the 6 pt gap): neighbouring sectors never fuse into one blob.
        GlassGroup(spacing: 2) {
            ZStack {
                ForEach(Array(model.sectors.enumerated()), id: \.element.id) { i, s in
                    WheelSectorSurface(geometry: g, index: i, highlighted: model.highlight == i, paging: s.isPaging,
                                       dwelling: model.dwelling && model.highlight == i, dwellSeconds: model.dwellSeconds, isStatic: model.isStatic)
                }
                WheelHubSurface(geometry: g, active: model.hubHot)
            }
        }
        .id(model.buildToken)
    }

    private func labelLayer(_ g: WheelGeometry) -> some View {
        ZStack {
            ForEach(Array(model.sectors.enumerated()), id: \.element.id) { i, s in
                WheelSectorLabel(sector: s, index: i, geometry: g, highlighted: model.highlight == i, pageNote: pageNote(for: s),
                                 isStatic: model.isStatic)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.accessibilityLabel(for: i))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onActivate(i) }
            }
        }
        .id(model.buildToken)
    }

    /// "2/3" on the paging sectors: the only page indicator the ring needs.
    private func pageNote(for s: WheelSector) -> String? {
        guard s.isPaging, model.content.pages.count > 1 else { return nil }
        let target = s.role == .more ? model.pageIndex + 2 : model.pageIndex
        return "\(max(target, 1))/\(model.content.pages.count)"
    }

    /// The drop-target glow: a pink ring just outside the disc (a stroke, no blur). Reduce Transparency and Increase Contrast make it thicker.
    private func dropGlow(_ g: WheelGeometry) -> some View {
        Circle()
            .strokeBorder(Brand.pink.opacity(a11y.increaseContrast ? 1 : 0.7), lineWidth: a11y.increaseContrast ? 3 : 2)
            .frame(width: (g.outerRadius + 5) * 2, height: (g.outerRadius + 5) * 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - One sector's surface

/// The glass (or opaque) shape of one sector with the highlight ring, the pop translation and the grow-in animation.
struct WheelSectorSurface: View {
    var geometry: WheelGeometry
    var index: Int
    var highlighted: Bool
    var paging: Bool
    var dwelling: Bool
    var dwellSeconds: TimeInterval
    var isStatic: Bool
    @Environment(\.a11y) private var a11y
    @State private var grown = false

    var body: some View {
        let shape = WheelSectorShape(geometry: geometry, index: index)
        let pop: CGFloat = highlighted && !a11y.reduceMotion && geometry.sectorCount > 1 ? WheelGeometry.popDistance : 0
        let dir = geometry.popDirection(of: index)
        let visible = grown || isStatic
        surface(shape)
            .overlay { if highlighted { shape.stroke(Brand.tint, lineWidth: a11y.increaseContrast ? 3.5 : 2.5) } }
            .overlay { if dwelling && paging { WheelDwellStroke(shape: shape, seconds: dwellSeconds, animated: !a11y.reduceMotion) } }
            .offset(x: dir.width * pop, y: dir.height * pop)
            .scaleEffect(visible || a11y.reduceMotion ? 1 : 0.82)
            .opacity(visible ? 1 : 0)
            .motion(DS.Motion.hover, value: highlighted)
            .onAppear {
                guard !isStatic else { return }
                // Stagger of 14 ms per sector, capped so the last sector of a full ring is in by ~120 ms.
                let delay = a11y.reduceMotion ? 0 : Double(min(index, 8)) * 0.014
                withAnimation(DS.Motion.animation(DS.Motion.open, reduceMotion: a11y.reduceMotion).delay(delay)) { grown = true }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func surface(_ shape: WheelSectorShape) -> some View {
        switch GlassPlan.surface(reduceTransparency: a11y.reduceTransparency) {
        case .glass:
            Color.clear.glassEffect(glass, in: shape)
        case .opaque:
            ZStack {
                shape.fill(DS.Surface.window)
                if highlighted { shape.fill(Brand.pink.opacity(GlassPlan.opaqueTintOpacity)) }
            }
            .overlay { shape.stroke(Color.primary.opacity(a11y.increaseContrast ? 0.6 : 0.18), lineWidth: a11y.increaseContrast ? 1.5 : 0.5) }
        }
    }

    private var glass: Glass {
        var g: Glass = .regular
        if highlighted { g = g.tint(Brand.pink.opacity(GlassPlan.glassTintOpacity)) }
        return g
    }
}

/// The progress of the "More..." dwell: the sector outline draws itself over `seconds` (linear). Without animation it is simply there.
struct WheelDwellStroke: View {
    var shape: WheelSectorShape
    var seconds: TimeInterval
    var animated: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        shape.trim(from: 0, to: animated ? progress : 1)
            .stroke(Brand.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: max(seconds, 0.05))) { progress = 1 }
            }
    }
}

/// The hub disc (cancel zone): a glass circle a few points inside the sectors' inner edge.
struct WheelHubSurface: View {
    var geometry: WheelGeometry
    var active: Bool
    @Environment(\.a11y) private var a11y

    var body: some View {
        let d = max(geometry.hubRadius - 5, 4) * 2
        Group {
            switch GlassPlan.surface(reduceTransparency: a11y.reduceTransparency) {
            case .glass:
                Color.clear.frame(width: d, height: d).glassEffect(.regular, in: Circle())
            case .opaque:
                Circle().fill(DS.Surface.window).frame(width: d, height: d)
                    .overlay { Circle().stroke(Color.primary.opacity(a11y.increaseContrast ? 0.6 : 0.18), lineWidth: a11y.increaseContrast ? 1.5 : 0.5) }
            }
        }
        .accessibilityHidden(true)
    }
}
