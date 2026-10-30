import Foundation

/// Parses the `-progress pipe:1` blocks of ffmpeg (`key=value` lines ending with `progress=continue|end`).
struct FFmpegProgressParser: Sendable {
    private(set) var outTime: Double?
    private(set) var speed: Double?

    /// Feeds one line. Returns true when a block ended (`progress=...`) and `outTime` / `speed` are current.
    mutating func feed(_ line: String) -> Bool {
        guard let eq = line.firstIndex(of: "=") else { return false }
        let key = line[line.startIndex..<eq]
        let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        switch key {
        case "out_time_us", "out_time_ms":
            // `out_time_ms` is also in microseconds in ffmpeg's progress output (a long-standing quirk).
            if let v = Double(value), v >= 0 { outTime = v / 1_000_000 }
        case "speed":
            let s = value.hasSuffix("x") ? String(value.dropLast()) : value
            if let v = Double(s.trimmingCharacters(in: .whitespaces)), v > 0 { speed = v }
        case "progress":
            return true
        default: break
        }
        return false
    }
}

enum FFmpegRunner {
    /// Runs the command through `ctx.runTool(.ffmpeg, ...)`: parses the progress blocks (`out_time_us`, `speed`, `progress=end`) into fractions of
    /// `totalDuration` (the expected duration of the OUTPUT; capped at 0.99 until the process exits), forwards them to `progress` / `ctx.report`,
    /// maps known stderr signatures to friendly errors and throws `CancellationError` after the process tree is killed.
    /// `range` places this run inside a larger piece of work: two-pass encodes call it twice with `0...0.4` and `0.4...1` (weights 40/60).
    /// ETA (from ffmpeg's `speed`) accounts for the passes that follow.
    static func run(_ command: FFmpegCommand, ctx: OperationContext, totalDuration: Double?, progress: ProgressSlice? = nil,
                    range: ClosedRange<Double> = 0...1) async throws {
        let parser = Locked(FFmpegProgressParser())
        let lastReported = Locked(-1.0)
        let stderr = Locked<[String]>([])
        let started = Date()
        let span = range.upperBound - range.lowerBound

        @Sendable func report(_ overall: Double?, eta: Double?) {
            if let progress { progress.report(overall ?? 0, eta: eta) } else { ctx.report(overall, eta: eta) }
        }
        let total = (totalDuration ?? 0) > 0.001 ? totalDuration : nil

        do {
            // Cancelling an encode discards its partial output anyway, so ffmpeg is killed at once (SIGKILL to its process group): a threaded x265 / SVT-AV1 run
            // would otherwise take its time to obey SIGTERM, and the budget for cancelling is 200 ms.
            try await ctx.runTool(.ffmpeg, command.arguments(), onStdoutLine: { line in
                let ended: Bool = parser.withLock { $0.feed(line) }
                guard ended else { return }
                let (time, speed) = parser.withLock { ($0.outTime, $0.speed) }
                guard let total, let time else { return }   // no known duration: stay indeterminate (the Job shows a spinner)
                let inner = min(time / total, 0.99)
                let overall = range.lowerBound + inner * span
                let fresh: Bool = lastReported.withLock { last in
                    if overall > last + 0.001 { last = overall; return true }
                    return false
                }
                guard fresh else { return }
                var eta: Double? = nil
                if let speed, speed > 0 {
                    let passRemaining = max(0, total - time) / speed
                    let passWall = total / speed
                    eta = passRemaining + (span > 0 ? (1 - range.upperBound) / span * passWall : 0)
                }
                report(overall, eta: eta)
            }, onStderrLine: { line in
                stderr.withLock { lines in
                    lines.append(line)
                    if lines.count > 200 { lines.removeFirst(lines.count - 200) }
                }
            }, killImmediately: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as ConversionError {
            throw friendlyError(e, stderr: stderr.value, command: command)
        }
        _ = started
        // The process has exited: only now may the run report its end of range.
        report(range.upperBound, eta: nil)
    }

    /// Maps stderr signatures to calm, localised errors (what happened, what to do). Unknown failures keep ConversionError.toolFailed.
    static func friendlyError(_ error: ConversionError, stderr: [String], command: FFmpegCommand) -> Error {
        guard case .toolFailed = error else { return error }
        let text = stderr.joined(separator: "\n").lowercased()
        func has(_ s: String) -> Bool { text.contains(s) }
        let audioOnly = command.outputs.first?.options.contains("-vn") ?? false
        if has("does not contain any stream") || has("matches no streams") {
            return audioOnly ? ConversionError.noAudioTrack
                : ConversionError.message(L10n("The file has nothing to write: none of the selected streams exist.", "В файле нет данных для записи: выбранных дорожек нет."))
        }
        if has("invalid data found when processing input") || has("moov atom not found") {
            return ConversionError.message(L10n("This file is damaged or is not a media file ffmpeg can read.", "Файл повреждён или не является медиафайлом, который умеет читать ffmpeg."))
        }
        if has("no such file or directory") || has("error opening input") {
            if let u = command.inputs.first?.url { return ConversionError.fileUnreadable(u) }
        }
        if has("unknown encoder") || (has("encoder") && has("not found")) {
            return ConversionError.unsupported(L10n("This ffmpeg build cannot write the chosen format. Pick another codec or install a full ffmpeg (Settings > Tools).",
                                                    "Эта сборка ffmpeg не умеет записывать выбранный формат. Выберите другой кодек или установите полный ffmpeg (Настройки > Инструменты)."))
        }
        if has("not divisible by 2") || has("width not divisible") || has("height not divisible") {
            return ConversionError.message(L10n("The picture size must be even for this codec. Use a size that is a multiple of 2.", "Для этого кодека размер кадра должен быть чётным. Выберите размер, кратный 2."))
        }
        if has("no space left on device") {
            return ConversionError.message(L10n("The disk is full. Free some space or choose another output folder.", "Диск заполнен. Освободите место или выберите другую папку для результата."))
        }
        if has("permission denied") || has("read-only file system") {
            if let u = command.outputs.first?.url { return ConversionError.outputNotWritable(u.deletingLastPathComponent()) }
        }
        if has("could not find tag for codec") || has("not currently supported in container") {
            return ConversionError.message(L10n("The chosen container cannot hold one of the streams. Pick MKV, or change the audio or subtitle settings.",
                                                "Выбранный контейнер не вмещает одну из дорожек. Выберите MKV или измените настройки звука или субтитров."))
        }
        if has("unrecognized option") {
            return ConversionError.message(L10n("The installed ffmpeg does not understand one of the options. Update ffmpeg or turn off the last option you changed.",
                                                "Установленный ffmpeg не понимает один из параметров. Обновите ffmpeg или отключите последний изменённый параметр."))
        }
        return error
    }
}
