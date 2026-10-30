import AppKit

/// Everything that arrives through `application(_:open:)`: file URLs (Dock drop, Open With, `open -a`), `swampconverter://download?...` (URL scheme, bookmarklet, Shortcuts), and
/// http(s) URLs. Pure routing in `route(_:)` (unit-tested) plus the side effects in `handle(_:)`.
///
/// Rules: only existing local files, a validated `swampconverter://download` request, or a downloadable http(s) link ever lead to an action. Paths, flags or any other scheme that
/// arrive inside a URL are never interpreted. A burst of events within 350 ms (a Dock drop of many files, Finder "Open With") is merged into ONE wheel.
@MainActor
enum URLRouter {
    enum Route: Equatable {
        case files([URL])
        case download(DownloadURLScheme.Request)
        case links([URL])
        case rejected(LinkRejection)
        case ignored
    }

    /// Pure: classifies a batch of opened URLs. A batch mixing files and links is split (files win); `swampconverter://` URLs use `DownloadURLScheme.parse` (the first one counts);
    /// plain web links are validated with `LinkParsing`; a link nobody may download becomes `.rejected`; any other scheme (javascript:, ftp:, data:...) is `.ignored`.
    nonisolated static func route(_ urls: [URL]) -> Route {
        var files: [URL] = []
        var seenFiles = Set<String>()
        var schemeURLs: [URL] = []
        var web: [URL] = []
        for url in urls {
            guard let scheme = url.scheme?.lowercased() else { continue }
            switch scheme {
            case "file":
                // A file URL for another machine ("file://server/share") is not a local file.
                if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { continue }
                let clean = (url as NSURL).filePathURL ?? url
                if seenFiles.insert(clean.standardizedFileURL.path).inserted { files.append(clean) }
            case DownloadURLScheme.scheme: schemeURLs.append(url)
            case "http", "https": web.append(url)
            default: continue
            }
        }
        if !files.isEmpty { return .files(files) }
        if let first = schemeURLs.first {
            switch DownloadURLScheme.parse(first) {
            case .success(let request): return .download(request)
            case .failure(let reason): return .rejected(reason)
            }
        }
        guard !web.isEmpty else { return .ignored }
        var valid: [URL] = []
        var keys = Set<String>()
        var firstFailure: LinkRejection?
        for url in web {
            switch LinkParsing.validate(url.absoluteString) {
            case .success(let normalized): if keys.insert(LinkParsing.canonicalKey(of: normalized)).inserted { valid.append(normalized) }
            case .failure(let reason): if firstFailure == nil { firstFailure = reason }
            }
        }
        if !valid.isEmpty { return .links(valid) }
        return .rejected(firstFailure ?? .malformed)
    }

    // MARK: Side effects

    /// The effects of a route, replaceable in tests (nothing in the real wheel or Studio is touched).
    struct Sinks {
        var presentFiles: (IncomingInput, NSPoint?) -> Void
        var openStudio: (IncomingInput) -> Void
        var presentLinks: (IncomingInput, NSPoint?) -> Void
        var download: (DownloadURLScheme.Request, JobOrigin) -> Void
        var toast: (String) -> Void
        var optionHeld: () -> Bool

        @MainActor static var live: Sinks {
            Sinks(
                presentFiles: { input, anchor in WheelController.shared.present(input, anchor: anchor) },
                openStudio: { input in StudioWindowController.shared.show(input: input) },
                presentLinks: { input, anchor in WheelController.shared.present(input, anchor: anchor, preferLinks: true) },
                download: { request, origin in
                    Task { @MainActor in
                        // A rejected request was already announced by the download-ui hook; only a hard failure needs a word here.
                        if case .failed(let message) = await DownloadService.shared.handle(scheme: request, origin: origin) {
                            ToastCenter.shared.show(message, symbol: "exclamationmark.triangle", severity: .error)
                        }
                    }
                },
                toast: { ToastCenter.shared.show($0, symbol: "exclamationmark.triangle", severity: .warning) },
                optionHeld: { NSEvent.modifierFlags.contains(.option) })
        }
    }

    static var sinks: Sinks = .live

    private static let batcher = URLBatcher { urls, origin, anchor in perform(route(urls), origin: origin, anchor: anchor) }

    /// Coalesces calls within 350 ms, then performs the route: files -> the wheel at the pointer (Studio when Option is held); scheme -> `DownloadService.shared.handle(scheme:)`;
    /// links -> the link wheel; rejected -> a toast with the reason; anything else is dropped.
    static func handle(_ urls: [URL], origin: JobOrigin = .dock, anchor: NSPoint? = nil) { batcher.add(urls, origin: origin, anchor: anchor) }

    /// Performs a route now (no coalescing).
    static func perform(_ route: Route, origin: JobOrigin, anchor: NSPoint?) {
        switch route {
        case .files(let urls): present(files: urls, origin: origin, anchor: anchor)
        case .download(let request): sinks.download(request, origin == .dock ? .urlScheme : origin)
        case .links(let urls): present(links: urls.map { LinkItem(url: $0, title: nil, sourceName: nil) }, origin: origin, anchor: anchor)
        case .rejected(let reason): sinks.toast(reason.message.text)
        case .ignored: break
        }
    }

    /// Files that exist -> `FileItem`s -> the wheel (or Studio). Missing files are skipped; if none is left the person is told.
    static func present(files urls: [URL], origin: JobOrigin, anchor: NSPoint? = nil, forceStudio: Bool = false) {
        let fm = FileManager.default
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            if !urls.isEmpty { sinks.toast(L("These files are no longer there.", "Этих файлов больше нет.")) }
            return
        }
        let input = IncomingInput(files: existing.map { FileItem(url: $0) }, origin: origin)
        if forceStudio || sinks.optionHeld() { sinks.openStudio(input) } else { sinks.presentFiles(input, anchor) }
    }

    /// Links -> the link wheel (Studio when Option is held).
    static func present(links: [LinkItem], origin: JobOrigin, anchor: NSPoint? = nil) {
        guard !links.isEmpty else { return }
        let input = IncomingInput(links: links, origin: origin)
        if sinks.optionHeld() { sinks.openStudio(input) } else { sinks.presentLinks(input, anchor) }
    }
}

/// Merges bursts of open events: the batch is delivered once no new event arrived for `quiet` (350 ms), or `maxWait` after the first one. One-shot task per burst; nothing runs at idle.
@MainActor
final class URLBatcher {
    private var urls: [URL] = []
    private var origin: JobOrigin = .dock
    private var anchor: NSPoint?
    private var task: Task<Void, Never>?
    private var firstAt: ContinuousClock.Instant?
    private let quiet: Duration
    private let maxWait: Duration
    private let deliver: ([URL], JobOrigin, NSPoint?) -> Void

    init(quiet: Duration = .milliseconds(350), maxWait: Duration = .milliseconds(1500), deliver: @escaping ([URL], JobOrigin, NSPoint?) -> Void) {
        self.quiet = quiet; self.maxWait = maxWait; self.deliver = deliver
    }

    /// True while a burst is waiting to be delivered (nothing else is ever scheduled).
    var hasPendingWork: Bool { task != nil }

    func add(_ new: [URL], origin: JobOrigin, anchor: NSPoint?) {
        guard !new.isEmpty else { return }
        urls.append(contentsOf: new)
        self.origin = origin
        if anchor != nil { self.anchor = anchor }
        let now = ContinuousClock.now
        let first = firstAt ?? now
        firstAt = first
        task?.cancel()
        let wait = min(quiet, max(.zero, maxWait - (now - first)))
        task = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        let batch = urls, o = origin, a = anchor
        urls = []; anchor = nil; firstAt = nil; task = nil
        guard !batch.isEmpty else { return }
        deliver(batch, o, a)
    }
}
