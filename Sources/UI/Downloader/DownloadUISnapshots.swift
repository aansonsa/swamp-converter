import SwiftUI

// Snapshots of every state of the download feature: the sheet (empty, invalid link, fetching, video, 4K HDR, audio, list, errors, started with two stages), the first-use notice, the
// install offer, Settings > Downloader and the toast. Light and dark, English and Russian; the accessibility matrix for the sheet and the notice.
// Names: `download.<state>`. Nothing here reads the network or the person's settings: every model gets an isolated settings object and stub dependencies.

enum DownloadSnapshotSamples {
    /// A parsed fixture of the downloader module (the same JSON its tests use), or a small stand-in when the fixtures folder cannot be found.
    static func info(_ name: String) -> DownloadInfo {
        if let info = try? DownloaderFixtures.info(name) { return info }
        return DownloadInfo(id: "x", webpageURL: URL(string: "https://example.com/watch?v=x")!, title: "Swamp video", channel: "Swamp Films", duration: 612)
    }

    @MainActor
    static func settings(_ change: (inout DownloaderSettings) -> Void = { _ in }) -> AppSettings {
        let s = AppSettings(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("swamp-download-ui-snapshot-\(UUID().uuidString).json"), autosave: false)
        s.update { change(&$0.downloader) }
        return s
    }

    @MainActor
    static func deps(_ settings: AppSettings? = nil) -> DownloadSheetModel.Dependencies {
        DownloadSheetModel.Dependencies(
            ensureReady: { .ready },
            fetchInfo: { _, _ in throw ConversionError.message(L10n("stub")) },
            start: { _, _ in .failed("stub") },
            openStudio: { _, _ in },
            outputDirectory: { mode in URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(mode.isAudioOnly ? "Music/Swamp Converter" : "Movies/Swamp Converter", isDirectory: true) },
            settings: settings ?? Self.settings())
    }

    @MainActor
    static func twoStageJob(title: String, convertFraction: Double?) -> Job {
        let job = Job(batchID: UUID(), operationID: "link.best", title: title, items: [], links: [LinkItem(url: URL(string: "https://www.youtube.com/watch?v=eightK_HDR01")!, title: title)],
                      overrides: OptionValues(), outputRules: nil, origin: .studio, mode: .studio, held: false)
        job.markStarted(finishAction: .nothing)
        job.setStages([StageProgress(spec: .download(), state: .done, fraction: 1),
                       StageProgress(spec: .convert(), state: .running, fraction: convertFraction)])
        job.update(progress: 0.6 + 0.4 * (convertFraction ?? 0), message: nil, etaHint: 42)
        return job
    }

    static let clipboard = LinkItem(url: URL(string: "https://www.youtube.com/watch?v=abc123XYZ_-")!, title: nil, sourceName: "clipboard")
}

@MainActor
enum DownloadUISnapshots {
    static func register() {
        let r = SnapshotRegistry.shared
        let full = SnapshotVariant.lightDarkRu
        let a11y = SnapshotVariant.accessibility
        let sheet = DownloadSheetContent.size
        let title = L10n("Download from Link", "Скачать по ссылке").en

        func sheetSnapshot(_ name: String, variants: [SnapshotVariant] = full, _ make: @escaping @MainActor () -> DownloadSheetModel) {
            r.register("download.\(name)", size: sheet, backdrop: .windowBackground, chrome: .window(title: title), variants: variants) {
                DownloadSheetContent(model: make(), onClose: {})
            }
        }
        typealias Samples = DownloadSnapshotSamples

        sheetSnapshot("sheet-empty") { .preview(deps: Samples.deps(), phase: .empty, clipboard: Samples.clipboard) }
        sheetSnapshot("sheet-invalid") { .preview(deps: Samples.deps(), phase: .empty, text: "file:///etc/passwd") }
        sheetSnapshot("sheet-fetching") { .preview(deps: Samples.deps(), phase: .fetching, text: "https://www.youtube.com/watch?v=abc123XYZ_-") }
        sheetSnapshot("sheet-video") {
            .preview(deps: Samples.deps(), phase: .info, text: "https://www.youtube.com/watch?v=abc123XYZ_-", info: Samples.info("video.json"))
        }
        sheetSnapshot("sheet-video-4k") {
            let m = DownloadSheetModel.preview(deps: Samples.deps(), phase: .info, text: "https://www.youtube.com/watch?v=eightK_HDR01", info: Samples.info("video-8k-hdr.json"))
            m.qualityID = m.qualityOptions.first(where: { $0.height == 2160 })?.id
            return m
        }
        sheetSnapshot("sheet-audio") {
            let m = DownloadSheetModel.preview(deps: Samples.deps(), phase: .info, text: "https://soundcloud.com/swamp/ambience", info: Samples.info("audio-only.json"))
            m.modeChoice = .audio
            return m
        }
        sheetSnapshot("sheet-playlist") {
            let m = DownloadSheetModel.preview(deps: Samples.deps(), phase: .playlist, text: "https://www.youtube.com/playlist?list=PLswampMix", info: Samples.info("playlist.json"))
            m.selection = Set(m.info?.entries.map(\.index).dropLast() ?? [])
            return m
        }
        sheetSnapshot("sheet-error-signin") {
            let f = DownloadFailure(message: YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: [youtube] x: Sign in to confirm you're not a bot").text)
            return .preview(deps: Samples.deps(), phase: .failed, text: "https://www.youtube.com/watch?v=private01", failure: f)
        }
        sheetSnapshot("sheet-error-runtime") {
            let f = DownloadFailure(message: L10n("YouTube needs a JavaScript runtime to offer this video. \(JSRuntimeAdvice.explanation.en)", "Для этого видео YouTube нужен JavaScript-движок. \(JSRuntimeAdvice.explanation.ru)").text)
            return .preview(deps: Samples.deps(), phase: .failed, text: "https://www.youtube.com/watch?v=abc123XYZ_-", failure: f)
        }
        sheetSnapshot("sheet-started") {
            let info = Samples.info("video-8k-hdr.json")
            return .preview(deps: Samples.deps(), phase: .started, text: info.webpageURL.absoluteString, info: info, job: Samples.twoStageJob(title: info.title, convertFraction: 0.35))
        }
        sheetSnapshot("sheet-video-a11y", variants: a11y) {
            .preview(deps: Samples.deps(), phase: .info, text: "https://www.youtube.com/watch?v=abc123XYZ_-", info: Samples.info("video.json"))
        }

        // The first-use notice and the install offer.
        r.register("download.consent", size: CGSize(width: 480, height: 400), backdrop: .windowBackground, chrome: .window(title: DownloadNotice.heading.en), variants: full + a11y) {
            DownloadConsentView(onFinish: { _ in }, settings: Samples.settings())
        }
        func installSnapshot(_ name: String, _ phase: YtDlpInstallModel.Phase, _ probe: JSRuntimeProbe.State) {
            r.register("download.install-\(name)", size: CGSize(width: 520, height: 520), backdrop: .windowBackground, chrome: .window(title: "Install yt-dlp"), variants: full) {
                DownloadInstallOfferBody(phase: phase, probe: JSRuntimeProbe(state: probe), onInstall: {}, onCancel: {}, onContinue: {})
            }
        }
        installSnapshot("idle", .idle, .missing)
        installSnapshot("working", .working(kind: .install, progress: 0.46), .missing)
        installSnapshot("done", .succeeded(.init(kind: .install, version: "2026.10.20", checksumVerified: true, alreadyLatest: false)), .found(kind: "deno", path: "/opt/homebrew/bin/deno", version: "2.1.4", meetsMinimum: true))
        installSnapshot("failed", .failed(L10n("The file did not match its checksum and was not installed.", "Файл не совпал с контрольной суммой и не был установлен.").text), .missing)

        // Settings > Downloader.
        func settingsSnapshot(_ name: String, installed: Bool, variants: [SnapshotVariant]) {
            r.register("download.settings-\(name)", size: CGSize(width: 680, height: 980), backdrop: .windowBackground, chrome: .window(title: L10n("Downloader", "Загрузка").en), variants: variants) {
                let manager = YtDlpToolManager()
                if installed { manager.publish(YtDlpStatus(url: URL(fileURLWithPath: "/Users/me/Library/Application Support/Swamp Converter/tools/yt-dlp"), version: "2026.10.20", source: .userFolder, jsRuntime: nil)) }
                let settings = Samples.settings {
                    $0.consentGiven = installed; $0.cookies = installed ? .safari : .none
                    if installed { $0.verifiedInstall = DownloaderSettings.VerifiedInstall(version: "2026.10.20", sha256: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90", date: 1792929600) }
                }
                let probe = JSRuntimeProbe(state: installed ? .found(kind: "deno", path: "/opt/homebrew/bin/deno", version: "2.1.4", meetsMinimum: true) : .missing)
                return DownloaderSettingsView(settings: settings, manager: manager, probe: probe, refreshesOnAppear: false)
            }
        }
        settingsSnapshot("installed", installed: true, variants: full)
        settingsSnapshot("missing", installed: false, variants: full)

        // The toast, drawn with the shared notice card (the Jobs module hosts it).
        r.register("download.toast", size: CGSize(width: 440, height: 260), backdrop: .wallpaper, variants: full) {
            VStack(spacing: DS.Space.md) {
                NoticeCard(NoticeCardContent(title: DownloadToast.startedText(link: LinkItem(url: URL(string: "https://www.youtube.com/watch?v=abc123XYZ_-")!, title: "Swamp Films - Part 1"), mode: .bestForApple),
                                             tone: .info, symbol: "arrow.down.circle", progress: .indeterminate, primary: NoticeAction(L("Show", "Показать")) {}))
                NoticeCard(NoticeCardContent(title: DownloadFailure(message: YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: Sign in to confirm your age").text).message,
                                             tone: .error, symbol: "exclamationmark.octagon", primary: NoticeAction(L("Choose a browser", "Выбрать браузер")) {}))
            }
            .padding(DS.Space.lg)
        }
    }
}
