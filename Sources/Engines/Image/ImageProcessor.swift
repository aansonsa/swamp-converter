import Foundation
import CoreGraphics

/// The picture-changing options of `image.convert`, parsed once from resolved option values (inactive fields hold their neutral defaults).
struct ImageSpec: Sendable {
    var autoOrient = true
    var cropMode = "none"
    var cropRatio = "1:1"
    var cropAnchor = "center"
    var cropTrim = 8.0
    var cropX = 0, cropY = 0, cropW = 0, cropH = 0
    var rotate = 0
    var flipH = false
    var flipV = false
    var sizeMode = "original"
    var sizeLong = 2048
    var sizeW = 0, sizeH = 0
    var sizePercent = 50.0
    var sizeMegapixels = 4.0
    var upscale = false
    var colorSpace = "keep"
    var gray = false

    init() {}

    init(_ o: OptionValues) {
        typealias K = ImageKeys
        autoOrient = o.bool(K.autoOrient, true)
        cropMode = o.string(K.cropMode, "none")
        cropRatio = o.string(K.cropRatio, "1:1")
        cropAnchor = o.string(K.cropAnchor, "center")
        cropTrim = o.double(K.cropTrim, 8)
        cropX = o.int(K.cropX); cropY = o.int(K.cropY); cropW = o.int(K.cropW); cropH = o.int(K.cropH)
        rotate = ((o.int(K.rotate) % 360) + 360) % 360
        flipH = o.bool(K.flipH); flipV = o.bool(K.flipV)
        sizeMode = o.string(K.sizeMode, "original")
        sizeLong = o.int(K.sizeLong, 2048)
        sizeW = o.int(K.sizeWidth); sizeH = o.int(K.sizeHeight)
        sizePercent = o.double(K.sizePercent, 50)
        sizeMegapixels = o.double(K.sizeMegapixels, 4)
        upscale = o.bool(K.upscale)
        colorSpace = o.string(K.colorSpace, "keep")
        gray = o.bool(K.gray) || o.string(K.colorSpace, "keep") == "gray"
    }

    /// The same request for a sample `ratio` times the size of the real picture (Studio previews): absolute pixel numbers shrink with it.
    func scaled(by ratio: Double) -> ImageSpec {
        var s = self
        func f(_ v: Int) -> Int { v <= 0 ? v : max(1, Int((Double(v) * ratio).rounded())) }
        s.cropX = f(cropX); s.cropY = f(cropY); s.cropW = f(cropW); s.cropH = f(cropH)
        s.sizeLong = f(sizeLong); s.sizeW = f(sizeW); s.sizeH = f(sizeH)
        s.sizeMegapixels = sizeMegapixels * ratio * ratio
        return s
    }

    /// True when decoding at a reduced size cannot change the result: no crop, and a plain downscale by at least half.
    var allowsReducedDecode: Bool { cropMode == "none" && ["longEdge", "fit", "percent", "megapixels", "exact"].contains(sizeMode) }

    var targetColorSpace: CGColorSpace? {
        switch colorSpace {
        case "srgb": return CGColorSpace(name: CGColorSpace.sRGB)
        case "p3": return CGColorSpace(name: CGColorSpace.displayP3)
        case "adobe": return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        default: return nil
        }
    }

    /// Output size for a picture whose upright size is `w x h` (nil = unchanged), including the crop that happens first.
    func outputSize(width w: Int, height h: Int) -> (width: Int, height: Int) {
        var cw = w, ch = h
        switch cropMode {
        case "ratio": if let r = ImageCrop.ratio(cropRatio), let rect = ImageCrop.ratioRect(width: w, height: h, ratio: r, anchor: "center") { cw = Int(rect.width); ch = Int(rect.height) }
        case "rect": if let rect = ImageCrop.userRect(x: cropX, y: cropY, w: cropW, h: cropH, width: w, height: h) { cw = Int(rect.width); ch = Int(rect.height) }
        default: break
        }
        let d = Dihedral(rotation: rotate, flipH: flipH, flipV: flipV).size(of: cw, ch)
        if let t = ImageSizePlan.target(mode: sizeMode, width: d.width, height: d.height, longEdge: sizeLong, frameW: sizeW, frameH: sizeH,
                                        percent: sizePercent, megapixels: sizeMegapixels, upscale: upscale) { return (t.width, t.height) }
        return d
    }
}

enum ImageProcessor {
    /// Applies the options in the fixed order: orient -> crop -> rotate / mirror -> resize -> colour. Orientation, rotation, mirroring, resizing, colour space,
    /// flattening and grayscale share ONE drawing pass; only content-aware crops (and "fill") add a pass before it.
    /// `nominal` is the upright size of the real picture when `loaded` is a reduced decode of it (sizes are planned on `nominal`, so the result is exact).
    static func process(_ loaded: ImageLoader.Loaded, spec: ImageSpec, nominal: (width: Int, height: Int)? = nil, flatten: CGColor? = nil) throws -> CGImage {
        var img = loaded.image
        var d4 = spec.autoOrient ? Dihedral(orientation: loaded.orientation) : .identity

        if spec.cropMode != "none" {
            if !d4.isIdentity { img = try draw(img, d4); d4 = .identity }
            if let r = try cropRect(for: img, spec: spec), let c = img.cropping(to: r) { img = c }
        }
        d4 = d4.then(Dihedral(rotation: spec.rotate, flipH: spec.flipH, flipV: spec.flipV))

        let upright = d4.size(of: img.width, img.height)
        let basis = nominal.map { d4.size(of: $0.width, $0.height) } ?? upright
        var width: Int? = nil, height: Int? = nil
        if let t = ImageSizePlan.target(mode: spec.sizeMode, width: basis.width, height: basis.height, longEdge: spec.sizeLong, frameW: spec.sizeW, frameH: spec.sizeH,
                                        percent: spec.sizePercent, megapixels: spec.sizeMegapixels, upscale: spec.upscale) {
            if t.cropToFrame {
                if !d4.isIdentity { img = try draw(img, d4); d4 = .identity }
                if let r = ImageCrop.ratioRect(width: img.width, height: img.height, ratio: (Double(t.width), Double(t.height)), anchor: "center"), let c = img.cropping(to: r) { img = c }
            }
            width = t.width; height = t.height
        } else if nominal != nil {
            width = basis.width; height = basis.height
        }
        try Task.checkCancellation()
        // CMYK, Lab and other non-RGB, non-gray pictures become sRGB (a CMYK JPEG or HEIC is read inverted or not at all by many viewers).
        let space = spec.targetColorSpace ?? (ImageBitmap.isUnusualModel(img) ? ImageBitmap.sRGB : nil)
        guard let out = ImageGeometry.render(img, d4, width: width, height: height, colorSpace: space, flatten: flatten, gray: spec.gray) else {
            throw ImageLoader.outOfMemory()
        }
        return out
    }

    private static func draw(_ image: CGImage, _ d4: Dihedral) throws -> CGImage {
        guard let out = ImageGeometry.render(image, d4) else { throw ImageLoader.outOfMemory() }
        return out
    }

    private static func cropRect(for img: CGImage, spec: ImageSpec) throws -> CGRect? {
        switch spec.cropMode {
        case "ratio":
            guard let r = ImageCrop.ratio(spec.cropRatio) else { return nil }
            let subject = spec.cropAnchor == "subject" ? ImageCrop.subjectBox(of: img) : nil
            return ImageCrop.ratioRect(width: img.width, height: img.height, ratio: r, anchor: spec.cropAnchor, subject: subject)
        case "autoTrim": return try ImageCrop.trimRect(of: img, tolerance: spec.cropTrim)
        case "rect": return ImageCrop.userRect(x: spec.cropX, y: spec.cropY, w: spec.cropW, h: spec.cropH, width: img.width, height: img.height)
        default: return nil
        }
    }
}
