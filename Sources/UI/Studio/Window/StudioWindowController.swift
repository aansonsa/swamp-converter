import SwiftUI
import AppKit
import Combine

/// Opens Studio windows. One window per session; dropping onto an open Studio adds sources instead of opening another. A Dock icon (and Cmd-Tab entry) stays while a Studio window is open
/// (`settings.showDockIconWithStudio`, applied by `WindowPresence`). The frame is remembered in `settings.studio.windowFrame`; whether a Studio was open at quit is kept in the
/// window module's own small state file so the app can bring it back (`restoreIfNeeded`).
@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    static let shared = StudioWindowController()

    /// Everything that differs between the real app and a test or snapshot run.
    struct Options {
        /// Bring the window forward and activate the app.
        var activates = true
        /// Put the "Studio" menu into the main menu while a window is open.
        var installsMenu = true
        /// Tell `WindowPresence` (Dock icon) about the window.
        var reportsPresence = true
        /// Where tests and snapshots park the window so nothing appears on the person's screen.
        var parkOffscreen = false
        var settings: AppSettings = .shared
        /// nil = the shared runner.
        var runner: JobRunner?
    }

    private struct Entry {
        let model: StudioWindowModel
        let window: NSWindow
        let presenceID: String
        var cancellables: Set<AnyCancellable>
    }

    /// Small enough for half of a MacBook screen (macOS tiling makes the window about 730 pt wide): below `StudioWindowContent.sidebarCollapseWidth` the sidebar
    /// folds away by itself and a short centre column scrolls, so nothing is ever cut off.
    static let minimumSize = CGSize(width: 720, height: 520)
    static let defaultSize = CGSize(width: 1240, height: 780)

    private let options: Options
    private var entries: [UUID: Entry] = [:]
    /// Most recently used last.
    private var order: [UUID] = []
    private var frameSaveWork: DispatchWorkItem?
    private var isTerminating = false
    private var terminationObserver: NSObjectProtocol?

    init(options: Options = Options()) {
        self.options = options
        super.init()
        if options.reportsPresence {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willTerminate() }
            }
        }
    }

    deinit { if let o = terminationObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: Queries

    var openSessionCount: Int { entries.count }

    /// The model of the window the person is working in (the key window, else the last one used).
    var frontModel: StudioWindowModel? {
        if let key = NSApp?.keyWindow, let e = entries.values.first(where: { $0.window === key }) { return e.model }
        return order.last.flatMap { entries[$0]?.model }
    }

    var models: [StudioWindowModel] { order.compactMap { entries[$0]?.model } }

    /// True when a Studio window was open when the app last quit.
    var wasOpenAtQuit: Bool { StudioWindowState.load().wasOpenAtQuit }

    func window(for model: StudioWindowModel) -> NSWindow? { entries[model.session.id]?.window }

    // MARK: Open

    /// THE entry point (wheel "Customise...", menu bar "Open Studio...", Dock drop, Settings "Edit in Studio...", queue "Edit Options", links):
    /// `input` empty = an empty Studio with an "Add Files / Paste a link" empty state; `target` pre-selects a target id (schema id) and `operationID` seeds from that wheel sector's quick recipe;
    /// `recipe` loads values + preset. When a Studio window is already open and `reuseOpen` is true, the input is added to it (a recipe always opens a window of its own).
    func show(input: IncomingInput = IncomingInput(), target: String? = nil, operationID: String? = nil, recipe: Recipe? = nil, reuseOpen: Bool = true) {
        let inputs = input.files.map(InputItem.file) + input.links.map(InputItem.link)
        if reuseOpen, recipe == nil, let model = frontModel, model.accepts(inputs) {
            if !inputs.isEmpty { model.ingest(inputs) }
            if let t = target, model.session.targetID != t || operationID != nil { model.session.selectTarget(t, operationID: operationID) }
            else if target == nil, let op = operationID { model.session.selectTarget(OperationRegistry.shared.operation(id: op)?.meta.schemaID ?? op, operationID: op) }
            model.pane = .source
            bringForward(model)
            return
        }
        let session = StudioSession(input: input, targetID: operationID ?? target, recipe: recipe)
        if let t = target, session.targetID != t, recipe == nil { session.selectTarget(t, operationID: operationID) }
        open(session: session)
    }

    /// Opens a window around an existing session (a queue row's "Edit Options", tests, snapshots).
    @discardableResult
    func open(session: StudioSession) -> StudioWindowModel {
        let model = StudioWindowModel(session: session, runner: options.runner, settings: options.settings)
        let window = makeWindow(for: model)
        model.window = window
        var bag = Set<AnyCancellable>()
        Loc.shared.$revision.dropFirst().sink { [weak window] _ in window?.title = Self.windowTitle }.store(in: &bag)
        let presence = "studio-\(session.id.uuidString)"
        entries[session.id] = Entry(model: model, window: window, presenceID: presence, cancellables: bag)
        order.append(session.id)
        if options.reportsPresence { WindowPresence.shared.opened(presence) }
        if options.installsMenu { StudioMenu.shared.install() }
        markOpen(true)
        if options.parkOffscreen {
            window.orderBack(nil)
        } else if options.activates {
            WindowPresence.shared.present(window, id: nil)
        } else {
            window.orderFront(nil)
        }
        return model
    }

    /// Brings a Studio forward when one is open, else opens an empty one (the app's "reopen" and the menu bar's "Open Studio...").
    func restoreIfNeeded() {
        if openSessionCount == 0, wasOpenAtQuit { show() }
    }

    func closeAll() {
        for id in order.reversed() { entries[id]?.window.close() }
    }

    private func bringForward(_ model: StudioWindowModel) {
        guard let w = entries[model.session.id]?.window else { return }
        order.removeAll { $0 == model.session.id }
        order.append(model.session.id)
        if options.parkOffscreen { return }
        if options.activates { WindowPresence.shared.present(w, id: nil) }
        else {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Window

    static var windowTitle: String { L("Studio", "Студия") }

    private func makeWindow(for model: StudioWindowModel) -> NSWindow {
        let size = Self.defaultSize
        var frame = CGRect(origin: .zero, size: size)
        if let restored = StudioFrameStore.restoredFrame(from: options.settings.data.studio.windowFrame, minSize: Self.minimumSize, screens: NSScreen.screens.map(\.visibleFrame)) {
            frame = restored
            // A second window must not sit exactly on top of the first.
            let offset = CGFloat(entries.count) * 24
            frame.origin.x += offset; frame.origin.y -= offset
        }
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = Self.windowTitle
        window.minSize = Self.minimumSize
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = NSHostingController(rootView: StudioRootView(model: model).appRoot())
        if options.parkOffscreen {
            window.setFrame(window.frameRect(forContentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height)), display: false)
        } else if StudioFrameStore.restoredFrame(from: options.settings.data.studio.windowFrame, minSize: Self.minimumSize, screens: NSScreen.screens.map(\.visibleFrame)) != nil {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        window.delegate = self
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = entries.first(where: { $0.value.window === w })?.key, let entry = entries[id] else { return }
        saveFrame(of: w)
        entry.model.session.cancelPreview()
        entry.model.transport.stop()
        w.delegate = nil
        entries[id] = nil
        order.removeAll { $0 == id }
        if options.reportsPresence { WindowPresence.shared.closed(entry.presenceID) }
        if entries.isEmpty {
            if !isTerminating { markOpen(false) }
            if options.installsMenu { StudioMenu.shared.uninstall() }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = entries.first(where: { $0.value.window === w })?.key else { return }
        order.removeAll { $0 == id }
        order.append(id)
    }

    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification.object as? NSWindow) }
    func windowDidMove(_ notification: Notification) { scheduleFrameSave(notification.object as? NSWindow) }

    /// Edit > Undo goes to the session's option history while the focus is not in a text field.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        entries.values.first(where: { $0.window === window }).map { StudioUndoBridge.manager(for: $0.model) }
    }

    // MARK: Persistence

    private func scheduleFrameSave(_ window: NSWindow?) {
        guard let window else { return }
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            MainActor.assumeIsolated { self.saveFrame(of: window) }
        }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveFrame(of window: NSWindow) {
        guard !options.parkOffscreen else { return }
        let text = NSStringFromRect(window.frame)
        options.settings.update { $0.studio.windowFrame = text }
    }

    private func markOpen(_ open: Bool) {
        guard options.reportsPresence else { return }
        var s = StudioWindowState.load()
        guard s.wasOpenAtQuit != open else { return }
        s.wasOpenAtQuit = open
        s.save()
    }

    private func willTerminate() {
        isTerminating = true
        for e in entries.values { saveFrame(of: e.window) }
    }
}
