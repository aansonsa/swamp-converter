import Foundation

/// The three packs that ship with the app, built from image recipes (keys of `ImageKeys`). Every value below is a field of the image schema, so Studio shows exactly
/// what a pack runs and each output stays editable as a normal recipe once a pack is duplicated.
enum MultiOutputBuiltins {
    static let socialID = "builtin.social"
    static let webID = "builtin.web"
    static let iconsID = "builtin.icons"

    /// Ids "builtin.social", "builtin.web", "builtin.icons".
    static var all: [MultiOutputPreset] { packs }

    private static let packs: [MultiOutputPreset] = [social, web, icons]

    // MARK: Social sizes

    /// 1080x1350 (feed portrait 4:5), 1080x1920 (stories, Reels, Shorts 9:16), 1200x630 (link preview, 1.91:1), 1080x1080 (square). The picture fills the frame and is
    /// cropped around the centre; JPEG 90 (the visually transparent point of the image engine), location removed because these files are meant to be posted.
    private static let social = MultiOutputPreset(
        id: socialID, name: L10n("Social sizes", "Размеры для соцсетей"), symbol: "square.grid.2x2", inputProfile: .image,
        items: [
            frame("portrait", L10n("Portrait 4:5", "Портрет 4:5"), 1080, 1350),
            frame("story", L10n("Story 9:16", "История 9:16"), 1080, 1920),
            frame("link", L10n("Link preview 1.91:1", "Превью ссылки 1.91:1"), 1200, 630),
            frame("square", L10n("Square 1:1", "Квадрат 1:1"), 1080, 1080)
        ], wheel: .tools)

    private static func frame(_ id: String, _ label: L10n, _ w: Int, _ h: Int) -> MultiOutputItem {
        MultiOutputItem(id: id, label: L10n("\(label.en) (\(w) x \(h))", "\(label.ru) (\(w) x \(h))"),
                        recipe: Recipe(operationID: "image.to.jpg", values: [
                            ImageKeys.format: "jpeg", ImageKeys.quality: 90, ImageKeys.sizeMode: "fill", ImageKeys.sizeWidth: .int(w), ImageKeys.sizeHeight: .int(h),
                            ImageKeys.colorSpace: "srgb", ImageKeys.mdMode: "noGPS"]),
                        nameSuffix: "\(w)x\(h)")
    }

    // MARK: Web images

    static let webWidths = [480, 960, 1920]

    /// WebP (quality 80) and JPEG (quality 82, progressive) at 480, 960 and 1920 px wide: the usual `srcset` ladder. Smaller pictures are never enlarged; colour is sRGB and
    /// all metadata is removed.
    private static let web = MultiOutputPreset(
        id: webID, name: L10n("Web images", "Картинки для сайта"), symbol: "globe", inputProfile: .image,
        items: webWidths.flatMap { w in [
            MultiOutputItem(id: "webp-\(w)", label: L10n("WebP, \(w) px wide", "WebP, ширина \(w) px"),
                            recipe: Recipe(operationID: "image.to.webp", values: [
                                ImageKeys.format: "webp", ImageKeys.quality: 80, ImageKeys.sizeMode: "fit", ImageKeys.sizeWidth: .int(w), ImageKeys.sizeHeight: 0,
                                ImageKeys.upscale: false, ImageKeys.colorSpace: "srgb", ImageKeys.mdMode: "strip"]),
                            nameSuffix: "\(w)w"),
            MultiOutputItem(id: "jpg-\(w)", label: L10n("JPG, \(w) px wide", "JPG, ширина \(w) px"),
                            recipe: Recipe(operationID: "image.to.jpg", values: [
                                ImageKeys.format: "jpeg", ImageKeys.quality: 82, ImageKeys.progressive: true, ImageKeys.sizeMode: "fit", ImageKeys.sizeWidth: .int(w),
                                ImageKeys.sizeHeight: 0, ImageKeys.upscale: false, ImageKeys.colorSpace: "srgb", ImageKeys.mdMode: "strip"]),
                            nameSuffix: "\(w)w")
        ] }, wheel: .tools)

    // MARK: Icon pack

    static let iconSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// One .ico (256, 128, 64, 48, 32, 16), one .icns, and PNGs from 16 to 1024 px. The picture is cut to a centred square first, so nothing is stretched.
    private static let icons = MultiOutputPreset(
        id: iconsID, name: L10n("Icon pack", "Набор значков"), symbol: "app.badge", inputProfile: .image,
        items: [
            MultiOutputItem(id: "ico", label: L10n("Windows icon (ICO)", "Значок Windows (ICO)"),
                            recipe: Recipe(operationID: "image.to.ico", values: square([ImageKeys.format: "ico", "img.ico.sizes": "256,128,64,48,32,16"])), nameSuffix: "icon"),
            MultiOutputItem(id: "icns", label: L10n("macOS icon (ICNS)", "Значок macOS (ICNS)"),
                            recipe: Recipe(operationID: "image.convert", values: square([ImageKeys.format: "icns"])), nameSuffix: "icon")
        ] + iconSizes.map { s in
            MultiOutputItem(id: "png-\(s)", label: L10n("PNG \(s) x \(s)", "PNG \(s) x \(s)"),
                            recipe: Recipe(operationID: "image.to.png", values: square([ImageKeys.format: "png", ImageKeys.sizeMode: "exact", ImageKeys.sizeWidth: .int(s),
                                                                                         ImageKeys.sizeHeight: .int(s), ImageKeys.mdMode: "strip"])), nameSuffix: "icon-\(s)")
        }, wheel: .tools)

    private static func square(_ values: OptionValues) -> OptionValues {
        values.overlaying([ImageKeys.cropMode: "ratio", ImageKeys.cropRatio: "1:1", "img.crop.anchor": "center"])
    }
}
