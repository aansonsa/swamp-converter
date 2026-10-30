import Foundation
import CoreImage
import CoreGraphics

// The CoreImage side of the picture plan: crop, rotate, flip, scale, borders, colour, noise, sharpness, watermark and burned-in text for ONE frame.
// Used by the AVFoundation export (no ffmpeg) frame by frame, and by the Studio preview when ffmpeg is missing. CoreImage's origin is the
// bottom-left corner; the plan speaks in top-left pixels, so every rectangle is flipped here.

enum VideoCI {
    static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    static func even(_ v: Int) -> Int { max(2, (v / 2) * 2) }

    static func rgb(_ hex: String) -> CIColor {
        let c = VideoOverlayRenderer.color(hex)
        return CIColor(cgColor: c)
    }

    /// Moves the image so its extent starts at (0, 0).
    static func normalized(_ i: CIImage) -> CIImage {
        i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
    }

    /// Geometry and colour of the plan applied to an upright frame. The result starts at (0, 0) and has exactly `outputSize` (even numbers).
    static func process(_ frame: CIImage, picture p: VideoPicturePlan, outputSize: (w: Int, h: Int)?) -> CIImage {
        var img = normalized(frame)
        // Crop (plan: top-left pixels).
        if let c = p.crop, c.w > 0 {
            let H = img.extent.height
            img = normalized(img.cropped(to: CGRect(x: CGFloat(c.x), y: H - CGFloat(c.y + c.h), width: CGFloat(c.w), height: CGFloat(c.h))))
        }
        // Rotate clockwise, then flip.
        switch p.rotate {
        case 90: img = normalized(img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2)))
        case 180: img = normalized(img.transformed(by: CGAffineTransform(rotationAngle: .pi)))
        case 270: img = normalized(img.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)))
        default: break
        }
        if p.flipH { img = normalized(img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if p.flipV { img = normalized(img.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }

        // Clean-up before scaling (as in the ffmpeg chain).
        if p.denoise > 0 {
            let level = [0.015, 0.03, 0.06][p.denoise - 1]
            img = img.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": level, "inputSharpness": 0.4]).cropped(to: img.extent)
        }
        // Size.
        if let s = p.scale {
            img = scaled(img, to: s, cover: p.scaleCover, anchor: p.anchor, point: p.anchorPoint)
        }
        if p.sharpen > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": [0.3, 0.6, 1.1][p.sharpen - 1]]).cropped(to: img.extent)
        }
        // Borders.
        if let canvas = p.padCanvas, p.pad != nil {
            let bg = CIImage(color: rgb(p.padColor)).cropped(to: CGRect(x: 0, y: 0, width: canvas.w, height: canvas.h))
            let dx = (CGFloat(canvas.w) - img.extent.width) / 2, dy = (CGFloat(canvas.h) - img.extent.height) / 2
            img = img.transformed(by: CGAffineTransform(translationX: dx.rounded(), y: dy.rounded())).composited(over: bg).cropped(to: bg.extent)
        } else if p.pad == "border", let b = p.padBorder {
            let w = img.extent.width + CGFloat(b.l + b.r), h = img.extent.height + CGFloat(b.t + b.b)
            let bg = CIImage(color: rgb(p.padColor)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            img = img.transformed(by: CGAffineTransform(translationX: CGFloat(b.l), y: CGFloat(b.b))).composited(over: bg).cropped(to: bg.extent)
        }
        // Colour.
        if abs(p.brightness) > 0.0005 || abs(p.contrast - 1) > 0.0005 || abs(p.saturation - 1) > 0.0005 || p.gray {
            img = img.applyingFilter("CIColorControls", parameters: ["inputBrightness": p.brightness, "inputContrast": p.contrast, "inputSaturation": p.gray ? 0 : p.saturation])
        }
        if abs(p.gamma - 1) > 0.0005 { img = img.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / max(p.gamma, 0.1)]) }
        if let k = p.colorTemp {
            img = img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: CGFloat(k), y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        // Final canvas: exactly the output size.
        let w = even(outputSize?.w ?? Int(img.extent.width)), h = even(outputSize?.h ?? Int(img.extent.height))
        return normalized(img).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func scaled(_ img: CIImage, to s: (w: Int, h: Int), cover: Bool, anchor: String, point: (x: Double, y: Double)?) -> CIImage {
        let W = img.extent.width, H = img.extent.height
        guard W > 0, H > 0 else { return img }
        func lanczos(_ i: CIImage, sx: CGFloat, sy: CGFloat) -> CIImage {
            i.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy]).cropped(to: CGRect(x: 0, y: 0, width: (W * sx).rounded(), height: (H * sy).rounded()))
        }
        if cover {
            let f = max(CGFloat(s.w) / W, CGFloat(s.h) / H)
            let big = normalized(lanczos(img, sx: f, sy: f))
            let bw = big.extent.width, bh = big.extent.height
            var x = (bw - CGFloat(s.w)) / 2, y = (bh - CGFloat(s.h)) / 2     // y in CI (bottom-left) coordinates
            if let p = point, anchor == "smart" {
                x = min(max(0, bw * CGFloat(p.x) - CGFloat(s.w) / 2), bw - CGFloat(s.w))
                y = min(max(0, bh * CGFloat(1 - p.y) - CGFloat(s.h) / 2), bh - CGFloat(s.h))
            } else {
                switch anchor {
                case "top": y = bh - CGFloat(s.h)
                case "bottom": y = 0
                case "left": x = 0
                case "right": x = bw - CGFloat(s.w)
                default: break
                }
            }
            return normalized(big.cropped(to: CGRect(x: x.rounded(), y: y.rounded(), width: CGFloat(s.w), height: CGFloat(s.h))))
        }
        return normalized(lanczos(img, sx: CGFloat(s.w) / W, sy: CGFloat(s.h) / H))
    }

    // MARK: Overlays

    /// A watermark image positioned like the ffmpeg `overlay` expression, as a CIImage ready to composite.
    static func placed(_ overlay: CGImage, in size: (w: Int, h: Int), position: String, margin: Int, opacity: Double, width: Int?) -> CIImage {
        var ci = CIImage(cgImage: overlay)
        if let w = width, w > 0, ci.extent.width > 0 {
            let f = CGFloat(w) / ci.extent.width
            ci = ci.transformed(by: CGAffineTransform(scaleX: f, y: f))
        }
        if opacity < 0.999 {
            ci = ci.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, min(1, opacity))))])
        }
        let ow = ci.extent.width, oh = ci.extent.height
        let W = CGFloat(size.w), H = CGFloat(size.h), m = CGFloat(margin)
        let x: CGFloat, y: CGFloat      // CI coordinates (bottom-left origin)
        switch position {
        case "tl": x = m; y = H - oh - m
        case "tr": x = W - ow - m; y = H - oh - m
        case "bl": x = m; y = m
        case "center": x = (W - ow) / 2; y = (H - oh) / 2
        default: x = W - ow - m; y = m
        }
        return normalized(ci).transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    static func cgImage(_ ci: CIImage) -> CGImage? {
        context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
