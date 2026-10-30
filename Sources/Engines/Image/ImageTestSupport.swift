import Foundation
import ImageIO
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers

/// Helpers of the image self-tests: running an operation the way the job runner does, reading outputs back with independent probes, and generated fixtures
/// (animated GIF, 16-bit wide-gamut PNG, a camera-RAW-like DNG) that `TestFixtures` does not provide.
enum ImgT {
    // MARK: Running operations

    @MainActor
    static func op(_ id: String) -> Operation {
        ImageCatalog.operations().first { $0.meta.id == id }!
    }

    /// Resolves `quick recipe + extra` over the schema with the source probed (like Studio) and executes. `mode: .quick` skips same-format files like the wheel.
    @MainActor
    @discardableResult
    static func run(_ id: String, _ urls: [URL], _ extra: OptionValues = OptionValues(), rules: OutputRules = OutputRules(),
                    settings: SettingsData = SettingsData(), mode: RunMode = .quick) async throws -> OperationResult {
        let operation = op(id)
        let items = FileItem.items(urls)
        let source = items.first != nil ? await ImageSourceProbe().probe(items[0]) : nil
        let resolved = operation.optionSchema(for: items).resolve(layers: [operation.quickOverrides(settings: settings), extra], source: source)
        let ctx = OperationContext(operationID: id, mode: mode, resolved: resolved, outputRules: rules, settings: settings)
        return try await operation.execute(items: items, ctx: ctx)
    }

    /// Runs `image.to.jpg` with `extra` (always Studio mode: nothing is skipped) and returns the single output.
    @MainActor
    static func convert(_ url: URL, _ extra: OptionValues, via id: String = "image.to.jpg") async throws -> URL {
        let r = try await run(id, [url], extra, mode: .studio)
        return try unwrap(r.outputs.first, "no output produced")
    }

    // MARK: Read-back probes

    static func props(_ url: URL) -> [CFString: Any] { ImageMetadata.read(url) ?? [:] }

    static func dict(_ url: URL, _ key: CFString) -> [CFString: Any]? { props(url)[key] as? [CFString: Any] }

    static func hasGPS(_ url: URL) -> Bool { ImageMetadata.hasGPS(props(url)) }

    static func make(_ url: URL) -> String? { dict(url, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake] as? String }

    static func depth(_ url: URL) -> Int { (props(url)[kCGImagePropertyDepth] as? Int) ?? 0 }

    static func profile(_ url: URL) -> String { (props(url)[kCGImagePropertyProfileName] as? String) ?? "" }

    static func dpi(_ url: URL) -> Double? { ImageMetadata.dpi(props(url))?.x }

    static func frameCount(_ url: URL) -> Int { CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0 }

    static func bytes(_ url: URL) -> [UInt8] { (try? Data(contentsOf: url)).map { Array($0) } ?? [] }

    static func size(_ url: URL) -> (width: Int, height: Int) { TestImage.size(of: url) ?? (0, 0) }

    /// Pixel at a relative position (0...1) so tests do not depend on exact sizes.
    static func pixel(_ url: URL, _ fx: Double, _ fy: Double) -> RGBA? {
        let s = size(url)
        return TestImage.pixel(of: url, x: min(s.width - 1, Int(Double(s.width) * fx)), y: min(s.height - 1, Int(Double(s.height) * fy)))
    }

    /// Colours of the four quadrants (TL, TR, BL, BR) of a picture.
    static func quadrants(_ url: URL) -> [RGBA?] { [pixel(url, 0.25, 0.25), pixel(url, 0.75, 0.25), pixel(url, 0.25, 0.75), pixel(url, 0.75, 0.75)] }

    static func isQuadrants(_ url: URL, _ expected: [RGBA], tolerance: Int = 30) -> Bool {
        let q = quadrants(url)
        return q.count == 4 && zip(q, expected).allSatisfy { TestImage.close($0, $1, tolerance: tolerance) }
    }

    static func describe(_ url: URL) -> String { quadrants(url).map { $0.map { "(\($0.r),\($0.g),\($0.b),\($0.a))" } ?? "nil" }.joined(separator: " ") }

    /// PNG header: (bit depth, colour type, interlace).
    static func pngHeader(_ url: URL) -> (depth: Int, colorType: Int, interlace: Int)? {
        let b = bytes(url)
        guard b.count > 33, b[0] == 0x89, b[1] == 0x50 else { return nil }
        return (Int(b[24]), Int(b[25]), Int(b[28]))
    }

    /// First JPEG start-of-frame marker: (marker byte, per-component (h, v) sampling).
    static func jpegFrame(_ url: URL) -> (marker: UInt8, components: [(h: Int, v: Int)])? {
        let b = bytes(url)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let m = b[i + 1]
            if m == 0xFF { i += 1; continue }
            if m == 0xD8 || (0xD0...0xD7).contains(m) || m == 0x01 { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(m), m != 0xC4, m != 0xC8, m != 0xCC {
                let n = Int(b[i + 9])
                var comps: [(Int, Int)] = []
                for k in 0..<n { let s = Int(b[i + 11 + k * 3]); comps.append((s >> 4, s & 15)) }
                return (m, comps)
            }
            i += 2 + len
        }
        return nil
    }

    /// Pixel of a PDF page rendered on white (relative position, y from the top).
    static func pdfPixel(_ url: URL, page: Int = 0, _ fx: Double, _ fy: Double, scale: Double = 1) -> RGBA? {
        guard let doc = PDFDocument(url: url), let p = doc.page(at: page) else { return nil }
        let box = p.bounds(for: .mediaBox)
        let w = max(1, Int(box.width * scale)), h = max(1, Int(box.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        p.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return nil }
        let x = min(w - 1, Int(Double(w) * fx)), y = min(h - 1, Int(Double(h) * fy))
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let o = y * ctx.bytesPerRow + x * 4
        return RGBA(r: px[o], g: px[o + 1], b: px[o + 2], a: px[o + 3])
    }

    static func mediaBox(_ url: URL, page: Int = 0) -> CGRect? { PDFDocument(url: url)?.page(at: page)?.bounds(for: .mediaBox) }

    // MARK: Fixtures

    /// Animated GIF of solid frames (red, green, blue ...) with the given delay each.
    static func animatedGIF(_ fx: TestFixtures, _ name: String = "anim.gif", frames: Int = 3, width: Int = 40, height: Int = 30, delay: Double = 0.2) throws -> URL {
        let colors: [RGBA] = [.red, .green, .blue, .yellow, .orange]
        let url = fx.url(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else { throw TestFailure(message: "no GIF destination", file: #fileID, line: #line) }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            CGImageDestinationAddImage(dest, fx.cgImage(width: width, height: height, pattern: .solid(colors[i % colors.count])),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw TestFailure(message: "GIF finalize failed", file: #fileID, line: #line) }
        return url
    }

    /// 16-bit PNG or TIFF in Display P3 (a horizontal ramp), to prove depth and profile survive.
    static func wideGamut(_ fx: TestFixtures, _ name: String = "p3.tiff", type: UTType = .tiff, width: Int = 64, height: Int = 32) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else {
            throw TestFailure(message: "no 16-bit context", file: #fileID, line: #line)
        }
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(colorSpace: cs, components: [0.9, 0.1, 0.1, 1])!, CGColor(colorSpace: cs, components: [0.1, 0.2, 0.95, 1])!] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        return try fx.writeImage(ctx.makeImage()!, name: name, type: type)
    }

    /// A camera-RAW-like DNG (linear 16-bit RGB, 2048 x 1536, left half red, right half blue) written byte by byte; ImageIO and the system RAW engine decode it.
    static func dng(_ fx: TestFixtures, _ name: String = "shot.dng", width: Int = 2048, height: Int = 1536) throws -> URL {
        var pix = Data(capacity: width * height * 6)
        var row = [UInt16](repeating: 0, count: width * 3)
        for y in 0..<height {
            for x in 0..<width {
                let left = x < width / 2
                row[x * 3] = left ? 40000 : 5000
                row[x * 3 + 1] = UInt16(Double(y) / Double(height) * 12000 + 3000)
                row[x * 3 + 2] = left ? 5000 : 40000
            }
            row.withUnsafeBytes { pix.append(contentsOf: $0) }
        }
        var d = Data([0x49, 0x49, 0x2A, 0x00, 0, 0, 0, 0])
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func pad() { if d.count % 2 == 1 { d.append(0) } }
        let pixOff = d.count
        d.append(pix)
        let bpsOff = d.count; u16(16); u16(16); u16(16); pad()
        func ascii(_ s: String) -> (Int, Int) { let o = d.count; d.append(contentsOf: Array(s.utf8)); d.append(0); pad(); return (o, s.utf8.count + 1) }
        let make = ascii("SwampCam"), model = ascii("Swamp DNG 1"), unique = ascii("SwampCam Swamp DNG 1")
        let cmOff = d.count
        for (n, den) in [(1, 1), (0, 1), (0, 1), (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), (1, 1)] { u32(n); u32(den) }
        let neutralOff = d.count
        for _ in 0..<3 { u32(1); u32(1) }
        while d.count % 4 != 0 { d.append(0) }
        let ifdOff = d.count
        let entries: [(Int, Int, Int, Int)] = [
            (254, 4, 1, 0), (256, 4, 1, width), (257, 4, 1, height), (258, 3, 3, bpsOff), (259, 3, 1, 1), (262, 3, 1, 34892),
            (271, 2, make.1, make.0), (272, 2, model.1, model.0), (273, 4, 1, pixOff), (274, 3, 1, 1), (277, 3, 1, 3), (278, 4, 1, height),
            (279, 4, 1, pix.count), (284, 3, 1, 1), (50706, 1, 4, 1 | (4 << 8)), (50707, 1, 4, 1 | (1 << 8)), (50708, 2, unique.1, unique.0),
            (50721, 10, 9, cmOff), (50728, 5, 3, neutralOff), (50778, 3, 1, 21)]
        u16(entries.count)
        for e in entries { u16(e.0); u16(e.1); u32(e.2); u32(e.3) }
        u32(0)
        var off = UInt32(ifdOff).littleEndian
        withUnsafeBytes(of: &off) { d.replaceSubrange(4..<8, with: $0) }
        let url = fx.url(name)
        try d.write(to: url)
        return url
    }

    /// A large JPEG (gradient) for memory-safe resizing tests.
    static func bigJPEG(_ fx: TestFixtures, _ name: String = "big.jpg", width: Int = 6000, height: Int = 4000) throws -> URL {
        try fx.writeImage(fx.cgImage(width: width, height: height, pattern: .gradient), name: name, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.8])
    }

    static func noisePhoto(_ fx: TestFixtures, _ name: String = "photo.png", width: Int = 640, height: Int = 480) throws -> URL {
        // Smooth picture with a little noise: compresses like a photograph (quality visibly changes the size).
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SplitMix(seed: 7)
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        for y in 0..<height { for x in 0..<width {
            let o = y * ctx.bytesPerRow + x * 4
            let n = Int(rng.next() & 31) - 16
            p[o] = UInt8(max(0, min(255, x * 255 / width + n))); p[o + 1] = UInt8(max(0, min(255, y * 255 / height + n))); p[o + 2] = UInt8(max(0, min(255, 128 + (x - y) / 8 + n))); p[o + 3] = 255
        } }
        return try fx.writeImage(ctx.makeImage()!, name: name, type: name.hasSuffix(".png") ? .png : .jpeg)
    }
}
