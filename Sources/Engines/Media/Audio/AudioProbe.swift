import Foundation
import AVFoundation
import CoreMedia

// Reading what an audio file is: codec, rate, channels, bit rate, duration, tags, cover. ffprobe when it exists, AVFoundation otherwise.
// The audio module keeps its own small probe so it works (and is testable) whatever state the shared MediaProbe is in.

/// The ordinary text tags, normalised across ID3, MP4 atoms and Vorbis comments.
struct AudTags: Equatable, Sendable {
    var title = "", artist = "", album = "", albumArtist = "", year = ""
    var track = "", trackTotal = "", disc = "", genre = "", composer = "", comment = ""

    var isEmpty: Bool { self == AudTags() }

    /// Normalises raw container tags (any case, any spelling: `album_artist`, `ALBUMARTIST`, `tracknumber`, `3/12`).
    static func from(raw: [String: String]) -> AudTags {
        var lower: [String: String] = [:]
        for (k, v) in raw { lower[k.lowercased()] = v }
        func pick(_ keys: String...) -> String { keys.compactMap { lower[$0] }.first(where: { !$0.isEmpty }) ?? "" }
        var t = AudTags()
        t.title = pick("title"); t.artist = pick("artist"); t.album = pick("album")
        t.albumArtist = pick("album_artist", "albumartist", "album artist")
        let date = pick("date", "year", "originaldate", "tdrc")
        t.year = String(date.prefix(4))
        let trk = pick("track", "tracknumber", "trck")
        let parts = trk.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        t.track = parts.first ?? ""
        t.trackTotal = parts.count > 1 ? parts[1] : pick("tracktotal", "totaltracks")
        let dsc = pick("disc", "discnumber", "tpos")
        t.disc = dsc.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        t.genre = pick("genre"); t.composer = pick("composer")
        t.comment = pick("comment", "description")
        return t
    }

    /// The tag with the given canonical name ("albumArtist").
    subscript(name: String) -> String {
        get {
            switch name {
            case "title": return title; case "artist": return artist; case "album": return album; case "albumArtist": return albumArtist
            case "year": return year; case "track": return track; case "trackTotal": return trackTotal; case "disc": return disc
            case "genre": return genre; case "composer": return composer; case "comment": return comment
            default: return ""
            }
        }
        set {
            switch name {
            case "title": title = newValue; case "artist": artist = newValue; case "album": album = newValue; case "albumArtist": albumArtist = newValue
            case "year": year = newValue; case "track": track = newValue; case "trackTotal": trackTotal = newValue; case "disc": disc = newValue
            case "genre": genre = newValue; case "composer": composer = newValue; case "comment": comment = newValue
            default: break
            }
        }
    }

    /// `3/12`, `3` or empty.
    var trackText: String { track.isEmpty ? "" : (trackTotal.isEmpty ? track : "\(track)/\(trackTotal)") }
}

struct AudInfo: Sendable {
    var url: URL
    var container = ""
    var codec = ""
    var profile: String? = nil
    var sampleRate: Int? = nil
    var channels: Int? = nil
    var channelLayout: String? = nil
    /// bit/s of the audio stream (falls back to the container's).
    var bitRate: Int? = nil
    var bitDepth: Int? = nil
    var isFloat = false
    var duration: Double? = nil
    var size: Int64? = nil
    var rawTags: [String: String] = [:]
    var hasCover = false
    var hasVideo = false
    var audioStreamCount = 0

    var hasAudio: Bool { audioStreamCount > 0 }
    var isLossless: Bool { AudCodecs.isLossless(codec) }
    var tags: AudTags { AudTags.from(raw: rawTags) }
    var kbps: Int? { bitRate.map { Int((Double($0) / 1000).rounded()) } }
}

enum AudProbe {
    /// Never throws for odd files: returns nil when nothing can read the file at all.
    static func read(_ url: URL, tools: ToolLocator = .shared) async -> AudInfo? {
        let env = AudEnvironment.current(tools: tools)
        if env.hasFFprobe || tools.has(.ffprobe), let info = await viaFFprobe(url, tools: tools) { return info }
        return await viaAVFoundation(url)
    }

    // MARK: ffprobe

    static func viaFFprobe(_ url: URL, tools: ToolLocator) async -> AudInfo? {
        guard let exe = tools.url(.ffprobe) else { return nil }
        let args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "--", url.path]
        guard let out = try? await ProcessRunner.run(exe, args, captureStdout: true, maxCapturedBytes: 4_000_000, allowNonZeroExit: false) else { return nil }
        return parse(ffprobeJSON: out.stdout, url: url)
    }

    static func parse(ffprobeJSON text: String, url: URL) -> AudInfo? {
        guard let data = text.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var info = AudInfo(url: url)
        let format = root["format"] as? [String: Any] ?? [:]
        info.container = format["format_name"] as? String ?? ""
        info.duration = (format["duration"] as? String).flatMap(Double.init)
        info.size = (format["size"] as? String).flatMap(Int64.init)
        let formatBitRate = (format["bit_rate"] as? String).flatMap(Int.init)
        var tags: [String: String] = [:]
        for (k, v) in (format["tags"] as? [String: Any] ?? [:]) { if let s = v as? String { tags[k.lowercased()] = s } }
        let streams = root["streams"] as? [[String: Any]] ?? []
        var audioSeen = 0
        for s in streams {
            let type = s["codec_type"] as? String
            let disposition = s["disposition"] as? [String: Any]
            if type == "video" {
                if (disposition?["attached_pic"] as? Int) == 1 || (s["codec_name"] as? String).map({ ["mjpeg", "png", "bmp", "gif"].contains($0) }) == true { info.hasCover = true } else { info.hasVideo = true }
            }
            guard type == "audio" else { continue }
            audioSeen += 1
            if audioSeen > 1 { continue }
            info.codec = s["codec_name"] as? String ?? ""
            info.profile = s["profile"] as? String
            info.sampleRate = (s["sample_rate"] as? String).flatMap(Int.init)
            info.channels = s["channels"] as? Int
            info.channelLayout = s["channel_layout"] as? String
            info.bitRate = (s["bit_rate"] as? String).flatMap(Int.init)
            if let d = (s["duration"] as? String).flatMap(Double.init), info.duration == nil { info.duration = d }
            let rawBits = (s["bits_per_raw_sample"] as? String).flatMap(Int.init)
            let sampleBits = s["bits_per_sample"] as? Int
            let fmt = s["sample_fmt"] as? String ?? ""
            info.isFloat = fmt.hasPrefix("flt") || fmt.hasPrefix("dbl")
            if let b = rawBits, b > 0 { info.bitDepth = b }
            else if let b = sampleBits, b > 0 { info.bitDepth = b }
            else if info.isFloat { info.bitDepth = 32 }
            else if AudCodecs.isLossless(info.codec) || info.codec.hasPrefix("pcm_") {
                info.bitDepth = fmt.hasPrefix("s16") ? 16 : (fmt.hasPrefix("s32") ? 32 : (fmt.hasPrefix("u8") ? 8 : nil))
            }
            for (k, v) in (s["tags"] as? [String: Any] ?? [:]) { if let str = v as? String, tags[k.lowercased()] == nil { tags[k.lowercased()] = str } }
        }
        info.audioStreamCount = audioSeen
        if info.bitRate == nil, !info.isLossless, info.audioStreamCount == 1 { info.bitRate = formatBitRate }
        if info.bitRate == nil, info.codec.hasPrefix("pcm_"), let r = info.sampleRate, let c = info.channels, let b = info.bitDepth { info.bitRate = r * c * b }
        info.rawTags = tags
        // Gapless data (iTunSMPB, written by Apple's encoder and by this app): the container's duration includes the encoder's priming and padding
        // (about 66 ms for AAC, 136 ms for HE-AAC); the number of valid frames is the real length.
        if let smpb = tags["itunsmpb"], let rate = info.sampleRate, rate > 0 {
            let words = smpb.split(separator: " ")
            // Only when it agrees with the container (HE-AAC counts its frames at the core rate, which would halve the length).
            if words.count >= 4, let valid = UInt64(words[3], radix: 16), valid > 0, let container = info.duration {
                let exact = Double(valid) / Double(rate)
                if exact <= container, container - exact < 0.25 { info.duration = exact }
            }
        }
        return info
    }

    // MARK: AVFoundation

    static func viaAVFoundation(_ url: URL) async -> AudInfo? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        var info = AudInfo(url: url)
        info.audioStreamCount = tracks.count
        info.container = url.pathExtension.lowercased()
        if let d = try? await asset.load(.duration), d.isNumeric { info.duration = d.seconds }
        info.size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        if let t = tracks.first {
            if let descs = try? await t.load(.formatDescriptions), let d = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                info.sampleRate = Int(asbd.mSampleRate)
                info.channels = Int(asbd.mChannelsPerFrame)
                info.codec = codecName(asbd.mFormatID)
                if asbd.mBitsPerChannel > 0 { info.bitDepth = Int(asbd.mBitsPerChannel) }
                info.isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            }
            if let rate = try? await t.load(.estimatedDataRate), rate > 0 { info.bitRate = Int(rate) }
        }
        var tags: [String: String] = [:]
        for item in (try? await asset.load(.metadata)) ?? [] {
            if item.commonKey == .commonKeyArtwork { info.hasCover = true; continue }
            guard let (key, value) = await tagPair(item) else { continue }
            if tags[key] == nil { tags[key] = value }
        }
        info.rawTags = tags
        return info.hasAudio ? info : nil
    }

    private static func tagPair(_ item: AVMetadataItem) async -> (String, String)? {
        let key: String?
        if let c = item.commonKey {
            switch c {
            case .commonKeyTitle: key = "title"
            case .commonKeyArtist: key = "artist"
            case .commonKeyAlbumName: key = "album"
            case .commonKeyType: key = "genre"
            case .commonKeyCreationDate: key = "date"
            case .commonKeyDescription: key = "comment"
            default: key = nil
            }
        } else {
            switch item.identifier {
            case .iTunesMetadataAlbumArtist: key = "album_artist"
            case .iTunesMetadataComposer: key = "composer"
            case .iTunesMetadataUserComment: key = "comment"
            case .iTunesMetadataUserGenre: key = "genre"
            case .id3MetadataTrackNumber: key = "track"
            case .id3MetadataPartOfASet: key = "disc"
            case .id3MetadataYear, .id3MetadataRecordingTime: key = "date"
            case .id3MetadataComposer: key = "composer"
            case .id3MetadataBand: key = "album_artist"
            default: key = nil
            }
        }
        guard let key, let s = try? await item.load(.stringValue), !s.isEmpty else { return nil }
        return (key, s)
    }

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "aac"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatOpus: return "opus"
        case kAudioFormatAC3: return "ac3"
        case kAudioFormatEnhancedAC3: return "eac3"
        case kAudioFormatLinearPCM: return "pcm_s16le"
        default: return "audio"
        }
    }
}

// MARK: Source probe (facts and chips for the Studio inspector and for conditions)

struct AudioSourceProbe: SourceProbe {
    func probe(_ item: FileItem) async -> SourceInfo {
        let out = SourceInfo(url: item.url, kind: item.kind)
        guard let info = await AudProbe.read(item.url) else { return out }
        return Self.sourceInfo(from: info, kind: item.kind)
    }

    /// Facts follow the conventional keys of Core/SourceInfo.swift.
    static func sourceInfo(from info: AudInfo, kind: FileKind) -> SourceInfo {
        var out = SourceInfo(url: info.url, kind: kind)
        func set(_ key: String, _ value: OptionValue?) { if let value { out.facts[key] = value } }
        set("container", info.container.isEmpty ? nil : .string(info.container))
        set("duration", info.duration.map { .double($0) })
        set("size", info.size.map { .double(Double($0)) })
        set("bitrate", info.bitRate.map { .int($0) })
        out.facts["audio.count"] = .int(info.audioStreamCount)
        out.facts["video.count"] = .int(info.hasVideo ? 1 : 0)
        if info.hasAudio {
            set("audio.0.codec", .string(info.codec))
            set("audio.0.channels", info.channels.map { .int($0) })
            set("audio.0.rate", info.sampleRate.map { .int($0) })
            set("audio.0.bitrate", info.bitRate.map { .int($0) })
            set("audio.0.bitdepth", info.bitDepth.map { .int($0) })
            out.facts["audio.0.lossless"] = .bool(info.isLossless)
        }
        out.facts["audio.hasCover"] = .bool(info.hasCover)
        let tags = info.tags
        for (_, name) in AudioKeys.tagFields where !tags[name].isEmpty { out.facts["audio.tag.\(name)"] = .string(tags[name]) }

        out.chips = chips(for: info)
        if info.hasAudio {
            out.streams = [SourceStream(kind: .audio, index: 0, title: AudCodecs.display(info.codec, profile: info.profile),
                                        detail: detail(info), language: nil, isDefault: true, facts: [:])]
        }
        if !info.isLossless, let k = info.kbps, k > 0, k < 96 {
            out.warnings.append(L10n("Low bit rate (\(k) kbit/s): converting will not improve the sound.", "Низкий битрейт (\(k) кбит/с): конвертация не улучшит звук."))
        }
        if info.audioStreamCount > 1 {
            out.warnings.append(L10n("The file has \(info.audioStreamCount) audio tracks; the first one is used.", "В файле несколько звуковых дорожек (\(info.audioStreamCount)); используется первая."))
        }
        return out
    }

    static func chips(for info: AudInfo) -> [SourceChip] {
        var chips: [SourceChip] = []
        if info.hasAudio { chips.append(SourceChip(symbol: "waveform", text: AudCodecs.display(info.codec, profile: info.profile))) }
        if let r = info.sampleRate { chips.append(SourceChip(symbol: nil, text: AudRates.label(r))) }
        if let c = info.channels { chips.append(SourceChip(symbol: nil, text: channelsText(c))) }
        if let k = info.kbps, k > 0 { chips.append(SourceChip(symbol: nil, text: "\(k) kbit/s")) }
        if let b = info.bitDepth, info.isLossless { chips.append(SourceChip(symbol: nil, text: info.isFloat ? "32-bit float" : "\(b)-bit")) }
        if let d = info.duration { chips.append(SourceChip(symbol: "clock", text: Util.formatTime(d))) }
        if info.hasCover { chips.append(SourceChip(symbol: "photo", text: L("Cover", "Обложка"))) }
        return chips
    }

    static func channelsText(_ c: Int) -> String {
        switch c {
        case 1: return L("Mono", "Моно")
        case 2: return L("Stereo", "Стерео")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return L("\(c) channels", "каналов: \(c)")
        }
    }

    private static func detail(_ info: AudInfo) -> String {
        [info.sampleRate.map(AudRates.label), info.channels.map(channelsText), info.kbps.map { "\($0) kbit/s" }].compactMap { $0 }.joined(separator: " · ")
    }
}
