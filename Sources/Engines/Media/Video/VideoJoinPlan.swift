import Foundation

// Joining videos (video.concat). Pure planning and argv building, testable without encoding.
//
// Two routes:
//   * stream copy through ffmpeg's concat DEMUXER, only when every clip has exactly the same streams (codec, profile, size, rotation, pixel format,
//     frame rate, and the same audio codec / rate / channels) and the target container can hold them: nothing is decoded, nothing is lost;
//   * re-encode through the concat FILTER, when the clips differ (or the container changes the codecs): every picture is fitted into one common size
//     (letterboxed, never stretched), one frame rate and one pixel format; every sound is brought to one sample rate and channel layout, and a clip
//     without sound gets silence of its own length, so picture and sound stay in step.

enum VideoJoinKeys {
    static let container = "join.container"        // same, mp4, mov, mkv, webm
    static let quality = "join.cq"                 // CRF of the re-encode (lower = better)
    static let normalise = "join.normalise"        // fit differing clips to one format (on) or refuse them (off)
    static let match = "join.match"                // best (largest picture, highest rate) or first (the first clip decides)
    static let order = "join.order"                // natural or selection
    static let keepMeta = "join.keepMeta"          // tags of the first clip travel to the result
}

struct VideoJoinClip: Sendable {
    var url: URL
    var info: MediaInfo
    var name: String { url.lastPathComponent }
}

/// What makes two clips "the same stream" for a lossless join.
struct VideoJoinSignature: Equatable, Sendable {
    var codec: String
    var profile: String
    var width: Int
    var height: Int
    var rotation: Int
    var sar: Int            // sample aspect ratio x 1000
    var pixelFormat: String
    var fps100: Int         // frame rate x 100
    var audioCodec: String  // "" = no sound
    var audioRate: Int
    var audioChannels: Int

    init?(_ info: MediaInfo) {
        guard let v = info.primaryVideo else { return nil }
        codec = v.codec; profile = v.profile ?? ""
        width = v.width ?? 0; height = v.height ?? 0; rotation = v.rotation
        sar = Int((v.sar * 1000).rounded()); pixelFormat = v.pixelFormat ?? ""
        fps100 = Int(((v.fps ?? 0) * 100).rounded())
        if let a = info.audioStreams.first { audioCodec = a.codec; audioRate = a.sampleRate ?? 0; audioChannels = a.channels ?? 0 }
        else { audioCodec = ""; audioRate = 0; audioChannels = 0 }
    }

    /// The first difference, in words (for the "clips differ" message and the plan note); nil when equal.
    func difference(from o: VideoJoinSignature) -> L10n? {
        if codec != o.codec || profile != o.profile { return L10n("different video codecs", "разные видеокодеки") }
        if width != o.width || height != o.height || rotation != o.rotation || sar != o.sar { return L10n("different picture sizes", "разные размеры кадра") }
        if fps100 != o.fps100 { return L10n("different frame rates", "разная частота кадров") }
        if pixelFormat != o.pixelFormat { return L10n("different pixel formats", "разные форматы пикселей") }
        if audioCodec.isEmpty != o.audioCodec.isEmpty { return L10n("some clips have no sound", "у части роликов нет звука") }
        if audioCodec != o.audioCodec || audioRate != o.audioRate || audioChannels != o.audioChannels { return L10n("different sound formats", "разные форматы звука") }
        return nil
    }
}

struct VideoJoinPlan: Sendable {
    enum Route: String, Sendable { case copy, reencode }
    var route: Route
    var container: String
    var width = 0, height = 0
    /// ffmpeg frame rate as a rational or decimal ("30000/1001", "25").
    var fps = "30"
    var hasAudio = false
    var audioRate = 48_000
    var audioChannels = 2
    var videoEncoder = "libx264"
    var audioEncoder = "aac"
    var crf = 21
    var totalDuration = 0.0
    var clips: [VideoJoinClip] = []
    var notes: [L10n] = []
}

enum VideoJoinPlanner {
    static let containers: Set<String> = ["mp4", "mov", "mkv", "webm"]

    /// Natural path order (clip2 before clip10) or the order given.
    static func ordered(_ items: [FileItem], natural: Bool) -> [FileItem] {
        natural ? items.sorted { Util.naturalCompare($0.url.path, $1.url.path) == .orderedAscending } : items
    }

    static func targetContainer(choice: String, firstKey: String) -> String {
        if containers.contains(choice) { return choice }
        if containers.contains(firstKey) { return firstKey }
        return "mp4"   // m4v, 3gp, avi, flv ... become MP4
    }

    static func plan(clips: [VideoJoinClip], options o: OptionValues, toolset: MediaToolset) throws -> VideoJoinPlan {
        guard clips.count >= 2 else {
            throw ConversionError.message(L10n("Joining needs at least two videos.", "Для объединения нужно хотя бы два видео."))
        }
        for c in clips where c.info.primaryVideo == nil {
            throw ConversionError.message(L10n("\(c.name) has no picture, so it cannot be joined.", "В файле \(c.name) нет изображения, его нельзя объединить."))
        }
        let container = targetContainer(choice: o.string(VideoJoinKeys.container, "same"), firstKey: Formats.key(of: clips[0].url))
        var plan = VideoJoinPlan(route: .reencode, container: container)
        plan.clips = clips
        plan.totalDuration = clips.reduce(0) { $0 + ($1.info.duration ?? 0) }
        plan.crf = max(0, min(51, o.int(VideoJoinKeys.quality, 21)))
        let sigs = clips.compactMap { VideoJoinSignature($0.info) }
        let firstDiff = sigs.dropFirst().compactMap { $0.difference(from: sigs[0]) }.first
        let v0 = sigs[0]
        let audioCodecOK = v0.audioCodec.isEmpty || MediaCapabilities.containerSupports(container, audioCodec: v0.audioCodec)
        let canCopy = firstDiff == nil && MediaCapabilities.containerSupports(container, videoCodec: v0.codec) && audioCodecOK
            && !(v0.codec == "hevc" && container == "webm")
        let normalise = o.bool(VideoJoinKeys.normalise, true)
        if clips.contains(where: { !$0.info.subtitleStreams.isEmpty }) {
            plan.notes.append(L10n("Subtitles are not carried into a joined video.", "Субтитры в объединённое видео не переносятся."))
        }
        if clips.contains(where: { $0.info.primaryVideo?.isHDR == true }) {
            plan.notes.append(L10n("HDR clips are joined as standard dynamic range.", "HDR-ролики объединены как обычное видео (SDR)."))
        }
        if canCopy {
            plan.route = .copy
            plan.hasAudio = !v0.audioCodec.isEmpty
            return plan
        }
        guard normalise else {
            let why = firstDiff ?? L10n("the container cannot hold these streams", "контейнер не вмещает эти дорожки")
            throw ConversionError.message(L10n("The videos cannot be joined as they are (\(why.en)). Turn on “Match the clips” to fit them to one format.",
                                               "Видео нельзя объединить как есть (\(why.ru)). Включите «Привести ролики к одному формату»."))
        }
        if let d = firstDiff { plan.notes.append(L10n("The videos differ (\(d.en)), so they were fitted to one format.", "Ролики различаются (\(d.ru)), поэтому они приведены к одному формату.")) }
        else { plan.notes.append(L10n("The container \(container.uppercased()) cannot hold the original streams, so the video was re-encoded.", "Контейнер \(container.uppercased()) не вмещает исходные дорожки, поэтому видео перекодировано.")) }

        // Common picture: the largest clip (or the first), even sides; the highest frame rate (or the first clip's).
        let first = o.string(VideoJoinKeys.match, "best") == "first"
        let sizes = clips.map { $0.info.primaryVideo?.displaySize ?? (640, 360) }
        let fpsList = clips.map { $0.info.primaryVideo?.fps ?? 30 }
        var size = sizes[0]
        if !first, let big = sizes.max(by: { $0.0 * $0.1 < $1.0 * $1.1 }) { size = big }
        plan.width = max(2, size.0 & ~1); plan.height = max(2, size.1 & ~1)
        let rate = first ? fpsList[0] : (fpsList.max() ?? 30)
        plan.fps = fpsString(rate.isFinite && rate > 1 ? min(rate, 120) : 30)
        // Common sound: the highest rate, stereo when any clip has two channels or more; silence for clips without sound.
        let audio = clips.flatMap { $0.info.audioStreams.prefix(1) }
        plan.hasAudio = !audio.isEmpty
        if plan.hasAudio {
            plan.audioRate = container == "webm" ? 48_000 : max(8_000, audio.compactMap(\.sampleRate).max() ?? 48_000)
            plan.audioChannels = audio.contains { ($0.channels ?? 1) >= 2 } ? 2 : 1
            if clips.contains(where: { $0.info.audioStreams.isEmpty }) {
                plan.notes.append(L10n("Clips without sound got silence, so picture and sound stay in step.", "Роликам без звука добавлена тишина, чтобы картинка и звук не расходились."))
            }
        }
        // Encoders.
        if container == "webm" {
            guard toolset.hasEncoder("libvpx-vp9"), toolset.hasEncoder("libopus") else {
                throw ConversionError.unsupported(L10n("This ffmpeg cannot write WebM (VP9 and Opus). Choose MP4 or MKV.", "Этот ffmpeg не умеет писать WebM (VP9 и Opus). Выберите MP4 или MKV."))
            }
            plan.videoEncoder = "libvpx-vp9"; plan.audioEncoder = "libopus"
        } else if toolset.hasEncoder("libx264") {
            plan.videoEncoder = "libx264"; plan.audioEncoder = "aac"
        } else if toolset.hasEncoder("h264_videotoolbox") {
            plan.videoEncoder = "h264_videotoolbox"; plan.audioEncoder = "aac"
        } else {
            throw ConversionError.unsupported(L10n("This ffmpeg has no H.264 encoder. Install a full ffmpeg (Settings > Tools).", "В этом ffmpeg нет кодировщика H.264. Установите полный ffmpeg (Настройки > Инструменты)."))
        }
        return plan
    }

    static func fpsString(_ f: Double) -> String {
        for (n, d) in [(24_000, 1001), (30_000, 1001), (60_000, 1001), (120_000, 1001)] where abs(f - Double(n) / Double(d)) < 0.01 { return "\(n)/\(d)" }
        let r = (f * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}

enum VideoJoinArgs {
    /// The one command of a plan. `tempDirectory` receives the concat list of the copy route.
    static func command(_ plan: VideoJoinPlan, output: URL, tempDirectory: URL, keepMeta: Bool) throws -> FFmpegCommand {
        var cmd = FFmpegCommand()
        var out: [String] = []
        switch plan.route {
        case .copy:
            let list = tempDirectory.appendingPathComponent("clips.txt")
            let text = try plan.clips.map { c -> String in
                guard !c.url.path.contains("\n") else { throw ConversionError.fileUnreadable(c.url) }
                return "file '" + c.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: list)
            cmd.inputs = [FFmpegInput(url: list, options: ["-f", "concat", "-safe", "0"])]
            out += ["-map", "0:v:0"]
            if plan.hasAudio { out += ["-map", "0:a:0"] }
            out += ["-sn", "-dn", "-c", "copy", "-map_chapters", "-1"]
            if keepMeta { cmd.inputs.append(FFmpegInput(url: plan.clips[0].url)); out += ["-map_metadata", "1"] } else { out += ["-map_metadata", "-1"] }
            out += ["-avoid_negative_ts", "make_zero"]
        case .reencode:
            cmd.inputs = plan.clips.map { FFmpegInput(url: $0.url) }
            cmd.filterComplex = filterGraph(plan)
            out += ["-map", "[v]"]
            if plan.hasAudio { out += ["-map", "[a]"] }
            out += ["-sn", "-dn", "-map_chapters", "-1"]
            out += keepMeta ? ["-map_metadata", "0"] : ["-map_metadata", "-1"]
            out += videoOptions(plan)
            if plan.hasAudio { out += audioOptions(plan) }
        }
        if plan.container == "mp4" || plan.container == "mov" { out += ["-movflags", "+faststart"] }
        out += ["-max_muxing_queue_size", "4096", "-f", VideoFFmpegArgs.muxerName(plan.container)]
        cmd.outputs = [FFmpegOutput(url: output, options: out)]
        return cmd
    }

    /// `[0:v]...[v0];[0:a]...[a0];...;[v0][a0][v1][a1]concat=n=N:v=1:a=1[v][a]`
    static func filterGraph(_ plan: VideoJoinPlan) -> String {
        let w = plan.width, h = plan.height
        var parts: [String] = []
        var joined = ""
        for (i, c) in plan.clips.enumerated() {
            parts.append("[\(i):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease:flags=bicubic,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=\(plan.fps),format=yuv420p[v\(i)]")
            joined += "[v\(i)]"
            guard plan.hasAudio else { continue }
            let layout = plan.audioChannels == 1 ? "mono" : "stereo"
            let fmt = "aformat=sample_fmts=fltp:sample_rates=\(plan.audioRate):channel_layouts=\(layout)"
            if c.info.audioStreams.isEmpty {
                let d = String(format: "%.3f", max(0.04, c.info.duration ?? 1))
                parts.append("anullsrc=channel_layout=\(layout):sample_rate=\(plan.audioRate):duration=\(d),\(fmt)[a\(i)]")
            } else {
                parts.append("[\(i):a:0]aresample=\(plan.audioRate),\(fmt)[a\(i)]")
            }
            joined += "[a\(i)]"
        }
        parts.append("\(joined)concat=n=\(plan.clips.count):v=1:a=\(plan.hasAudio ? 1 : 0)\(plan.hasAudio ? "[v][a]" : "[v]")")
        return parts.joined(separator: ";")
    }

    static func videoOptions(_ plan: VideoJoinPlan) -> [String] {
        switch plan.videoEncoder {
        case "libvpx-vp9":
            return ["-c:v", "libvpx-vp9", "-crf", "\(plan.crf)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
        case "h264_videotoolbox":
            let q = max(1, min(100, 100 - (plan.crf - 8) * 3))
            return ["-c:v", "h264_videotoolbox", "-q:v", "\(q)", "-allow_sw", "1", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
        default:
            return ["-c:v", "libx264", "-preset", "medium", "-crf", "\(plan.crf)", "-profile:v", "high", "-pix_fmt", "yuv420p"]
        }
    }

    static func audioOptions(_ plan: VideoJoinPlan) -> [String] {
        let kbps = plan.audioEncoder == "libopus" ? 128 : (plan.audioChannels == 1 ? 96 : 160)
        return ["-c:a", plan.audioEncoder, "-b:a", "\(kbps)k", "-ar", "\(plan.audioRate)", "-ac", "\(plan.audioChannels)"]
    }
}
