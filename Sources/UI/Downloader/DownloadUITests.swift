import Foundation
import SwiftUI

// Self-tests of the download UI, part 1: everything that needs no yt-dlp at all (pure helpers, the state machine with stub dependencies, the hooks, the toasts, the controller
// with a parked window). Part 2 (DownloadUITestsFlow.swift) runs the real engine against the FAKE yt-dlp. The network is never reached: `NetworkGate.forbidAll` holds in every test
// except inside `DownloadRig`, which refuses to run unless the located tool IS the fake.

/// Counts and scripts for the stub dependencies of a sheet model.
@MainActor
final class StubSheet {
    var readiness: DownloadReadiness = .ready
    var fetchResult: Result<DownloadInfo, Error> = .success(DownloadSnapshotSamples.info("video.json"))
    var fetchDelay: Duration?
    var startOutcome: DownloadService.StartOutcome = .failed("stub")
    private(set) var fetches: [(url: URL, whole: Bool)] = []
    private(set) var requests: [DownloadRequest] = []
    private(set) var studioOpened: [(LinkItem, DownloadMode)] = []
    private(set) var readinessChecks = 0
    let settings = DownloadSnapshotSamples.settings()
    let folder = URL(fileURLWithPath: "/tmp/swamp-download-ui-test-out", isDirectory: true)

    func deps() -> DownloadSheetModel.Dependencies {
        DownloadSheetModel.Dependencies(
            ensureReady: { [unowned self] in self.readinessChecks += 1; return self.readiness },
            fetchInfo: { [unowned self] url, whole in
                self.fetches.append((url, whole))
                if let d = self.fetchDelay { try await Task.sleep(for: d) }
                return try self.fetchResult.get()
            },
            start: { [unowned self] request, _ in self.requests.append(request); return self.startOutcome },
            openStudio: { [unowned self] link, mode in self.studioOpened.append((link, mode)) },
            outputDirectory: { [unowned self] _ in self.folder },
            settings: settings)
    }

    func model() -> DownloadSheetModel { DownloadSheetModel(deps: deps()) }
}

@MainActor
func downloadUIEnglish<T>(_ body: () async throws -> T) async rethrows -> T {
    let saved = Loc.shared.setting
    Loc.shared.set(.english)
    defer { Loc.shared.set(saved) }
    return try await body()
}

enum DownloadUITests {
    static let videoLink = "https://www.youtube.com/watch?v=abc123XYZ_-"

    static func test(_ name: String, timeout: TimeInterval = 60, _ body: @escaping SelfTestBody) {
        SelfTestRegistry.shared.register("download-ui", name, timeout: timeout, body)
    }

    static func register() {
        registerWiring()
        registerState()
        registerPure()
        registerFlow()
    }

    // MARK: Wiring

    private static func registerWiring() {
        test("the downloader settings page is registered after the other built-in pages and before About") {
            let reg = SettingsPageRegistry()
            reg.register(SettingsPageDescriptor(id: .about, title: L10n("About"), symbol: "info.circle", order: 100) { AnyView(EmptyView()) })
            reg.register(SettingsPageDescriptor(id: .downloader, title: L10n("Downloader"), symbol: "arrow.down.circle", order: 60) { AnyView(EmptyView()) })
            try expectEqual(reg.pages.map(\.id.raw), ["downloader", "about"])
        }

        test("install() puts all four hooks on the service and registers the page") {
            let service = DownloadService.shared
            let saved = service.hooks
            defer { service.hooks = saved }
            service.hooks = DownloadService.Hooks()
            DownloadUIModule.install()
            let h = service.hooks
            try expect(h.requestConsent != nil && h.offerInstall != nil && h.started != nil && h.rejected != nil, "every hook is installed")
            try expect(SettingsPageRegistry.shared.pages.contains { $0.id == .downloader })
            DownloadUIModule.install()    // idempotent
            try expectEqual(SettingsPageRegistry.shared.pages.filter { $0.id == .downloader }.count, 1)
        }

        test("the consent dialog answers through the host without opening a window when a test answers it") {
            DownloadDialogHost.autoAnswer = { id in id == "install" }
            defer { DownloadDialogHost.autoAnswer = nil }
            let consent = await DownloadDialogs.requestConsent()
            let install = await DownloadDialogs.offerInstall()
            try expectEqual(consent, false); try expectEqual(install, true)
        }

        test("consent is recorded only when the person agrees") {
            let s = DownloadSnapshotSamples.settings()
            try expectEqual(s.data.downloader.consentGiven, false)
            try expectEqual(DownloadConsent.record(false, in: s), false)
            try expectEqual(s.data.downloader.consentGiven, false, "Not now writes nothing")
            try expectEqual(DownloadConsent.record(true, in: s), true)
            try expectEqual(s.data.downloader.consentGiven, true)
            try expect(!DownloadNotice.points.isEmpty && DownloadNotice.points.allSatisfy { !$0.text.en.isEmpty && !$0.text.ru.isEmpty && $0.text.en != $0.text.ru })
            try expect(DownloadNotice.usageLine.en.contains("right to download") && DownloadNotice.legalText.ru.contains("DRM"))
        }

        test("parallel parts: four by default, always 1...8, and a settings file written before the field existed still loads") {
            var d = DownloaderSettings()
            try expectEqual(d.fragments, 4)
            d.concurrentFragments = 0; try expectEqual(d.fragments, 1)
            d.concurrentFragments = 50; try expectEqual(d.fragments, 8)
            // A nil optional is not written, so the encoding of the defaults is exactly what an old file looks like.
            let old = try JSONEncoder().encode(DownloaderSettings())
            try expect(!String(decoding: old, as: UTF8.self).contains("concurrentFragments"))
            let back = try JSONDecoder().decode(DownloaderSettings.self, from: old)
            try expectEqual(back.fragments, 4)
            d.concurrentFragments = 6
            try expectEqual(try JSONDecoder().decode(DownloaderSettings.self, from: JSONEncoder().encode(d)).fragments, 6, "a chosen value survives saving")
        }

        test("the Settings page has a control for every field of DownloaderSettings that a person can change") {
            // The page binds these key paths; a new field without a control must be added here on purpose.
            let internalFields: Set<String> = ["lastUpdateCheck", "browserAutomationExplained", "verifiedInstall"]   // bookkeeping: what the app verified, not a choice
            let names = Set(Mirror(reflecting: DownloaderSettings()).children.compactMap(\.label))
            let covered: Set<String> = ["consentGiven", "folder", "afterDownload", "cookies", "rateLimitKBps", "concurrentFragments", "filenameTemplate", "embedMetadata", "embedThumbnail", "subtitles",
                                        "subtitleLanguages", "burnSubtitles", "checkForUpdates", "defaultMode"]
            try expectEqual(names.subtracting(internalFields).subtracting(covered), [], "fields without a control on the page")
        }
    }
}
