import Foundation

// What the Studio asks of the video engine besides running it: the source record turned back into a MediaInfo (so the planner can run without
// probing again), the numeric cross-field messages (spec/handbrake.md 2.13), and the bridge from video options to the audio engine's options.

enum VideoSourceBridge {
    /// MediaInfo-lite from the facts a `SourceInfo` carries. Nil when the record has no video facts at all.
    static func mediaInfo(from s: SourceInfo?) -> MediaInfo? {
        guard let s, s.number("video.width") != nil || s.int("audio.count") ?? 0 > 0 || s.duration != nil else { return nil }
        var m = MediaInfo(url: s.url, container: s.string("container") ?? Formats.key(of: s.url), duration: s.duration, bitRate: s.int("bitrate"), size: s.sizeBytes)
        m.viaFFprobe = false
        var idx = 0
        if (s.int("video.count") ?? 0) > 0 {
            var v = MediaStreamInfo(kind: .video, index: idx, codec: s.string("video.codec") ?? "h264")
            v.profile = s.string("video.profile")
            v.width = s.int("video.codedWidth") ?? s.int("video.width")
            v.height = s.int("video.codedHeight") ?? s.int("video.height")
            v.fps = s.number("video.fps"); v.maxFps = s.number("video.maxfps") ?? v.fps
            v.pixelFormat = s.string("video.pixfmt")
            v.bitDepth = s.int("video.bitdepth")
            v.interlaced = s.bool("video.interlaced") ?? false
            v.fieldOrder = v.interlaced ? "tt" : nil
            v.isHDR = s.bool("video.hdr") ?? false
            v.rotation = s.int("video.rotation") ?? 0
            v.isVFR = s.bool("video.vfr") ?? false
            v.sar = s.number("video.sar") ?? 1
            v.colorTransfer = s.string("video.transfer")
            v.bitRate = s.int("video.bitrate")
            m.streams.append(v)
            idx += 1
        }
        for n in 0..<(s.int("audio.count") ?? 0) {
            var a = MediaStreamInfo(kind: .audio, index: s.int("audio.\(n).index") ?? idx, codec: s.string("audio.\(n).codec") ?? "aac")
            a.channels = s.int("audio.\(n).channels"); a.sampleRate = s.int("audio.\(n).rate")
            a.language = s.string("audio.\(n).lang"); a.bitRate = s.int("audio.\(n).bitrate")
            m.streams.append(a); idx += 1
        }
        for n in 0..<(s.int("sub.count") ?? 0) {
            var t = MediaStreamInfo(kind: .subtitle, index: s.int("sub.\(n).index") ?? idx, codec: s.string("sub.\(n).codec") ?? "subrip")
            t.language = s.string("sub.\(n).lang")
            m.streams.append(t); idx += 1
        }
        return m
    }

    /// Resolves partial option values the way the engine will (defaults, clamping, inactive fields).
    static func resolve(_ options: OptionValues, source: SourceInfo?) -> ResolvedOptions {
        VideoSchemas.convert(items: []).resolve(layers: [options], source: source)
    }
}

enum VideoValidation {
    /// The messages that need arithmetic or two fields compared (the rest are declarative rules in `VideoSchemas.rules()`).
    static func messages(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        let r = VideoSourceBridge.resolve(options, source: source)
        let o = VOpts(r)
        var out: [OptionMessage] = []
        let duration = source?.duration

        // V19: the end must come after the start; a start beyond the clip is just as wrong.
        let start = o.time(VideoKeys.trimStart) ?? 0
        if let end = o.time(VideoKeys.trimEnd), end <= start {
            out.append(OptionMessage(id: "V19", severity: .error, text: L10n("The end must come after the start.", "Конец должен быть позже начала."), fieldKey: VideoKeys.trimEnd))
        } else if let d = duration, start > 0, start >= d {
            out.append(OptionMessage(id: "V19", severity: .error, text: L10n("The start is beyond the end of the clip.", "Начало находится за концом ролика."), fieldKey: VideoKeys.trimStart))
        }
        // V20: a fast cut starts at a key frame, usually a little earlier.
        if (start > 0 || o.time(VideoKeys.trimEnd) != nil), !o.b(VideoKeys.trimAccurate), o.isActive(VideoKeys.trimAccurate) {
            out.append(OptionMessage(id: "V20", severity: .warning,
                                     text: L10n("Copying cuts at key frames, so the start can move a second or two earlier. Turn on Frame-accurate cut to start exactly.",
                                                "При копировании обрезка идёт по ключевым кадрам, поэтому начало может сдвинуться на секунду-две. Включите точную обрезку, чтобы начать ровно."),
                                     fieldKey: VideoKeys.trimAccurate, fix: OptionFix(title: L10n("Cut Exactly", "Резать точно"), set: [VideoKeys.trimAccurate: true])))
        }
        // V16: the requested size is very small for the clip.
        if o.s(VideoKeys.rateControl) == "size", let d = duration, d > 1, let w = source?.number("video.width"), let h = source?.number("video.height") {
            let target = Int64(max(0.5, o.d(VideoKeys.targetMB, 25)) * 1_000_000)
            let fit = VideoSizePlanner.plan(durationSeconds: d / max(0.25, o.d(VideoKeys.filterSpeed, 1)), targetBytes: target, audioKbps: o.i(VideoKeys.audioBitrate, 128),
                                            sourceWidth: Int(w), sourceHeight: Int(h), fps: source?.number("video.fps") ?? 30,
                                            hasAudio: o.s(VideoKeys.audioMode) != "none", allowDownscale: o.b(VideoKeys.sizeLadder))
            if fit.unreachable {
                out.append(OptionMessage(id: "V16", severity: .warning,
                                         text: L10n("\(Util.formatBytes(target)) is very small for \(Util.formatDuration(d)). The picture will look blocky; raise the size or shorten the clip.",
                                                    "\(Util.formatBytes(target)) - очень мало для \(Util.formatDuration(d)). Картинка будет «квадратной»: увеличьте размер или сократите ролик."),
                                         fieldKey: VideoKeys.targetMB))
            }
        }
        // V25: quality values far outside the usual band.
        if o.s(VideoKeys.rateControl) == "cq", o.s(VideoKeys.venc) != "hardware", ["h264", "hevc"].contains(o.s(VideoKeys.vcodec)) {
            let q = o.d(VideoKeys.cq, 23)
            if q < 14 {
                out.append(OptionMessage(id: "V25", severity: .warning, text: L10n("Quality \(Int(q)) gives very large files. The usual range is 18 to 24.", "Качество \(Int(q)) даёт очень большие файлы. Обычный диапазон - от 18 до 24."), fieldKey: VideoKeys.cq,
                                         fix: OptionFix(title: L10n("Use 20", "Выбрать 20"), set: [VideoKeys.cq: 20])))
            } else if q > 32 {
                out.append(OptionMessage(id: "V25", severity: .warning, text: L10n("Quality \(Int(q)) loses a lot of detail. The usual range is 18 to 24.", "Качество \(Int(q)) заметно теряет детали. Обычный диапазон - от 18 до 24."), fieldKey: VideoKeys.cq,
                                         fix: OptionFix(title: L10n("Use 24", "Выбрать 24"), set: [VideoKeys.cq: 24])))
            }
        }
        // V18: a constant frame rate below the source's.
        if o.s(VideoKeys.fpsMode) == "constant", let src = source?.number("video.fps"), let f = Double(o.s(VideoKeys.fps)), f < src - 0.5 {
            out.append(OptionMessage(id: "V18", severity: .info, text: L10n("The frame rate is lowered from \(VideoPlanner.num((src * 100).rounded() / 100)) to \(VideoPlanner.num(f)) fps.",
                                                                                "Частота кадров снижается с \(VideoPlanner.num((src * 100).rounded() / 100)) до \(VideoPlanner.num(f)) к/с."), fieldKey: VideoKeys.fps))
        }
        // V24: a long software encode.
        if let est = VideoEstimator.estimate(options: options, source: source), let secs = est.seconds, secs > 20 * 60 {
            out.append(OptionMessage(id: "V24", severity: .info, text: L10n("Estimated \(Util.formatDuration(secs)) on this Mac. Hardware encoding is several times faster.",
                                                                              "Ориентировочно \(Util.formatDuration(secs)) на этом Mac. Аппаратное кодирование в несколько раз быстрее."), fieldKey: VideoKeys.venc))
        }
        return out
    }
}

/// Video options -> the audio engine's options for the MP3 container (audio only).
enum VideoAudioBridge {
    static func audioOptions(from r: ResolvedOptions) -> OptionValues {
        let o = VOpts(r)
        var v = OptionValues()
        v[AudioKeys.target] = "mp3"
        v[AudioKeys.rateControl] = .string(o.s(VideoKeys.audioRC) == "quality" ? "quality" : "bitrate")
        v[AudioKeys.bitrate] = .int(o.i(VideoKeys.audioBitrate, 160))
        v[AudioKeys.quality] = .int(o.i(VideoKeys.audioQuality, 70))
        switch o.s(VideoKeys.audioMixdown) {
        case "mono": v[AudioKeys.channels] = "mono"
        case "auto", "5.1", "7.1": v[AudioKeys.channels] = "keep"
        default: v[AudioKeys.channels] = "stereo"
        }
        let rate = o.s(VideoKeys.audioRate)
        v[AudioKeys.sampleRate] = .string(rate.isEmpty || rate == "auto" ? "keep" : rate)
        v[AudioKeys.gain] = .double(o.d(VideoKeys.audioGain))
        let norm = o.s(VideoKeys.audioNorm)
        v[AudioKeys.normalize] = .string(norm.isEmpty ? "off" : norm)
        if norm == "custom" { v["aud.norm.lufs"] = .double(o.d(VideoKeys.audioNormLUFS, -16)) }
        v[AudioKeys.fadeIn] = .double(o.d(VideoKeys.fadeIn)); v[AudioKeys.fadeOut] = .double(o.d(VideoKeys.fadeOut))
        v[AudioKeys.speed] = .double(o.d(VideoKeys.filterSpeed, 1))
        if let s = o.time(VideoKeys.trimStart) { v[AudioKeys.trimStart] = .double(s) }
        if let e = o.time(VideoKeys.trimEnd) { v[AudioKeys.trimEnd] = .double(e) }
        v["aud.t.mode"] = .string(o.b(VideoKeys.trimAccurate) || !o.isActive(VideoKeys.trimAccurate) ? "accurate" : "copy")
        v[AudioKeys.tagsMode] = .string(o.s(VideoKeys.metadataMode) == "strip" ? "strip" : "keep")
        return v
    }
}
