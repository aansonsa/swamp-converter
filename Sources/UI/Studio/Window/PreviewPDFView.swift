import SwiftUI
import AppKit
import PDFKit
import Vision

// The PDF preview: the current page large, a strip of page thumbnails whose selection IS the "Pages" field of the options (click selects one page, Command adds or removes,
// Shift extends), and an overlay that shows where on-device text recognition finds text. Pages render lazily, only the visible thumbnails exist.

/// Pure rendering helpers for pages (also used by the self-tests).
enum PDFPagePreview {
    /// The page as a picture, longest side `maxPixel`. Rotation and the crop box are applied by PDFKit.
    static func image(of page: PDFPage, maxPixel: Int) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
        let scale = CGFloat(maxPixel) / max(w, h)
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        let ns = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Text boxes Vision finds on a page picture, normalised with a TOP-left origin.
    static func textBoxes(in image: CGImage) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { o in
            let b = o.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
    }
}

/// Holds the open document and the thumbnails (reference type: the lazy cells share it).
@MainActor
final class PDFPreviewStore: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var isLocked = false
    @Published private(set) var failed = false
    private let thumbs = NSCache<NSNumber, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    init() { thumbs.countLimit = 80 }

    var pageCount: Int { document?.pageCount ?? 0 }

    func open(_ url: URL) {
        thumbs.removeAllObjects()
        guard let doc = PDFDocument(url: url) else { document = nil; failed = true; return }
        failed = false
        isLocked = doc.isLocked
        document = doc
    }

    func thumbnail(_ index: Int, maxPixel: Int) -> CGImage? {
        if let hit = thumbs.object(forKey: NSNumber(value: index)) { return hit.image }
        guard let page = document?.page(at: index), let img = PDFPagePreview.image(of: page, maxPixel: maxPixel) else { return nil }
        thumbs.setObject(CGImageBox(img), forKey: NSNumber(value: index))
        return img
    }

    func page(_ index: Int) -> PDFPage? { document?.page(at: index) }
}

struct PreviewPDFView: View {
    @ObservedObject var model: StudioWindowModel
    @ObservedObject var session: StudioSession
    var row: StudioSourceRow
    var bindings: PreviewBindings

    @StateObject private var store = PDFPreviewStore()
    @State private var current = 0
    @State private var anchor: Int?
    @State private var pageImage: CGImage?
    @State private var showText = false
    @State private var boxes: [CGRect] = []
    @State private var scanning = false

    private var values: OptionValues { session.resolved?.values ?? session.values }
    private var selection: Set<Int> {
        guard let key = bindings.pageRangeKey else { return [] }
        let all = Set(0..<store.pageCount)
        let sel = PageSelection.indices(from: values.string(key, "all"), pageCount: store.pageCount) ?? all
        return sel
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            Divider()
            if store.pageCount > 0 {
                strip
                PreviewControlBar {
                    Text(L("Page \(current + 1) of \(store.pageCount)", "Страница \(current + 1) из \(store.pageCount)")).font(DS.Typo.numeric(DS.Typo.callout)).foregroundStyle(.secondary)
                    if bindings.pageRangeKey != nil {
                        InfoChip(selection.count == store.pageCount ? L("All pages", "Все страницы") : L("Selected: \(selection.count)", "Выбрано: \(selection.count)"), symbol: "checklist")
                        if selection.count != store.pageCount {
                            Button(L("All Pages", "Все страницы")) { setSelection([]) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    if bindings.ocrKey != nil { PreviewToggleButton(title: L("Show Recognized Text", "Показать распознанный текст"), symbol: "text.viewfinder", isOn: $showText) }
                    if let b = row.sizeBytes { Text(Util.formatBytes(b)).font(DS.Typo.numeric(DS.Typo.caption)).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: row.url) { if let url = row.url { store.open(url); current = 0; anchor = nil; await renderPage() } }
        .task(id: current) { await renderPage() }
        .task(id: TextScanKey(page: current, on: showText, ready: pageImage != nil)) { await scan() }
    }

    private struct TextScanKey: Equatable { var page: Int; var on: Bool; var ready: Bool }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        if store.isLocked {
            PreviewMessage(symbol: "lock", title: L("This PDF is locked", "Этот PDF защищён паролем"), text: L("Choose “Unlock PDF” as the result and enter the password to see the pages.", "Выберите результат «Снять защиту PDF» и введите пароль, чтобы увидеть страницы."))
        } else if store.failed {
            PreviewMessage(symbol: "exclamationmark.triangle", title: L("The PDF can’t be opened", "Не удаётся открыть PDF"), text: nil)
        } else {
            GeometryReader { geo in
                ZStack {
                    if let img = pageImage {
                        let rect = PreviewMath.fitRect(image: CGSize(width: img.width, height: img.height), in: geo.size)
                        Image(decorative: img, scale: 1).resizable().interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .overlay { if showText { textOverlay(size: rect.size) } }
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                            .position(x: rect.midX, y: rect.midY)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Color.primary.opacity(0.04))
            .accessibilityLabel(Text(L("Page \(current + 1)", "Страница \(current + 1)")))
        }
    }

    private func textOverlay(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, b in
                Rectangle().fill(Brand.blueFill.opacity(0.18))
                    .overlay { Rectangle().strokeBorder(Brand.blueFill, lineWidth: 1) }
                    .frame(width: b.width * size.width, height: b.height * size.height)
                    .offset(x: b.minX * size.width, y: b.minY * size.height)
            }
            if scanning { ProgressView().controlSize(.small).padding(DS.Space.sm) }
            else if boxes.isEmpty {
                Text(L("No text found on this page", "На этой странице текст не найден")).font(DS.Typo.caption).padding(DS.Space.sm)
                    .background(.regularMaterial, in: Capsule()).padding(DS.Space.sm)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: DS.Space.sm) {
                ForEach(0..<store.pageCount, id: \.self) { i in
                    PDFThumbCell(store: store, index: i, isSelected: bindings.pageRangeKey != nil ? selection.contains(i) : i == current, isCurrent: i == current)
                        .onTapGesture { tap(i) }
                }
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        }
        .frame(height: 124)
    }

    private func tap(_ i: Int) {
        let flags = NSEvent.modifierFlags
        current = i
        guard let key = bindings.pageRangeKey else { return }
        // A plain click on a selected page of a partial selection keeps it a single-page selection; with nothing selected yet it starts one.
        let base = selection.count == store.pageCount ? Set<Int>() : selection
        let new = PageSelection.toggled(base, page: i, anchor: anchor, command: flags.contains(.command), shift: flags.contains(.shift), pageCount: store.pageCount)
        if !flags.contains(.shift) { anchor = i }
        session.set(key, .string(PageSelection.rangeString(new, pageCount: store.pageCount)))
    }

    private func setSelection(_ s: Set<Int>) {
        guard let key = bindings.pageRangeKey else { return }
        session.set(key, .string(PageSelection.rangeString(s, pageCount: store.pageCount)))
    }

    // MARK: Rendering

    private func renderPage() async {
        guard store.pageCount > 0, let page = store.page(current) else { pageImage = nil; return }
        let img = PDFPagePreview.image(of: page, maxPixel: 1400)
        if !Task.isCancelled { pageImage = img; boxes = [] }
    }

    private func scan() async {
        guard showText, let img = pageImage else { boxes = []; scanning = false; return }
        scanning = true
        let found = await Task.detached(priority: .utility) { PDFPagePreview.textBoxes(in: img) }.value
        if !Task.isCancelled { boxes = found; scanning = false }
    }
}

struct PDFThumbCell: View {
    @ObservedObject var store: PDFPreviewStore
    var index: Int
    var isSelected: Bool
    var isCurrent: Bool
    @Environment(\.a11y) private var a11y
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(width: 72, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isSelected ? Brand.pink : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 0.5) }
            .overlay(alignment: .topTrailing) {
                if isSelected { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(Brand.onPink, Brand.pink).padding(3).accessibilityHidden(true) }
            }
            Text("\(index + 1)").font(DS.Typo.numeric(DS.Typo.caption)).foregroundStyle(isCurrent ? Brand.pinkInk : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        // Keyed by the document too: a second PDF with as many pages kept showing the first one's thumbnails.
        .task(id: ThumbKey(index: index, document: store.document.map(ObjectIdentifier.init))) { image = store.thumbnail(index, maxPixel: 184) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Page \(index + 1)", "Страница \(index + 1)")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ThumbKey: Equatable { var index: Int; var document: ObjectIdentifier? }
