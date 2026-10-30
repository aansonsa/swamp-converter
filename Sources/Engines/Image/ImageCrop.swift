import Foundation
import CoreGraphics
import Vision

/// Crop windows and target sizes. Pure functions on pixel numbers, except the two content-aware ones (trim, subject) which look at pixels.
/// All rectangles use pixel coordinates with the origin at the TOP-LEFT of the picture (what `CGImage.cropping(to:)` expects).
enum ImageCrop {
    /// "16:9" -> (16, 9).
    static func ratio(_ text: String) -> (w: Double, h: Double)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 else { return nil }
        return (a, b)
    }

    /// The largest window of aspect ratio `ratio` that fits `width x height`, placed by `anchor` (center, top, bottom, left, right) or around `subject`.
    /// nil when the picture already has that ratio (within a pixel).
    static func ratioRect(width: Int, height: Int, ratio: (w: Double, h: Double), anchor: String, subject: CGRect? = nil) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        let target = ratio.w / ratio.h
        var nw = width, nh = height
        if Double(width) / Double(height) > target { nw = max(1, min(width, Int((Double(height) * target).rounded()))) }
        else { nh = max(1, min(height, Int((Double(width) / target).rounded()))) }
        if nw == width && nh == height { return nil }
        var x = (width - nw) / 2, y = (height - nh) / 2
        switch anchor {
        case "top": y = 0
        case "bottom": y = height - nh
        case "left": x = 0
        case "right": x = width - nw
        case "subject":
            if let s = subject {
                x = Int((s.midX - Double(nw) / 2).rounded()); y = Int((s.midY - Double(nh) / 2).rounded())
            }
        default: break
        }
        x = min(max(0, x), width - nw); y = min(max(0, y), height - nh)
        return CGRect(x: x, y: y, width: nw, height: nh)
    }

    /// A user rectangle clamped to the picture. A zero width / height means "to the edge". nil when it covers everything or lies outside.
    static func userRect(x: Int, y: Int, w: Int, h: Int, width: Int, height: Int) -> CGRect? {
        let x0 = min(max(0, x), width - 1), y0 = min(max(0, y), height - 1)
        let x1 = w <= 0 ? width : min(width, x0 + w), y1 = h <= 0 ? height : min(height, y0 + h)
        guard x1 > x0, y1 > y0 else { return nil }
        let r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return (r.width == CGFloat(width) && r.height == CGFloat(height)) ? nil : r
    }

    /// Removes borders of one colour (the colour of the top-left pixel; transparent borders count as one colour). `tolerance` is a percentage of the
    /// channel range. nil when there is nothing to remove or the whole picture is uniform. Big pictures are scanned at reduced size.
    static func trimRect(of image: CGImage, tolerance: Double) throws -> CGRect? {
        let scan = image.width * image.height > 24_000_000 ? 4096 : nil
        guard let px = ImageBitmap.rgba8(image, maxSide: scan) else { return nil }
        let w = px.width, h = px.height, bpr = px.bytesPerRow
        let thr = Int((max(0, min(50, tolerance)) / 100 * 255).rounded())
        return try px.data.withUnsafeBytes { raw -> CGRect? in
            let p = raw.bindMemory(to: UInt8.self)
            let b0 = Int(p[0]), b1 = Int(p[1]), b2 = Int(p[2]), b3 = Int(p[3])
            @inline(__always) func same(_ o: Int) -> Bool {
                if b3 == 0 && p[o + 3] == 0 { return true }
                return abs(Int(p[o]) - b0) <= thr && abs(Int(p[o + 1]) - b1) <= thr && abs(Int(p[o + 2]) - b2) <= thr && abs(Int(p[o + 3]) - b3) <= thr
            }
            func rowIsBorder(_ y: Int) -> Bool { var o = y * bpr; for _ in 0..<w { if !same(o) { return false }; o += 4 }; return true }
            var top = 0
            while top < h, rowIsBorder(top) { top += 1; if top & 63 == 0 { try Task.checkCancellation() } }
            if top == h { return nil }
            var bottom = h - 1
            while bottom > top, rowIsBorder(bottom) { bottom -= 1 }
            func colIsBorder(_ x: Int) -> Bool { for y in top...bottom { if !same(y * bpr + x * 4) { return false } }; return true }
            var left = 0
            while left < w, colIsBorder(left) { left += 1; if left & 63 == 0 { try Task.checkCancellation() } }
            var right = w - 1
            while right > left, colIsBorder(right) { right -= 1 }
            if top == 0 && left == 0 && bottom == h - 1 && right == w - 1 { return nil }
            // Back to full-size pixels; one scan pixel of safety when the scan was reduced.
            let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
            let pad = scan == nil ? 0 : 1
            let x0 = max(0, Int((Double(left - pad) * sx).rounded(.down))), y0 = max(0, Int((Double(top - pad) * sy).rounded(.down)))
            let x1 = min(image.width, Int((Double(right + 1 + pad) * sx).rounded(.up))), y1 = min(image.height, Int((Double(bottom + 1 + pad) * sy).rounded(.up)))
            guard x1 > x0, y1 > y0 else { return nil }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    /// The most eye-catching area (attention saliency of Vision, computed on this Mac) in pixel coordinates, or nil when Vision finds nothing.
    static func subjectBox(of image: CGImage) -> CGRect? {
        let small: CGImage
        if max(image.width, image.height) > 640, let s = ImageGeometry.render(image, .identity, width: max(1, image.width * 640 / max(image.width, image.height)),
                                                                              height: max(1, image.height * 640 / max(image.width, image.height))) { small = s } else { small = image }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        request.revision = VNGenerateAttentionBasedSaliencyImageRequestRevision2
        guard (try? VNImageRequestHandler(cgImage: small, options: [:]).perform([request])) != nil,
              let box = request.results?.first?.salientObjects?.first?.boundingBox, !box.isEmpty else { return nil }
        let w = Double(image.width), h = Double(image.height)
        return CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
    }
}

/// Target sizes for the `img.size.mode` options.
enum ImageSizePlan {
    struct Target: Equatable {
        var width: Int
        var height: Int
        /// Fill mode: crop the source to the aspect ratio of the frame first.
        var cropToFrame = false
    }

    /// Output size for a picture of `w x h`, or nil when the options leave it as it is.
    static func target(mode: String, width w: Int, height h: Int, longEdge: Int, frameW: Int, frameH: Int, percent: Double, megapixels: Double, upscale: Bool) -> Target? {
        guard w > 0, h > 0 else { return nil }
        func dims(_ s: Double) -> Target { Target(width: max(1, Int((Double(w) * s).rounded())), height: max(1, Int((Double(h) * s).rounded()))) }
        switch mode {
        case "longEdge":
            let long = max(1, longEdge)
            let s = Double(long) / Double(max(w, h))
            if s == 1 || (s > 1 && !upscale) { return nil }
            var t = dims(s)
            if w >= h { t.width = long } else { t.height = long }
            return t
        case "fit":
            guard frameW > 0 || frameH > 0 else { return nil }
            let sw = frameW > 0 ? Double(frameW) / Double(w) : .infinity, sh = frameH > 0 ? Double(frameH) / Double(h) : .infinity
            let s = min(sw, sh)
            if s == 1 || (s > 1 && !upscale) { return nil }
            return dims(s)
        case "exact":
            guard frameW > 0 || frameH > 0 else { return nil }
            let tw = frameW > 0 ? frameW : max(1, Int((Double(frameH) * Double(w) / Double(h)).rounded()))
            let th = frameH > 0 ? frameH : max(1, Int((Double(frameW) * Double(h) / Double(w)).rounded()))
            return (tw == w && th == h) ? nil : Target(width: tw, height: th)
        case "fill":
            guard frameW > 0 && frameH > 0 else { return target(mode: "exact", width: w, height: h, longEdge: longEdge, frameW: frameW, frameH: frameH, percent: percent, megapixels: megapixels, upscale: upscale) }
            return Target(width: frameW, height: frameH, cropToFrame: true)
        case "percent":
            let s = max(0.01, percent / 100)
            return s == 1 ? nil : dims(s)
        case "megapixels":
            let s = (max(0.01, megapixels) * 1_000_000 / (Double(w) * Double(h))).squareRoot()
            if abs(s - 1) < 0.0005 || (s > 1 && !upscale) { return nil }
            return dims(s)
        default:
            return nil
        }
    }
}
