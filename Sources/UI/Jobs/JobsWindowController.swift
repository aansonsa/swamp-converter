import SwiftUI
import AppKit
import Combine

/// The Jobs window: Running / Queued / Finished sections of `JobRowView`s (kind icon, name + target, `SlantedProgressBar`, ETA, per-stage line for download + convert jobs), drag to
/// reorder WAITING rows, Cancel everywhere, Pause for encodes, Retry, Remove, a log sheet, and result handling on every finished job (feature J): reveal in Finder, DRAG the result out
/// into any app, Share, Quick Look, copy path, Open (all through `ResultActions` of the actions module). Studio embeds the same row view in its queue panel (`JobRowView`).
///
/// Opened lazily by `show()` (menu bar, Dock menu, notification clicks) and torn down on close, so a closed window costs nothing; its frame is remembered.
@MainActor
final class JobsWindowController: NSObject, NSWindowDelegate {
    static let shared = JobsWindowController()
    static let frameName = "SwampJobsWindow"
    static let defaultSize = NSSize(width: 560, height: 520)
    static let minimumSize = NSSize(width: 460, height: 320)
    /// The Jobs window counts as a real window: Dock icon, menu bar and Command-Tab while it is open, like the other windows of the app.
    static let presenceID = "jobs"

    private var window: NSWindow?
    private var model: JobsListModel?
    private var language: AnyCancellable?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Brings the window to the front, creating it on first use. Looking at the jobs clears the menu bar's unseen-error dot.
    func show() {
        let w = window ?? makeWindow()
        MenuBarProgressModel.shared.markErrorsSeen()
        WindowPresence.shared.present(w, id: Self.presenceID)
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let model = JobsListModel()
        model.start()
        self.model = model
        let controller = NSHostingController(rootView: JobsListView(model: model, runner: model.runner).appRoot())
        controller.sizingOptions = []   // the window keeps the person's size; the content does not resize it
        let w = NSWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = L("Jobs", "Задачи")
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.setContentSize(Self.defaultSize)
        w.contentMinSize = Self.minimumSize
        w.delegate = self
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        language = Loc.shared.$revision.dropFirst().sink { [weak w] _ in w?.title = L("Jobs", "Задачи") }
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        WindowPresence.shared.closed(Self.presenceID)
        let closing = window, closingModel = model
        window = nil
        model = nil
        language = nil
        closingModel?.stop()
        // Release the SwiftUI tree with the window. The window and model stay alive for one more turn (they are still on the call stack).
        closing?.contentViewController = nil
        DispatchQueue.main.async { _ = (closing, closingModel) }
    }
}
