import SwiftUI

/// Settings > Recipes: the five quality knobs, the quick recipe of any operation, and the preset list.
struct RecipesPage: View {
    @ObservedObject private var settings: AppSettings
    private let registry: OperationRegistry
    private let store: PresetStore
    private let initialOperation: String?

    init(settings: AppSettings = .shared, registry: OperationRegistry = .shared, store: PresetStore? = nil, initialOperation: String? = nil) {
        _settings = ObservedObject(wrappedValue: settings)
        self.registry = registry
        self.store = store ?? .shared
        self.initialOperation = initialOperation
    }

    var body: some View {
        Form {
            qualitySection
            QuickRecipeEditor(settings: settings, registry: registry, initial: initialOperation)
            PresetsSection(store: store, registry: registry)
        }
        .formStyle(.grouped)
        .appRoot()
    }

    // MARK: Quality

    private static let dpiChoices = [72, 96, 150, 200, 300, 450, 600]

    private var qualitySection: some View {
        FormSection(L("Quality", "Качество"), symbol: "dial.medium",
                    footer: L("These feed the quick recipes of the matching operations. In the Studio every job can still choose its own values.",
                              "Эти значения используются в быстрых рецептах соответствующих операций. В Студии для каждой задачи можно выбрать свои.")) {
            qualityRow(L("JPEG and WebP quality", "Качество JPEG и WebP"), \.quality.jpegQuality, 40...100, 1, "quality.jpegQuality",
                       low: L("Smaller file", "Меньше файл"), high: L("Better quality", "Лучше качество"))
            qualityRow(L("Image compression quality", "Качество при сжатии изображений"), \.quality.compressQuality, 20...95, 1, "quality.compressQuality",
                       low: L("Smaller file", "Меньше файл"), high: L("Better quality", "Лучше качество"))
            SettingsRow(L("PDF to images resolution", "Разрешение PDF в изображения"), help: L("Dots per inch. 300 is sharp enough to print.", "Точек на дюйм. 300 достаточно для печати.")) {
                SettingsMenuPicker(L("PDF to images resolution", "Разрешение PDF в изображения"), selection: settings.binding(\.quality.pdfDpi), options: dpiOptions)
            }.settingsKey("quality.pdfDpi")
            qualityRow(L("Video quality (H.264)", "Качество видео (H.264)"), \.quality.videoCrf, 16...32, 1, "quality.videoCrf",
                       low: L("Better quality", "Лучше качество"), high: L("Smaller file", "Меньше файл"), help: L("Lower numbers keep more detail and make bigger files.", "Меньшие числа сохраняют больше деталей, но файл получается больше."))
            qualityRow(L("Compressed video quality", "Качество сжатого видео"), \.quality.compressVideoCrf, 20...40, 1, "quality.compressVideoCrf",
                       low: L("Better quality", "Лучше качество"), high: L("Smaller file", "Меньше файл"), help: L("Used by “Compress video”.", "Используется командой «Сжать видео»."))
        }
    }

    private var dpiOptions: [(value: Int, label: String)] {
        var list = Self.dpiChoices
        let current = settings.data.quality.pdfDpi
        if !list.contains(current) { list.append(current); list.sort() }
        return list.map { (value: $0, label: "\($0) dpi") }
    }

    private func qualityRow(_ title: String, _ keyPath: WritableKeyPath<SettingsData, Int>, _ range: ClosedRange<Double>, _ step: Double, _ key: String,
                            low: String, high: String, help: String? = nil) -> some View {
        SettingsRow(title, help: help) {
            HStack(spacing: DS.Space.sm) {
                CommitSlider(title, value: settings.binding(keyPath, get: { Double($0) }, set: { v, _ in Int(v.rounded()) }), in: range, step: step, minLabel: low, maxLabel: high)
                    .frame(maxWidth: 300)
                Text("\(settings.data[keyPath: keyPath])").font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
            }
        }
        .settingsKey(key)
    }
}
