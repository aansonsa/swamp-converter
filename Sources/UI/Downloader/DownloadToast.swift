import SwiftUI
import Combine

/// The toast shown when a download starts from the hotkey / URL scheme / Services / the sheet ("Download started: <title or host>" with a "Show" button), the calm message for a
/// link that cannot be downloaded, and the failure toast with the fix that fits. The toast itself is the Jobs module's `ToastCenter` (a glass card near the top of the screen that
/// never takes focus); this file decides the words and the buttons. The menu-bar progress is the Jobs module's too.
@MainActor
enum DownloadToast {
    /// Test hook: receives every toast instead of the screen.
    nonisolated(unsafe) static var sink: (@MainActor (_ text: String, _ symbol: String?, _ severity: UserMessage.Severity, _ actionTitle: String?) -> Void)?

    /// The jobs watched for a failure (one entry per running download started through the hooks); each removes itself when its job finishes.
    private static var watchers: [UUID: AnyCancellable] = [:]

    /// `sheetVisible`: the download window shows its own "started" state, so a second message would only repeat it; the failure watch runs either way.
    static func started(link: LinkItem, mode: DownloadMode, job: Job, sheetVisible: Bool? = nil) {
        if !(sheetVisible ?? DownloadSheetController.shared.isVisible) {
            post(startedText(link: link, mode: mode), symbol: "arrow.down.circle", severity: .info,
                 action: (L("Show", "Показать"), { JobsWindowController.shared.show() }))
        }
        watchFailure(of: job)
    }

    static func rejected(_ reason: LinkRejection) {
        post(reason.message.text, symbol: "exclamationmark.triangle", severity: .warning, action: nil)
    }

    /// A failure with a way out (sign in, JavaScript runtime, Settings): shown as an error toast whose button does the fix.
    static func failed(_ failure: DownloadFailure) {
        let action: (String, @MainActor () -> Void)? = failure.fixTitle.map { title in
            (title, {
                switch failure.fix {
                case .installTool, .reviewNotice: DownloadSheetController.shared.show(link: nil, prefillFromClipboard: false)
                case .openSettings: failure.openSettingsFix()
                default: SettingsWindowController.shared.show(page: .downloader)
                }
            })
        }
        post(failure.message, symbol: "exclamationmark.octagon", severity: .error, action: action)
    }

    /// "Download started: Swamp Films - Part 1" / "Загрузка началась: ..."; the host when the title is not known yet. Audio modes say so.
    static func startedText(link: LinkItem, mode: DownloadMode) -> String {
        let name = link.displayTitle
        if mode.isAudioOnly { return L("Audio download started: \(name)", "Загрузка звука началась: \(name)") }
        return L("Download started: \(name)", "Загрузка началась: \(name)")
    }

    // MARK: Failure watching

    /// Which failures deserve their own toast: only those with a fix button or an explanation the job card cannot give. Everything else is left to the Jobs module's card.
    static func warrantsToast(_ failure: DownloadFailure) -> Bool { failure.fix != nil && failure.kind != .consentDeclined }

    private static func watchFailure(of job: Job) {
        let id = job.id
        watchers[id] = job.$state.sink { state in
            guard state.isFinished else { return }
            Task { @MainActor in
                watchers[id] = nil
                guard state == .failed, let message = job.errorMessage else { return }
                let failure = DownloadFailure(message: message)
                if warrantsToast(failure) { failed(failure) }
            }
        }
    }

    private static func post(_ text: String, symbol: String?, severity: UserMessage.Severity, action: (String, @MainActor () -> Void)?) {
        if let sink { sink(text, symbol, severity, action?.0); return }
        ToastCenter.shared.show(text, symbol: symbol, severity: severity, action: action.map { (title: $0.0, handler: $0.1) })
    }
}
