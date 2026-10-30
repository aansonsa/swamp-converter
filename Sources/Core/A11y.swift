import SwiftUI
import AppKit

// The four accessibility display options every custom drawing in the app must honour (design bar):
//   Reduce Motion        -> no scale / stagger / pop, opacity changes only (0.12 s fades)
//   Reduce Transparency  -> own fills become opaque; no glass
//   Increase Contrast    -> 1-2 pt separators, stronger highlight outline, labels at 4.5:1
//   Differentiate Without Colour -> never colour alone: add outline / symbol / text
//
// Views read `@Environment(\.a11y)`. The root view of every window gets `.appRoot()` (UI/Shared), which fills the
// environment from the system and re-reads it when the user changes the settings. Snapshots override the values
// through `\.a11yOverride` so every state can be rendered offscreen.

struct A11y: Equatable, Sendable {
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false
    var differentiateWithoutColor = false

    /// Current system values.
    @MainActor static var system: A11y {
        let ws = NSWorkspace.shared
        return A11y(reduceMotion: ws.accessibilityDisplayShouldReduceMotion,
                    reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency,
                    increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast,
                    differentiateWithoutColor: ws.accessibilityDisplayShouldDifferentiateWithoutColor)
    }
}

private struct A11yKey: EnvironmentKey { static let defaultValue = A11y() }
private struct A11yOverrideKey: EnvironmentKey { static let defaultValue: A11y? = nil }

extension EnvironmentValues {
    /// Effective accessibility options (system values unless a snapshot overrides them).
    var a11y: A11y {
        get { self[A11yKey.self] }
        set { self[A11yKey.self] = newValue }
    }
    /// Set by the snapshot harness (and tests) to force a state regardless of the system settings.
    var a11yOverride: A11y? {
        get { self[A11yOverrideKey.self] }
        set { self[A11yOverrideKey.self] = newValue }
    }
}

/// Fills `\.a11y` from the system and keeps it current. Prefer `.appRoot()` from UI/Shared over using this directly.
struct A11yFromSystem: ViewModifier {
    @Environment(\.a11yOverride) private var override: A11y?
    @State private var system = A11y.system

    func body(content: Content) -> some View {
        content
            .environment(\.a11y, override ?? system)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                system = A11y.system
            }
    }
}

extension View {
    func a11yFromSystem() -> some View { modifier(A11yFromSystem()) }
}
