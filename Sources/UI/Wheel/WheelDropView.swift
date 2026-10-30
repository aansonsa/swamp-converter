import AppKit
import SwiftUI

// The wheel panel's content view (spec/platform.md 6.1, spec/wheel.md 9, 18.1): an AppKit drop destination that hosts the SwiftUI ring as a click-through subview. SwiftUI's
// `.onDrop` has no per-sector geometry, so every drag position is converted to wheel coordinates here and handed to `WheelModel` (highlight, haptic tick, dwell); the same view
// takes the mouse in click mode. All decisions live in `WheelModel` and `WheelController`; this view only translates events.

/// What a drag may do over a zone, and which effect to answer with. Pure, unit-tested.
enum WheelDropPolicy {
    /// Never `.move` (the source would delete the original): copy if the source allows it, else generic, else link.
    static func safeEffect(sourceMask: NSDragOperation) -> NSDragOperation {
        if sourceMask.contains(.copy) { return .copy }
        if sourceMask.contains(.generic) { return .generic }
        if sourceMask.contains(.link) { return .link }
        return []
    }

    /// Over an enabled sector or the "Customise..." capsule the drop is accepted; over the hub, outside the disc, on a dimmed sector or on "More..." the cursor shows "not allowed".
    static func operation(zone: WheelModel.Zone, sectors: [WheelSector], sourceMask: NSDragOperation) -> NSDragOperation {
        switch zone {
        case .sector(let i):
            guard sectors.indices.contains(i), sectors[i].enabled, !sectors[i].isPaging else { return [] }
            return safeEffect(sourceMask: sourceMask)
        case .capsule:
            return safeEffect(sourceMask: sourceMask)
        case .hub, .outside:
            return []
        }
    }
}

@MainActor
final class WheelDropView: NSView {
    weak var controller: WheelController?
    /// The model of the wheel on screen (nil while hidden).
    var model: WheelModel?

    private let host = WheelPassThroughHostingView(rootView: AnyView(EmptyView()))
    private var trackingArea: NSTrackingArea?
    /// The sector the button went down on (click mode: a click is down + up on the same zone).
    private var pressedZone: WheelModel.Zone?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 408, height: 408))
        registerForDraggedTypes(DragPasteboardReader.draggedTypes)
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("WheelDropView is created in code") }

    /// Replaces the hosted ring (a new presentation); `nil` empties it so a hidden panel holds no view tree.
    func setRoot(_ view: AnyView?) { host.rootView = view ?? AnyView(EmptyView()) }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    /// Wheel coordinates (relative to the centre, y up) of a point in window coordinates.
    func wheelPoint(fromWindow p: NSPoint) -> CGPoint {
        let local = convert(p, from: nil)
        return CGPoint(x: local.x - bounds.midX, y: local.y - bounds.midY)
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered(sender)
        return track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let model else { return [] }
        let p = wheelPoint(fromWindow: sender.draggingLocation)
        controller?.dragMoved()
        model.pointerMoved(to: p)
        model.setDropActive(model.geometry.containsDisc(p))
        model.setCustomiseHeld(NSEvent.modifierFlags.contains(.command) && AppSettings.shared.data.gestures.commandOpensStudio)
        return WheelDropPolicy.operation(zone: model.zone(at: p), sectors: model.sectors, sourceMask: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model?.pointerLeft()
        model?.setDropActive(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let model else { return false }
        let p = wheelPoint(fromWindow: sender.draggingLocation)
        return !WheelDropPolicy.operation(zone: model.zone(at: p), sectors: model.sectors, sourceMask: sender.draggingSourceOperationMask).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        return controller.performDrop(sender, at: wheelPoint(fromWindow: sender.draggingLocation))
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        model?.setDropActive(false)
        controller?.dragFinished()
    }

    // MARK: Pointer (click mode)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model, model.presentation == .click else { return }
        model.pointerMoved(to: wheelPoint(fromWindow: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        guard let model, model.presentation == .click else { return }
        model.pointerLeft()
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        pressedZone = model.zone(at: wheelPoint(fromWindow: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, let down = pressedZone else { return }
        pressedZone = nil
        let p = wheelPoint(fromWindow: event.locationInWindow)
        // A click is down and up on the same zone; dragging off a sector before releasing cancels the click.
        guard model.zone(at: p) == down else { return }
        controller?.click(at: p, customise: event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command))
    }

    override func rightMouseDown(with event: NSEvent) { controller?.close() }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { false }
}
