import SwiftUI
import AppKit

// Offscreen snapshots of the whole Studio window and of its parts (`./build.sh snapshot <dir> studio-window`). The window is the real one: the sidebar, centre column, preview,
// queue panel and toolbar are the production views fed by a hand-built `StudioViewState`; only the inspector is a stand-in unless the session has a real schema.

enum StudioSnapshotScene: String, CaseIterable {
    case empty, video, image, audio, pdf, subtitles, sheet, archive, download, queue
}

/// A fake operation for the queue scene (the real engines are not needed to draw rows).
final class StudioSnapshotOperation: PerFileOperation, @unchecked Sendable {
    init() {
        super.init(meta: .make("snap.compress", .tools, .video, L10n("Compress", "Сжать"), symbol: "film", schema: "video.convert", inputs: ["mov", "mp4", "mkv"]))
    }
}

@MainActor
enum StudioWindowSnapshots {
    static let windowSize = CGSize(width: 1240, height: 780)

    static func register() {
        let reg = SnapshotRegistry.shared
        for scene in StudioSnapshotScene.allCases {
            let variants: [SnapshotVariant] = (scene == .video || scene == .queue) ? SnapshotVariant.lightDarkRu + SnapshotVariant.accessibility : SnapshotVariant.lightDarkRu
            reg.register("studio-window.\(scene.rawValue)", size: windowSize, backdrop: .windowBackground, chrome: .window(title: StudioWindowController.windowTitle), variants: variants) {
                StudioSnapshotWindow(scene: scene)
            }
        }
        // The smallest window the person can make: nothing may be cut off here.
        for scene in [StudioSnapshotScene.video, .empty] {
            reg.register("studio-window.min-\(scene.rawValue)", size: StudioWindowController.minimumSize, backdrop: .windowBackground,
                         chrome: .window(title: StudioWindowController.windowTitle), variants: [.light]) { StudioSnapshotWindow(scene: scene) }
        }
        reg.register("studio-window.dbgcentre", size: CGSize(width: 700, height: 700), backdrop: .windowBackground, variants: [.light]) { StudioDebugCentre() }
        reg.register("studio-window.dbgsidebar", size: CGSize(width: 260, height: 700), backdrop: .windowBackground, variants: [.light]) { StudioDebugSidebar() }
        reg.register("studio-window.compare", size: CGSize(width: 760, height: 520), backdrop: .windowBackground, variants: SnapshotVariant.lightDark) { StudioSnapshotCompare() }
        reg.register("studio-window.timeline", size: CGSize(width: 720, height: 200), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) { StudioSnapshotTimeline() }
        reg.register("studio-window.queue-panel", size: CGSize(width: 760, height: 460), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) { StudioSnapshotQueuePanel() }
    }

    // MARK: Model per scene

    static func makeModel(_ scene: StudioSnapshotScene) -> StudioWindowModel {
        let assets = StudioSnapshotAssets.shared
        let settings = AppSettings(fileURL: AppPaths.tempRoot.appendingPathComponent("studio-snap-settings-\(UUID().uuidString.prefix(6)).json"), autosave: false)
        let runner = scene == .queue ? StudioSnapshotQueue.makeRunner() : JobRunner(persistence: false, registry: OperationRegistry(), settings: settings)
        let model = StudioWindowModel(session: StudioSession(input: IncomingInput()), runner: runner, settings: settings)
        var state = StudioViewState()
        state.canStart = scene != .empty
        state.hasSchema = scene != .empty
        state.isModified = scene == .video
        state.presetName = scene == .video ? "Web 1080p" : nil
        state.summaryLine = nil

        func row(_ id: String, _ name: String, _ detail: String, _ kind: StudioContentKind, _ fileKind: FileKind?, _ url: URL?, status: StudioSource.Status = .ready,
                 bytes: Int64? = nil, duration: Double? = nil, fps: Double? = nil, size: CGSize? = nil, pages: Int? = nil) -> StudioSourceRow {
            var r = StudioSourceRow(id: id, name: name, detail: detail, kind: kind, fileKind: fileKind, url: url, status: status)
            r.sizeBytes = bytes; r.duration = duration; r.fps = fps; r.pixelSize = size; r.pageCount = pages
            return r
        }
        func targets(_ main: OperationFamily, _ title: String, _ symbol: String) -> [StudioTargetRow] {
            [StudioTargetRow(id: "\(main.rawValue).convert", title: title, symbol: symbol, family: main, unavailableReason: nil),
             StudioTargetRow(id: "audio.convert", title: L("Audio", "Аудио"), symbol: "waveform", family: .audio, unavailableReason: nil),
             StudioTargetRow(id: "image.convert", title: L("Images", "Изображения"), symbol: "photo", family: .image, unavailableReason: scene == .video ? L("Needs ffmpeg, not installed.", "Нужен ffmpeg, он не установлен.") : nil)]
        }
        let pages = [StudioPageRow(id: "format", title: L("Format", "Формат"), symbol: "shippingbox"), StudioPageRow(id: "video", title: L("Video", "Видео"), symbol: "film")]

        switch scene {
        case .empty:
            break
        case .video:
            let a = row("file:/Clips/Heron.mov", "Heron.mov", "3840x2160, HEVC, 59.94 fps", .video, .video, assets.photoURL, bytes: 1_240_000_000, duration: 761, fps: 59.94, size: CGSize(width: 3840, height: 2160))
            let b = row("file:/Clips/Boardwalk.mp4", "Boardwalk.mp4", "1920x1080, H.264, 25 fps", .video, .video, assets.photoURL, status: .probing, bytes: 220_000_000, duration: 95)
            state.sources = [a, b]; state.focusedSourceID = a.id
            state.targets = targets(.video, L("Video", "Видео"), "film"); state.targetID = "video.convert"; state.pages = pages
            model.previewOverride = StudioPreviewOverride(frames: PreviewFrames.synthetic(before: assets.videoFrame, after: assets.videoFrameAfter, bytes: 396_000_000, note: nil),
                                                         filmstrip: assets.filmstrip, overview: nil)
        case .image:
            let a = row("file:/Photos/Lake.jpg", "Lake.jpg", "1600x1000, JPEG", .image, .image, assets.photoURL, bytes: 3_400_000, size: CGSize(width: 1600, height: 1000))
            state.sources = [a]; state.focusedSourceID = a.id
            state.targets = targets(.image, L("Images", "Изображения"), "photo"); state.targetID = "image.convert"; state.pages = pages
            model.previewOverride = StudioPreviewOverride(frames: PreviewFrames.synthetic(before: assets.photoBefore, after: assets.photoAfter, bytes: 640_000, note: nil))
        case .audio:
            let a = row("file:/Audio/Interview.wav", "Interview.wav", "WAV, 48 kHz, stereo", .audio, .audio, assets.wavURL, bytes: 48_000_000, duration: 271)
            state.sources = [a]; state.focusedSourceID = a.id
            state.targets = targets(.audio, L("Audio", "Аудио"), "waveform"); state.targetID = "audio.convert"; state.pages = pages
            model.previewOverride = StudioPreviewOverride(frames: PreviewFrames.synthetic(before: nil, after: nil, bytes: 4_300_000, note: nil), filmstrip: nil,
                                                         overview: AudioOverview(peaks: assets.waveform, integratedLUFS: -17.4, samplePeakDB: -1.2, channels: 2))
        case .pdf:
            let a = row("file:/Docs/Report.pdf", "Report.pdf", "8 pages, A4", .pdf, .pdf, assets.pdfURL, bytes: 18_200, pages: 8)
            state.sources = [a]; state.focusedSourceID = a.id
            state.targets = targets(.pdf, "PDF", "doc.richtext"); state.targetID = "pdf.optimize"; state.pages = pages
        case .subtitles:
            let a = row("file:/Subs/Film.srt", "Film.srt", "SRT, 40 cues", .subtitle, .subtitle, assets.srtURL, bytes: 3_100)
            state.sources = [a]; state.focusedSourceID = a.id
            state.targets = targets(.subtitle, L("Subtitles", "Субтитры"), "captions.bubble"); state.targetID = "subtitle.convert"; state.pages = pages
        case .sheet:
            let a = row("file:/Data/Участки.csv", "Участки.csv", "CSV, 41 rows", .spreadsheet, .spreadsheet, assets.csvURL, bytes: 4_900)
            state.sources = [a]; state.focusedSourceID = a.id
            state.targets = targets(.spreadsheet, L("Spreadsheets", "Таблицы"), "tablecells"); state.targetID = "sheet.convert"; state.pages = pages
        case .archive:
            let a = row("file:/Archives/Unsafe.tar", "Unsafe.tar", "TAR", .archive, .archive, assets.unsafeTarURL, bytes: 10_240)
            let b = row("file:/Archives/Pack.zip", "Pack.zip", "ZIP, 5 files", .archive, .archive, assets.zipURL, bytes: 2_300)
            state.sources = [a, b]; state.focusedSourceID = b.id
            state.targets = targets(.archive, L("Archives", "Архивы"), "archivebox"); state.targetID = "archive.extract"; state.pages = pages
        case .download:
            let link = LinkItem(url: URL(string: "https://example.org/watch?v=heron")!, title: L("Heron at dawn, 4K", "Цапля на рассвете, 4K"))
            var a = row("link:example.org/watch?v=heron", link.displayTitle, link.host, .link, nil, nil)
            a.status = .ready
            state.sources = [a]; state.focusedSourceID = a.id; state.isLinkSession = true
            state.targets = [StudioTargetRow(id: "download.video", title: L("Download", "Скачать"), symbol: "arrow.down.circle", family: .download, unavailableReason: nil)]
            state.targetID = "download.video"; state.pages = pages
        case .queue:
            let a = row("file:/Clips/Heron.mov", "Heron.mov", "3840x2160, HEVC", .video, .video, assets.photoURL, bytes: 1_240_000_000, duration: 761)
            state.sources = [a]; state.focusedSourceID = a.id
            state.targets = targets(.video, L("Video", "Видео"), "film"); state.targetID = "video.convert"; state.pages = pages
            model.pane = .queue
        }
        model.freeze(state: state, queue: QueueSnapshot.make(runner))
        return model
    }
}

extension PreviewFrames {
    /// Frames for snapshots and tests.
    static func synthetic(before: CGImage?, after: CGImage?, bytes: Int64?, note: String?) -> PreviewFrames {
        PreviewFrames(before: before, after: after, note: note, resultBytes: bytes)
    }
}

struct StudioSnapshotWindow: View {
    let scene: StudioSnapshotScene
    @StateObject private var model: StudioWindowModel

    init(scene: StudioSnapshotScene) {
        self.scene = scene
        // Built here, not inside the StateObject autoclosure: that runs during the first SwiftUI update, and the scene's fixtures start child processes (zip, tar) whose wait spins
        // the run loop, which re-enters the update and aborts with "AttributeGraph: cycle detected".
        let model = StudioWindowSnapshots.makeModel(scene)
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        // The snapshot window grows by its toolbar (52 pt) and the harness centres a content frame of the requested height in it: asking for the full height fills the window.
        StudioWindowContent(model: model, inspector: (model.session.schema == nil && model.state.hasSchema) ? { AnyView(StudioSnapshotInspector(kind: model.state.kind)) } : nil)
    }
}

// MARK: - Parts

struct StudioSnapshotCompare: View {
    @State private var divider = 0.5
    @State private var zoom = PreviewZoom.fit
    var body: some View {
        let a = StudioSnapshotAssets.shared
        PreviewCanvas(before: a.photoBefore, after: a.photoAfter, isWorking: false, divider: $divider, zoom: $zoom, loupeOn: false) { _ in EmptyView() }
            .frame(width: 720, height: 480)
    }
}

struct StudioSnapshotTimeline: View {
    var body: some View {
        let a = StudioSnapshotAssets.shared
        VStack(spacing: DS.Space.lg) {
            StudioTimeline(duration: 761, time: 214.5, start: 120, end: 580, backdrop: .filmstrip(a.filmstrip), chapters: [0, 180, 420, 600], keyframes: stride(from: 0.0, to: 761, by: 24).map { $0 }, fps: 59.94,
                           canTrim: true, onScrub: { _, _ in }, onTrim: { _, _ in })
            StudioTimeline(duration: 271, time: 90, start: 0, end: 200, backdrop: .waveform(a.waveform), fps: nil, canTrim: true, onScrub: { _, _ in }, onTrim: { _, _ in })
        }
        .padding(DS.Space.lg)
        .frame(width: 720, height: 200)
    }
}

struct StudioSnapshotQueuePanel: View {
    @State private var runner = StudioSnapshotQueue.makeRunner()
    var body: some View { QueuePanel(runner: runner).frame(width: 760, height: 460) }
}

// MARK: - Queue fixture

@MainActor
enum StudioSnapshotQueue {
    /// A runner (no persistence, its own registry) holding one job in each state. Jobs are held, so nothing starts; states are set directly.
    static func makeRunner() -> JobRunner {
        let registry = OperationRegistry()
        let op = StudioSnapshotOperation()
        registry.register(op)
        let settings = AppSettings(fileURL: AppPaths.tempRoot.appendingPathComponent("studio-snap-q-\(UUID().uuidString.prefix(6)).json"), autosave: false)
        let runner = JobRunner(persistence: false, registry: registry, settings: settings)
        let a = StudioSnapshotAssets.shared
        func file(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/Users/me/Movies/\(name)"), isDirectory: false, size: 880_000_000) }

        let done = runner.enqueue(operation: op, items: [file("Lake walk.mov")])
        let running = runner.enqueue(operation: op, items: [file("Heron.mov")])
        let paused = runner.enqueue(operation: op, items: [file("Boardwalk.mkv")])
        let failed = runner.enqueue(operation: op, items: [file("Dunes.mov")])
        _ = runner.enqueue(operation: op, items: [file("Sunrise.mp4")], overrides: ["video.cq": .int(20)])
        _ = runner.enqueue(operation: op, items: [file("Fog.mp4")])

        done.markStarted(finishAction: .nothing)
        done.finish(.done, result: OperationResult(outputs: [a.photoURL]))
        running.markStarted(finishAction: .nothing)
        running.update(progress: 0.42, message: L("Converting", "Конвертация"), etaHint: 140)
        paused.markStarted(finishAction: .nothing)
        paused.update(progress: 0.15, message: nil, etaHint: 600)
        paused.markPaused(true)
        failed.markStarted(finishAction: .nothing)
        failed.finish(.failed, error: L("Not enough space on the disk. Free up 1.2 GB, then choose Retry.", "На диске не хватает места. Освободите 1,2 ГБ и нажмите «Повторить»."))
        return runner
    }
}

struct StudioDebugCentre: View {
    @StateObject private var model = StudioWindowSnapshots.makeModel(.video)
    var body: some View { StudioCentreContent(model: model).frame(width: 700, height: 700) }
}
struct StudioDebugSidebar: View {
    @StateObject private var model = StudioWindowSnapshots.makeModel(.video)
    var body: some View { StudioSidebarContent(model: model).frame(width: 260, height: 700) }
}
