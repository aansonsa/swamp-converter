import Foundation

// NETWORK POLICY. The app is 100 percent local EXCEPT the downloader, and the downloader only touches the network after an explicit
// user action and the first-use consent. This file is the single checkpoint: every network call in the code base (yt-dlp runs, the
// yt-dlp install / update-check fetches) calls `NetworkGate.authorize(...)` first. If it throws, the call must not happen.
//
//   * `--self-test` and `--snapshot` set `forbidAll`, so a test that accidentally reaches for the network fails loudly instead of
//     contacting a server (agents must never make real requests while developing).
//   * Consent is `settings.downloader.consentGiven`, written only by the consent sheet / Settings > Downloader.
//   * Every authorised call is recorded in a small in-memory ring that Settings > Downloader shows ("Recent network activity").

enum NetworkPurpose: String, Sendable {
    /// Download the yt-dlp release asset + its SHA2-256SUMS (the explicit "Install yt-dlp" button).
    case installYtDlp
    /// Ask GitHub for the latest yt-dlp version (the "Update" button, or the opt-in check on use).
    case updateCheckYtDlp
    /// yt-dlp fetching info / media (spawned process: the app itself opens no socket).
    case mediaInfo
    case mediaDownload

    var title: L10n {
        switch self {
        case .installYtDlp: return L10n("Install yt-dlp from the official release", "Установка yt-dlp с официального релиза")
        case .updateCheckYtDlp: return L10n("Check for a yt-dlp update", "Проверка обновления yt-dlp")
        case .mediaInfo: return L10n("Fetch information about a link", "Получение сведений о ссылке")
        case .mediaDownload: return L10n("Download from a link", "Загрузка по ссылке")
        }
    }
}

struct NetworkEvent: Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var purpose: NetworkPurpose
    /// Host only ("github.com", "youtube.com"): never a full URL, never a query.
    var host: String
}

enum NetworkGate {
    /// True during --self-test / --snapshot: nothing may reach the network.
    nonisolated(unsafe) static var forbidAll = false
    /// Settings source (tests inject their own).
    nonisolated(unsafe) static var settingsProvider: @Sendable () -> SettingsData = { AppSettings.shared.data }

    private static let ring = Locked<[NetworkEvent]>([])
    static var recentActivity: [NetworkEvent] { ring.value }

    /// Throws when the purpose is not allowed right now. `userInitiated` is true for button presses and explicit commands
    /// (install, update, a download the user started); the opt-in background update check passes false.
    static func authorize(_ purpose: NetworkPurpose, host: String? = nil, userInitiated: Bool = true) throws {
        if forbidAll {
            throw ConversionError.message(L10n("Network access is switched off in this run.", "Доступ к сети отключён в этом запуске."))
        }
        let s = settingsProvider().downloader
        guard s.consentGiven else {
            throw ConversionError.message(L10n("Downloading uses the network and a third-party tool. Read the notice in Settings > Downloader and agree first.",
                                               "Загрузка использует сеть и стороннюю программу. Сначала прочитайте уведомление в Настройки > Загрузка и согласитесь."))
        }
        if purpose == .updateCheckYtDlp && !userInitiated && !s.checkForUpdates {
            throw ConversionError.message(L10n("Automatic update checks are off.", "Автоматическая проверка обновлений выключена."))
        }
        record(purpose, host: host)
    }

    /// Records a network use (called by `authorize`; also by code that learns the real host later, e.g. after the info fetch).
    static func record(_ purpose: NetworkPurpose, host: String?) {
        let e = NetworkEvent(purpose: purpose, host: host ?? "")
        ring.withLock { r in r.append(e); if r.count > 50 { r.removeFirst(r.count - 50) } }
        Log.info("network: \(purpose.rawValue) \(host ?? "")")
    }

    static func clearActivity() { ring.value = [] }
}

/// `swampconverter://download?url=<encoded>&mode=<mode>[&title=<text>]`: lets a browser bookmark / bookmarklet, a Shortcuts action or
/// another app start a download from ANY browser (including Firefox, which exposes no URL to AppleScript). Pure parsing and building.
enum DownloadURLScheme {
    static let scheme = "swampconverter"

    struct Request: Equatable, Sendable {
        var link: LinkItem
        /// nil = use `settings.downloader.defaultMode`.
        var mode: DownloadMode?
    }

    /// Validates the whole thing: scheme, host "download", a downloadable http(s) `url`, an optional known `mode`.
    static func parse(_ url: URL) -> Result<Request, LinkRejection> {
        guard url.scheme?.lowercased() == scheme, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.host?.lowercased() == "download" || comps.path.lowercased() == "/download" else { return .failure(.malformed) }
        let items = comps.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value else { return .failure(.empty) }
        switch LinkParsing.validate(raw) {
        case .failure(let r): return .failure(r)
        case .success(let target):
            let title = items.first(where: { $0.name == "title" })?.value.map { String($0.prefix(200)) }
            let mode = DownloadMode(parameter: items.first(where: { $0.name == "mode" })?.value)
            return .success(Request(link: LinkItem(url: target, title: title, sourceName: "URL scheme"), mode: mode))
        }
    }

    /// The URL a bookmarklet / Shortcut would open.
    static func make(link: URL, mode: DownloadMode? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = scheme; c.host = "download"
        var items = [URLQueryItem(name: "url", value: link.absoluteString)]
        if let mode { items.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        c.queryItems = items
        // URLComponents leaves "&" and "=" inside values readable; encode them so the nested URL survives intact.
        c.percentEncodedQuery = items.map { i in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            return "\(i.name)=\(i.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return c.url
    }

    /// One-line bookmarklet for browsers without an AppleScript URL (Settings > Downloader shows it for copying).
    static func bookmarklet(mode: DownloadMode = .bestForApple) -> String {
        "javascript:(function(){location.href='\(scheme)://download?url='+encodeURIComponent(location.href)+'&mode=\(mode.rawValue)';})();"
    }
}
