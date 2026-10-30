import AppKit

/// NSServices provider (Info.plist `NSServices`): "Convert with Swamp Converter" (files, `public.item`) and "Download with Swamp Converter" (selected text and `public.url`).
/// Verified on this Mac (spec/platform.md 7): a Finder multi-selection arrives in ONE call; LaunchServices launches the app when needed; `NSPerformService` can drive it in tests.
/// Both handlers read the pasteboard, validate, and hand over to `URLRouter`; an unusable selection is reported through the Services `error` pointer (macOS shows it).
@MainActor
final class ServicesProvider: NSObject {
    /// Info.plist: NSMessage = convertFiles. Reads `pboard` file URLs (`.urlReadingFileURLsOnly`) and opens the wheel at the pointer.
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = Self.fileURLs(from: pboard)
        guard !files.isEmpty else {
            error.pointee = L("There are no files to convert in this selection.", "В выделении нет файлов для конвертации.") as NSString
            return
        }
        URLRouter.present(files: files, origin: .service)
    }

    /// Info.plist: NSMessage = downloadLink. Reads selected text and / or `public.url`, extracts links with `LinkParsing.downloadableLinks`, then opens the link wheel at the pointer.
    @objc func downloadLink(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        switch Self.links(from: pboard) {
        case .success(let links): URLRouter.present(links: links, origin: .service)
        case .failure(let reason): error.pointee = reason.message.text as NSString
        }
    }

    // MARK: Pure pasteboard readers (unit-tested with a private pasteboard)

    /// Existing local file URLs on the pasteboard (a Finder multi-selection arrives as several `public.file-url` items).
    nonisolated static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let objects = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<String>()
        return objects.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The downloadable links of the selection: the text first (`LinkParsing.downloadableLinks`), then a `public.url` item. The reason is the first problem found when there is none.
    nonisolated static func links(from pboard: NSPasteboard) -> Result<[LinkItem], LinkRejection> {
        var texts: [String] = []
        if let s = pboard.string(forType: .string) { texts.append(s) }
        if let s = pboard.string(forType: .URL) { texts.append(s) }
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL] {
            texts.append(contentsOf: urls.filter { !$0.isFileURL }.map(\.absoluteString))
        }
        var links: [LinkItem] = []
        var keys = Set<String>()
        for text in texts {
            for link in LinkParsing.downloadableLinks(in: text, source: "selection") where keys.insert(link.canonicalKey).inserted { links.append(link) }
        }
        if !links.isEmpty { return .success(links) }
        for text in texts {
            if case .failure(let reason) = LinkParsing.firstDownloadable(in: text) { return .failure(reason) }
        }
        return .failure(.empty)
    }
}
