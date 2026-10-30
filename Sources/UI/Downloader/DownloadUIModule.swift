import SwiftUI
import AppKit

// MODULE download-ui (owner: download UI engineer). Prefix for new top-level types: Download* (views) / Consent* / Clipboard*.
// Files: Sources/UI/Downloader/*.
// Spec: the DOWNLOADER block of the project brief (paste / clipboard detection / drop; info card; quality and mode pickers; destination; post-download action; playlist picker;
//       settings page; queue integration), the ONE-KEYSTROKE block (toast + banner), spec/ux.md 5 (permissions: pre-alert has one "Continue" button and never imitates the system alert),
//       6 (calm errors); spec/handbrake.md 6 (Studio inspector conventions: Form .grouped, Simple / Advanced, "disabled with a reason").
//
// This module owns every PIXEL of the download feature and none of its logic: the logic is `DownloadService` (downloader module). Nothing here touches the network; it only calls
// `DownloadService.shared` and observes jobs.
//
//   DownloadUIModule.swift            install(), the hooks, the dialogs the hooks open
//   DownloadSheetController/Model/View/Support   the "Download from Link" window and its state machine
//   DownloadInfoCard, QualityPickerView, PlaylistPickerView, DownloadOptionsForm, ClipboardLinkBanner   the parts of the sheet
//   DownloadConsentView, DownloadInstallModel, JSRuntimeStatusView   first-use notice, explicit yt-dlp install, JavaScript runtime help
//   DownloaderSettingsView(+NetworkSections)   Settings > Downloader
//   DownloadToast, DownloadFailure, DownloadStageProgress, DownloadUIFormat   toasts, failure recognition, two-stage progress, text helpers
//   DownloadUISnapshots, DownloadUITests*    snapshots of every state and the self-tests

enum DownloadUIModule {
    /// Installs `DownloadService.shared.hooks` (consent sheet, install offer, "started" toast, rejection message) and registers the "downloader" Settings page with
    /// `SettingsPageRegistry.shared`. Called by the app at launch (cheap: no view is built).
    @MainActor
    static func install() {
        DownloadService.shared.hooks = makeHooks()
        SettingsPageRegistry.shared.register(SettingsPageDescriptor(id: .downloader, title: L10n("Downloader", "Загрузка"), symbol: "arrow.down.circle", order: 60) { AnyView(DownloaderSettingsView()) })
    }

    /// The four hooks of the service. Separate from `install()` so tests can inspect them.
    @MainActor
    static func makeHooks() -> DownloadService.Hooks {
        DownloadService.Hooks(
            requestConsent: { await DownloadDialogs.requestConsent() },
            offerInstall: { await DownloadDialogs.offerInstall() },
            started: { link, mode, job in DownloadToast.started(link: link, mode: mode, job: job) },
            rejected: { reason in DownloadToast.rejected(reason) })
    }

    #if !SC_SHIPPING
    @MainActor
    static func registerSnapshots() { DownloadUISnapshots.register() }
    #endif

    #if !SC_SHIPPING
    static func registerSelfTests() { DownloadUITests.register() }
    #endif
}

/// The two questions the service asks before it touches the network: the first-use notice and the install offer. Each is a sheet on the download window when that is open,
/// otherwise a small window of its own; closing it counts as "no".
@MainActor
enum DownloadDialogs {
    static func requestConsent() async -> Bool {
        await DownloadDialogHost.ask(id: "consent", title: DownloadNotice.heading.text, size: CGSize(width: 480, height: 400), parent: DownloadSheetController.shared.currentWindow) { finish in
            DownloadConsentView(onFinish: { finish($0) })
        }
    }

    static func offerInstall() async -> Bool {
        await DownloadDialogHost.ask(id: "install", title: L("Install yt-dlp", "Установка yt-dlp"), size: CGSize(width: 520, height: 520), parent: DownloadSheetController.shared.currentWindow) { finish in
            DownloadInstallOfferView(onFinish: { finish($0) })
        }
    }
}
