import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CommonCrypto
import AppKit
import CoreText

// Shared helpers of the intelligence self-tests (oracles read results back with code that is NOT the code that wrote them).

/// One-shot event with a timeout (tests wait on it instead of polling).
final class IntelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func fire() {
        lock.lock(); fired = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume(returning: true) }
    }

    /// True when the event happened, false after `timeout` seconds without it.
    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if fired { lock.unlock(); c.resume(returning: true); return }
            waiters.append(c)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock(); let w = waiters; waiters = []; lock.unlock()
                w.forEach { $0.resume(returning: false) }
            }
        }
    }
}

enum IntelTest {
    /// The resolved quick recipe of the image scrub operation.
    @MainActor
    static func quickScrubOptions() -> OptionValues {
        let op = (try? operation("scrub.image"))!
        return OperationContext.testing(op, items: []).options
    }

    /// A registered operation by id, built fresh from the catalogue.
    @MainActor
    static func operation(_ id: String) throws -> Operation {
        try unwrap(IntelligenceCatalog.operations().first { $0.meta.id == id }, "operation \(id) is not in the catalogue")
    }

    /// Runs `id` on `urls` with its quick recipe plus `extra`, writing next to the sources (the fixture folder).
    @MainActor
    static func run(_ id: String, _ urls: [URL], extra: OptionValues = OptionValues(), mode: RunMode = .quick) async throws -> OperationResult {
        let op = try operation(id)
        let items = urls.map { FileItem(url: $0) }
        let ctx = OperationContext.testing(op, items: items, extra: extra, mode: mode)
        defer { ctx.cleanupTemp() }
        return try await op.execute(items: items, ctx: ctx)
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Everything ImageIO reports about the first image, flattened to "dictionary.key" (properties) so tests can look for leaks.
    static func properties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return props
    }

    static func dictionary(_ url: URL, _ key: CFString) -> [String: Any] { properties(url)[key as String] as? [String: Any] ?? [:] }

    /// A JPEG that carries every kind of personal tag the scrubber knows.
    @discardableResult
    static func richJPEG(_ fx: TestFixtures, _ name: String = "rich.jpg", orientation: Int? = nil, width: Int = 96, height: Int = 64,
                         colorSpace: CGColorSpace? = nil) throws -> URL {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 50.08, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 14.42, kCGImagePropertyGPSLongitudeRef: "E", kCGImagePropertyGPSAltitude: 190.0] as [CFString: Any]
        props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "SwampCam", kCGImagePropertyTIFFModel: "Test 1", kCGImagePropertyTIFFArtist: "Andris Test",
                                                 kCGImagePropertyTIFFSoftware: "SwampEdit 9"] as [CFString: Any]
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00", kCGImagePropertyExifLensModel: "Swamp 35mm f/1.8",
                                                 kCGImagePropertyExifBodySerialNumber: "SN-123456", kCGImagePropertyExifUserComment: "private note"] as [CFString: Any]
        props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCaptionAbstract: "Secret caption", kCGImagePropertyIPTCByline: ["Andris Test"]] as [CFString: Any]
        var image = fx.cgImage(width: width, height: height, pattern: .quadrants)
        if let colorSpace, let converted = image.copy(colorSpace: colorSpace) { image = converted }
        return try fx.writeImage(image, name: name, type: .jpeg, properties: props)
    }

    /// Decoded sRGB RGBA bytes of a picture file (nil when it cannot be read).
    static func rgba(_ u: URL) -> (w: Int, h: Int, px: [UInt8])? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let data = ctx.data else { return nil }
        return (img.width, img.height, Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4)))
    }

    /// Mean absolute difference of two pictures of the same size after decoding both (0 = identical), on a 0...255 scale.
    static func meanDifference(_ a: URL, _ b: URL) -> Double? {
        guard let x = rgba(a), let y = rgba(b), x.w == y.w, x.h == y.h else { return nil }
        var sum = 0
        for i in 0..<x.px.count where i % 4 != 3 { sum += abs(Int(x.px[i]) - Int(y.px[i])) }
        return Double(sum) / Double(x.w * x.h * 3)
    }

    /// PSNR in dB over the RGB channels of two same-size pictures (infinity when identical).
    static func psnr(_ a: URL, _ b: URL) -> Double? {
        guard let x = rgba(a), let y = rgba(b), x.w == y.w, x.h == y.h else { return nil }
        var sum = 0.0
        for i in 0..<x.px.count where i % 4 != 3 { let d = Double(Int(x.px[i]) - Int(y.px[i])); sum += d * d }
        let mse = sum / Double(x.w * x.h * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// A photograph-like picture: smooth gradient, soft shapes, fine noise and some text (flat colours would make every lossy metric meaningless).
    static func photoLike(_ fx: TestFixtures, width: Int = 320, height: Int = 240) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.1, green: 0.3, blue: 0.6, alpha: 1), CGColor(srgbRed: 0.95, green: 0.75, blue: 0.4, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 0.8)); ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Swamp 2024 Привет", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.white]))
        ctx.textPosition = CGPoint(x: 12, y: 14); CTLineDraw(line, ctx)
        var rng = SplitMix(seed: 7)
        if let p = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) {
            let bpr = ctx.bytesPerRow
            for y in 0..<height { for x in 0..<width {
                let o = y * bpr + x * 4
                let n = Int(rng.next() % 9) - 4
                for c in 0..<3 { p[o + c] = UInt8(max(0, min(255, Int(p[o + c]) + n))) }
            } }
        }
        return ctx.makeImage()!
    }

    /// First line of output of `ffprobe` / `ffmpeg` style tools; nil when the tool is missing.
    static func tool(_ t: Tool, _ args: [String], timeout: TimeInterval = 60) -> String? {
        guard let url = ToolLocator.shared.url(t) else { return nil }
        return SyncProcess.run(url, args, timeout: timeout)
    }

    /// MD5 of the first video / audio stream's compressed packets (`-c copy`), the proof that a copy did not re-encode.
    static func streamHash(_ url: URL, stream: String) -> String? {
        tool(.ffmpeg, ["-v", "error", "-i", url.path, "-map", stream, "-c", "copy", "-f", "md5", "-"])?
            .split(separator: "\n").first(where: { $0.hasPrefix("MD5=") }).map(String.init)
    }

    /// ffprobe JSON of tags + streams.
    static func probeTags(_ url: URL) -> (format: [String: String], streams: [[String: String]])? {
        guard let text = tool(.ffprobe, ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", url.path]), let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func tags(_ d: [String: Any]?) -> [String: String] {
            ((d?["tags"] as? [String: Any]) ?? [:]).reduce(into: [:]) { $0[$1.key.lowercased()] = "\($1.value)" }
        }
        return (tags(json["format"] as? [String: Any]), ((json["streams"] as? [[String: Any]]) ?? []).map(tags))
    }
}
