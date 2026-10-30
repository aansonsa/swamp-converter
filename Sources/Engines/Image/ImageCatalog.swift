import Foundation

// The 18 per-file operations + 1 batch operation of the image family, in wheel order (spec/catalog.md 3.1).
// `gif.to.mp4` / `gif.to.webm` belong to the VIDEO module (they need ffmpeg).
// Several operations share ONE schema ("image.convert") and differ only by their quick overrides.

enum ImageCatalog {
    static let all = Formats.imageAndRawInputs

    @MainActor
    static func operations() -> [Operation] {
        let convert: [(String, L10n?, [Tool])] = [("jpg", nil, []), ("png", nil, []), ("webp", nil, [.cwebp]), ("avif", nil, []), ("heic", nil, []), ("tiff", nil, []), ("ico", nil, []),
                                                  ("pdf", L10n("document", "документ"), [])]
        var ops: [Operation] = convert.map { key, sub, tools in
            ImageOperation(.convert("image.to.\(key)", .image, to: key, sub: sub, symbol: "photo", schema: "image.convert", inputs: all, requires: tools)) { s in
                ImageQuick.convert(to: key, settings: s)
            }
        }
        func tool(_ id: String, _ label: L10n, sub: L10n? = nil, symbol: String, suffix: L10n, quick: @escaping @Sendable (SettingsData) -> OptionValues) {
            ops.append(ImageOperation(.make(id, .tools, .image, label, sub: sub, symbol: symbol, schema: "image.convert", inputs: all, suffix: suffix), quick: quick))
        }
        tool("image.compress", L10n("Compress", "Сжать"), symbol: "arrow.down.right.and.arrow.up.left", suffix: L10n("compressed", "сжато")) { ImageQuick.compress(settings: $0) }
        tool("image.half", L10n("Shrink", "Уменьшить"), sub: L10n("50%"), symbol: "arrow.down.right.and.arrow.up.left", suffix: L10n("smaller", "уменьшено")) { ImageQuick.half(settings: $0) }
        tool("image.max1920", L10n("Max 1920 px", "Макс. 1920 px"), sub: L10n("for web", "для интернета"), symbol: "arrow.down.right.and.arrow.up.left", suffix: L10n("1920")) { ImageQuick.max1920(settings: $0) }
        tool("image.rotate.right", L10n("Rotate", "Повернуть"), sub: L10n("right", "вправо"), symbol: "rotate.right", suffix: L10n("rotated", "повёрнуто")) { ImageQuick.rotate(90, settings: $0) }
        tool("image.rotate.left", L10n("Rotate", "Повернуть"), sub: L10n("left", "влево"), symbol: "rotate.left", suffix: L10n("rotated", "повёрнуто")) { ImageQuick.rotate(270, settings: $0) }
        tool("image.flip", L10n("Mirror", "Отразить"), symbol: "flip.horizontal", suffix: L10n("mirrored", "отражено")) { ImageQuick.flip(settings: $0) }
        tool("image.square", L10n("Square", "Квадрат"), sub: L10n("crop", "обрезка"), symbol: "crop", suffix: L10n("square", "квадрат")) { ImageQuick.square(settings: $0) }
        tool("image.grayscale", L10n("Grayscale", "Оттенки серого"), symbol: "paintpalette", suffix: L10n("grayscale", "оттенки серого")) { ImageQuick.grayscale(settings: $0) }
        tool("image.strip", L10n("No metadata", "Без метаданных"), sub: L10n("GPS, EXIF", "GPS, EXIF"), symbol: "eraser", suffix: L10n("no metadata", "без метаданных")) { ImageQuick.strip(settings: $0) }
        ops.append(ImageMergePDFOperation(meta: .make("image.merge.pdf", .tools, .image, L10n("Merge to PDF", "Объединить в PDF"), symbol: "arrow.triangle.merge",
                                                schema: "image.pdf", inputs: all, min: 2)))
        return ops
    }
}

/// Quick recipes (spec/catalog.md 3.1 "Quick recipes", spec/handbrake.md 4.6). Keys are in `ImageKeys`.
/// Every value here is a field of `ImageSchemas.convert`, so the Studio shows exactly what the wheel runs.
///
/// Default qualities and why (measured by the self-tests of ImageTestsEncoders on photographic fixtures; 1600 x 1200 smooth photo, bytes / PSNR):
///  * Convert and the edit tools use `SettingsData.quality.jpegQuality` = 90 on EVERY lossy codec's own 1 to 100 scale. That is the visually transparent point
///    (PSNR 43 to 44 dB): JPEG 172 KB / 43.8 dB, HEIC 84 KB / 43.6 dB, AVIF 35 KB / 43.6 dB, WebP (cwebp -m 6) 42 KB / 43.3 dB. Modern codecs reach the same look at
///    a half, a fifth and a quarter of the JPEG size, so one number serves all of them. Lower values (HEIC 80, AVIF 60, WebP 80) are in the built-in presets.
///  * JPEG comes from Apple's encoder: byte for byte what `sips` writes at the same quality, within 0.4 dB of libjpeg-turbo at the same file size when baseline and
///    0.1 to 1 dB better when progressive. Baseline is the default because every viewer reads it; Compress writes progressive.
///  * Compress uses `compressQuality` = 70 with metadata removed, 4:2:0, progressive JPEG and a dithered 256-colour palette for PNG pictures without transparency.
///  * PNG is always re-filtered and re-deflated losslessly (`PNGOptimizer`): about 15 to 20 percent smaller than ImageIO's own PNG and smaller than ffmpeg's and ImageMagick's.
enum ImageQuick {
    static func convert(to key: String, settings s: SettingsData) -> OptionValues {
        [ImageKeys.format: .string(key == "jpg" ? "jpeg" : key), ImageKeys.quality: .int(s.quality.jpegQuality)]
    }
    /// Strip metadata, quality 70, progressive 4:2:0 JPEG, palette PNG (256 colours, Floyd-Steinberg) for pictures without transparency.
    static func compress(settings s: SettingsData) -> OptionValues {
        [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.compressQuality), ImageKeys.mdMode: "strip", ImageKeys.progressive: true, ImageKeys.pngPalette: true]
    }
    static func half(settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.sizeMode: "percent", ImageKeys.sizePercent: 50] }
    static func max1920(settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.sizeMode: "longEdge", ImageKeys.sizeLong: 1920] }
    static func rotate(_ degrees: Int, settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.rotate: .int(degrees)] }
    static func flip(settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.flipH: true] }
    static func square(settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.cropMode: "ratio", ImageKeys.cropRatio: "1:1"] }
    static func grayscale(settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.gray: true] }
    static func strip(settings s: SettingsData) -> OptionValues { [ImageKeys.format: "same", ImageKeys.quality: .int(s.quality.jpegQuality), ImageKeys.mdMode: "strip"] }
}
