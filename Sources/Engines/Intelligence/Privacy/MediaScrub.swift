import Foundation

// Video and audio files: which personal tags are inside, and a stream-copied COPY without them.
//
// Route 1 (ffmpeg + ffprobe): `-c copy`, so picture and sound are never re-encoded. The selected tags are blanked one by one (`-metadata key=`), which keeps every
// group the person did not choose; "remove all" uses `-map_metadata -1` and drops chapters and cover art. `-fflags +bitexact` keeps ffmpeg from writing its own
// version string. Route 2 (no ffmpeg): AVAssetExportSession in passthrough mode with the "sharing" metadata filter (location, make / model, software, creation
// date) or an empty metadata list (everything); see `AVScrub`. The result is inspected again and the report says what really disappeared.

enum MediaScrub {
    // MARK: Tag classification (pure)

    /// A container tag -> the kind of personal data it reveals. nil = technical (brand, handler, language, durations ...).
    static func item(forTag key: String, value: String = "") -> ScrubReport.Item? {
        let k = key.lowercased()
        if k.hasPrefix("location") || k.contains("iso6709") || k.contains(".location") || k.hasPrefix("gps") || k == "xyz" || k == "©xyz" || k == "geo" { return .gps }
        if k.hasPrefix("com.apple.quicktime.camera.") {
            return k.hasSuffix("identifier") ? .serialNumber : (k.contains("lens") ? .lensModel : nil)
        }
        if k.contains("serial") { return .serialNumber }
        switch k {
        case "com.apple.quicktime.make", "make", "©mak": return .cameraMake
        case "com.apple.quicktime.model", "model", "©mod", "com.apple.quicktime.hardware.model": return .cameraModel
        case "com.apple.quicktime.software", "software", "tool", "©too", "encoded_by", "encodedby", "encoding_tool", "writing_application", "writingapp",
             "_statistics_writing_app", "com.android.version", "com.android.manufacturer", "com.android.model":
            if k == "com.android.manufacturer" { return .cameraMake }
            if k == "com.android.model" { return .cameraModel }
            return .software
        case "encoder":
            // The bare muxer name ("Lavf") that bit-exact mode leaves behind carries no version and nothing about the person.
            let v = value.trimmingCharacters(in: .whitespaces)
            return (v.isEmpty || v == "Lavf" || v == "Lavc") ? nil : .encoder
        case "creation_time", "date", "©day", "com.apple.quicktime.creationdate", "encoded_date", "tagged_date", "date_released", "originaldate", "year",
             "_statistics_writing_date_utc", "modification_time", "com.apple.quicktime.modificationdate": return .creationTime
        case "artist", "author", "album_artist", "composer", "performer", "copyright", "publisher", "writer", "creator", "©art", "©wrt", "cprt",
             "com.apple.quicktime.author", "com.apple.quicktime.artist", "com.apple.quicktime.copyright", "com.apple.quicktime.publisher": return .author
        case "title", "album", "show", "episode_id", "©nam", "©alb", "com.apple.quicktime.title", "com.apple.quicktime.displayname": return .title
        case "comment", "description", "synopsis", "lyrics", "keywords", "©cmt", "com.apple.quicktime.description", "com.apple.quicktime.keywords",
             "com.apple.quicktime.comment", "ldes": return .comment
        case "major_brand", "minor_version", "compatible_brands", "handler_name", "vendor_id", "language", "duration", "bps", "number_of_frames",
             "number_of_bytes", "_statistics_tags", "timecode", "reel_name", "encoder-eng", "bit_rate", "track", "disc", "genre", "compilation", "gapless_playback",
             "itunsmpb", "itunnorm", "rotate", "alpha_mode", "stereo_mode":
            return nil
        default: return .other
        }
    }

    // MARK: ffprobe

    struct Tag: Equatable { var key: String; var value: String }
    struct Stream { var index: Int; var type: String; var codec: String; var attachedPicture: Bool; var tags: [Tag] }
    struct Probe { var format: [Tag]; var streams: [Stream]; var hasChapters: Bool; var duration: Double? }

    static func probe(_ url: URL, tools: ToolLocator) -> Probe? {
        guard let ffprobe = tools.url(.ffprobe) else { return nil }
        let args = ["-v", "error", "-show_entries", "format=duration:format_tags:stream=index,codec_type,codec_name:stream_tags:stream_disposition=attached_pic:chapter=id",
                    "-of", "json", url.path]
        guard let text = SyncProcess.run(ffprobe, args, timeout: 30), let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func tags(_ d: [String: Any]?) -> [Tag] {
            ((d?["tags"] as? [String: Any]) ?? [:]).compactMap { k, v in
                let s = "\(v)".components(separatedBy: ";").first ?? "\(v)"
                return Tag(key: k, value: s)
            }.sorted { $0.key < $1.key }
        }
        let streams = ((json["streams"] as? [[String: Any]]) ?? []).map { s in
            Stream(index: (s["index"] as? Int) ?? 0, type: (s["codec_type"] as? String) ?? "", codec: (s["codec_name"] as? String) ?? "",
                   attachedPicture: ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1, tags: tags(s))
        }
        let format = json["format"] as? [String: Any]
        return Probe(format: tags(format), streams: streams, hasChapters: !((json["chapters"] as? [[String: Any]]) ?? []).isEmpty,
                     duration: (format?["duration"] as? String).flatMap(Double.init))
    }

    /// Items present in a probe result (stable order).
    static func items(in probe: Probe) -> [ScrubReport.Item] {
        var found = Set<ScrubReport.Item>()
        for t in probe.format { if let i = item(forTag: t.key, value: t.value) { found.insert(i) } }
        for s in probe.streams {
            for t in s.tags { if let i = item(forTag: t.key, value: t.value) { found.insert(i) } }
            if s.attachedPicture { found.insert(.thumbnail) }
        }
        return ScrubReport.Item.allCases.filter(found.contains)
    }

    // MARK: Inspect

    static func inspect(_ url: URL, tools: ToolLocator) async -> ScrubReport {
        if let p = probe(url, tools: tools) { return ScrubReport(removed: items(in: p)) }
        return await AVScrub.inspect(url)
    }

    // MARK: Scrub

    static func scrub(input: FileItem, output: URL, selection: ScrubSelection, allowFFmpeg: Bool, ctx: OperationContext, progress: ProgressSlice? = nil) async throws -> ScrubReport {
        let tools = ctx.tools
        guard allowFFmpeg, tools.has(.ffmpeg), let probe = probe(input.url, tools: tools) else {
            return try await AVScrub.scrub(input: input, output: output, selection: selection, ctx: ctx, progress: progress)
        }
        let before = items(in: probe)
        let args = try arguments(input: input.url, output: output, probe: probe, selection: selection)
        let total = probe.duration
        try await ctx.runTool(.ffmpeg, args, onStdoutLine: { line in
            guard let d = total, d > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress?.report(Swift.min(us / 1_000_000 / d, 1) * 0.95)
        })
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.noOutput }
        let after = items(in: Self.probe(output, tools: tools) ?? Probe(format: [], streams: [], hasChapters: false, duration: nil))
        return report(before: before, after: after, selection: selection, route: "ffmpeg")
    }

    /// removed = present before and gone after; residual = still there although selected.
    static func report(before: [ScrubReport.Item], after: [ScrubReport.Item], selection: ScrubSelection, route: String) -> ScrubReport {
        var r = ScrubReport()
        r.removed = before.filter { !after.contains($0) }
        r.residual = after.filter(selection.selects)
        r.kept = [route]
        return r
    }

    /// The ffmpeg command line (pure: tested without running anything).
    static func arguments(input: URL, output: URL, probe: Probe, selection: ScrubSelection) throws -> [String] {
        let ext = output.pathExtension.lowercased()
        let isMOVFamily = ["mp4", "mov", "m4v", "m4a", "m4b", "3gp", "3g2"].contains(ext)
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]

        // Streams: everything the person can see or hear; cover art goes with "remove all".
        var mapped: [Stream] = []
        for s in probe.streams {
            switch s.type {
            case "video": if !(s.attachedPicture && selection.everything) { mapped.append(s) }
            case "audio": mapped.append(s)
            case "subtitle":
                // MP4 / MOV can only carry text subtitles in their own format; anything else would make the copy fail.
                if !isMOVFamily || s.codec == "mov_text" { mapped.append(s) }
            default: break
            }
        }
        guard !mapped.isEmpty else { throw ConversionError.noOutput }
        for s in mapped { args += ["-map", "0:\(s.index)"] }
        args += ["-c", "copy", "-dn"]
        if isMOVFamily, mapped.contains(where: { $0.type == "subtitle" }) { args += ["-c:s", "mov_text"] }

        // Metadata.
        if selection.everything {
            args += ["-map_metadata", "-1", "-map_chapters", "-1"]
            for (outIndex, s) in mapped.enumerated() {
                if let lang = s.tags.first(where: { $0.key.lowercased() == "language" })?.value, lang != "und" { args += ["-metadata:s:\(outIndex)", "language=\(lang)"] }
            }
        } else {
            for t in probe.format where item(forTag: t.key, value: t.value).map(selection.selects) == true { args += ["-metadata", "\(t.key)="] }
            for (outIndex, s) in mapped.enumerated() {
                for t in s.tags where item(forTag: t.key, value: t.value).map(selection.selects) == true { args += ["-metadata:s:\(outIndex)", "\(t.key)="] }
            }
            // ffmpeg does not carry the creation time over by itself; the person who kept dates gets them back.
            if !selection.dates, let created = probe.format.first(where: { $0.key == "creation_time" }) { args += ["-metadata", "creation_time=\(created.value)"] }
        }
        if selection.device || selection.everything { args += ["-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"] }
        if isMOVFamily { args += ["-movflags", "+faststart" + (selection.everything ? "" : "+use_metadata_tags")] }
        args += ["-progress", "pipe:1", "-nostats", output.path]
        return args
    }
}
