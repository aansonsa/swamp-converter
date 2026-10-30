import AppKit
import SwiftUI

// The wheel's window (spec/wheel.md 3, 18.1; spec/platform.md 6.1). A borderless, transparent, non-activating panel that floats above everything (full-screen apps and every
// Space included) and never takes the focus away from the app the person is dragging out of. Drag mode: it can never become key, so a drag never steals the keyboard.
// Click mode (hotkey, menu bar, Dock, Services, clipboard): it may become key (arrows, digits, Return, Esc) WITHOUT activating the app.
//
// The pattern (NSPanel with .nonactivatingPanel, hidesOnDeactivate off, no animation, order-front-regardless) follows Maccy's FloatingPanel (MIT, p0deje/Maccy); no code was
// copied: Maccy's panel is a titled, resizable popup with its own persistence, this one is a fixed, borderless, click-through-free disc.

@MainActor
final class WheelPanel: NSPanel {
    /// Click mode only: lets the panel take the key window status for the keyboard model.
    var allowsKey = false
    /// Called when the panel loses key status (click mode closes the wheel).
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 408, height: 408), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isMovable = false
        isExcludedFromWindowsMenu = true
    }

    /// AppKit would pull a frame that sticks out of the screen (the transparent pad may protrude) back in; the placement maths already keeps the DISC inside.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// A hosting view that never takes a click: pointer input belongs to the AppKit drop view above the hosted SwiftUI ring, which hit-tests with `WheelGeometry`.
final class WheelPassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
