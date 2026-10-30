import Foundation
import CoreGraphics

/// Reduces an opaque picture to a 256-colour palette ("lossy PNG"): an exact palette when the picture has at most 256 colours, otherwise median cut on a 5-bit
/// histogram with Floyd-Steinberg error diffusion. The result is an indexed `CGImage`, which ImageIO writes as a palette PNG (colour type 3).
/// Palette PNGs carry no colour profile, so the colours are converted to sRGB first (a Display P3 photo would otherwise lose its profile and shift).
enum ImageQuantizer {
    /// nil when the picture is not a candidate: it has translucent pixels (a palette without alpha would damage them) or is not RGB.
    static func quantize(_ image: CGImage) throws -> CGImage? {
        guard image.width > 0, image.height > 0, image.width * image.height <= 120_000_000 else { return nil }
        if let cs = image.colorSpace, cs.model != .rgb { return nil }
        let base = ImageBitmap.sRGB
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: base, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: ImageBitmap.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let space = ctx.colorSpace else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return nil }
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let bpr = ctx.bytesPerRow

        // Exact palette first (cheap for flat graphics, bails out quickly for photographs).
        var exact: [UInt32: UInt8] = [:]
        var order: [UInt32] = []
        var tooMany = false
        for y in 0..<h {
            if y & 127 == 0 { try Task.checkCancellation() }
            let row = px + y * bpr
            for x in 0..<w {
                let o = x * 4
                if row[o + 3] != 255 { return nil }
                if !tooMany {
                    let key = UInt32(row[o]) << 16 | UInt32(row[o + 1]) << 8 | UInt32(row[o + 2])
                    if exact[key] == nil {
                        if order.count == 256 { tooMany = true } else { exact[key] = UInt8(order.count); order.append(key) }
                    }
                }
            }
        }
        var indices = [UInt8](repeating: 0, count: w * h)
        var palette: [UInt8] = []
        if !tooMany {
            for key in order { palette += [UInt8(key >> 16 & 255), UInt8(key >> 8 & 255), UInt8(key & 255)] }
            for y in 0..<h {
                let row = px + y * bpr
                for x in 0..<w { indices[y * w + x] = exact[UInt32(row[x * 4]) << 16 | UInt32(row[x * 4 + 1]) << 8 | UInt32(row[x * 4 + 2])] ?? 0 }
            }
        } else {
            let built = try buildPalette(px, width: w, height: h, bytesPerRow: bpr)
            palette = built.palette
            try dither(px, width: w, height: h, bytesPerRow: bpr, palette: built.palette, into: &indices)
        }
        let count = palette.count / 3
        guard count > 0, let indexed = CGColorSpace(indexedBaseSpace: space, last: count - 1, colorTable: palette),
              let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: indexed, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Palette (median cut + k-means refinement)

    /// Bits per channel of the histogram that palette and dithering work on (6 bits: 64 levels, 262 144 bins).
    private static let histBits = 6
    private static let histSize = 1 << (3 * histBits)
    /// Perceptual weights of the colour distance (green counts most), as small integers.
    private static let wr = 2, wg = 4, wb = 3

    @inline(__always) private static func bin(_ r: Int, _ g: Int, _ b: Int) -> Int { (r >> 2) << 12 | (g >> 2) << 6 | (b >> 2) }

    private struct Box {
        var bins: [Int32]
        var count: Int
        var lo = (r: 63, g: 63, b: 63), hi = (r: 0, g: 0, b: 0)
    }

    /// 256 colours: median cut over the histogram, then a few k-means (Lloyd) passes that move every colour to the centre of the pixels it serves.
    /// Returns the palette (RGB triples) and the histogram so the dithering pass can build its nearest-colour lookup on demand.
    private static func buildPalette(_ px: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow bpr: Int) throws -> (palette: [UInt8], hist: Histogram) {
        var hist = Histogram()
        for y in 0..<h {
            if y & 127 == 0 { try Task.checkCancellation() }
            let row = px + y * bpr
            for x in 0..<w {
                let r = Int(row[x * 4]), g = Int(row[x * 4 + 1]), b = Int(row[x * 4 + 2])
                let k = bin(r, g, b)
                hist.count[k] += 1; hist.sr[k] += r; hist.sg[k] += g; hist.sb[k] += b
            }
        }
        let used = (0..<histSize).filter { hist.count[$0] > 0 }.map { Int32($0) }
        func bounds(_ bins: [Int32]) -> Box {
            var box = Box(bins: bins, count: 0)
            for k32 in bins {
                let k = Int(k32), r = k >> 12, g = (k >> 6) & 63, b = k & 63
                box.count += hist.count[k]
                box.lo = (min(box.lo.r, r), min(box.lo.g, g), min(box.lo.b, b)); box.hi = (max(box.hi.r, r), max(box.hi.g, g), max(box.hi.b, b))
            }
            return box
        }
        /// How much splitting this box helps: pixels in it times its weighted extent.
        func score(_ b: Box) -> Double {
            b.bins.count < 2 ? -1 : Double(b.count) * Double(max((b.hi.r - b.lo.r) * wr, (b.hi.g - b.lo.g) * wg, (b.hi.b - b.lo.b) * wb) + 1)
        }
        var boxes = [bounds(used)]
        while boxes.count < 256 {
            if boxes.count & 31 == 0 { try Task.checkCancellation() }
            guard let (i, best) = boxes.enumerated().max(by: { score($0.element) < score($1.element) }), score(best) > 0 else { break }
            let rr = (best.hi.r - best.lo.r) * wr, gg = (best.hi.g - best.lo.g) * wg, bb = (best.hi.b - best.lo.b) * wb
            func channel(_ k: Int32) -> Int { rr >= gg && rr >= bb ? Int(k) >> 12 : (gg >= bb ? (Int(k) >> 6) & 63 : Int(k) & 63) }
            let sorted = best.bins.sorted { channel($0) < channel($1) }
            var acc = 0, cut = 1
            for (k, bin) in sorted.enumerated() { acc += hist.count[Int(bin)]; if acc * 2 >= best.count { cut = max(1, min(sorted.count - 1, k + 1)); break } }
            boxes[i] = bounds(Array(sorted[..<cut]))
            boxes.append(bounds(Array(sorted[cut...])))
        }
        // Box averages are the starting colours.
        var centres: [(r: Double, g: Double, b: Double)] = boxes.map { box in
            var r = 0, g = 0, bl = 0
            for k in box.bins { r += hist.sr[Int(k)]; g += hist.sg[Int(k)]; bl += hist.sb[Int(k)] }
            let n = Double(max(1, box.count))
            return (Double(r) / n, Double(g) / n, Double(bl) / n)
        }
        // Lloyd passes over the used bins (each bin counts with its pixel count).
        let binColour: [(r: Double, g: Double, b: Double, n: Double)] = used.map { k in
            let c = Double(hist.count[Int(k)])
            return (Double(hist.sr[Int(k)]) / c, Double(hist.sg[Int(k)]) / c, Double(hist.sb[Int(k)]) / c, c)
        }
        for _ in 0..<4 {
            try Task.checkCancellation()
            var sum = [(r: Double, g: Double, b: Double, n: Double)](repeating: (0, 0, 0, 0), count: centres.count)
            for c in binColour {
                var bi = 0, bd = Double.greatestFiniteMagnitude
                for (j, p) in centres.enumerated() {
                    let dr = c.r - p.r, dg = c.g - p.g, db = c.b - p.b
                    let d = Double(wr) * dr * dr + Double(wg) * dg * dg + Double(wb) * db * db
                    if d < bd { bd = d; bi = j }
                }
                sum[bi].r += c.r * c.n; sum[bi].g += c.g * c.n; sum[bi].b += c.b * c.n; sum[bi].n += c.n
            }
            for j in 0..<centres.count where sum[j].n > 0 { centres[j] = (sum[j].r / sum[j].n, sum[j].g / sum[j].n, sum[j].b / sum[j].n) }
        }
        var palette: [UInt8] = []
        for c in centres { palette += [UInt8(min(255, max(0, c.r.rounded()))), UInt8(min(255, max(0, c.g.rounded()))), UInt8(min(255, max(0, c.b.rounded())))] }
        return (palette, hist)
    }

    /// Pixel counts and colour sums per histogram bin.
    private struct Histogram {
        var count = [Int](repeating: 0, count: ImageQuantizer.histSize)
        var sr = [Int](repeating: 0, count: ImageQuantizer.histSize), sg = [Int](repeating: 0, count: ImageQuantizer.histSize), sb = [Int](repeating: 0, count: ImageQuantizer.histSize)
    }

    /// Floyd-Steinberg: the rounding error of each pixel is passed on to its right and lower neighbours (serpentine scan, error clamped so a hard edge cannot smear).
    /// The nearest palette colour of a 6-bit bin is found on first use and remembered.
    private static func dither(_ px: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow bpr: Int, palette: [UInt8], into out: inout [UInt8]) throws {
        var lut = [Int16](repeating: -1, count: histSize)
        let n = palette.count / 3
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
            let k = bin(r, g, b)
            let cached = lut[k]
            if cached >= 0 { return Int(cached) }
            // Centre of the bin, not its corner.
            let cr = (r & ~3) | 2, cg = (g & ~3) | 2, cb = (b & ~3) | 2
            var best = 0, bestD = Int.max
            for i in 0..<n {
                let dr = cr - Int(palette[i * 3]), dg = cg - Int(palette[i * 3 + 1]), db = cb - Int(palette[i * 3 + 2])
                let d = wr * dr * dr + wg * dg * dg + wb * db * db
                if d < bestD { bestD = d; best = i }
            }
            lut[k] = Int16(best)
            return best
        }
        var cur = [Int32](repeating: 0, count: (w + 2) * 3), next = cur
        for y in 0..<h {
            if y & 63 == 0 { try Task.checkCancellation() }
            let row = px + y * bpr
            let leftToRight = y % 2 == 0
            for step in 0..<w {
                let x = leftToRight ? step : w - 1 - step
                let c0 = min(255, max(0, Int(row[x * 4]) + Int(cur[(x + 1) * 3]) / 16))
                let c1 = min(255, max(0, Int(row[x * 4 + 1]) + Int(cur[(x + 1) * 3 + 1]) / 16))
                let c2 = min(255, max(0, Int(row[x * 4 + 2]) + Int(cur[(x + 1) * 3 + 2]) / 16))
                let idx = nearest(c0, c1, c2)
                out[y * w + x] = UInt8(idx)
                let e0 = Int32(max(-64, min(64, c0 - Int(palette[idx * 3])))), e1 = Int32(max(-64, min(64, c1 - Int(palette[idx * 3 + 1])))), e2 = Int32(max(-64, min(64, c2 - Int(palette[idx * 3 + 2]))))
                // Mirror the kernel on right-to-left rows.
                let ahead = leftToRight ? (x + 2) * 3 : x * 3, behind = leftToRight ? x * 3 : (x + 2) * 3, below = (x + 1) * 3
                cur[ahead] += e0 * 7; cur[ahead + 1] += e1 * 7; cur[ahead + 2] += e2 * 7
                next[behind] += e0 * 3; next[behind + 1] += e1 * 3; next[behind + 2] += e2 * 3
                next[below] += e0 * 5; next[below + 1] += e1 * 5; next[below + 2] += e2 * 5
                next[ahead] += e0; next[ahead + 1] += e1; next[ahead + 2] += e2
            }
            swap(&cur, &next)
            for i in 0..<next.count { next[i] = 0 }
        }
    }
}
