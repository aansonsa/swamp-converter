import Foundation
import AVFoundation

// video.concat: planner (pure), argv, and real joins read back with ffprobe / ffmpeg and AVFoundation. Suite "video".
// Fixtures are flat-colour clips (red, green, blue ...) of different sizes, rates and sound, so the ORDER of the result can be read from its pixels.

enum VideoJoinTests {
    typealias R = VideoRealTests

    /// A flat-colour clip with a sine tone (or none).
    @MainActor
    static func clip(_ name: String, color: String, size: String = "320x240", fps: Int = 24, seconds: Double = 1, audio: Bool = true, tone: Int = 440, rate: Int = 48_000,
                     title: String? = nil, extra: [String] = []) throws -> URL {
        var args = ["-f", "lavfi", "-i", "color=c=\(color):s=\(size):r=\(fps):d=\(seconds)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=\(tone):sample_rate=\(rate):duration=\(seconds)"] }
        args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p"]
        args += audio ? ["-c:a", "aac", "-b:a", "96k", "-shortest"] : ["-an"]
        if let title { args += ["-metadata", "title=\(title)"] }
        return try VT.make(VTShared.fx, name, args + extra)
    }

    struct Run { var url: URL; var result: OperationResult; var log: [String]; var progress: [Double] }

    @MainActor
    static func operation() throws -> Operation {
        guard let o = VideoCatalog.operations().first(where: { $0.meta.id == "video.concat" }) else { throw TestFailure(message: "video.concat is not registered", file: #fileID, line: #line) }
        return o
    }

    @MainActor
    static func join(_ inputs: [URL], _ set: OptionValues = [:]) async throws -> Run {
        let op = try operation()
        let items = inputs.map { FileItem(url: $0) }
        let ctx = OperationContext.testing(op, items: items, extra: set, mode: .studio, rules: VT.outRules())
        let log = Locked<[String]>([]), progress = Locked<[Double]>([])
        ctx.onLog = { line in log.withLock { $0.append(line) } }
        ctx.onProgress = { p, _, _ in if let p { progress.withLock { $0.append(p) } } }
        defer { ctx.cleanupTemp() }
        let r = try await op.execute(items: items, ctx: ctx)
        guard let u = r.outputs.first else { throw TestFailure(message: "video.concat produced no output", file: #fileID, line: #line) }
        return Run(url: u, result: r, log: log.value, progress: progress.value)
    }

    /// The colour at the centre of the picture at `t`.
    static func colour(_ url: URL, at t: Double) throws -> String {
        let f = try VT.frame(url, at: t)
        return VT.quadrantColor(f.pixel(f.w / 2, f.h / 2))
    }

    /// MD5 of every decoded frame (ffmpeg framemd5): equal lists mean identical pictures.
    static func frameHashes(_ url: URL) -> [String] {
        guard let ff = VT.ffmpeg else { return [] }
        let text = VT.run(ff, ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:v:0", "-f", "framemd5", "-"])
        return text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    static func info(_ ac: [(codec: String, ch: Int, lang: String?)] = [("aac", 2, nil)], w: Int = 1920, h: Int = 1080, fps: Double = 30, video: String = "h264") -> MediaInfo {
        VTPlan.info(video: video, w: w, h: h, fps: fps, duration: 10, audio: ac)
    }

    static func clips(_ infos: [MediaInfo], names: [String]? = nil) -> [VideoJoinClip] {
        infos.enumerated().map { i, m in VideoJoinClip(url: URL(fileURLWithPath: "/tmp/\(names?[i] ?? "c\(i + 1).mp4")"), info: m) }
    }

    static func register() {
        let ts = MediaToolset(hasFFmpeg: true, hasFFprobe: true, encoders: ["libx264", "aac", "libvpx-vp9", "libopus", "h264_videotoolbox"])

        SelfTestRegistry.shared.register("video", "video.concat is on the Tools wheel for two or more videos only, and its Studio schema names an oracle per field") {
            let reg = OperationRegistry()
            reg.register(VideoCatalog.operations())
            let a = FileItem(url: URL(fileURLWithPath: "/tmp/a.mp4")), b = FileItem(url: URL(fileURLWithPath: "/tmp/b.mov")), c = FileItem(url: URL(fileURLWithPath: "/tmp/c.txt"))
            try expect(!reg.entries(wheel: .tools, items: [a]).map(\.id).contains("video.concat"), "one video: no Join")
            try expect(reg.entries(wheel: .tools, items: [a, b]).map(\.id).contains("video.concat"), "two videos: Join")
            try expect(!reg.entries(wheel: .tools, items: [a, c]).map(\.id).contains("video.concat"), "a video and a text file: no Join")
            let op = try unwrap(reg.operation(id: "video.concat"))
            try expectEqual(op.meta.minItems, 2); try expectEqual(op.meta.suffix?.en, "joined"); try expectEqual(op.meta.suffix?.ru, "объединено")
            try expectEqual(op.meta.requires, [.ffmpeg]); try expectEqual(op.meta.concurrency, .video)
            let fields = op.optionSchema(for: []).allFields
            try expect(fields.count >= 5 && fields.allSatisfy { !$0.oracle.isEmpty }, "every field names an oracle")
        }

        SelfTestRegistry.shared.register("video", "join planning: identical clips are copied, differing clips are fitted, refusing to fit is an honest error") {
            let same = try VideoJoinPlanner.plan(clips: clips([info(), info(), info()]), options: [:], toolset: ts)
            try expectEqual(same.route, .copy); try expect(same.hasAudio, "audio kept"); try expectEqual(same.container, "mp4")
            for diff in [info(w: 1280, h: 720), info(fps: 25), info([("aac", 1, nil)]), info(video: "hevc"), info([])] {
                let p = try VideoJoinPlanner.plan(clips: clips([info(), diff]), options: [:], toolset: ts)
                try expectEqual(p.route, .reencode, "a clip that differs forces the fitting route")
                try expect(!p.notes.isEmpty, "the person is told")
            }
            let p = try VideoJoinPlanner.plan(clips: clips([info(w: 1280, h: 720, fps: 24), info(w: 1920, h: 1080, fps: 30), info(w: 640, h: 360, fps: 25)]), options: [:], toolset: ts)
            try expect(p.width == 1920 && p.height == 1080 && p.fps == "30", "the largest picture and the highest rate: \(p.width)x\(p.height) \(p.fps)")
            let f = try VideoJoinPlanner.plan(clips: clips([info(w: 1280, h: 720, fps: 24), info(w: 1920, h: 1080, fps: 30)]), options: [VideoJoinKeys.match: "first"], toolset: ts)
            try expect(f.width == 1280 && f.height == 720 && f.fps == "24", "the first clip decides: \(f.width)x\(f.height) \(f.fps)")
            let ntsc = try VideoJoinPlanner.plan(clips: clips([info(fps: 29.97), info(fps: 25)]), options: [:], toolset: ts)
            try expectEqual(ntsc.fps, "30000/1001")
            do { _ = try VideoJoinPlanner.plan(clips: clips([info(), info(w: 640, h: 360)]), options: [VideoJoinKeys.normalise: false], toolset: ts); throw TestFailure(message: "must refuse", file: #fileID, line: #line) }
            catch let e as ConversionError { try expect(ConversionError.describe(e).contains("picture sizes"), ConversionError.describe(e)) }
            do { _ = try VideoJoinPlanner.plan(clips: clips([info()]), options: [:], toolset: ts); throw TestFailure(message: "must refuse one clip", file: #fileID, line: #line) } catch is ConversionError {}
            // Containers: legacy ones become MP4; WebM never copies H.264; a missing x264 falls back to VideoToolbox; nothing at all is an honest error.
            try expectEqual(try VideoJoinPlanner.plan(clips: clips([info(), info()], names: ["a.avi", "b.avi"]), options: [:], toolset: ts).container, "mp4")
            try expectEqual(try VideoJoinPlanner.plan(clips: clips([info(), info()], names: ["a.mkv", "b.mkv"]), options: [:], toolset: ts).container, "mkv")
            let web = try VideoJoinPlanner.plan(clips: clips([info(), info()]), options: [VideoJoinKeys.container: "webm"], toolset: ts)
            try expect(web.route == .reencode && web.videoEncoder == "libvpx-vp9" && web.audioEncoder == "libopus" && web.audioRate == 48_000, "WebM: VP9 + Opus")
            var vt = ts; vt.encoders.remove("libx264")
            try expectEqual(try VideoJoinPlanner.plan(clips: clips([info(), info(w: 640, h: 360)]), options: [:], toolset: vt).videoEncoder, "h264_videotoolbox")
            vt.encoders.remove("h264_videotoolbox")
            do { _ = try VideoJoinPlanner.plan(clips: clips([info(), info(w: 640, h: 360)]), options: [:], toolset: vt); throw TestFailure(message: "must refuse", file: #fileID, line: #line) } catch is ConversionError {}
            // The order: natural, or as given.
            let items = ["/x/v10.mp4", "/x/v2.mp4", "/x/v1.mp4"].map { FileItem(url: URL(fileURLWithPath: $0)) }
            try expectEqual(VideoJoinPlanner.ordered(items, natural: true).map(\.name), ["v1.mp4", "v2.mp4", "v10.mp4"])
            try expectEqual(VideoJoinPlanner.ordered(items, natural: false).map(\.name), ["v10.mp4", "v2.mp4", "v1.mp4"])
        }

        SelfTestRegistry.shared.register("video", "join argv: the copy route uses the concat demuxer with escaped paths, the fitting route one concat filter with silence for mute clips") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vj-\(Util.hex8())", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            var copy = try VideoJoinPlanner.plan(clips: clips([info(), info()], names: ["it's.mp4", "b.mp4"]), options: [:], toolset: ts)
            copy.clips[1].url = URL(fileURLWithPath: "/tmp/b.mp4")
            let c = try VideoJoinArgs.command(copy, output: URL(fileURLWithPath: "/out/r.mp4"), tempDirectory: tmp, keepMeta: true).arguments()
            try expect(c.contains("concat") && c.contains("-safe") && c.contains("copy") && !c.contains("-filter_complex"), c.joined(separator: " "))
            let list = try String(contentsOf: tmp.appendingPathComponent("clips.txt"), encoding: .utf8)
            try expect(list.contains("file '/tmp/it'\\''s.mp4'"), "single quote escaped: \(list)")
            let fit = try VideoJoinPlanner.plan(clips: clips([info(), info([]), info(w: 640, h: 360)]), options: [:], toolset: ts)
            let a = try VideoJoinArgs.command(fit, output: URL(fileURLWithPath: "/out/r.mp4"), tempDirectory: tmp, keepMeta: false).arguments()
            let graph = a[(a.firstIndex(of: "-filter_complex") ?? 0) + 1]
            try expect(graph.contains("concat=n=3:v=1:a=1[v][a]") && graph.contains("anullsrc") && graph.contains("pad=1920:1080") && graph.contains("fps=30"), graph)
            try expect(a.contains("libx264") && a.contains("aac") && a.contains("-map_metadata") && a[a.firstIndex(of: "-map_metadata")! + 1] == "-1", a.joined(separator: " "))
            let vt = try VideoJoinPlanner.plan(clips: clips([info(), info(w: 640, h: 360)]), options: [:], toolset: MediaToolset(hasFFmpeg: true, hasFFprobe: true, encoders: ["h264_videotoolbox", "aac"]))
            try expect(VideoJoinArgs.videoOptions(vt).contains("h264_videotoolbox") && VideoJoinArgs.videoOptions(vt).contains("-q:v"), "VideoToolbox options")
        }

        R.reg("join: three clips of different size, rate and sound become one playable video in natural order, picture and sound in step",
              oracles: ["vjoin.order", "vjoin.normalise", "vjoin.match"], timeout: 240) {
            // v1 red 320x240@24 with sound (1 s); v2 green 16:9 192x108@30 WITHOUT sound (1.5 s); v10 blue 160x120@25 with sound (2 s).
            let v1 = try clip("v1.mp4", color: "red", size: "320x240", fps: 24, seconds: 1, tone: 440)
            let v2 = try clip("v2.mp4", color: "green", size: "192x108", fps: 30, seconds: 1.5, audio: false)
            let v10 = try clip("v10.mp4", color: "blue", size: "160x120", fps: 25, seconds: 2, tone: 880, rate: 44_100)
            let run = try await join([v10, v2, v1])   // the order of dropping does not matter: natural order wins
            let p = try VT.probe(run.url)
            try expectEqual(p.vcodec, "h264"); try expect(p.formatName.contains("mp4"), p.formatName)
            try expect(p.width == 320 && p.height == 240, "the largest clip sets the size: \(p.width)x\(p.height)")
            try expectClose(p.rate("avg_frame_rate"), 30, tolerance: 0.05)
            try expectClose(p.duration, 4.5, tolerance: 0.15)
            let frames = try unwrap(Int(VT.run(try unwrap(VT.ffprobe), ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", run.url.path]).trimmingCharacters(in: .whitespacesAndNewlines)))
            try expect(abs(frames - 135) <= 3, "frame count \(frames), expected about 4.5 s x 30 = 135")
            try expect(p.audio != nil, "the sound is kept")
            try expectEqual(p.int(p.audio, "channels"), 1, "every clip is mono, so is the result"); try expectEqual(p.int(p.audio, "sample_rate"), 48_000, "the highest rate of the clips")
            // Order and letterboxing, read from the pixels.
            try expectEqual(try colour(run.url, at: 0.5), "red"); try expectEqual(try colour(run.url, at: 1.8), "green"); try expectEqual(try colour(run.url, at: 3.5), "blue")
            let f = try VT.frame(run.url, at: 1.8)
            let bar = f.pixel(f.w / 2, 3)
            try expect(bar.0 < 40 && bar.1 < 40 && bar.2 < 40, "the 16:9 clip is letterboxed with black bars, not stretched: \(bar)")
            // Sound in step: tone while clips 1 and 3 play, silence (not a gap, not a shift) while the sound-less clip 2 plays.
            let loud = try unwrap(VT.rmsDB(run.url, from: 0.1, duration: 0.7)), silent = try unwrap(VT.rmsDB(run.url, from: 1.15, duration: 1.0)), loud3 = try unwrap(VT.rmsDB(run.url, from: 2.7, duration: 1.5))
            try expect(loud > -30 && loud3 > -30 && silent < -60, "tone \(loud) dB, silence \(silent) dB, tone \(loud3) dB")
            let sound = try unwrap(Double(VT.run(try unwrap(VT.ffprobe), ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration", "-of", "csv=p=0", run.url.path]).trimmingCharacters(in: .whitespacesAndNewlines)))
            try expect(abs(sound - p.duration) < 0.15, "sound \(sound) s against picture \(p.duration) s")
            // Name and place: beside the first (sorted) video, "(joined)".
            try expect(run.url.lastPathComponent.hasPrefix("v1 (joined)") || run.url.lastPathComponent.contains("(joined)") || run.url.lastPathComponent.contains("(объединено)"), run.url.lastPathComponent)
            try expect(run.log.contains { $0.contains("join route: reencode") }, "the log names the route")
            try expect(run.result.note?.en.contains("differ") == true, "the finished card says the clips were fitted: \(run.result.note?.en ?? "nil")")
            // Progress stays in range, never goes back, ends at 1.
            try expect(run.progress.allSatisfy { $0 >= 0 && $0 <= 1.0001 } && zip(run.progress, run.progress.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && (run.progress.last ?? 0) > 0.99, "progress: \(run.progress.suffix(5))")
            // The independent player agrees: AVFoundation can play it and sees the same length.
            let asset = AVURLAsset(url: run.url)
            let (playable, dur) = try await asset.load(.isPlayable, .duration)
            try expect(playable, "AVFoundation cannot play the result")
            try expectClose(dur.seconds, p.duration, tolerance: 0.2)
            let tracks = try await asset.load(.tracks); try expect(tracks.contains { $0.mediaType == .video } && tracks.contains { $0.mediaType == .audio }, "AVFoundation sees a video and an audio track")
            // "As selected" keeps the order given; "match to the first video" takes its size.
            let chosen = try await join([v10, v1], [VideoJoinKeys.order: "selection", VideoJoinKeys.match: "first"])
            let sz = VT.probeSize(chosen.url); try expect(sz == (160, 120), "the first video in the chosen order decides the size: \(sz)")
            try expectEqual(try colour(chosen.url, at: 0.5), "blue"); try expectEqual(try colour(chosen.url, at: 2.5), "red")
            // Switching the fitting off refuses differing clips with an honest message and leaves nothing behind.
            do { _ = try await join([v1, v2], [VideoJoinKeys.normalise: false]); throw TestFailure(message: "differing clips must be refused when fitting is off", file: #fileID, line: #line) }
            catch let e as ConversionError { try expect(ConversionError.describe(e).contains("cannot be joined"), ConversionError.describe(e)) }
        }

        R.reg("join: identical clips are joined by stream copy, bit for bit (every decoded frame equals the clips' frames in order)", oracles: ["vjoin.keepMeta", "vjoin.container"], timeout: 180) {
            let a = try clip("same1.mp4", color: "red", seconds: 1, title: "Swamp trip"), b = try clip("same2.mp4", color: "green", seconds: 1.5), c = try clip("same3.mp4", color: "blue", seconds: 1)
            let run = try await join([c, a, b])
            try expect(run.log.contains { $0.contains("join route: copy") }, "log: \(run.log.filter { $0.contains("join") })")
            let want = frameHashes(a) + frameHashes(b) + frameHashes(c)
            try expect(want.count == 24 + 36 + 24, "fixtures: \(want.count) frames")
            try expectEqual(frameHashes(run.url), want, "the joined frames are the clips' frames, in order, unchanged")
            let p = try VT.probe(run.url)
            try expectEqual(p.vcodec, "h264"); try expectClose(p.duration, 3.5, tolerance: 0.15)
            try expectEqual(p.tags["title"], "Swamp trip", "the first video's tags travel along")
            let stripped = try await join([a, b, c], [VideoJoinKeys.keepMeta: false])
            try expect(try VT.probe(stripped.url).tags["title"] == nil, "tags removed on request")
            try expectEqual(frameHashes(stripped.url), want)
            // A different container: MKV holds the same streams, still a copy.
            let mkv = try await join([a, b, c], [VideoJoinKeys.container: "mkv"])
            try expect(try VT.probe(mkv.url).formatName.contains("matroska"), "MKV"); try expectEqual(frameHashes(mkv.url), want)
            // WebM cannot hold H.264: the video is re-encoded to VP9 and says so.
            let web = try await join([a, b], [VideoJoinKeys.container: "webm", VideoJoinKeys.quality: 34])
            let wp = try VT.probe(web.url)
            try expect(wp.formatName.contains("webm") && wp.vcodec == "vp9", "WebM + VP9: \(wp.formatName) \(wp.vcodec)")
            try expect(wp.audio.map { VT.probeCodec($0) } == "opus", "Opus sound")
        }

        R.reg("join: a lower CRF makes a larger file when the clips are re-encoded", oracles: ["vjoin.quality"], timeout: 180) {
            let a = try VT.clip(VTShared.fx, "q1.mp4", seconds: 1.5, size: "320x240", noise: 20), b = try VT.clip(VTShared.fx, "q2.mp4", seconds: 1.5, size: "256x192", fps: 30, noise: 20)
            let good = try await join([a, b], [VideoJoinKeys.quality: 16]), small = try await join([a, b], [VideoJoinKeys.quality: 32])
            try expect(VTFile.size(good.url) > VTFile.size(small.url) * 2, "CRF 16: \(VTFile.size(good.url)) bytes, CRF 32: \(VTFile.size(small.url)) bytes")
        }

        R.reg("join: cancelling stops ffmpeg within a second and leaves no partial file; a file without picture is refused", timeout: 180) {
            let a = try VT.clip(VTShared.fx, "c1.mp4", seconds: 40, size: "1280x720", fps: 30, codec: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", "-pix_fmt", "yuv420p"], noise: 8)
            let b = try VT.clip(VTShared.fx, "c2.mp4", seconds: 40, size: "1024x576", fps: 25, codec: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", "-pix_fmt", "yuv420p"], noise: 8)
            let rules = VT.outRules()
            let op = try operation()
            let items = [FileItem(url: a), FileItem(url: b)]
            let ctx = OperationContext.testing(op, items: items, mode: .studio, rules: rules)
            let started = Locked<Date?>(nil)
            ctx.onProgress = { p, _, _ in if let p, p > 0, started.value == nil { started.withLock { $0 = Date() } } }
            let task = Task { @MainActor in try await op.execute(items: items, ctx: ctx) }
            var waited = 0.0
            while started.value == nil, waited < 30 { try await Task.sleep(nanoseconds: 100_000_000); waited += 0.1 }
            try expect(started.value != nil, "the join never reported progress")
            let t0 = Date()
            task.cancel()
            do { _ = try await task.value; throw TestFailure(message: "a cancelled join must not finish", file: #fileID, line: #line) } catch is CancellationError {}
            try expect(Date().timeIntervalSince(t0) < 2, "cancellation took \(Date().timeIntervalSince(t0)) s")
            ctx.cleanupTemp()
            let left = (try? FileManager.default.contentsOfDirectory(atPath: rules.customDir ?? "")) ?? []
            try expect(left.isEmpty, "nothing may be left behind: \(left)")
            let audioOnly = try VT.make(VTShared.fx, "tone.mka", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac"])
            do { _ = try await join([a, audioOnly]); throw TestFailure(message: "no picture must be refused", file: #fileID, line: #line) } catch is ConversionError {}
        }
    }
}

extension VT {
    static func probeCodec(_ stream: [String: Any]) -> String { stream["codec_name"] as? String ?? "" }
}
