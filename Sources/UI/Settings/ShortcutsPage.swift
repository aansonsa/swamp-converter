import SwiftUI

/// Settings > Shortcuts: the two global shortcuts (wheel; download the current browser page) with a recorder each, what the wheel shortcut reads, and where macOS keeps the
/// permissions it needs. `HotkeyManager` registers the chords; this page only edits the settings and shows what the manager reports.
struct ShortcutsPage: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var manager: HotkeyManager

    init(settings: AppSettings = .shared, manager: HotkeyManager? = nil) {
        _settings = ObservedObject(wrappedValue: settings)
        _manager = ObservedObject(wrappedValue: manager ?? .shared)
    }

    var body: some View {
        Form {
            wheelSection
            downloadSection
            readsSection
            if !manager.registrationNotes.isEmpty { notesSection }
            servicesSection
        }
        .formStyle(.grouped)
        .appRoot()
    }

    // MARK: The two shortcuts

    private var wheelSection: some View {
        FormSection(L("Wheel shortcut", "Сочетание для колеса"), symbol: "circle.hexagongrid",
                    footer: L("Opens the wheel for the files selected in Finder, the page open in your browser, or an image on the clipboard.",
                              "Открывает колесо для файлов, выбранных в Finder, страницы в браузере или изображения в буфере обмена.")) {
            SettingsToggleRow(L("Open the wheel with a shortcut", "Открывать колесо сочетанием клавиш"), isOn: settings.binding(\.hotkey.enabled))
            SettingsRow(L("Shortcut", "Сочетание")) {
                HotkeyRecorder(setting: settings.binding(\.hotkey), other: settings.data.downloadHotkey, defaultSetting: HotkeySetting(),
                               presets: HotkeyPresets.wheelFallbacks, registration: manager.wheel, title: L("Wheel shortcut", "Сочетание для колеса"))
            }.settingsKey("hotkey")
        }
    }

    private var downloadSection: some View {
        FormSection(L("Download shortcut", "Сочетание для загрузки"), symbol: "arrow.down.circle",
                    footer: L("Downloads the page open in your browser at once, without the wheel, using the default mode of the Downloader. The Downloader asks for your consent before it ever touches the network.",
                              "Сразу скачивает страницу, открытую в браузере, без колеса, в режиме по умолчанию из настроек загрузки. Перед выходом в сеть загрузчик всегда спрашивает ваше согласие.")) {
            SettingsToggleRow(L("Download with a shortcut", "Скачивать сочетанием клавиш"), isOn: settings.binding(\.downloadHotkey.enabled))
            SettingsRow(L("Shortcut", "Сочетание")) {
                HotkeyRecorder(setting: settings.binding(\.downloadHotkey), other: settings.data.hotkey, defaultSetting: .downloadDefault,
                               presets: HotkeyPresets.downloadFallbacks, registration: manager.download, title: L("Download shortcut", "Сочетание для загрузки"))
            }.settingsKey("downloadHotkey")
        }
    }

    // MARK: What the wheel shortcut reads

    private var readsSection: some View {
        FormSection(L("What the shortcut looks at", "Что учитывает сочетание"), symbol: "eye",
                    footer: L("macOS asks once before the app may control Finder or a browser. You can review the answer in System Settings > Privacy & Security > Automation.",
                              "macOS один раз спросит разрешение, прежде чем приложение сможет управлять Finder или браузером. Ответ можно проверить в Системных настройках > Конфиденциальность и безопасность > Автоматизация.")) {
            SettingsToggleRow(L("Use the files selected in Finder", "Использовать файлы, выбранные в Finder"),
                              isOn: settings.binding(\.gestures.hotkeyUsesFinderSelection)).settingsKey("gestures.hotkeyUsesFinderSelection")
            SettingsToggleRow(L("Read the page in the front browser", "Читать страницу в браузере на переднем плане"),
                              help: L("Looks at the selected text, then the open tab, then the clipboard for a link.", "Ищет ссылку сначала в выделенном тексте, затем во вкладке, затем в буфере обмена."),
                              isOn: settings.binding(\.hotkeyReadsBrowser)).settingsKey("hotkeyReadsBrowser")
            AutomationAccessRow(title: L("Automation permission", "Разрешение «Автоматизация»"),
                                help: L("Asks macOS now for Finder and every open browser, so Swamp Converter shows up in the Automation list.",
                                        "Сразу спрашивает macOS о Finder и всех открытых браузерах, чтобы Swamp Converter появился в списке «Автоматизация»."))
            AccessibilityAccessRow(title: L("Selected-text permission", "Разрешение «Выделенный текст»"),
                                   help: L("Lets the shortcut read a link you have selected in any app. It is the way to go in Dia and Firefox, which cannot share their open tab.",
                                           "Позволяет сочетанию читать ссылку, выделенную в любом приложении. Это основной способ для Dia и Firefox, которые не сообщают открытую вкладку."))
        }
    }

    private var notesSection: some View {
        FormSection(L("Shortcut status", "Состояние сочетаний"), symbol: "info.circle") {
            ForEach(Array(manager.registrationNotes.enumerated()), id: \.offset) { _, note in
                InlineMessage(note.text, tone: .info)
            }
        }
    }

    private var servicesSection: some View {
        FormSection(L("Services", "Службы"), symbol: "contextualmenu.and.cursorarrow",
                    footer: L("In Finder, right-click files and choose Services to send them to the wheel. You can give a Service its own key in System Settings > Keyboard > Keyboard Shortcuts > Services.",
                              "В Finder щёлкните файлы правой кнопкой и выберите «Службы», чтобы отправить их на колесо. Для службы можно назначить своё сочетание в Системных настройках > Клавиатура > Сочетания клавиш > Службы.")) {
            SettingsRow(L("Keyboard shortcuts for Services", "Сочетания для служб")) {
                Button(L("Open System Settings…", "Открыть Системные настройки…")) { SettingsLinks.open(SettingsLinks.servicesShortcuts) }
            }
        }
    }
}
