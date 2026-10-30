import Foundation

/// The details of a video stream that `MediaInfo` does not carry and the planner needs: codec tag (hev1 or hvc1), colour tags, HDR mastering
/// metadata, pixel aspect ratio, Dolby Vision. One cheap ffprobe call (first frame only); the parser is a pure function so it is table-tested.
/// Everything is optional: a missing ffprobe or an odd file just leaves the fields nil and the planner falls back to `MediaInfo`.
struct SmartVideoFacts: Equatable, Sendable {
    var codecTag: String?                // "hvc1", "hev1", "avc1", "dvh1", ...
    var pixelFormat: String?             // "yuv420p10le"
    var colorPrimaries: String?          // "bt709", "bt2020"
    var colorTransfer: String?           // "bt709", "smpte2084", "arib-std-b67"
    var colorSpace: String?              // "bt709", "bt2020nc"
    var colorRange: String?              // "tv", "pc"
    var sampleAspectRatio: String?       // "32:27"
    var fieldOrder: String?              // "progressive", "tt", ...
    /// x265 `master-display` string: `G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)` in 0.00002 / 0.0001 cd/m2 units.
    var masteringDisplay: String?
    /// x265 `max-cll` string: "maxContent,maxAverage".
    var maxCLL: String?
    /// Dolby Vision profile number when the stream carries a DOVI configuration record.
    var dolbyVisionProfile: Int?

    init() {}

    var hasHDRMetadata: Bool { masteringDisplay != nil || maxCLL != nil }
    /// Width / height of one pixel (1 when square or unknown).
    var pixelAspectRatio: Double {
        guard let s = sampleAspectRatio, s != "N/A", s != "0:1" else { return 1 }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "/" })
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 else { return 1 }
        return a / b
    }
    var isSquarePixels: Bool { abs(pixelAspectRatio - 1) < 0.005 }

    static func bitDepth(ofPixelFormat pix: String) -> Int? {
        let p = pix.lowercased()
        if p.isEmpty { return nil }
        if p.contains("p16") || p.contains("16le") || p.contains("16be") { return 16 }
        if p.contains("12le") || p.contains("12be") || p.hasPrefix("p012") { return 12 }
        if p.contains("10le") || p.contains("10be") || p.hasPrefix("p010") { return 10 }
        if p.contains("9le") || p.contains("9be") { return 9 }
        return 8
    }

    // MARK: Parsing

    /// Parses `ffprobe -print_format json -select_streams v:0 -show_streams-ish -show_frames -read_intervals %+#1` output.
    static func parse(json: Data) -> SmartVideoFacts {
        var f = SmartVideoFacts()
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return f }
        let stream = (root["streams"] as? [[String: Any]])?.first ?? [:]
        let frame = (root["frames"] as? [[String: Any]])?.first ?? [:]
        func str(_ key: String) -> String? {
            for d in [stream, frame] {
                if let s = d[key] as? String, !s.isEmpty, s != "unknown", s != "N/A", s != "unspecified" { return s }
            }
            return nil
        }
        if let tag = stream["codec_tag_string"] as? String, !tag.hasPrefix("["), tag != "0x0000" { f.codecTag = tag.lowercased() }
        f.pixelFormat = str("pix_fmt")
        f.colorPrimaries = str("color_primaries")
        f.colorTransfer = str("color_transfer")
        f.colorSpace = str("color_space")
        f.colorRange = str("color_range")
        f.sampleAspectRatio = str("sample_aspect_ratio")
        f.fieldOrder = (stream["field_order"] as? String).flatMap { $0 == "unknown" ? nil : $0 }
        let sideData = ((stream["side_data_list"] as? [[String: Any]]) ?? []) + ((frame["side_data_list"] as? [[String: Any]]) ?? [])
        for sd in sideData {
            let type = (sd["side_data_type"] as? String) ?? ""
            if type.hasPrefix("Mastering display"), f.masteringDisplay == nil { f.masteringDisplay = masteringString(sd) }
            if type.hasPrefix("Content light level"), f.maxCLL == nil,
               let c = (sd["max_content"] as? NSNumber)?.intValue, let a = (sd["max_average"] as? NSNumber)?.intValue { f.maxCLL = "\(c),\(a)" }
            if type.hasPrefix("DOVI"), let p = (sd["dv_profile"] as? NSNumber)?.intValue { f.dolbyVisionProfile = p }
        }
        return f
    }

    private static func rational(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        guard let s = any as? String else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
        return Double(s)
    }

    private static func masteringString(_ sd: [String: Any]) -> String? {
        guard let rx = rational(sd["red_x"]), let ry = rational(sd["red_y"]), let gx = rational(sd["green_x"]), let gy = rational(sd["green_y"]),
              let bx = rational(sd["blue_x"]), let by = rational(sd["blue_y"]), let wx = rational(sd["white_point_x"]), let wy = rational(sd["white_point_y"]),
              let maxL = rational(sd["max_luminance"]), let minL = rational(sd["min_luminance"]) else { return nil }
        func c(_ v: Double) -> Int { Int((v * 50_000).rounded()) }
        func l(_ v: Double) -> Int { Int((v * 10_000).rounded()) }
        return "G(\(c(gx)),\(c(gy)))B(\(c(bx)),\(c(by)))R(\(c(rx)),\(c(ry)))WP(\(c(wx)),\(c(wy)))L(\(l(maxL)),\(l(minL)))"
    }

    // MARK: Probing

    static let ffprobeArguments: [String] = [
        "-v", "error", "-print_format", "json", "-select_streams", "v:0", "-read_intervals", "%+#1",
        "-show_entries", "stream=codec_name,codec_tag_string,profile,pix_fmt,sample_aspect_ratio,field_order,color_range,color_space,color_transfer,color_primaries:stream_side_data_list",
        "-show_frames"
    ]

    /// Reads the facts of `url` with ffprobe. Never throws: any failure gives empty facts. Cancellation is honoured by the caller's task.
    static func read(url: URL, tools: ToolLocator = .shared, ctx: OperationContext? = nil) async -> SmartVideoFacts {
        guard let ffprobe = tools.url(.ffprobe) else { return SmartVideoFacts() }
        let args = ffprobeArguments + [url.path]
        let out: ProcessOutput?
        if let ctx {
            out = try? await ctx.runProcess(ffprobe, args, captureStdout: true, allowNonZeroExit: true)
        } else {
            out = try? await ProcessRunner.run(ffprobe, args, captureStdout: true, allowNonZeroExit: true)
        }
        guard let out else { return SmartVideoFacts() }
        return parse(json: Data(out.stdout.utf8))
    }
}

extension SmartVideoFacts {
    /// Colour description the planner works with: ffprobe facts first, then the `isHDR` flag of the stream (assume HDR10 when only the flag is known).
    func colorInfo(stream: MediaStreamInfo?) -> SmartColorInfo {
        var c = SmartColorInfo(primaries: colorPrimaries, transfer: colorTransfer, matrix: colorSpace, range: colorRange)
        if stream?.isHDR == true, !c.isHDR {
            c.transfer = "smpte2084"
            c.primaries = c.primaries ?? "bt2020"
            c.matrix = c.matrix ?? "bt2020nc"
        }
        return c
    }
}

/// Builds a `MediaInfo`-lite from Core's `SourceInfo` facts so the Studio summary (chips, estimate) can run the planner without probing again.
enum SmartSourceAdapter {
    static func mediaInfo(from source: SourceInfo) -> MediaInfo? {
        guard let vcodec = source.string("video.codec") else { return nil }
        var v = MediaStreamInfo(kind: .video, index: 0, codec: vcodec)
        v.profile = source.string("video.profile")
        v.width = source.int("video.width"); v.height = source.int("video.height")
        v.fps = source.number("video.fps")
        v.pixelFormat = source.string("video.pixfmt")
        v.bitDepth = source.int("video.bitdepth")
        v.rotation = source.int("video.rotation") ?? 0
        v.interlaced = source.bool("video.interlaced") ?? false
        v.isHDR = source.bool("video.hdr") ?? false
        var info = MediaInfo(url: source.url, container: source.string("container") ?? source.url.pathExtension, duration: source.duration,
                             bitRate: source.int("bitrate"), size: source.sizeBytes)
        info.streams = [v]
        let audioCount = source.int("audio.count") ?? 0
        for n in 0..<audioCount {
            var a = MediaStreamInfo(kind: .audio, index: 1 + n, codec: source.string("audio.\(n).codec") ?? "")
            a.channels = source.int("audio.\(n).channels"); a.sampleRate = source.int("audio.\(n).rate"); a.bitRate = source.int("audio.\(n).bitrate")
            a.language = source.string("audio.\(n).lang")
            info.streams.append(a)
        }
        let subCount = source.int("sub.count") ?? 0
        for n in 0..<subCount {
            info.streams.append(MediaStreamInfo(kind: .subtitle, index: 1 + audioCount + n, codec: source.string("sub.\(n).codec") ?? ""))
        }
        return info
    }
}
