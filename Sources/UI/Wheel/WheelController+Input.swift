import Foundation
import AppKit

// What the person does to an open wheel: a drop (drag mode), a click or keys (click mode). Every path ends in `perform(_:)` with a `WheelAction` decided by `WheelModel`.

/// The keyboard model of click mode (spec/wheel.md 7.2) as a pure mapping, so the table can be unit-tested without events.
enum WheelKeyCommand: Equatable {
    case close, previous, next, activate, tab(backwards: Bool), repeatView, togglePasteBack, customise, digit(Int), none

    static func command(keyCode: UInt16, characters: String?, shift: Bool) -> WheelKeyCommand {
        switch keyCode {
        case 53: return .close                          // Esc
        case 123, 126: return .previous                 // left, up
        case 124, 125: return .next                     // right, down
        case 36, 76, 49: return .activate               // Return, keypad Enter, Space
        case 48: return .tab(backwards: shift)
        default: break
        }
        guard let c = characters?.lowercased(), c.count == 1, let ch = c.first else { return .none }
        if let d = ch.wholeNumberValue, (1...9).contains(d), ch.isASCII { return .digit(d) }
        switch ch {
        case "r": return .repeatView
        case "p": return .togglePasteBack
        case "e": return .customise
        default: return .none
        }
    }
}

extension WheelController {
    // MARK: Click mode

    /// Local monitor for click mode: the keyboard model and the Option / Command state. Returns true when the event was consumed.
    func handleLocal(_ event: NSEvent) -> Bool {
        guard isVisible, session.mode == .click, let model else { return false }
        if event.type == .flagsChanged {
            model.setCustomiseHeld(event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command))
            return false
        }
        if event.modifierFlags.contains(.command), event.keyCode != 53 { return false }   // Cmd-Q and friends stay with the system
        let command = WheelKeyCommand.command(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, shift: event.modifierFlags.contains(.shift))
        apply(command, customiseHeld: event.modifierFlags.contains(.option))
        return true                                                                      // no beep for keys the wheel does not use
    }

    func apply(_ command: WheelKeyCommand, customiseHeld: Bool = false) {
        guard let model else { return }
        switch command {
        case .close: close()
        case .previous: model.move(by: -1)
        case .next: model.move(by: 1)
        case .activate:
            if let s = model.highlightedSector { perform(model.decide(sector: s, customise: customiseHeld || model.customiseHeld)) }
        case .tab(let backwards):
            if model.content.hasMore {
                let n = model.content.pages.count
                model.setPage((model.pageIndex + (backwards ? n - 1 : 1)) % n, highlightFirst: true)
            } else {
                cycleWheel(backwards: backwards)
            }
        case .repeatView: toggleRepeat()
        case .togglePasteBack: if model.pasteBackAvailable { model.pasteBack.toggle() }
        case .customise:
            if let s = model.highlightedSector { perform(model.decide(sector: s, customise: true)) }
        case .digit(let d):
            if let s = model.sector(forDigit: d) { perform(model.decide(sector: s, customise: customiseHeld || model.customiseHeld)) }
        case .none: break
        }
    }

    /// A click at `point` (wheel coordinates) in click mode: a sector runs, "More..." pages, the capsule customises, the hub and the outside close.
    func click(at point: CGPoint, customise: Bool) {
        guard let model, session.mode == .click else { return }
        perform(model.decide(at: point, customise: customise || model.customiseHeld))
    }

    // MARK: Drag mode

    /// The drop. Everything that only exists after the drop (promised files, picture bytes) is materialised NOW, while the drag session is alive; the work itself runs after.
    func performDrop(_ info: NSDraggingInfo, at point: CGPoint) -> Bool {
        guard let model, session.mode == .drag else { return false }
        graceWork?.cancel(); graceWork = nil
        let age = ProcessInfo.processInfo.systemUptime - model.openedAt
        let action = model.decide(at: point, customise: model.customiseHeld)
        switch action {
        case .cancel, .switchPage:
            return false                                                    // the files slide back; draggingEnded closes the wheel
        case .run, .customise, .customiseLast:
            if age < Self.openGuard { return false }                       // a wheel that has just popped up under the cursor never fires
            let payload = DragPasteboardReader.read(info.draggingPasteboard)
            let pending = DragPasteboardReader.beginMaterialising(payload, into: AppPaths.incomingFolder(custom: AppSettings.shared.data.incomingFolder))
            let context = makeRunContext(model: model)
            session.consumed = true
            Task { await self.execute(action, context: context, input: await pending.wait()) }
            DispatchQueue.main.async { [weak self] in self?.close() }
            return true
        }
    }

    /// The drag ended over the panel (or after it was entered): close. Idempotent.
    func dragFinished() { close() }

    // MARK: Decisions

    /// Carries out a decision for the items the wheel already holds (click mode, VoiceOver, keyboard).
    func perform(_ action: WheelAction) {
        guard let model else { return }
        switch action {
        case .cancel:
            close()
        case .switchPage(let page):
            model.setPage(page, highlightFirst: session.mode == .click)
        case .run, .customise, .customiseLast:
            let context = makeRunContext(model: model)
            let input = session.input
            session.consumed = true
            close()
            Task { await self.execute(action, context: context, input: input) }
        }
    }
}
