import SwiftUI
import AppKit

// Small controls and the option labels shared by several Settings pages. Nothing here owns a setting; the pages bind them with `AppSettings.binding(...)`.

/// A pop-up menu with a hidden label (the row draws the title) and a spoken name.
struct SettingsMenuPicker<T: Hashable>: View {
    var title: String
    @Binding var selection: T
    var options: [(value: T, label: String)]

    init(_ title: String, selection: Binding<T>, options: [(value: T, label: String)]) {
        self.title = title; self._selection = selection; self.options = options
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(Text(title))
    }
}

/// A folder setting: the chosen path (or the default's description), "Choose..." and "Use the default". The path wraps in the middle and can be selected.
struct SettingsFolderRow: View {
    var title: String
    var help: String?
    var symbol: String?
    /// Shown when no folder is chosen.
    var placeholder: String
    @Binding var path: String?
    var enabled = true
    var allowsClear = true

    var body: some View {
        SettingsRow(title, help: help, symbol: symbol) {
            HStack(spacing: DS.Space.sm) {
                Text(displayPath)
                    .font(DS.Typo.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: 220, alignment: .trailing)
                Button(L("Choose…", "Выбрать…")) { choose() }
                    .disabled(!enabled)
                if allowsClear, path != nil {
                    Button(L("Use Default", "По умолчанию")) { path = nil }.disabled(!enabled)
                }
            }
        }
    }

    private var displayPath: String {
        guard let path, !path.isEmpty else { return placeholder }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func choose() {
        let start = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let url = SettingsPanels.chooseFolder(title: title, start: start) { path = url.path }
    }
}

/// The readable names of the enum-valued settings (one place, both languages).
enum SettingsLabels {
    static func language(_ v: LanguageSetting) -> String {
        switch v {
        case .system: return L("Same as macOS", "Как в macOS")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    static func appearance(_ v: AppearanceSetting) -> String {
        switch v {
        case .system: return L("Automatic", "Авто")
        case .light: return L("Light", "Светлая")
        case .dark: return L("Dark", "Тёмная")
        }
    }

    static func outputMode(_ v: OutputDirMode) -> String {
        switch v {
        case .sameAsSource: return L("Next to the original", "Рядом с оригиналом")
        case .subfolder: return L("In a subfolder next to the original", "В подпапке рядом с оригиналом")
        case .custom: return L("In a folder I choose", "В выбранной папке")
        }
    }

    static func collision(_ v: OutputCollision) -> String {
        switch v {
        case .number: return L("Add a number to the new file", "Добавить номер к новому файлу")
        case .replace: return L("Replace the existing file", "Заменить существующий файл")
        case .skip: return L("Skip that file", "Пропустить этот файл")
        }
    }

    static func notifications(_ v: NotificationMode) -> String {
        switch v {
        case .background: return L("When the app is in the background", "Когда приложение в фоне")
        case .always: return L("Always", "Всегда")
        case .off: return L("Never", "Никогда")
        }
    }

    static func modifier(_ v: ModifierKey) -> String {
        switch v {
        case .none: return L("None", "Нет")
        case .shift: return "Shift \u{21E7}"
        case .control: return "Control \u{2303}"
        case .option: return "Option \u{2325}"
        case .command: return "Command \u{2318}"
        }
    }
}
