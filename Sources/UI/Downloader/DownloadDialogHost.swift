import SwiftUI
import AppKit

// A tiny host for the two modal questions of the downloader (the first-use notice and the install offer). It shows a SwiftUI view in a titled window, as a sheet on the
// download sheet when that is open, and resumes the caller with the answer. It never polls and holds nothing after the answer: the window and the hosting controller are
// released as soon as the question is answered.

@MainActor
final class DownloadDialogHost: NSObject, NSWindowDelegate {
    /// Test hook: when set, dialogs are answered with this value without opening a window (a self-test must never put a window on the person's screen).
    nonisolated(unsafe) static var autoAnswer: ((_ id: String) -> Bool)?

    private var window: NSWindow?
    private var parent: NSWindow?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var answered = false

    /// Shows `content` and returns what it passes to `finish`. Closing the window counts as "No".
    static func ask<Content: View>(id: String, title: String, size: CGSize, parent: NSWindow?, @ViewBuilder content: @escaping (_ finish: @escaping @MainActor (Bool) -> Void) -> Content) async -> Bool {
        if let auto = autoAnswer { return auto(id) }
        let host = DownloadDialogHost()
        return await host.run(title: title, size: size, parent: parent, content: content)
    }

    private func run<Content: View>(title: String, size: CGSize, parent: NSWindow?, content: @escaping (_ finish: @escaping @MainActor (Bool) -> Void) -> Content) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            continuation = cont
            let view = content { [weak self] answer in self?.finish(answer) }.appRoot()
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            let w = NSWindow(contentViewController: controller)
            w.title = title
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(size)
            w.delegate = self
            window = w
            if let parent, parent.isVisible {
                self.parent = parent
                parent.beginSheet(w, completionHandler: nil)
            } else {
                w.center()
                // The same "opens behind the app you were in" trap the main windows had: a consent or install dialog raised from Control-Option-D has no
                // parent window, so it goes through the shared presenter (activate first, then order front regardless) rather than its own older order.
                WindowPresence.shared.present(w, id: nil)
            }
        }
    }

    private func finish(_ answer: Bool) {
        guard !answered else { return }
        answered = true
        if let w = window {
            if let parent { parent.endSheet(w) }
            w.orderOut(nil)
            w.delegate = nil
            w.contentViewController = nil
        }
        window = nil
        parent = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: answer)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}
