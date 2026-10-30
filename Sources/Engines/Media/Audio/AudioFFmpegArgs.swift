import Foundation

// The ffmpeg command line of one audio encode. PURE: every field of the schema that ffmpeg realises shows up here as a visible argument,
// which is what the golden-argv self-tests assert. Arguments are always an array (no shell). Fixed prefix per the backends spec:
// -hide_banner -nostdin -y -nostats -progress pipe:1, and `-fps_mode` is never needed for audio.

/// What pass 1 measured (loudnorm) or computed (peak gain).
struct AudMeasurement: Equatable, Sendable {
    var inputI = 0.0, inputTP = 0.0, inputLRA = 0.0, inputThresh = 0.0, offset = 0.0
    /// Gain in dB that brings the (already filtered) signal to the peak target.
    var peakGainDB: Double? = nil
}

struct AudFFmpegJob: Sendable {
    var input: URL
    var output: URL
    var plan: AudPlan
    var info: AudInfo?
    var env: AudEnvironment
    /// A prepared JPEG for the second input (replace, or keep + scale). Nil: copy the source's own picture (keep) or none.
    var coverInput: URL? = nil
    var measurement: AudMeasurement? = nil
    /// Overrides the plan's bit rate (size-limit retries).
    var kbpsOverride: Int? = nil

    var kbps: Int { kbpsOverride ?? plan.kbps }
}

enum AudFFmpegArgs {
    static let prefix = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"]

    /// Targets that can carry a picture.
    static func supportsCover(_ t: AudTarget) -> Bool { t == .mp3 || t.isMP4Family || t == .flac }

    static func num(_ x: Double) -> String {
        let s = String(format: "%.3f", x)
        return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    // MARK: Whole command

    static func transcode(_ job: AudFFmpegJob) -> [String] {
        let plan = job.plan
        var a = prefix
        a += inputOptions(plan)
        a += ["-i", job.input.path]
        if let cover = job.coverInput { a += ["-i", cover.path] }
        a += ["-map", "0:a:0"]
        var coverMapped = false
        if supportsCover(plan.target) {
            if job.coverInput != nil { a += ["-map", "1:v:0"]; coverMapped = true }
            else if plan.coverMode == .keep, job.info?.hasCover == true { a += ["-map", "0:v:0?"]; coverMapped = true }
        }
        if plan.trimCopy {
            a += ["-c:a", "copy"]
        } else {
            let filters = filterChain(job)
            if !filters.isEmpty { a += ["-af", filters.joined(separator: ",")] }
            a += codecArguments(job)
            if let r = outputRate(job) { a += ["-ar", String(r)] }
            if let c = plan.channels { a += ["-ac", String(c)] }
        }
        if coverMapped {
            a += ["-c:v", "copy", "-disposition:v", "attached_pic"]
            if plan.target == .mp3 { a += ["-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"] }
        }
        a += metadataArguments(plan)
        if plan.target == .mp3 { a += ["-id3v2_version", String(plan.id3Version)] }
        a += ["-f", plan.target.muxer, job.output.path]
        return a
    }

    /// Pass 1 of two-pass normalisation: the same trim and filters up to the normaliser, then the analyser, output to nowhere.
    static func measurement(_ job: AudFFmpegJob) -> [String] {
        var j = job
        j.measurement = nil
        var a = prefix
        a += inputOptions(job.plan)
        a += ["-i", job.input.path, "-map", "0:a:0"]
        var filters = preNormFilters(j)
        guard let norm = job.plan.norm else { return a + ["-f", "null", "-"] }
        switch norm.kind {
        case .peak: filters.append("volumedetect")
        case .loudness: filters.append("loudnorm=I=\(num(norm.level)):TP=\(num(norm.truePeak)):LRA=\(num(norm.lra)):print_format=json")
        }
        a += ["-af", filters.joined(separator: ","), "-f", "null", "-"]
        return a
    }

    // MARK: Pieces

    /// `-ss` / `-t` as INPUT options: exact when transcoding, keyframe-snapped with `-c copy`.
    static func inputOptions(_ plan: AudPlan) -> [String] {
        var o: [String] = []
        if plan.trimStart > 0 { o += ["-ss", num(plan.trimStart)] }
        if let end = plan.trimEnd { o += ["-t", num(end - plan.trimStart)] }
        return o
    }

    /// Filters before the normaliser (shared with the measurement pass).
    static func preNormFilters(_ job: AudFFmpegJob) -> [String] {
        let plan = job.plan
        var f: [String] = []
        if plan.silenceTrim {
            let t = "\(num(plan.silenceDB))dB"
            f.append("silenceremove=start_periods=1:start_threshold=\(t):detection=peak,areverse,silenceremove=start_periods=1:start_threshold=\(t):detection=peak,areverse")
        }
        if plan.highpass > 0 { f.append("highpass=f=\(plan.highpass)") }
        switch plan.eq {
        case "bass": f.append("bass=g=5")
        case "treble": f.append("treble=g=4")
        case "voice": f += ["highpass=f=80", "equalizer=f=3000:t=q:w=1:g=3"]
        default: break
        }
        if plan.speed != 1 { f += tempoFilters(plan.speed) }
        if plan.gainDB != 0 { f.append("volume=\(num(plan.gainDB))dB") }
        return f
    }

    /// `atempo` accepts 0.5 ... 2.0 per instance; chain for anything outside.
    static func tempoFilters(_ speed: Double) -> [String] {
        var s = speed
        var out: [String] = []
        while s > 2.0 { out.append("atempo=2"); s /= 2.0 }
        while s < 0.5 { out.append("atempo=0.5"); s /= 0.5 }
        out.append("atempo=\(num(s))")
        return out
    }

    static func filterChain(_ job: AudFFmpegJob) -> [String] {
        let plan = job.plan
        var f = preNormFilters(job)
        if let norm = plan.norm {
            switch norm.kind {
            case .peak:
                if let g = job.measurement?.peakGainDB, abs(g) > 0.0001 { f.append("volume=\(num(g))dB") }
            case .loudness:
                var l = "loudnorm=I=\(num(norm.level)):TP=\(num(norm.truePeak)):LRA=\(num(norm.lra))"
                if norm.twoPass, let m = job.measurement {
                    l += ":measured_I=\(num(m.inputI)):measured_TP=\(num(m.inputTP)):measured_LRA=\(num(m.inputLRA)):measured_thresh=\(num(m.inputThresh)):offset=\(num(m.offset)):linear=true"
                }
                f.append(l)
            }
        }
        let out = plan.outputDuration(sourceDuration: job.info?.duration)
        if plan.fadeIn > 0 { f.append("afade=t=in:st=0:d=\(num(plan.fadeIn))") }
        if plan.fadeOut > 0, let d = out, d > plan.fadeOut { f.append("afade=t=out:st=\(num(d - plan.fadeOut)):d=\(num(plan.fadeOut))") }
        else if plan.fadeOut > 0, out != nil { f.append("afade=t=out:st=0:d=\(num(out ?? plan.fadeOut))") }
        if plan.limiter { f.append("alimiter=limit=0.89:level=false") }
        if let d = ditherFilter(job, hasFilters: !f.isEmpty) { f.append(d) }
        return f
    }

    /// The reduction to 16 bits, done explicitly: through DOUBLE precision, so that it rounds and dithers without bias (measured with ffmpeg 9: its integer
    /// shift, its float to 16-bit paths and its dithered float paths all truncate, a constant -0.5 step of error; only the double path is clean). Nil when nothing is reduced (16-bit lossless in, no filters in between) or the target is not 16-bit PCM-like.
    static func ditherFilter(_ job: AudFFmpegJob, hasFilters: Bool) -> String? {
        let p = job.plan
        guard [.wav, .aiff, .caf, .flac, .alac].contains(p.target), resolvedDepth(p.bitDepth, job.info) == 16 else { return nil }
        let untouched = job.info.map { $0.isLossless && !$0.isFloat && ($0.bitDepth ?? 16) <= 16 } ?? false
        if untouched && !hasFilters && p.sampleRate == nil && (p.channels == nil || p.channels! >= (job.info?.channels ?? 0)) { return nil }
        return "aformat=sample_fmts=dblp,aresample=osf=\(p.target == .alac ? "s16p" : "s16")" + (p.dither == .none ? "" : ":dither_method=\(p.dither.rawValue)")
    }

    /// loudnorm upsamples to 192 kHz: always pin the rate when it runs.
    static func outputRate(_ job: AudFFmpegJob) -> Int? {
        if let r = job.plan.sampleRate { return r }
        guard job.plan.norm?.kind == .loudness, let source = job.info?.sampleRate else { return nil }
        return AudRates.effective(requested: nil, source: source, target: job.plan.target) ?? source
    }

    static func codecArguments(_ job: AudFFmpegJob) -> [String] {
        let p = job.plan
        let kbps = job.kbps
        let fit = p.fitBytes != nil
        switch p.target {
        case .mp3:
            var a = ["-c:a", "libmp3lame"]
            if p.useQuality { a += ["-q:a", String(AudQuality.mp3V(p.quality))] }
            else { if fit { a += ["-abr", "1"] }; a += ["-b:a", "\(kbps)k"] }
            a += ["-joint_stereo", p.mp3Joint ? "1" : "0"]
            return a
        case .aac, .m4b, .m4r:
            if job.env.hasAACAudioToolbox {
                if p.useQuality { return ["-c:a", "aac_at", "-aac_at_mode", "vbr", "-q:a", String(AudQuality.aacAtQ(p.quality))] }
                return ["-c:a", "aac_at"] + (fit ? ["-aac_at_mode", "abr"] : []) + ["-b:a", "\(kbps)k"]
            }
            let k = p.useQuality ? AudQuality.approxKbps(target: p.target, quality: p.quality) : kbps
            return ["-c:a", "aac", "-b:a", "\(k)k"]
        case .alac:
            var a = ["-c:a", "alac"]
            switch resolvedDepth(p.bitDepth, job.info) { case 16: a += ["-sample_fmt", "s16p"]; default: a += ["-sample_fmt", "s32p", "-bits_per_raw_sample", "24"] }
            return a
        case .flac:
            var a = ["-c:a", "flac", "-compression_level", String(p.flacLevel)]
            switch resolvedDepth(p.bitDepth, job.info) { case 16: a += ["-sample_fmt", "s16"]; default: a += ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"] }
            return a
        case .wav, .caf:
            let depth = resolvedDepth(p.bitDepth, job.info)
            return ["-c:a", depth == 32 ? "pcm_f32le" : (depth == 24 ? "pcm_s24le" : "pcm_s16le")]
        case .aiff:
            let depth = resolvedDepth(p.bitDepth, job.info)
            return ["-c:a", depth >= 24 ? "pcm_s24be" : "pcm_s16be"]
        case .opus:
            return ["-c:a", "libopus", "-b:a", "\(kbps)k", "-application", p.opusApplication, "-vbr", p.opusVBR]
        case .ogg:
            if p.useQuality { return ["-c:a", "libvorbis", "-q:a", num(AudQuality.vorbisQ(p.quality))] }
            return ["-c:a", "libvorbis", "-b:a", "\(kbps)k"]
        case .ac3: return ["-c:a", "ac3", "-b:a", "\(kbps)k"]
        case .eac3: return ["-c:a", "eac3", "-b:a", "\(kbps)k"]
        case .auto, .same: return []
        }
    }

    /// 16, 24 or 32 (float). "Keep" follows the source: floats stay floats, 24/32-bit integers become 24, everything else (lossy included) 16.
    static func resolvedDepth(_ d: AudBitDepth, _ info: AudInfo?) -> Int {
        switch d {
        case .i16: return 16
        case .i24: return 24
        case .f32: return 32
        case .keep:
            guard let info else { return 16 }
            if info.isFloat && info.isLossless { return 32 }
            if let b = info.bitDepth, b >= 24, info.isLossless { return 24 }
            return 16
        }
    }

    static func metadataArguments(_ plan: AudPlan) -> [String] {
        var a: [String] = []
        switch plan.tagsMode {
        case .strip:
            a += ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact"]
        case .keep, .custom:
            break
        }
        for (_, name) in AudioKeys.tagFields {
            guard let value = plan.tagEdits[name], name != "trackTotal" else { continue }
            let key: String
            switch name {
            case "albumArtist": key = "album_artist"
            case "year": key = "date"
            default: key = name
            }
            if name == "track" {
                let total = plan.tagEdits["trackTotal"]
                a += ["-metadata", "track=\(total.map { "\(value)/\($0)" } ?? value)"]
            } else {
                a += ["-metadata", "\(key)=\(value)"]
            }
        }
        if plan.tagEdits["track"] == nil, let total = plan.tagEdits["trackTotal"] { a += ["-metadata", "track=/\(total)"] }
        return a
    }

    // MARK: Parsing

    /// The JSON block loudnorm prints at the end of pass 1.
    static func parseLoudnorm(_ lines: [String]) -> AudMeasurement? {
        let text = lines.joined(separator: "\n")
        guard let open = text.lastIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func d(_ k: String) -> Double? { (json[k] as? String).flatMap(Double.init) ?? (json[k] as? Double) }
        guard let i = d("input_i"), let tp = d("input_tp"), let lra = d("input_lra"), let th = d("input_thresh"), let off = d("target_offset"),
              i.isFinite, tp.isFinite else { return nil }
        return AudMeasurement(inputI: i, inputTP: tp, inputLRA: lra, inputThresh: th, offset: off)
    }

    /// `max_volume: -6.0 dB` of volumedetect.
    static func parseMaxVolume(_ lines: [String]) -> Double? {
        for l in lines.reversed() {
            if let r = l.range(of: "max_volume:") {
                let rest = l[r.upperBound...].replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
                if let v = Double(rest) { return v }
            }
        }
        return nil
    }

    /// `out_time_us=1234567` of `-progress pipe:1`.
    static func parseProgressSeconds(_ line: String) -> Double? {
        guard line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return nil }
        guard let v = Double(line.split(separator: "=", maxSplits: 1).last ?? "") else { return nil }
        return v / 1_000_000
    }
}
