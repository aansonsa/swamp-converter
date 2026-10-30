import Foundation
import AppKit
import UniformTypeIdentifiers

/// Finished-job conveniences (feature J): used by the Jobs UI rows / cards, notification buttons and the menu-bar "recent results" items. The Actions wheel's
/// own sectors (Reveal, Open with, Quick Look, Share, Copy path) call the same functions, so a result and a dropped file behave identically.
@MainActor
enum ResultActions {
    enum PathStyle: String, Sendable, CaseIterable {
        /// `/Users/me/My File.png`
        case posix
        /// `'/Users/me/My File.png'`, safe to paste into a shell (a quote inside the name is written `'\''`).
        case quoted
        /// `file:///Users/me/My%20File.png`
        case fileURL
        /// `~/My File.png` (paths outside the home folder stay absolute).
        case tilde

        var title: L10n {
            switch self {
            case .posix: return L10n("Plain path", "Обычный путь")
            case .quoted: return L10n("In quotes (for the shell)", "В кавычках (для оболочки)")
            case .fileURL: return L10n("file:// address", "Адрес file://")
            case .tilde: return L10n("Starting with ~", "Начиная с ~")
            }
        }
    }

    // MARK: Finder, open, preview

    /// Selects the files in Finder (`activateFileViewerSelecting`). Files that no longer exist are left out; when none is left the person is told.
    static func reveal(_ urls: [URL]) {
        let present = existing(urls)
        guard !present.isEmpty else { return tellMissing(urls) }
        ActionsSystem.current.revealInFinder(present)
    }

    /// Opens with the default app, or with `app` when given.
    static func open(_ urls: [URL], with app: URL? = nil) {
        let present = existing(urls)
        guard !present.isEmpty else { return tellMissing(urls) }
        if let app { ActionsSystem.current.openWithApp(present, app) } else { ActionsSystem.current.openWithDefaultApp(present) }
    }

    /// Quick Look panel for the files (`QLPreviewPanel`); the arrow keys move between them, Space closes it.
    static func quickLook(_ urls: [URL]) {
        let present = existing(urls)
        guard !present.isEmpty else { return tellMissing(urls) }
        QuickLookCoordinator.shared.show(present)
    }

    // MARK: Sharing

    /// The Share menu (AirDrop, Messages, Mail ...) anchored at `anchor` in `view`. Without a view in a window the menu opens at the pointer, from a one-point
    /// invisible window that lives exactly as long as the sharing does.
    static func share(_ urls: [URL], from view: NSView?, anchor: NSRect) {
        let items = shareable(urls)
        guard !items.isEmpty else { return tellMissing(urls) }
        if let view, view.window != nil {
            ShareSession.present(items, relativeTo: anchor, of: view, session: ShareSession(anchor: nil))
        } else {
            ShareSession.presentAtPointer(items, at: ActionsSystem.current.mouseLocation())
        }
    }

    /// Files and folders that exist (AirDrop takes folders too).
    static func shareable(_ urls: [URL]) -> [URL] { existing(urls) }

    // MARK: Pasteboard

    /// Copies the FILES to the pasteboard (paste into Finder / Mail / Messages) and optionally their paths as text.
    static func copyFiles(_ urls: [URL], alsoPaths: Bool = false, pasteboard: NSPasteboard = .general) {
        let present = existing(urls)
        guard !present.isEmpty else { return tellMissing(urls) }
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = present.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if alsoPaths, index == 0 { item.setString(format(present, style: .posix), forType: .string) }
            return item
        }
        if !pasteboard.writeObjects(items) {
            MessageCenter.shared.post(clipboardBusyMessage, severity: .warning, symbol: "exclamationmark.triangle")
        }
    }

    /// Puts the paths on the pasteboard as text, one per line. Returns false after five failed attempts (the pasteboard can be busy for a moment).
    @discardableResult
    static func copyPaths(_ urls: [URL], style: PathStyle = .posix, pasteboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty else { return false }
        let ok = ActionPasteboard.writeText(format(urls, style: style), pasteboard: pasteboard)
        if !ok { MessageCenter.shared.post(clipboardBusyMessage, severity: .warning, symbol: "exclamationmark.triangle") }
        return ok
    }

    /// "Paste as file": the results go back on the pasteboard as files (and, for pictures, their own bytes), so a clipboard screenshot that was converted can be
    /// pasted straight into Mail, Messages or Finder. Same code as the Intelligence module's clipboard source.
    @discardableResult
    static func pasteAsFile(_ urls: [URL], pasteboard: NSPasteboard = .general) -> Bool {
        let ok = ClipboardSource.put(results: urls, pasteboard: pasteboard)
        if !ok { tellMissing(urls) }
        return ok
    }

    // MARK: Open With

    /// Apps able to open the file for the "Open With" submenu (names + icons), default app first, the rest in alphabetical order.
    static func openWithApps(for url: URL) -> [(name: String, url: URL)] {
        let ws = NSWorkspace.shared
        let preferred = ws.urlForApplication(toOpen: url)
        var seen = Set<String>()
        var result: [(name: String, url: URL)] = []
        func add(_ app: URL) {
            guard seen.insert(app.standardizedFileURL.path).inserted else { return }
            result.append((appName(app), app))
        }
        if let preferred { add(preferred) }
        for app in ws.urlsForApplications(toOpen: url).sorted(by: { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }) { add(app) }
        return result
    }

    /// Apps that can open ALL the files, default of the first file first.
    static func openWithApps(forAll urls: [URL]) -> [(name: String, url: URL)] {
        guard let first = urls.first else { return [] }
        let others = urls.dropFirst().map { Set(openWithApps(for: $0).map { $0.url.standardizedFileURL.path }) }
        return openWithApps(for: first).filter { app in others.allSatisfy { $0.contains(app.url.standardizedFileURL.path) } }
    }

    static func appName(_ app: URL) -> String {
        var name = FileManager.default.displayName(atPath: app.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }

    // MARK: Drag

    /// A drag item provider for dragging a result out of the Jobs window into any app. It hands over a COPY of the file (a file representation, no file URL), so the
    /// receiving app can never move the result away.
    static func dragItem(for url: URL) -> NSItemProvider {
        guard FileManager.default.fileExists(atPath: url.path), let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    // MARK: Formatting

    static func format(_ urls: [URL], style: PathStyle, home: String = NSHomeDirectory()) -> String {
        urls.map { formatOne($0, style: style, home: home) }.joined(separator: "\n")
    }

    static func formatOne(_ url: URL, style: PathStyle, home: String = NSHomeDirectory()) -> String {
        let path = url.path
        switch style {
        case .posix: return path
        case .quoted: return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .fileURL: return URL(fileURLWithPath: path).absoluteString
        case .tilde:
            let h = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
            if path == h { return "~" }
            return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
        }
    }

    // MARK: Messages

    static func existing(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            var st = stat()
            return lstat(url.path, &st) == 0 && seen.insert(url.path).inserted
        }
    }

    private static func tellMissing(_ urls: [URL]) {
        let text = urls.count > 1
            ? L("These files are no longer where they were.", "Этих файлов больше нет на прежнем месте.")
            : L("The file is no longer where it was.", "Файла больше нет на прежнем месте.")
        MessageCenter.shared.post(text, severity: .warning, symbol: "questionmark.folder")
    }

    static func cannotOpenMessage(_ url: URL) -> String {
        L("No app could open “\(url.lastPathComponent)”.", "Ни одна программа не смогла открыть «\(url.lastPathComponent)».")
    }

    static var clipboardBusyMessage: String {
        L("The clipboard is busy. Try again in a moment.", "Буфер обмена занят. Попробуйте ещё раз через мгновение.")
    }
}

/// Writes text to the pasteboard with the retry the original needed on Windows (the clipboard can be held by another app for a few milliseconds).
enum ActionPasteboard {
    /// Up to `attempts` tries `delay` seconds apart. `write` is injectable for tests; the default writes to `pasteboard` and reads the text back to make sure it
    /// really landed.
    @discardableResult
    static func writeText(_ text: String, attempts: Int = 5, delay: TimeInterval = 0.05, pasteboard: NSPasteboard = .general,
                          write: ((String) -> Bool)? = nil) -> Bool {
        let perform = write ?? { value in
            pasteboard.clearContents()
            return pasteboard.setString(value, forType: .string) && pasteboard.string(forType: .string) == value
        }
        for attempt in 0..<max(attempts, 1) {
            if perform(text) { return true }
            if attempt < attempts - 1, delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        return false
    }
}
