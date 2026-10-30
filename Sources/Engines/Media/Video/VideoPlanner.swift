import Foundation

// VideoPlanBuilder: resolved options + probed source + analyses + toolset -> VideoEncodePlan (pure; no file or process access except
// reading the optional external subtitle file named in the options). The rules of spec/handbrake.md 2.1 (routing), 2.12 (containers),
// 2.13 (validation V-ids) live here; the pieces are split over VideoPlanner*.swift.

/// Typed reader over resolved options: a field that is inactive (hidden, disabled, missing a capability) reads as its neutral value.
struct VOpts {
    let r: ResolvedOptions
    var values: OptionValues { r.values }
    init(_ r: ResolvedOptions) { self.r = r }

    func isActive(_ k: String) -> Bool { r.isActive(k) }
    func s(_ k: String) -> String { r.isActive(k) ? r.values.string(k) : "" }
    func i(_ k: String, _ d: Int = 0) -> Int { r.isActive(k) ? r.values.int(k, d) : d }
    func d(_ k: String, _ d: Double = 0) -> Double { r.isActive(k) ? r.values.double(k, d) : d }
    func b(_ k: String) -> Bool { r.isActive(k) && r.values.bool(k) }
    /// Seconds; nil when empty / unset / inactive.
    func time(_ k: String) -> Double? {
        guard r.isActive(k), let v = r.values[k] else { return nil }
        if case .string(let s) = v { return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Util.parseTime(s) }
        return v.asDouble
    }
    func rows(_ k: String) -> [[String: OptionValue]] { r.isActive(k) ? r.values.rows(k) : [] }
    func has(_ k: String) -> Bool { !s(k).isEmpty }
}

enum VideoPlanBuilder {
    /// resolved options + probed source + analyses + toolset -> plan. Routing of spec/handbrake.md 2.1: AVFoundation (VideoToolbox, ProRes, CoreImage)
    /// when no ffmpeg exists, ffmpeg otherwise; hardware vs software encoders with a fallback and an info note when the preferred one is missing.
    /// `capabilities` is kept for API compatibility; the planner reads the `toolset` (default: the detected one) so tests can fake any machine.
    static func build(options: ResolvedOptions, source: MediaInfo?, capabilities: Capabilities = .shared, analysis: VideoAnalysis = VideoAnalysis(),
                      toolset: MediaToolset? = nil, preferHardware: Bool = false) throws -> VideoEncodePlan {
        var planner = VideoPlanner(o: VOpts(options), src: source, an: analysis, tools: toolset ?? MediaToolset.current, preferHW: preferHardware)
        return try planner.build()
    }
}

struct VideoPlanner {
    let o: VOpts
    let src: MediaInfo?
    let an: VideoAnalysis
    let tools: MediaToolset
    let preferHW: Bool
    var plan = VideoEncodePlan()
    /// Bit depth and chroma format chosen by the codec step (used by the picture and encoder-option steps).
    var depth = 8
    var chromaKey = "4:2:0"
    var sv: MediaStreamInfo? { src?.primaryVideo }

    init(o: VOpts, src: MediaInfo?, an: VideoAnalysis, tools: MediaToolset, preferHW: Bool) {
        self.o = o; self.src = src; self.an = an; self.tools = tools; self.preferHW = preferHW
    }

    mutating func note(_ en: String, _ ru: String) { plan.notes.append(L10n(en, ru)) }

    func fail(_ key: String, _ en: String, _ ru: String) -> ConversionError { .invalidOption(key: key, reason: L10n(en, ru)) }

    // MARK: Orchestration

    mutating func build() throws -> VideoEncodePlan {
        try resolveContainer()
        plan.sourceDuration = src?.duration
        plan.sourceSize = src?.size
        plan.sourceVideoStream = sv?.index
        if plan.container == "mp3" { return try buildAudioOnly() }
        if let s = src, !s.hasVideo { throw ConversionError.message(L10n("This file has no video picture.", "В файле нет видеоизображения.")) }
        plan.backend = tools.hasFFmpeg ? .ffmpeg : .avfoundation
        try planRange()
        planPicture()
        if plan.container == "gif" { try planGif(); return plan }
        try planCodec()
        try planAudio()
        try planRate()
        assembleFilters()
        buildEncoderOptions()
        try planSubtitles()
        planChaptersAndMetadata()
        try planOverlays()
        finish()
        if plan.backend == .avfoundation {
            try checkAVFoundationRoute()
            if sv?.isHDR == true || (sv?.bitDepth ?? 8) > 8 {
                note("Without ffmpeg the picture is written in 8-bit SDR, so HDR and the extra colour depth are lost.", "Без ffmpeg картинка записывается в 8-битном SDR, поэтому HDR и дополнительная глубина цвета теряются.")
            }
        }
        return plan
    }

    // MARK: Container

    mutating func resolveContainer() throws {
        var c = o.s(VideoKeys.container)
        if c.isEmpty { c = "mp4" }
        if c == "same" {
            let sc = src?.container ?? "mp4"
            c = ["mp4", "mov", "mkv", "webm"].contains(sc) ? sc : "mp4"
        }
        plan.container = c
        plan.movFlagsFaststart = o.b(VideoKeys.faststart) && (c == "mp4" || c == "mov")
        plan.alignAV = o.b(VideoKeys.alignAV)
    }

    // MARK: Range (trim) and speed

    mutating func planRange() throws {
        let start = max(0, o.time(VideoKeys.trimStart) ?? 0)
        let end = o.time(VideoKeys.trimEnd)
        if let e = end, e <= start { throw fail(VideoKeys.trimEnd, "The end must come after the start.", "Конец должен быть позже начала.") }
        if let d = src?.duration, start >= d - 0.001, start > 0 {
            throw fail(VideoKeys.trimStart, "The start is beyond the end of the clip.", "Начало находится за концом ролика.")
        }
        plan.trimStart = start
        var effectiveEnd = end
        if let e = end, let d = src?.duration, e >= d - 0.001 { effectiveEnd = nil }
        plan.trimEnd = effectiveEnd
        let trimming = start > 0.0005 || effectiveEnd != nil
        plan.copyTrim = trimming && !o.b(VideoKeys.trimAccurate)
        let speed = max(0.25, min(4, o.d(VideoKeys.filterSpeed, 1) == 0 ? 1 : o.d(VideoKeys.filterSpeed, 1)))
        plan.picture.speed = speed
        if let base = (effectiveEnd ?? src?.duration).map({ max(0, $0 - start) }) {
            plan.outputDuration = base / speed
            plan.estimatedDuration = plan.outputDuration
        }
    }

    // MARK: Finishing

    mutating func finish() {
        plan.noAutoRotate = !o.b(VideoKeys.respectMeta) && o.isActive(VideoKeys.respectMeta)
        if plan.picture.outputSize == nil { plan.picture.outputSize = sv?.displaySize.map { ($0.width, $0.height) } }
        if plan.videoCodec != "copy", plan.rate == .none, plan.hardware { /* hardware ProRes: profile decides */ }
        plan.audioKbpsTotal = plan.audioTracks.reduce(0) { $0 + ($1.bitrateKbps ?? ($1.codec == "copy" ? Int((Double(src?.audioStreams.first?.bitRate ?? 0)) / 1000) : 128)) }
    }

    /// The AVFoundation route can only write H.264 / HEVC / ProRes into MP4 / MOV (spec/handbrake.md 5.3).
    mutating func checkAVFoundationRoute() throws {
        let ok = ["mp4", "mov"].contains(plan.container) && ["h264", "hevc", "prores", "copy"].contains(plan.videoCodec)
        guard ok else { throw ConversionError.toolMissing(.ffmpeg) }
        if plan.videoCodec == "prores" && plan.container != "mov" { throw ConversionError.toolMissing(.ffmpeg) }
    }
}
