import Foundation
import AppKit
import ImageIO
import CoreGraphics

/// What the Studio shows around an image conversion: source facts and chips, the size estimate, the summary chips, cross-field notes and the before / after preview.
struct ImageSourceProbe: SourceProbe {
    /// Facts image.width / height (upright), image.dpi, image.alpha, image.profile, image.frames, image.hasGPS, image.bitdepth, image.orientation, image.key;
    /// reads ImageIO properties only (no pixels), so it is cheap even for 100 MP files.
    func probe(_ item: FileItem) async -> SourceInfo {
        var info = SourceInfo(url: item.url, kind: item.kind)
        info.facts["container"] = .string(item.key)
        info.facts["image.key"] = .string(item.key)
        var w = 0, h = 0, frames = 1
        var props: [CFString: Any]? = nil
        if item.key == "svg" {
            if let ns = NSImage(contentsOf: item.url), ns.size.width >= 1 { w = Int(ns.size.width.rounded()) * 2; h = Int(ns.size.height.rounded()) * 2 }
            info.facts["image.alpha"] = .bool(true)
            info.chips.append(SourceChip(symbol: "photo", text: "\(w) × \(h)"))
            info.chips.append(SourceChip(symbol: nil, text: "SVG"))
            info.facts["image.width"] = .int(w); info.facts["image.height"] = .int(h); info.facts["image.frames"] = .int(1)
            return info
        }
        if let src = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            frames = max(1, CGImageSourceGetCount(src))
            var index = 0, best = -1
            if let t = CGImageSourceGetType(src) as String?, t == "com.microsoft.ico" || t == "com.apple.icns" {
                let sizes = frames
                frames = 1     // sizes of one icon, not frames of an animation
                for i in 0..<sizes {
                    let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                    let side = max((p?[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
                    if side > best { best = side; index = i }
                }
            }
            props = CGImageSourceCopyPropertiesAtIndex(src, index, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        }
        w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = ImageMetadata.orientation(props)
        let upright = Dihedral(orientation: orientation).size(of: w, h)
        let alpha = (props?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let profile = props?[kCGImagePropertyProfileName] as? String
        let depth = (props?[kCGImagePropertyDepth] as? Int) ?? 8
        let inventory = ImageMetadata.inventory(props)
        info.facts["image.width"] = .int(upright.width)
        info.facts["image.height"] = .int(upright.height)
        info.facts["image.alpha"] = .bool(alpha)
        info.facts["image.frames"] = .int(frames)
        info.facts["image.hasGPS"] = .bool(inventory.hasGPS)
        info.facts["image.bitdepth"] = .int(depth)
        info.facts["image.orientation"] = .int(orientation)
        if let d = ImageMetadata.dpi(props) { info.facts["image.dpi"] = .double(d.x) }
        if let profile { info.facts["image.profile"] = .string(profile) }

        if upright.width > 0 {
            info.chips.append(SourceChip(symbol: "photo", text: "\(upright.width) × \(upright.height)"))
            info.chips.append(SourceChip(symbol: nil, text: String(format: "%.1f MP", Double(upright.width * upright.height) / 1_000_000)))
        }
        info.chips.append(SourceChip(symbol: nil, text: item.key.uppercased()))
        if let profile { info.chips.append(SourceChip(symbol: "paintpalette", text: profile)) }
        if alpha { info.chips.append(SourceChip(symbol: "circle.dotted", text: L("Transparency", "Прозрачность"))) }
        if frames > 1 && !["ico", "icns"].contains(item.key) { info.chips.append(SourceChip(symbol: "square.stack", text: Loc.frames(frames))) }
        if inventory.hasGPS { info.chips.append(SourceChip(symbol: "location", text: L("Location", "Геолокация"))) }
        if let device = inventory.device { info.chips.append(SourceChip(symbol: "camera", text: device)) }
        if frames > 1 && !["ico", "icns"].contains(item.key) { info.warnings.append(L10n("Several frames: only the first one is used unless you choose otherwise.", "Несколько кадров: используется только первый, если не выбрать иначе.")) }
        if inventory.hasGPS { info.warnings.append(L10n("The picture records where it was taken.", "В картинке записано место съёмки.")) }
        if orientation != 1 { info.warnings.append(L10n("The camera stored this picture rotated; the rotation is applied.", "Камера записала картинку повёрнутой; поворот применяется.")) }
        if depth > 8 { info.warnings.append(L10n("\(depth)-bit color: JPEG and HEIC will store 8 bits.", "Цвет \(depth) бит: JPEG и HEIC сохранят 8 бит.")) }
        return info
    }
}

private extension Loc {
    static func frames(_ n: Int) -> String { L("\(n) frames", "кадров: \(n)") }
}

enum ImageStudioSupport {
    // MARK: Estimate

    /// Bits per pixel of a lossy photo format at `quality`; calibrated on camera JPEGs, deliberately rough.
    static func jpegBitsPerPixel(_ quality: Int) -> Double { 0.3 + 2.3 * pow(Double(min(100, max(1, quality))) / 90, 3) }

    static func estimate(options o: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        guard let item = items.first else { return nil }
        var w = source?.int("image.width") ?? 0, h = source?.int("image.height") ?? 0
        if w <= 0 || h <= 0, let p = ImageMetadata.read(item.url) {
            w = (p[kCGImagePropertyPixelWidth] as? Int) ?? 0; h = (p[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let u = Dihedral(orientation: ImageMetadata.orientation(p)).size(of: w, h); w = u.width; h = u.height
        }
        guard w > 0, h > 0 else { return nil }
        let plan = ImageRunner.plan(for: item, options: o)
        let out = plan.spec.outputSize(width: w, height: h)
        let px = Double(out.width) * Double(out.height)
        let q = o.int(ImageKeys.quality, 90)
        let alpha = source?.bool("image.alpha") ?? false
        var bytes: Double
        switch plan.format {
        case "jpeg": bytes = px * jpegBitsPerPixel(q) / 8
        case "heic": bytes = px * jpegBitsPerPixel(q) * 0.55 / 8
        case "avif": bytes = px * jpegBitsPerPixel(q) * 0.45 / 8
        case "webp": bytes = px * jpegBitsPerPixel(q) * (o.bool(ImageKeys.lossless) ? 3.2 : 0.7) / 8
        case "jp2": bytes = px * jpegBitsPerPixel(q) * 0.8 / 8
        case "png": bytes = px * (o.bool(ImageKeys.pngPalette) ? 3.5 : 10) / 8
        case "tiff": bytes = px * ["none": 24.0, "lzw": 14.0, "deflate": 11.0, "packbits": 22.0][o.string(ImageKeys.tiffCompression, "lzw")]! / 8
        case "bmp", "tga", "psd": bytes = px * (alpha ? 32 : 24) / 8
        case "gif": bytes = px * 2.5 / 8
        case "pdf": bytes = px * jpegBitsPerPixel(q) / 8 + 2_000
        case "ico", "icns": bytes = ImageEncodeParams.parseSizes(o.string(ImageKeys.icoSizes, "")).reduce(0.0) { $0 + Double($1 * $1) * 4 } * 0.6 + 1_500
        default: bytes = px * 12 / 8
        }
        let limit = Double(o.int(ImageKeys.targetKB)) * 1024
        if limit > 0, ImageFormat.isLossy(plan.format) { bytes = min(bytes, limit) }
        let note: L10n? = ["jpeg", "heic", "avif", "webp", "jp2"].contains(plan.format) ? L10n("Estimated from typical photos; real size depends on the picture.", "Оценка по типичным фото; реальный размер зависит от картинки.") : nil
        return OperationEstimate(bytes: Int64(max(1_000, bytes)), seconds: max(0.05, px / 30_000_000), confidence: .rough, note: note)
    }

    // MARK: Chips and notes

    static func chips(options o: OptionValues, source: SourceInfo?) -> [String] {
        let chosen = o.string(ImageKeys.format, "jpeg")
        var out: [String] = [chosen == "same" ? L("Same format", "Тот же формат") : (chosen == "jpeg" ? "JPEG" : chosen.uppercased())]
        let format = chosen == "same" ? "same" : ImageFormat.canonical(chosen)
        if ImageFormat.isLossy(format) || format == "same" || format == "pdf" { out.append("Q\(o.int(ImageKeys.quality, 90))") }
        if o.int(ImageKeys.targetKB) > 0 { out.append("≤ " + Util.formatBytes(Int64(o.int(ImageKeys.targetKB)) * 1024)) }
        if let w = source?.int("image.width"), let h = source?.int("image.height"), w > 0 {
            let s = ImageSpec(o).outputSize(width: w, height: h)
            if s.width != w || s.height != h { out.append("\(s.width) × \(s.height)") }
        } else {
            switch o.string(ImageKeys.sizeMode, "original") {
            case "longEdge": out.append("\(o.int(ImageKeys.sizeLong)) px")
            case "percent": out.append(Loc.percent(o.int(ImageKeys.sizePercent)))
            case "fit", "exact", "fill": out.append("\(o.int(ImageKeys.sizeWidth)) × \(o.int(ImageKeys.sizeHeight))")
            default: break
            }
        }
        if o.string(ImageKeys.cropMode, "none") == "ratio" { out.append(o.string(ImageKeys.cropRatio, "1:1")) }
        if o.int(ImageKeys.rotate) != 0 { out.append("\(o.int(ImageKeys.rotate))°") }
        if o.bool(ImageKeys.flipH) || o.bool(ImageKeys.flipV) { out.append(L("Mirrored", "Отражено")) }
        if o.bool(ImageKeys.gray) || o.string(ImageKeys.colorSpace) == "gray" { out.append(L("Black and white", "Чёрно-белое")) }
        else if let cs = ["srgb": "sRGB", "p3": "Display P3", "adobe": "Adobe RGB"][o.string(ImageKeys.colorSpace, "keep")] { out.append(cs) }
        switch o.string(ImageKeys.mdMode, "keep") {
        case "strip": out.append(L("No metadata", "Без метаданных"))
        case "noGPS": out.append(L("No location", "Без геолокации"))
        default: break
        }
        return out
    }

    static func validate(options o: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        var out: [OptionMessage] = []
        if o.string(ImageKeys.format) == "ico", let w = source?.int("image.width"), let h = source?.int("image.height") {
            let biggest = ImageEncodeParams.parseSizes(o.string(ImageKeys.icoSizes, "")).first ?? 256
            if max(w, h) < biggest {
                out.append(OptionMessage(id: "image.ico.small", severity: .info,
                                         text: L10n("The picture is smaller than the largest icon size; that icon will look soft.", "Картинка меньше самого большого размера значка, он будет нечётким."),
                                         fieldKey: ImageKeys.icoSizes))
            }
        }
        if o.string(ImageKeys.format) == "heic" || o.string(ImageKeys.format) == "avif", o.string(ImageKeys.mdMode) == "keep", source?.bool("image.hasGPS") == true {
            out.append(OptionMessage(id: "image.gps.kept", severity: .info, text: L10n("The location stays in the file. Choose “Remove location” before sharing.", "Геолокация останется в файле. Перед отправкой выберите «Убрать геолокацию»."),
                                     fieldKey: ImageKeys.mdMode))
        }
        return out
    }

    // MARK: Preview

    /// Sample of the real run: the picture decoded at reduced size, the same options applied (absolute sizes scaled down), lossy formats encoded and decoded again.
    static func preview(item: FileItem, options o: OptionValues, maxPixel: Int) throws -> OperationPreview? {
        let plan = ImageRunner.plan(for: item, options: o)
        var before = ImageLoader.Options()
        before.maxPixel = maxPixel
        let original = try ImageLoader.load(item.url, before)
        try Task.checkCancellation()

        let props = ImageMetadata.read(item.url)
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? original.width, h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? original.height
        let up = Dihedral(orientation: ImageMetadata.orientation(props)).size(of: w, h)
        var opts = ImageLoader.Options()
        opts.maxPixel = maxPixel
        opts.applyOrientation = plan.bakeOrientation
        let loaded = try ImageLoader.loadUnoriented(item.url, opts)
        let sampleUp = Dihedral(orientation: loaded.orientation).size(of: loaded.image.width, loaded.image.height)
        let ratio = Double(max(sampleUp.width, sampleUp.height)) / Double(max(1, max(up.width, up.height)))
        var spec = plan.spec.scaled(by: min(1, ratio))
        if plan.spec.sizeMode == "original" { spec.sizeMode = "original" }
        var after = try ImageProcessor.process(loaded, spec: spec, flatten: plan.flatten)
        try Task.checkCancellation()

        var sampleBytes: Int64? = nil
        var note: L10n? = nil
        if ImageFormat.writesNatively(plan.format), plan.format != "ico" {
            var enc = o
            enc[ImageKeys.targetKB] = .int(0)
            if let data = try? ImageEncoder.encodeSync(after, format: plan.format, options: enc, context: ImageEncodeContext(sourceURL: nil)) {
                sampleBytes = Int64(data.count)
                if ImageFormat.isLossy(plan.format), let src = CGImageSourceCreateWithData(data as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) { after = decoded }
            }
        } else if plan.format == "webp" {
            note = L10n("The preview does not show WebP compression.", "Предпросмотр не показывает сжатие WebP.")
        }
        if ((props == nil ? 1 : CGImageSourceGetCountOf(item.url)) > 1) && plan.frames == "first" { note = L10n("Preview shows the first frame only.", "Предпросмотр показывает только первый кадр.") }
        return OperationPreview(before: original, after: after, note: note, sampleOutputBytes: sampleBytes)
    }

    private static func CGImageSourceGetCountOf(_ url: URL) -> Int {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 1 }
        return CGImageSourceGetCount(s)
    }
}
