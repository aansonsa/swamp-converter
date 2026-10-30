import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum CutoutKeys {
    static let format = "cut.format"             // png, webp (cwebp), heic (alpha)
    static let cropToSubject = "cut.crop"
    static let padding = "cut.padding"
    static let background = "cut.bg"             // transparent, color
    static let backgroundColor = "cut.bg.color"
    static let feather = "cut.feather"
    static let maxPixel = "cut.maxPixel"         // downscale huge inputs before Vision (0 = never)
    /// "" = keep every subject; "1,3" = only the subjects Vision numbered 1 and 3.
    static let instances = "cut.instances"
}

enum CutoutSchemas {
    static let removeBackgroundID = "image.removebg"

    /// Pages Result (format, transparent or colour), Subject (crop + padding, feather, which subjects), Size (maximum size). Works for an empty items array.
    static func removeBackground(items: [FileItem]) -> OptionSchema {
        OptionSchema(id: removeBackgroundID, title: L10n("Remove background", "Удаление фона"), symbol: "person.crop.rectangle", pages: [
            .make("result", symbol: "photo", L10n("Result", "Результат"), [
                .make("format", L10n("File", "Файл"), footer: L10n("PNG keeps full quality. WebP is smaller and needs the cwebp tool.", "PNG сохраняет полное качество. WebP меньше, но нужен инструмент cwebp."), [
                    .picker(CutoutKeys.format, L10n("Format", "Формат"), [
                        FieldOption("png", "PNG"),
                        FieldOption("webp", "WebP", requires: ["tool.cwebp"], hint: Tool.cwebp.installHint),
                        FieldOption("heic", "HEIC", requires: ["native.imageio.write.heic"])
                    ], def: "png").basic().affects([.plan]).oracle("cut.format.magic")
                ]),
                .make("background", L10n("Background", "Фон"), [
                    .segmented(CutoutKeys.background, L10n("Behind the subject", "За объектом"), [
                        FieldOption("transparent", L10n("Transparent", "Прозрачный")),
                        FieldOption("color", L10n("Color", "Цвет"))
                    ], def: "transparent").basic().affects([.preview]).oracle("cut.bg.alpha"),
                    .color(CutoutKeys.backgroundColor, L10n("Color", "Цвет"), def: "#FFFFFF").visible(.eq(CutoutKeys.background, "color")).basic()
                        .affects([.preview]).oracle("cut.bg.color.pixel")
                ])
            ]),
            .make("subject", symbol: "person.crop.square", L10n("Subject", "Объект"), [
                .make("crop", L10n("Crop", "Кадрирование"), [
                    .toggle(CutoutKeys.cropToSubject, L10n("Crop to the subject", "Обрезать по объекту")).basic().affects([.preview, .estimate]).oracle("cut.crop.size"),
                    .stepper(CutoutKeys.padding, L10n("Space around the subject", "Поле вокруг объекта"), min: 0, max: 500, step: 4, def: 0, unit: "px")
                        .enabled(.eq(CutoutKeys.cropToSubject, true)).affects([.preview, .estimate]).oracle("cut.padding.size")
                ]),
                .make("edge", L10n("Edge", "Край"), [
                    .slider(CutoutKeys.feather, L10n("Soften the edge", "Смягчить край"), min: 0, max: 20, step: 1, def: 0, unit: "px",
                            minLabel: L10n("Sharp", "Резкий"), maxLabel: L10n("Soft", "Мягкий")).affects([.preview]).oracle("cut.feather.alpha"),
                    .text(CutoutKeys.instances, L10n("Keep only subjects numbered", "Оставить только объекты с номерами"), placeholder: L10n("all", "все"), validation: .integerList).expert()
                        .help(L10n("The picture may contain several subjects; they are numbered 1, 2, 3 … Leave empty to keep them all.", "На картинке может быть несколько объектов, они нумеруются 1, 2, 3 … Пусто — оставить все."))
                        .affects([.preview]).oracle("cut.instances.alpha")
                ])
            ]),
            .make("size", symbol: "arrow.up.left.and.arrow.down.right", L10n("Size", "Размер"), [
                .make("max", L10n("Maximum size", "Максимальный размер"), footer: L10n("Larger pictures are scaled down first: faster and lighter on memory.", "Большие изображения сначала уменьшаются: быстрее и экономнее по памяти."), [
                    .picker(CutoutKeys.maxPixel, L10n("Longest side", "Длинная сторона"), [
                        FieldOption("0", L10n("Original size", "Исходный размер")), FieldOption("512", "512 px"), FieldOption("1024", "1024 px"), FieldOption("2048", "2048 px"),
                        FieldOption("3000", "3000 px"), FieldOption("4096", "4096 px")
                    ], def: "0").standard().affects([.estimate, .preview]).oracle("cut.maxPixel.size")
                ])
            ])
        ])
    }
}

/// `image.removebg`: image -> `{name} (cutout).png|webp` with an alpha channel. WebP needs `cwebp` (the field is disabled with a hint without it).
final class RemoveBackgroundOperation: PerFileOperation, @unchecked Sendable {
    override func optionSchema(for items: [FileItem]) -> OptionSchema { CutoutSchemas.removeBackground(items: items) }
    override func quickOverrides(settings: SettingsData) -> OptionValues { [CutoutKeys.format: "png"] }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        Capabilities.shared.has("native.vision.foreground") ? .available
            : .unavailable(reason: L10n("Background removal is not available on this Mac.", "Удаление фона недоступно на этом Mac."), missing: [])
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        var chips = [options.string(CutoutKeys.format, "png").uppercased()]
        chips.append(options.string(CutoutKeys.background) == "color" ? options.string(CutoutKeys.backgroundColor, "#FFFFFF") : L("Transparent", "Прозрачный"))
        if options.bool(CutoutKeys.cropToSubject) { chips.append(L("Cropped", "Обрезано")) }
        return chips
    }

    /// One mapping from options to engine options for the job and the preview. Inactive fields (hidden by their conditions) fall back to defaults.
    static func cutoutOptions(_ o: OptionValues, isActive: (String) -> Bool = { _ in true }) -> CutoutOptions {
        var c = CutoutOptions()
        c.cropToSubject = o.bool(CutoutKeys.cropToSubject)
        c.padding = c.cropToSubject && isActive(CutoutKeys.padding) ? o.int(CutoutKeys.padding) : 0
        if o.string(CutoutKeys.background) == "color", isActive(CutoutKeys.backgroundColor) { c.backgroundHex = o.string(CutoutKeys.backgroundColor, "#FFFFFF") }
        c.feather = o.int(CutoutKeys.feather)
        c.maxPixel = o.int(CutoutKeys.maxPixel)
        let numbers = o.string(CutoutKeys.instances).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        c.instanceIndexes = numbers.isEmpty ? nil : Set(numbers)
        return c
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let options = Self.cutoutOptions(ctx.options, isActive: ctx.isActive)
        let format = ctx.options.string(CutoutKeys.format, "png")
        progress.report(0.05, message: nil)
        let url = item.url, limit = options.maxPixel > 0 ? options.maxPixel : nil
        let loaded = try await CancellableWork.run { try ImageLoader.load(url, ImageLoader.Options(maxPixel: limit)) }
        progress.report(0.15)
        let cut = try await CutoutEngine.cutout(loaded, options: options)
        progress.report(0.85)
        let data = try await Self.encode(cut, format: format)
        try ctx.checkCancelled()
        let output = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: format) { try data.write(to: $0) }
        progress.report(1)
        return [output]
    }

    /// PNG is written here with ImageIO (lossless, alpha untouched); WebP and HEIC go through the image module's encoder (cwebp / ImageIO).
    static func encode(_ image: CGImage, format: String) async throws -> Data {
        if format == "png" {
            return try await CancellableWork.run {
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ConversionError.noOutput }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { throw ConversionError.noOutput }
                return data as Data
            }
        }
        return try await ImageEncoder.encode(image, format: format, options: [ImageKeys.quality: 92, ImageKeys.lossless: false, ImageKeys.mdMode: "strip"])
    }

    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        guard let item = items.first else { return nil }
        var o = Self.cutoutOptions(options)
        o.maxPixel = o.maxPixel > 0 ? min(o.maxPixel, maxPixel) : maxPixel
        let before = try ImageLoader.load(item.url, ImageLoader.Options(maxPixel: o.maxPixel))
        let after = try await CutoutEngine.cutout(before, options: o)
        return OperationPreview(before: before, after: after, note: L10n("Preview is scaled down.", "Предпросмотр уменьшен."))
    }
}
