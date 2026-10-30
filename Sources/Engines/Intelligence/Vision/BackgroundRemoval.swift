import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
@preconcurrency import Vision

// C. Background removal with Vision (VNGenerateForegroundInstanceMaskRequest). The mask comes from Vision, the compositing is Core Image: the original pixels
// are never resampled (only a deliberate max-pixel downscale changes the size), the cut-out keeps the picture's colour space.

enum VisionCapabilities {
    /// Registers `native.vision.foreground`: the request has a revision on this Mac. A cheap property read (no model is loaded); the self-test runs the real thing.
    static func register() {
        Capabilities.shared.register("native.vision.foreground") { !VNGenerateForegroundInstanceMaskRequest.supportedRevisions.isEmpty }
    }
}

struct CutoutOptions: Equatable, Sendable {
    /// Crop the result to the bounding box of the subject (+ `padding` px).
    var cropToSubject = false
    var padding = 0
    /// "#RRGGBB" fill instead of transparency (nil = transparent).
    var backgroundHex: String? = nil
    /// Feather the mask edge by this many pixels (0 = hard).
    var feather = 0
    /// Which instances to keep (nil = all foreground instances). Vision numbers the subjects 1, 2, 3 ...
    var instanceIndexes: Set<Int>? = nil
    /// Scale the picture down so its longest side is at most this many pixels before anything else happens (0 = keep the size; pictures above
    /// `CutoutEngine.hardLimit` (8192 px: the float mask alone is 200 MB there) are always reduced to it so a 100-megapixel panorama cannot exhaust memory).
    var maxPixel = 0
}

enum CutoutEngine {
    static let hardLimit = 8_192

    /// Foreground instance mask -> RGBA cutout. Runs on the Neural Engine / GPU; loads Vision on first call; every heavy step returns to the caller at once when the
    /// task is cancelled (the running request is cancelled too). Throws a calm `ConversionError.message` ("No subject was found in the picture") when the mask is empty.
    static func cutout(_ image: CGImage, options: CutoutOptions) async throws -> CGImage {
        try Task.checkCancellation()
        let limit = options.maxPixel > 0 ? min(options.maxPixel, hardLimit) : hardLimit
        let source = try await CancellableWork.run { scaledDown(image, longestSide: limit) }
        let mask = try await foregroundMask(of: source, instances: options.instanceIndexes)
        return try await CancellableWork.run { try compose(source, mask: mask, options: options) }
    }

    // MARK: Vision

    struct Mask: @unchecked Sendable {
        var buffer: CVPixelBuffer
        /// Bounding box of the subject in image pixels, origin top-left, width/height inclusive of the last pixel.
        var bounds: CGRect
    }

    private static let noSubject = ConversionError.message(L10n("No subject was found in the picture. Try a picture where one person, animal or object stands out.",
                                                              "На картинке не найден объект. Попробуйте изображение, где чётко выделяется человек, животное или предмет."))

    static func foregroundMask(of image: CGImage, instances: Set<Int>?) async throws -> Mask {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let requestBox = UncheckedBox(value: request)
        return try await CancellableWork.run(onCancel: { requestBox.value.cancel() }) {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw noSubject }
            var keep = observation.allInstances
            if let wanted = instances, !wanted.isEmpty {
                keep = keep.filteredIndexSet { wanted.contains($0) }
                if keep.isEmpty {
                    throw ConversionError.message(L10n("The picture has \(observation.allInstances.count) subject(s); the numbers you chose do not exist. Leave the field empty to keep all.",
                                                       "На картинке объектов: \(observation.allInstances.count). Выбранных номеров нет. Оставьте поле пустым, чтобы взять все."))
                }
            }
            let buffer = try observation.generateScaledMaskForImage(forInstances: keep, from: handler)
            guard let bounds = bounds(of: buffer) else { throw noSubject }
            return Mask(buffer: buffer, bounds: bounds)
        }
    }

    /// Bounding box of the pixels above 0.5 in a one-component float mask (nil when the mask is empty).
    static func bounds(of buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            var hit = false
            for x in 0..<w where row[x] > 0.5 {
                hit = true
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            if hit { if y < minY { minY = y }; maxY = y }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: Compositing

    private static func compose(_ image: CGImage, mask: Mask, options: CutoutOptions) throws -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var maskImage = CIImage(cvPixelBuffer: mask.buffer)
        if options.feather > 0 {
            maskImage = maskImage.clampedToExtent().applyingGaussianBlur(sigma: Double(options.feather) / 2).cropped(to: extent)
        }
        let source = CIImage(cgImage: image)
        let fill: CIImage = {
            guard let hex = options.backgroundHex, let c = rgb(fromHex: hex) else { return CIImage(color: .clear) }
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
        }()
        let blended = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: fill.cropped(to: extent), kCIInputMaskImageKey: maskImage])

        // Output canvas in Core Image coordinates (origin bottom-left).
        var canvas = extent
        if options.cropToSubject {
            let b = mask.bounds
            let ci = CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height)
            canvas = ci.insetBy(dx: -CGFloat(max(options.padding, 0)), dy: -CGFloat(max(options.padding, 0)))
        }
        let final = blended.composited(over: fill.cropped(to: canvas)).cropped(to: canvas)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let out = context.createCGImage(final, from: canvas, format: .RGBA8, colorSpace: space) else { throw ConversionError.noOutput }
        return out
    }

    static func rgb(fromHex hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let t = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return (CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255)
    }

    // MARK: Scaling

    static func scaledDown(_ image: CGImage, longestSide limit: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard limit > 0, longest > limit else { return image }
        let scale = Double(limit) / Double(longest)
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        // Gray / CMYK colour spaces cannot back a premultiplied RGBA context: those pictures are drawn in sRGB.
        guard let ctx = image.colorSpace.flatMap({ CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: info) })
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
