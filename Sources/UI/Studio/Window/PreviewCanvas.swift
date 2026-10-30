import SwiftUI
import AppKit

// The picture area of the preview: the original and the result in one frame with a draggable divider, zoom to 100% with panning, a loupe for artefacts.
// Overlays (crop handles, safe areas) are drawn by the caller on top, positioned by the picture's displayed rect.

/// Clips a layer to the left `fraction` of `rect` (the "before" half of the comparison).
struct DividerClip: Shape {
    var rect: CGRect
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    func path(in bounds: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height))
    }
}

struct PreviewCanvas<Overlay: View>: View {
    var before: CGImage?
    var after: CGImage?
    var isWorking: Bool
    @Binding var divider: Double
    @Binding var zoom: PreviewZoom
    var loupeOn: Bool
    /// Video previews step frames with the arrow keys, so the divider keeps to the mouse there.
    var arrowKeysMoveDivider = true
    @ViewBuilder var overlay: (CGRect) -> Overlay

    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var hover: CGPoint?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.a11y) private var a11y
    @FocusState private var focused: Bool

    private var imagePixels: CGSize? {
        guard let img = after ?? before else { return nil }
        return CGSize(width: img.width, height: img.height)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = displayedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let after {
                    picture(after, rect)
                    if let before { picture(before, rect).clipShape(DividerClip(rect: rect, fraction: divider)) }
                } else if let before {
                    picture(before, rect)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if before != nil, after != nil {
                    dividerHandle(rect)
                    cornerLabel(L("Before", "До"), at: CGPoint(x: rect.minX + DS.Space.sm, y: rect.minY + DS.Space.sm), leading: true, visible: divider > 0.12)
                    cornerLabel(L("After", "После"), at: CGPoint(x: rect.maxX - DS.Space.sm, y: rect.minY + DS.Space.sm), leading: false, visible: divider < 0.88)
                }
                overlay(rect)
                if loupeOn { loupe(rect: rect) }
                if isWorking {
                    ProgressView().controlSize(.small).padding(DS.Space.sm)
                        .background(.regularMaterial, in: Capsule())
                        .padding(DS.Space.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityLabel(Text(L("Updating the preview", "Обновление просмотра")))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(drag(in: rect, container: geo.size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): if loupeOn { hover = p }
                case .ended: hover = nil
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { guard arrowKeysMoveDivider else { return .ignored }; divider = PreviewMath.nudged(divider, by: -0.02); return .handled }
            .onKeyPress(.rightArrow) { guard arrowKeysMoveDivider else { return .ignored }; divider = PreviewMath.nudged(divider, by: 0.02); return .handled }
            .clipped()
        }
        .background(Color.primary.opacity(0.04))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Preview", "Просмотр")))
        .accessibilityValue(before != nil && after != nil ? Text(L("Divider at \(Int(divider * 100)) percent", "Разделитель на \(Int(divider * 100)) процентах")) : Text(""))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: divider = PreviewMath.nudged(divider, by: 0.1)
            case .decrement: divider = PreviewMath.nudged(divider, by: -0.1)
            @unknown default: break
            }
        }
        .onChange(of: zoom) { _, _ in pan = .zero; panStart = .zero }
    }

    // MARK: Geometry

    private func displayedRect(in container: CGSize) -> CGRect {
        guard let px = imagePixels else { return CGRect(origin: .zero, size: container) }
        switch zoom {
        case .fit: return PreviewMath.fitRect(image: px, in: container)
        case .actual: return PreviewMath.actualRect(image: px, in: container, backingScale: displayScale, pan: pan)
        }
    }

    private func picture(_ image: CGImage, _ rect: CGRect) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(zoom == .actual ? .none : .high)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: Divider

    private func dividerHandle(_ rect: CGRect) -> some View {
        let x = rect.minX + rect.width * divider
        return ZStack {
            Rectangle().fill(.white.opacity(0.9)).frame(width: a11y.increaseContrast ? 3 : 2, height: rect.height)
                .shadow(color: .black.opacity(0.35), radius: 1)
            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(a11y.increaseContrast ? 0.6 : 0.15), lineWidth: 1) }
        }
        .position(x: x, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cornerLabel(_ text: String, at p: CGPoint, leading: Bool, visible: Bool) -> some View {
        Text(text).font(DS.Typo.caption.weight(.semibold))
            .padding(.horizontal, DS.Space.sm).padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
            .position(x: p.x + (leading ? 24 : -24), y: p.y + 10)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func drag(in rect: CGRect, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                focused = true
                switch zoom {
                case .fit:
                    divider = PreviewMath.dividerFraction(x: v.location.x, minX: rect.minX, width: rect.width)
                case .actual:
                    let moved = CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height)
                    if let px = imagePixels {
                        let shown = CGSize(width: px.width / displayScale, height: px.height / displayScale)
                        pan = PreviewMath.clampedPan(moved, displayed: shown, container: container)
                    }
                }
            }
            .onEnded { _ in panStart = pan }
    }

    // MARK: Loupe

    /// A fixed HUD at the bottom left: the area under the pointer at 4x, original beside result.
    @ViewBuilder private func loupe(rect: CGRect) -> some View {
        if let hover, rect.contains(hover), let img = after ?? before, rect.width > 0 {
            let u = (hover.x - rect.minX) / rect.width, v = (hover.y - rect.minY) / rect.height
            HStack(spacing: DS.Space.xs) {
                loupeTile(before, u: u, v: v)
                if after != nil { loupeTile(after, u: u, v: v) }
            }
            .padding(DS.Space.xs)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .id(img.width)
        }
    }

    private func loupeTile(_ image: CGImage?, u: Double, v: Double) -> some View {
        let side: CGFloat = 40
        return Group {
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                let r = PreviewMath.loupeRect(center: CGPoint(x: u * size.width, y: v * size.height), side: side, image: size)
                if let crop = image.cropping(to: r) {
                    Image(decorative: crop, scale: 1).resizable().interpolation(.none).frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
            }
        }
    }
}

// MARK: - Overlays

/// Crop handles: the cut-away area is dimmed, the four edges are draggable. The result is committed once, when the drag ends.
struct CropOverlay: View {
    var rect: CGRect
    @Binding var insets: PreviewMath.CropInsets
    var sourcePixels: CGSize
    var onCommit: (PreviewMath.CropInsets) -> Void
    @Environment(\.a11y) private var a11y

    var body: some View {
        let kept = CGRect(x: rect.minX + rect.width * insets.left, y: rect.minY + rect.height * insets.top,
                          width: rect.width * (1 - insets.left - insets.right), height: rect.height * (1 - insets.top - insets.bottom))
        ZStack {
            Path { p in p.addRect(rect); p.addRect(kept) }
                .fill(.black.opacity(0.4), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Rectangle().strokeBorder(Brand.pink, lineWidth: a11y.increaseContrast ? 2.5 : 1.5).frame(width: kept.width, height: kept.height).position(x: kept.midX, y: kept.midY)
                .allowsHitTesting(false)
            handle(.left, at: CGPoint(x: kept.minX, y: kept.midY), vertical: true)
            handle(.right, at: CGPoint(x: kept.maxX, y: kept.midY), vertical: true)
            handle(.top, at: CGPoint(x: kept.midX, y: kept.minY), vertical: false)
            handle(.bottom, at: CGPoint(x: kept.midX, y: kept.maxY), vertical: false)
            Text(sizeText).font(DS.Typo.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, DS.Space.sm).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .position(x: kept.midX, y: max(kept.minY + 16, rect.minY + 16))
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.space)
    }

    private var sizeText: String {
        let px = PreviewMath.cropPixels(insets, source: sourcePixels)
        return "\(Int(sourcePixels.width) - px.left - px.right) \u{00D7} \(Int(sourcePixels.height) - px.top - px.bottom)"
    }

    private func handle(_ edge: PreviewMath.CropEdge, at point: CGPoint, vertical: Bool) -> some View {
        Capsule().fill(.white)
            .overlay { Capsule().strokeBorder(Brand.pink, lineWidth: 1.5) }
            .frame(width: vertical ? 6 : 30, height: vertical ? 30 : 6)
            .shadow(color: .black.opacity(0.3), radius: 1)
            .padding(10)
            .contentShape(Rectangle())
            .position(point)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { v in insets = PreviewMath.moved(insets, edge: edge, to: fraction(edge, v.location)) }
                .onEnded { v in
                    let i = PreviewMath.moved(insets, edge: edge, to: fraction(edge, v.location))
                    insets = i
                    onCommit(i)
                })
            .accessibilityLabel(Text(label(edge)))
    }

    static let space = "studio.crop"

    private func fraction(_ edge: PreviewMath.CropEdge, _ p: CGPoint) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        switch edge {
        case .left: return Double((p.x - rect.minX) / rect.width)
        case .right: return Double(1 - (p.x - rect.minX) / rect.width)
        case .top: return Double((p.y - rect.minY) / rect.height)
        case .bottom: return Double(1 - (p.y - rect.minY) / rect.height)
        }
    }

    private func label(_ e: PreviewMath.CropEdge) -> String {
        switch e {
        case .left: return L("Crop left edge", "Левый край обрезки")
        case .right: return L("Crop right edge", "Правый край обрезки")
        case .top: return L("Crop top edge", "Верхний край обрезки")
        case .bottom: return L("Crop bottom edge", "Нижний край обрезки")
        }
    }
}

/// The zones of a vertical video that an app's own interface covers, drawn as a quiet dashed frame with its name.
struct SafeAreaOverlay: View {
    var rect: CGRect
    var area: PreviewMath.SafeArea

    var body: some View {
        let safe = PreviewMath.safeRect(area, in: rect)
        ZStack {
            Path { p in p.addRect(rect); p.addRect(safe) }
                .fill(.black.opacity(0.18), style: FillStyle(eoFill: true))
            Rectangle().strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(width: safe.width, height: safe.height).position(x: safe.midX, y: safe.midY)
            Text(area.name.text).font(DS.Typo.caption).padding(.horizontal, DS.Space.sm).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule()).position(x: safe.midX, y: safe.maxY - 14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
