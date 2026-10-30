import SwiftUI

/// How big a thumbnail to ask the cache for. Requests are rounded UP to a few bucket sizes so a list of rows at 40 pt and a strip at 44 pt share one cache
/// entry per file, and a 2x display never decodes more than it can show.
enum ThumbnailSizing {
    static let buckets = [64, 128, 256, 512, 1024]

    /// Smallest bucket that covers `points * scale` pixels (the largest bucket for anything bigger).
    static func maxPixel(points: CGFloat, scale: CGFloat) -> Int {
        let need = Int((max(points, 1) * max(scale, 1)).rounded(.up))
        return buckets.first { $0 >= need } ?? buckets[buckets.count - 1]
    }
}

/// A file's picture: the cached ImageIO / Quick Look thumbnail (`ThumbnailCache.shared`) in a rounded tile with a hairline edge. While it loads (or when the
/// file cannot be decoded) the tile shows the file kind's symbol, so rows never jump. Loading is a cancellable `.task`: scrolling a row away cancels it, and the
/// view drops its image when it disappears (the cache keeps the bytes, capped at 32 MB).
struct ThumbnailView: View {
    var url: URL
    var kind: FileKind?
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    /// `.fit` shows the whole picture (Studio source preview), `.fill` crops to the tile (rows, shelf).
    var fit: Bool
    var label: String?

    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.a11y) private var a11y

    init(url: URL, kind: FileKind? = nil, size: CGFloat = 40, cornerRadius: CGFloat? = nil, fit: Bool = false, label: String? = nil) {
        self.init(url: url, kind: kind, width: size, height: size, cornerRadius: cornerRadius, fit: fit, label: label)
    }

    init(url: URL, kind: FileKind? = nil, width: CGFloat, height: CGFloat, cornerRadius: CGFloat? = nil, fit: Bool = false, label: String? = nil) {
        self.url = url; self.kind = kind; self.width = width; self.height = height; self.fit = fit; self.label = label
        // Concentric with a 12 pt card padded by 6: about a quarter of the short side, between 4 and 12.
        self.cornerRadius = cornerRadius ?? min(max(min(width, height) * 0.2, DS.Radius.chip - 2), DS.Radius.card)
    }

    private struct LoadKey: Equatable { var url: URL; var pixels: Int }

    private var loadKey: LoadKey { LoadKey(url: url, pixels: ThumbnailSizing.maxPixel(points: max(width, height), scale: displayScale)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: (kind ?? .other).symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: min(width, height) * 0.42, weight: .regular))
                .foregroundStyle(.secondary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(a11y.increaseContrast ? 0.5 : 0.12), lineWidth: a11y.increaseContrast ? 1 : 0.5) }
        .task(id: loadKey) {
            let key = loadKey
            let loaded = await ThumbnailCache.shared.thumbnail(for: key.url, kind: kind, maxPixel: key.pixels, scale: Int(max(displayScale, 1).rounded()))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { image = loaded }
        }
        .onDisappear { image = nil }
        .accessibilityElement()
        .accessibilityLabel(Text(label ?? ""))
        .accessibilityHidden(label == nil)
    }
}
