import Foundation

// Audio of the video: which source tracks are taken (rules), the concrete output tracks (defaults plus optional per-track rows),
// codec / container fallbacks, channels, rates, bitrate or VBR quality, gain, compressor, loudness, speed and fades (spec/handbrake.md 2.6).

extension VideoPlanner {
    struct TrackRow {
        var source: Int = 0
        var codec: String? = nil
        var mixdown: String? = nil
        var bitrate: Int = 0
        var rate: String? = nil
        var gain: Double = 0
        var name: String? = nil
    }

    static let channelLimits: [String: Int] = ["mp3": 2, "vorbis": 2, "ac3": 6, "eac3": 8, "opus": 8, "aac": 8, "flac": 8, "alac": 8, "pcm16": 8, "pcm24": 8]
    static let defaultPassMask = "aac,ac3,eac3,mp3,flac,alac,opus"

    /// `atempo` accepts 0.5...2 per instance; larger changes are chained.
    static func atempoChain(_ speed: Double) -> [String] {
        var out: [String] = []
        var s = speed
        while s > 2.0001 { out.append("atempo=2"); s /= 2 }
        while s < 0.4999 { out.append("atempo=0.5"); s *= 2 }
        if abs(s - 1) > 0.0005 { out.append("atempo=\(num(s))") }
        return out
    }

    func parseRows() -> [TrackRow] {
        o.rows(VideoKeys.audioTracks).map { r in
            var t = TrackRow()
            t.source = r["src"]?.asInt ?? 0
            if let c = r["codec"]?.asString, !c.isEmpty, c != "default" { t.codec = c }
            if let m = r["mixdown"]?.asString, !m.isEmpty, m != "default" { t.mixdown = m }
            t.bitrate = r["bitrate"]?.asInt ?? 0
            if let rt = r["rate"]?.asString, !rt.isEmpty, rt != "default" { t.rate = rt }
            t.gain = r["gain"]?.asDouble ?? 0
            if let n = r["name"]?.asString, !n.isEmpty { t.name = n }
            return t
        }
    }

    /// Languages as ISO 639-2 codes ("rus,eng"); ISO 639-1 codes are accepted too.
    static func languageMatches(_ streamLang: String?, wanted: [String]) -> Bool {
        guard let l = streamLang?.lowercased() else { return wanted.contains("und") || wanted.contains("any") }
        if wanted.contains("any") { return true }
        let aliases: [String: [String]] = ["rus": ["ru"], "eng": ["en"], "lav": ["lv"], "ger": ["de", "deu"], "fre": ["fr", "fra"], "spa": ["es"], "ita": ["it"], "pol": ["pl"], "ukr": ["uk"], "lit": ["lt"], "est": ["et"]]
        for w in wanted {
            if w == l { return true }
            if aliases[w]?.contains(l) == true || aliases[l]?.contains(w) == true { return true }
        }
        return false
    }

    mutating func planAudio() throws {
        let mode = o.s(VideoKeys.audioMode).isEmpty ? "first" : o.s(VideoKeys.audioMode)
        var codecKey = o.s(VideoKeys.audioCodec).isEmpty ? "aac" : o.s(VideoKeys.audioCodec)
        plan.audioTracks = []
        // Stream copy of the picture between trim points copies the sound too.
        if plan.copyTrim && plan.videoCodec == "copy" { codecKey = "copy" }
        if mode == "none" || codecKey == "none" || plan.container == "gif" { plan.audioCodec = "none"; return }
        let streams = src?.audioStreams ?? []
        if src != nil && streams.isEmpty { plan.audioCodec = "none"; return }

        var picks: [(stream: MediaStreamInfo?, row: TrackRow?)] = []
        let rows = parseRows()
        if !rows.isEmpty {
            for r in rows {
                if streams.isEmpty { picks.append((nil, r)) }
                else if streams.indices.contains(r.source) { picks.append((streams[r.source], r)) }
            }
        } else if streams.isEmpty {
            picks = [(nil, nil)]
        } else {
            switch mode {
            case "all": picks = streams.map { ($0, nil) }
            case "languages":
                let wanted = o.s(VideoKeys.audioLangs).lowercased().split(whereSeparator: { ", ;".contains($0) }).map(String.init)
                let m = streams.filter { Self.languageMatches($0.language, wanted: wanted) }
                if !m.isEmpty { picks = m.map { ($0, nil) } }
                else if o.b(VideoKeys.audioLangFallback) { picks = [(streams[0], nil)] }
            default: picks = [(streams[0], nil)]
            }
        }
        var tracks: [VideoAudioTrackPlan] = []
        for p in picks { tracks.append(makeAudioTrack(stream: p.stream, row: p.row, defaultKey: codecKey)) }

        // Extra surround track: a copy of the source Dolby Digital track after the main (re-encoded) one.
        if o.s(VideoKeys.audioSecond) == "copySurround", codecKey != "copy", (picks.first?.stream ?? streams.first) != nil {
            let ac3 = streams.first { ["ac3", "eac3"].contains($0.codec) && ($0.bitRate ?? 0) <= 640_000 }
            if let s = ac3, MediaCapabilities.containerSupports(plan.container, audioCodec: s.codec) {
                var t = VideoAudioTrackPlan(sourceStream: s.index, encoder: "copy", codec: "copy")
                t.language = s.language
                tracks.append(t)
            }
        }
        plan.audioTracks = tracks
        plan.audioCodec = tracks.first?.codec ?? "none"
        plan.audioFilters = commonAudioFilters()
    }

    /// Filters every audio track gets: reverse, speed, fades.
    func commonAudioFilters() -> [String] {
        var f: [String] = []
        if plan.picture.reverse { f.append("areverse") }
        f += Self.atempoChain(plan.picture.speed)
        return f
    }

    mutating func makeAudioTrack(stream: MediaStreamInfo?, row: TrackRow?, defaultKey: String) -> VideoAudioTrackPlan {
        var key = row?.codec ?? defaultKey
        let container = plan.container
        var notes: [L10n] = []
        let index = stream?.index ?? -1

        func fallbackKey() -> String {
            switch container { case "webm": return "opus"; case "avi": return "mp3"; default: return "aac" }
        }
        if key == "copy" {
            let mask = Set((o.s(VideoKeys.audioPassMask).isEmpty ? Self.defaultPassMask : o.s(VideoKeys.audioPassMask)).lowercased().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            if let s = stream {
                let n = MediaCapabilities.normalizeAudio(s.codec)
                let allowed = mask.contains(n) || mask.contains("all")
                if allowed && MediaCapabilities.containerSupports(container, audioCodec: s.codec) {
                    var t = VideoAudioTrackPlan(sourceStream: index, encoder: "copy", codec: "copy")
                    t.language = o.s(VideoKeys.audioLang).isEmpty ? s.language : o.s(VideoKeys.audioLang)
                    t.name = row?.name ?? (o.s(VideoKeys.audioName).isEmpty ? nil : o.s(VideoKeys.audioName))
                    return t
                }
                key = o.s(VideoKeys.audioFallback).isEmpty ? "aac" : o.s(VideoKeys.audioFallback)
                if !MediaCapabilities.containerSupports(container, audioCodec: key) { key = fallbackKey() }
                notes.append(L10n("The \(MediaSourceMapper.codecDisplay(s.codec)) sound cannot be copied here, so it is re-encoded.", "Звук \(MediaSourceMapper.codecDisplay(s.codec)) нельзя скопировать, поэтому он перекодируется."))
            } else { key = "aac" }
        }
        if !MediaCapabilities.containerSupports(container, audioCodec: key) {
            notes.append(L10n("\(container.uppercased()) cannot hold this audio codec; \(fallbackKey().uppercased()) is used.", "\(container.uppercased()) не вмещает этот аудиокодек; используется \(fallbackKey().uppercased())."))
            key = fallbackKey()
        }
        // Encoder availability.
        var encoder: String
        let useFF = tools.hasFFmpeg
        switch key {
        case "aac": encoder = useFF && tools.hasEncoder("aac_at") ? "aac_at" : "aac"
        case "mp3": encoder = "libmp3lame"
        case "opus": encoder = "libopus"
        case "flac": encoder = "flac"
        case "alac": encoder = "alac"
        case "ac3": encoder = "ac3"
        case "eac3": encoder = "eac3"
        case "pcm16": encoder = "pcm_s16le"
        case "pcm24": encoder = "pcm_s24le"
        case "vorbis": encoder = tools.hasEncoder("libvorbis") ? "libvorbis" : "vorbis"
        default: encoder = "aac"; key = "aac"
        }
        if useFF && !tools.hasEncoder(encoder) {
            let alt = fallbackKey() == "aac" ? "aac" : fallbackKey()
            notes.append(L10n("This ffmpeg cannot write \(key.uppercased()) sound; \(alt.uppercased()) is used.", "Этот ffmpeg не умеет записывать звук \(key.uppercased()); используется \(alt.uppercased())."))
            key = alt
            encoder = alt == "aac" ? (tools.hasEncoder("aac_at") ? "aac_at" : "aac") : (alt == "mp3" ? "libmp3lame" : "libopus")
        }
        if !useFF && !["aac", "alac", "pcm16", "pcm24"].contains(key) {
            notes.append(L10n("Without ffmpeg only AAC, Apple Lossless and PCM sound can be written; AAC is used.", "Без ffmpeg можно записывать только AAC, Apple Lossless и PCM; используется AAC."))
            key = "aac"; encoder = "aac"
        }
        plan.notes += notes

        var t = VideoAudioTrackPlan(sourceStream: index, encoder: encoder, codec: key)

        // Channels.
        let srcCh = stream?.channels
        let mix = row?.mixdown ?? (o.s(VideoKeys.audioMixdown).isEmpty ? "stereo" : o.s(VideoKeys.audioMixdown))
        var outCh: Int?
        switch mix {
        case "mono": outCh = 1
        case "stereo": outCh = srcCh.map { min($0, 2) } ?? 2
        case "dpl2": outCh = 2; t.matrixDPL2 = (srcCh ?? 6) > 2
        case "5.1": outCh = srcCh.map { min($0, 6) } ?? 6
        case "7.1": outCh = srcCh.map { min($0, 8) } ?? 8
        default: outCh = srcCh
        }
        if let limit = Self.channelLimits[key], let c = outCh, c > limit { outCh = limit }
        if let c = outCh, c != srcCh { t.channels = c } else if srcCh == nil, let c = outCh { t.channels = c }
        if key == "mp3", (srcCh ?? 2) > 2, t.channels == nil { t.channels = 2 }
        let finalChannels = outCh ?? srcCh ?? 2

        // Sample rate.
        var rate: Int?
        let rateText = row?.rate ?? (o.s(VideoKeys.audioRate).isEmpty ? "auto" : o.s(VideoKeys.audioRate))
        if rateText != "auto", let khz = Double(rateText) { rate = Int((khz < 1000 ? khz * 1000 : khz).rounded()) }
        let normOn = o.s(VideoKeys.audioNorm) != "off" && !o.s(VideoKeys.audioNorm).isEmpty
        if rate == nil, normOn { rate = stream?.sampleRate ?? 48000 }   // loudnorm upsamples to 192 kHz unless the rate is pinned
        let srcRate = rate ?? stream?.sampleRate
        if key == "opus", let r = srcRate, ![8000, 12000, 16000, 24000, 48000].contains(r) {
            rate = 48000
            plan.notes.append(L10n("Opus supports 8, 12, 16, 24 and 48 kHz. Using 48 kHz.", "Opus поддерживает 8, 12, 16, 24 и 48 кГц. Используется 48 кГц."))
        }
        if key == "ac3" || key == "eac3", let r = srcRate, ![32000, 44100, 48000].contains(r) { rate = 48000 }
        t.sampleRate = rate

        // Bitrate or VBR quality.
        let lossless = ["flac", "alac", "pcm16", "pcm24"].contains(key)
        if !lossless {
            let useVBR = o.s(VideoKeys.audioRC) == "quality" && (encoder == "aac_at" || key == "mp3")
            if useVBR {
                let q = Double(o.i(VideoKeys.audioQuality, 70))
                t.vbr = true
                t.quality = key == "mp3" ? Int(((100 - q) / 100 * 9).rounded()) : Int(((100 - q) / 100 * 14).rounded())
            } else {
                var kb = (row?.bitrate ?? 0) > 0 ? row!.bitrate : (o.i(VideoKeys.audioBitrate, 160) > 0 ? o.i(VideoKeys.audioBitrate, 160) : 160)
                if finalChannels > 2 { kb = min(640, kb * finalChannels / 2) }
                t.bitrateKbps = kb
            }
        }

        // Filters: gain, compressor, loudness (then the shared speed / fade chain).
        var f = commonAudioFilters()
        let gain = o.d(VideoKeys.audioGain) + (row?.gain ?? 0)
        if abs(gain) > 0.0005 { f.append("volume=\(Self.num(gain))dB") }
        switch o.s(VideoKeys.audioComp) {
        case "light": f.append("acompressor=threshold=-18dB:ratio=2:attack=20:release=250")
        case "moderate": f.append("acompressor=threshold=-18dB:ratio=3:attack=20:release=250")
        case "strong": f.append("acompressor=threshold=-18dB:ratio=6:attack=20:release=250")
        case "nightmode": f.append("acompressor=threshold=-30dB:ratio=6:attack=5:release=200:makeup=6dB")
        default: break
        }
        if normOn {
            let target: Double
            switch o.s(VideoKeys.audioNorm) {
            case "ebu": target = -23
            case "podcast": target = -16
            case "streaming": target = -14
            default: target = o.d(VideoKeys.audioNormLUFS, -16)
            }
            var ln = "loudnorm=I=\(Self.num(target)):TP=-1.5:LRA=11"
            if let m = an.loudness {
                ln += ":measured_I=\(Self.num(m.inputI)):measured_TP=\(Self.num(m.inputTP)):measured_LRA=\(Self.num(m.inputLRA)):measured_thresh=\(Self.num(m.inputThresh)):offset=\(Self.num(m.targetOffset)):linear=true"
            }
            f.append(ln)
        }
        if let dur = plan.outputDuration {
            if o.d(VideoKeys.fadeIn) > 0 { f.append("afade=t=in:st=0:d=\(Self.num(o.d(VideoKeys.fadeIn)))") }
            let fo = o.d(VideoKeys.fadeOut)
            if fo > 0, dur > fo { f.append("afade=t=out:st=\(Self.num(dur - fo)):d=\(Self.num(fo))") }
        } else if o.d(VideoKeys.fadeIn) > 0 { f.append("afade=t=in:st=0:d=\(Self.num(o.d(VideoKeys.fadeIn)))") }
        if key != "copy" { t.filters = f }
        if o.d(VideoKeys.audioDRC) > 0, ["ac3", "eac3"].contains(stream?.codec ?? "") { t.drc = o.d(VideoKeys.audioDRC) }
        t.name = row?.name ?? (o.s(VideoKeys.audioName).isEmpty ? nil : o.s(VideoKeys.audioName))
        let lang = o.s(VideoKeys.audioLang)
        t.language = lang.isEmpty ? stream?.language : lang
        return t
    }
}
