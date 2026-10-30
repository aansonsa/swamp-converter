import Foundation
import CoreGraphics

/// The eight ways to turn a picture without touching its pixel values: rotate clockwise by a multiple of 90 degrees, THEN mirror horizontally.
/// EXIF orientation values, the user's rotate / mirror options and their combination are all `Dihedral`s, so orientation, rotation and mirroring
/// cost one drawing pass together.
struct Dihedral: Equatable, Sendable {
    var rotation: Int
    var flipH: Bool

    static let identity = Dihedral(rotation: 0, flipH: false)
    var isIdentity: Bool { rotation == 0 && !flipH }
    /// True when width and height trade places.
    var swapsAxes: Bool { rotation == 90 || rotation == 270 }

    init(rotation: Int, flipH: Bool) {
        self.rotation = ((rotation % 360) + 360) % 360 / 90 * 90
        self.flipH = flipH
    }

    /// EXIF orientation 1...8 (values outside the range mean "upright").
    init(orientation: Int) {
        switch orientation {
        case 2: self.init(rotation: 0, flipH: true)
        case 3: self.init(rotation: 180, flipH: false)
        case 4: self.init(rotation: 180, flipH: true)     // mirror vertically = rotate 180 + mirror horizontally
        case 5: self.init(rotation: 90, flipH: true)
        case 6: self.init(rotation: 90, flipH: false)
        case 7: self.init(rotation: 270, flipH: true)
        case 8: self.init(rotation: 270, flipH: false)
        default: self.init(rotation: 0, flipH: false)
        }
    }

    /// The user's options: rotate clockwise, then mirror horizontally and / or vertically.
    init(rotation: Int, flipH: Bool, flipV: Bool) {
        let d = Dihedral(rotation: rotation, flipH: flipH)
        self = flipV ? d.then(Dihedral(rotation: 180, flipH: true)) : d
    }

    // Integer 2x2 matrices in a y-up plane: R90 clockwise = [[0,1],[-1,0]], mirror = [[-1,0],[0,1]].
    private typealias M = (a: Int, b: Int, c: Int, d: Int)
    private static func mul(_ p: M, _ q: M) -> M { (p.a * q.a + p.b * q.c, p.a * q.b + p.b * q.d, p.c * q.a + p.d * q.c, p.c * q.b + p.d * q.d) }
    private static let mirror: M = (-1, 0, 0, 1)
    private var matrix: M {
        var m: M = (1, 0, 0, 1)
        for _ in 0..<(rotation / 90) { m = Dihedral.mul((0, 1, -1, 0), m) }
        return flipH ? Dihedral.mul(Dihedral.mirror, m) : m
    }

    /// First `self`, then `next`.
    func then(_ next: Dihedral) -> Dihedral {
        var m = Dihedral.mul(next.matrix, matrix)
        let det = m.a * m.d - m.b * m.c
        let flipped = det < 0
        if flipped { m = Dihedral.mul(Dihedral.mirror, m) }
        switch (m.a, m.b, m.c, m.d) {
        case (1, 0, 0, 1): return Dihedral(rotation: 0, flipH: flipped)
        case (0, 1, -1, 0): return Dihedral(rotation: 90, flipH: flipped)
        case (-1, 0, 0, -1): return Dihedral(rotation: 180, flipH: flipped)
        default: return Dihedral(rotation: 270, flipH: flipped)
        }
    }

    /// Size of a `width x height` picture after the transform.
    func size(of width: Int, _ height: Int) -> (width: Int, height: Int) { swapsAxes ? (height, width) : (width, height) }
}

/// Bitmap contexts that keep what the source has: its colour space (RGB and gray), 16-bit depth and alpha.
enum ImageBitmap {
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// CMYK, Lab, indexed-from-ICC and other models that are neither RGB nor gray.
    static func isUnusualModel(_ image: CGImage) -> Bool {
        guard let m = image.colorSpace?.model else { return false }
        return m != .rgb && m != .monochrome
    }

    /// True when the picture is in a colour space other than sRGB that is not a gray one (gray pictures keep their gray space).
    static func needsSRGB(_ image: CGImage) -> Bool {
        guard let cs = image.colorSpace else { return false }
        return cs.model != .monochrome && name(cs) != name(sRGB)
    }

    static func name(_ cs: CGColorSpace?) -> String? { cs?.name as String? }

    /// A context for drawing into, in `override ?? template's` colour space. Falls back to 8-bit sRGB when the source space cannot back a bitmap.
    static func makeContext(width: Int, height: Int, template: CGImage, colorSpace override: CGColorSpace? = nil, alpha: Bool) -> CGContext? {
        guard width > 0, height > 0, width <= 200_000, height <= 200_000 else { return nil }
        let base = override ?? template.colorSpace
        let wide = template.bitsPerComponent > 8 && !template.bitmapInfo.contains(.floatComponents)
        if let b = base, b.model == .monochrome, !alpha {
            if let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: wide ? 16 : 8, bytesPerRow: 0, space: b,
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue | (wide ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) { return c }
        }
        if let b = base, b.model == .rgb, !b.isWideGamutRec2020 {
            let info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
            if wide, let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: b,
                                       bitmapInfo: info | CGBitmapInfo.byteOrder16Little.rawValue) { return c }
            if let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: b, bitmapInfo: info) { return c }
        }
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)
    }

    /// 8-bit RGBA copy of the picture (longest side limited to `maxSide`, aspect kept) for pixel scanning.
    static func rgba8(_ image: CGImage, maxSide: Int? = nil) -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        var w = image.width, h = image.height
        if let m = maxSide, max(w, h) > m { let s = Double(m) / Double(max(w, h)); w = max(1, Int((Double(w) * s).rounded())); h = max(1, Int((Double(h) * s).rounded())) }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data else { return nil }
        return (Data(bytes: p, count: ctx.bytesPerRow * h), w, h, ctx.bytesPerRow)
    }
}

private extension CGColorSpace {
    /// Wide spaces (Rec. 2020 / PQ / HLG) draw badly into integer bitmaps; they are developed to sRGB instead.
    var isWideGamutRec2020: Bool {
        guard let n = name as String? else { return false }
        return n.contains("2020") || n.contains("2100") || n.contains("PQ") || n.contains("HLG")
    }
}

@inline(__always) private func luma8(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
    let y: Int = 54 * Int(r) + 183 * Int(g) + 19 * Int(b)
    return UInt8(truncatingIfNeeded: y >> 8)
}

/// 16-bit samples are little-endian (the contexts are created with `byteOrder16Little`, which is the host order on Apple silicon).
@inline(__always) private func luma16(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> UInt16 {
    let y: Int = 54 * Int(r) + 183 * Int(g) + 19 * Int(b)
    return UInt16(truncatingIfNeeded: y >> 8)
}

enum ImageGeometry {
    /// One drawing pass: orientation / rotation / mirror (`d4`), resampling to `width x height` (the size AFTER the rotation, default: natural),
    /// optional colour-space conversion, flattening onto `flatten`, and grayscale. Returns nil when the bitmap cannot be allocated.
    /// Draws nothing and returns `image` itself when the request changes nothing.
    static func render(_ image: CGImage, _ d4: Dihedral = .identity, width: Int? = nil, height: Int? = nil, colorSpace: CGColorSpace? = nil,
                       flatten: CGColor? = nil, gray: Bool = false) -> CGImage? {
        let natural = d4.size(of: image.width, image.height)
        let outW = max(1, width ?? natural.width), outH = max(1, height ?? natural.height)
        let alphaIn = ImageBitmap.hasAlpha(image)
        let needsFlatten = flatten != nil && alphaIn
        let sameSpace = colorSpace == nil || ImageBitmap.name(colorSpace) == ImageBitmap.name(image.colorSpace)
        if d4.isIdentity, outW == image.width, outH == image.height, sameSpace, !needsFlatten, !gray { return image }

        let alphaOut = alphaIn && !needsFlatten
        guard let ctx = ImageBitmap.makeContext(width: outW, height: outH, template: image, colorSpace: colorSpace, alpha: alphaOut) else { return nil }
        if needsFlatten, let bg = flatten {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        // The picture is drawn into its own rectangle, rotated about the centre of the result, then mirrored.
        let drawW = CGFloat(d4.swapsAxes ? outH : outW), drawH = CGFloat(d4.swapsAxes ? outW : outH)
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        if d4.flipH { ctx.scaleBy(x: -1, y: 1) }
        if d4.rotation != 0 { ctx.rotate(by: -CGFloat(d4.rotation) * .pi / 180) }
        ctx.draw(image, in: CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH))
        guard gray else { return ctx.makeImage() }
        return grayscale(ctx, opaque: !alphaOut)
    }

    /// Rec. 709 luminance of every pixel (weights 54 / 183 / 19 out of 256). An opaque result becomes a true one-channel gray picture;
    /// pictures with transparency keep their RGBA layout with equal channels.
    private static func grayscale(_ ctx: CGContext, opaque: Bool) -> CGImage? {
        guard let data = ctx.data, ctx.colorSpace?.model != .monochrome else { return ctx.makeImage() }
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow, wide = ctx.bitsPerComponent == 16
        if opaque, let g = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
           let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: wide ? 16 : 8, bytesPerRow: 0, space: g,
                               bitmapInfo: CGImageAlphaInfo.none.rawValue | (wide ? CGBitmapInfo.byteOrder16Little.rawValue : 0)),
           let dst = out.data {
            let obpr = out.bytesPerRow
            for y in 0..<h {
                if y & 255 == 0, Task.isCancelled { return nil }
                if wide {
                    let s = (data + y * bpr).assumingMemoryBound(to: UInt16.self), d = (dst + y * obpr).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<w { d[x] = luma16(s[x * 4], s[x * 4 + 1], s[x * 4 + 2]) }
                } else {
                    let s = (data + y * bpr).assumingMemoryBound(to: UInt8.self), d = (dst + y * obpr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { d[x] = luma8(s[x * 4], s[x * 4 + 1], s[x * 4 + 2]) }
                }
            }
            return out.makeImage()
        }
        // Transparency: premultiplied channels combine linearly, so the same weights apply.
        for y in 0..<h {
            if wide {
                let s = (data + y * bpr).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w {
                    let v = luma16(s[x * 4], s[x * 4 + 1], s[x * 4 + 2])
                    s[x * 4] = v; s[x * 4 + 1] = v; s[x * 4 + 2] = v
                }
            } else {
                let s = (data + y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let v = luma8(s[x * 4], s[x * 4 + 1], s[x * 4 + 2])
                    s[x * 4] = v; s[x * 4 + 1] = v; s[x * 4 + 2] = v
                }
            }
        }
        return ctx.makeImage()
    }
}
