import Foundation
import AppKit
import QuickLookUI

// The two system presenters the actions share: the Share menu (AirDrop, Messages, Mail ...) and the Quick Look panel.

/// One run of the Share menu. A menu needs a view in a window to hang from; when the caller has none (the wheel is already gone), a one-point invisible,
/// non-activating panel is placed at the pointer and closed again the moment sharing ends or the menu is dismissed.
@MainActor
final class ShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private var anchor: NSPanel?
    private var picker: NSSharingServicePicker?
    private static var live: [ShareSession] = []

    init(anchor: NSPanel?) {
        self.anchor = anchor
        super.init()
    }

    static func present(_ items: [URL], relativeTo rect: NSRect, of view: NSView, session: ShareSession) {
        endAll()
        live.append(session)
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = session
        session.picker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    static func presentAtPointer(_ items: [URL], at point: NSPoint) {
        let panel = NSPanel(contentRect: NSRect(x: point.x, y: point.y, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        panel.contentView = content
        panel.orderFrontRegardless()
        present(items, relativeTo: content.bounds, of: content, session: ShareSession(anchor: panel))
    }

    /// Closes every open session (a new Share request replaces the previous one).
    static func endAll() {
        live.forEach { $0.finish() }
        live.removeAll()
    }

    static var activeCount: Int { live.count }

    func finish() {
        anchor?.orderOut(nil)
        anchor?.close()
        anchor = nil
        picker = nil
        ShareSession.live.removeAll { $0 === self }
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish() }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        // Closing the Mail or Messages window without sending is a cancel, not a failure: no warning for that.
        let ns = error as NSError
        if !(ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError) {
            MessageCenter.shared.post(ConversionError.describe(error), severity: .warning, symbol: "exclamationmark.triangle")
        }
        finish()
    }
}

/// The shared Quick Look panel with one data source: the last list of files it was asked to show. The arrow keys move between them (QLPreviewPanel does that
/// itself), Space or Esc closes it.
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    private(set) var urls: [URL] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()       // in front even when macOS declines to activate the menu-bar app
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let panel = QLPreviewPanel.shared()
        guard panel?.dataSource === self else { return }
        panel?.orderOut(nil)
        urls = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}
