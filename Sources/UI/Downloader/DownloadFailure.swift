import Foundation

// What went wrong with a download, in the person's words, and the one thing that can fix it. The engine already turns yt-dlp's stderr into a calm localised sentence
// (`YtDlpInfoParser.friendlyMessage`); this file recognises WHICH sentence it is (in English or Russian) so the sheet and the toast can offer the right button:
// pick a browser to sign in with, explain the JavaScript runtime, open the Downloader settings. Pure: no UI, no network.

struct DownloadFailure: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case signIn, privateVideo, ageRestricted, geoBlocked, noJSRuntime, networkDown, diskFull, drm, toolTooOld, ffmpegMissing, liveNotEnded
        case consentDeclined, notInstalled, cookiesDenied, other
    }

    /// The button next to the message.
    enum Fix: Equatable, Sendable {
        /// Choose the browser whose sign-in yt-dlp may use (inline in the sheet, Settings > Downloader elsewhere).
        case chooseBrowser
        case showJSRuntimeHelp
        case openSettings
        case installTool
        case reviewNotice
    }

    var kind: Kind
    var message: String

    init(kind: Kind, message: String) { self.kind = kind; self.message = message }

    /// Recognises the engine's sentence. Anything unknown is `.other` and shown as it is.
    init(message: String) { self.init(kind: Self.classify(message), message: message) }

    var fix: Fix? {
        switch kind {
        case .signIn, .privateVideo, .ageRestricted: return .chooseBrowser
        case .noJSRuntime: return .showJSRuntimeHelp
        case .toolTooOld, .diskFull, .cookiesDenied: return .openSettings
        case .notInstalled: return .installTool
        case .consentDeclined: return .reviewNotice
        case .geoBlocked, .networkDown, .drm, .ffmpegMissing, .liveNotEnded, .other: return nil
        }
    }

    var fixTitle: String? {
        switch fix {
        case .chooseBrowser: return L("Choose a browser", "Выбрать браузер")
        case .showJSRuntimeHelp: return L("How to fix", "Как исправить")
        case .openSettings: return L("Open Settings", "Открыть настройки")
        case .installTool: return L("Install yt-dlp", "Установить yt-dlp")
        case .reviewNotice: return L("Read the notice", "Прочитать уведомление")
        case nil: return nil
        }
    }

    /// Worth offering "Try Again" (the cause may go away by itself or by the fix).
    var canRetry: Bool { kind != .drm && kind != .liveNotEnded }

    // MARK: Recognition

    /// Each entry: the kind and fragments of the engine's sentences in both languages (lower case). Order matters: the first match wins.
    private static let table: [(Kind, [String])] = [
        (.drm, ["protected by drm", "защищено drm"]),
        (.privateVideo, ["video is private", "видео закрытое"]),
        (.ageRestricted, ["age-restricted", "возрастное ограничение"]),
        (.signIn, ["asks you to sign in", "просит войти", "sign in"]),
        (.geoBlocked, ["not available in your country", "недоступно в вашей стране"]),
        (.liveNotEnded, ["live stream", "прямая трансляция", "has not started yet", "ещё не началась"]),
        (.noJSRuntime, ["javascript runtime", "javascript-движок", "javascript-движк"]),
        (.diskFull, ["disk is full", "диск заполнен"]),
        (.cookiesDenied, ["may not read the browser's cookies", "не разрешено читать cookies"]),
        (.toolTooOld, ["too old for the app", "слишком старая для приложения"]),
        (.ffmpegMissing, ["ffmpeg is needed", "нужен ffmpeg"]),
        (.networkDown, ["could not reach the site", "не удалось связаться с сайтом", "network access is switched off"])
    ]

    static func classify(_ message: String) -> Kind {
        let lower = message.lowercased()
        for (kind, needles) in table where needles.contains(where: { lower.contains($0) }) { return kind }
        return .other
    }

    // MARK: Building

    static func from(_ error: Error) -> DownloadFailure {
        if error is CancellationError { return DownloadFailure(kind: .other, message: L("Canceled.", "Отменено.")) }
        return DownloadFailure(message: ConversionError.describe(error))
    }

    static func from(_ outcome: DownloadService.StartOutcome) -> DownloadFailure? {
        switch outcome {
        case .started: return nil
        case .needsConsent:
            return DownloadFailure(kind: .consentDeclined, message: L("Downloading needs your agreement first. Nothing was downloaded.", "Для загрузки нужно ваше согласие. Ничего не скачано."))
        case .needsInstall:
            return DownloadFailure(kind: .notInstalled, message: L("yt-dlp is not installed, so nothing was downloaded. Install it with one click.", "yt-dlp не установлен, поэтому ничего не скачано. Установите его одним нажатием."))
        case .rejected(let reason): return DownloadFailure(kind: .other, message: reason.message.text)
        case .failed(let text): return DownloadFailure(message: text)
        }
    }
}

extension DownloadFailure {
    /// The Settings fix: the browser's cookies need Full Disk Access in System Settings, everything else is on the Downloader page.
    @MainActor func openSettingsFix() {
        if kind == .cookiesDenied { SettingsLinks.open(SettingsLinks.fullDiskAccess) } else { SettingsWindowController.shared.show(page: .downloader) }
    }
}
