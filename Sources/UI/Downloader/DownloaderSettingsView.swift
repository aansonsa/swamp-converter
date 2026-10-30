import SwiftUI
import AppKit

/// Settings > Downloader: the status of yt-dlp (version, where it was found, Install / Update with progress and the SHA-256 result), the opt-in update check (OFF by default), the
/// JavaScript runtime row, the cookies browser (explained), speed limit, the defaults of the quick path (folder, mode, after-download action, file names), the URL-scheme / bookmarklet
/// help, the browser-automation row, the recent network activity and the one-line usage notice. Everything is bound to `settings.downloader`; nothing is cached in the view.
struct DownloaderSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: YtDlpToolManager
    @StateObject private var install = YtDlpInstallModel()
    @StateObject private var probe: JSRuntimeProbe
    /// Is the installed file still the one whose checksum was verified? nil until checked (or when there is nothing to compare).
    @State private var integrity: Bool?
    /// Snapshots turn the live re-detection off so the page shows the state they set up.
    private let refreshesOnAppear: Bool

    init(settings: AppSettings = .shared, manager: YtDlpToolManager? = nil, probe: JSRuntimeProbe? = nil, refreshesOnAppear: Bool = true) {
        let manager = manager ?? .shared
        self.settings = settings
        self.manager = manager
        self._probe = StateObject(wrappedValue: probe ?? JSRuntimeProbe())
        self.refreshesOnAppear = refreshesOnAppear
    }

    private func binding<T>(_ keyPath: WritableKeyPath<DownloaderSettings, T>) -> Binding<T> {
        Binding(get: { settings.data.downloader[keyPath: keyPath] }, set: { value in settings.update { $0.downloader[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            consentSection
            toolSection
            runtimeSection
            signInSection
            defaultsSection
            DownloaderSettingsNetworkSections(settings: settings)
        }
        .formStyle(.grouped)
        .appRoot()
        .onAppear { if refreshesOnAppear { manager.applyDetected() } }
    }

    // MARK: Consent

    private var consentSection: some View {
        FormSection(L("Download from links", "Скачивание по ссылкам"), symbol: "arrow.down.circle",
                    footer: DownloadNotice.usageLine.text) {
            SettingsToggleRow(L("I agree to the notice", "Я согласен с уведомлением"),
                              help: L("Downloading uses the internet and the free program yt-dlp. Nothing is downloaded while this is off.",
                                      "Скачивание использует интернет и бесплатную программу yt-dlp. Пока это выключено, ничего не скачивается."),
                              symbol: "checkmark.shield", isOn: binding(\.consentGiven))
        }
    }

    // MARK: yt-dlp

    private var toolSection: some View {
        FormSection("yt-dlp", symbol: "shippingbox") {
            let status = manager.status
            ValueRow(L("Status", "Состояние"), value: status.isInstalled ? L("Installed", "Установлен") : L("Not installed", "Не установлен"))
            if status.isInstalled {
                ValueRow(L("Version", "Версия"), value: status.version ?? L("checking…", "проверка…"))
                ValueRow(L("Found", "Где найден"), value: Self.sourceText(status.source), help: status.url?.path)
            }
            installRow(status)
            SettingsToggleRow(L("Check for updates when I download", "Проверять обновления при загрузке"),
                              help: L("Off by default. When on, the app asks github.com once a day for the newest yt-dlp version and only tells you; it never updates by itself.",
                                      "По умолчанию выключено. Если включить, приложение раз в день спрашивает github.com о новейшей версии yt-dlp и только сообщает вам; само оно ничего не обновляет."),
                              symbol: "arrow.triangle.2.circlepath", isOn: binding(\.checkForUpdates))
        }
    }

    @ViewBuilder private func installRow(_ status: YtDlpStatus) -> some View {
        let managed = Self.isManagedByApp(status)
        // Installing and checking go online, which the notice above must allow first; without it the buttons only produced "agree first" errors.
        let agreed = settings.data.downloader.consentGiven
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                if !status.isInstalled {
                    Button(L("Install yt-dlp", "Установить yt-dlp")) { install.install() }.buttonStyle(.brandProminent).disabled(install.isWorking || !agreed)
                } else {
                    Button(L("Check for Update", "Проверить обновление")) { install.update() }.secondaryButtonLook().disabled(install.isWorking || !managed || !agreed)
                }
                if install.isWorking { Button(L("Cancel", "Отмена")) { install.cancel() }.secondaryButtonLook() }
                Spacer()
            }
            if !agreed {
                FormFootnote(L("Switch on “I agree to the notice” above first: installing downloads yt-dlp from github.com.",
                               "Сначала включите «Я согласен с уведомлением» выше: установка скачивает yt-dlp с github.com."))
            }
            switch install.phase {
            case .idle:
                if status.isInstalled && !managed {
                    FormFootnote(L("This copy is managed outside the app. Update it where you installed it, for example: brew upgrade yt-dlp.",
                                   "Эта копия управляется вне приложения. Обновите её там, где устанавливали, например: brew upgrade yt-dlp."))
                } else if managed, let record = settings.data.downloader.verifiedInstall {
                    verifiedNote(record)
                } else {
                    FormFootnote(L("Every install and update is checked against the official SHA-256 checksum. If the check fails, nothing is installed.",
                                   "Каждая установка и обновление проверяются по официальной контрольной сумме SHA-256. Если проверка не пройдена, ничего не устанавливается."))
                }
            case .working(let kind, let progress):
                SlantedProgressBar(value: progress)
                Text(YtDlpInstallModel.progressText(kind: kind, progress: progress)).font(DS.Typo.numeric(.caption)).foregroundStyle(.secondary)
            case .succeeded(let outcome):
                InlineMessage(YtDlpInstallModel.successText(outcome), tone: .success, onDismiss: { install.reset() })
            case .failed(let message):
                InlineMessage(message, tone: .error, detail: L("Nothing was changed.", "Ничего не изменено."), onDismiss: { install.reset() })
            }
        }
        .task(id: settings.data.downloader.verifiedInstall?.date ?? 0) { if refreshesOnAppear { integrity = await manager.installedMatchesVerifiedRecord() } }
    }

    /// The standing result of the last install or update: version, date, the start of the checksum, and whether the file on disk is still that file.
    @ViewBuilder private func verifiedNote(_ record: DownloaderSettings.VerifiedInstall) -> some View {
        let date = Date(timeIntervalSince1970: record.date).formatted(date: .abbreviated, time: .omitted)
        let short = String(record.sha256.prefix(12))
        if integrity == false {
            InlineMessage(L("The file on disk is not the one that was checked when it was installed. Install yt-dlp again to be safe.",
                            "Файл на диске не тот, что был проверен при установке. Для надёжности установите yt-dlp заново."), tone: .warning)
        } else {
            FormFootnote(L("Installed by the app on \(date), version \(record.version). Its SHA-256 (\(short)...) matched the official checksum\(integrity == true ? ", and the file on disk is unchanged" : "").",
                           "Установлено приложением \(date), версия \(record.version). Его SHA-256 (\(short)...) совпала с официальной контрольной суммой\(integrity == true ? ", файл на диске не менялся" : "")."))
        }
    }

    static func isManagedByApp(_ status: YtDlpStatus) -> Bool { status.source == .userFolder }

    static func sourceText(_ source: ToolSource?) -> String {
        switch source {
        case .userFolder: return L("Installed by Swamp Converter", "Установлен Swamp Converter")
        case .homebrew: return "Homebrew"
        case .path: return L("Found in PATH", "Найден в PATH")
        case .system: return L("System", "Система")
        case .userOverride: return L("Chosen in Settings > Tools", "Выбран в Настройки > Инструменты")
        case .bundled: return L("Inside the app", "Внутри приложения")
        case nil: return "\u{2014}"
        }
    }

    // MARK: JavaScript runtime

    private var runtimeSection: some View {
        FormSection(L("JavaScript runtime", "JavaScript-движок"), symbol: "curlybraces") {
            JSRuntimeStatusView(probe: probe)
            Button(L("Check Again", "Проверить снова")) { Task { await probe.refresh() } }.secondaryButtonLook().controlSize(.small)
        }
    }

    // MARK: Sign-in

    private var signInSection: some View {
        FormSection(L("Sites that ask you to sign in", "Сайты, которые просят войти"), symbol: "person.badge.key",
                    footer: L("Only for sites that ask you to sign in or restrict a video by age. yt-dlp reads the cookies of the chosen browser on this Mac when it downloads; the app does not store them.",
                              "Только для сайтов, которые просят войти или ограничивают видео по возрасту. yt-dlp читает cookies выбранного браузера на этом Mac во время загрузки; приложение их не хранит.")) {
            Picker(L("Use the sign-in of", "Использовать вход из"), selection: binding(\.cookies)) {
                ForEach(CookieBrowser.allCases, id: \.self) { Text($0.title.text).tag($0) }
            }
        }
    }

    // MARK: Defaults

    private var defaultsSection: some View {
        FormSection(L("Defaults", "По умолчанию"), symbol: "slider.horizontal.3",
                    footer: L("These apply to the quick path (the wheel, the hotkey, the menu bar). The download window lets you change them for one download.",
                              "Это действует для быстрого пути (колесо, горячая клавиша, меню-бар). В окне загрузки их можно изменить для одной загрузки.")) {
            Picker(L("Mode for the hotkey", "Режим для горячей клавиши"), selection: binding(\.defaultMode)) {
                ForEach(DownloadMode.allCases, id: \.self) { Text($0.title.text).tag($0) }
            }
            Picker(L("After download", "После загрузки"), selection: binding(\.afterDownload)) {
                Text(L("Keep as downloaded", "Оставить как скачано")).tag(AfterDownload.keepOriginal)
                Text(SmartMode.bestForApple.title.text).tag(AfterDownload.bestForApple)
                Text(SmartMode.universal.title.text).tag(AfterDownload.universal)
            }
            SettingsRow(L("Save to", "Куда сохранять"), help: L("Default: Movies / Swamp Converter (Music / Swamp Converter for sound).", "По умолчанию: Фильмы / Swamp Converter (Музыка / Swamp Converter для звука).")) {
                HStack(spacing: DS.Space.sm) {
                    Text(settings.data.downloader.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("Default", "По умолчанию"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button(L("Choose…", "Выбрать…")) {
                        let start = settings.data.downloader.folder.map { URL(fileURLWithPath: $0) }
                        if let url = DownloadFolderChooser.choose(starting: start) { settings.update { $0.downloader.folder = url.path } }
                    }.controlSize(.small).secondaryButtonLook()
                    if settings.data.downloader.folder != nil {
                        Button(L("Default", "По умолчанию")) { settings.update { $0.downloader.folder = nil } }.controlSize(.small).secondaryButtonLook()
                    }
                }
            }
            DownloaderTemplateRow(settings: settings)
            SettingsToggleRow(L("Add title and chapters to the file", "Записывать название и главы в файл"), isOn: binding(\.embedMetadata))
            SettingsToggleRow(L("Add the cover picture to the file", "Добавлять обложку в файл"), isOn: binding(\.embedThumbnail))
            SettingsToggleRow(L("Download subtitles", "Скачивать субтитры"), isOn: binding(\.subtitles))
            if settings.data.downloader.subtitles {
                SettingsRow(L("Subtitle languages", "Языки субтитров"), help: L("Codes separated by commas, for example en,de.", "Коды через запятую, например en,de.")) {
                    TextField("", text: binding(\.subtitleLanguages), prompt: Text("en,de")).labelsHidden().frame(maxWidth: 140).multilineTextAlignment(.trailing)
                }
                let canBurn = Capabilities.shared.has("ff.filter.subtitles")
                SettingsToggleRow(L("Burn subtitles into the picture", "Вшивать субтитры в картинку"),
                                  help: canBurn ? nil : L("Needs an ffmpeg with subtitle drawing (libass), which is not installed.", "Нужен ffmpeg с отрисовкой субтитров (libass), он не установлен."),
                                  isOn: binding(\.burnSubtitles)).disabled(!canBurn)
            }
        }
    }
}

/// The file name template with its safety check: only a template that stays inside the download folder is stored.
struct DownloaderTemplateRow: View {
    @ObservedObject var settings: AppSettings
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SettingsRow(L("File name", "Имя файла"), help: L("Fields: %(title)s %(id)s %(uploader)s %(upload_date)s %(ext)s. It can never point outside the folder.",
                                                               "Поля: %(title)s %(id)s %(uploader)s %(upload_date)s %(ext)s. Файл не может оказаться вне папки.")) {
                TextField("", text: $text).labelsHidden().frame(maxWidth: 240).font(DS.Typo.mono)
                    .onChange(of: text) { _, new in
                        if YtDlpArguments.isSafeTemplate(new) { settings.update { $0.downloader.filenameTemplate = new } }
                    }
            }
            if !text.isEmpty && !YtDlpArguments.isSafeTemplate(text) {
                InlineMessage(L("This template is not allowed: it must stay inside the download folder.", "Этот шаблон недопустим: файл должен оставаться в папке загрузки."), tone: .warning,
                              fixTitle: L("Restore the Default", "Вернуть по умолчанию"), onFix: { text = DownloaderSettings().filenameTemplate })
            }
        }
        .onAppear { if !loaded { text = settings.data.downloader.filenameTemplate; loaded = true } }
    }
}
