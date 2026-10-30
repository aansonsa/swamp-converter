import Foundation

// Subtitles, chapters, metadata, overlays (watermark, burned-in subtitles), the GIF branch and the audio-only (MP3) branch.

extension VideoPicturePlan {
    /// Does the picture need to be decoded and re-encoded (filters, resize, rotate, fps change, speed)? Stream copy rules out all of these (V05).
    var changesPicture: Bool {
        crop != nil || rotate != 0 || flipH || flipV || scale != nil || padCanvas != nil || pad != nil || deinterlace != nil || ivtc || deblock != nil
            || denoise > 0 || chromaSmooth > 0 || deband || sharpen > 0 || gray || brightness != 0 || contrast != 1 || saturation != 1 || gamma != 1
            || colorTemp != nil || stabilize || reverse || abs(speed - 1) > 0.0005 || fps != nil || fadeIn > 0 || fadeOut > 0 || applySAR
    }
}

extension VideoPlanner {
    // MARK: Subtitles

    func subtitleCodec(for s: MediaStreamInfo, container: String) -> String? {
        switch container {
        case "mp4", "mov": return s.isBitmapSubtitle ? nil : "mov_text"
        case "mkv":
            if s.isBitmapSubtitle { return "copy" }
            return ["ass", "ssa"].contains(s.codec) ? "ass" : (s.codec == "subrip" ? "copy" : "srt")
        case "webm": return s.isBitmapSubtitle ? nil : "webvtt"
        default: return nil
        }
    }

    mutating func planSubtitles() throws {
        guard o.isActive(VideoKeys.subMode) else { return }
        let mode = o.s(VideoKeys.subMode).isEmpty ? "keep" : o.s(VideoKeys.subMode)
        guard mode != "none", plan.container != "gif" else { return }
        let container = plan.container
        let extFile = o.s(VideoKeys.extFile)
        if !extFile.isEmpty, mode != "burn" {
            if let codec = MediaCapabilities.textSubtitleCodec(for: container) {
                plan.externalSubtitles = [VideoExternalSubtitle(file: URL(fileURLWithPath: extFile), offsetMs: o.i(VideoKeys.extOffset),
                                                                charset: Self.charsetKey(o.s(VideoKeys.extCharset)), language: o.has(VideoKeys.extLang) && o.s(VideoKeys.extLang) != "und" ? o.s(VideoKeys.extLang) : nil, codec: codec)]
            } else {
                note("\(container.uppercased()) cannot hold subtitles; the subtitle file is left out.", "\(container.uppercased()) не вмещает субтитры; файл субтитров не добавлен.")
            }
        }
        guard mode == "keep" else { return }
        let wanted = o.s(VideoKeys.subLangs).lowercased().split(whereSeparator: { ", ;".contains($0) }).map(String.init)
        let forcedOnly = o.b(VideoKeys.subForcedOnly)
        var dropped = 0
        var tracks: [VideoSubtitleTrackPlan] = []
        for s in src?.subtitleStreams ?? [] {
            if !wanted.isEmpty, !Self.languageMatches(s.language, wanted: wanted) { continue }
            if forcedOnly, !s.isForced { continue }
            guard let codec = subtitleCodec(for: s, container: container) else { dropped += 1; continue }
            tracks.append(VideoSubtitleTrackPlan(sourceStream: s.index, codec: codec, language: s.language, isDefault: false, isForced: s.isForced))
        }
        switch o.s(VideoKeys.subDefault) {
        case "first": if !tracks.isEmpty { tracks[0].isDefault = true }
        case "forced": if let i = tracks.firstIndex(where: { $0.isForced }) { tracks[i].isDefault = true }
        default: break
        }
        if dropped > 0 {
            note("Picture-based subtitles can't be kept in \(container.uppercased()). Burn them in or switch to MKV.", "Графические субтитры нельзя сохранить в \(container.uppercased()). Вшейте их в картинку или выберите MKV.")
        }
        plan.subtitleTracks = tracks
    }

    static func charsetKey(_ picker: String) -> String { picker.isEmpty ? "auto" : picker }

    // MARK: Chapters and metadata

    mutating func planChaptersAndMetadata() {
        let container = plan.container
        switch o.s(VideoKeys.chapterMode) {
        case "none": plan.chapters = .none
        case "auto":
            if let dur = plan.outputDuration, dur > 0 {
                let step = max(1, o.d(VideoKeys.chapterInterval, 5)) * 60
                var list: [VideoChapter] = []
                var t = 0.0, n = 1
                while t < dur - 0.5 { list.append(VideoChapter(start: t, title: L("Chapter \(n)", "Глава \(n)"))); t += step; n += 1 }
                plan.chapters = list.isEmpty ? .none : .custom(list)
            } else { plan.chapters = .none }
        case "custom":
            let rows = o.rows(VideoKeys.chapterRows)
            let list = rows.compactMap { r -> VideoChapter? in
                guard let t = r["start"]?.asDouble ?? r["start"]?.asString.flatMap(Util.parseTime) else { return nil }
                return VideoChapter(start: max(0, t), title: r["title"]?.asString ?? "")
            }.sorted { $0.start < $1.start }
            plan.chapters = list.isEmpty ? .none : .custom(list)
        default: plan.chapters = .keepSource
        }
        if !MediaCapabilities.supportsChapters(container) { plan.chapters = .none }

        var md = VideoMetadataPlan()
        md.mode = o.s(VideoKeys.metadataMode).isEmpty ? "keep" : o.s(VideoKeys.metadataMode)
        md.noGPS = o.b(VideoKeys.metadataNoGPS)
        md.keepCreationDate = !o.isActive(VideoKeys.mdKeepDates) || o.b(VideoKeys.mdKeepDates)
        if md.mode == "custom" {
            let map: [(String, String)] = [(VideoKeys.mdTitle, "title"), (VideoKeys.mdArtist, "artist"), (VideoKeys.mdAlbum, "album"), (VideoKeys.mdYear, "date"),
                                            (VideoKeys.mdGenre, "genre"), (VideoKeys.mdComment, "comment"), (VideoKeys.mdDescription, "description"),
                                            (VideoKeys.mdCopyright, "copyright"), (VideoKeys.mdLanguage, "language")]
            for (key, tag) in map where o.has(key) { md.tags[tag] = o.s(key) }
        }
        let cover = o.s(VideoKeys.mdCover)
        if !cover.isEmpty, ["mp4", "mov", "mkv"].contains(container) { md.cover = URL(fileURLWithPath: cover) }
        plan.metadata = md
    }

    // MARK: Overlays

    mutating func planOverlays() throws {
        let size = plan.picture.outputSize
        switch o.s(VideoKeys.wmMode) {
        case "image":
            let f = o.s(VideoKeys.wmFile)
            if !f.isEmpty {
                plan.overlays.append(.watermarkImage(file: URL(fileURLWithPath: f), widthPercent: o.d(VideoKeys.wmScale, 15), opacity: o.d(VideoKeys.wmOpacity, 70) / 100,
                                                     position: o.s(VideoKeys.wmPos).isEmpty ? "br" : o.s(VideoKeys.wmPos), margin: o.i(VideoKeys.wmMargin, 24)))
            }
        case "text":
            let t = o.s(VideoKeys.wmText)
            if !t.isEmpty {
                plan.overlays.append(.watermarkText(text: t, widthPercent: o.d(VideoKeys.wmScale, 15), opacity: o.d(VideoKeys.wmOpacity, 70) / 100,
                                                    position: o.s(VideoKeys.wmPos).isEmpty ? "br" : o.s(VideoKeys.wmPos), margin: o.i(VideoKeys.wmMargin, 24)))
            }
        default: break
        }
        if o.s(VideoKeys.subMode) == "burn" {
            var cues: [VideoCue]? = nil
            let ext = o.s(VideoKeys.extFile)
            if !ext.isEmpty {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: ext)) {
                    let text = VideoCueParser.decode(data, charset: Self.charsetKey(o.s(VideoKeys.extCharset)))
                    let shift = Double(o.i(VideoKeys.extOffset)) / 1000
                    cues = VideoCueParser.parse(text).map { VideoCue(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
                }
            } else { cues = an.burnCues }
            if let cues, !cues.isEmpty, size != nil {
                var st = VideoBurnStyle()
                st.font = o.s(VideoKeys.burnFont).isEmpty ? st.font : o.s(VideoKeys.burnFont)
                st.sizePercent = o.d(VideoKeys.burnSize, 5.5)
                st.color = o.s(VideoKeys.burnColor).isEmpty ? "#FFFFFF" : o.s(VideoKeys.burnColor)
                st.outlineColor = o.s(VideoKeys.burnOutlineColor).isEmpty ? "#000000" : o.s(VideoKeys.burnOutlineColor)
                st.outline = o.d(VideoKeys.burnOutline, 2); st.shadow = o.d(VideoKeys.burnShadow, 1)
                st.box = o.b(VideoKeys.burnBox); st.boxOpacity = o.d(VideoKeys.burnBoxOpacity, 50)
                st.position = o.s(VideoKeys.burnPos).isEmpty ? "bottom" : o.s(VideoKeys.burnPos)
                st.margin = o.d(VideoKeys.burnMargin, 6)
                plan.overlays.append(.burnIn(cues: cues, style: st))
            } else {
                note("No subtitle text was found to burn in.", "Текст субтитров для вшивания не найден.")
            }
        }
    }

    // MARK: GIF

    mutating func planGif() throws {
        plan.videoCodec = "gif"; plan.videoEncoder = "gif"; plan.audioCodec = "none"; plan.hardware = false
        plan.audioTracks = []; plan.subtitleTracks = []; plan.chapters = .none
        var g = VideoGifPlan()
        g.fps = max(1, o.i(VideoKeys.gifFps, 15))
        g.width = max(16, o.i(VideoKeys.gifWidth, 480))
        g.colors = max(2, min(256, o.i(VideoKeys.gifColors, 256)))
        g.dither = o.s(VideoKeys.gifDither).isEmpty ? "bayer" : o.s(VideoKeys.gifDither)
        g.loop = o.s(VideoKeys.gifLoop).isEmpty ? "forever" : o.s(VideoKeys.gifLoop)
        plan.gif = g
        var p = plan.picture
        p.scale = nil; p.padCanvas = nil; p.pad = nil; p.scaleCover = false; p.fps = nil
        p.fadeIn = 0; p.fadeOut = 0
        plan.picture = p
        let (pre, _) = Self.filterChain(p, encoder: "gif", needsEven: false, source: sv, outputDuration: plan.outputDuration)
        let dither = g.dither == "bayer" ? "dither=bayer:bayer_scale=5:diff_mode=rectangle" : (g.dither == "none" ? "dither=none:diff_mode=rectangle" : "dither=\(g.dither):diff_mode=rectangle")
        let tail = "fps=\(g.fps),scale='min(\(g.width),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=\(g.colors):stats_mode=diff[p];[b][p]paletteuse=\(dither)"
        plan.videoFilters = pre + [tail]
        if let dur = plan.outputDuration, dur > 0 {
            plan.estimatedDuration = dur
        }
        plan.metadata.mode = "strip"
        plan.picture.outputSize = {
            guard let d = sv?.displaySize else { return nil }
            let w = g.width, h = Int((Double(d.height) * Double(g.width) / Double(max(1, d.width))).rounded())
            return (w, h)
        }()
        if plan.backend == .avfoundation { throw ConversionError.toolMissing(.ffmpeg) }
    }

    // MARK: Audio only (MP3)

    mutating func buildAudioOnly() throws -> VideoEncodePlan {
        plan.noVideo = true
        plan.videoCodec = "none"; plan.videoEncoder = "none"
        plan.backend = tools.hasFFmpeg ? .ffmpeg : .avfoundation
        try planRange()
        guard let s = src else {
            plan.audioTracks = [makeAudioTrack(stream: nil, row: nil, defaultKey: "mp3")]
            plan.audioCodec = "mp3"
            return plan
        }
        guard let first = s.audioStreams.first else { throw ConversionError.noAudioTrack }
        plan.picture.reverse = o.b(VideoKeys.reverse)
        var track = makeAudioTrack(stream: first, row: nil, defaultKey: "mp3")
        if track.codec != "mp3" && track.codec != "copy" {
            // The container is MP3: other codecs make no sense here.
            track = makeAudioTrack(stream: first, row: VideoPlanner.TrackRow(codec: "mp3"), defaultKey: "mp3")
        }
        plan.audioTracks = [track]
        plan.audioCodec = track.codec
        plan.audioFilters = commonAudioFilters()
        plan.metadata.mode = o.s(VideoKeys.metadataMode).isEmpty ? "keep" : o.s(VideoKeys.metadataMode)
        if !tools.hasFFmpeg { throw ConversionError.toolMissing(.ffmpeg) }
        return plan
    }
}
