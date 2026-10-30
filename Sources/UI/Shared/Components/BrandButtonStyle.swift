import SwiftUI

/// A flat pink call-to-action for the rare place where `.buttonStyle(.glassProminent)` would put white text on the light pink
/// (2.4:1). Label colour is `Brand.onPink` (7.9:1). No gradient, no shadow. Use at most one per window.
/// Keyboard focus draws a 2 pt ring in the tint (a custom style does not get the system ring); Increase Contrast adds a 1 pt outline.
struct BrandProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.a11y) private var a11y

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Brand.onPink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(Brand.pink.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Capsule())
            .overlay { if a11y.increaseContrast { Capsule().strokeBorder(Brand.onPink, lineWidth: 1) } }
            .overlay { if isFocused { Capsule().strokeBorder(Brand.tint, lineWidth: 2).padding(-4) } }
            .contentShape(Capsule())
            .animation(DS.Motion.animation(DS.Motion.hover, reduceMotion: a11y.reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrandProminentButtonStyle {
    static var brandProminent: BrandProminentButtonStyle { BrandProminentButtonStyle() }
}

extension View {
    /// Secondary buttons: neutral glass with a normal label colour. A pink root tint would otherwise turn `.glass` / `.bordered` buttons into pink fills with white text
    /// (and pink text on light backgrounds). RULE: never use `.glassProminent` / `.borderedProminent` with the brand tint; use `.brandProminent` for the one call to action
    /// and `.secondaryButtonLook()` for everything else.
    func secondaryButtonLook() -> some View { buttonStyle(.glass).tint(nil) }
}
