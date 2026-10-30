import Foundation

// ffprobe back end of MediaProbe: `-print_format json -show_format -show_streams -show_chapters`, parsed leniently
// (every field may be missing or "N/A"; numbers arrive as strings).

extension MediaProbe {
    static func probeWithFFprobe(_ url: URL, ffprobe: URL) async throws -> MediaInfo? {
        let args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", "-i", FFmpegCommand.safePath(url)]
        let out = try await ProcessRunner.run(ffprobe, args, captureStdout: true, maxCapturedBytes: 32_000_000, toolName: "ffprobe", allowNonZeroExit: true)
        guard let data = out.stdout.data(using: .utf8), !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseFFprobe(root, url: url)
    }

    /// Pure: ffprobe's JSON document -> MediaInfo (unit-tested with fixtures).
    static func parseFFprobe(_ root: [String: Any], url: URL) -> MediaInfo? {
        let format = root["format"] as? [String: Any] ?? [:]
        let rawStreams = root["streams"] as? [[String: Any]] ?? []
        guard !rawStreams.isEmpty || !format.isEmpty else { return nil }
        let formatName = format["format_name"] as? String ?? ""
        var info = MediaInfo(url: url, container: containerKey(formatName: formatName, url: url))
        info.formatName = formatName
        info.duration = number(format["duration"]).flatMap { $0 > 0 ? $0 : nil }
        info.bitRate = number(format["bit_rate"]).map { Int($0) }
        info.size = number(format["size"]).map { Int64($0) }
        info.tags = lowercasedTags(format["tags"] as? [String: Any])

        for s in rawStreams {
            guard let type = s["codec_type"] as? String else { continue }
            let kind: MediaStreamKind
            switch type {
            case "video": kind = .video
            case "audio": kind = .audio
            case "subtitle": kind = .subtitle
            case "attachment": kind = .attachment
            default: kind = .data
            }
            var st = MediaStreamInfo(kind: kind, index: (s["index"] as? Int) ?? info.streams.count, codec: (s["codec_name"] as? String) ?? "unknown")
            st.profile = s["profile"] as? String
            st.codecTag = (s["codec_tag_string"] as? String).flatMap { $0.hasPrefix("[") || $0 == "0x0000" ? nil : $0 }
            let tags = lowercasedTags(s["tags"] as? [String: Any])
            st.language = tags["language"].flatMap { $0 == "und" ? nil : $0 }
            st.title = tags["title"]
            if let disp = s["disposition"] as? [String: Any] {
                st.isDefault = (disp["default"] as? Int ?? 0) == 1
                st.isForced = (disp["forced"] as? Int ?? 0) == 1
                st.isAttachedPicture = (disp["attached_pic"] as? Int ?? 0) == 1
            }
            st.bitRate = number(s["bit_rate"]).map { Int($0) }
            st.frameCount = number(s["nb_frames"]).map { Int($0) }
            switch kind {
            case .video:
                st.width = s["width"] as? Int
                st.height = s["height"] as? Int
                let avg = fraction(s["avg_frame_rate"]), base = fraction(s["r_frame_rate"])
                st.fps = avg ?? base
                st.maxFps = base ?? avg
                if let a = avg, let b = base, b > 0, abs(a - b) / b > 0.03, !st.isAttachedPicture { st.isVFR = true }
                st.pixelFormat = s["pix_fmt"] as? String
                st.bitDepth = bitDepth(pixFmt: st.pixelFormat, rawBits: number(s["bits_per_raw_sample"]).map { Int($0) })
                st.fieldOrder = s["field_order"] as? String
                st.interlaced = ["tt", "bb", "tb", "bt"].contains(st.fieldOrder ?? "")
                st.colorPrimaries = s["color_primaries"] as? String
                st.colorTransfer = s["color_transfer"] as? String
                st.colorSpace = s["color_space"] as? String
                st.colorRange = s["color_range"] as? String
                st.isHDR = ["smpte2084", "arib-std-b67"].contains(st.colorTransfer ?? "")
                st.level = s["level"] as? Int
                if let sar = ratio(s["sample_aspect_ratio"]), sar > 0 { st.sar = sar }
                st.rotation = rotation(sideData: s["side_data_list"] as? [[String: Any]], tags: tags)
            case .audio:
                st.channels = s["channels"] as? Int
                st.channelLayout = s["channel_layout"] as? String
                st.sampleRate = number(s["sample_rate"]).map { Int($0) }
                st.bitDepth = number(s["bits_per_raw_sample"]).map { Int($0) } ?? number(s["bits_per_sample"]).flatMap { $0 > 0 ? Int($0) : nil }
            default: break
            }
            info.streams.append(st)
        }
        for c in root["chapters"] as? [[String: Any]] ?? [] {
            let t = lowercasedTags(c["tags"] as? [String: Any])
            guard let a = number(c["start_time"]), let b = number(c["end_time"]) else { continue }
            info.chapters.append(MediaChapterInfo(start: a, end: b, title: t["title"] ?? ""))
        }
        // An audio-only or unreadable result without any stream is not a media file.
        if info.streams.isEmpty && info.duration == nil { return nil }
        return info
    }

    // MARK: Helpers

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// "30000/1001" -> 29.97; "0/0" -> nil.
    static func fraction(_ v: Any?) -> Double? {
        guard let s = v as? String else { return number(v) }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b != 0, a != 0 { return a / b }
        if p.count == 1, let a = Double(p[0]), a > 0 { return a }
        return nil
    }

    /// "64:45" -> 1.422.
    static func ratio(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        let p = s.split(separator: ":")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b != 0, a != 0 { return a / b }
        return nil
    }

    static func lowercasedTags(_ t: [String: Any]?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in t ?? [:] { if let s = v as? String { out[k.lowercased()] = s } }
        return out
    }

    /// Bits per component from the pixel format name: yuv420p10le -> 10, p010le -> 10, nv12 -> 8, gray12le -> 12, rgb48 -> 16.
    static func bitDepth(pixFmt: String?, rawBits: Int?) -> Int? {
        if let r = rawBits, r > 0 { return r }
        guard let p = pixFmt else { return nil }
        if let m = p.range(of: #"(\d+)(le|be)$"#, options: .regularExpression) {
            let digits = p[m].prefix { $0.isNumber }
            if let n = Int(digits), [9, 10, 12, 14, 16].contains(n) { return n }
        }
        if p.hasPrefix("p010") { return 10 }
        if p.hasPrefix("p012") { return 12 }
        if p.hasPrefix("p016") { return 16 }
        if p.hasPrefix("rgb48") || p.hasPrefix("bgr48") { return 16 }
        return 8
    }

    /// Clockwise rotation (0/90/180/270) from a display matrix. ffprobe reports the counter-clockwise angle to apply (-90 = rotate 90 clockwise).
    static func rotation(sideData: [[String: Any]]?, tags: [String: String]) -> Int {
        var degrees: Double?
        for sd in sideData ?? [] {
            if (sd["side_data_type"] as? String) == "Display Matrix", let r = number(sd["rotation"]) { degrees = -r }
        }
        if degrees == nil, let r = tags["rotate"].flatMap(Double.init) { degrees = r }
        guard let d = degrees else { return 0 }
        var n = Int(d.rounded()) % 360
        if n < 0 { n += 360 }
        return [0, 90, 180, 270].min(by: { abs($0 - n) < abs($1 - n) }) ?? 0
    }

    /// Normalised container key for UI and rules: mp4, mov, mkv, webm, avi, gif, ts, flv, wmv, mpg, ogv, 3gp ...
    static func containerKey(formatName: String, url: URL) -> String {
        let names = formatName.split(separator: ",").map(String.init)
        let ext = Formats.key(of: url)
        if names.contains("matroska") { return ext == "webm" ? "webm" : "mkv" }
        if names.contains("mov") || names.contains("mp4") {
            if ["mp4", "mov", "3gp", "3g2"].contains(ext) { return ext }
            if ext == "m4a" || ext == "m4b" { return "mp4" }
            return names.contains("mp4") && !names.contains("mov") ? "mp4" : "mov"
        }
        if names.contains("avi") { return "avi" }
        if names.contains("gif") { return "gif" }
        if names.contains("mpegts") { return "ts" }
        if names.contains("flv") { return "flv" }
        if names.contains("asf") { return "wmv" }
        if names.contains("ogg") { return ext.isEmpty ? "ogg" : ext }
        if names.contains("mpeg") { return "mpg" }
        return ext.isEmpty ? (names.first ?? "") : ext
    }
}
