import Foundation

// Quality ladder and format choice. Pure functions of `DownloadInfo`; covered by golden tests on the JSON fixtures.
//
// Rules (kept in tests):
//  * Best for Apple / Maximum: highest height, then frame rate, then HDR. At that exact height/fps/HDR the codec is chosen so that no lossy
//    step is needed later: H.264 / HEVC win over VP9 / AV1 when their bitrate is within ~15% of the best one (they can be remuxed
//    losslessly); otherwise the best-bitrate codec wins and the convert stage re-encodes it to HEVC.
//  * Universal: height <= 1080, SDR preferred, H.264 (avc1) preferred at the chosen height regardless of bitrate, AAC audio preferred.
//  * Audio modes: best audio; for M4A the AAC (m4a) stream unless Opus is more than ~15% better (then it is converted).
//  * `maxHeight` caps every video choice. DRM formats are never offered.

/// The outcome of choosing formats for one video (explicit ids so yt-dlp does not have to guess).
struct FormatChoice: Equatable, Sendable {
    var video: DownloadFormat?
    var audio: DownloadFormat?
    /// A single format that carries both streams (used when the page has no separate video-only streams).
    var muxed: DownloadFormat?
    /// The `-f` expression: explicit ids first, the generic mode expression as a fallback ("137+140/bv*+ba/b").
    var selector: String
    var estimatedBytes: Int64?

    var height: Int? { video?.height ?? muxed?.height }
    /// True when the selection is two separate streams that ffmpeg has to merge.
    var needsMerge: Bool { video != nil && audio != nil }
}

enum FormatSelector {
    /// Heights the ladder snaps to (a 1920x800 film is "1080p", a 1080x1920 phone video is "1080p").
    static let ladder = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144]
    /// Share of the best bitrate an Apple-friendly codec must reach to be preferred over VP9 / AV1.
    static let friendlyBitrateShare = 0.85

    // MARK: Quality ladder

    /// The quality ladder offered for `info`: one option per available picture height, highest first (4320p ... 144p), with the codec the
    /// "Best for Apple" choice would take at that height and a size estimate (video + best audio). Heights the page does not offer do not appear.
    static func qualityOptions(for info: DownloadInfo) -> [QualityOption] {
        let heights = Set(playable(info).compactMap { pictureHeight(of: $0) }).sorted(by: >)
        return heights.compactMap { h in
            guard let c = choose(info: info, mode: .bestForApple, maxHeight: h) else { return nil }
            let f = c.video ?? c.muxed
            guard let f else { return nil }
            var label = "\(h)p"
            if let fps = f.fps, fps >= 49 { label += "\(Int(fps.rounded()))" }
            if f.isHDR { label += " HDR" }
            return QualityOption(height: h, label: label, codec: f.codecFamily, fps: f.fps, isHDR: f.isHDR, estimatedBytes: c.estimatedBytes,
                                 selector: expression(for: .bestForApple, maxHeight: h))
        }
    }

    // MARK: Expressions

    /// The generic `-f` expression for a mode (needs no page information). `maxHeight` caps every video selector.
    /// The last alternative ignores the cap so portrait videos (whose `height` is the long side) still download.
    static func expression(for mode: DownloadMode, maxHeight: Int?) -> String {
        switch mode {
        case .audioM4A: return "ba[ext=m4a]/ba/b"
        case .audioMP3: return "ba/b"
        case .bestForApple, .maximum:
            guard let h = maxHeight, h > 0 else { return "bv*+ba/b" }
            return "bv*[height<=\(h)]+ba/b[height<=\(h)]/bv*+ba/b"
        case .universal:
            let cap = min(maxHeight.map { $0 > 0 ? $0 : 1080 } ?? 1080, 1080)
            return "bv*[height<=\(cap)][vcodec^=avc]+ba[acodec^=mp4a]/bv*[height<=\(cap)]+ba/b[height<=\(cap)]/bv*+ba/b"
        }
    }

    /// Explicit ids chosen from the page, then the generic expression as a safety net. Same as `choose(...)?.selector`.
    static func expression(for mode: DownloadMode, maxHeight: Int?, info: DownloadInfo) -> String {
        choose(info: info, mode: mode, maxHeight: maxHeight)?.selector ?? expression(for: mode, maxHeight: maxHeight)
    }

    /// For a Mac without ffmpeg (video and sound cannot be joined): the best format that already carries both, under the cap.
    static func singleFileSelector(info: DownloadInfo?, maxHeight: Int?) -> String {
        let cap = (maxHeight ?? 0) > 0 ? maxHeight : nil
        let generic = cap.map { "b[height<=\($0)]/b" } ?? "b"
        guard let info else { return generic }
        let muxed = playable(info).filter { $0.vcodec != "none" && $0.acodec != "none" && $0.height != nil }
        let capped = cap.map { c in muxed.filter { (pictureHeight(of: $0) ?? 0) <= c } } ?? muxed
        guard let best = (capped.isEmpty ? muxed : capped).max(by: { (pictureHeight(of: $0) ?? 0, $0.tbr ?? 0) < (pictureHeight(of: $1) ?? 0, $1.tbr ?? 0) }) else { return generic }
        return "\(best.id)/\(generic)"
    }

    // MARK: Choosing

    /// Chooses the video and audio formats for a mode, or nil when the page lists no usable format (then use the generic expression).
    static func choose(info: DownloadInfo, mode: DownloadMode, maxHeight: Int?) -> FormatChoice? {
        let fallback = expression(for: mode, maxHeight: maxHeight)
        let usable = playable(info)
        if mode.isAudioOnly {
            let audios = usable.filter { $0.isAudioOnly }
            guard let a = bestAudio(audios, preferAAC: mode == .audioM4A, strictAAC: false) else { return nil }
            return FormatChoice(video: nil, audio: a, muxed: nil, selector: "\(a.id)/\(fallback)", estimatedBytes: bytes(of: a, duration: info.duration))
        }
        let cap = effectiveCap(mode: mode, maxHeight: maxHeight)
        let videoCandidates = usable.filter { $0.vcodec != "none" && $0.height != nil }
        guard !videoCandidates.isEmpty else { return nil }
        let capped = cap.map { c in videoCandidates.filter { (pictureHeight(of: $0) ?? 0) <= c } } ?? videoCandidates
        // Nothing under the cap (the page's smallest picture is bigger): take the smallest there is.
        let pool = capped.isEmpty ? [videoCandidates.min { ($0.height ?? 0) < ($1.height ?? 0) }!] : capped
        let preferSDR = mode == .universal
        let best = pool.max { lhs, rhs in
            let l = rank(lhs, preferSDR: preferSDR), r = rank(rhs, preferSDR: preferSDR)
            return l.lexicographicallyPrecedes(r)
        }!
        // Same picture (height, fps bucket, HDR): pick the codec.
        let group = pool.filter { sameTier($0, best) }
        let pick = pickCodec(from: group, universal: mode == .universal)
        if pick.isVideoOnly || pick.acodec == "none" {
            let audios = usable.filter { $0.isAudioOnly }
            let audio = bestAudio(audios, preferAAC: true, strictAAC: mode == .universal)
            guard let audio else {
                // Video without any separate audio stream: let yt-dlp merge generically.
                return FormatChoice(video: pick, audio: nil, muxed: nil, selector: "\(pick.id)+ba/\(fallback)", estimatedBytes: bytes(of: pick, duration: info.duration))
            }
            let total = zip2(bytes(of: pick, duration: info.duration), bytes(of: audio, duration: info.duration))
            return FormatChoice(video: pick, audio: audio, muxed: nil, selector: "\(pick.id)+\(audio.id)/\(fallback)", estimatedBytes: total)
        }
        return FormatChoice(video: nil, audio: nil, muxed: pick, selector: "\(pick.id)/\(fallback)", estimatedBytes: bytes(of: pick, duration: info.duration))
    }

    // MARK: Helpers

    /// Formats that can be downloaded: no DRM, something to play.
    static func playable(_ info: DownloadInfo) -> [DownloadFormat] {
        info.formats.filter { !$0.hasDRM && !($0.vcodec == "none" && $0.acodec == "none") }
    }

    /// The label height of a format: letterboxed films count by width ("1080p" for 1920x800), portrait videos by their short side.
    static func pictureHeight(of f: DownloadFormat) -> Int? {
        guard let h = f.height, h > 0 else { return nil }
        guard let w = f.width, w > 0 else { return snap(h) }
        if h > w { return snap(w) }                                   // portrait
        return snap(max(h, Int((Double(w) * 9.0 / 16.0).rounded())))  // landscape, possibly letterboxed
    }

    /// Snaps to a ladder step when within 6%, else keeps the value.
    private static func snap(_ v: Int) -> Int {
        for step in ladder where abs(Double(v - step)) / Double(step) <= 0.06 { return step }
        return v
    }

    private static func effectiveCap(mode: DownloadMode, maxHeight: Int?) -> Int? {
        let user = (maxHeight ?? 0) > 0 ? maxHeight : nil
        guard mode == .universal else { return user }
        return min(user ?? 1080, 1080)
    }

    /// Sort key, larger is better: picture height, frame-rate bucket, HDR (or SDR for Universal).
    private static func rank(_ f: DownloadFormat, preferSDR: Bool) -> [Double] {
        let hdr = preferSDR ? (f.isHDR ? 0.0 : 1.0) : (f.isHDR ? 1.0 : 0.0)
        return [Double(pictureHeight(of: f) ?? 0), fpsBucket(f), hdr]
    }

    /// 60 fps and 50 fps are one tier, 24/25/30 another: a 29.97 vs 30 difference must not decide.
    private static func fpsBucket(_ f: DownloadFormat) -> Double { (f.fps ?? 0) >= 49 ? 60 : ((f.fps ?? 0) >= 40 ? 48 : 30) }

    private static func sameTier(_ a: DownloadFormat, _ b: DownloadFormat) -> Bool {
        pictureHeight(of: a) == pictureHeight(of: b) && fpsBucket(a) == fpsBucket(b) && a.isHDR == b.isHDR
    }

    private static func isFriendly(_ f: DownloadFormat) -> Bool { f.codecFamily == .h264 || f.codecFamily == .hevc }

    private static func codecRank(_ f: DownloadFormat) -> Int {
        switch f.codecFamily { case .av1: return 4; case .vp9: return 3; case .hevc: return 2; case .h264: return 1; default: return 0 }
    }

    private static func pickCodec(from group: [DownloadFormat], universal: Bool) -> DownloadFormat {
        func rate(_ f: DownloadFormat) -> Double { f.tbr ?? 0 }
        let bestRate = group.max { rate($0) < rate($1) }!
        let friendly = group.filter(isFriendly)
        if universal, let h264 = group.filter({ $0.codecFamily == .h264 }).max(by: { rate($0) < rate($1) }) { return h264 }
        if let f = friendly.max(by: { rate($0) < rate($1) }) {
            if isFriendly(bestRate) { return f }
            // Unknown bitrates: prefer the format that needs no re-encode.
            if rate(bestRate) == 0 || rate(f) == 0 { return f }
            if rate(f) >= friendlyBitrateShare * rate(bestRate) { return f }
        }
        // Several non-friendly codecs: with equal-ish bitrate the more modern one is more efficient, but the higher bitrate is the safer "best".
        if rate(bestRate) == 0 { return group.max { codecRank($0) < codecRank($1) }! }
        return bestRate
    }

    private static func bestAudio(_ audios: [DownloadFormat], preferAAC: Bool, strictAAC: Bool) -> DownloadFormat? {
        guard !audios.isEmpty else { return nil }
        // One language only: the page's original (marked "default"/"original"), else the most common, else the first.
        let languages = Set(audios.compactMap(\.language))
        var pool = audios
        if languages.count > 1 {
            let marked = audios.filter { ($0.note ?? "").localizedCaseInsensitiveContains("default") || ($0.note ?? "").localizedCaseInsensitiveContains("original") }
            if !marked.isEmpty { pool = marked } else {
                let counts = Dictionary(grouping: audios.compactMap(\.language), by: { $0 }).mapValues(\.count)
                if let top = counts.max(by: { $0.value < $1.value })?.key { pool = audios.filter { $0.language == top } }
            }
        }
        func rate(_ f: DownloadFormat) -> Double { f.tbr ?? 0 }
        func isAAC(_ f: DownloadFormat) -> Bool { f.acodec.lowercased().hasPrefix("mp4a") || f.ext == "m4a" }
        let best = pool.max { rate($0) < rate($1) }!
        guard preferAAC else { return best }
        let aac = pool.filter(isAAC).max { rate($0) < rate($1) }
        if let aac {
            if strictAAC || isAAC(best) || rate(best) == 0 || rate(aac) >= friendlyBitrateShare * rate(best) { return aac }
        }
        return best
    }

    private static func bytes(of f: DownloadFormat, duration: Double?) -> Int64? {
        if let b = f.bytes { return b }
        if let tbr = f.tbr, let d = duration, d > 0 { return Int64(tbr * 1000 / 8 * d) }
        return nil
    }

    private static func zip2(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) { case let (x?, y?): return x + y; case let (x?, nil): return x; case let (nil, y?): return y; default: return nil }
    }
}
