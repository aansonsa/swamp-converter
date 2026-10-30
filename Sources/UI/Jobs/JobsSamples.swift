import Foundation

/// Synthetic jobs in every state, for the snapshots and the self-tests. They are plain `Job` objects driven through the same methods the runner uses
/// (`markStarted`, `update`, `setStages`, `finish`); nothing runs and no file is touched.
@MainActor
enum JobsSamples {
    private static func file(_ name: String, size: Int64 = 4_200_000) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/Users/me/Pictures/\(name)"), isDirectory: false, size: size)
    }

    static func make(_ title: String, op: String = "image.to.jpg", names: [String], mode: RunMode = .studio, batch: UUID = UUID(), size: Int64 = 4_200_000) -> Job {
        Job(batchID: batch, operationID: op, title: title, items: names.map { file($0, size: size) }, overrides: OptionValues(), outputRules: nil, origin: .studio, mode: mode, held: false)
    }

    static func link(_ title: String, page: String, mode: RunMode = .quick) -> Job {
        let item = LinkItem(url: URL(string: "https://example.com/watch?v=tide")!, title: page)
        return Job(batchID: UUID(), operationID: "download.video", title: title, items: [], links: [item], overrides: OptionValues(), outputRules: nil, origin: .wheel, mode: mode, held: false)
    }

    static func running(_ title: String = "Convert to MP4", names: [String] = ["holiday.mov"], progress: Double = 0.42, eta: TimeInterval = 130,
                        message: String = "Encoding 1080p", op: String = "video.to.mp4", mode: RunMode = .studio) -> Job {
        let j = make(title, op: op, names: names, mode: mode, size: 480_000_000)
        j.markStarted(finishAction: .nothing)
        j.update(progress: progress, message: message, etaHint: eta)
        return j
    }

    static func twoStage(progress: Double = 0.25, downloadFraction: Double = 0.62) -> Job {
        let j = link(L("Download video", "Скачать видео"), page: "Tide pools of the northern coast")
        j.markStarted(finishAction: .nothing)
        var download = StageProgress(spec: .download(), state: .running, fraction: downloadFraction)
        download.startedAt = Date()
        j.setStages([download, StageProgress(spec: .convert())])
        j.update(progress: progress, message: "", etaHint: 95)
        return j
    }

    static func paused() -> Job {
        let j = running("Compress video", names: ["interview.mp4"], progress: 0.6, eta: 300, message: "Encoding", op: "video.compress")
        j.markPaused(true)
        return j
    }

    static func queued(_ title: String = "Merge PDF", names: [String] = ["a.pdf", "b.pdf", "c.pdf"]) -> Job {
        make(title, op: "pdf.merge", names: names)
    }

    static func done(_ title: String = "Convert to JPG", input: String = "IMG_2041.heic", output: String = "IMG_2041.jpg", note: L10n? = nil) -> Job {
        let j = make(title, names: [input])
        j.markStarted(finishAction: .nothing)
        j.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/Users/me/Pictures/\(output)")], note: note))
        return j
    }

    static func doneMany() -> Job {
        let names = ["day1.png", "day2.png", "day3.png", "day4.png"]
        let j = make("Convert to PNG", op: "image.to.png", names: names)
        j.markStarted(finishAction: .nothing)
        j.finish(.done, result: OperationResult(outputs: names.map { URL(fileURLWithPath: "/Users/me/Pictures/Out/" + $0) }))
        return j
    }

    static func withWarnings() -> Job {
        let j = make("Convert to PNG", op: "image.to.png", names: ["scan-01.tiff", "scan-02.tiff", "scan-03.tiff"])
        j.markStarted(finishAction: .nothing)
        j.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/Users/me/Pictures/scan-01.png"), URL(fileURLWithPath: "/Users/me/Pictures/scan-03.png")],
                                                failures: ["scan-02.tiff: " + L("Cannot read scan-02.tiff.", "Не удалось прочитать scan-02.tiff.")]))
        return j
    }

    static func failed(_ message: String? = nil) -> Job {
        let j = make("Compress video", op: "video.compress", names: ["interview.mp4"], size: 480_000_000)
        j.markStarted(finishAction: .nothing)
        j.finish(.failed, error: message ?? L("ffmpeg is not installed. Install it with Homebrew: brew install ffmpeg.",
                                              "ffmpeg не установлен. Установите его через Homebrew: brew install ffmpeg."))
        return j
    }

    static func cancelled() -> Job {
        let j = make("Convert to WebP", op: "image.to.webp", names: ["poster.png"])
        j.markStarted(finishAction: .nothing)
        j.finish(.cancelled)
        return j
    }

    /// Six jobs in mixed states: the Jobs window sheet.
    static func mixed() -> [Job] {
        [running(), twoStage(), queued(), done(), failed(), withWarnings()]
    }
}
