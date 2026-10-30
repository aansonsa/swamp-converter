import SwiftUI
import AppKit

// The image preview: original and result in one frame with a draggable divider, size delta chip, zoom to 100%, a loupe for compression artefacts, and crop handles that write the
// crop fields of the options. The result picture comes from the session (`OperationPreview`), the original from the thumbnail cache while the session is still working.

/// Crop handles <-> option values. Pure, so the mapping is tested without a window. Video cuts pixels from each edge ("crop.t / b / l / r"); images use a rectangle ("img.crop.x / y / w / h").
enum PreviewCropAdapter {
    enum Family { case video, image }

    static func modeKey(_ f: Family) -> String { f == .video ? "crop.mode" : "img.crop.mode" }
    static func activeMode(_ f: Family) -> String { f == .video ? "custom" : "rect" }

    /// The crop currently set in the options, nil when the crop mode is not the manual one.
    static func insets(_ f: Family, values: OptionValues, source: CGSize) -> PreviewMath.CropInsets? {
        guard values.string(modeKey(f)) == activeMode(f), source.width > 0, source.height > 0 else { return nil }
        switch f {
        case .video:
            return PreviewMath.insets(leftPx: values.int("crop.l"), topPx: values.int("crop.t"), rightPx: values.int("crop.r"), bottomPx: values.int("crop.b"), source: source)
        case .image:
            let x = values.int("img.crop.x"), y = values.int("img.crop.y")
            let w = values.int("img.crop.w"), h = values.int("img.crop.h")
            let right = w > 0 ? max(0, Int(source.width) - x - w) : 0
            let bottom = h > 0 ? max(0, Int(source.height) - y - h) : 0
            return PreviewMath.insets(leftPx: x, topPx: y, rightPx: right, bottomPx: bottom, source: source)
        }
    }

    /// The field writes for dragged handles (even pixel counts; an untouched far edge is written as "to the edge" for images).
    static func writes(_ f: Family, insets: PreviewMath.CropInsets, source: CGSize) -> [(key: String, value: OptionValue)] {
        let px = PreviewMath.cropPixels(insets, source: source)
        switch f {
        case .video:
            return [("crop.mode", "custom"), ("crop.l", .int(px.left)), ("crop.t", .int(px.top)), ("crop.r", .int(px.right)), ("crop.b", .int(px.bottom))]
        case .image:
            let w = Int(source.width) - px.left - px.right, h = Int(source.height) - px.top - px.bottom
            return [("img.crop.mode", "rect"), ("img.crop.x", .int(px.left)), ("img.crop.y", .int(px.top)),
                    ("img.crop.w", .int(px.right == 0 ? 0 : w)), ("img.crop.h", .int(px.bottom == 0 ? 0 : h))]
        }
    }
}

struct PreviewImageView: View {
    @ObservedObject var model: StudioWindowModel
    @ObservedObject var session: StudioSession
    var row: StudioSourceRow
    var frames: PreviewFrames
    var bindings: PreviewBindings
    var appliesToFocus: Bool

    @State private var divider = 0.5
    @State private var zoom = PreviewZoom.fit
    @State private var loupe = false
    @State private var cropEditing = false
    @State private var dragInsets: PreviewMath.CropInsets?
    @State private var original: CGImage?
    @State private var widthBucket = 1024

    private struct RequestKey: Equatable { var id: String; var bucket: Int; var applies: Bool }

    private var sourcePixels: CGSize { row.pixelSize ?? (frames.before ?? original).map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    private var liveInsets: PreviewMath.CropInsets? {
        PreviewCropAdapter.insets(.image, values: session.resolved?.values ?? session.values, source: sourcePixels)
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewCanvas(before: frames.before ?? original, after: frames.after, isWorking: frames.isWorking, divider: $divider, zoom: $zoom, loupeOn: loupe) { rect in
                if cropEditing, bindings.imageCrop, sourcePixels.width > 0 {
                    CropOverlay(rect: rect, insets: Binding(get: { dragInsets ?? liveInsets ?? PreviewMath.CropInsets() }, set: { dragInsets = $0 }),
                                sourcePixels: sourcePixels) { commitCrop($0) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widthBucket = Self.bucket(forWidth: $0 * 2) }
            Divider()
            PreviewControlBar {
                Picker(L("Zoom", "Масштаб"), selection: $zoom) {
                    Text(L("Fit", "Вписать")).tag(PreviewZoom.fit)
                    Text("100%").tag(PreviewZoom.actual)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel(Text(L("Zoom", "Масштаб")))
                PreviewToggleButton(title: L("Loupe", "Лупа"), symbol: "plus.magnifyingglass", isOn: $loupe, isEnabled: frames.before != nil || original != nil)
                if bindings.imageCrop {
                    PreviewToggleButton(title: L("Crop", "Обрезка"), symbol: "crop", isOn: cropBinding)
                }
                PreviewSizeChip(original: row.sizeBytes, result: frames.resultBytes)
                if let note = frames.note { Text(note).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !appliesToFocus { InfoChip(L("The result preview follows the first file", "Просмотр результата следует за первым файлом"), symbol: "info.circle") }
            }
        }
        .task(id: RequestKey(id: row.id, bucket: widthBucket, applies: appliesToFocus)) {
            model.previewTime = nil
            model.previewMaxPixel = widthBucket
            if appliesToFocus { session.requestPreview(time: nil, maxPixel: widthBucket) }
        }
        .task(id: row.url) {
            guard let url = row.url else { return }
            original = await ThumbnailCache.shared.thumbnail(for: url, kind: .image, maxPixel: 2048, scale: 1)
        }
        .onDisappear { session.cancelPreview() }
    }

    // MARK: Crop

    private var cropBinding: Binding<Bool> {
        Binding(get: { cropEditing }, set: { on in
            cropEditing = on
            if on, liveInsets == nil { for w in PreviewCropAdapter.writes(.image, insets: PreviewMath.CropInsets(), source: sourcePixels) { session.set(w.key, w.value) } }
            if !on { dragInsets = nil; session.set(PreviewCropAdapter.modeKey(.image), "none") }
        })
    }

    private func commitCrop(_ insets: PreviewMath.CropInsets) {
        for w in PreviewCropAdapter.writes(.image, insets: insets, source: sourcePixels) { session.set(w.key, w.value) }
        dragInsets = nil
    }

    /// Pixels the preview should render for a pane `pixels` wide: a few fixed sizes so scrolling between window sizes does not re-render for every point.
    static func bucket(forWidth pixels: CGFloat) -> Int {
        let sizes = [640, 1024, 1600, 2400]
        return sizes.first { CGFloat($0) >= pixels } ?? sizes[sizes.count - 1]
    }
}
