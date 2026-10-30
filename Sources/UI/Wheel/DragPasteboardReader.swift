import Foundation
import AppKit
import UniformTypeIdentifiers

// What is being dragged, read from a drag pasteboard (the global one while the drag is running, or `draggingPasteboard` inside the drop).
// Order of discovery (spec/wheel.md 10): real files, promised files (Mail, Photos, Safari), a raw image, a web link. Nothing is fetched from the network.
//
// The drag pasteboard is never cleared, so stale content is always present: callers compare `changeCount` against the value at mouse-down
// (see DragSession) and read only after a NEW drag session has started. Reading `.drag` needs no consent (macOS 15.4+ asks only for `.general`).

/// A file that does not exist yet: the sender promised it and delivers it into the incoming folder when the drop happens.
struct PromisedFile {
    let receiver: NSFilePromiseReceiver
    /// Names the sender announced (used for the sector list before delivery).
    let names: [String]
}

struct DragPayload {
    /// Real files and folders already on disk.
    var files: [FileItem] = []
    var promised: [PromisedFile] = []
    /// Raw image bytes (a picture dragged out of a web page or a document) and the Uniform Type they came as.
    var imageData: Data?
    var imageType: UTType?
    var links: [LinkItem] = []
    /// A web page title that travelled with the link (`public.url-name`).
    var linkTitle: String?
    var changeCount: Int = 0

    var isEmpty: Bool { files.isEmpty && promised.isEmpty && imageData == nil && links.isEmpty }
    /// Some of the input only exists after the drop (promises, raw image bytes).
    var needsMaterialisation: Bool { !promised.isEmpty || imageData != nil }

    /// Placeholder items for the sector list while the drop has not happened: the right KIND (by extension) without touching the disk.
    var placeholderItems: [FileItem] {
        var items = files
        for p in promised {
            for name in p.names {
                items.append(FileItem(url: AppPaths.incomingFolder(custom: AppSettings.shared.data.incomingFolder).appendingPathComponent(name), isDirectory: false, size: nil, contentType: nil))
            }
        }
        if imageData != nil {
            let ext = imageType?.preferredFilenameExtension ?? "png"
            items.append(FileItem(url: AppPaths.incomingFolder(custom: AppSettings.shared.data.incomingFolder).appendingPathComponent(L("Image", "Изображение") + "." + ext), isDirectory: false, size: nil, contentType: imageType))
        }
        return items
    }

    /// Everything the wheel needs before the drop (links win over nothing; files win over links when both travel).
    var previewInput: IncomingInput {
        IncomingInput(files: placeholderItems, links: links, origin: .wheel, pageTitle: linkTitle)
    }
}

enum DragPasteboardReader {
    // MARK: Pure type test

    static let legacyFilenames = "NSFilenamesPboardType"

    /// Types that mean "something we can work with is being dragged". Plain text is deliberately absent: dragging a text selection must not open a wheel.
    static func hasPayload(rawTypes: [String]) -> Bool {
        let set = Set(rawTypes)
        if set.contains(NSPasteboard.PasteboardType.fileURL.rawValue) || set.contains(legacyFilenames) { return true }
        if set.contains(NSPasteboard.PasteboardType.URL.rawValue) { return true }
        if set.contains(NSPasteboard.PasteboardType.png.rawValue) || set.contains(NSPasteboard.PasteboardType.tiff.rawValue) { return true }
        if !set.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes) { return true }
        return false
    }

    static func hasPayload(_ pb: NSPasteboard) -> Bool { hasPayload(rawTypes: (pb.types ?? []).map(\.rawValue)) }

    /// The pasteboard types the wheel panel registers for.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .png, .tiff, NSPasteboard.PasteboardType(legacyFilenames)] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    // MARK: Reading

    /// Reads the pasteboard without any I/O beyond stat calls: file URLs (existing only), promise receivers (names only), image bytes, web links.
    @MainActor
    static func read(_ pb: NSPasteboard) -> DragPayload {
        var payload = DragPayload()
        payload.changeCount = pb.changeCount

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] {
            var seen = Set<String>()
            for u in urls where FileManager.default.fileExists(atPath: u.path) && seen.insert(u.standardizedFileURL.path).inserted {
                payload.files.append(FileItem(url: u))
            }
        }
        if payload.files.isEmpty, let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] {
            payload.promised = receivers.map { PromisedFile(receiver: $0, names: $0.fileNames.isEmpty ? [L("File", "Файл")] : $0.fileNames) }
        }
        if payload.files.isEmpty && payload.promised.isEmpty {
            if let data = pb.data(forType: .png) { payload.imageData = data; payload.imageType = .png }
            else if let data = pb.data(forType: .tiff) { payload.imageData = data; payload.imageType = .tiff }
        }
        // Links travel with files too (a dragged web location); they matter when nothing else is there or the caller prefers them.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL] {
            let title = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            var seen = Set<String>()
            for u in urls where !u.isFileURL {
                guard case .success(let clean) = LinkParsing.validate(u.absoluteString), seen.insert(LinkParsing.canonicalKey(of: clean)).inserted else { continue }
                payload.links.append(LinkItem(url: clean, title: title, sourceName: L("Dragged link", "Перетащенная ссылка")))
            }
            payload.linkTitle = title
        }
        // A browser drags a picture as image bytes AND its address: the picture is the payload, the address is noise.
        if payload.imageData != nil && payload.files.isEmpty && payload.promised.isEmpty { payload.links = [] }
        return payload
    }

    // MARK: Materialising (at the moment of the drop)

    /// Starts delivering whatever only exists after the drop. MUST be called while the drop is being handled (promises are valid then). The returned
    /// handle completes when every promised file has arrived and the image bytes were written; failures simply leave their item out.
    @MainActor
    static func beginMaterialising(_ payload: DragPayload, into folder: URL) -> PendingInput {
        let pending = PendingInput(base: IncomingInput(files: payload.files, links: payload.links, origin: .wheel, pageTitle: payload.linkTitle))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pending.expect(payload.promised.reduce(0) { $0 + max($1.names.count, 1) } + (payload.imageData == nil ? 0 : 1))
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in payload.promised {
            promise.receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                pending.deliver(error == nil ? url : nil)
            }
        }
        if let data = payload.imageData {
            let name = L("Image", "Изображение") + " " + Self.stamp()
            let target = Util.uniqueURL(in: folder, base: name, ext: "png")
            let png: Data? = payload.imageType == .png ? data : ClipboardImageEncoding.pngData(from: data)
            if let png, (try? png.write(to: target, options: .atomic)) != nil { pending.deliver(target) } else { pending.deliver(nil) }
        }
        pending.sealIfNothingExpected()
        return pending
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: Date())
    }
}

/// The input after materialising: completes when all promised files arrived (thread-safe collector, resumable exactly once).
final class PendingInput: @unchecked Sendable {
    private let lock = NSLock()
    private var base: IncomingInput
    private var remaining = 0
    private var sealed = false
    private var done: IncomingInput?
    private var continuation: CheckedContinuation<IncomingInput, Never>?

    init(base: IncomingInput) { self.base = base }

    func expect(_ n: Int) { lock.lock(); remaining += n; lock.unlock() }

    func deliver(_ url: URL?) {
        lock.lock()
        if let url { base.files.append(FileItem(url: url)) }
        remaining -= 1
        let finish = remaining <= 0
        lock.unlock()
        if finish { complete() }
    }

    func sealIfNothingExpected() {
        lock.lock(); sealed = true; let finish = remaining <= 0; lock.unlock()
        if finish { complete() }
    }

    private func complete() {
        lock.lock()
        guard done == nil else { lock.unlock(); return }
        done = base
        let c = continuation; continuation = nil
        let value = base
        lock.unlock()
        c?.resume(returning: value)
    }

    /// The finished input. Safe to call before or after completion.
    func wait() async -> IncomingInput {
        await withCheckedContinuation { cont in
            lock.lock()
            if let done { lock.unlock(); cont.resume(returning: done); return }
            continuation = cont
            lock.unlock()
        }
    }
}

enum ClipboardImageEncoding {
    /// Any image bytes -> PNG bytes (alpha kept). nil when the data is not a picture.
    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

extension Util {
    /// `base.ext`, or `base (2).ext`, `base (3).ext` ... the first name that does not exist in `folder`.
    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let safe = safeFileName(base, fallback: "file")
        var url = folder.appendingPathComponent(safe).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safe) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
