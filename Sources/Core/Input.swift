import Foundation

// Inputs are no longer only files: a web link (dragged from a browser, read from the page, pasted, selected as text) is an
// input too. `InputItem` is the sum type the wheel, the Dock icon, the menu-bar icon, Services, the Studio and the CLI pass
// around. Operations still receive `[FileItem]` (file operations) or `[LinkItem]` (download operations): they never see a mix.

/// A web link the user wants to download. Immutable snapshot; `title` is filled when the page title is known (browser tab title,
/// yt-dlp info) and only used for display.
struct LinkItem: Hashable, Identifiable, Sendable {
    let url: URL
    /// Page / video title when known (wheel header, job title). Never used for file names without sanitising.
    var title: String?
    /// Where the link came from ("Safari", "clipboard", "selection") for the toast and for diagnostics.
    var sourceName: String?

    var id: URL { url }
    /// "youtube.com" (lower case, without www. / m.).
    var host: String { LinkParsing.displayHost(of: url) }
    /// Title when known, otherwise the host.
    var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? host }
    /// Stable identity used to drop duplicates (youtu.be/ID and youtube.com/watch?v=ID are the same video).
    var canonicalKey: String { LinkParsing.canonicalKey(of: url) }

    init(url: URL, title: String? = nil, sourceName: String? = nil) {
        self.url = url; self.title = title; self.sourceName = sourceName
    }
}

enum InputItem: Hashable, Identifiable, Sendable {
    case file(FileItem)
    case link(LinkItem)

    var id: String {
        switch self {
        case .file(let f): return "file:" + f.url.path
        case .link(let l): return "link:" + l.canonicalKey
        }
    }
    var file: FileItem? { if case .file(let f) = self { return f } else { return nil } }
    var link: LinkItem? { if case .link(let l) = self { return l } else { return nil } }
    var isLink: Bool { link != nil }
    var displayName: String {
        switch self { case .file(let f): return f.name; case .link(let l): return l.displayTitle }
    }
}

extension Array where Element == InputItem {
    var files: [FileItem] { compactMap(\.file) }
    var links: [LinkItem] { compactMap(\.link) }
}

/// Everything that arrives at the app door in one go: files and/or links, plus where it came from. Produced by the drag
/// detector, the Dock/menu-bar drop handlers, Services, the URL scheme, the hotkey readers and the CLI; consumed by
/// `WheelController.present(_:)` and `QuickRun`.
struct IncomingInput: Sendable {
    var files: [FileItem] = []
    var links: [LinkItem] = []
    var origin: JobOrigin = .wheel
    /// Window title of the page the link came from, shown in the link wheel header together with the host.
    var pageTitle: String? = nil

    init(files: [FileItem] = [], links: [LinkItem] = [], origin: JobOrigin = .wheel, pageTitle: String? = nil) {
        self.files = files; self.links = links; self.origin = origin; self.pageTitle = pageTitle
    }

    var isEmpty: Bool { files.isEmpty && links.isEmpty }
    /// Which wheel family the input belongs to. When both are present the LINK wins only if `preferLinks` is set by the
    /// caller (the hotkey does that when the front app is a browser, see WheelContext).
    func prefersLinkWheel(preferLinks: Bool) -> Bool {
        if files.isEmpty { return !links.isEmpty }
        if links.isEmpty { return false }
        return preferLinks
    }
}

/// Plain-text rendering of `IncomingInput` for tests and `--json` output.
extension IncomingInput: CustomStringConvertible {
    var description: String {
        "IncomingInput(files: \(files.map(\.name)), links: \(links.map(\.url.absoluteString)), origin: \(origin.rawValue))"
    }
}
