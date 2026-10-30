import SwiftUI
import AppKit

// The panel under toasts and the HUD cards: borderless, transparent, never key, never main, never activates the app, visible on every Space and over full-screen apps.
// (The flags are the well-known recipe for a window that must not take focus; Maccy's FloatingPanel, MIT, uses a similar set. Nothing was copied: its panel is a key-able search
// popup tied to that app's settings and state, ours is a small status card that never takes the keyboard.)

final class JobsFloatingPanel: NSPanel {
    init(contentSize: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that reports the pointer entering and leaving, even while the app is inactive (a toast or card is hovered without activating anything).
/// SwiftUI's own `onHover` follows the key-window rules, which a non-activating panel never meets.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the floating cards go. Pure geometry (tested); the screen is the one under the pointer.
enum FloatingPlacement {
    /// Bottom centre of `visible`, `inset` above its bottom edge.
    static func bottomCenter(in visible: NSRect, size: NSSize, inset: CGFloat) -> NSPoint {
        NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + inset)
    }

    /// Top right of `visible` (just under the menu bar), `inset` from the edges. The origin is the lower-left corner AppKit wants.
    static func topRight(in visible: NSRect, size: NSSize, inset: CGFloat) -> NSPoint {
        NSPoint(x: visible.maxX - size.width - inset, y: visible.maxY - size.height - inset)
    }

    /// The screen that contains `point`, else the main one, else the first.
    @MainActor
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
