import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// The model of ONE Studio window: it wraps the session (options, targets, presets) and the queue (JobRunner), keeps the small Equatable `StudioViewState` the views read,
// and performs the window's commands. Nothing here polls: it reacts to the session's and the runner's change notifications and to the runner's event stream.

enum StudioPane: String, Equatable, Sendable { case source, queue }

/// Counts the toolbar, the sidebar badge and the command availability need from the queue.
struct QueueSnapshot: Equatable, Sendable {
    var total = 0
    /// Added with "Add to Queue", waiting for "Start Queue".
    var held = 0
    var waiting = 0
    var running = 0
    var paused = 0
    var failed = 0
    var done = 0
    var queuePaused = false

    /// Jobs that still need attention in the sidebar badge (not finished).
    var open: Int { held + waiting + running + paused }
    var isEmpty: Bool { total == 0 }

    @MainActor
    static func make(_ runner: JobRunner) -> QueueSnapshot {
        var q = QueueSnapshot()
        q.queuePaused = runner.queuePaused
        for j in runner.jobs {
            q.total += 1
            switch j.state {
            case .waiting: if j.held { q.held += 1 } else { q.waiting += 1 }
            case .running: q.running += 1
            case .paused: q.paused += 1
            case .failed: q.failed += 1
            case .done: q.done += 1
            case .cancelled, .skipped: break
            }
        }
        return q
    }
}

/// Small settings of the window that are not part of `SettingsData` (the frozen document): kept in their own file in Application Support.
struct StudioWindowState: Codable, Equatable, Sendable {
    var wasOpenAtQuit = false
    var whenDone: String = QueueWhenDone.nothing.rawValue

    static var fileURL: URL { AppPaths.supportDir.appendingPathComponent("studio-window.json") }

    static func load() -> StudioWindowState {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(StudioWindowState.self, from: d) else { return StudioWindowState() }
        return s
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Self.fileURL, options: .atomic) }
    }
}

/// What a drop or a paste delivers, turned into inputs: file URLs become files, web addresses and text with web addresses become links. Pure.
enum StudioDropParser {
    static func inputs(urls: [URL], strings: [String]) -> [InputItem] {
        var out: [InputItem] = []
        var seen = Set<String>()
        func add(_ i: InputItem) { if seen.insert(i.id).inserted { out.append(i) } }
        for u in urls {
            if u.isFileURL { add(.file(FileItem(url: u))) }
            else { for l in LinkParsing.downloadableLinks(in: u.absoluteString) { add(.link(l)) } }
        }
        for s in strings { for l in LinkParsing.downloadableLinks(in: s) { add(.link(l)) } }
        return out
    }

    /// Reads dropped item providers (Finder files, browser links, dragged text).
    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> [InputItem] {
        var urls: [URL] = [], strings: [String] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let u = await loadURL(p) { urls.append(u); continue }
            }
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let s = await loadString(p) { strings.append(s) }
        }
        return inputs(urls: urls, strings: strings)
    }

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    private static func loadString(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: NSString.self) { s, _ in cont.resume(returning: s as? String) }
        }
    }
}

/// Puts the Mac to sleep once, after the queue ran clean ("When done: Put the Mac to sleep"). Armed only on request, listens to the runner's events (no timers), disarms itself.
@MainActor
final class QueueSleepWatcher {
    private var task: Task<Void, Never>?
    private(set) var isArmed = false
    private let sleepAction: @MainActor () -> Void

    init(sleepAction: @escaping @MainActor () -> Void = QueueSleepWatcher.sleepNow) { self.sleepAction = sleepAction }

    func arm(runner: JobRunner) {
        disarm()
        isArmed = true
        let events = runner.events()
        task = Task { @MainActor [weak self, weak runner] in
            for await e in events {
                guard let self, let runner else { return }
                if case .batchFinished(let summary) = e {
                    let active = runner.jobs.filter { !$0.state.isFinished && !($0.held && $0.state == .waiting) }.count
                    if QueueWhenDone.shouldSleep(choice: .sleep, failed: summary.failed, cancelled: summary.cancelled, stillActive: active) {
                        self.isArmed = false
                        self.sleepAction()
                        return
                    }
                    if summary.failed > 0 || summary.cancelled > 0 { self.isArmed = false; return }   // a failure keeps the Mac awake
                }
            }
        }
    }

    func disarm() { task?.cancel(); task = nil; isArmed = false }

    /// `pmset sleepnow` needs no privileges. Arguments are an array, never a shell string.
    static func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// What a snapshot (or a test) puts in the preview instead of reading files and asking the session: pictures, the filmstrip, the loudness overview.
struct StudioPreviewOverride {
    var frames: PreviewFrames?
    var filmstrip: [CGImage]?
    var overview: AudioOverview?
}

@MainActor
final class StudioWindowModel: ObservableObject {
    let session: StudioSession
    let runner: JobRunner
    let transport = PreviewTransport()
    let sleepWatcher: QueueSleepWatcher

    @Published private(set) var state: StudioViewState
    @Published private(set) var queue = QueueSnapshot()
    @Published var pane: StudioPane = .source {
        didSet { if oldValue != pane { savePane() } }
    }
    @Published var selectedSourceID: String? {
        didSet { if oldValue != selectedSourceID { scheduleRefresh() } }
    }
    @Published var whenDone: QueueWhenDone = .nothing {
        didSet { if oldValue != whenDone { persistWhenDone() } }
    }
    @Published private(set) var redoAvailable = false
    @Published var isDropTargeted = false
    /// A calm one-line note near the top of the centre column ("2 items were left out"), dismissed by the person.
    @Published var notice: String?
    /// The text of the open "Add a Link" sheet; nil while the sheet is closed.
    @Published var linkDraft: String?
    /// Width of the preview in pixels and the time of the frame it shows: what "Refresh Preview" asks the session for.
    var previewTime: Double?
    var previewMaxPixel = 1280

    /// Snapshots and tests show a hand-built state instead of the session's: the model stops following the session while this is set.
    private(set) var isFrozen = false
    var previewOverride: StudioPreviewOverride?

    weak var window: NSWindow?
    /// Edit > Undo while no text field has the focus (see `StudioWindowController.windowWillReturnUndoManager`).
    private(set) lazy var undoBridge = StudioUndoBridge(model: self)
    private let settings: AppSettings
    private var bag = Set<AnyCancellable>()
    private var eventsTask: Task<Void, Never>?
    private var refreshPending = false
    private var inUndoRedo = false
    private var restoring = true

    init(session: StudioSession, runner: JobRunner? = nil, settings: AppSettings = .shared, sleepWatcher: QueueSleepWatcher? = nil) {
        let runner = runner ?? JobRunner.shared
        self.session = session
        self.runner = runner
        self.settings = settings
        self.sleepWatcher = sleepWatcher ?? QueueSleepWatcher()
        self.state = StudioViewState.make(from: session, focusedSourceID: nil)
        self.queue = QueueSnapshot.make(runner)
        self.whenDone = QueueWhenDone(rawValue: StudioWindowState.load().whenDone) ?? .nothing
        // An empty window opens on the queue only while jobs are running or waiting there: finished jobs stay in the runner, and opening on them hid the drop area.
        self.pane = (settings.data.studio.showQueue && queue.open > 0 && state.isEmpty) ? .queue : .source
        self.selectedSourceID = session.sources.first?.id
        self.restoring = false
        session.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &bag)
        runner.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &bag)
        session.$values.dropFirst().sink { [weak self] _ in
            guard let self, !self.inUndoRedo else { return }
            self.redoAvailable = false
        }.store(in: &bag)
        // Job state changes (waiting -> running -> done) do not publish through the runner: its event stream does. Progress ticks are ignored on purpose.
        let events = runner.events()
        eventsTask = Task { @MainActor [weak self] in
            for await e in events {
                if case .progress = e { continue }
                self?.scheduleRefresh()
            }
        }
        refresh()
    }

    deinit { eventsTask?.cancel() }

    // MARK: Refresh

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Shows `state` (and `queue`) as they are. For snapshots and tests; the real window never calls it.
    func freeze(state: StudioViewState, queue: QueueSnapshot? = nil) {
        isFrozen = true
        self.state = state
        if let queue { self.queue = queue }
        if selectedSourceID == nil { selectedSourceID = state.focusedSourceID }
    }

    func refresh() {
        refreshPending = false
        guard !isFrozen else { return }
        if selectedSourceID == nil || !session.sources.contains(where: { $0.id == selectedSourceID }) { selectedSourceID = session.sources.first(where: { $0.isUsableForStudio })?.id ?? session.sources.first?.id }
        let new = StudioViewState.make(from: session, focusedSourceID: selectedSourceID)
        if new != state { state = new }
        let q = QueueSnapshot.make(runner)
        if q != queue { queue = q }
    }

    // MARK: Commands

    func commandContext() -> StudioCommandContext {
        StudioCommandContext(hasSources: !state.isEmpty, sessionCanStart: state.canStart, heldQueueCount: queue.held, activeJobCount: queue.running + queue.paused,
                             hasSchema: state.hasSchema, pageCount: state.pages.count, hasTimeline: state.kind.hasTimeline && pane == .source,
                             canPreview: state.hasSchema && !state.isEmpty && !state.isLinkSession, isModified: session.canUndo, redoAvailable: session.canRedo)
    }

    func isEnabled(_ command: StudioCommand) -> Bool { StudioCommands.isEnabled(command, commandContext()) }

    func perform(_ command: StudioCommand) {
        guard isEnabled(command) else { return }
        switch command {
        case .addFiles: presentAddFiles()
        case .pasteLink: beginAddingLink()
        case .start: start()
        case .addToQueue: addToQueue()
        case .preview: refreshPreview()
        case .searchOptions: StudioResponderFinder.focusSearchField(in: window)
        case .presetMenu: if !StudioResponderFinder.openPresetMenu(in: window) { StudioResponderFinder.focusSearchField(in: window) }
        case .inspectorPage(let n): session.selectPage(at: n - 1)     // counts the pages the form shows, not the hidden ones
        case .playPause: transport.togglePlay()
        case .stepBackward: transport.step(forward: false, coarse: false)
        case .stepForward: transport.step(forward: true, coarse: false)
        case .setIn: transport.setIn()
        case .setOut: transport.setOut()
        case .undoOption: undo()
        case .redoOption: redo()
        }
    }

    func undo() {
        inUndoRedo = true; session.undo(); inUndoRedo = false
        redoAvailable = true
    }

    func redo() {
        inUndoRedo = true; session.redo(); inUndoRedo = false
        // One more redo may exist; the next failed attempt is harmless, so keep it available until a new edit arrives.
    }

    // MARK: Sources

    /// True when `inputs` are of the kind this window already works on (files with files, links with links), or the window is empty.
    func accepts(_ inputs: [InputItem]) -> Bool {
        guard let first = session.sources.first else { return true }
        return inputs.allSatisfy { $0.isLink == first.input.isLink }
    }

    func ingest(_ inputs: [InputItem]) {
        guard !inputs.isEmpty else { return }
        let before = Set(session.sources.map(\.id))
        session.addSources(inputs)
        if let first = inputs.first(where: { !before.contains($0.id) }) { selectedSourceID = first.id }
        pane = .source
        scheduleRefresh()
    }

    /// "Add a Link…" (Command-L, the sidebar, the empty state): a sheet with one field, filled with the link on the clipboard when there is one. The link becomes a
    /// source of this window (download options, then Start), it does not open the separate download window.
    func beginAddingLink() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        if case .success(let item) = LinkParsing.firstDownloadable(in: clip) { linkDraft = item.url.absoluteString } else { linkDraft = "" }
    }

    /// Adds the link in the sheet; returns the reason when the text holds no link that can be downloaded (the sheet shows it and stays open).
    @discardableResult
    func commitLink() -> LinkRejection? {
        switch LinkParsing.firstDownloadable(in: linkDraft ?? "") {
        case .success(var item):
            item.sourceName = item.sourceName ?? "Studio"
            linkDraft = nil
            // A window works on files or on links, never both: a link added next to files used to be marked "can't be combined" and silently left out.
            if accepts([.link(item)]) { ingest([.link(item)]) }
            else { StudioWindowController.shared.show(input: IncomingInput(links: [item], origin: .studio), reuseOpen: false) }
            return nil
        case .failure(let reason):
            return reason
        }
    }

    func ingest(providers: [NSItemProvider]) {
        Task { @MainActor in
            let items = await StudioDropParser.load(providers)
            if items.isEmpty { self.notice = L("Nothing in that drop could be added: drop files, a folder or a web link.", "Из перетащенного ничего не удалось добавить: перетащите файлы, папку или веб-ссылку."); return }
            // Links next to files (or files next to links) go to a window of their own, as with Add a Link.
            let linkWindow = self.session.sources.first?.input.isLink ?? items[0].isLink
            let mine = items.filter { $0.isLink == linkWindow }, other = items.filter { $0.isLink != linkWindow }
            self.ingest(mine)
            if !other.isEmpty {
                StudioWindowController.shared.show(input: IncomingInput(files: other.compactMap(\.file), links: other.compactMap(\.link), origin: .studio), reuseOpen: false)
            }
        }
    }

    func removeSource(id: String) { session.removeSource(id: id); scheduleRefresh() }

    func presentAddFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = L("Add Files", "Добавить файлы")
        panel.prompt = L("Add", "Добавить")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK else { return }
            let items = panel.urls.map { InputItem.file(FileItem(url: $0)) }
            Task { @MainActor in self?.ingest(items) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handle) } else { panel.begin(completionHandler: handle) }
    }

    // MARK: Running

    func addToQueue() {
        let jobs = session.addToQueue()
        guard !jobs.isEmpty else { return }
        MessageCenter.shared.post(jobs.count == 1 ? L("Added to the queue", "Добавлено в очередь") : L("\(jobs.count) added to the queue", "Добавлено в очередь: \(jobs.count)"),
                                  severity: .info, symbol: "text.badge.plus")
        scheduleRefresh()
    }

    /// HandBrake's rule: with a queue waiting, Start runs the queue; otherwise it runs the current work.
    func start() {
        if StudioCommands.startRunsQueue(commandContext()) { startQueue() } else { startSession() }
    }

    func startQueue() {
        applyWhenDoneToWaitingJobs()
        runner.startQueue()
        armSleepIfNeeded()
        pane = .queue
        scheduleRefresh()
    }

    private func startSession() {
        let previous = session.outputRules.after
        if whenDone.afterFinish != .nothing { session.outputRules.after = whenDone.afterFinish }
        // A queue paused earlier (here or in the Jobs window) would keep the new job waiting for ever.
        if runner.queuePaused { runner.resumeQueue() }
        let jobs = session.start()
        if session.outputRules.after != previous { session.outputRules.after = previous }
        guard !jobs.isEmpty else { return }
        armSleepIfNeeded()
        pane = .queue
        scheduleRefresh()
    }

    /// Queued jobs take the "when done" choice at the moment the queue starts (rules are read when a job starts).
    func applyWhenDoneToWaitingJobs() {
        let after = whenDone.afterFinish
        guard after != .nothing else { return }
        for j in runner.jobs where j.state == .waiting {
            var rules = j.outputRules ?? settings.data.output
            if rules.after == .nothing { rules.after = after; _ = runner.updateOverrides(j, j.overrides, outputRules: rules) }
        }
    }

    private func armSleepIfNeeded() {
        if whenDone == .sleep { sleepWatcher.arm(runner: runner) } else { sleepWatcher.disarm() }
    }

    func refreshPreview() { session.requestPreview(time: previewTime, maxPixel: previewMaxPixel) }

    // MARK: Persistence

    private func savePane() {
        guard !restoring else { return }
        let show = pane == .queue
        settings.update { $0.studio.showQueue = show }
    }

    private func persistWhenDone() {
        guard !restoring else { return }
        var s = StudioWindowState.load()
        s.whenDone = whenDone.rawValue
        s.save()
        if whenDone != .sleep { sleepWatcher.disarm() } else if queue.open > 0 && queue.running + queue.paused > 0 { sleepWatcher.arm(runner: runner) }
    }
}

extension StudioSource {
    /// Probe failures (a mixed batch, a missing file) are left out of the default selection.
    var isUsableForStudio: Bool { if case .failed = status { return false }; return true }
}
