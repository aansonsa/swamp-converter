import Foundation

/// plan -> one `FFmpegCommand`. Pure: no I/O, golden-tested (`SmartTests`). Arguments are an array, never a shell string.
///
/// Shape of the output options, in this order (every part exists only when it applies):
///   -map 0:V -map 0:A... -map 0:S...         explicit stream selection (cover art, data and attachment streams are left out)
///   -map_metadata -1 ...                    metadata strip (language tags are re-applied)
///   -c:v <encoder + quality + profile + pix_fmt + tag + colour tags>   or  -c:v copy [-tag:v hvc1]
///   -c:a:N copy | aac_at -b:a:N 256k | alac [-ac:a:N 6]
///   -c:s mov_text | copy
///   -movflags +faststart
enum SmartCommandBuilder {
    static func command(for plan: TranscodePlan, input: URL, output: URL, capabilities: SmartCapabilities = .current) -> FFmpegCommand {
        var cmd = FFmpegCommand()
        cmd.inputs = [FFmpegInput(url: input, options: plan.inputOptions)]
        cmd.videoFilters = plan.video == .copy ? [] : plan.videoFilters
        cmd.outputs = [FFmpegOutput(url: output, options: outputOptions(plan, capabilities: capabilities))]
        return cmd
    }

    static func outputOptions(_ plan: TranscodePlan, capabilities: SmartCapabilities) -> [String] {
        var o: [String] = []
        // Streams.
        if let v = plan.videoStreamIndex { o += ["-map", "0:\(v)"] }
        for a in plan.audioStreamIndexes { o += ["-map", "0:\(a)"] }
        for s in plan.subtitleStreamIndexes { o += ["-map", "0:\(s)"] }
        // Metadata.
        if plan.stripMetadata {
            o += ["-map_metadata", "-1", "-map_metadata:s:v", "-1", "-fflags", "+bitexact"]
            for (i, lang) in plan.audioLanguages.enumerated() {
                if let lang, !lang.isEmpty, lang != "und" { o += ["-metadata:s:a:\(i)", "language=\(lang)"] }
            }
        }
        // Video.
        o += videoOptions(plan)
        // Audio.
        let aacName = capabilities.aacAudioToolbox ? "aac_at" : "aac"
        for (i, action) in plan.audio.enumerated() {
            switch action {
            case .copy: o += ["-c:a:\(i)", "copy"]
            case .aac(let kbps): o += ["-c:a:\(i)", aacName, "-b:a:\(i)", "\(kbps)k"]
            case .alac: o += ["-c:a:\(i)", "alac"]
            }
            if i < plan.audioChannels.count, let ch = plan.audioChannels[i] { o += ["-ac:a:\(i)", "\(ch)"] }
        }
        // Subtitles.
        if !plan.subtitleStreamIndexes.isEmpty, let codec = plan.subtitleCodec { o += ["-c:s", codec] }
        // Container.
        if plan.faststart && SmartContainer.isQuickTimeFamily(plan.container) { o += ["-movflags", "+faststart"] }
        o += ["-max_muxing_queue_size", "4096"]
        return o
    }

    static func videoOptions(_ plan: TranscodePlan) -> [String] {
        var o: [String] = []
        switch plan.video {
        case .copy:
            o += ["-c:v", "copy"]
            if let tag = plan.videoTag { o += ["-tag:v", tag] }
            o += ["-avoid_negative_ts", "make_zero"]
        case .hevc(let encoder, _), .h264(let encoder):
            o += ["-c:v", encoder]
            let q = plan.qualityValue ?? 65
            if encoder.hasSuffix("_videotoolbox") {
                o += ["-q:v", fmt(q)]
                if let profile = plan.videoProfile { o += ["-profile:v", profile] }
                o += ["-g", "\(keyframeInterval(fps: plan.sourceFPS))"]
            } else {
                if let preset = plan.encoderPreset { o += ["-preset", preset] }
                o += ["-crf", fmt(q)]
                if let profile = plan.videoProfile { o += ["-profile:v", profile] }
            }
            if let pix = plan.pixelFormat { o += ["-pix_fmt", pix] }
            if let tag = plan.videoTag { o += ["-tag:v", tag] }
            o += colorOptions(plan.color)
            if encoder == "libx265" { o += ["-x265-params", x265Params(plan)] }
            o += ["-fps_mode", "vfr"]
        }
        return o
    }

    static func colorOptions(_ c: SmartColorInfo) -> [String] {
        var o: [String] = []
        if let v = c.primaries { o += ["-color_primaries", v] }
        if let v = c.transfer { o += ["-color_trc", v] }
        if let v = c.matrix { o += ["-colorspace", v] }
        if let v = c.range { o += ["-color_range", v] }
        return o
    }

    static func x265Params(_ plan: TranscodePlan) -> String {
        var p = ["log-level=error"]
        if plan.isHDR {
            p += ["hdr10=1", "hdr10-opt=1", "repeat-headers=1"]
            if let m = plan.masteringDisplay { p.append("master-display=\(m)") }
            if let c = plan.maxCLL { p.append("max-cll=\(c)") }
        }
        return p.joined(separator: ":")
    }

    /// About two seconds between key frames (hardware encoders default to a very short interval that inflates the file).
    static func keyframeInterval(fps: Double?) -> Int {
        let f = (fps ?? 30)
        guard f.isFinite, f > 0 else { return 60 }
        return Util.clamp(Int((f * 2).rounded()), 24, 240)
    }

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}
