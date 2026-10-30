import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Accelerate

// Pixel-level comparison of pictures for the conformance checks. Both sides are decoded with ImageIO (orientation applied, sRGB, 8 bit) and
// compared as numbers: PSNR, SSIM, alpha plane, exact equality. Decoding the OUTPUT with ImageIO is independent of whatever encoder wrote it
// (the engines use ImageIO to write too, but a wrong container, a wrong colour space or a missing alpha channel still shows up in the numbers).

struct RasterImage: @unchecked Sendable {
    var width: Int
    var height: Int
    /// R, G, B per pixel (3 bytes), transparency composited on the background colour the decode asked for (white by default).
    var rgb: [UInt8]
    /// One alpha byte per pixel (255 for opaque pictures).
    var alpha: [UInt8]

    var pixelCount: Int { width * height }
    var hasTransparency: Bool { alpha.contains { $0 < 250 } }
    var transparentFraction: Double { alpha.isEmpty ? 0 : Double(alpha.filter { $0 < 128 }.count) / Double(alpha.count) }

    /// Rec.709 luma plane.
    var luma: [Float] {
        let n = pixelCount
        var out = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n), g = r, b = r
        rgb.withUnsafeBufferPointer { p in
            vDSP_vfltu8(p.baseAddress!, 3, &r, 1, vDSP_Length(n))
            vDSP_vfltu8(p.baseAddress! + 1, 3, &g, 1, vDSP_Length(n))
            vDSP_vfltu8(p.baseAddress! + 2, 3, &b, 1, vDSP_Length(n))
        }
        var wr: Float = 0.2126, wg: Float = 0.7152, wb: Float = 0.0722
        vDSP_vsmul(r, 1, &wr, &out, 1, vDSP_Length(n))
        vDSP_vsma(g, 1, &wg, out, 1, &out, 1, vDSP_Length(n))
        vDSP_vsma(b, 1, &wb, out, 1, &out, 1, vDSP_Length(n))
        return out
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)
        return (Int(rgb[i * 3]), Int(rgb[i * 3 + 1]), Int(rgb[i * 3 + 2]), Int(alpha[i]))
    }

    /// Mean colour of a rectangle given in 0...1 coordinates (x right, y down).
    func mean(_ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) -> (r: Double, g: Double, b: Double) {
        let x0 = Int(Double(width) * rx), y0 = Int(Double(height) * ry)
        let x1 = max(x0 + 1, Int(Double(width) * (rx + rw))), y1 = max(y0 + 1, Int(Double(height) * (ry + rh)))
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for y in y0..<min(y1, height) { for x in x0..<min(x1, width) {
            let i = y * width + x
            sr += Double(rgb[i * 3]); sg += Double(rgb[i * 3 + 1]); sb += Double(rgb[i * 3 + 2]); n += 1
        } }
        return n == 0 ? (0, 0, 0) : (sr / n, sg / n, sb / n)
    }
}

enum ImageFidelity {
    // MARK: Decoding

    /// Pixel size from the container header (no orientation applied).
    static func storedSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func orientationTag(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return p[kCGImagePropertyOrientation] as? Int
    }

    static func frameCount(_ url: URL) -> Int { CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0 }

    /// Index of the largest frame (ICO and ICNS hold several sizes; index 0 is usually the smallest).
    static func largestFrame(_ src: CGImageSource) -> Int {
        var best = 0, bestArea = 0
        for i in 0..<CGImageSourceGetCount(src) {
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { continue }
            if w * h > bestArea { best = i; bestArea = w * h }
        }
        return best
    }

    /// The decoded picture: orientation applied, converted to sRGB, transparency also composited on `background`. Nil when ImageIO cannot decode the file.
    /// `maxSide` decodes a reduced picture (ImageIO's own scaler): comparing big pictures in a debug build is slow, and two pictures of the same size reduce to the same size.
    static func decode(_ url: URL, applyOrientation: Bool = true, largestFrame wantLargest: Bool = false, maxSide: Int? = nil, background: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)) -> RasterImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let index = wantLargest ? largestFrame(src) : 0
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let image: CGImage?
        if applyOrientation || (maxSide.map { max(pw, ph) > $0 } ?? false) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
                                         kCGImageSourceThumbnailMaxPixelSize: min(max(pw, ph), maxSide ?? Int.max), kCGImageSourceShouldCacheImmediately: true]
            image = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, index, nil)
        }
        guard let cg = image else { return nil }
        return raster(cg, background: background)
    }

    static func raster(_ cg: CGImage, background: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)) -> RasterImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var alphaPlane = [UInt8](repeating: 255, count: w * h)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        // Pass 1: straight alpha over transparent black gives the alpha plane.
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok1 = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok1 else { return nil }
        for i in 0..<(w * h) { alphaPlane[i] = buf[i * 4 + 3] }
        // Pass 2: composite on the background.
        let ok2 = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255, blue: CGFloat(background.b) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok2 else { return nil }
        for i in 0..<(w * h) { rgb[i * 3] = buf[i * 4]; rgb[i * 3 + 1] = buf[i * 4 + 1]; rgb[i * 3 + 2] = buf[i * 4 + 2] }
        return RasterImage(width: w, height: h, rgb: rgb, alpha: alphaPlane)
    }

    /// Rasterises one PDF page to the given pixel width (white page, annotations drawn).
    static func rasterize(pdf url: URL, page: Int = 0, width: Int) -> RasterImage? {
        rasterizeCG(pdf: url, page: page, width: width).flatMap { raster($0) }
    }

    /// The page rendered at the full output resolution and then reduced by ImageIO's thumbnailer, exactly the way `decode(_:maxSide:)` reduces the converter's own picture.
    /// Comparing a picture reduced by ImageIO with a page rendered straight at the small size mixes two different resamplers into the difference (text edges alone cost 5 dB).
    static func rasterizeReduced(pdf url: URL, page: Int = 0, renderWidth: Int, maxSide: Int) -> RasterImage? {
        guard let full = rasterizeCG(pdf: url, page: page, width: renderWidth),
              let data = CFDataCreateMutable(nil, 0), let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, full, nil)
        guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(max(full.width, full.height), maxSide), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).flatMap { raster($0) }
    }

    private static func rasterizeCG(pdf url: URL, page: Int, width: Int) -> CGImage? {
        guard let doc = PDFDocument(url: url), let p = doc.page(at: page) else { return nil }
        let box = p.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(width) / box.width
        let w = width, h = max(1, Int((box.height * scale).rounded()))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        p.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: Resampling

    /// High-quality resample to another size (for comparing a resized output with its source).
    static func scaled(_ img: RasterImage, width: Int, height: Int) -> RasterImage? {
        guard width > 0, height > 0, img.width > 0 else { return nil }
        if width == img.width && height == img.height { return img }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 255, count: img.pixelCount * 4)
        for i in 0..<img.pixelCount { rgba[i * 4] = img.rgb[i * 3]; rgba[i * 4 + 1] = img.rgb[i * 3 + 1]; rgba[i * 4 + 2] = img.rgb[i * 3 + 2] }
        let source: CGImage? = CGDataProvider(data: Data(rgba) as CFData).flatMap {
            CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4, space: cs,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let cg = source,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { return nil }
        return raster(out)
    }

    // MARK: Metrics

    /// Peak signal-to-noise ratio in dB over R, G and B (infinity for identical pictures). Nil when the sizes differ.
    static func psnr(_ a: RasterImage, _ b: RasterImage) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let n = a.rgb.count
        var fa = [Float](repeating: 0, count: n), fb = fa, diff = fa
        a.rgb.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress!, 1, &fa, 1, vDSP_Length(n)) }
        b.rgb.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress!, 1, &fb, 1, vDSP_Length(n)) }
        vDSP_vsub(fb, 1, fa, 1, &diff, 1, vDSP_Length(n))
        var sum: Float = 0
        vDSP_svesq(diff, 1, &sum, vDSP_Length(n))
        let mse = Double(sum) / Double(n)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// Pearson correlation of the luma planes after both pictures are reduced to `width` px (area-averaged), which removes anti-aliasing differences between two renderers
    /// and keeps where the ink is. 1 = the same layout, about 0 = unrelated, negative = inverted. Nil when a picture is too small or has no contrast at all.
    static func layoutCorrelation(_ a: RasterImage, _ b: RasterImage, width: Int = 80) -> Double? {
        guard a.width >= width, b.width >= width else { return nil }
        let h = max(1, Int((Double(width) * Double(a.height) / Double(a.width)).rounded()))
        guard let sa = scaled(a, width: width, height: h), let sb = scaled(b, width: width, height: h) else { return nil }
        let la = sa.luma, lb = sb.luma
        let n = Float(la.count)
        let ma = la.reduce(0, +) / n, mb = lb.reduce(0, +) / n
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for i in 0..<la.count { let x = la[i] - ma, y = lb[i] - mb; cov += x * y; va += x * x; vb += y * y }
        guard va > 0, vb > 0 else { return nil }
        return Double(cov / (va.squareRoot() * vb.squareRoot()))
    }

    /// Mean structural similarity of the luma planes (8x8 windows, stride 4). 1 means identical.
    static func ssim(_ a: RasterImage, _ b: RasterImage) -> Double? {
        guard a.width == b.width, a.height == b.height, a.width >= 8, a.height >= 8 else { return nil }
        let la = a.luma, lb = b.luma
        let c1: Float = 6.5025, c2: Float = 58.5225
        var total: Double = 0
        var windows = 0
        var y = 0
        while y + 8 <= a.height {
            var x = 0
            while x + 8 <= a.width {
                var ma: Float = 0, mb: Float = 0
                for dy in 0..<8 { for dx in 0..<8 { let i = (y + dy) * a.width + x + dx; ma += la[i]; mb += lb[i] } }
                ma /= 64; mb /= 64
                var va: Float = 0, vb: Float = 0, cov: Float = 0
                for dy in 0..<8 { for dx in 0..<8 {
                    let i = (y + dy) * a.width + x + dx
                    let da = la[i] - ma, db = lb[i] - mb
                    va += da * da; vb += db * db; cov += da * db
                } }
                va /= 63; vb /= 63; cov /= 63
                total += Double(((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2)))
                windows += 1
                x += 4
            }
            y += 4
        }
        return windows == 0 ? nil : total / Double(windows)
    }

    /// Largest absolute difference of any channel of any pixel.
    static func maxDifference(_ a: RasterImage, _ b: RasterImage) -> Int? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var m = 0
        for i in 0..<a.rgb.count { m = max(m, abs(Int(a.rgb[i]) - Int(b.rgb[i]))) }
        return m
    }

    /// Mean absolute difference of the alpha planes (0 = identical transparency).
    static func alphaError(_ a: RasterImage, _ b: RasterImage) -> Double? {
        guard a.width == b.width, a.height == b.height, !a.alpha.isEmpty else { return nil }
        var s = 0
        for i in 0..<a.alpha.count { s += abs(Int(a.alpha[i]) - Int(b.alpha[i])) }
        return Double(s) / Double(a.alpha.count)
    }

    /// Everything the checks usually want in one call: decode `source` and `output` (the output resampled to the source size when `allowResize`).
    struct Comparison {
        var source: RasterImage
        var output: RasterImage
        var psnr: Double
        var ssim: Double
        var alphaError: Double
        var sameSize: Bool
        var summary: String { String(format: "PSNR %.1f dB, SSIM %.4f%@", psnr, ssim, sameSize ? "" : " (resampled)") }
    }

    static func compare(source: URL, output: URL, allowResize: Bool = false, maxSide: Int? = nil, background: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)) -> Comparison? {
        guard let s = decode(source, maxSide: maxSide, background: background), var o = decode(output, largestFrame: true, maxSide: maxSide, background: background) else { return nil }
        var same = true
        if o.width != s.width || o.height != s.height {
            guard allowResize, let scaled = scaled(o, width: s.width, height: s.height) else { return nil }
            o = scaled; same = false
        }
        guard let p = psnr(s, o), let m = ssim(s, o) else { return nil }
        return Comparison(source: s, output: o, psnr: p, ssim: m, alphaError: same ? (alphaError(s, o) ?? 0) : 0, sameSize: same)
    }
}
