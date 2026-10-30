import Foundation
import AppKit
import ImageIO
import QuickLookThumbnailing

// ONE thumbnail service for the whole app (Studio source strip, Jobs rows, download info card, shelf, queue). Decoding uses the ImageIO thumbnail options
// (`kCGImageSourceThumbnailMaxPixelSize`, no immediate caching of the full image) so a 60 MB RAW or a 100 MP photo never gets decoded at full size; other kinds
// (video, PDF, documents) go through QLThumbnailGenerator. Results live in a size-capped NSCache (32 MB, 200 entries); nothing is kept for views that are gone.

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.totalCostLimit = 32 * 1024 * 1024
        c.countLimit = 200
        return c
    }()

    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    private func key(_ url: URL, _ maxPixel: Int, _ scale: Int) -> NSString {
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(maxPixel)|\(scale)|\(m)" as NSString
    }

    /// A thumbnail whose longest side is at most `maxPixel` pixels (not points). nil when the file cannot be decoded. Cheap on a cache hit; cancellable.
    func thumbnail(for url: URL, kind: FileKind? = nil, maxPixel: Int = 256, scale: Int = 2) async -> CGImage? {
        let k = key(url, maxPixel, scale)
        if let hit = cache.object(forKey: k) { return hit.image }
        let kind = kind ?? FileItem(url: url).kind
        var result: CGImage?
        if kind.isImageLike || kind == .other, let img = Self.imageIOThumbnail(url: url, maxPixel: maxPixel) { result = img }
        else if let img = await Self.quickLookThumbnail(url: url, maxPixel: maxPixel, scale: scale) { result = img }
        if result == nil, FileManager.default.fileExists(atPath: url.path) {
            // QLThumbnailGenerator fails for archives and unknown types: the generic file icon is the calm fallback.
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            var rect = CGRect(x: 0, y: 0, width: maxPixel, height: maxPixel)
            result = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        if let r = result, !Task.isCancelled { cache.setObject(CGImageBox(r), forKey: k, cost: r.bytesPerRow * r.height) }
        return result
    }

    func removeAll() { cache.removeAllObjects() }

    static func imageIOThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,           // bake the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    static func quickLookThumbnail(url: URL, maxPixel: Int, scale: Int) async -> CGImage? {
        let side = CGFloat(maxPixel) / CGFloat(max(scale, 1))
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: CGFloat(scale), representationTypes: .thumbnail)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in cont.resume(returning: rep?.cgImage) }
        }
    }
}
