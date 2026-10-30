import SwiftUI

// Snapshot sheets, part 3: the adaptive picker in wide and narrow columns.

struct PickerSheet: View {
    @State private var mode = 1
    private var options: [(value: Int, label: String)] {
        [(1, L("Best for Apple", "Лучшее для Apple и других устройств")), (2, L("Maximum quality", "Максимальное качество")), (3, L("Universal", "Универсальный"))]
    }
    private var short: [(value: Int, label: String)] {
        [(1, L("Quick", "Быстро")), (2, L("Balanced", "Баланс")), (3, L("Small", "Мало"))]
    }

    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                caption(L("Short labels: a segmented control", "Короткие подписи: сегментированный переключатель"))
                AdaptivePicker(L("Preset", "Пресет"), selection: $mode, options: short)
                caption(L("Long labels in a wide column: segmented when it fits", "Длинные подписи в широкой колонке: сегменты, если помещаются"))
                AdaptivePicker(L("Mode", "Режим"), selection: $mode, options: options).frame(width: 520, alignment: .leading)
                caption(L("The same labels in a narrow column: a menu, never a clipped control", "Те же подписи в узкой колонке: меню, а не обрезанный переключатель"))
                AdaptivePicker(L("Mode", "Режим"), selection: $mode, options: options).frame(width: 260, alignment: .leading)
                Form {
                    SettingsRow(L("Mode", "Режим")) { AdaptivePicker(L("Mode", "Режим"), selection: $mode, options: options) }
                }
                .formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 90)
                Spacer(minLength: 0)
            }
        }
    }

    private func caption(_ text: String) -> some View { Text(text).font(DS.Typo.caption).foregroundStyle(.secondary) }
}

extension SharedModule {
    @MainActor static func registerPickerSnapshots() {
        SnapshotRegistry.shared.register("shared.picker", size: CGSize(width: 600, height: 420), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) { PickerSheet() }
    }
}
