import SwiftUI

/// The modifier EVERY root view of every window, panel and popover gets:
///   brand tint  +  accessibility environment (Reduce Motion / Transparency, Increase Contrast)  +  live language switching.
/// `ContentView().appRoot()`
struct AppRoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(BrandContrastSync())
            .brandTint()
            .a11yFromSystem()
            .localizedRoot()
    }
}

/// Keeps `Brand.contrastOverride` equal to the effective Increase Contrast value of the view tree (the system flag in the app, the forced
/// value in a snapshot variant), so the dynamic brand inks and the view-driven outlines always agree.
struct BrandContrastSync: ViewModifier {
    @Environment(\.a11y) private var a11y
    func body(content: Content) -> some View {
        Brand.contrastOverride = a11y.increaseContrast
        // NOT just `return content`: SwiftUI never evaluates the body of a modifier that returns its content untouched (verified by the
        // "shared/.appRoot()" self-test), so the line above would silently never run. A real (if neutral) modifier keeps the body alive.
        return content.opacity(1)
    }
}

extension View {
    func appRoot() -> some View { modifier(AppRoot()) }
}
