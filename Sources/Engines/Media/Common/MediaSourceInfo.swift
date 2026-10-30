import Foundation

/// MediaInfo -> SourceInfo (facts, chips, streams, plain-words warnings). Shared by the audio and the video probes.
enum MediaSourceMapper {
    static func codecDisplay(_ codec: String) -> String {
        switch codec.lowercased() {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vp8": return "VP8"
        case "mpeg4": return "MPEG-4"
        case "mpeg2video": return "MPEG-2"
        case "prores": return "ProRes"
        case "aac": return "AAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "dts": return "DTS"
        case "truehd": return "TrueHD"
        case "subrip": return "SubRip"
        case "ass", "ssa": return "ASS"
        case "mov_text": return "Timed text"
        case "webvtt": return "WebVTT"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        default:
            if codec.hasPrefix("pcm_") { return "PCM" }
            return codec.uppercased()
        }
    }

    static func channelText(_ channels: Int?, layout: String?) -> String {
        guard let c = channels else { return "" }
        switch c {
        case 1: return L("mono", "моно")
        case 2: return L("stereo", "стерео")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return L("\(c) channels", "каналов: \(c)")
        }
    }

    static func fpsText(_ fps: Double) -> String {
        let r = (fps * 100).rounded() / 100
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.2f", r).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func map(_ info: MediaInfo, kind: FileKind) -> SourceInfo {
        var s = SourceInfo(url: info.url, kind: kind)
        s.facts["container"] = .string(info.container)
        if let d = info.duration { s.facts["duration"] = .double(d) }
        if let b = info.size { s.facts["size"] = .double(Double(b)) }
        if let b = info.bitRate { s.facts["bitrate"] = .int(b) }

        let videos = info.videoStreams, audios = info.audioStreams, subs = info.subtitleStreams
        s.facts["video.count"] = .int(videos.count)
        s.facts["audio.count"] = .int(audios.count)
        s.facts["sub.count"] = .int(subs.count)
        s.facts["chapters.count"] = .int(info.chapters.count)

        if let v = videos.first {
            let size = v.displaySize
            s.facts["video.codec"] = .string(v.codec)
            if let p = v.profile { s.facts["video.profile"] = .string(p) }
            if let size { s.facts["video.width"] = .int(size.width); s.facts["video.height"] = .int(size.height) }
            if let w = v.width, let h = v.height { s.facts["video.codedWidth"] = .int(w); s.facts["video.codedHeight"] = .int(h) }
            if let f = v.fps { s.facts["video.fps"] = .double(f) }
            if let f = v.maxFps { s.facts["video.maxfps"] = .double(f) }
            if let p = v.pixelFormat { s.facts["video.pixfmt"] = .string(p) }
            s.facts["video.bitdepth"] = .int(v.bitDepth ?? 8)
            s.facts["video.interlaced"] = .bool(v.interlaced)
            s.facts["video.hdr"] = .bool(v.isHDR)
            s.facts["video.rotation"] = .int(v.rotation)
            s.facts["video.vfr"] = .bool(v.isVFR)
            s.facts["video.sar"] = .double(v.sar)
            if let t = v.colorTransfer { s.facts["video.transfer"] = .string(t) }
            if let b = v.bitRate { s.facts["video.bitrate"] = .int(b) }
        }
        for (n, a) in audios.enumerated() {
            s.facts["audio.\(n).codec"] = .string(a.codec)
            if let c = a.channels { s.facts["audio.\(n).channels"] = .int(c) }
            if let r = a.sampleRate { s.facts["audio.\(n).rate"] = .int(r) }
            if let l = a.language { s.facts["audio.\(n).lang"] = .string(l) }
            if let b = a.bitRate { s.facts["audio.\(n).bitrate"] = .int(b) }
            s.facts["audio.\(n).index"] = .int(a.index)
        }
        for (n, t) in subs.enumerated() {
            s.facts["sub.\(n).codec"] = .string(t.codec)
            if let l = t.language { s.facts["sub.\(n).lang"] = .string(l) }
            s.facts["sub.\(n).bitmap"] = .bool(t.isBitmapSubtitle)
            s.facts["sub.\(n).index"] = .int(t.index)
        }
        if audios.isEmpty == false, let a = audios.first {
            // Conventional single-track facts for audio files.
            if let c = a.channels { s.facts["audio.channels"] = .int(c) }
            if let r = a.sampleRate { s.facts["audio.rate"] = .int(r) }
            s.facts["audio.codec"] = .string(a.codec)
        }

        // Chips: container, video codec + size + fps, depth / HDR, audio, duration.
        s.chips.append(SourceChip(symbol: "shippingbox", text: info.container.uppercased()))
        if let v = videos.first {
            s.chips.append(SourceChip(symbol: "film", text: codecDisplay(v.codec)))
            if let size = v.displaySize { s.chips.append(SourceChip(symbol: "aspectratio", text: "\(size.width)×\(size.height)")) }
            if let f = v.fps { s.chips.append(SourceChip(symbol: "speedometer", text: L("\(fpsText(f)) fps", "\(fpsText(f)) к/с"))) }
            if v.isHDR { s.chips.append(SourceChip(symbol: "sun.max", text: "HDR")) }
            else if (v.bitDepth ?? 8) >= 10 { s.chips.append(SourceChip(symbol: "circle.lefthalf.filled", text: L("\(v.bitDepth ?? 10)-bit", "\(v.bitDepth ?? 10) бит"))) }
        }
        if let a = audios.first {
            s.chips.append(SourceChip(symbol: "waveform", text: "\(codecDisplay(a.codec)) \(channelText(a.channels, layout: a.channelLayout))".trimmingCharacters(in: .whitespaces)))
            if audios.count > 1 { s.chips.append(SourceChip(symbol: "speaker.wave.2", text: L("\(audios.count) audio tracks", "дорожек звука: \(audios.count)"))) }
        }
        if !subs.isEmpty { s.chips.append(SourceChip(symbol: "captions.bubble", text: L("\(subs.count) subtitles", "субтитров: \(subs.count)"))) }
        if let d = info.duration { s.chips.append(SourceChip(symbol: "clock", text: Util.formatTime(d))) }

        // Streams for the inspector.
        for (n, v) in videos.enumerated() {
            var detail = codecDisplay(v.codec)
            if let p = v.profile { detail += " " + p }
            if let size = v.displaySize { detail += ", \(size.width)×\(size.height)" }
            if let f = v.fps { detail += ", " + L("\(fpsText(f)) fps", "\(fpsText(f)) к/с") }
            s.streams.append(SourceStream(kind: .video, index: n, title: L("Video", "Видео"), detail: detail, language: v.language, isDefault: v.isDefault,
                                          facts: ["stream": .int(v.index)]))
        }
        for (n, a) in audios.enumerated() {
            var detail = codecDisplay(a.codec)
            let ch = channelText(a.channels, layout: a.channelLayout)
            if !ch.isEmpty { detail += ", " + ch }
            if let r = a.sampleRate { detail += ", " + String(format: "%g", Double(r) / 1000) + " kHz" }
            if let b = a.bitRate { detail += ", \(b / 1000) " + L("kbit/s", "кбит/с") }
            let name = a.title ?? L("Audio \(n + 1)", "Звук \(n + 1)")
            s.streams.append(SourceStream(kind: .audio, index: n, title: name, detail: detail, language: a.language, isDefault: a.isDefault,
                                          facts: ["stream": .int(a.index), "codec": .string(a.codec), "channels": .int(a.channels ?? 0)]))
        }
        for (n, t) in subs.enumerated() {
            let name = t.title ?? L("Subtitles \(n + 1)", "Субтитры \(n + 1)")
            s.streams.append(SourceStream(kind: .subtitle, index: n, title: name, detail: codecDisplay(t.codec) + (t.isForced ? L(", forced", ", принудительные") : ""),
                                          language: t.language, isDefault: t.isDefault, facts: ["stream": .int(t.index), "bitmap": .bool(t.isBitmapSubtitle)]))
        }
        for (n, c) in info.chapters.prefix(300).enumerated() {
            s.streams.append(SourceStream(kind: .chapter, index: n, title: c.title.isEmpty ? L("Chapter \(n + 1)", "Глава \(n + 1)") : c.title,
                                          detail: Util.formatTime(c.start), facts: ["start": .double(c.start), "end": .double(c.end)]))
        }

        // Plain-words oddities.
        if let v = videos.first {
            if v.isVFR { s.warnings.append(L10n("Variable frame rate: the frame rate changes inside the clip (typical for screen recordings and phones). Choose a constant rate if an editor needs one.",
                                                "Переменная частота кадров: она меняется внутри ролика (так пишут экран и телефоны). Выберите постоянную частоту, если она нужна редактору.")) }
            if v.isHDR { s.warnings.append(L10n("HDR video. Keep HDR needs a 10-bit HEVC encoder and an HDR-capable screen.",
                                                "HDR-видео. Чтобы сохранить HDR, нужен 10-битный HEVC и экран с поддержкой HDR.")) }
            else if (v.bitDepth ?? 8) >= 10 { s.warnings.append(L10n("10-bit video. HEVC keeps the extra depth; 10-bit H.264 does not play on iPhone or Apple TV.",
                                                                    "10-битное видео. HEVC сохраняет глубину цвета; 10-битный H.264 не воспроизводится на iPhone и Apple TV.")) }
            if v.interlaced { s.warnings.append(L10n("Interlaced video. Turn on Deinterlace to remove the comb lines on moving edges.",
                                                     "Чересстрочное видео. Включите деинтерлейсинг, чтобы убрать «гребёнку» на движущихся краях.")) }
            if v.rotation != 0 { s.warnings.append(L10n("The file stores a rotation of \(v.rotation)°. The picture is shown rotated automatically.",
                                                       "В файле записан поворот на \(v.rotation)°. Картинка поворачивается автоматически.")) }
            if let size = v.displaySize, size.width % 2 == 1 || size.height % 2 == 1 {
                s.warnings.append(L10n("Odd picture size (\(size.width)×\(size.height)). It is adjusted to an even size for most encoders.",
                                       "Нечётный размер кадра (\(size.width)×\(size.height)). Для большинства кодировщиков он будет изменён на чётный."))
            }
        } else if kind == .video {
            s.warnings.append(L10n("This file has no video picture.", "В файле нет видеоизображения."))
        }
        return s
    }
}
