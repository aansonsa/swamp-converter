import SwiftUI

// Offscreen snapshot of the floating shelf panel (filled and with long Russian names).

enum ActionsSnapshots {
    @MainActor
    static func register() {
        let r = SnapshotRegistry.shared
        r.register("actions.shelf", size: CGSize(width: 330, height: 280), backdrop: .wallpaper, variants: SnapshotVariant.lightDarkRu) {
            ShelfContentView(model: sampleModel(), handlers: .inert, onClose: {})
                .padding(20)
        }
        r.register("actions.shelf-empty", size: CGSize(width: 330, height: 170), backdrop: .wallpaper) {
            ShelfContentView(model: ShelfModel(), handlers: .inert, onClose: {})
                .padding(20)
        }
    }

    @MainActor
    private static func sampleModel() -> ShelfModel {
        ShelfModel(urls: ["/Users/swamp/Pictures/holiday-photo.heic", "/Users/swamp/Documents/Квартальный отчёт для бухгалтерии 2026.pdf", "/Users/swamp/Movies/clip.mov"]
            .map { URL(fileURLWithPath: $0) })
    }
}
