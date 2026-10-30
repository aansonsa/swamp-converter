import SwiftUI

// Snapshot sheet for the wordmark ornament: every size it is used at, in the three colours it is allowed to wear, tilted and straight.
// Compare with swamp-logo.png by eye: broad, ultra-heavy, tightly set, leaning about 6 degrees, flat colour.

struct WordmarkSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(alignment: .lastTextBaseline, spacing: DS.Space.xl) {
                    Brand.wordmark(size: 72)
                    Brand.wordmark(size: 40, color: Brand.pinkInk)
                    Brand.wordmark(size: 24, color: Brand.blueInk)
                }
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    caption(L("Small sizes (22, 18, 14 pt)", "Малые размеры (22, 18, 14 pt)"))
                    HStack(alignment: .lastTextBaseline, spacing: DS.Space.lg) {
                        Brand.wordmark(size: 22, color: Brand.pinkInk)
                        Brand.wordmark(size: 18, color: Brand.pinkInk)
                        Brand.wordmark(size: 14, color: Brand.pinkInk)
                        Brand.wordmark(size: 14, color: Brand.blueInk)
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    caption(L("In context: header, empty state, menu-bar scale", "В контексте: заголовок, пустое состояние, масштаб строки меню"))
                    HStack(spacing: DS.Space.md) {
                        Brand.wordmark(size: 20, color: Brand.pinkInk)
                        Text(L("Studio", "Студия")).font(DS.Typo.title)
                        Spacer(minLength: 0)
                        Image(systemName: "circle.grid.2x2").foregroundStyle(.secondary)
                    }
                    .padding(DS.Space.md)
                    .background(DS.Surface.control, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func caption(_ text: String) -> some View { Text(text).font(DS.Typo.caption).foregroundStyle(.secondary) }
}

extension SharedModule {
    @MainActor static func registerWordmarkSnapshots() {
        SnapshotRegistry.shared.register("shared.wordmark", size: CGSize(width: 560, height: 360), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) { WordmarkSheet() }
    }
}
