import Foundation
import AppKit

// Building a presentation: which input, which wheel, which content; the two entry points (a drag gesture, `present(_:)`) and the in-wheel switches (wheel, repeat view).

extension WheelController {
    // MARK: Entry points

    /// Opens the wheel for `input` (click mode) at `anchor` (screen coordinates, nil = the mouse location), clamped into the visible frame of the screen under the cursor.
    /// Files -> the file wheels (Convert / Tools / Actions; `wheel` picks the first one); links -> the LINK wheel (download modes + "Choose in Studio...") headed by the page
    /// title and host; both present -> the link wheel when `preferLinks`. Used by the Dock-icon drop, the menu-bar-icon drop, Services, "Wheel for clipboard" and the hotkey.
    func present(_ input: IncomingInput, anchor: NSPoint? = nil, wheel: WheelKind? = nil, preferLinks: Bool = false) {
        guard !input.isEmpty else {
            toast(Self.nothingToConvert, symbol: "tray")
            return
        }
        close()
        var s = WheelSession(mode: .click, input: input)
        s.isLink = input.prefersLinkWheel(preferLinks: preferLinks)
        if s.isLink {
            s.wheel = .link
        } else {
            s.wheel = wheel.flatMap { $0 == .link ? nil : $0 } ?? Self.firstUsefulWheel(for: input.files, builder: contentBuilder())
        }
        open(s, anchor: anchor ?? NSEvent.mouseLocation)
    }

    /// The wheel for a screenshot (or any image) taken from the clipboard.
    func presentClipboard(image item: FileItem, anchor: NSPoint? = nil) {
        close()
        var s = WheelSession(mode: .click, input: IncomingInput(files: [item], origin: .clipboard))
        s.wheel = .convert
        s.clipboardItem = item
        open(s, anchor: anchor ?? NSEvent.mouseLocation)
    }

    /// A drag gesture (modifier tap or shake) while files or a link are being dragged: the wheel opens in drag mode under the cursor.
    func presentDrag(wheel: WheelKind) {
        guard !isPaused else { return }
        close()
        let payload = DragPasteboardReader.read(dragPasteboard())
        var s = WheelSession(mode: .drag, input: payload.previewInput)
        s.input.origin = .wheel
        s.isLink = s.input.files.isEmpty && !s.input.links.isEmpty
        s.wheel = s.isLink ? .link : wheel
        open(s, anchor: NSEvent.mouseLocation)
    }

    /// The first file wheel that has something to offer for `files` (Convert, then Tools, then Actions); Convert when all are empty.
    static func firstUsefulWheel(for files: [FileItem], builder: WheelContentBuilder) -> WheelKind {
        for w in WheelKind.fileWheels where !builder.fileContent(items: files, wheel: w).isEmpty { return w }
        return .convert
    }

    /// Builds the model for `s` and puts it on screen.
    func open(_ s: WheelSession, anchor: NSPoint) {
        let m = makeModel(for: s)
        show(m, session: s, anchor: anchor)
    }

    // MARK: Content

    func makeContent(for s: WheelSession) -> WheelContent {
        let builder = contentBuilder()
        if s.isLink { return builder.linkContent(links: s.input.links, pageTitle: s.input.pageTitle) }
        if let clip = s.clipboardItem { return builder.clipboardContent(item: clip, operationIDs: ClipboardSource.wheelOperationIDs(for: clip)) }
        if s.isRepeat { return builder.repeatContent(last: QuickRun.shared.lastOperation(for: s.input.files), wheel: s.wheel) }
        return builder.fileContent(items: s.input.files, wheel: s.wheel)
    }

    func makeModel(for s: WheelSession) -> WheelModel {
        let settings = AppSettings.shared.data
        let m = WheelModel(content: makeContent(for: s), presentation: s.mode, summary: WheelInputSummary.make(s.input), scale: settings.wheelScale,
                           dwellSeconds: Double(max(settings.wheelDwellMilliseconds, 100)) / 1000)
        m.waitingForItems = s.mode == .drag && s.input.isEmpty
        m.reachableWheels = (s.isLink || s.clipboardItem != nil) ? [] : WheelKind.fileWheels
        m.pasteBackAvailable = s.clipboardItem != nil
        if offscreenForTesting { m.tick = nil }
        m.scheduleDwellCheck = { [weak self, weak m] due in
            MainActor.assumeIsolated {
                guard let self, let m else { return }
                self.dwellWork?.cancel()
                let work = DispatchWorkItem { [weak m] in MainActor.assumeIsolated { _ = m?.checkDwell(now: ProcessInfo.processInfo.systemUptime) } }
                self.dwellWork = work
                let delay = max(due - ProcessInfo.processInfo.systemUptime, 0) + 0.002
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        // Click mode starts with the first sector highlighted (keyboard model); no tick for that.
        if s.mode == .click, !m.sectors.isEmpty {
            let t = m.tick
            m.tick = nil
            m.setHighlight(0)
            m.tick = t
        }
        return m
    }

    // MARK: In-wheel switches

    /// Another file wheel (modifier tap of another key in drag mode, Tab in click mode). Input is kept; link and clipboard wheels do not switch.
    func switchWheel(to wheel: WheelKind) {
        guard let model, !session.isLink, session.clipboardItem == nil, wheel != .link else { return }
        session.wheel = wheel
        session.isRepeat = false
        model.setContent(makeContent(for: session), keepHighlight: false)
        if session.mode == .click, !model.sectors.isEmpty { model.setHighlight(0) }
    }

    /// Tapping the same wheel key again (or R) swaps the ring for the single "repeat last action" sector and back.
    func toggleRepeat() {
        guard let model, !session.isLink, session.clipboardItem == nil else { return }
        session.isRepeat.toggle()
        model.setContent(makeContent(for: session), keepHighlight: false)
        if session.mode == .click, !model.sectors.isEmpty { model.setHighlight(0) }
    }

    /// Tab: the next (or previous) file wheel.
    func cycleWheel(backwards: Bool) {
        let all = WheelKind.fileWheels
        guard let i = all.firstIndex(of: session.wheel) else { return }
        switchWheel(to: all[(i + (backwards ? all.count - 1 : 1)) % all.count])
    }

    /// A drag entered the panel: when the wheel opened before the pasteboard held anything readable, read it now and rebuild the ring.
    func dragEntered(_ info: NSDraggingInfo) {
        guard let model, session.mode == .drag else { return }
        graceWork?.cancel(); graceWork = nil
        guard model.waitingForItems || session.input.isEmpty else { return }
        let payload = DragPasteboardReader.read(info.draggingPasteboard)
        guard !payload.isEmpty else { return }
        var input = payload.previewInput
        input.origin = .wheel
        session.input = input
        session.isLink = input.files.isEmpty && !input.links.isEmpty
        if session.isLink { session.wheel = .link }
        model.summary = WheelInputSummary.make(input)
        model.waitingForItems = false
        model.reachableWheels = session.isLink ? [] : WheelKind.fileWheels
        model.setContent(makeContent(for: session), keepHighlight: true)
    }

    /// The drag moved over the panel: the grace period of a finished drag is off (called at display rate: a nil check only).
    func dragMoved() {
        if graceWork != nil { graceWork?.cancel(); graceWork = nil }
    }
}
