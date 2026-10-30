import Foundation

// plan -> ffmpeg commands (one per pass). Streams are mapped explicitly (by container index) so cover art, attachments and data streams never
// sneak into the result; per-output-stream options use stream specifiers (`-c:a:0`). Table-driven golden tests assert on `arguments()`.

enum VideoFFmpegArgs {
    static func muxerName(_ container: String) -> String {
        switch container { case "mkv": return "matroska"; case "mp3": return "mp3"; default: return container }
    }

    /// plan -> one `FFmpegCommand` per pass (two-pass gives two). Writes helper files (rendered subtitle pictures, chapter list, converted
    /// external subtitles) into `tempDirectory`. Pass 1 of a two-pass plan writes to /dev/null with `-an`.
    static func commands(for plan: VideoEncodePlan, input: URL, output: URL, tempDirectory: URL) throws -> [FFmpegCommand] {
        let twoPass = plan.passes == 2 && plan.videoCodec != "copy"
        let passLog = tempDirectory.appendingPathComponent("pass").path
        var result: [FFmpegCommand] = []
        if twoPass {
            result.append(try buildCommand(plan, input: input, output: URL(fileURLWithPath: "/dev/null"), tempDirectory: tempDirectory, pass: (1, passLog)))
            result.append(try buildCommand(plan, input: input, output: output, tempDirectory: tempDirectory, pass: (2, passLog)))
        } else {
            result.append(try buildCommand(plan, input: input, output: output, tempDirectory: tempDirectory, pass: nil))
        }
        return result
    }

    // MARK: One command

    static func buildCommand(_ plan: VideoEncodePlan, input: URL, output: URL, tempDirectory: URL, pass: (Int, String)?) throws -> FFmpegCommand {
        var cmd = FFmpegCommand()
        let firstPass = pass?.0 == 1
        var inOpts: [String] = []
        if plan.noAutoRotate { inOpts.append("-noautorotate") }
        if plan.trimStart > 0.0005 { inOpts += ["-ss", ts(plan.trimStart)] }
        if let end = plan.trimEnd { inOpts += ["-t", ts(end - plan.trimStart)] }
        if let drc = plan.audioTracks.compactMap({ $0.drc }).first { inOpts += ["-drc_scale", VideoPlanner.num(drc)] }
        cmd.inputs = [FFmpegInput(url: input, options: inOpts)]

        var out: [String] = []
        var nextInput = 1
        func addInput(_ url: URL, _ opts: [String] = []) -> Int {
            cmd.inputs.append(FFmpegInput(url: url, options: opts)); defer { nextInput += 1 }; return nextInput
        }
        let fm = FileManager.default

        // --- Mapping: video
        let vidSpec = plan.sourceVideoStream.map { "0:\($0)" } ?? "0:v:0"
        var videoLabel: String? = nil
        if plan.noVideo {
            out.append("-vn")
        } else if !plan.overlays.isEmpty && plan.videoCodec != "copy" {
            videoLabel = "[vout]"
        } else {
            out += ["-map", vidSpec]
        }

        // --- Mapping: audio
        let audioActive = !firstPass && !plan.audioTracks.isEmpty && plan.container != "gif"
        if audioActive {
            for t in plan.audioTracks { out += ["-map", t.sourceStream >= 0 ? "0:\(t.sourceStream)" : "0:a:0?"] }
        } else {
            out.append("-an")
        }

        // --- Subtitles (source tracks, then external files)
        var subOrdinal = 0
        var subOptions: [String] = []
        if !firstPass && !plan.container.isEmpty && plan.container != "gif" && (!plan.subtitleTracks.isEmpty || !plan.externalSubtitles.isEmpty) {
            for s in plan.subtitleTracks {
                out += ["-map", "0:\(s.sourceStream)"]
                subOptions += ["-c:s:\(subOrdinal)", s.codec]
                if let l = s.language { subOptions += ["-metadata:s:s:\(subOrdinal)", "language=\(l)"] }
                subOptions += ["-disposition:s:\(subOrdinal)", s.isDefault ? "default" : (s.isForced ? "forced" : "0")]
                subOrdinal += 1
            }
            for (k, ext) in plan.externalSubtitles.enumerated() {
                let data = try Data(contentsOf: ext.file)
                let cues = VideoCueParser.parse(VideoCueParser.decode(data, charset: ext.charset))
                guard !cues.isEmpty else { throw ConversionError.message(L10n("The subtitle file has no readable text.", "В файле субтитров нет читаемого текста.")) }
                let srtURL = tempDirectory.appendingPathComponent("ext-sub-\(k).srt")
                try Data(VideoCueParser.srt(cues, offsetMs: ext.offsetMs).utf8).write(to: srtURL)
                let idx = addInput(srtURL)
                out += ["-map", "\(idx):0"]
                subOptions += ["-c:s:\(subOrdinal)", ext.codec]
                if let l = ext.language { subOptions += ["-metadata:s:s:\(subOrdinal)", "language=\(l)"] }
                subOrdinal += 1
            }
        } else {
            out.append("-sn")
        }

        // --- Chapters
        switch plan.chapters {
        case .keepSource: out += ["-map_chapters", plan.copyTrim || plan.trimStart > 0 ? "0" : "0"]
        case .none: out += ["-map_chapters", "-1"]
        case .custom(let list):
            let url = tempDirectory.appendingPathComponent("chapters.ffmeta")
            try Data(ffmetadata(list, duration: plan.outputDuration).utf8).write(to: url)
            let idx = addInput(url, ["-f", "ffmetadata"])
            out += ["-map_chapters", "\(idx)"]
        }

        // --- Metadata
        switch plan.metadata.mode {
        case "strip":
            out += ["-map_metadata", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
        default:
            out += ["-map_metadata", "0"]
            if plan.metadata.noGPS { out += ["-metadata", "location=", "-metadata", "location-eng="] }
            for (k, v) in plan.metadata.tags.sorted(by: { $0.key < $1.key }) { out += ["-metadata", "\(k)=\(v)"] }
            if !plan.metadata.keepCreationDate { out += ["-metadata", "creation_time=\(iso8601Now())"] }
        }

        // --- Cover art (the options that name the cover stream go AFTER the video codec options: the later `-c:v` would otherwise win)
        var coverOptions: [String] = []
        if let cover = plan.metadata.cover, fm.isReadableFile(atPath: cover.path), !firstPass {
            if plan.container == "mkv" {
                let mime = cover.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                out += ["-attach", cover.path, "-metadata:s:t:0", "mimetype=\(mime)", "-metadata:s:t:0", "filename=cover.\(cover.pathExtension.lowercased())"]
            } else {
                let idx = addInput(cover)
                out += ["-map", "\(idx):v:0"]
                coverOptions = ["-c:v:1", "mjpeg", "-pix_fmt:v:1", "yuvj420p", "-disposition:v:1", "attached_pic"]
            }
        }

        // --- Video codec options
        if !plan.noVideo {
            if plan.videoCodec == "copy" {
                out += ["-c:v", "copy"] + plan.encoderOptions
                if plan.copyTrim { out += ["-avoid_negative_ts", "make_zero"] }
            } else {
                out += plan.encoderOptions
                out += ["-fps_mode", plan.fpsMode]
                if plan.container == "gif" { out += ["-loop", gifLoop(plan.gif?.loop ?? "forever")] }
            }
        }
        out += coverOptions
        if let pass { out += ["-pass", "\(pass.0)", "-passlogfile", pass.1] }

        // --- Audio codec options (per output stream)
        if audioActive {
            for (i, t) in plan.audioTracks.enumerated() { out += audioOptions(t, ordinal: i, alignAV: plan.alignAV, container: plan.container) }
            if plan.audioTracks.contains(where: { $0.encoder == "vorbis" }) { out += ["-strict", "-2"] }
        }
        out += subOptions
        if plan.alignAV { out += ["-avoid_negative_ts", "make_zero"] }

        // --- Container
        if plan.movFlagsFaststart && !firstPass { out += ["-movflags", "+faststart"] }
        if plan.container == "mp3" { out += ["-id3v2_version", "3"] }
        out += ["-max_muxing_queue_size", "4096"]
        if firstPass { out += ["-f", "null"] } else { out += ["-f", muxerName(plan.container)] }

        // --- Filters
        if let label = videoLabel {
            let prepared = try VideoOverlayRenderer.prepare(plan.overlays, plan: plan, tempDirectory: tempDirectory)
            var graph = ""
            let postCount = plan.postOverlayFilterCount
            let pre = Array(plan.videoFilters.dropLast(postCount)), post = Array(plan.videoFilters.suffix(postCount))
            graph += "[\(vidSpec)]" + (pre.isEmpty ? "null" : pre.joined(separator: ",")) + "[v0]"
            var current = "v0"
            for (k, ov) in prepared.enumerated() {
                let idx = addInput(ov.input.url, ov.input.options)
                let next = k == prepared.count - 1 && post.isEmpty ? "vout" : "v\(k + 1)"
                graph += ";" + ov.stage(idx, current, next)
                current = next
            }
            if !post.isEmpty { graph += ";[\(current)]" + post.joined(separator: ",") + "[vout]" }
            else if prepared.isEmpty { graph = graph.replacingOccurrences(of: "[v0]", with: "[vout]") }
            cmd.filterComplex = graph
            out = ["-map", label] + out
        } else if !plan.noVideo && plan.videoCodec != "copy" {
            cmd.videoFilters = plan.videoFilters
        }
        cmd.outputs = [FFmpegOutput(url: output, options: out)]
        return cmd
    }

    // MARK: Pieces

    static func audioOptions(_ t: VideoAudioTrackPlan, ordinal i: Int, alignAV: Bool, container: String = "mkv") -> [String] {
        var a: [String] = ["-c:a:\(i)", t.encoder]
        if t.encoder != "copy" {
            if t.vbr, let q = t.quality {
                if t.encoder == "aac_at" { a += ["-aac_at_mode:a:\(i)", "vbr"] }
                a += ["-q:a:\(i)", "\(q)"]
            } else if let k = t.bitrateKbps {
                a += ["-b:a:\(i)", "\(k)k"]
            }
            if t.encoder == "libopus" { a += ["-vbr:a:\(i)", "on"] }
            if let c = t.channels { a += ["-ac:a:\(i)", "\(c)"] }
            if let r = t.sampleRate { a += ["-ar:a:\(i)", "\(r)"] }
            var filters = t.filters
            if t.matrixDPL2 { filters.insert("aresample=matrix_encoding=dplii", at: 0) }
            if alignAV { filters.insert("aresample=async=1:first_pts=0", at: 0) }
            if !filters.isEmpty { a += ["-filter:a:\(i)", filters.joined(separator: ",")] }
        }
        if let n = t.name {
            a += ["-metadata:s:a:\(i)", "title=\(n)"]
            // MP4 and MOV have no "title" for a track; the handler name is what players show.
            if container == "mp4" || container == "mov" { a += ["-metadata:s:a:\(i)", "handler_name=\(n)"] }
        }
        if let l = t.language { a += ["-metadata:s:a:\(i)", "language=\(l)"] }
        return a
    }

    static func gifLoop(_ s: String) -> String {
        switch s {
        case "forever": return "0"
        case "once": return "-1"
        default: if let n = Int(s), n >= 2 { return "\(n - 1)" } else { return "0" }
        }
    }

    /// Seconds for `-ss` / `-t` (milliseconds precision, no exponent).
    static func ts(_ t: Double) -> String {
        var s = String(format: "%.3f", max(0, t))
        while s.hasSuffix("0") && s.contains(".") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }

    static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// FFMETADATA1 chapter list (milliseconds timebase); `=`, `;`, `#`, `\` and newlines in titles are escaped.
    static func ffmetadata(_ chapters: [VideoChapter], duration: Double?) -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for ch in s { if "=;#\\\n".contains(ch) { o.append("\\") }; o.append(ch) }
            return o
        }
        var s = ";FFMETADATA1\n"
        for (i, c) in chapters.enumerated() {
            let start = Int((c.start * 1000).rounded())
            let end = i + 1 < chapters.count ? Int((chapters[i + 1].start * 1000).rounded()) : Int(((duration ?? (c.start + 1)) * 1000).rounded())
            s += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(start)\nEND=\(max(end, start + 1))\ntitle=\(esc(c.title))\n"
        }
        return s
    }
}
