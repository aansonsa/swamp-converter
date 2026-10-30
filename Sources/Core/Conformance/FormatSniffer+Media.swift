import Foundation

// Container sniffing for audio and video: RIFF, FORM, Ogg, Matroska/WebM (EBML), MPEG-4 / QuickTime boxes, MPEG audio frames, ADTS, FLAC, CAF.
// Codec names follow ffprobe's vocabulary so the conformance checks can compare them with what the encoders were asked for.

extension FormatSniffer {
    static func sniffMedia(_ h: [UInt8], _ r: ByteReader) -> SniffedFormat? {
        if h.hasPrefix("RIFF"), h.count >= 16 {
            if h.hasPrefix("WAVE", at: 8) { return wav(h) }
            if h.hasPrefix("AVI ", at: 8) { return SniffedFormat(key: "avi", detail: "RIFF AVI", hasVideo: true, hasAudio: true) }
        }
        if h.hasPrefix("FORM"), h.hasPrefix("AIFF", at: 8) || h.hasPrefix("AIFC", at: 8) {
            return SniffedFormat(key: "aiff", detail: h.ascii(8..<12), codecs: [h.hasPrefix("AIFC", at: 8) ? "pcm_aifc" : "pcm_s16be"], hasAudio: true)
        }
        if h.hasPrefix("caff") { return SniffedFormat(key: "caf", detail: "Core Audio Format", hasAudio: true) }
        if h.hasPrefix("fLaC") { return SniffedFormat(key: "flac", detail: "native FLAC", codecs: ["flac"], hasAudio: true) }
        if h.hasPrefix("OggS") { return ogg(h) }
        if h.hasBytes([0x1A, 0x45, 0xDF, 0xA3]) { return matroska(h) }
        if h.count >= 12, h.hasPrefix("ftyp", at: 4) { return isoBase(r) }
        if h.hasPrefix("FLV\u{01}") { return SniffedFormat(key: "flv", detail: "Flash Video", hasVideo: true, hasAudio: true) }
        if h.hasBytes([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return SniffedFormat(key: "asf", detail: "ASF (wma / wmv)", hasVideo: true, hasAudio: true) }
        if h.hasBytes([0x00, 0x00, 0x01, 0xBA]) { return SniffedFormat(key: "mpg", detail: "MPEG program stream", hasVideo: true) }
        if h.hasPrefix("#!AMR") { return SniffedFormat(key: "amr", detail: "AMR", hasAudio: true) }
        if h.hasBytes([0x0B, 0x77]) { return SniffedFormat(key: "ac3", detail: "AC-3", codecs: ["ac3"], hasAudio: true) }
        let big = r.read(at: 0, 1200)
        if big.count >= 565, big[0] == 0x47, big[188] == 0x47, big[376] == 0x47 { return SniffedFormat(key: "ts", detail: "MPEG transport stream", hasVideo: true) }
        if big.count >= 1000, big[4] == 0x47, big[196] == 0x47, big[388] == 0x47 { return SniffedFormat(key: "ts", detail: "MPEG transport stream (M2TS)", hasVideo: true) }
        return mpegAudio(r)
    }

    // MARK: RIFF WAVE

    private static func wav(_ h: [UInt8]) -> SniffedFormat {
        var codec = "unknown"
        var detail = "RIFF WAVE"
        if h.count >= 36, h.hasPrefix("fmt ", at: 12) {
            let tag = Int(h.u16le(at: 20) ?? 0), ch = Int(h.u16le(at: 22) ?? 0), rate = Int(h.u32le(at: 24) ?? 0), bits = Int(h.u16le(at: 34) ?? 0)
            let kind: String
            switch tag {
            case 1: kind = "pcm_s\(bits)le"
            case 3: kind = "pcm_f\(bits)le"
            case 0xFFFE: kind = "pcm_s\(bits)le (extensible)"
            case 0x55: kind = "mp3"
            case 0x11: kind = "adpcm_ima_wav"
            default: kind = String(format: "format 0x%04x", tag)
            }
            codec = kind
            detail += " \(kind) \(rate) Hz \(ch) ch"
        }
        return SniffedFormat(key: "wav", detail: detail, codecs: [codec], hasAudio: true)
    }

    // MARK: Ogg

    private static func ogg(_ h: [UInt8]) -> SniffedFormat {
        guard h.count > 27 else { return SniffedFormat(key: "ogg", detail: "Ogg, truncated", hasAudio: true) }
        let segments = Int(h[26])
        let payload = 27 + segments
        let p = Array(h.dropFirst(min(payload, h.count)).prefix(16))
        if p.hasBytes([0x01]) , p.hasPrefix("vorbis", at: 1) { return SniffedFormat(key: "ogg", detail: "Ogg Vorbis", codecs: ["vorbis"], hasAudio: true) }
        if p.hasPrefix("OpusHead") { return SniffedFormat(key: "opus", detail: "Ogg Opus", codecs: ["opus"], hasAudio: true) }
        if p.hasBytes([0x7F]), p.hasPrefix("FLAC", at: 1) { return SniffedFormat(key: "oga", detail: "Ogg FLAC", codecs: ["flac"], hasAudio: true) }
        if p.hasBytes([0x80]), p.hasPrefix("theora", at: 1) { return SniffedFormat(key: "ogv", detail: "Ogg Theora", codecs: ["theora"], hasVideo: true) }
        if p.hasPrefix("Speex") { return SniffedFormat(key: "spx", detail: "Ogg Speex", codecs: ["speex"], hasAudio: true) }
        return SniffedFormat(key: "ogg", detail: "Ogg, unknown codec", hasAudio: true)
    }

    // MARK: Matroska / WebM

    private static func matroska(_ h: [UInt8]) -> SniffedFormat {
        // EBML header element: id (4 bytes), size (vint), then children; DocType is element 0x4282.
        var i = 4
        func vint() -> Int? {
            guard i < h.count else { return nil }
            let first = h[i]
            var length = 1
            var mask: UInt8 = 0x80
            while length <= 8, first & mask == 0 { length += 1; mask >>= 1 }
            guard length <= 8, i + length <= h.count else { return nil }
            var value = Int(first & (mask &- 1))
            for k in 1..<length { value = (value << 8) | Int(h[i + k]) }
            i += length
            return value
        }
        guard let headerSize = vint() else { return SniffedFormat(key: "mkv", detail: "EBML", hasVideo: true) }
        let end = min(h.count, i + headerSize)
        var docType = "matroska"
        while i + 3 <= end {
            let idStart = i
            let first = h[i]
            var idLen = 1
            var mask: UInt8 = 0x80
            while idLen <= 4, first & mask == 0 { idLen += 1; mask >>= 1 }
            guard idLen <= 4, i + idLen < end else { break }
            let id = h[idStart..<(idStart + idLen)].reduce(0) { ($0 << 8) | Int($1) }
            i += idLen
            guard let size = vint(), i + size <= h.count else { break }
            if id == 0x4282 { docType = String(decoding: h[i..<(i + size)], as: UTF8.self) }
            i += size
        }
        return SniffedFormat(key: docType == "webm" ? "webm" : "mkv", detail: "EBML DocType \(docType)", hasVideo: true, hasAudio: true)
    }

    // MARK: MPEG audio

    /// Layer III frame header at `i`: (bitrate bit/s, sample rate, frame length) or nil.
    static func mp3Header(_ b: [UInt8], at i: Int) -> (bitrate: Int, rate: Int, length: Int)? {
        guard i >= 0, i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let versionBits = Int(b[i + 1] >> 3) & 3          // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
        let layerBits = Int(b[i + 1] >> 1) & 3            // 1 = Layer III
        guard versionBits != 1, layerBits == 1 else { return nil }
        let brIndex = Int(b[i + 2] >> 4), srIndex = Int(b[i + 2] >> 2) & 3
        guard brIndex != 0, brIndex != 15, srIndex != 3 else { return nil }
        let mpeg1 = versionBits == 3
        let table1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let table2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let bitrate = (mpeg1 ? table1 : table2)[brIndex] * 1000
        let rates = mpeg1 ? [44100, 48000, 32000] : (versionBits == 2 ? [22050, 24000, 16000] : [11025, 12000, 8000])
        let rate = rates[srIndex]
        let pad = Int(b[i + 2] >> 1) & 1
        let length = (mpeg1 ? 144 : 72) * bitrate / rate + pad
        return (bitrate, rate, length)
    }

    private static func mpegAudio(_ r: ByteReader) -> SniffedFormat? {
        let h = r.head(16)
        var start: UInt64 = 0
        if h.hasPrefix("ID3"), h.count >= 10 {
            let size = (UInt64(h[6]) << 21) | (UInt64(h[7]) << 14) | (UInt64(h[8]) << 7) | UInt64(h[9])
            start = 10 + size + ((h[5] & 0x10) != 0 ? 10 : 0)
        }
        // The frame sync follows the tag directly or after a little padding; frames are checked in pairs to avoid false positives.
        let window = r.read(at: start, 8192)
        guard window.count >= 8 else {
            return start > 0 ? SniffedFormat(key: "mp3", detail: "ID3v2 tag without frames", codecs: ["mp3"], hasAudio: true) : nil
        }
        for i in 0..<(window.count - 4) where window[i] == 0xFF {
            if let f = mp3Header(window, at: i), i + f.length + 4 <= window.count, mp3Header(window, at: i + f.length) != nil {
                return SniffedFormat(key: "mp3", detail: "MPEG Layer III \(f.bitrate / 1000) kbit/s \(f.rate) Hz" + (start > 0 ? " with ID3v2" : ""), codecs: ["mp3"], hasAudio: true)
            }
            if i == 0, window[1] & 0xF6 == 0xF0 { return SniffedFormat(key: "aac", detail: "AAC in ADTS", codecs: ["aac"], hasAudio: true) }
        }
        return nil
    }

    // MARK: MPEG-4 / QuickTime

    struct IsoTrack: Equatable { var handler: String; var entry: String; var codec: String }
    struct IsoInfo { var major: String; var compatible: [String]; var tracks: [IsoTrack] }

    static func isoBase(_ r: ByteReader) -> SniffedFormat {
        guard let info = parseISO(r) else { return SniffedFormat(key: "mp4", detail: "ISO base media, unreadable boxes") }
        let brands = [info.major] + info.compatible
        let video = info.tracks.contains { $0.handler == "vide" }
        let audio = info.tracks.contains { $0.handler == "soun" }
        let codecs = info.tracks.filter { $0.handler == "vide" || $0.handler == "soun" || $0.handler == "sbtl" || $0.handler == "text" }.map(\.codec)
        func f(_ key: String) -> SniffedFormat {
            SniffedFormat(key: key, detail: "ftyp \(info.major.trimmingCharacters(in: .whitespaces)), tracks " + info.tracks.map { "\($0.handler):\($0.codec)" }.joined(separator: ","),
                          codecs: codecs, hasVideo: video, hasAudio: audio)
        }
        if info.tracks.isEmpty {
            if brands.contains("avif") || brands.contains("avis") { return f("avif") }
            if brands.contains(where: { ["heic", "heix", "hevc", "hevx", "heim", "heis"].contains($0) }) { return f("heic") }
            if brands.contains("mif1") { return f("heic") }
        }
        if info.major == "qt  " { return f("mov") }
        if info.major.hasPrefix("3g") { return f("3gp") }
        if !video && audio { return f("m4a") }
        return f("mp4")
    }

    /// Walks `ftyp` and the `moov > trak > mdia` tree for handler types and sample-entry codecs.
    static func parseISO(_ r: ByteReader) -> IsoInfo? {
        var major = "", compatible: [String] = [], tracks: [IsoTrack] = []
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
        var currentHandler = "", currentEntry = "", currentCodec = ""

        func walk(_ from: UInt64, _ to: UInt64, depth: Int) {
            var pos = from
            var steps = 0
            while pos + 8 <= to, steps < 4000, depth < 8 {
                steps += 1
                guard let size32 = r.u32be(at: pos) else { return }
                let type = String(decoding: r.read(at: pos + 4, 4), as: UTF8.self)
                var size = UInt64(size32), header: UInt64 = 8
                if size32 == 1 { guard let big = r.u64be(at: pos + 8) else { return }; size = big; header = 16 }
                if size32 == 0 { size = to - pos }
                guard size >= header, pos + size <= to else { return }
                let payload = pos + header, end = pos + size
                switch type {
                case "ftyp":
                    let b = r.read(at: payload, Int(min(end - payload, 128)))
                    major = b.ascii(0..<4)
                    var k = 8
                    while k + 4 <= b.count { compatible.append(b.ascii(k..<(k + 4))); k += 4 }
                case "trak":
                    currentHandler = ""; currentEntry = ""; currentCodec = ""
                    walk(payload, end, depth: depth + 1)
                    if !currentHandler.isEmpty { tracks.append(IsoTrack(handler: currentHandler, entry: currentEntry, codec: currentCodec)) }
                case "hdlr":
                    currentHandler = r.read(at: payload + 8, 4).ascii(0..<4)
                case "stsd":
                    let entry = r.read(at: payload + 8, Int(min(end - payload - 8, 400)))
                    if entry.count >= 8 {
                        currentEntry = entry.ascii(4..<8)
                        currentCodec = codecName(entry: currentEntry, body: entry)
                    }
                default:
                    if containers.contains(type) { walk(payload, end, depth: depth + 1) }
                }
                pos = end
            }
        }
        walk(0, r.size, depth: 0)
        return major.isEmpty ? nil : IsoInfo(major: major, compatible: compatible, tracks: tracks)
    }

    private static func codecName(entry: String, body: [UInt8]) -> String {
        switch entry {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "av01": return "av1"
        case "vp09": return "vp9"
        case "mp4v": return "mpeg4"
        case "jpeg", "mjpa", "mjpb": return "mjpeg"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "prores"
        case "alac": return "alac"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        case "Opus": return "opus"
        case "fLaC": return "flac"
        case "sowt", "twos", "lpcm", "in24", "in32", "fl32", "fl64": return "pcm"
        case "tx3g": return "mov_text"
        case "mp4a":
            // esds: ... 0x04 (DecoderConfigDescriptor) len objectTypeIndication ...
            if let e = indexOf(body, "esds"), let tag = (e..<min(body.count - 2, e + 24)).first(where: { body[$0] == 0x04 }) {
                var k = tag + 1
                while k < body.count, body[k] & 0x80 != 0 { k += 1 }
                k += 1
                if k < body.count { return body[k] == 0x6B || body[k] == 0x69 ? "mp3" : "aac" }
            }
            return "aac"
        default: return entry
        }
    }

    private static func indexOf(_ bytes: [UInt8], _ s: String) -> Int? {
        let p = Array(s.utf8)
        guard bytes.count >= p.count else { return nil }
        for i in 0...(bytes.count - p.count) where bytes[i] == p[0] && Array(bytes[i..<(i + p.count)]) == p { return i }
        return nil
    }
}
