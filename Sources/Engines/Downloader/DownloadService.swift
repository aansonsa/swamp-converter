import Foundation

// THE single entry point of the download feature. The wheel (link sector), the global "download this page" hotkey, the menu-bar and Dock
// drop, Services, the swampconverter:// URL scheme, the clipboard banner, the Studio and the CLI ALL call `DownloadService.shared.start(...)`.
// Nobody else builds yt-dlp jobs. It enforces: valid http(s) URL (LinkParsing), consent, tool present, then submits a normal Job
// (stages: download -> optional convert) to the shared JobRunner, so progress, ETA, cancel, queue and notifications are the ones of conversions.

@MainActor
final class DownloadService: ObservableObject {
    static let shared = DownloadService()

    /// UI hooks (installed by the download-ui module; nil in the CLI, where consent comes from the settings file / flags).
    struct Hooks {
        /// Show the first-use consent sheet (network + third-party tool). Returns true if the user agreed (the sheet writes `consentGiven`).
        var requestConsent: (@MainActor () async -> Bool)?
        /// Offer the explicit "Install yt-dlp" step. Returns true when the tool is installed afterwards.
        var offerInstall: (@MainActor () async -> Bool)?
        /// Called right after a job was created (the toast "Downloading ... " + menu-bar progress start).
        var started: (@MainActor (LinkItem, DownloadMode, Job) -> Void)?
        /// A link that cannot be downloaded (not http/https, private host ...): the calm message to show.
        var rejected: (@MainActor (LinkRejection) -> Void)?
    }
    var hooks = Hooks()

    enum StartOutcome {
        case started(Job)
        /// The user declined (or no UI exists to ask): nothing happened.
        case needsConsent
        case needsInstall
        case rejected(LinkRejection)
        case failed(String)
    }

    /// Where jobs go (tests use a private runner with persistence off).
    var jobRunner: JobRunner { runnerOverride ?? JobRunner.shared }
    var runnerOverride: JobRunner?
    var registry: OperationRegistry = .shared

    // MARK: Start

    /// Starts a download of `url` in `mode` (nil = `settings.downloader.defaultMode`). Never throws; the outcome says what happened and the
    /// hooks have already informed the user. Duplicate links already queued or running are not queued twice (same canonical key -> that job).
    func start(url: URL, mode: DownloadMode? = nil, title: String? = nil, origin: JobOrigin = .other) async -> StartOutcome {
        let chosen = mode ?? AppSettings.shared.data.downloader.defaultMode
        let clean: URL
        switch LinkParsing.validate(url.absoluteString) {
        case .failure(let reason): return reject(reason)
        case .success(let u): clean = u
        }
        let link = LinkItem(url: clean, title: title)
        if let running = duplicate(of: link) { return .started(running) }
        if let early = await ensureReady() { return early }
        guard let op = registry.operation(id: DownloadCatalog.operationID(for: chosen)) else {
            return .failed(L("Downloading is not available in this build.", "Загрузка недоступна в этой сборке."))
        }
        // A second start of the same link may have slipped in while a sheet was open.
        if let running = duplicate(of: link) { return .started(running) }
        let job = jobRunner.submit(operation: op, links: [link], overrides: OptionValues(), origin: origin, mode: .quick)
        hooks.started?(link, chosen, job)
        checkForUpdateInBackground()
        return .started(job)
    }

    func start(link: LinkItem, mode: DownloadMode? = nil, origin: JobOrigin = .other) async -> StartOutcome {
        await start(url: link.url, mode: mode, title: link.title, origin: origin)
    }

    /// Full control (Studio / download sheet): an explicit request (quality, subtitles, sections, playlist items ...). `held` = "Add to Queue".
    func start(request: DownloadRequest, title: String? = nil, origin: JobOrigin = .studio, held: Bool = false) async -> StartOutcome {
        let clean: URL
        switch LinkParsing.validate(request.url.absoluteString) {
        case .failure(let reason): return reject(reason)
        case .success(let u): clean = u
        }
        var request = request
        request.url = clean
        if let early = await ensureReady() { return early }
        guard let op = registry.operation(id: DownloadCatalog.operationID(for: request.mode)) else {
            return .failed(L("Downloading is not available in this build.", "Загрузка недоступна в этой сборке."))
        }
        let link = LinkItem(url: clean, title: title)
        let overrides = DownloadOptionsMapper.options(from: request)
        let job: Job
        if held { job = jobRunner.enqueue(operation: op, links: [link], overrides: overrides, origin: origin, mode: .studio) }
        else { job = jobRunner.submit(operation: op, links: [link], overrides: overrides, origin: origin, mode: .studio) }
        hooks.started?(link, request.mode, job)
        if !held { checkForUpdateInBackground() }
        return .started(job)
    }

    /// Handles a parsed `swampconverter://download` request (called by the app module's URL handler).
    func handle(scheme request: DownloadURLScheme.Request, origin: JobOrigin = .other) async -> StartOutcome {
        await start(link: request.link, mode: request.mode, origin: origin)
    }

    // MARK: Information

    /// `yt-dlp -J` for the info card / quality picker / playlist picker. Consent- and NetworkGate-checked; cancellable; results cached for a minute.
    /// A link to a video inside a list means that video; `flatPlaylist: true` asks for the list (its entries are listed without their formats).
    func fetchInfo(_ url: URL, flatPlaylist: Bool = false) async throws -> DownloadInfo {
        let clean: URL
        switch LinkParsing.validate(url.absoluteString) {
        case .failure(let reason): throw ConversionError.message(reason.message)
        case .success(let u): clean = u
        }
        try NetworkGate.authorize(.mediaInfo, host: LinkParsing.displayHost(of: clean))
        let exe = try ToolLocator.shared.require(.ytdlp)
        let settings = NetworkGate.settingsProvider().downloader
        let version = await Task.detached(priority: .utility) { ToolLocator.shared.version(of: .ytdlp) }.value
        let query = DownloadInfoFetcher.Query(url: clean, flat: true, wholePlaylist: flatPlaylist, cookies: settings.cookies,
                                              jsRuntime: JSRuntimeDetector.detect(), supportsJSRuntimes: YtDlpToolManager.supportsJSRuntimesOption(version: version))
        return try await DownloadInfoFetcher.fetch(query, executable: exe) { exe, args in
            try await ProcessRunner.run(exe, args, captureStdout: true, maxCapturedBytes: 64_000_000, allowNonZeroExit: true, background: false)
        }
    }

    // MARK: Folders

    /// The effective output folder: settings.downloader.folder, else ~/Movies/Swamp Converter (video) or ~/Music/Swamp Converter (audio).
    func outputDirectory(for mode: DownloadMode, settings: DownloaderSettings = AppSettings.shared.data.downloader) -> URL {
        DownloadFolders.resolve(audioOnly: mode.isAudioOnly, settingsFolder: settings.folder)
    }

    // MARK: Internals

    private func reject(_ reason: LinkRejection) -> StartOutcome {
        hooks.rejected?(reason)
        return .rejected(reason)
    }

    private func duplicate(of link: LinkItem) -> Job? {
        jobRunner.jobs.first { !$0.state.isFinished && $0.isLinkJob && $0.links.contains { $0.canonicalKey == link.canonicalKey } }
    }

    /// Consent first, then the tool. Returns the outcome to give back when the person declined or nothing can happen; nil = ready.
    private func ensureReady() async -> StartOutcome? {
        if !NetworkGate.settingsProvider().downloader.consentGiven {
            guard let ask = hooks.requestConsent, await ask(), NetworkGate.settingsProvider().downloader.consentGiven else { return .needsConsent }
        }
        if !ToolLocator.shared.has(.ytdlp) {
            guard let offer = hooks.offerInstall, await offer() else { return .needsInstall }
            guard ToolLocator.shared.has(.ytdlp) else { return .needsInstall }
        }
        return nil
    }

    /// The opt-in daily update check (setting off by default); a newer version only produces a quiet message.
    private func checkForUpdateInBackground() {
        guard NetworkGate.settingsProvider().downloader.checkForUpdates else { return }
        Task { @MainActor in
            if let newer = await YtDlpToolManager.shared.checkForUpdateIfDue() {
                MessageCenter.shared.post(L("A newer yt-dlp (\(newer)) is available. Update it in Settings > Downloader.", "Доступна новая версия yt-dlp (\(newer)). Обновите её в Настройки > Загрузка."),
                                          symbol: "arrow.down.circle")
            }
        }
    }
}
