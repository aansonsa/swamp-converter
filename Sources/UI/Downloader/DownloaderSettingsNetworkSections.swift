import SwiftUI
import AppKit

/// The lower part of Settings > Downloader: speed limit, the bookmarklet / URL scheme (for browsers that expose no address to the app), the browser-automation row, and what
/// the app did on the network recently (hosts only, never a full address). Each block is a plain Form section.
struct DownloaderSettingsNetworkSections: View {
    @ObservedObject var settings: AppSettings
    @State private var copied = false
    @State private var activity: [NetworkEvent] = []

    /// Speed limits in KB/s the picker offers (0 = unlimited); a stored value that is not among them is added so it is never silently replaced.
    static let rateChoices = [0, 256, 512, 1_024, 2_048, 5_120, 10_240]

    static func rateTitle(_ kbps: Int) -> String {
        if kbps <= 0 { return L("No limit", "Без ограничения") }
        if kbps >= 1_024 { return L("\(kbps / 1_024) MB/s", "\(kbps / 1_024) МБ/с") }
        return L("\(kbps) KB/s", "\(kbps) КБ/с")
    }

    var body: some View {
        rateSection
        schemeSection
        automationSection
        activitySection
    }

    // MARK: Speed

    private var rateSection: some View {
        let current = settings.data.downloader.rateLimitKBps
        let choices = Self.rateChoices.contains(current) ? Self.rateChoices : (Self.rateChoices + [current]).sorted()
        return FormSection(L("Speed", "Скорость"), symbol: "speedometer") {
            Picker(L("Limit the speed", "Ограничить скорость"), selection: Binding(get: { current }, set: { v in settings.update { $0.downloader.rateLimitKBps = v } })) {
                ForEach(choices, id: \.self) { Text(Self.rateTitle($0)).tag($0) }
            }
            Picker(L("Parallel parts", "Параллельные части"), selection: Binding(get: { settings.data.downloader.fragments }, set: { v in settings.update { $0.downloader.concurrentFragments = v } })) {
                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
            }
            FormFootnote(L("The speed limit is handy when you need the connection for something else. More parallel parts download a video faster on a good connection; 1 is gentler.",
                           "Ограничение скорости удобно, когда соединение нужно для другого. Больше параллельных частей — быстрее загрузка на хорошем соединении; 1 — бережнее."))
        }
    }

    // MARK: Bookmarklet

    private var schemeSection: some View {
        let mode = settings.data.downloader.defaultMode
        let script = DownloadURLScheme.bookmarklet(mode: mode)
        return FormSection(L("From any browser", "Из любого браузера"), symbol: "bookmark",
                           footer: L("Make a bookmark in your browser and paste this line as its address. Clicking the bookmark sends the open page to Swamp Converter (address: \(DownloadURLScheme.scheme)://download).",
                                     "Создайте закладку в браузере и вставьте эту строку как её адрес. Нажатие на закладку отправляет открытую страницу в Swamp Converter (адрес: \(DownloadURLScheme.scheme)://download).")) {
            HStack(spacing: DS.Space.sm) {
                Text(script).font(DS.Typo.mono).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script, forType: .string)
                    copied = true
                } label: { Label(copied ? L("Copied", "Скопировано") : L("Copy", "Копировать"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .controlSize(.small).secondaryButtonLook()
            }
        }
    }

    // MARK: Automation

    private var automationSection: some View {
        FormSection(L("Reading the link from a browser", "Чтение ссылки из браузера"), symbol: "safari",
                    footer: L("Firefox does not share its address with other apps; use the bookmark above for it.", "Firefox не сообщает свой адрес другим приложениям; для него используйте закладку выше.")) {
            AutomationAccessRow(title: L("Browser permission", "Разрешение для браузера"),
                                help: L("To read the address of the page you are looking at, macOS asks once per browser to allow Swamp Converter to control it. “Allow Access…” asks now for every open browser; if you said no, change it in System Settings.",
                                        "Чтобы прочитать адрес открытой страницы, macOS один раз для каждого браузера спрашивает, можно ли Swamp Converter им управлять. «Разрешить доступ…» спрашивает сразу обо всех открытых браузерах; если вы отказали, измените это в Системных настройках."))
        }
    }

    // MARK: Recent network activity

    private var activitySection: some View {
        FormSection(L("Recent network activity", "Недавняя сетевая активность"), symbol: "network",
                    footer: L("Everything this app asked the network to do since it started. Only site names are listed.", "Всё, что приложение просило сделать в сети с момента запуска. Показаны только имена сайтов.")) {
            if activity.isEmpty {
                Text(L("Nothing yet.", "Пока ничего.")).foregroundStyle(.secondary)
            } else {
                ForEach(activity.suffix(8).reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                        Text(e.purpose.title.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.md)
                        if !e.host.isEmpty { Text(e.host).font(DS.Typo.caption).foregroundStyle(.secondary) }
                        Text(e.date, style: .time).font(DS.Typo.numeric(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { activity = NetworkGate.recentActivity }
    }
}
