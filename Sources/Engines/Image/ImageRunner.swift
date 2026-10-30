import Foundation
import ImageIO
import CoreGraphics

/// Runs ONE picture through the whole chain: decode -> orient -> crop -> rotate / mirror -> resize -> colour -> metadata -> encode -> atomic output.
/// The behaviour is a pure function of the resolved options; the operation's id is never consulted.
enum ImageRunner {
    /// What the options mean for one concrete file.
    struct Plan {
        var format: String
        var spec: ImageSpec
        /// True when the EXIF rotation is baked into the pixels (always, unless the user turned it off AND the format can store the tag).
        var bakeOrientation: Bool
        var flatten: CGColor?
        var frames: String
    }

    static func plan(for item: FileItem, options o: OptionValues) -> Plan {
        let chosen = o.string(ImageKeys.format, "jpeg")
        let format = chosen == "same" ? ImageFormat.sameFormat(forKey: item.key) : ImageFormat.canonical(chosen)
        var spec = ImageSpec(o)
        let bake = spec.autoOrient || !ImageFormat.carriesOrientation(format)
        spec.autoOrient = bake
        let flatten: CGColor? = ImageFormat.supportsAlpha(format) ? nil : ImageFormat.color(hex: o.string(ImageKeys.alphaBackground, "#FFFFFF"))
        return Plan(format: format, spec: spec, bakeOrientation: bake, flatten: flatten, frames: o.string(ImageKeys.frames, "first"))
    }

    static func run(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice, suffix: L10n?) async throws -> [URL] {
        let o = ctx.options
        let plan = plan(for: item, options: o)
        if plan.format == "webp", !ctx.tools.has(.cwebp) { throw ConversionError.toolMissing(.cwebp) }
        guard ImageFormat.known.contains(plan.format) else {
            throw ConversionError.unsupported(L10n("The format \(plan.format.uppercased()) cannot be written.", "Формат \(plan.format.uppercased()) нельзя записать."))
        }
        progress.report(0.02)
        try ctx.checkCancelled()

        let props = ImageMetadata.read(item.url)
        let frameCount = max(1, (props == nil ? 1 : frameCountOf(item.url)))
        var outputs: [URL] = []

        if plan.frames == "animated", plan.format == "gif", frameCount > 1 {
            outputs.append(try await runAnimated(item, ctx: ctx, plan: plan, frameCount: frameCount, progress: progress, suffix: suffix))
        } else if plan.frames == "all", frameCount > 1 {
            let digits = String(frameCount).count
            let base = ctx.outputBaseName(for: item, suffix: suffix)
            for i in 0..<frameCount {
                try ctx.checkCancelled()
                let name = base + " - " + String(format: "%0\(digits)d", i + 1)
                outputs.append(try await runFrame(item, index: i, ctx: ctx, plan: plan, suffix: suffix, baseName: name,
                                                  progress: { progress.report((Double(i) + $0) / Double(frameCount)) }))
            }
        } else {
            outputs.append(try await runFrame(item, index: 0, ctx: ctx, plan: plan, suffix: suffix, baseName: nil, progress: { progress.report($0) }))
        }
        progress.report(1)
        return outputs
    }

    private static func frameCountOf(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return 1 }
        // The pictures of an icon are sizes of one image, not frames of an animation.
        if let type = CGImageSourceGetType(src) as String?, type == "com.microsoft.ico" || type == "com.apple.icns" { return 1 }
        return max(1, CGImageSourceGetCount(src))
    }

    // MARK: One frame

    /// Decodes and processes frame `index`; reduced-size decoding is used when the result is at least 2x smaller than the file.
    static func prepareFrame(_ item: FileItem, index: Int, plan: Plan, props: [CFString: Any]?, extraMaxPixel: Int? = nil) throws -> (image: CGImage, loaded: ImageLoader.Loaded) {
        var opts = ImageLoader.Options()
        opts.frameIndex = index
        opts.applyOrientation = false
        var nominal: (width: Int, height: Int)? = nil
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let isIconOrSVG = ["svg", "ico", "icns"].contains(item.key) || Formats.rawInputs.contains(item.key)
        if w > 0, h > 0, plan.bakeOrientation, plan.spec.allowsReducedDecode, !isIconOrSVG, ((props?[kCGImagePropertyDepth] as? Int) ?? 8) <= 8 {
            let o = ImageMetadata.orientation(props)
            let up = Dihedral(orientation: o).size(of: w, h)
            let t = plan.spec.outputSize(width: up.width, height: up.height)
            let ratio = max(Double(t.width) / Double(up.width), Double(t.height) / Double(up.height))
            let limit = Int((Double(max(w, h)) * ratio).rounded(.up))
            if limit > 0, limit * 2 <= max(w, h) {
                opts.maxPixel = limit
                opts.applyOrientation = true
                nominal = up
            }
        }
        if let extra = extraMaxPixel { opts.maxPixel = min(opts.maxPixel ?? extra, extra) }
        let loaded = try ImageLoader.loadUnoriented(item.url, opts)
        let image = try ImageProcessor.process(loaded, spec: plan.spec, nominal: nominal, flatten: plan.flatten)
        return (image, loaded)
    }

    private static func runFrame(_ item: FileItem, index: Int, ctx: OperationContext, plan: Plan, suffix: L10n?, baseName: String?,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        let o = ctx.options
        let props = ImageMetadata.read(item.url, index: index)
        let (image, loaded) = try prepareFrame(item, index: index, plan: plan, props: props)
        progress(0.55)
        try ctx.checkCancelled()
        let recorded = plan.bakeOrientation ? 1 : ImageMetadata.orientation(props)
        let enc = ImageEncodeContext(sourceURL: item.url, properties: loaded.properties ?? props, orientation: recorded)
        let ext = ImageFormat.fileExtension(plan.format)
        let targetKB = o.int(ImageKeys.targetKB)
        let fits = targetKB > 0 && ["jpeg", "heic", "avif"].contains(plan.format)

        let url = try await ctx.produceFile(for: item, suffix: suffix, ext: ext, base: baseName) { tmp in
            if fits {
                let data = try ImageTargetSize.encodeToFit(image, format: plan.format, options: o, context: enc, targetBytes: Int64(targetKB) * 1024)
                try data.write(to: tmp)
            } else {
                try await ImageEncoder.write(image, format: plan.format, options: o, context: enc, to: tmp)
            }
        }
        progress(1)
        return url
    }

    // MARK: Animation

    private static func runAnimated(_ item: FileItem, ctx: OperationContext, plan: Plan, frameCount: Int, progress: ProgressSlice, suffix: L10n?) async throws -> URL {
        var frames: [(image: CGImage, delay: Double)] = []
        for i in 0..<frameCount {
            try ctx.checkCancelled()
            let props = ImageMetadata.read(item.url, index: i)
            let (image, _) = try prepareFrame(item, index: i, plan: plan, props: props)
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            frames.append((image, delay))
            progress.report(0.8 * Double(i + 1) / Double(frameCount))
        }
        return try await ctx.produceFile(for: item, suffix: suffix, ext: "gif") { tmp in try ImageContainers.writeAnimatedGIF(frames: frames, to: tmp) }
    }
}

/// "Fit to file size" for ImageIO formats: the largest quality whose file is not above the limit, shrinking the picture when quality alone cannot reach it.
enum ImageTargetSize {
    static func encodeToFit(_ image: CGImage, format: String, options: OptionValues, context: ImageEncodeContext, targetBytes: Int64) throws -> Data {
        let encode: (CGImage, Int) throws -> Data = { img, q in
            var o = options
            o[ImageKeys.quality] = .int(q)
            return try ImageEncoder.encodeSync(img, format: format, options: o, context: context)
        }
        do {
            return try ImageFit.search(image: image, targetBytes: targetBytes, minQuality: 30, allowResize: true, encode: encode).data
        } catch ConversionError.unsupported {
            return try search(image, targetBytes: targetBytes, minQuality: 30, encode: encode)
        }
    }

    /// Local binary search over quality, then over scale (x0.85 per step), used only when the shared planner is unavailable.
    /// Never returns a file above `targetBytes`: when even the smallest attempt is too big it says so (the colour profile and headers alone can exceed a tiny limit).
    static func search(_ image: CGImage, targetBytes: Int64, minQuality: Int, encode: (CGImage, Int) throws -> Data) throws -> Data {
        var current = image
        var smallest = Int64.max
        for _ in 0..<16 {
            try Task.checkCancellation()
            var lo = minQuality, hi = 100
            var found: Data? = nil
            while lo <= hi {
                let mid = (lo + hi) / 2
                let d = try encode(current, mid)
                smallest = min(smallest, Int64(d.count))
                if Int64(d.count) <= targetBytes { found = d; lo = mid + 1 } else { hi = mid - 1 }
            }
            if let f = found { return f }
            let w = max(16, Int(Double(current.width) * 0.85)), h = max(16, Int(Double(current.height) * 0.85))
            if w >= current.width && h >= current.height { break }
            guard let smaller = ImageGeometry.render(current, .identity, width: w, height: h) else { break }
            current = smaller
        }
        throw ConversionError.message(L10n("The picture cannot be made as small as \(Util.formatBytes(targetBytes)); the smallest result would be \(Util.formatBytes(smallest)). Choose a larger limit.",
                                           "Картинку не удаётся уменьшить до \(Util.formatBytes(targetBytes)); самый маленький результат - \(Util.formatBytes(smallest)). Выберите ограничение побольше."))
    }
}
