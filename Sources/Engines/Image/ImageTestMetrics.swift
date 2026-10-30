import Foundation
import ImageIO
import CoreGraphics
import CoreText
import PDFKit
import UniformTypeIdentifiers

/// Independent read-back measurements for the image self-tests: they decode files with ImageIO (never with the code under test), sniff real formats by magic bytes
/// and by the system `file` command, and compare pictures (PSNR on RGB, bit-exact equality).
enum ImgMetrics {
    // MARK: Pixels

    /// A decoded picture as 8-bit RGBA, sRGB, composited on `background` (so transparency is comparable between files). Orientation tags are NOT applied.
    struct Pixels {
        var width: Int
        var height: Int
        var data: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = (y * width + x) * 4; return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2])) }
    }

    static func pixels(_ url: URL, frame: Int = 0, background: RGBA = .white) -> Pixels? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > frame,
              let img = CGImageSourceCreateImageAtIndex(src, frame, nil) else { return nil }
        return pixels(img, background: background)
    }

    static func pixels(_ img: CGImage, background: RGBA = .white) -> Pixels? {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(background.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Pixels(width: w, height: h, data: data) : nil
    }

    static func frameProps(_ url: URL, _ index: Int) -> [CFString: Any]? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, index, nil) as? [CFString: Any] }
    }

    /// Colour of one pixel (relative position) of frame `frame`, composited on white.
    static func pixel(_ url: URL, frame: Int, _ fx: Double, _ fy: Double) -> RGBA? {
        guard let p = pixels(url, frame: frame) else { return nil }
        let x = min(p.width - 1, Int(Double(p.width) * fx)), y = min(p.height - 1, Int(Double(p.height) * fy))
        let c = p.rgb(x, y)
        return RGBA(r: UInt8(c.0), g: UInt8(c.1), b: UInt8(c.2))
    }

    /// PSNR in dB over the RGB channels (255 peak); `.infinity` when identical; nil when the sizes differ or a file cannot be decoded.
    static func psnr(_ a: URL, _ b: URL) -> Double? {
        guard let pa = pixels(a), let pb = pixels(b) else { return nil }
        return psnr(pa, pb)
    }

    static func psnr(_ pa: Pixels, _ pb: Pixels) -> Double? {
        guard pa.width == pb.width, pa.height == pb.height else { return nil }
        var sum = 0.0
        var i = 0
        let n = pa.width * pa.height
        for _ in 0..<n {
            for c in 0..<3 { let d = Double(Int(pa.data[i + c]) - Int(pb.data[i + c])); sum += d * d }
            i += 4
        }
        let mse = sum / Double(n * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let pa = pixels(a), let pb = pixels(b), pa.width == pb.width, pa.height == pb.height else { return false }
        return pa.data == pb.data
    }

    /// Largest per-channel difference between two equally sized pictures.
    static func maxDifference(_ a: Pixels, _ b: Pixels) -> Int? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var m = 0
        for i in 0..<a.data.count where i % 4 != 3 { m = max(m, abs(Int(a.data[i]) - Int(b.data[i]))) }
        return m
    }

    /// PSNR of `output` against the `source` scaled to the same size (for resized results): the source is redrawn with high-quality interpolation.
    static func psnrScaled(source: URL, output: URL, applyingOrientation: Bool = false) -> Double? {
        guard let po = pixels(output), let src = CGImageSourceCreateWithURL(source as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: po.width, height: po.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: po.width, height: po.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: po.width, height: po.height))
        guard let scaled = ctx.makeImage(), let ps = pixels(scaled) else { return nil }
        return psnr(ps, po)
    }

    // MARK: Format sniffing (independent of the writer)

    /// The real format of a file from its magic bytes: jpeg, png, gif, bmp, tiff, webp, ico, icns, pdf, jp2, heic, avif, or "unknown".
    static func sniff(_ url: URL) -> String {
        let b = TestFile.magic(url, 32)
        func starts(_ s: [UInt8], at o: Int = 0) -> Bool { b.count >= o + s.count && Array(b[o..<(o + s.count)]) == s }
        func ascii(_ s: String, at o: Int = 0) -> Bool { starts(Array(s.utf8), at: o) }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if ascii("GIF87a") || ascii("GIF89a") { return "gif" }
        if ascii("BM") { return "bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if ascii("RIFF") && ascii("WEBP", at: 8) { return "webp" }
        if starts([0, 0, 1, 0]) { return "ico" }
        if ascii("icns") { return "icns" }
        if ascii("%PDF") { return "pdf" }
        if starts([0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return "jp2" }
        if ascii("ftyp", at: 4) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if brand.hasPrefix("avi") { return "avif" }
            if ["heic", "heix", "mif1", "msf1", "hevc"].contains(brand) { return "heic" }
        }
        return "unknown"
    }

    /// ImageIO's own answer ("public.jpeg" ...), a second opinion next to the magic bytes.
    static func imageIOType(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// `/usr/bin/file --mime-type -b`, a third opinion that shares no code with the writer.
    static func mime(_ url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        p.arguments = ["--mime-type", "-b", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fixtures

    /// A photographic-like picture: sky-to-ground gradient, soft shapes, text and sensor-like noise of +-`noise` levels (so lossy metrics and file sizes mean something).
    static func photo(_ fx: TestFixtures, _ name: String = "photo.png", width: Int = 640, height: Int = 480, seed: UInt64 = 11, alpha: Bool = false, noise: Int = 8) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestFailure(message: "no bitmap context", file: #fileID, line: #line)
        }
        let w = CGFloat(width), h = CGFloat(height)
        let sky = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.25, green: 0.45, blue: 0.85, alpha: 1), CGColor(srgbRed: 0.95, green: 0.80, blue: 0.60, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.35), options: [.drawsAfterEndLocation])
        ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.38, blue: 0.18, alpha: 1))
        ctx.move(to: CGPoint(x: 0, y: h * 0.35)); ctx.addCurve(to: CGPoint(x: w, y: h * 0.30), control1: CGPoint(x: w * 0.3, y: h * 0.50), control2: CGPoint(x: w * 0.7, y: h * 0.15))
        ctx.addLine(to: CGPoint(x: w, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: 0)); ctx.fillPath()
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.55, width: w * 0.18, height: w * 0.18))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.9, alpha: 1)); ctx.fillEllipse(in: CGRect(x: w * 0.12, y: h * 0.62, width: w * 0.22, height: w * 0.10))
        let font = CTFontCreateUIFontForLanguage(.system, max(14, h / 9), nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Swamp 12345 Привет", attributes: [.font: font, .foregroundColor: CGColor(gray: 0.05, alpha: 1)]))
        ctx.textPosition = CGPoint(x: w * 0.08, y: h * 0.12)
        CTLineDraw(line, ctx)
        // Sensor noise on top.
        var rng = SplitMix(seed: seed)
        if let p = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height) {
            for y in 0..<height { for x in 0..<width {
                let o = y * ctx.bytesPerRow + x * 4
                if alpha && p[o + 3] == 0 { continue }
                let n = noise == 0 ? 0 : Int(rng.next() % UInt64(2 * noise + 1)) - noise
                for c in 0..<3 { p[o + c] = UInt8(max(0, min(255, Int(p[o + c]) + n))) }
            } }
        }
        if alpha {
            // A transparent hole (right quarter) so alpha handling is observable.
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: w * 0.75, y: 0, width: w * 0.25, height: h))
        }
        guard let image = ctx.makeImage() else { throw TestFailure(message: "no photo image", file: #fileID, line: #line) }
        let ext = (name as NSString).pathExtension.lowercased()
        let type: UTType = ext == "png" ? .png : (ext == "tiff" || ext == "tif" ? .tiff : .jpeg)
        return try fx.writeImage(image, name: name, type: type, properties: type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:])
    }
}


/// PDF read-back through PDFKit (independent of the code that wrote the file).
enum PDFProbe {
    static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

    /// The page drawn on white at `scale` pixels per point.
    static func render(_ url: URL, page: Int = 0, scale: Double = 1) -> CGImage? {
        guard let doc = PDFDocument(url: url), let p = doc.page(at: page) else { return nil }
        let box = p.bounds(for: .mediaBox)
        let w = max(1, Int((box.width * scale).rounded())), h = max(1, Int((box.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        p.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
