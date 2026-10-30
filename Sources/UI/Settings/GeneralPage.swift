import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings > General: language and appearance, where results go and how they are named, privacy, startup and quit, notifications, parallel jobs, the Terminal of the Actions wheel.
/// Every control is bound to `AppSettings` through `settings.binding(...)`; nothing here keeps a second copy of a value.
struct GeneralPage: View {
    @ObservedObject private var settings: AppSettings
    @State private var loginState: LoginItem.State = .disabled
    @State private var loginNote: String?

    init(settings: AppSettings = .shared) { _settings = ObservedObject(wrappedValue: settings) }

    private var output: Binding<OutputRules> { settings.binding(\.output) }

    var body: some View {
        Form {
            SetupChecklistSection()
            appearanceSection
            resultsSection
            privacySection
            startupSection
            notificationsSection
            performanceSection
            actionsSection
        }
        .formStyle(.grouped)
        .onAppear { refreshLogin(mirror: true) }
        .appRoot()
    }

    // MARK: Language and appearance

    private var appearanceSection: some View {
        FormSection(L("Appearance", "Оформление"), symbol: "paintbrush") {
            SettingsRow(L("Appearance", "Оформление")) {
                AdaptivePicker(L("Appearance", "Оформление"), selection: appearanceBinding,
                               options: AppearanceSetting.allCases.map { ($0, SettingsLabels.appearance($0)) })
            }.settingsKey("appearance")
            SettingsToggleRow(L("Show the icon in the menu bar", "Показывать значок в строке меню"),
                              help: L("The menu-bar icon is the quickest way to open the Studio, the queue and these settings.",
                                      "Значок в строке меню - самый быстрый путь к Студии, очереди и этим настройкам."),
                              isOn: settings.binding(\.showMenuBarIcon)).settingsKey("showMenuBarIcon")
            SettingsToggleRow(L("Keep a Dock icon while the Studio is open", "Держать значок в Dock, пока открыта Студия"),
                              help: L("Lets you switch to the Studio with Command-Tab. The icon goes away when the last window closes.",
                                      "Позволяет переключаться на Студию через Command-Tab. Значок исчезает, когда закрывается последнее окно."),
                              isOn: Binding(get: { settings.data.showDockIconWithStudio },
                                            set: { v in settings.update { $0.showDockIconWithStudio = v }; WindowPresence.shared.settingChanged() }))
                .settingsKey("showDockIconWithStudio")
        }
    }

    private var appearanceBinding: Binding<AppearanceSetting> {
        Binding(get: { settings.data.appearance },
                set: { value in settings.update { $0.appearance = value }; SettingsEffects.applyAppearance(value) })
    }

    // MARK: Results

    private var resultsSection: some View {
        FormSection(L("Results", "Результаты"), symbol: "folder.badge.gearshape",
                    footer: L("These are the defaults for the wheel, watched folders and Services. The Studio can change them for one job.",
                              "Это значения по умолчанию для колеса, отслеживаемых папок и Служб. В Студии их можно изменить для одной задачи.")) {
            SettingsRow(L("Where results go", "Куда попадают результаты")) {
                SettingsMenuPicker(L("Where results go", "Куда попадают результаты"), selection: settings.binding(\.output.dirMode),
                                   options: [OutputDirMode.sameAsSource, .subfolder, .custom].map { ($0, SettingsLabels.outputMode($0)) })
            }.settingsKey("output.dirMode")
            SettingsRow(L("Subfolder name", "Название подпапки")) {
                TextField(L("Subfolder name", "Название подпапки"), text: settings.binding(\.output.subfolderName), prompt: Text("Converted"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 180)
                    .disabled(output.wrappedValue.dirMode != .subfolder)
            }.settingsKey("output.subfolderName")
            SettingsFolderRow(title: L("Chosen folder", "Выбранная папка"), help: nil, symbol: nil,
                              placeholder: L("No folder chosen", "Папка не выбрана"), path: settings.binding(\.output.customDir),
                              enabled: output.wrappedValue.dirMode == .custom)
                .settingsKey("output.customDir")
            if output.wrappedValue.dirMode == .custom, (output.wrappedValue.customDir ?? "").isEmpty {
                InlineMessage(L("Choose a folder, or results keep going next to the originals.", "Выберите папку, иначе результаты по-прежнему будут рядом с оригиналами."),
                              tone: .warning)
            }
            SettingsRow(L("Name of the new file", "Имя нового файла"),
                        help: L("Tokens: {name} {suffix} {preset} {date} {time}; for video also {codec} {res} {width} {height} {fps} {quality} {container}. Unknown tokens are dropped.",
                                "Метки: {name} {suffix} {preset} {date} {time}; для видео ещё {codec} {res} {width} {height} {fps} {quality} {container}. Неизвестные метки удаляются.")) {
                TextField(L("Name template", "Шаблон имени"), text: settings.binding(\.output.nameTemplate), prompt: Text("{name}"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { normaliseTemplate() }
            }.settingsKey("output.nameTemplate")
            SettingsRow(L("When a file with that name exists", "Если файл с таким именем уже есть")) {
                SettingsMenuPicker(L("When a file with that name exists", "Если файл с таким именем уже есть"), selection: settings.binding(\.output.collision),
                                   options: [OutputCollision.number, .replace, .skip].map { ($0, SettingsLabels.collision($0)) })
            }.settingsKey("output.collision")
            SettingsToggleRow(L("Keep the original dates", "Сохранять даты оригинала"),
                              help: L("The new file gets the creation and modification dates of the original.", "Новый файл получает даты создания и изменения оригинала."),
                              isOn: settings.binding(\.output.keepDates)).settingsKey("output.keepDates")
            SettingsToggleRow(L("Show the result in Finder when done", "Показывать результат в Finder по завершении"),
                              isOn: settings.binding(\.revealResult)).settingsKey("revealResult")
            SettingsFolderRow(title: L("Folder for dragged-in images and links", "Папка для перетащенных изображений и ссылок"),
                              help: L("Pictures dragged from a browser or taken from the clipboard are saved here before they are converted.",
                                      "Картинки, перетащенные из браузера или взятые из буфера обмена, сохраняются сюда перед конвертацией."),
                              symbol: nil, placeholder: L("Downloads / Swamp Converter", "Загрузки / Swamp Converter"),
                              path: settings.binding(\.incomingFolder)).settingsKey("incomingFolder")
        }
    }

    private func normaliseTemplate() {
        let t = output.wrappedValue.nameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { settings.update { $0.output.nameTemplate = "{name}" } }
    }

    // MARK: Privacy

    private var privacySection: some View {
        FormSection(L("Privacy and clipboard", "Приватность и буфер обмена"), symbol: "hand.raised") {
            SettingsToggleRow(L("Always remove location and camera data", "Всегда удалять данные о месте и камере"),
                              help: L("Applies to quick and automatic runs, where the format allows it. In the Studio the field keeps its own value unless you leave it at the default.",
                                      "Действует для быстрых и автоматических запусков, если формат это позволяет. В Студии поле хранит своё значение, пока вы не оставите его по умолчанию."),
                              isOn: settings.binding(\.alwaysStripMetadata)).settingsKey("alwaysStripMetadata")
            SettingsToggleRow(L("Offer an image from the clipboard", "Предлагать изображение из буфера обмена"),
                              help: L("When you press the wheel shortcut with nothing selected and an image on the clipboard, the wheel offers to convert it.",
                                      "Если нажать сочетание колеса без выделенных файлов, а в буфере обмена есть изображение, колесо предложит его преобразовать."),
                              isOn: settings.binding(\.offerClipboardImage)).settingsKey("offerClipboardImage")
        }
    }

    // MARK: Startup and quit

    private var startupSection: some View {
        FormSection(L("Startup and quit", "Запуск и выход"), symbol: "power") {
            SettingsToggleRow(L("Open at login", "Открывать при входе в систему"),
                              help: L("Starts quietly in the menu bar. macOS keeps the final say and you can change it in System Settings.",
                                      "Запускается тихо в строке меню. Последнее слово за macOS: это можно изменить в Системных настройках."),
                              isOn: launchBinding)
                .disabled(loginState == .unavailable).settingsKey("launchAtLogin")
            if loginState == .requiresApproval {
                InlineMessage(L("macOS is waiting for your approval in Login Items.", "macOS ждёт вашего подтверждения в разделе «Объекты входа»."), tone: .warning,
                              fixTitle: L("Open Login Items", "Открыть «Объекты входа»"), onFix: { SettingsLinks.open(SettingsLinks.loginItems) })
            } else if loginState == .unavailable {
                InlineMessage(L("Open at login is not available for this copy of the app.", "Для этой копии приложения запуск при входе недоступен."), tone: .info)
            } else if let loginNote {
                InlineMessage(loginNote, tone: .warning, onDismiss: { self.loginNote = nil })
            }
            SettingsToggleRow(L("Ask before quitting while jobs are running", "Спрашивать перед выходом, пока идут задачи"),
                              isOn: settings.binding(\.confirmQuitWithJobs)).settingsKey("confirmQuitWithJobs")
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { settings.data.launchAtLogin }, set: { setLaunch($0) })
    }

    private func setLaunch(_ on: Bool) {
        loginNote = nil
        do { try LoginItem.set(enabled: on) } catch { loginNote = ConversionError.describe(error) }
        refreshLogin(mirror: true)
        if on, loginNote == nil, !(loginState == .enabled || loginState == .requiresApproval) {
            loginNote = L("macOS did not turn it on. Check System Settings > General > Login Items & Extensions.", "macOS не включил запуск при входе. Проверьте Системные настройки > Основные > Объекты входа.")
        }
    }

    private func refreshLogin(mirror: Bool) {
        loginState = LoginItem.state
        guard mirror else { return }
        let actual = loginState == .enabled || loginState == .requiresApproval
        if settings.data.launchAtLogin != actual { settings.update { $0.launchAtLogin = actual } }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        FormSection(L("Notifications and sound", "Уведомления и звук"), symbol: "bell") {
            SettingsRow(L("Tell me when a job finishes", "Сообщать о завершении задачи")) {
                SettingsMenuPicker(L("Tell me when a job finishes", "Сообщать о завершении задачи"), selection: settings.binding(\.notificationMode),
                                   options: [NotificationMode.background, .always, .off].map { ($0, SettingsLabels.notifications($0)) })
            }.settingsKey("notificationMode")
            SettingsToggleRow(L("Play a sound when a job finishes", "Звук по завершении задачи"),
                              help: L("Off by default. The sound is never the only signal.", "По умолчанию выключен. Звук никогда не бывает единственным сигналом."),
                              isOn: settings.binding(\.completionSound)).settingsKey("completionSound")
            SettingsRow(L("System notification settings", "Системные настройки уведомлений"), help: L("Banners, alerts and Focus are controlled by macOS.", "Баннеры, оповещения и фокусирование настраиваются в macOS.")) {
                Button(L("Open…", "Открыть…")) { SettingsLinks.open(SettingsLinks.notifications) }
            }
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        FormSection(L("Performance", "Производительность"), symbol: "speedometer",
                    footer: L("The app never runs more jobs than your Mac has performance cores, and runs fewer in Low Power Mode or when the Mac is hot.",
                              "Приложение не запускает больше задач, чем у вашего Mac производительных ядер, и запускает меньше в режиме энергосбережения или при нагреве.")) {
            SettingsRow(L("Jobs at the same time", "Одновременных задач")) {
                HStack(spacing: DS.Space.sm) {
                    Text("\(settings.data.maxConcurrentJobs)").font(DS.Typo.numeric(.body)).frame(minWidth: 18, alignment: .trailing)
                    Stepper(L("Jobs at the same time", "Одновременных задач"), value: settings.binding(\.maxConcurrentJobs), in: 1...Self.jobCeiling).labelsHidden()
                }
            }.settingsKey("maxConcurrentJobs")
            SettingsToggleRow(L("Pause automatic work on battery", "Приостанавливать автоматическую работу от батареи"),
                              help: L("Watched folders and chains wait until the Mac is plugged in.", "Отслеживаемые папки и цепочки ждут подключения к сети."),
                              isOn: settings.binding(\.pauseBackgroundOnBattery)).settingsKey("pauseBackgroundOnBattery")
            SettingsToggleRow(L("Check free space before a job", "Проверять свободное место перед задачей"),
                              help: L("Warns, or refuses to start, when the result would not fit on the disk.", "Предупреждает или не запускает задачу, если результат не поместится на диск."),
                              isOn: settings.binding(\.freeSpaceGuard)).settingsKey("freeSpaceGuard")
        }
    }

    /// What the scheduler will really run at once (the performance cores), so the stepper never offers a number that silently does nothing more.
    static var jobCeiling: Int {
        let env = SystemEnvironment.current()
        return max(1, min(8, env.performanceCores ?? max(env.cores / 2, 1)))
    }

    // MARK: Actions wheel

    private var actionsSection: some View {
        FormSection(L("Actions wheel", "Колесо действий"), symbol: "bolt") {
            SettingsRow(L("Terminal app", "Приложение Терминал"), help: L("Used by “Terminal: open here” on the Actions wheel.", "Используется командой «Терминал: открыть здесь» на колесе действий.")) {
                SettingsMenuPicker(L("Terminal app", "Приложение Терминал"), selection: terminalBinding, options: terminalOptions)
            }.settingsKey("terminalApp")
            SettingsToggleRow(L("Keep the shelf between launches", "Сохранять полку между запусками"),
                              help: L("The shelf holds files you set aside from the Actions wheel.", "На полке лежат файлы, отложенные с колеса действий."),
                              isOn: settings.binding(\.shelfPersist)).settingsKey("shelfPersist")
        }
    }

    private static let otherTag = "\u{0}other"

    private var terminalOptions: [(value: String, label: String)] {
        var list = TerminalApps.known.map { (value: $0.name, label: $0.name) }
        let current = TerminalApps.choice(for: settings.data.terminalApp)
        if !list.contains(where: { $0.value == current.name }) { list.append((value: current.name, label: current.name)) }
        list.append((value: Self.otherTag, label: L("Other app…", "Другое приложение…")))
        return list
    }

    private var terminalBinding: Binding<String> {
        Binding(get: { TerminalApps.choice(for: settings.data.terminalApp).name },
                set: { name in
                    if name == Self.otherTag { chooseTerminal(); return }
                    settings.update { $0.terminalApp = name == TerminalApps.terminal.name ? nil : name }
                })
    }

    private func chooseTerminal() {
        guard let url = SettingsPanels.chooseFile(title: L("Choose a terminal app", "Выберите приложение-терминал"), types: [.applicationBundle],
                                                  start: URL(fileURLWithPath: "/Applications", isDirectory: true)) else { return }
        settings.update { $0.terminalApp = url.path }
    }
}
