import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Snapshot matrix of the wheel (spec/wheel.md 19.18): ring sizes 3 / 8 / 12, the link wheel with a long page title, the clipboard wheel, a dimmed sector with its hint, paging,
// the waiting and repeat hubs, the permission sheets; light / dark, English / Russian, and the accessibility variants for the busiest ring. The content is synthetic (no operation
// registry needed) so the images do not move when an engine changes its labels.

enum WheelSnapshotData {
    static func sector(_ id: String, _ en: String, _ ru: String, sub: (String, String)? = nil, symbol: String = "photo", format: Bool = false,
                       enabled: Bool = true, hint: (String, String)? = nil, role: WheelSector.Role? = nil) -> WheelSector {
        WheelSector(id: id, role: role ?? .operation(id), title: L10n(en, ru), subtitle: sub.map { L10n($0.0, $0.1) }, symbol: symbol, isFormatTile: format,
                    enabled: enabled, hint: hint.map { L10n($0.0, $0.1) })
    }

    static let png = sector("image.to.png", "PNG", "PNG", format: true)
    static let webp = sector("image.to.webp", "WebP", "WebP", format: true)
    static let heic = sector("image.to.heic", "HEIC", "HEIC", format: true)
    static let pdf = sector("image.to.pdf", "PDF", "PDF", sub: ("document", "документ"), format: true)
    static let tiff = sector("image.to.tiff", "TIFF", "TIFF", format: true)
    static let gif = sector("image.to.gif", "GIF", "GIF", format: true)
    static let compress = sector("image.compress", "Compress", "Сжать", sub: ("smaller file", "меньше файл"), symbol: "arrow.down.right.and.arrow.up.left")
    static let shrink = sector("image.half", "Shrink", "Уменьшить", sub: ("50%", "50%"), symbol: "arrow.down.left.and.arrow.up.right")
    static let removeBG = sector("image.removebg", "Remove background", "Убрать фон", sub: ("cutout", "вырез"), symbol: "person.crop.rectangle")
    static let merge = sector("pdf.merge", "Merge PDF", "Объединить PDF", sub: ("one file", "один файл"), symbol: "doc.on.doc")
    static let strip = sector("image.strip", "No metadata", "Без метаданных", sub: ("privacy", "приватность"), symbol: "eye.slash")
    static let rotate = sector("image.rotate.right", "Rotate", "Повернуть", sub: ("right", "вправо"), symbol: "rotate.right")
    static let ocr = sector("tools.ocr", "Extract text", "Извлечь текст", sub: ("OCR", "OCR"), symbol: "text.viewfinder",
                            enabled: false, hint: ("Needs the Vision text model, which is not available on this Mac.", "Нужна модель распознавания текста Vision, она недоступна на этом Mac."))
    static let copy = sector("action.copy", "Copy", "Копировать", sub: ("to folder...", "в папку..."), symbol: "doc.on.doc")
    static let more = sector("more", "More...", "Ещё...", symbol: "ellipsis", role: .more)
    static let back = sector("back", "Back", "Назад", symbol: "chevron.backward", role: .back)

    static let imageSummary = WheelInputSummary(icons: [.type(.jpeg), .type(.png), .type(.heic)], text: "9 images \u{00B7} 2 PDFs", count: 11)
    static func oneImage(_ name: String = "IMG_2041.jpg") -> WheelInputSummary { WheelInputSummary(icons: [.type(.jpeg)], text: name, count: 1) }

    @MainActor
    static func model(pages: [[WheelSector]], wheel: WheelKind = .convert, highlight: Int = -1, mode: WheelPresentation = .drag, summary: WheelInputSummary = imageSummary,
                      page: Int = 0, linkTitle: String? = nil, linkHost: String? = nil, repeatView: Bool = false, waiting: Bool = false, capsuleHot: Bool = false) -> WheelModel {
        var content = WheelContent(wheel: wheel, pages: pages, isRepeatView: repeatView)
        content.linkTitle = linkTitle
        content.linkHost = linkHost
        let m = WheelModel(content: content, presentation: mode, summary: summary)
        m.isStatic = true
        m.tick = nil
        m.waitingForItems = waiting
        m.reachableWheels = wheel == .link ? [] : WheelKind.fileWheels
        if page > 0 { m.setPage(page) }
        if capsuleHot { m.pointerMoved(to: CGPoint(x: 0, y: -35)) }
        if highlight >= 0 { m.setHighlight(highlight) }
        return m
    }

    /// The link wheel of a page with a very long title (the hub wraps and ends in an ellipsis).
    @MainActor
    static func linkModel() -> WheelModel {
        let links = [sector("link.best", "Best for Apple", "Лучшее для Apple", sub: ("HEVC if needed", "HEVC при необходимости"), symbol: "apple.logo"),
                     sector("link.max", "Maximum quality", "Максимальное качество", sub: ("best quality, as is", "лучшее качество, как есть"), symbol: "sparkles"),
                     sector("link.universal", "Universal", "Универсальный", sub: ("H.264, for all", "H.264 для всех"), symbol: "globe"),
                     sector("link.audio.m4a", "Audio M4A", "Аудио M4A", sub: ("sound only", "только звук"), symbol: "waveform"),
                     sector("link.audio.mp3", "Audio MP3", "Аудио MP3", sub: ("sound only", "только звук"), symbol: "waveform"),
                     WheelContentBuilder.studioSector]
        return model(pages: [links], wheel: .link, mode: .click, summary: WheelInputSummary(icons: [.symbol("link")], text: "youtube.com", count: 1, isLinks: true),
                     linkTitle: "How a very long page title wraps inside the hub of the download wheel, 4K HDR", linkHost: "youtube.com")
    }

    /// The ring the app really builds for `item` (operation registry, tool detection, default layout), for artwork.
    @MainActor
    static func realModel(wheel: WheelKind, item: FileItem, highlight: Int) -> WheelModel {
        let content = WheelContentBuilder().fileContent(items: [item], wheel: wheel)
        let m = WheelModel(content: content, presentation: .drag, summary: WheelInputSummary.make(files: [item]))
        m.isStatic = true
        m.tick = nil
        m.reachableWheels = WheelKind.fileWheels
        if highlight >= 0 { m.setHighlight(highlight) }
        return m
    }

    /// The wheel for a screenshot taken from the clipboard.
    @MainActor
    static func clipboardModel() -> WheelModel {
        let ops = [sector("image.to.jpg", "JPG", "JPG", format: true), webp, heic, sector("image.to.png", "PNG", "PNG", format: true), compress, removeBG,
                   sector("action.copy", "Save as...", "Сохранить как...", sub: ("to folder...", "в папку..."), symbol: "square.and.arrow.down")]
        let m = model(pages: [ops], highlight: 0, mode: .click, summary: WheelInputSummary(icons: [.type(.png)], text: "Screenshot 2026-10-25 120301", count: 1))
        m.pasteBackAvailable = true
        m.reachableWheels = []
        return m
    }

    /// The smallest wheel scale (0.8).
    @MainActor
    static func smallModel() -> WheelModel {
        let m = model(pages: eight, highlight: 0)
        m.scale = 0.8
        return m
    }

    /// Three sectors; eight with "More..."; twelve (the geometry's stress case).
    static var three: [[WheelSector]] { [[png, compress, copy]] }
    static var eight: [[WheelSector]] { [[png, webp, heic, pdf, compress, shrink, removeBG, more], [tiff, gif, merge, strip, rotate, ocr, copy, back]] }
    static var twelve: [[WheelSector]] { [[png, webp, heic, pdf, tiff, gif, compress, shrink, removeBG, merge, strip, rotate]] }
}

struct WheelSnapshotView: View {
    @StateObject private var model: WheelModel
    init(_ model: @autoclosure @escaping () -> WheelModel) { _model = StateObject(wrappedValue: model()) }
    var body: some View {
        WheelRingView(model: model)
            .frame(width: model.geometry.panelSide, height: model.geometry.panelSide)
            .appRoot()
    }
}

extension WheelModule {
    @MainActor
    static func registerSnapshots() {
        let s = SnapshotRegistry.shared
        let size = CGSize(width: 440, height: 440)
        let full = SnapshotVariant.lightDarkRu
        typealias D = WheelSnapshotData
        s.register("wheel.three-sectors", size: size, variants: full) { WheelSnapshotView(D.model(pages: D.three, highlight: 1, summary: D.oneImage())) }
        s.register("wheel.eight-sectors", size: size, variants: full) { WheelSnapshotView(D.model(pages: D.eight, highlight: 3)) }
        // The wheel alone, for artwork such as docs/social-preview.png. Glass over a transparent window samples whatever is behind the window, so it is rendered
        // twice, over flat black and flat white; the difference of the two gives the wheel's own colour and opacity (a cut-out with no wallpaper in it).
        s.register("wheel.promo-black", size: size, backdrop: .none, variants: [SnapshotVariant.dark]) { ZStack { Color.black; WheelSnapshotView(D.model(pages: D.eight, highlight: 3)) } }
        s.register("wheel.promo-white", size: size, backdrop: .none, variants: [SnapshotVariant.dark]) { ZStack { Color.white; WheelSnapshotView(D.model(pages: D.eight, highlight: 3)) } }
        // The three real rings (Convert, Tools, Actions) for one PNG, idle and with each sector hovered in turn, over black and white for the same matte. Used to
        // composite the wheel onto a screen recording that did not capture it. 72 images, so only when SC_PROMO_WHEELS is set.
        if ProcessInfo.processInfo.environment["SC_PROMO_WHEELS"] != nil {
            let png = FileItem(url: URL(fileURLWithPath: "/tmp/swamp-logo.png"), isDirectory: false, size: 1_048_576)
            for wheel in WheelKind.fileWheels {
                for hover in -1..<8 {
                    for (tag, color) in [("black", Color.black), ("white", Color.white)] {
                        s.register("wheel.real-\(wheel.rawValue)-\(hover + 1)-\(tag)", size: size, backdrop: .none, variants: [SnapshotVariant.dark]) {
                            ZStack { color; WheelSnapshotView(D.realModel(wheel: wheel, item: png, highlight: hover)) }
                        }
                    }
                }
            }
        }
        s.register("wheel.eight-idle", size: size, variants: full) { WheelSnapshotView(D.model(pages: D.eight, mode: .click)) }
        s.register("wheel.twelve-sectors", size: size, variants: full) { WheelSnapshotView(D.model(pages: D.twelve, highlight: 10)) }
        s.register("wheel.link-long-title", size: size, variants: full) { WheelSnapshotView(D.linkModel()) }
        s.register("wheel.clipboard", size: size, variants: full) { WheelSnapshotView(D.clipboardModel()) }
        s.register("wheel.disabled-hint", size: size, variants: full) { WheelSnapshotView(D.model(pages: D.eight, highlight: 5, page: 1)) }
        s.register("wheel.page-two", size: size, variants: full) { WheelSnapshotView(D.model(pages: D.eight, highlight: 1, page: 1)) }
        s.register("wheel.waiting", size: size, variants: SnapshotVariant.lightDark) { WheelSnapshotView(D.model(pages: [[]], summary: .empty, waiting: true)) }
        s.register("wheel.repeat", size: size, variants: SnapshotVariant.lightDark) {
            WheelSnapshotView(D.model(pages: [[WheelSector(id: "repeat", role: .repeatLast, title: L10n("WebP", "WebP"), subtitle: L10n("quality 80", "качество 80"),
                                                          symbol: "arrow.trianglehead.counterclockwise", isFormatTile: false)]], repeatView: true))
        }
        s.register("wheel.customise-capsule", size: size, variants: SnapshotVariant.lightDark) { WheelSnapshotView(D.model(pages: D.eight, capsuleHot: true)) }
        s.register("wheel.a11y", size: size, variants: SnapshotVariant.accessibility) { WheelSnapshotView(D.model(pages: D.eight, highlight: 4)) }
        s.register("wheel.scale-small", size: CGSize(width: 360, height: 360), variants: SnapshotVariant.lightDark) { WheelSnapshotView(D.smallModel()) }
        s.register("wheel.permission-explain", size: CGSize(width: 480, height: 200), backdrop: .wallpaper, variants: full) {
            WheelPermissionSheet(copy: .copy(for: .explainBrowser(.safari)), onChoice: { _ in }).frame(width: 480, height: 200)
        }
        s.register("wheel.permission-denied", size: CGSize(width: 480, height: 200), backdrop: .wallpaper, variants: SnapshotVariant.lightDark) {
            WheelPermissionSheet(copy: .copy(for: .deniedFinder), onChoice: { _ in }).frame(width: 480, height: 200)
        }
    }
}
