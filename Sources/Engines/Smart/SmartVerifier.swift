import Foundation
import AVFoundation
import CoreMedia

struct SmartVerification: Equatable, Sendable {
    var isPlayable: Bool
    var readableFrames: Int
    var codecTag: String?
    var pixelFormat: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    var duration: Double?
    var hasAudio: Bool
    var problems: [String]
    var audioTracks = 0
    var subtitleTracks = 0
    var colorTransfer: String?
    /// "avfoundation" for MP4 / MOV, "ffprobe" for Matroska / WebM (AVFoundation cannot open those).
    var judge = "avfoundation"
    var passed: Bool { problems.isEmpty && isPlayable && readableFrames > 0 }
}

/// Proves that an output really plays on Apple software: `AVURLAsset.isPlayable`, an `AVAssetReader` that decodes frames at the start, the middle and the end
/// (not just the first), the expected codec tag (hvc1), pixel format, resolution, frame rate, duration, audio and subtitle tracks, HDR colour tags.
/// ffprobe supplies tag / pix_fmt / counts when installed; AVFoundation is the judge of playability. Matroska and WebM cannot be opened by
/// AVFoundation (fact 4 of spec/backends.md): they are judged by ffprobe frame reads instead.
enum SmartVerifier {
    static func verify(output: URL, against plan: TranscodePlan, source: MediaInfo, durationTolerance: Double = 0.5) async -> SmartVerification {
        var r = SmartVerification(isPlayable: false, readableFrames: 0, codecTag: nil, pixelFormat: nil, width: nil, height: nil, fps: nil, duration: nil,
                                  hasAudio: false, problems: [])
        guard FileManager.default.fileExists(atPath: output.path),
              ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            r.problems.append("the output file is missing or empty")
            return r
        }
        let facts = await SmartVideoFacts.read(url: output)
        let counts = await SmartStreamCounts.read(url: output)
        r.codecTag = facts.codecTag
        r.pixelFormat = facts.pixelFormat
        r.colorTransfer = facts.colorTransfer
        if let c = counts { r.audioTracks = c.audio; r.subtitleTracks = c.subtitle; r.hasAudio = c.audio > 0 }

        if SmartContainer.isQuickTimeFamily(plan.container) {
            r.judge = "avfoundation"
            await judgeWithAVFoundation(output, tenBit: plan.isTenBit || (SmartVideoFacts.bitDepth(ofPixelFormat: facts.pixelFormat ?? "") ?? 8) > 8, into: &r)
        } else {
            r.judge = "ffprobe"
            await judgeWithFFprobe(output, into: &r)
        }
        compare(plan: plan, source: source, facts: facts, durationTolerance: durationTolerance, into: &r)
        return r
    }

    // MARK: AVFoundation

    private static func judgeWithAVFoundation(_ url: URL, tenBit: Bool, into r: inout SmartVerification) async {
        let asset = AVURLAsset(url: url)
        r.isPlayable = (try? await asset.load(.isPlayable)) ?? false
        if !r.isPlayable { r.problems.append("AVFoundation says the file is not playable"); return }
        let duration = ((try? await asset.load(.duration))?.seconds).flatMap { $0.isFinite ? $0 : nil }
        r.duration = duration
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            r.problems.append("AVFoundation finds no video track"); return
        }
        if let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(t)
            r.width = Int(abs(rect.width).rounded()); r.height = Int(abs(rect.height).rounded())
        }
        if let f = try? await track.load(.nominalFrameRate), f > 0 { r.fps = Double(f) }
        if r.codecTag == nil, let fds = try? await track.load(.formatDescriptions), let fd = fds.first {
            r.codecTag = fourCC(CMFormatDescriptionGetMediaSubType(fd)).lowercased()
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio) {
            if r.audioTracks == 0 { r.audioTracks = audio.count }
            r.hasAudio = !audio.isEmpty
        }
        // Real decoding: a few frames at the start, in the middle and at the end.
        // The VIDEO track's own length places the windows: a subtitle or audio track can make the container longer than the picture.
        let videoSpan = ((try? await track.load(.timeRange))?.duration.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let total = min(videoSpan ?? duration ?? 0, duration ?? .infinity)
        let windows: [Double] = total > 2 ? [0, total / 2, max(0, total - 0.6)] : [0]
        var counts: [Int] = []
        for start in windows {
            let n = await Task.detached(priority: .utility) { readFrames(asset: asset, track: track, start: start, tenBit: tenBit, maxFrames: 6) }.value
            counts.append(n)
        }
        r.readableFrames = counts.reduce(0, +)
        for (i, n) in counts.enumerated() where n == 0 {
            r.problems.append("no frame could be decoded near \(String(format: "%.1f", windows[i])) s")
        }
    }

    /// Decodes up to `maxFrames` frames starting at `start`. Blocking: call from a background task.
    private static func readFrames(asset: AVAsset, track: AVAssetTrack, start: Double, tenBit: Bool, maxFrames: Int) -> Int {
        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600))
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return 0 }
        reader.add(out)
        guard reader.startReading() else { return 0 }
        var n = 0
        while n < maxFrames {
            let got: Bool = autoreleasepool {
                guard let sb = out.copyNextSampleBuffer() else { return false }
                if CMSampleBufferGetImageBuffer(sb) != nil { n += 1 }
                return true
            }
            if !got { break }
        }
        reader.cancelReading()
        return n
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: ffprobe (Matroska / WebM)

    private static func judgeWithFFprobe(_ url: URL, into r: inout SmartVerification) async {
        guard let ffprobe = ToolLocator.shared.url(.ffprobe) else {
            r.problems.append("ffprobe is needed to check this container"); return
        }
        func run(_ args: [String]) async -> String? {
            (try? await ProcessRunner.run(ffprobe, args, captureStdout: true, allowNonZeroExit: true))?.stdout
        }
        let info = await run(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate:format=duration", "-of", "json", url.path])
        if let data = info?.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let s = (obj["streams"] as? [[String: Any]])?.first {
                r.width = s["width"] as? Int; r.height = s["height"] as? Int
                if let f = s["avg_frame_rate"] as? String, let slash = f.firstIndex(of: "/"), let a = Double(f[f.startIndex..<slash]), let b = Double(f[f.index(after: slash)...]), b > 0 { r.fps = a / b }
            }
            if let d = (obj["format"] as? [String: Any])?["duration"] as? String { r.duration = Double(d) }
        }
        let total = r.duration ?? 0
        let starts: [Double] = total > 2 ? [0, total / 2, max(0, total - 0.6)] : [0]
        var frames = 0
        for t in starts {
            let text = await run(["-v", "error", "-select_streams", "v:0", "-read_intervals", "\(t)%+#6", "-show_entries", "frame=pts_time", "-of", "csv=p=0", url.path])
            let n = text?.split(whereSeparator: \.isNewline).count ?? 0
            frames += n
            if n == 0 { r.problems.append("no frame could be read near \(String(format: "%.1f", t)) s") }
        }
        r.readableFrames = frames
        r.isPlayable = frames > 0
    }

    // MARK: Expectations

    private static func compare(plan: TranscodePlan, source: MediaInfo, facts: SmartVideoFacts, durationTolerance: Double, into r: inout SmartVerification) {
        // Codec tag.
        if let expected = plan.videoTag, let tag = r.codecTag, tag != expected { r.problems.append("codec tag is \(tag), expected \(expected)") }
        if plan.videoTag == nil, plan.video == .copy, SmartCodec.video(source.videoStreams.first?.codec) == "h264", let tag = r.codecTag,
           SmartContainer.isQuickTimeFamily(plan.container), tag != "avc1", tag != "avc3" {
            r.problems.append("codec tag is \(tag), expected avc1")
        }
        // Pixel format (10-bit stays 10-bit, 8-bit stays 8-bit).
        if let want = plan.pixelFormat, let got = r.pixelFormat {
            let a = SmartVideoFacts.bitDepth(ofPixelFormat: want) ?? 8, b = SmartVideoFacts.bitDepth(ofPixelFormat: got) ?? 8
            if a != b { r.problems.append("pixel format is \(got), expected \(want)") }
        }
        // Size.
        if let w = plan.targetWidth, let h = plan.targetHeight, let gw = r.width, let gh = r.height, abs(gw - w) > 1 || abs(gh - h) > 1 {
            r.problems.append("size is \(gw)x\(gh), expected \(w)x\(h)")
        }
        // Frame rate: within 5 percent (variable frame rate sources only have an average).
        if let want = plan.sourceFPS, want > 1, let got = r.fps, got > 1, abs(got - want) / want > 0.05 {
            r.problems.append("frame rate is \(String(format: "%.2f", got)), expected \(String(format: "%.2f", want)) fps")
        }
        // Duration.
        if let want = plan.sourceDuration, want > 0, let got = r.duration, abs(got - want) > durationTolerance {
            r.problems.append("duration is \(String(format: "%.2f", got)) s, expected \(String(format: "%.2f", want)) s")
        }
        // Audio.
        if !plan.audio.isEmpty, r.audioTracks < plan.audio.count {
            r.problems.append("expected \(plan.audio.count) audio track(s), found \(r.audioTracks)")
        }
        // Subtitles.
        if !plan.subtitleStreamIndexes.isEmpty, r.subtitleTracks < plan.subtitleStreamIndexes.count, r.subtitleTracks >= 0 {
            r.problems.append("expected \(plan.subtitleStreamIndexes.count) subtitle track(s), found \(r.subtitleTracks)")
        }
        // HDR tags.
        if plan.isHDR, let want = plan.color.transfer, let got = r.colorTransfer, got != want {
            r.problems.append("HDR transfer is \(got), expected \(want)")
        }
    }
}

/// Number of streams per type, one cheap ffprobe call.
struct SmartStreamCounts: Equatable, Sendable {
    var video = 0, audio = 0, subtitle = 0

    static func parse(json: Data) -> SmartStreamCounts? {
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], let streams = obj["streams"] as? [[String: Any]] else { return nil }
        var c = SmartStreamCounts()
        for s in streams {
            switch s["codec_type"] as? String {
            case "video": if (s["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 { c.video += 1 }
            case "audio": c.audio += 1
            case "subtitle": c.subtitle += 1
            default: break
            }
        }
        return c
    }

    static func read(url: URL) async -> SmartStreamCounts? {
        guard let ffprobe = ToolLocator.shared.url(.ffprobe),
              let out = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type:stream_disposition=attached_pic", "-of", "json", url.path],
                                                     captureStdout: true, allowNonZeroExit: true) else { return nil }
        return parse(json: Data(out.stdout.utf8))
    }
}
