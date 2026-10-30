import Foundation

// Small helpers of the download run: the progress sink that turns yt-dlp lines into throttled stage progress, the job title, the test seam of
// the convert stage and the subtitle burn-in step.

/// Collects what one yt-dlp run prints. Called from the process I/O queue; everything is lock-protected.
final class DownloadProgressSink: @unchecked Sendable {
    struct Update { var fraction: Double?; var message: String? }

    private let lock = NSLock()
    private var mapper: DownloadProgressMapper
    private var lastForward = Date.distantPast
    private var lastPhase: DownloadProgress.Phase = .fetchingInfo
    private var destinations: [String] = []
    private var errorLines: [String] = []
    private var lastItem: (index: Int, count: Int)?
    /// Minimum seconds between two forwarded updates (the Jobs window shows 10 Hz at most).
    let interval: TimeInterval

    init(parts: [Double], items: Int, interval: TimeInterval = 0.1) {
        mapper = DownloadProgressMapper(parts: parts, items: items)
        self.interval = interval
    }

    /// Feeds one stdout line. Returns an update to forward, or nil when the line carries no news or came too soon.
    func feed(line: String, now: Date = Date()) -> Update? {
        lock.lock(); defer { lock.unlock() }
        if let d = YtDlpProgressParser.destinationPath(in: line) { destinations.append(d) }
        guard let p = YtDlpProgressParser.parse(line: line) else { return nil }
        if let i = p.itemIndex, let n = p.itemCount { lastItem = (i, n) }
        let fraction = mapper.feed(p)
        let phaseChanged = p.phase != lastPhase
        lastPhase = p.phase
        let done = (fraction ?? 0) >= 0.999 || (p.fraction ?? 0) >= 0.999     // the end of a file is always shown
        guard phaseChanged || done || now.timeIntervalSince(lastForward) >= interval else { return nil }
        lastForward = now
        return Update(fraction: fraction, message: message(for: p))
    }

    /// True for the lines that only carry a percentage (ours and yt-dlp's own): they are shown on the bar, not written to the job log.
    static func isProgressNoise(_ line: String) -> Bool {
        if line.hasPrefix("SC|") || line.hasPrefix("download:SC|") || line.isEmpty { return true }
        return line.range(of: "^\\[download\\]\\s+[0-9]+(\\.[0-9]+)?%", options: .regularExpression) != nil
    }

    func addStderr(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        errorLines.append(line)
        if errorLines.count > 60 { errorLines.removeFirst(errorLines.count - 60) }
    }

    var stderrText: String { lock.lock(); defer { lock.unlock() }; return errorLines.joined(separator: "\n") }
    var reportedDestinations: [String] { lock.lock(); defer { lock.unlock() }; return destinations }

    private func message(for p: DownloadProgress) -> String? {
        var prefix = ""
        if let item = lastItem, item.count > 1 { prefix = L("Video \(item.index) of \(item.count). ", "Видео \(item.index) из \(item.count). ") }
        switch p.phase {
        case .fetchingInfo: return prefix + L("Contacting the site…", "Связь с сайтом…")
        case .merging: return prefix + L("Joining video and sound…", "Склейка видео и звука…")
        case .extractingAudio: return prefix + L("Extracting the sound…", "Извлечение звука…")
        case .embedding: return prefix + L("Adding title and cover…", "Добавление названия и обложки…")
        case .finished: return prefix + L("Download finished", "Загрузка завершена")
        case .downloading:
            guard let done = p.downloadedBytes else { return prefix + L("Downloading…", "Загрузка…") }
            var s = Util.formatBytes(done)
            if let total = p.totalBytes, total > 0 { s += L(" of ", " из ") + Util.formatBytes(total) }
            if let speed = p.bytesPerSecond, speed > 0 { s += ", " + Util.formatBytes(Int64(speed)) + L("/s", "/с") }
            return prefix + L("Downloading ", "Загрузка ") + s
        }
    }
}

/// The job card shows the video title as soon as it is known ("Download: Swamp Documentary").
enum DownloadJobTitle {
    static func set(_ title: String, jobID: UUID) {
        let trimmed = title.count > 90 ? String(title.prefix(90)) + "..." : title
        Task { @MainActor in
            DownloadService.shared.jobRunner.job(id: jobID)?.title = L("Download: \(trimmed)", "Загрузка: \(trimmed)")
        }
    }
}

/// Test seam of the convert stage: the self-tests replace the nested smart / preset run so the download module is tested without the
/// smart module's ffmpeg work. nil in production.
enum DownloadPostProcess {
    typealias Override = @Sendable (_ source: URL, _ after: AfterDownload, _ rules: OutputRules, _ ctx: OperationContext) async throws -> [URL]
    nonisolated(unsafe) static var override: Override?

    /// The operation that performs a post-download action, or why none can.
    static func operation(for after: AfterDownload) -> (op: Operation, overrides: OptionValues)? {
        let registry = OperationRegistry.shared
        switch after {
        case .keepOriginal: return nil
        case .bestForApple: return registry.operation(id: "smart.best").map { ($0, OptionValues()) }
        case .universal: return registry.operation(id: "smart.universal").map { ($0, OptionValues()) }
        case .preset(let id):
            guard let preset = PresetStore.shared.preset(id: id) else { return nil }
            let op = preset.operationID.flatMap { registry.operation(id: $0) } ?? registry.primaryOperation(forTarget: preset.targetID)
            return op.map { ($0, preset.values) }
        }
    }
}

/// Draws the downloaded .srt into the picture with ffmpeg's subtitles filter (needs libass; the option is disabled without it).
/// The picture is re-encoded once: hevc_videotoolbox when the Mac has it, otherwise libx264 at a high quality; sound is copied.
enum DownloadBurnIn {
    static func arguments(inputName: String, subtitleName: String, outputName: String, hardware: Bool) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-i", inputName, "-vf", "subtitles=\(subtitleName)", "-map", "0:v:0", "-map", "0:a?", "-sn"]
        if hardware { a += ["-c:v", "hevc_videotoolbox", "-q:v", "70", "-tag:v", "hvc1"] }
        else { a += ["-c:v", "libx264", "-crf", "16", "-preset", "medium", "-pix_fmt", "yuv420p"] }
        a += ["-c:a", "copy", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", outputName]
        return a
    }

    /// Runs the burn-in in `area.root/burn`; returns the new file (same stem as the download). Throws a calm message on failure.
    static func run(source: URL, subtitles: URL, area: DownloadWorkArea, duration: Double?, ctx: OperationContext) async throws -> URL {
        let ffmpeg = try ctx.tools.require(.ffmpeg)
        guard Capabilities.shared.has("ff.filter.subtitles") else {
            throw ConversionError.message(L10n("This ffmpeg cannot draw subtitles into the picture (it was built without libass).", "Этот ffmpeg не умеет вшивать субтитры в картинку (собран без libass)."))
        }
        let dir = area.root.appendingPathComponent("burn", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The filter takes a path in its own escaping rules; a neutral copy next to the output avoids every special character.
        let subCopy = dir.appendingPathComponent("subs.srt")
        try? FileManager.default.removeItem(at: subCopy)
        try FileManager.default.copyItem(at: subtitles, to: subCopy)
        let output = dir.appendingPathComponent(source.lastPathComponent)
        let hardware = Capabilities.shared.has("ff.enc.hevc_videotoolbox")
        let args = arguments(inputName: source.path, subtitleName: subCopy.lastPathComponent, outputName: output.lastPathComponent, hardware: hardware)
        try await ctx.runProcess(ffmpeg, args, workingDirectory: dir, onStdoutLine: { line in
            guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)), let d = duration, d > 0 else { return }
            ctx.report(min(0.99, us / 1_000_000 / d), message: L("Drawing the subtitles…", "Вшивание субтитров…"))
        })
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.noOutput }
        return output
    }
}
