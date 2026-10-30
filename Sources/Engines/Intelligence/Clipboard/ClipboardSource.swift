import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// E. Clipboard source. Reading the General pasteboard programmatically can raise a consent prompt on macOS 15.4+ (spec/wheel.md 18.4 item 7):
// it is only ever done as the direct result of a user action (hotkey, menu item "Wheel for clipboard"), never in the background, and `.alwaysDeny` shows a hint.

enum ClipboardContent {
    /// Files copied in Finder.
    case files([FileItem])
    /// An image (a screenshot, a copied picture) saved as a PNG in `AppPaths.incomingFolder()`; the file belongs to the user's incoming folder, not to temp.
    case image(FileItem)
    /// One or more downloadable links in copied text.
    case links([LinkItem])
    case empty
    /// macOS refused access to the pasteboard.
    case denied

    /// Calm sentence for the empty / denied cases (toast or wheel hint); nil when there is something to work with.
    var hint: L10n? {
        switch self {
        case .empty: return L10n("The clipboard is empty. Copy a file, a picture or a link first.", "Буфер обмена пуст. Сначала скопируйте файл, изображение или ссылку.")
        case .denied: return L10n("macOS did not allow reading the clipboard. Allow it in System Settings > Privacy & Security > Paste from Other Apps.",
                                  "macOS не разрешила читать буфер обмена. Разрешите это в Системных настройках > Конфиденциальность и безопасность > Вставка из других приложений.")
        default: return nil
        }
    }
}

@MainActor
enum ClipboardSource {
    /// Pasteboard change count -> the PNG already saved for it (a second read of the same clipboard must not litter the folder).
    private static var saved: [String: URL] = [:]
    /// Screenshots this type created; only these may be deleted by `discard`.
    private static var created = Set<URL>()
    private static let maxLinks = 20

    /// Reads the pasteboard once. Priority: file URLs, then image data, then text containing links. Cheap: no polling anywhere (the pasteboard has
    /// no change notification and this app uses no timers).
    static func read(pasteboard: NSPasteboard = .general, incomingFolder: URL = AppPaths.incomingFolder()) -> ClipboardContent {
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny { return .denied }

        // 1. Files copied in Finder (only paths that still exist).
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { return .files(existing.map { FileItem(url: $0) }) }
        }

        // 2. A picture.
        if let item = saveImage(from: pasteboard, into: incomingFolder) { return .image(item) }

        // 3. Links in copied text (or a copied web address).
        var links: [LinkItem] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard LinkParsing.isDownloadable(url), seen.insert(LinkParsing.canonicalKey(of: url)).inserted, links.count < maxLinks else { return }
            links.append(LinkItem(url: url, sourceName: L("Clipboard", "Буфер обмена")))
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL] {
            urls.filter { !$0.isFileURL }.forEach(add)
        }
        if links.isEmpty, let text = pasteboard.string(forType: .string) { LinkParsing.extractURLs(from: text).forEach(add) }
        return links.isEmpty ? .empty : .links(links)
    }

    // MARK: Image

    private static func saveImage(from pasteboard: NSPasteboard, into folder: URL) -> FileItem? {
        let key = "\(pasteboard.name.rawValue)#\(pasteboard.changeCount)"
        if let url = saved[key], FileManager.default.fileExists(atPath: url.path) { return FileItem(url: url) }

        let png: Data?
        if let raw = pasteboard.data(forType: .png), CGImageSourceCreateWithData(raw as CFData, nil) != nil {
            png = raw
        } else {
            let fallbackTypes: [NSPasteboard.PasteboardType] = [.tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
            png = fallbackTypes.lazy.compactMap { pasteboard.data(forType: $0) }.compactMap(pngData(from:)).first
        }
        guard let png else { return nil }

        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let base = L("Screenshot", "Снимок экрана") + " " + stamp.string(from: Date())
        var url = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) (\(n)).png"); n += 1 }
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        saved[key] = url
        created.insert(url)
        if saved.count > 8 { saved = saved.filter { FileManager.default.fileExists(atPath: $0.value.path) } }
        return FileItem(url: url)
    }

    /// Any image data -> PNG bytes (alpha kept). nil when the data is not a picture.
    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Removes a screenshot this type saved when the person closed the wheel without choosing anything (the file would be a stray otherwise).
    /// Files it did not create are never touched.
    @discardableResult
    static func discard(_ item: FileItem) -> Bool {
        guard created.remove(item.url) != nil else { return false }
        saved = saved.filter { $0.value != item.url }
        return (try? FileManager.default.removeItem(at: item.url)) != nil
    }

    // MARK: Wheel

    /// The wheel for a clipboard IMAGE offers: convert (JPG / WebP / HEIC), compress, remove background and "Save as..." (copy to a folder of the person's choice).
    /// Operation ids in wheel order, only those registered and applicable to `item`.
    static func wheelOperationIDs(for item: FileItem, registry: OperationRegistry = .shared) -> [String] {
        let wanted = ["image.to.jpg", "image.to.webp", "image.to.heic", "image.to.png", "image.compress", "image.removebg", "action.copy"]
        return wanted.filter { id in registry.operation(id: id)?.appliesTo([item]) == true }
    }

    // MARK: Paste as file

    /// "Paste as file": puts the RESULT of a job back on the pasteboard as file URLs and, for pictures, their own bytes (no re-encoding), so it can be pasted
    /// into Mail, Messages, Finder and into apps that take pictures. Returns false when there is nothing to put.
    @discardableResult
    static func put(results: [URL], pasteboard: NSPasteboard = .general) -> Bool {
        let files = results.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return false }
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = files.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if let type = imageType(for: url), let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 50_000_000,
               let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }

    private static func imageType(for url: URL) -> NSPasteboard.PasteboardType? {
        switch Formats.key(of: url) {
        case "png": return .png
        case "jpg": return NSPasteboard.PasteboardType("public.jpeg")
        case "tiff": return .tiff
        case "heic": return NSPasteboard.PasteboardType("public.heic")
        case "gif": return NSPasteboard.PasteboardType("com.compuserve.gif")
        default: return nil
        }
    }
}
