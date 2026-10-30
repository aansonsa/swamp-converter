import Foundation
import SwiftUI
import Combine

// The state machine of the download sheet. No views, no windows: the controller and the views observe it, the tests drive it with stub dependencies and the real engine against the
// FAKE yt-dlp. Nothing here starts a process or opens a socket by itself: `fetch()` asks the service's own hooks for consent and the tool first, and the engine's `NetworkGate`
// refuses anything the person has not agreed to.
//
//   empty --fetch--> fetching --ok--> info | playlist --download--> started
//                        |                  \--error--> failed --retry--> fetching
//                        \--cancel--> empty

@MainActor
final class DownloadSheetModel: ObservableObject {
    enum Phase: Equatable { case empty, fetching, info, playlist, failed, started }

    /// Everything outside the model, replaceable in tests and snapshots.
    struct Dependencies {
        var ensureReady: @MainActor () async -> DownloadReadiness
        var fetchInfo: @MainActor (_ url: URL, _ wholeList: Bool) async throws -> DownloadInfo
        var start: @MainActor (_ request: DownloadRequest, _ title: String?) async -> DownloadService.StartOutcome
        var openStudio: @MainActor (_ link: LinkItem, _ mode: DownloadMode) -> Void
        var outputDirectory: @MainActor (_ mode: DownloadMode) -> URL
        var settings: AppSettings

        @MainActor static func live(service: DownloadService? = nil, settings: AppSettings? = nil) -> Dependencies {
            let service = service ?? .shared, settings = settings ?? .shared
            return Dependencies(
                ensureReady: { await DownloadFlow.ensureReady(service: service) },
                fetchInfo: { url, whole in try await service.fetchInfo(url, flatPlaylist: whole) },
                start: { request, title in await service.start(request: request, title: title, origin: .studio) },
                openStudio: { link, mode in
                    StudioWindowController.shared.show(input: IncomingInput(links: [link], origin: .studio), operationID: DownloadCatalog.operationID(for: mode))
                },
                outputDirectory: { service.outputDirectory(for: $0) },
                settings: settings)
        }
    }

    // MARK: State

    @Published var text = "" { didSet { if text != oldValue { textChanged() } } }
    @Published private(set) var phase: Phase = .empty
    @Published private(set) var info: DownloadInfo?
    @Published private(set) var qualityOptions: [QualityOption] = []
    @Published private(set) var failure: DownloadFailure?
    @Published private(set) var clipboardLink: LinkItem?
    @Published private(set) var startedJob: Job?
    @Published private(set) var startedTitle = ""
    /// The link is a video inside a list and the whole list was not asked for yet.
    @Published private(set) var offersWholeList = false

    // Choices
    @Published var modeChoice: DownloadModeChoice = .best { didSet { if modeChoice != oldValue { after = modeChoice.defaultAfter(settingsAfter: deps.settings.data.downloader.afterDownload) } } }
    @Published var qualityID: String?
    @Published var audioFormat: DownloadAudioFormat = .m4a
    /// Picture height cap for a list (entries have no formats yet): 0 = best.
    @Published var listMaxHeight = 0
    @Published var after: AfterDownload
    @Published var folder: URL?
    @Published var subtitleMode: DownloadSubtitleMode = .none
    @Published var subtitleLanguages: String
    @Published var rangeStart = ""
    @Published var rangeEnd = ""
    @Published var selection: Set<Int> = []

    let deps: Dependencies
    private var fetchTask: Task<Void, Never>?
    private var fetchGeneration = 0

    init(deps: Dependencies? = nil) {
        let d = deps ?? .live()
        self.deps = d
        let s = d.settings.data.downloader
        after = s.afterDownload
        subtitleLanguages = s.subtitleLanguages
        subtitleMode = s.subtitles ? .soft : .none
    }

    // MARK: The link field

    /// nil while the field is empty; otherwise the normalised link or why it can't be downloaded (the text under the field).
    var validation: Result<URL, LinkRejection>? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if case .success(let u) = LinkParsing.validate(t) { return .success(u) }
        // A pasted sentence with a link inside is fine: take its first downloadable link.
        switch LinkParsing.firstDownloadable(in: t) {
        case .success(let item): return .success(item.url)
        case .failure(let reason): return .failure(reason)
        }
    }
    var validURL: URL? { if case .success(let u)? = validation { return u } else { return nil } }
    var rejection: LinkRejection? { if case .failure(let r)? = validation { return r } else { return nil } }

    private func textChanged() {
        // Editing the link after a result invalidates it: back to the start (a running fetch is cancelled).
        if phase != .empty && phase != .started { reset(keepText: true) }
    }

    // MARK: Clipboard

    /// Reads the clipboard once (the sheet calls this when it opens, never again by itself).
    func loadClipboardBanner() {
        clipboardLink = ClipboardLinkReader.link()
        if let c = clipboardLink, c.url == validURL { clipboardLink = nil }
    }

    func useClipboardLink() {
        guard let link = clipboardLink else { return }
        clipboardLink = nil
        text = link.url.absoluteString
        fetch()
    }

    func dismissClipboardBanner() { clipboardLink = nil }

    /// The Paste button: whatever link is on the clipboard now (an explicit click), then fetch.
    func paste() {
        guard let link = ClipboardLinkReader.link() else {
            if let raw = ClipboardLinkReader.currentText()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty { text = String(raw.prefix(2_100)) }
            return
        }
        clipboardLink = nil
        text = link.url.absoluteString
        fetch()
    }

    // MARK: Fetching

    var canFetch: Bool { validURL != nil && phase != .fetching }

    func fetch(wholeList: Bool = false) {
        guard let url = validURL else { return }
        fetchTask?.cancel()
        fetchGeneration += 1
        let generation = fetchGeneration
        failure = nil
        phase = .fetching
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let readiness = await self.deps.ensureReady()
            guard generation == self.fetchGeneration, !Task.isCancelled else { return }
            guard readiness == .ready else {
                self.fail(DownloadFailure.from(readiness == .consentDeclined ? .needsConsent : .needsInstall)!)
                return
            }
            do {
                let result = try await self.deps.fetchInfo(url, wholeList)
                guard generation == self.fetchGeneration, !Task.isCancelled else { return }
                self.show(info: result, requestedURL: url, wholeList: wholeList)
            } catch is CancellationError {
                if generation == self.fetchGeneration { self.phase = .empty }
            } catch {
                guard generation == self.fetchGeneration, !Task.isCancelled else { return }
                self.fail(DownloadFailure.from(error))
            }
        }
    }

    /// Waits for the running fetch (tests).
    func settled() async { await fetchTask?.value }

    func cancelFetch() {
        fetchTask?.cancel()
        fetchGeneration += 1
        if phase == .fetching { phase = .empty }
    }

    private func show(info result: DownloadInfo, requestedURL: URL, wholeList: Bool) {
        info = result
        qualityID = nil
        qualityOptions = result.isPlaylist ? [] : FormatSelector.qualityOptions(for: result)
        offersWholeList = !result.isPlaylist && !wholeList && Self.isVideoInsideList(requestedURL)
        if result.isPlaylist {
            selection = Set(result.entries.map(\.index))
            phase = .playlist
        } else {
            selection = []
            phase = .info
        }
    }

    private func fail(_ f: DownloadFailure) {
        failure = f
        phase = .failed
    }

    /// `watch?v=ID&list=PL...`: one video that belongs to a list.
    static func isVideoInsideList(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let has: (String) -> Bool = { name in items.contains { $0.name == name && ($0.value ?? "").isEmpty == false } }
        return has("list") && has("v")
    }

    func reset(keepText: Bool = false) {
        fetchTask?.cancel()
        fetchGeneration += 1
        if !keepText { text = "" }
        info = nil
        qualityOptions = []
        failure = nil
        startedJob = nil
        offersWholeList = false
        selection = []
        qualityID = nil
        phase = .empty
    }

    // MARK: Choices -> request

    var isAudio: Bool { modeChoice == .audio }
    var selectedQuality: QualityOption? { qualityOptions.first { $0.id == qualityID } }
    var effectiveMode: DownloadMode { modeChoice.mode(audioFormat: audioFormat) }
    var ffmpegAvailable: Bool { Capabilities.shared.has("tool.ffmpeg") }
    var convertsAfterDownload: Bool { !isAudio && modeChoice != .maximum && after != .keepOriginal }
    var isLive: Bool { info?.isLive ?? false }

    /// "01:30" or "90" typed in a range field; nil when empty; `.invalid` when it can't be read.
    enum TimeField: Equatable { case empty, value(Double), invalid }
    static func parseField(_ text: String) -> TimeField {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if let v = Util.parseTime(text) { return .value(v) }
        return .invalid
    }

    /// The reason the time range can't be used, or nil.
    var rangeProblem: String? {
        let a = Self.parseField(rangeStart), b = Self.parseField(rangeEnd)
        if a == .invalid || b == .invalid { return L("Type a time like 1:30 or 90.", "Введите время, например 1:30 или 90.") }
        if case .value(let s) = a, case .value(let e) = b, e <= s { return L("The end of the part must come after its start.", "Конец части должен быть позже её начала.") }
        if (a != .empty || b != .empty) && !ffmpegAvailable { return L("Cutting a part needs ffmpeg, which is not installed.", "Для вырезки части нужен ffmpeg, он не установлен.") }
        return nil
    }

    var playlistItems: String? { PlaylistSpec.make(selection: selection, indices: (info?.entries ?? []).map(\.index)) }
    var selectedEntries: [PlaylistEntry] { (info?.entries ?? []).filter { selection.contains($0.index) } }

    /// The size the download will roughly take, for the footer ("about 410 MB").
    var estimatedBytes: Int64? {
        guard let info else { return nil }
        if phase == .playlist {
            let total = selectedEntries.compactMap(\.duration).reduce(0, +)
            guard total > 0 else { return nil }
            return DownloadFormatText.roughBytes(seconds: total, height: listMaxHeight, audioOnly: isAudio)
        }
        if isAudio { return info.duration.map { DownloadFormatText.roughBytes(seconds: $0, height: 0, audioOnly: true) } }
        return (selectedQuality ?? qualityOptions.first)?.estimatedBytes
    }

    var canDownload: Bool {
        guard phase == .info || phase == .playlist, rangeProblem == nil, !isLive else { return false }
        if phase == .playlist { return playlistItems != nil }
        return true
    }

    /// The button label: the verb follows what will happen.
    var primaryTitle: String {
        switch phase {
        case .empty: return L("Get Info", "Получить сведения")
        case .failed: return (failure?.canRetry ?? true) ? L("Try Again", "Повторить") : L("Get Info", "Получить сведения")
        case .fetching: return L("Getting Info…", "Получение сведений…")
        case .info, .playlist:
            return convertsAfterDownload ? L("Download and Convert", "Скачать и конвертировать") : L("Download", "Скачать")
        case .started: return L("Done", "Готово")
        }
    }

    func makeRequest() -> DownloadRequest? {
        guard let url = validURL, info != nil else { return nil }
        let mode = effectiveMode
        var r = DownloadRequest(url: url, outputDirectory: folder ?? deps.outputDirectory(mode))
        let s = deps.settings.data.downloader
        r.mode = mode
        r.audioFormat = audioFormat
        r.audioQuality = 0
        if !isAudio {
            if phase == .playlist { if listMaxHeight > 0 { r.maxHeight = listMaxHeight } }
            else if let q = selectedQuality, q.height > 0 { r.maxHeight = q.height }
        }
        r.after = isAudio || modeChoice == .maximum ? .keepOriginal : after
        r.embedMetadata = s.embedMetadata
        r.embedThumbnail = s.embedThumbnail
        r.filenameTemplate = s.filenameTemplate
        r.cookies = s.cookies
        r.rateLimitKBps = s.rateLimitKBps
        r.concurrentFragments = s.fragments
        if phase == .playlist { r.playlistItems = playlistItems }
        if !isAudio, subtitleMode != .none {
            r.subtitles = subtitleMode
            r.subtitleLanguages = subtitleLanguages.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        if case .value(let v) = Self.parseField(rangeStart) { r.sectionStart = v }
        if case .value(let v) = Self.parseField(rangeEnd) { r.sectionEnd = v }
        return r
    }

    // MARK: Actions

    /// The primary button.
    func primaryAction() {
        switch phase {
        case .empty, .failed: fetch()
        case .info, .playlist: download()
        case .started: break
        case .fetching: break
        }
    }

    private var downloadTask: Task<Void, Never>?

    func download() {
        guard canDownload, let request = makeRequest(), downloadTask == nil else { return }
        let title = info?.title
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.deps.start(request, title)
            self.downloadTask = nil
            if case .started(let job) = outcome {
                self.startedJob = job
                self.startedTitle = title ?? job.title
                self.phase = .started
            } else if let f = DownloadFailure.from(outcome) {
                self.fail(f)
            }
        }
    }

    func settledDownload() async { await downloadTask?.value }

    func openInStudio() {
        guard let url = validURL else { return }
        deps.openStudio(LinkItem(url: url, title: info?.title, sourceName: "download sheet"), effectiveMode)
    }

    /// Writes the browser that yt-dlp may take the sign-in from (the inline fix for "sign in" errors), then tries again.
    func chooseBrowser(_ browser: CookieBrowser) {
        deps.settings.update { $0.downloader.cookies = browser }
    }
}

// MARK: Previews and tests

extension DownloadSheetModel {
    /// A model in a given state without any fetch: what the snapshots draw and what layout tests inspect. Never used on a user path.
    static func preview(deps: Dependencies, phase: Phase, text: String = "", info: DownloadInfo? = nil, failure: DownloadFailure? = nil, job: Job? = nil,
                        clipboard: LinkItem? = nil) -> DownloadSheetModel {
        let m = DownloadSheetModel(deps: deps)
        m.text = text
        m.info = info
        if let info {
            m.qualityOptions = info.isPlaylist ? [] : FormatSelector.qualityOptions(for: info)
            if info.isPlaylist { m.selection = Set(info.entries.map(\.index)) }
        }
        m.failure = failure
        m.startedJob = job
        m.startedTitle = info?.title ?? job?.title ?? ""
        m.clipboardLink = clipboard
        m.phase = phase
        return m
    }
}
