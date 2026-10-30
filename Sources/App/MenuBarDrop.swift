import AppKit

/// What a drag onto the status item or the Dock icon may carry: file URLs, web links (a URL item or text containing http(s) links). Pure pasteboard reading, shared with tests.
enum MenuBarDrop {
    /// File URLs first (a Finder drag), otherwise the http(s) URLs of a URL item or of dragged text. Whether a link is acceptable is decided later by `URLRouter.route`.
    nonisolated static func urls(from pboard: NSPasteboard) -> [URL] {
        let files = ServicesProvider.fileURLs(from: pboard)
        if !files.isEmpty { return files }
        var out: [URL] = []
        var seen = Set<String>()
        func add(_ u: URL) { if let s = u.scheme?.lowercased(), s == "http" || s == "https", seen.insert(u.absoluteString).inserted { out.append(u) } }
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL] { urls.forEach(add) }
        if let text = pboard.string(forType: .string) { LinkParsing.extractURLs(from: text).forEach(add) }
        return out
    }
}

/// A transparent layer on top of the status item button that accepts drops. Mouse events pass straight to the button (so the menu still opens), only the drag destination lives here.
final class MenuBarDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .string])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }

    private var button: NSStatusBarButton? { superview as? NSStatusBarButton }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !MenuBarDrop.urls(from: sender.draggingPasteboard).isEmpty else { return [] }
        button?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { button?.highlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { button?.highlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !MenuBarDrop.urls(from: sender.draggingPasteboard).isEmpty }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let urls = MenuBarDrop.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
