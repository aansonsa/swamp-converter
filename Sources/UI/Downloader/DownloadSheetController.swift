import SwiftUI
import AppKit
import Combine

/// The link sheet: one small window ("Download from Link"). Opened by the menu bar ("Download from Link…"), Studio's "Paste link" (Cmd-L), the wheel's "Choose in Studio..." for links.
/// Single instance: opening it again focuses it (a link passed in replaces the field). Built on first `show`, released on close (a closed sheet costs nothing, and a fetch still
/// running is cancelled with it; a download that already started goes on in the job runner).
///
/// `show(link:prefillFromClipboard:)` keeps the placeholder's signature. With `link` the sheet fills the field and fetches the information at once (the person asked for that link).
/// With `prefillFromClipboard` it looks at the clipboard ONCE and offers a link there as a banner: it never fetches on its own.
@MainActor
final class DownloadSheetController: NSObject, NSWindowDelegate {
    static let shared = DownloadSheetController()

    /// Everything that differs between the real app and a test run.
    struct Options {
        var activates = true
        var reportsPresence = true
        /// Tests park the window far away so nothing appears on the person's screen.
        var parkOffscreen = false
        /// nil = the live service.
        var dependencies: DownloadSheetModel.Dependencies?
    }

    static let presenceID = "download-sheet"

    private let options: Options
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()
    /// The model of the open sheet (tests read it).
    private(set) var model: DownloadSheetModel?

    init(options: Options = Options()) {
        self.options = options
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var currentWindow: NSWindow? { window }

    func show(link: LinkItem? = nil, prefillFromClipboard: Bool = true) {
        let m: DownloadSheetModel
        let fresh = window == nil
        if let existing = model, window != nil { m = existing } else {
            m = DownloadSheetModel(deps: options.dependencies)
            model = m
        }
        if fresh { makeWindow(for: m) }
        if let link {
            if m.phase != .started { m.text = link.url.absoluteString }
            else { m.reset(); m.text = link.url.absoluteString }
            m.dismissClipboardBanner()
            m.fetch()
        } else if prefillFromClipboard, m.phase == .empty, m.text.isEmpty {
            m.loadClipboardBanner()
        }
        guard let w = window else { return }
        if !options.parkOffscreen, options.activates {
            WindowPresence.shared.present(w, id: options.reportsPresence ? Self.presenceID : nil)
        } else {
            w.orderFront(nil)
            if fresh, options.reportsPresence { WindowPresence.shared.opened(Self.presenceID) }
        }
    }

    func close() { window?.close() }

    private func makeWindow(for model: DownloadSheetModel) {
        let root = DownloadSheetContent(model: model, onClose: { [weak self] in self?.close() }).appRoot()
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let w = NSWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = L("Download from Link", "Скачать по ссылке")
        w.isReleasedWhenClosed = false
        w.setContentSize(DownloadSheetContent.size)
        w.contentMinSize = NSSize(width: DownloadSheetContent.size.width, height: 480)
        w.delegate = self
        if options.parkOffscreen { w.setFrameOrigin(NSPoint(x: -4000, y: -4000)) } else { w.center() }
        window = w
        Loc.shared.$revision.dropFirst().sink { [weak self] _ in self?.window?.title = L("Download from Link", "Скачать по ссылке") }.store(in: &bag)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancelFetch()
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
        model = nil
        bag.removeAll()
        if options.reportsPresence { WindowPresence.shared.closed(Self.presenceID) }
    }
}
