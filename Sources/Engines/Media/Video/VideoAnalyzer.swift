import Foundation

// The cheap analysis passes that run BEFORE planning (spec/handbrake.md 5.2 step 2): crop detection, interlace detection, the first pass of the
// two-pass loudness normalisation, the cues of the subtitle track to burn in, the key frame before a fast cut. Each pass is a short ffmpeg run
// (a few seconds of media at most) through `ctx.runTool`, so it is cancellable and shares the job's pause/cancel handling.

enum VideoAnalyzer {
    // MARK: Parsing (pure, unit-tested with fixtures)

    /// `crop=1920:800:0:140` -> a crop; the LAST line of a window is the settled value.
    static func parseCrop(_ line: String) -> VideoPicturePlan.Crop? {
        guard let r = line.range(of: #"crop=(\d+):(\d+):(\d+):(\d+)"#, options: .regularExpression) else { return nil }
        let nums = line[r].dropFirst(5).split(separator: ":").compactMap { Int($0) }
        guard nums.count == 4 else { return nil }
        return .init(x: nums[2], y: nums[3], w: nums[0], h: nums[1])
    }

    /// Union of the windows' crops (the most conservative crop = the largest picture area seen), rounded to even numbers.
    /// Windows that look like black frames (less than a quarter of the picture) are ignored. Nil when there is nothing to remove.
    static func mergeCrops(_ crops: [VideoPicturePlan.Crop], frame: (w: Int, h: Int)?) -> VideoPicturePlan.Crop? {
        let usable = crops.filter { c in
            guard c.w >= 16, c.h >= 16 else { return false }
            if let f = frame { return c.w * c.h * 4 >= f.w * f.h }
            return true
        }
        guard !usable.isEmpty else { return nil }
        let x0 = usable.map(\.x).min()!, y0 = usable.map(\.y).min()!
        let x1 = usable.map { $0.x + $0.w }.max()!, y1 = usable.map { $0.y + $0.h }.max()!
        let x = (x0 / 2) * 2, y = (y0 / 2) * 2
        let w = ((x1 - x) / 2) * 2, h = ((y1 - y) / 2) * 2
        if let f = frame {
            // Less than 4 pixels of bars in total is noise, not a letterbox.
            if f.w - w + (f.h - h) < 4 { return nil }
            if w > f.w || h > f.h { return nil }
        }
        return .init(x: x, y: y, w: w, h: h)
    }

    /// "Multi frame detection: TFF: 0 BFF: 0 Progressive: 198 Undetermined: 2" -> verdict (spec: interlaced if (TFF + BFF) / frames > 0.1).
    static func parseIdet(_ lines: [String]) -> Bool? {
        for line in lines.reversed() where line.contains("Multi frame detection") {
            func n(_ key: String) -> Int {
                guard let r = line.range(of: "\(key):\\s*(\\d+)", options: .regularExpression) else { return 0 }
                return Int(line[r].split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            }
            let tff = n("TFF"), bff = n("BFF"), prog = n("Progressive")
            let total = tff + bff + prog
            guard total >= 20 else { return nil }
            return Double(tff + bff) / Double(total) > 0.1
        }
        return nil
    }

    /// The JSON block loudnorm prints on stderr after `print_format=json`.
    static func parseLoudnorm(_ lines: [String]) -> LoudnessMeasurement? {
        let text = lines.joined(separator: "\n")
        guard let open = text.range(of: "{", options: .backwards), let close = text.range(of: "}", options: .backwards), open.lowerBound < close.upperBound else { return nil }
        // The JSON begins at the last "{" that belongs to the loudnorm summary (it has no nested objects).
        guard let data = String(text[open.lowerBound..<close.upperBound]).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func v(_ k: String) -> Double? { (j[k] as? String).flatMap(Double.init) ?? (j[k] as? Double) }
        guard let i = v("input_i"), let tp = v("input_tp"), let lra = v("input_lra"), let th = v("input_thresh"), let off = v("target_offset"),
              i.isFinite, i > -70 else { return nil }
        return LoudnessMeasurement(inputI: i, inputTP: tp, inputLRA: lra, inputThresh: th, targetOffset: off)
    }

    // MARK: Running

    static var ffmpegArgsPrefix: [String] { ["-hide_banner", "-nostdin", "-v", "info"] }

    /// Positions (seconds) of the sample windows: 10% ... 90% of the clip, or the start of a very short one.
    static func windows(duration: Double?, count: Int) -> [Double] {
        guard let d = duration, d > 6 else { return [0] }
        return (0..<count).map { i in d * (0.1 + 0.8 * Double(i) / Double(max(count - 1, 1))) }
    }

    static func detectCrop(url: URL, frame: (w: Int, h: Int)?, duration: Double?, ctx: OperationContext) async throws -> VideoPicturePlan.Crop? {
        var found: [VideoPicturePlan.Crop] = []
        for t in windows(duration: duration, count: 5) {
            try ctx.checkCancelled()
            let last = Locked<VideoPicturePlan.Crop?>(nil)
            let args = ffmpegArgsPrefix + ["-ss", VideoFFmpegArgs.ts(t), "-t", "1.5", "-i", FFmpegCommand.safePath(url), "-vf", "cropdetect=limit=24:round=2:reset=0",
                                           "-an", "-sn", "-dn", "-f", "null", "-"]
            try await ctx.runTool(.ffmpeg, args, onStdoutLine: { _ in }, onStderrLine: { line in
                if let c = parseCrop(line) { last.value = c }
            }, allowNonZeroExit: true)
            if let c = last.value { found.append(c) }
        }
        return mergeCrops(found, frame: frame)
    }

    static func detectInterlace(url: URL, duration: Double?, ctx: OperationContext) async throws -> Bool? {
        let start = (duration ?? 0) > 20 ? min((duration ?? 0) * 0.1, 60) : 0
        let lines = Locked<[String]>([])
        let args = ffmpegArgsPrefix + ["-ss", VideoFFmpegArgs.ts(start), "-i", FFmpegCommand.safePath(url), "-frames:v", "200", "-vf", "idet", "-an", "-sn", "-dn", "-f", "null", "-"]
        try await ctx.runTool(.ffmpeg, args, onStdoutLine: { _ in }, onStderrLine: { line in
            if line.contains("Multi frame detection") { lines.withLock { $0.append(line) } }
        }, allowNonZeroExit: true)
        return parseIdet(lines.value)
    }

    /// First pass of the two-pass loudness normalisation: the stream is measured through the same filters that precede `loudnorm` in the real run.
    static func measureLoudness(url: URL, streamIndex: Int, preFilters: [String], target: Double, trimStart: Double, trimEnd: Double?, ctx: OperationContext) async throws -> LoudnessMeasurement? {
        let lines = Locked<[String]>([])
        var inOpts: [String] = []
        if trimStart > 0.0005 { inOpts += ["-ss", VideoFFmpegArgs.ts(trimStart)] }
        if let e = trimEnd { inOpts += ["-t", VideoFFmpegArgs.ts(e - trimStart)] }
        let chain = (preFilters + ["loudnorm=I=\(VideoPlanner.num(target)):TP=-1.5:LRA=11:print_format=json"]).joined(separator: ",")
        let args = ffmpegArgsPrefix + inOpts + ["-i", FFmpegCommand.safePath(url), "-map", streamIndex >= 0 ? "0:\(streamIndex)" : "0:a:0", "-vn", "-sn", "-dn", "-af", chain, "-f", "null", "-"]
        try await ctx.runTool(.ffmpeg, args, onStdoutLine: { _ in }, onStderrLine: { line in lines.withLock { $0.append(line) } }, allowNonZeroExit: true)
        return parseLoudnorm(lines.value)
    }

    /// Cues of the subtitle track to burn in (source time), extracted to SRT by ffmpeg and parsed here.
    static func extractCues(url: URL, streamIndex: Int, ctx: OperationContext) async throws -> [VideoCue] {
        let out = ctx.tempDir.appendingPathComponent("burn-\(Util.hex8()).srt")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = ["-hide_banner", "-nostdin", "-y", "-i", FFmpegCommand.safePath(url), "-map", "0:\(streamIndex)", "-f", "srt", out.path]
        try await ctx.runTool(.ffmpeg, args, onStdoutLine: { _ in }, allowNonZeroExit: true)
        guard let data = try? Data(contentsOf: out), !data.isEmpty else { return [] }
        return VideoCueParser.parse(VideoCueParser.decode(data, charset: "utf-8"))
    }

    /// The time of the key frame a fast (stream-copy) cut starting at `start` really begins with: the last one at or before `start`.
    static func keyframe(atOrBefore start: Double, url: URL, ctx: OperationContext) async -> Double? {
        guard let probe = ctx.tools.url(.ffprobe), start > 0.001 else { return nil }
        let from = max(0, start - 120)
        let args = ["-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey", "-show_entries", "frame=pts_time", "-of", "csv=p=0",
                    "-read_intervals", "\(VideoFFmpegArgs.ts(from))%\(VideoFFmpegArgs.ts(start + 0.02))", "-i", FFmpegCommand.safePath(url)]
        guard let out = try? await ProcessRunner.run(probe, args, captureStdout: true, toolName: "ffprobe", allowNonZeroExit: true) else { return nil }
        let times = out.stdout.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ","))) }
        return times.filter { $0 <= start + 0.02 }.max()
    }

    // MARK: Orchestration

    /// Runs the analyses the options ask for. Every failure degrades to "no analysis" (the planner works without them).
    static func run(_ r: ResolvedOptions, info: MediaInfo, toolset: MediaToolset, ctx: OperationContext) async throws -> VideoAnalysis {
        var an = VideoAnalysis()
        guard toolset.hasFFmpeg else { return an }
        let o = VOpts(r)
        let isCopy = o.s(VideoKeys.vcodec) == "copy"
        let sv = info.primaryVideo
        let display = sv?.displaySize.map { (w: $0.width, h: $0.height) }
        if sv != nil, !isCopy {
            if o.s(VideoKeys.cropMode) == "auto" {
                an.crop = try await detectCrop(url: info.url, frame: display, duration: info.duration, ctx: ctx)
            }
            if o.s(VideoKeys.deinterlace) == "auto", sv?.interlaced != true, sv?.fieldOrder != "progressive" {
                an.interlaced = try await detectInterlace(url: info.url, duration: info.duration, ctx: ctx)
            }
            if o.s(VideoKeys.sizeMode) == "fill", o.s(VideoKeys.sizeAnchor) == "smart" {
                an.subjectCenter = await VideoSubjectFinder.center(url: info.url, duration: info.duration)
            }
        }
        if o.s(VideoKeys.subMode) == "burn", o.s(VideoKeys.extFile).isEmpty, !isCopy {
            let texts = info.subtitleStreams.filter { !$0.isBitmapSubtitle }
            let pick = Int(o.s(VideoKeys.burnTrack))
            let stream = pick.flatMap { texts.indices.contains($0) ? texts[$0] : nil } ?? texts.first
            if let s = stream { an.burnCues = try await extractCues(url: info.url, streamIndex: s.index, ctx: ctx) }
        }
        return an
    }
}
