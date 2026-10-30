import SwiftUI

/// The one glass surface of the control layer (wheel disc, floating HUD cards, shelf, toast). Content views never sit on glass.
/// With Reduce Transparency it becomes an opaque system fill with a hairline separator (a tint survives as a ring and a wash); with Increase Contrast the outline is stronger.
/// The decisions live in `GlassPlan` / `glassSurface` (UI/Shared/DesignSystem/GlassSurface.swift).
struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat
    var padding: CGFloat
    /// Optional tint (hover / drop target glow). Pass `Brand.pink` only for the active state; nil = plain glass.
    var tint: Color?
    @ViewBuilder var content: () -> Content

    init(cornerRadius: CGFloat = DS.Radius.panel, padding: CGFloat = DS.Space.lg, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius; self.padding = padding; self.tint = tint; self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .glassSurface(cornerRadius: cornerRadius, tint: tint)
    }
}
