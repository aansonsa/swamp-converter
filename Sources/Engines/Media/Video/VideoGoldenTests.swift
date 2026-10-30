import Foundation

// Golden tests without encoding (spec/handbrake.md 5.4 "two kinds of test"): the argument list for every codec, the filter order, stream mapping,
// FFmpegCommand rules, the pure parsers of the analysers and the ffmpeg progress, and capability gating with hand-made toolsets.

enum VideoGoldenTests {
    static func reg(_ name: String, oracles: [String] = [], requires: [String] = [], _ body: @escaping SelfTestBody) {
        VideoOracles.prove(oracles, by: name)
        SelfTestRegistry.shared.register("video.golden", name, requires: requires, timeout: 60, body)
    }

    /// A complete modern toolset, the same on every Mac, so the golden lines never depend on what is installed.
    static let full = MediaToolset(hasFFmpeg: true, hasFFprobe: true, ffmpegVersion: "9.0.1",
                                   encoders: ["libx264", "libx265", "libsvtav1", "libvpx", "libvpx-vp9", "h264_videotoolbox", "hevc_videotoolbox", "prores_videotoolbox", "prores_ks", "dnxhd", "ffv1", "mpeg4",
                                              "aac", "aac_at", "libmp3lame", "libopus", "flac", "alac", "ac3", "eac3", "pcm_s16le", "pcm_s24le", "vorbis"],
                                   filters: ["bwdif", "yadif", "w3fdif", "hqdn3d", "nlmeans", "atadenoise", "cas", "minterpolate", "colorspace", "overlay"], muxers: ["mp4", "mov", "matroska", "webm", "avi", "gif"])

    static func argv(_ set: OptionValues, info: MediaInfo = VTPlan.info(), analysis: VideoAnalysis = VideoAnalysis(), tools: MediaToolset = full) throws -> String {
        let p = try VTPlan.plan(set, info: info, analysis: analysis, toolset: tools)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vt-g-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: tmp) }
        let cmds = try VideoFFmpegArgs.commands(for: p, input: URL(fileURLWithPath: "/in/source.mp4"), output: URL(fileURLWithPath: "/out/result.\(p.container)"), tempDirectory: tmp)
        return cmds.last!.arguments().joined(separator: " ")
    }

    static func register() {
        reg("FFmpegCommand: fixed prefix, input options before -i, filters joined, outputs last, leading dashes made safe, spaces and Cyrillic stay one argument") {
            var c = FFmpegCommand()
            c.inputs = [FFmpegInput(url: URL(fileURLWithPath: "/tmp/Мой фильм (1).mov"), options: ["-ss", "1.5"]), FFmpegInput(url: URL(fileURLWithPath: "/tmp/b.png"))]
            c.videoFilters = ["scale=640:-2", "hflip"]; c.audioFilters = ["volume=3dB", "aresample=48000"]
            c.outputs = [FFmpegOutput(url: URL(fileURLWithPath: "/tmp/out.mp4"), options: ["-c:v", "libx264"])]
            c.global = ["-threads", "2"]
            let a = c.arguments()
            try expectEqual(Array(a.prefix(6)), ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"])
            try expectEqual(a[6...7].map { $0 }, ["-threads", "2"])
            let i = try unwrap(a.firstIndex(of: "-ss")); try expectEqual(a[i + 1], "1.5"); try expectEqual(a[i + 2], "-i"); try expectEqual(a[i + 3], "/tmp/Мой фильм (1).mov")
            try expect(a.contains("scale=640:-2,hflip") && a.contains("volume=3dB,aresample=48000"), "filters joined with commas")
            try expectEqual(a.last, "/tmp/out.mp4")
            try expect(a.firstIndex(of: "-vf")! < a.firstIndex(of: "-c:v")!, "filters before the output options")
            c.filterComplex = "[0:v][1:v]overlay[v]"
            try expect(c.arguments().contains("-filter_complex") && !c.arguments().contains("-vf"), "a filter graph replaces -vf")
            try expectEqual(FFmpegCommand.safePath(URL(fileURLWithPath: "-weird.mp4")).hasPrefix("./") || FFmpegCommand.safePath(URL(fileURLWithPath: "-weird.mp4")).hasPrefix("/"), true)
            try expect(!c.displayString().isEmpty)
        }

        R_codecTable()

        reg("no argument list ever uses -vsync (this ffmpeg removed it): frame handling is always an explicit -fps_mode", oracles: []) {
            for set: OptionValues in [[:], [VideoKeys.fpsMode: "constant", VideoKeys.fps: "24"], [VideoKeys.fpsMode: "peak", VideoKeys.fps: "30"], [VideoKeys.container: "gif"], [VideoKeys.vcodec: "hevc"]] {
                let a = try argv(set)
                try expect(!a.contains("-vsync"), "-vsync in \(a)")
                if set[VideoKeys.container] == nil { try expect(a.contains("-fps_mode "), "no -fps_mode in \(a)") }
            }
            try expect(try argv([VideoKeys.fpsMode: "constant", VideoKeys.fps: "24"]).contains("-fps_mode cfr"))
            try expect(try argv([VideoKeys.fpsMode: "peak", VideoKeys.fps: "30"], info: VTPlan.info(fps: 60)).contains("-fps_mode cfr"))
            try expect(try argv([VideoKeys.fpsMode: "peak", VideoKeys.fps: "30"], info: VTPlan.info(fps: 24)).contains("-fps_mode vfr"), "a 24 fps source stays untouched")
        }

        reg("streams are mapped explicitly: no cover art, data or attachment sneaks in; unwanted streams are switched off") {
            let a = try argv([VideoKeys.audioMode: "none", VideoKeys.subMode: "none"])
            try expect(a.contains("-map 0:0") && a.contains("-an") && a.contains("-sn"), a)
            try expect(!a.contains("-map 0 "), "never map everything: \(a)")
            let both = try argv([VideoKeys.audioMode: "all"], info: VTPlan.info(audio: [("aac", 2, "eng"), ("ac3", 6, "rus")]))
            try expect(both.contains("-map 0:1") && both.contains("-map 0:2"), both)
            let mc = try argv([VideoKeys.chapterMode: "none"]); try expect(mc.contains("-map_chapters -1"), mc)
            let strip = try argv([VideoKeys.metadataMode: "strip"]); try expect(strip.contains("-map_metadata -1") && strip.contains("-fflags +bitexact"), strip)
        }

        reg("the filter chain keeps the documented order: deinterlace, crop, rotate, denoise, scale, even size, sharpen, colour, speed, frame rate") {
            let a = try argv([VideoKeys.deinterlace: "on", VideoKeys.cropMode: "custom", VideoKeys.cropTop: 10, VideoKeys.cropBottom: 10, VideoKeys.rotate: "90", VideoKeys.denoise: "light",
                              VideoKeys.sizeMode: "percent", VideoKeys.sizePercent: 50, VideoKeys.sharpen: "light", VideoKeys.eqBrightness: 0.1, VideoKeys.filterSpeed: 2.0,
                              VideoKeys.fpsMode: "constant", VideoKeys.fps: "15"], info: VTPlan.info(w: 1920, h: 1080, interlaced: true))
            let vf = try unwrap(a.components(separatedBy: " -vf ").last?.components(separatedBy: " -").first)
            let order = ["bwdif", "crop=", "transpose=1", "hqdn3d", "scale=", "scale=trunc", "unsharp", "eq=", "setpts=PTS/2", "fps=15"]
            var last = -1
            for m in order {
                guard let r = vf.range(of: m, range: vf.index(vf.startIndex, offsetBy: max(last, 0))..<vf.endIndex) else { throw TestFailure(message: "\(m) missing or out of order in \(vf)", file: #fileID, line: #line) }
                last = vf.distance(from: vf.startIndex, to: r.lowerBound)
            }
        }

        reg("odd sizes: encoders that need even sizes get the even-size scale at the end of the picture steps, the others do not") {
            for (codec, even) in [("h264", true), ("hevc", true), ("av1", true), ("vp9", false), ("mpeg4", false)] {
                let container = ["vp9": "webm", "av1": "mkv", "mpeg4": "avi"][codec] ?? "mp4"
                let a = try argv([VideoKeys.vcodec: .string(codec), VideoKeys.container: .string(container), VideoKeys.venc: "software"])
                try expectEqual(a.contains("scale=trunc(iw/2)*2:trunc(ih/2)*2"), even, "\(codec): \(a)")
            }
        }

        reg("turbo1: a fast first pass is the default; switching it off asks x264 and x265 for a slow first pass", oracles: ["turbo1.argv"]) {
            let on = try argv([VideoKeys.rateControl: "abr", VideoKeys.twoPass: true, VideoKeys.turbo1: true, VideoKeys.venc: "software"])
            let off = try argv([VideoKeys.rateControl: "abr", VideoKeys.twoPass: true, VideoKeys.turbo1: false, VideoKeys.venc: "software"])
            try expect(!on.contains("slow-firstpass"), on); try expect(off.contains("slow-firstpass=1"), off)
            let x265 = try argv([VideoKeys.vcodec: "hevc", VideoKeys.rateControl: "abr", VideoKeys.twoPass: true, VideoKeys.turbo1: false, VideoKeys.venc: "software"])
            try expect(x265.contains("slow-firstpass=1"), x265)
        }

        reg("two passes: pass 1 reads the source without sound and writes nowhere, pass 2 has the same bitrate and the sound; hardware encoders stay single pass") {
            let p = try VTPlan.plan([VideoKeys.rateControl: "abr", VideoKeys.vbitrate: 900, VideoKeys.twoPass: true, VideoKeys.venc: "software"], toolset: full)
            try expectEqual(p.passes, 2)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vt-g-\(Util.hex8())", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: tmp) }
            let cmds = try VideoFFmpegArgs.commands(for: p, input: URL(fileURLWithPath: "/in/a.mp4"), output: URL(fileURLWithPath: "/out/b.mp4"), tempDirectory: tmp)
            let a1 = cmds[0].arguments().joined(separator: " "), a2 = cmds[1].arguments().joined(separator: " ")
            try expect(a1.contains("-an") && a1.contains("-pass 1") && a1.hasSuffix("-f null /dev/null"), a1)
            try expect(a2.contains("-pass 2") && a2.contains("-map 0:1") && a2.contains("-b:v 900k") && a1.contains("-b:v 900k"), a2)
            let hw = try VTPlan.plan([VideoKeys.rateControl: "abr", VideoKeys.vbitrate: 900, VideoKeys.twoPass: true, VideoKeys.venc: "hardware"], toolset: full)
            try expectEqual(hw.passes, 1)
        }

        reg("burn-in and watermark add a second input and an overlay stage with the blend format of the picture; fades come after the overlays") {
            let subs = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(Util.hex8()).srt")
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n\n".utf8).write(to: subs); defer { try? FileManager.default.removeItem(at: subs) }
            let a = try argv([VideoKeys.subMode: "burn", VideoKeys.extFile: .string(subs.path), VideoKeys.wmMode: "text", VideoKeys.wmText: "Mark", VideoKeys.fadeOut: 1.0])
            try expect(a.contains("-filter_complex") && a.contains("overlay=") && a.contains("format=yuv420:eof_action"), a)
            try expect(a.contains("-f concat -safe 0"), "the cue timeline is a concat input: \(a)")
            let fg = try unwrap(a.components(separatedBy: " -filter_complex ").last?.components(separatedBy: " -map").first)
            try expect(fg.range(of: "overlay")!.lowerBound < fg.range(of: "fade=t=out")!.lowerBound, "fade after the overlays: \(fg)")
            try expectEqual(VideoOverlayRenderer.overlayFormat("yuv420p10le"), "yuv420p10"); try expectEqual(VideoOverlayRenderer.overlayFormat("yuv444p"), "yuv444"); try expectEqual(VideoOverlayRenderer.overlayFormat(nil), "yuv420")
        }

        reg("pure analysis parsers: cropdetect, idet and loudnorm lines, crop merging and keyframe windows") {
            let c = try unwrap(VideoAnalyzer.parseCrop("[Parsed_cropdetect_0 @ 0x1] x1:0 x2:319 y1:30 y2:209 w:320 h:180 x:0 y:30 pts:100 t:4.1 limit:0.094 crop=320:180:0:30"))
            try expect(c.w == 320 && c.h == 180 && c.x == 0 && c.y == 30, "\(c)")
            try expect(VideoAnalyzer.parseCrop("no crop here") == nil)
            let merged = try unwrap(VideoAnalyzer.mergeCrops([.init(x: 0, y: 30, w: 320, h: 180), .init(x: 0, y: 28, w: 320, h: 184), .init(x: 0, y: 32, w: 320, h: 176)], frame: (320, 240)))
            try expect(merged.y == 28 && merged.h == 184, "the union of the windows: \(merged)")
            try expect(VideoAnalyzer.mergeCrops([.init(x: 0, y: 0, w: 320, h: 238)], frame: (320, 240)) == nil, "two pixels of bars are noise")
            try expect(VideoAnalyzer.mergeCrops([.init(x: 100, y: 100, w: 20, h: 20)], frame: (320, 240)) == nil, "a mostly black window is ignored")
            try expectEqual(VideoAnalyzer.parseIdet(["Multi frame detection: TFF: 90 BFF: 0 Progressive: 10 Undetermined: 0"]), true)
            try expectEqual(VideoAnalyzer.parseIdet(["Multi frame detection: TFF: 1 BFF: 0 Progressive: 199 Undetermined: 0"]), false)
            try expect(VideoAnalyzer.parseIdet(["Multi frame detection: TFF: 1 BFF: 0 Progressive: 2 Undetermined: 0"]) == nil, "too few frames to say")
            let json = ["[Parsed_loudnorm_0 @ 0x1]", "{", "\t\"input_i\" : \"-21.81\",", "\t\"input_tp\" : \"-9.51\",", "\t\"input_lra\" : \"1.10\",", "\t\"input_thresh\" : \"-32.14\",", "\t\"output_i\" : \"-16.00\",", "\t\"target_offset\" : \"0.02\"", "}"]
            let m = try unwrap(VideoAnalyzer.parseLoudnorm(json)); try expectClose(m.inputI, -21.81); try expectClose(m.targetOffset, 0.02)
            try expect(VideoAnalyzer.parseLoudnorm(["nothing"]) == nil)
            try expectEqual(VideoAnalyzer.windows(duration: 100, count: 5).count, 5); try expectEqual(VideoAnalyzer.windows(duration: 3, count: 5), [0])
        }

        reg("ffmpeg progress: blocks become fractions of the OUTPUT length, never reach 1 before the process ends; known failures become calm messages") {
            var p = FFmpegProgressParser()
            for line in ["frame=10", "out_time_us=500000", "speed=2.5x", "progress=continue"] { _ = p.feed(line) }
            try expectClose(p.outTime ?? -1, 0.5); try expectClose(p.speed ?? -1, 2.5)
            try expect(p.feed("progress=end"), "a block ends with progress=")
            var q = FFmpegProgressParser(); _ = q.feed("out_time_us=N/A"); try expect(q.outTime == nil, "N/A is ignored")
            func friendly(_ text: String, audioOnly: Bool = false) -> String {
                var c = FFmpegCommand(); c.inputs = [FFmpegInput(url: URL(fileURLWithPath: "/a.mp4"))]
                c.outputs = [FFmpegOutput(url: URL(fileURLWithPath: "/b.mp4"), options: audioOnly ? ["-vn"] : [])]
                return ConversionError.describe(FFmpegRunner.friendlyError(.toolFailed(tool: "ffmpeg", code: 1, detail: ""), stderr: [text], command: c))
            }
            try expect(friendly("Output file does not contain any stream", audioOnly: true).lowercased().contains("audio"), "no audio track")
            try expect(friendly("Invalid data found when processing input").lowercased().contains("damaged"), "damaged file")
            try expect(friendly("No space left on device").lowercased().contains("disk is full"), "disk full")
            try expect(friendly("width not divisible by 2").contains("even") || friendly("width not divisible by 2").lowercased().contains("multiple of 2"), "even size")
            try expect(friendly("Unknown encoder 'libfoo'").lowercased().contains("cannot write"), "unknown encoder")
        }

        reg("MediaProbe parses ffprobe JSON leniently: rotation, interlacing, HDR, frame rates, bit depth, chapters, missing and N/A fields", requires: []) {
            let json: [String: Any] = [
                "format": ["format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "12.5", "bit_rate": "4000000", "size": "6250000", "tags": ["Title": "Clip"]],
                "streams": [
                    ["index": 0, "codec_type": "video", "codec_name": "hevc", "profile": "Main 10", "width": 3840, "height": 2160, "avg_frame_rate": "30000/1001", "r_frame_rate": "30000/1001", "pix_fmt": "yuv420p10le",
                     "field_order": "progressive", "color_transfer": "smpte2084", "color_primaries": "bt2020", "color_space": "bt2020nc", "sample_aspect_ratio": "1:1", "codec_tag_string": "hvc1",
                     "side_data_list": [["side_data_type": "Display Matrix", "rotation": -90]], "disposition": ["default": 1, "attached_pic": 0]],
                    ["index": 1, "codec_type": "audio", "codec_name": "eac3", "channels": 6, "channel_layout": "5.1(side)", "sample_rate": "48000", "bit_rate": "640000", "tags": ["language": "rus", "title": "Основной"]],
                    ["index": 2, "codec_type": "subtitle", "codec_name": "hdmv_pgs_subtitle", "tags": ["language": "eng"], "disposition": ["forced": 1]],
                    ["index": 3, "codec_type": "video", "codec_name": "mjpeg", "width": 600, "height": 600, "disposition": ["attached_pic": 1]]
                ],
                "chapters": [["start_time": "0.000000", "end_time": "6.0", "tags": ["title": "Один"]], ["start_time": "6.0", "end_time": "12.5"]]]
            let m = try unwrap(MediaProbe.parseFFprobe(json, url: URL(fileURLWithPath: "/x/clip.mp4")))
            try expectEqual(m.container, "mp4"); try expectClose(m.duration ?? 0, 12.5); try expectEqual(m.tags["title"], "Clip")
            let v = try unwrap(m.primaryVideo)
            try expect(v.rotation == 90 && v.isHDR && v.bitDepth == 10 && !v.interlaced && v.codecTag == "hvc1", "video \(v)")
            try expectEqual(v.rotatedSize?.width, 2160); try expectClose(v.fps ?? 0, 29.97, tolerance: 0.01)
            try expectEqual(m.audioStreams.first?.language, "rus"); try expectEqual(m.audioStreams.first?.channels, 6)
            try expect(m.subtitleStreams.first?.isBitmapSubtitle == true && m.subtitleStreams.first?.isForced == true, "PGS forced")
            try expectEqual(m.attachedPictures.count, 1); try expectEqual(m.videoStreams.count, 1, "cover art is not a video stream")
            try expectEqual(m.chapters.map(\.title), ["Один", ""]);
            let s = MediaProbe.sourceInfo(from: m, kind: .video)
            try expectEqual(s.int("video.rotation"), 90); try expectEqual(s.bool("video.hdr"), true); try expectEqual(s.int("audio.0.channels"), 6); try expectEqual(s.int("chapters.count"), 2)
            try expectEqual(s.int("video.width"), 2160, "display size after rotation"); try expect(s.warnings.count >= 2, "plain-words warnings for HDR and rotation")
            try expect(MediaProbe.parseFFprobe(["format": [:], "streams": []], url: URL(fileURLWithPath: "/x/none.mp4")) == nil, "nothing to read")
            let odd = try unwrap(MediaProbe.parseFFprobe(["format": ["duration": "N/A"], "streams": [["codec_type": "video", "codec_name": "h264", "width": 10, "height": 10, "avg_frame_rate": "0/0", "r_frame_rate": "25/1"]]], url: URL(fileURLWithPath: "/x/odd.avi")))
            try expect(odd.duration == nil && odd.primaryVideo?.fps == 25, "N/A duration and 0/0 rate are tolerated")
        }

        reg("capability gating: a toolset without x265 uses the hardware HEVC encoder (and says so); without any HEVC encoder the plan is refused with a calm message") {
            var t = full; t.encoders.remove("libx265")
            let p = try VTPlan.plan([VideoKeys.vcodec: "hevc"], toolset: t)
            try expectEqual(p.videoEncoder, "hevc_videotoolbox"); try expect(p.hardware && !p.notes.isEmpty, "a note says so")
            t.encoders.remove("hevc_videotoolbox")
            do { _ = try VTPlan.plan([VideoKeys.vcodec: "hevc"], toolset: t); throw TestFailure(message: "no HEVC encoder must be refused", file: #fileID, line: #line) }
            catch let e as ConversionError { try expect(ConversionError.describe(e).contains("HEVC"), ConversionError.describe(e)) }
            var noMP3 = full; noMP3.encoders.remove("libmp3lame")
            let a = try VTPlan.plan([VideoKeys.audioCodec: "mp3"], toolset: noMP3)
            try expectEqual(a.audioTracks.first?.codec, "aac"); try expect(a.notes.contains { $0.en.contains("MP3") }, "the plan says MP3 is not available")
            var noAT = full; noAT.encoders.remove("aac_at")
            try expectEqual(try VTPlan.plan([:], toolset: noAT).audioTracks.first?.encoder, "aac"); try expectEqual(try VTPlan.plan([:], toolset: full).audioTracks.first?.encoder, "aac_at")
        }

        reg("capability gating: without ffmpeg only MP4 / MOV with H.264, HEVC or ProRes can be written, through AVFoundation; everything else says it needs ffmpeg") {
            var none = MediaToolset(); none.hasFFmpeg = false
            let p = try VTPlan.plan([:], toolset: none)
            try expectEqual(p.backend, .avfoundation); try expectEqual(p.videoEncoder, "avf.h264"); try expect(p.notes.contains { $0.en.contains("ffmpeg is not installed") })
            try expectEqual(try VTPlan.plan([VideoKeys.vcodec: "hevc"], toolset: none).videoEncoder, "avf.hevc")
            for set: OptionValues in [[VideoKeys.container: "mkv"], [VideoKeys.container: "webm"], [VideoKeys.container: "gif"], [VideoKeys.container: "mp3"], [VideoKeys.vcodec: "vp9", VideoKeys.container: "mp4"]] {
                do { _ = try VTPlan.plan(set, toolset: none); throw TestFailure(message: "\(set.storage) must need ffmpeg", file: #fileID, line: #line) }
                catch let e as ConversionError { if case .toolMissing = e {} else if case .unsupported = e {} else { throw e } }
            }
            let hdr = try VTPlan.plan([:], info: VTPlan.info(depth: 10, hdr: true), toolset: none)
            try expect(hdr.notes.contains { $0.en.contains("8-bit SDR") }, "HDR loss without ffmpeg is announced")
            // Availability on the wheel.
            let mkv = [FileItem(url: URL(fileURLWithPath: "/tmp/a.mkv"), isDirectory: false)], mp4 = [FileItem(url: URL(fileURLWithPath: "/tmp/a.mp4"), isDirectory: false)]
            try expect(!VideoOperation.availability(base: .available, items: mkv, hasFFmpeg: false).isAvailable, "an MKV source needs ffmpeg")
            try expect(VideoOperation.availability(base: .available, items: mp4, hasFFmpeg: false).isAvailable, "an MP4 source does not")
            try expect(VideoOperation.availability(base: .available, items: mkv, hasFFmpeg: true).isAvailable, "with ffmpeg everything opens")
            let gate = OperationAvailability.unavailable(reason: Capabilities.reason(for: "tool.ffmpeg"), missing: [.ffmpeg])
            try expect(!VideoOperation.availability(base: gate, items: mp4, hasFFmpeg: false).isAvailable, "MKV output (a missing tool in the catalogue row) stays unavailable")
        }
    }

    // MARK: Codec table

    static func R_codecTable() {
        reg("argument lists per codec: encoder, rate control, tags, pixel format and container flags", oracles: ["vcodec.codec"]) {
            struct Case { var set: OptionValues; var has: [String]; var hasNot: [String] = [] }
            let cases: [Case] = [
                Case(set: [VideoKeys.venc: "software"], has: ["-c:v libx264", "-preset medium", "-crf 23", "-pix_fmt yuv420p", "-movflags +faststart", "-f mp4", "-c:a:0 aac_at", "-b:a:0 160k"], hasNot: ["-tag:v"]),
                Case(set: [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software"], has: ["-c:v libx265", "-crf 23", "-tag:v hvc1", "-x265-params log-level=error"]),
                Case(set: [VideoKeys.vcodec: "hevc", VideoKeys.venc: "hardware", VideoKeys.cqHardware: 55], has: ["-c:v hevc_videotoolbox", "-q:v 55", "-tag:v hvc1"], hasNot: ["-crf"]),
                Case(set: [VideoKeys.vcodec: "h264", VideoKeys.venc: "hardware", VideoKeys.cqHardware: 70], has: ["-c:v h264_videotoolbox", "-q:v 70"], hasNot: ["-crf"]),
                Case(set: [VideoKeys.vcodec: "av1", VideoKeys.container: "mkv"], has: ["-c:v libsvtav1", "-preset 6", "-crf 23", "-f matroska"]),
                Case(set: [VideoKeys.vcodec: "vp9", VideoKeys.container: "webm", VideoKeys.speed: "fast"], has: ["-c:v libvpx-vp9", "-b:v 0", "-crf 23", "-row-mt 1", "-cpu-used 4", "-f webm", "-c:a:0 libopus"]),
                Case(set: [VideoKeys.vcodec: "vp8", VideoKeys.container: "webm"], has: ["-c:v libvpx", "-crf 23", "-b:v 20M"]),
                Case(set: [VideoKeys.vcodec: "prores", VideoKeys.container: "mov", VideoKeys.profile: "hq", VideoKeys.venc: "software"], has: ["-c:v prores_ks", "-profile:v 3", "-vendor apl0", "-pix_fmt yuv422p10le", "-f mov"], hasNot: ["-crf"]),
                Case(set: [VideoKeys.vcodec: "prores", VideoKeys.container: "mov", VideoKeys.profile: "4444", VideoKeys.venc: "software"], has: ["-profile:v 4", "-pix_fmt yuv444p10le"]),
                Case(set: [VideoKeys.vcodec: "dnxhr", VideoKeys.container: "mov", VideoKeys.profile: "sq"], has: ["-c:v dnxhd", "-profile:v dnxhr_sq", "-pix_fmt yuv422p"]),
                Case(set: [VideoKeys.vcodec: "ffv1", VideoKeys.container: "mkv"], has: ["-c:v ffv1", "-level 3", "-g 1"]),
                Case(set: [VideoKeys.vcodec: "mpeg4", VideoKeys.container: "avi", VideoKeys.cq: 23, VideoKeys.audioCodec: "mp3"], has: ["-c:v mpeg4", "-q:v 4", "-f avi", "-c:a:0 libmp3lame"]),
                Case(set: [VideoKeys.vcodec: "copy"], has: ["-c:v copy"], hasNot: ["-crf", "-vf", "libx264"]),
                Case(set: [VideoKeys.rateControl: "lossless", VideoKeys.venc: "software"], has: ["-crf 0"]),
                Case(set: [VideoKeys.rateControl: "abr", VideoKeys.vbitrate: 1500, VideoKeys.twoPass: false, VideoKeys.venc: "software"], has: ["-b:v 1500k"], hasNot: ["-crf", "-pass"]),
                Case(set: [VideoKeys.venc: "software", VideoKeys.profile: "high", VideoKeys.level: "4.1", VideoKeys.tune: "film", VideoKeys.keyint: 2.0, VideoKeys.bframes: "2", VideoKeys.refs: 4],
                     has: ["-profile:v high", "-level 4.1", "-tune film", "-g 60", "-flags +cgop", "-bf 2", "-refs 4"]),
                Case(set: [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.profile: "main10", VideoKeys.level: "4.1", VideoKeys.keyint: 2.0, VideoKeys.bframes: "3", VideoKeys.refs: 3],
                     has: ["-profile:v main10", "level-idc=41", "keyint=60", "bframes=3", "ref=3", "-pix_fmt yuv420p10le"]),
                Case(set: [VideoKeys.venc: "software", VideoKeys.vbvMaxrate: 4000], has: ["-maxrate 4000k", "-bufsize 8000k"]),
                Case(set: [VideoKeys.venc: "software", VideoKeys.extra: "ref=3:bad stuff;rm -rf /:deblock=-1,-1"], has: ["-x264-params ref=3:deblock=-1,-1"], hasNot: ["rm", "bad"]),
                Case(set: [VideoKeys.faststart: false], has: [], hasNot: ["-movflags"]),
                Case(set: [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.appleTag: false], has: ["-c:v libx265"], hasNot: ["-tag:v"]),
                Case(set: [VideoKeys.venc: "software", VideoKeys.speed: "veryslow"], has: ["-preset veryslow"]),
                Case(set: [VideoKeys.vcodec: "av1", VideoKeys.container: "mkv", VideoKeys.speed: "veryslow"], has: ["-preset 2"]),
            ]
            for c in cases {
                let a = try argv(c.set)
                for h in c.has { try expect(a.contains(h), "missing \"\(h)\" in \(a)") }
                for n in c.hasNot { try expect(!a.contains(n), "unexpected \"\(n)\" in \(a)") }
            }
        }
    }
}
