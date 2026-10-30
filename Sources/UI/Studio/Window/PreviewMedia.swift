import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

// Media helpers of the preview pane: frames for the scrubber (AVFoundation, ffmpeg for containers macOS cannot open), the filmstrip under the timeline, the key frame scan, and the
// 3 second test render. Everything is cancellable, runs below user-interactive priority and writes only into `AppPaths` temp folders.

enum PreviewFrameGrabber {
    /// The frame at `time`, longest side <= maxPixel, rotation applied. Fast and approximate (nearest key frame) when `exact` is false: right for scrubbing.
    static func frame(url: URL, at time: Double, maxPixel: Int, exact: Bool = false) async -> CGImage? {
        if let img = await native(url: url, at: time, maxPixel: maxPixel, exact: exact) { return img }
        return await viaFFmpeg(url: url, at: time, maxPixel: maxPixel)
    }

    private static func native(url: URL, at time: Double, maxPixel: Int, exact: Bool) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        if !exact { gen.requestedTimeToleranceBefore = .positiveInfinity; gen.requestedTimeToleranceAfter = .positiveInfinity }
        else { gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero }
        var t = max(0, time)
        if let d = (try? await asset.load(.duration))?.seconds, d.isFinite, d > 0 { t = min(t, max(0, d - 0.05)) }
        return try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    private static func viaFFmpeg(url: URL, at time: Double, maxPixel: Int) async -> CGImage? {
        guard let ffmpeg = ToolLocator.shared.url(.ffmpeg), !Task.isCancelled else { return nil }
        let dir = AppPaths.makeTempDirectory(purpose: "studio-frame")
        defer { AppPaths.removeTemp(dir) }
        let out = dir.appendingPathComponent("frame.png")
        let m = max(16, maxPixel)
        let scale = "scale=w='if(gt(iw,ih),min(iw,\(m)),-2)':h='if(gt(iw,ih),-2,min(ih,\(m)))'"
        let args = ["-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.3f", max(0, time)), "-i", url.path, "-frames:v", "1", "-an", "-sn", "-vf", scale, out.path]
        _ = try? await ProcessRunner.run(ffmpeg, args, toolName: "ffmpeg", allowNonZeroExit: true, background: true)
        guard let src = CGImageSourceCreateWithURL(out as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// `count` small frames spread evenly over the clip (the filmstrip behind the timeline). Empty when the file cannot be opened by AVFoundation.
    static func filmstrip(url: URL, duration: Double, count: Int, maxPixel: Int = 160) async -> [CGImage] {
        guard duration > 0, count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in gen.images(for: times) {
            if Task.isCancelled { gen.cancelAllCGImageGeneration(); return [] }
            if case .success(_, let image, _) = result { images.append(image) }
        }
        return images
    }
}

/// Key frame times via ffprobe (`-skip_frame nokey`): the ticks under the timeline when the person asks for them. Optional: no ffprobe, no ticks.
enum KeyframeScanner {
    static var isAvailable: Bool { ToolLocator.shared.has(.ffprobe) }

    static func scan(url: URL, limit: Int = 4000) async -> [Double] {
        guard let ffprobe = ToolLocator.shared.url(.ffprobe) else { return [] }
        let box = Locked<[Double]>([])
        let args = ["-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey", "-show_entries", "frame=pts_time", "-of", "csv=p=0", url.path]
        _ = try? await ProcessRunner.run(ffprobe, args, onStdoutLine: { line in
            if let t = Double(line.trimmingCharacters(in: .whitespaces)) { box.withLock { if $0.count < limit { $0.append(t) } } }
        }, toolName: "ffprobe", allowNonZeroExit: true, background: true)
        return box.value.sorted()
    }
}

// MARK: - The 3 second test render

/// "Render 3 s Test": a real encode of three seconds at the playhead with the current options, into a temp folder, looped in the pane. It uses a private runner, so the
/// person's queue and history are untouched, and the trim fields of the schema (found by key) carry the window.
enum PreviewClipPlan {
    static let length = 3.0

    /// The trim window around `time`: starts at `time`, but at most `length` before the end of the clip.
    static func window(time: Double, duration: Double, length: Double = PreviewClipPlan.length) -> (start: Double, end: Double) {
        let l = min(length, max(duration, 0.1))
        let start = min(max(time, 0), max(duration - l, 0))
        return (PreviewMath.snappedToFrame(start, fps: nil), PreviewMath.snappedToFrame(start + l, fps: nil))
    }

    /// The recipe of the test: the session's recipe plus the trim window, written to a private output folder with the name template that cannot collide.
    static func recipe(base: Recipe, bindings: PreviewBindings, window: (start: Double, end: Double), outputDirectory: URL) -> Recipe? {
        guard let s = bindings.trimStartKey, let e = bindings.trimEndKey else { return nil }
        var r = base
        r.values[s] = .double(window.start)
        r.values[e] = .double(window.end)
        var rules = r.output ?? OutputRules()
        rules.dirMode = .custom
        rules.customDir = outputDirectory.path
        rules.nameTemplate = "{name}"
        rules.collision = .number
        rules.trashSource = false
        rules.after = .nothing
        r.output = rules
        return r
    }
}

@MainActor
final class PreviewClipRenderer: ObservableObject {
    enum State: Equatable {
        case idle
        case rendering(Double?)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var runner: JobRunner?
    private var job: Job?
    private var folder: URL?
    private var watch: Task<Void, Never>?
    private let makeRunner: @MainActor () -> JobRunner

    init(makeRunner: @escaping @MainActor () -> JobRunner = { JobRunner(persistence: false) }) { self.makeRunner = makeRunner }

    var isRendering: Bool { if case .rendering = state { return true }; return false }

    func start(base: Recipe, bindings: PreviewBindings, file: FileItem, time: Double, duration: Double) {
        cancel()
        let folder = AppPaths.makeTempDirectory(purpose: "studio-test")
        self.folder = folder
        let window = PreviewClipPlan.window(time: time, duration: duration)
        guard let recipe = PreviewClipPlan.recipe(base: base, bindings: bindings, window: window, outputDirectory: folder) else {
            state = .failed(L("This kind of file has no 3 second test.", "Для этого типа файлов нет трёхсекундной пробы."))
            return
        }
        let runner = makeRunner()
        self.runner = runner
        guard let job = runner.submit(recipe: recipe, items: [file], origin: .studio, mode: .studio) else {
            state = .failed(L("The conversion for this test is not available.", "Преобразование для пробы недоступно."))
            return
        }
        self.job = job
        state = .rendering(nil)
        let events = runner.events()
        watch = Task { @MainActor [weak self] in
            for await e in events {
                guard let self, let job = self.job else { return }
                switch e {
                case .progress(let j) where j.id == job.id: self.state = .rendering(j.progress)
                case .finished(let j) where j.id == job.id:
                    if let out = j.outputs.first { self.state = .ready(out) } else { self.state = .failed(L("The test produced no file.", "Проба не создала файл.")) }
                    return
                case .failed(let j) where j.id == job.id:
                    self.state = .failed(j.errorMessage ?? L("The test could not be rendered.", "Не удалось создать пробу."))
                    return
                case .cancelled(let j) where j.id == job.id:
                    self.state = .idle
                    return
                default: break
                }
            }
        }
    }

    func cancel() {
        watch?.cancel(); watch = nil
        if let j = job { runner?.cancel(j) }
        job = nil; runner = nil
        state = .idle
    }

    /// Removes the rendered clip and its folder (the window closes, or a new test starts).
    func cleanUp() {
        cancel()
        if let f = folder { AppPaths.removeTemp(f) }
        folder = nil
    }
}
