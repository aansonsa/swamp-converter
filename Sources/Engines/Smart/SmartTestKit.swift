import Foundation
import AVFoundation

/// Helpers shared by the smart self-tests: fixtures generated with ffmpeg / lavfi (nothing is downloaded, everything lives in the test's temp folder),
/// independent read-back with ffprobe and AVFoundation, and planner input builders.
enum SK {
    // MARK: Planner inputs

    static func video(_ codec: String, _ w: Int = 1920, _ h: Int = 1080, pix: String? = "yuv420p", depth: Int? = nil, profile: String? = nil, fps: Double = 30,
                      hdr: Bool = false, rotation: Int = 0, interlaced: Bool = false, index: Int = 0) -> MediaStreamInfo {
        var s = MediaStreamInfo(kind: .video, index: index, codec: codec)
        s.width = w; s.height = h; s.fps = fps; s.pixelFormat = pix; s.profile = profile; s.rotation = rotation; s.interlaced = interlaced; s.isHDR = hdr
        s.bitDepth = depth ?? pix.flatMap { SmartVideoFacts.bitDepth(ofPixelFormat: $0) }
        return s
    }

    static func audio(_ codec: String, ch: Int = 2, index: Int, lang: String? = nil, isDefault: Bool = false) -> MediaStreamInfo {
        var s = MediaStreamInfo(kind: .audio, index: index, codec: codec)
        s.channels = ch; s.sampleRate = 48000; s.language = lang; s.isDefault = isDefault
        return s
    }

    static func sub(_ codec: String, index: Int) -> MediaStreamInfo { MediaStreamInfo(kind: .subtitle, index: index, codec: codec) }

    static func info(_ file: String, container: String? = nil, _ streams: [MediaStreamInfo], duration: Double = 10) -> MediaInfo {
        let ext = (file as NSString).pathExtension.lowercased()
        let c = container ?? (["mkv", "webm"].contains(ext) ? "matroska,webm" : (ext == "avi" ? "avi" : (ext == "ts" ? "mpegts" : "mov,mp4,m4a,3gp,3g2,mj2")))
        var m = MediaInfo(url: URL(fileURLWithPath: "/tmp/\(file)"), container: c, duration: duration, bitRate: 8_000_000, size: 10_000_000)
        m.streams = streams
        return m
    }

    /// Capabilities of a typical Apple-silicon Mac with Homebrew ffmpeg (x265 and x264 present, no zscale).
    static var fullCaps: SmartCapabilities {
        var c = SmartCapabilities()
        c.libx265 = true; c.libx264 = true; c.libmp3lame = true
        return c
    }

    static func plan(_ info: MediaInfo, _ mode: SmartMode = .bestForApple, caps: SmartCapabilities? = nil, facts: SmartVideoFacts = SmartVideoFacts(),
                     _ tweak: (inout SmartOptions) -> Void = { _ in }) -> TranscodePlan {
        var o = SmartOptions(mode: mode)
        tweak(&o)
        return TranscodePlanner.plan(probe: info, mode: mode, capabilities: caps ?? fullCaps, options: o, facts: facts)
    }

    static func hdr10Facts(tag: String? = nil) -> SmartVideoFacts {
        var f = SmartVideoFacts()
        f.colorPrimaries = "bt2020"; f.colorTransfer = "smpte2084"; f.colorSpace = "bt2020nc"; f.colorRange = "tv"; f.pixelFormat = "yuv420p10le"
        f.masteringDisplay = "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"; f.maxCLL = "1000,400"
        f.codecTag = tag
        return f
    }

    // MARK: Running tools

    static func ffmpegURL() throws -> URL { try ToolLocator.shared.require(.ffmpeg) }

    @discardableResult
    static func ffmpeg(_ args: [String], captureStdout: Bool = false) async throws -> ProcessOutput {
        try await ProcessRunner.run(try ffmpegURL(), ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + args, captureStdout: captureStdout)
    }

    static func ffprobeJSON(_ url: URL, _ extra: [String] = []) async -> [String: Any] {
        guard let ffprobe = ToolLocator.shared.url(.ffprobe),
              let out = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format"] + extra + [url.path],
                                                     captureStdout: true, allowNonZeroExit: true),
              let obj = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any] else { return [:] }
        return obj
    }

    static func streams(_ url: URL, _ type: String? = nil) async -> [[String: Any]] {
        let all = (await ffprobeJSON(url))["streams"] as? [[String: Any]] ?? []
        guard let type else { return all }
        return all.filter { ($0["codec_type"] as? String) == type }
    }

    static func formatTags(_ url: URL) async -> [String: Any] {
        ((await ffprobeJSON(url))["format"] as? [String: Any])?["tags"] as? [String: Any] ?? [:]
    }

    static func formatName(_ url: URL) async -> String {
        ((await ffprobeJSON(url))["format"] as? [String: Any])?["format_name"] as? String ?? ""
    }

    static func duration(_ url: URL) async -> Double {
        Double(((await ffprobeJSON(url))["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
    }

    static func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? ((d[k] as? NSNumber).map { "\($0)" } ?? "") }
    static func int(_ d: [String: Any], _ k: String) -> Int { (d[k] as? Int) ?? Int(str(d, k)) ?? 0 }

    /// Side data of the first frame (HDR mastering / light level) read straight from the bitstream or container.
    static func hasHDRSideData(_ url: URL) async -> (mastering: Bool, cll: Bool) {
        guard let ffprobe = ToolLocator.shared.url(.ffprobe),
              let out = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames",
                                                               "-show_entries", "frame=side_data_list", "-of", "json", url.path], captureStdout: true, allowNonZeroExit: true) else { return (false, false) }
        return (out.stdout.contains("Mastering display metadata"), out.stdout.contains("Content light level metadata"))
    }

    /// AVFoundation as the independent judge: playable, and the first frames decode.
    static func avfPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }

    // MARK: Fixtures

    /// lavfi test pattern + sine; `v` / `a` are the codec argument lists. 320x240, 24 fps by default.
    @discardableResult
    static func clip(_ fx: TestFixtures, _ name: String, size: String = "320x240", fps: Int = 24, seconds: Double = 2, filter: String = "", pixFmt: String? = nil,
                     video v: [String] = ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"], audio a: [String]? = ["-c:a", "aac"],
                     audioSource: String = "sine=frequency=440:sample_rate=48000", extra: [String] = []) async throws -> URL {
        let out = fx.url(name)
        var src = "testsrc2=size=\(size):rate=\(fps):duration=\(seconds)"
        if !filter.isEmpty { src += "," + filter }
        if let pixFmt { src += ",format=\(pixFmt)" }
        var args = ["-f", "lavfi", "-i", src]
        if a != nil { args += ["-f", "lavfi", "-t", "\(seconds)", "-i", audioSource] }
        args += v
        if let a { args += a }
        args += extra
        args.append(out.path)
        try await ffmpeg(args)
        return out
    }

    /// True when the media stack of the media-video module (MediaProbe, FFmpegCommand, FFmpegRunner) is wired up; otherwise the run tests SKIP.
    static func requireMediaStack(_ fx: TestFixtures) async throws {
        let probeFile = try await clip(fx, "stack-check.mp4", seconds: 0.5, audio: nil)
        do {
            _ = try await MediaProbe.probe(probeFile)
            let cmd = FFmpegCommand(inputs: [FFmpegInput(url: probeFile)], outputs: [FFmpegOutput(url: fx.url("stack-out.mp4"), options: ["-c", "copy"])])
            if cmd.arguments().filter({ $0 == "-i" }).isEmpty { try skipTest("FFmpegCommand.arguments() is not implemented yet (media-video module)") }
        } catch let e as ConversionError {
            if case .unsupported = e { try skipTest("the media-video module is not wired up yet") }
            throw e
        }
    }

    /// Runs the engine on `input` the way the wheel does: quick context of `smart.best`, mode and tweaks layered on top.
    @MainActor
    static func run(_ input: URL, mode: SmartMode = .bestForApple, caps: SmartCapabilities? = nil, rules: OutputRules = OutputRules(), base: String? = nil,
                    _ tweak: (inout SmartOptions) -> Void = { _ in }, ctxTweak: ((OperationContext) -> Void)? = nil) async throws -> SmartTranscodeResult {
        let op = SmartCatalog.operations()[0]
        let item = FileItem(url: input)
        let ctx = OperationContext.testing(op, items: [item], mode: .quick, rules: rules)
        ctxTweak?(ctx)
        var o = SmartOptions(mode: mode)
        tweak(&o)
        return try await SmartTranscoder.transcodeDetailed(input: item, options: o, ctx: ctx, progress: nil, base: base, capabilities: caps)
    }
}
