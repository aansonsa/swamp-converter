import Foundation

// AudPlan: the typed, validated reading of the audio options for ONE source file. Pure: (options, probe, environment) in, plan out.
// Routing, the ffmpeg argument builder, the native engine and the estimate all read the plan, never the raw option keys.

struct AudNorm: Equatable, Sendable {
    enum Kind: Sendable { case peak, loudness }
    var kind: Kind
    /// Target integrated loudness (LUFS) for `.loudness`; target sample peak (dBFS) for `.peak`.
    var level: Double
    /// True-peak ceiling (dBTP).
    var truePeak: Double
    var lra: Double = 11
    var twoPass: Bool
    /// The person asked for a loudness range other than loudnorm's default: only ffmpeg's loudnorm shapes the range.
    var customLRA = false

    static func from(_ v: OptionValues) -> AudNorm? {
        let two = v.bool(AudioKeys.normTwoPass, true)
        switch v.string(AudioKeys.normalize, "off") {
        case "peak": return AudNorm(kind: .peak, level: -1.0, truePeak: -1.0, twoPass: true)
        case "ebu": return AudNorm(kind: .loudness, level: -23, truePeak: -1.0, lra: 7, twoPass: two)
        case "podcast": return AudNorm(kind: .loudness, level: -16, truePeak: -1.5, twoPass: two)
        case "streaming": return AudNorm(kind: .loudness, level: -14, truePeak: -1.5, twoPass: two)
        case "custom":
            let lra = min(20, max(1, v.double(AudioKeys.normLRA, 11)))
            return AudNorm(kind: .loudness, level: v.double(AudioKeys.normLUFS, -16), truePeak: v.double(AudioKeys.normTP, -1.5), lra: lra, twoPass: two, customLRA: lra != 11)
        default: return nil
        }
    }
}

enum AudDither: String, Sendable { case none, rectangular, triangular }
enum AudTagsMode: String, Sendable { case keep, strip, custom }
enum AudCoverMode: String, Sendable { case keep, remove, replace, extract }
enum AudAACProfile: String, Sendable { case lc, he, hev2 }

struct AudPlan: Sendable {
    /// The concrete format. For a pass-through plan this is the family of the source and `fileExtension` is the source's own extension.
    var target: AudTarget
    var passthrough = false
    var fileExtension: String
    var useQuality = false
    /// Bit rate in kbit/s for lossy bitrate mode (already resolved from "automatic", clamped to the encoder's range); 0 for lossless.
    var kbps = 0
    var quality = 78
    var aacProfile: AudAACProfile = .lc
    /// nil = keep the source rate. Already moved onto the rates the encoder accepts.
    var sampleRate: Int? = nil
    /// nil = keep; 1 or 2.
    var channels: Int? = nil
    var bitDepth: AudBitDepth = .keep
    var flacLevel = 5
    var opusApplication = "audio"
    var opusVBR = "on"
    var mp3Joint = true
    var id3Version = 3
    /// `ogg` without libvorbis in ffmpeg is encoded by sox.
    var oggViaSox = false
    var gainDB = 0.0
    var norm: AudNorm? = nil
    var limiter = false
    var silenceTrim = false
    var silenceDB = -50.0
    var highpass = 0
    var eq = "flat"
    var dither: AudDither = .triangular
    var fadeIn = 0.0
    var fadeOut = 0.0
    var speed = 1.0
    var trimStart = 0.0
    var trimEnd: Double? = nil
    var trimCopy = false
    var tagsMode: AudTagsMode = .keep
    var tagEdits: [String: String] = [:]
    var coverMode: AudCoverMode = .keep
    var coverFile: URL? = nil
    var coverMax = 0
    var fitBytes: Int64? = nil
    /// Decisions taken for the person ("MP3 was not available, AAC was used"), written to the job log.
    var notes: [L10n] = []

    /// Anything besides re-encoding the sound that the ffmpeg route would do through filters.
    var needsFFmpegFeature: Bool {
        speed != 1 || highpass > 0 || eq != "flat" || silenceTrim || limiter || trimCopy || norm?.customLRA == true || (target == .flac && (flacLevel != 5 || bitDepth == .i16))
    }
    var hasDSP: Bool { gainDB != 0 || norm != nil || fadeIn > 0 || fadeOut > 0 }
    var isTrimmed: Bool { trimStart > 0 || trimEnd != nil }
    /// Duration of the produced sound in seconds, when the source duration is known.
    func outputDuration(sourceDuration: Double?) -> Double? {
        guard let d = sourceDuration else { return nil }
        let end = min(trimEnd ?? d, d)
        return max(0, end - trimStart) / max(speed, 0.01)
    }
}

enum AudPlanner {
    static let tolerance = 1.06

    /// Builds the plan. Throws `invalidOption` for impossible ranges and `toolMissing`-style errors for targets this Mac cannot write.
    /// - Parameters:
    ///   - values: resolved (or sparse) option values.
    ///   - outputExtension: the extension the caller already committed to (`video.to.mp3` creates the output first); only used when the target is `auto` / `same`.
    static func make(values rawValues: OptionValues, info: AudInfo?, inputKey: String, outputExtension: String? = nil, env: AudEnvironment) throws -> AudPlan {
        let schemaDefaults = AudioSchemas.convert(items: []).defaults()
        let v = schemaDefaults.overlaying(rawValues)
        var notes: [L10n] = []

        // Channels first: bit rate defaults depend on them.
        var channels: Int? = nil
        switch v.string(AudioKeys.channels, "keep") { case "mono": channels = 1; case "stereo": channels = 2; default: break }

        // Target.
        let requested = AudTarget(rawValue: v.string(AudioKeys.target, "aac")) ?? .aac
        var target = requested
        var passthrough = false
        var extensionOverride: String? = nil
        var compactNote: L10n? = nil
        let requestedKbps = v.int(AudioKeys.bitrate, 0)
        let useQualityRequested = v.string(AudioKeys.rateControl, "bitrate") == "quality"
        if !requested.isConcrete {
            if let ext = outputExtension, let t = AudTarget.forExtension(ext) {
                target = t
            } else if requested == .same {
                let r = AudSmart.same(inputKey: inputKey, info: info, env: env)
                target = r.target; notes += r.notes
            } else {
                let comparison = useQualityRequested ? AudQuality.approxKbps(target: .mp3, quality: v.int(AudioKeys.quality, 78)) : (requestedKbps > 0 ? requestedKbps : 128)
                let r = AudSmart.auto(inputKey: inputKey, info: info, requestedKbps: comparison, env: env)
                target = r.target; passthrough = r.passthrough; notes += r.notes
                if passthrough { extensionOverride = inputKey; compactNote = r.compactNote }
            }
        }
        if !env.canEncode(target) && !passthrough {
            if let reason = env.unavailableReason(for: target) { throw ConversionError.unsupported(reason) }
        }

        var plan = AudPlan(target: target, passthrough: passthrough, fileExtension: extensionOverride ?? target.fileExtension)
        plan.channels = channels
        if target == .mp3, (info?.channels ?? 2) > 2, channels == nil {
            plan.channels = 2
            notes.append(L10n("MP3 holds two channels at most, so the sound was mixed down to stereo.", "MP3 хранит не более двух каналов, поэтому звук сведён в стерео."))
        }
        let outChannels = plan.channels ?? min(info?.channels ?? 2, target.maxChannels)

        // Rate control.
        plan.useQuality = useQualityRequested && target.hasQualityMode
        plan.quality = v.int(AudioKeys.quality, 78)
        if target.isLossy {
            var kbps = requestedKbps
            if kbps <= 0 { kbps = AudBitrates.auto(target: target, info: info, channels: outChannels) }
            let clamped = AudBitrates.clamp(kbps, target: target, channels: outChannels)
            if clamped != kbps && requestedKbps > 0 {
                notes.append(L10n("\(kbps) kbit/s is outside the range of \(target.title.en); \(clamped) kbit/s was used.", "\(kbps) кбит/с вне диапазона формата \(target.title.ru); использовано \(clamped) кбит/с."))
            }
            plan.kbps = clamped
        }
        plan.aacProfile = AudAACProfile(rawValue: v.string(AudioKeys.aacProfile, "lc")) ?? .lc
        if plan.aacProfile != .lc && plan.useQuality { plan.aacProfile = .lc }
        if plan.aacProfile != .lc && !target.isAAC { plan.aacProfile = .lc }

        // Sound format.
        let wantedRate = Int(v.string(AudioKeys.sampleRate, "keep"))
        let effective = AudRates.effective(requested: wantedRate, source: info?.sampleRate, target: target)
        if let e = effective, e != info?.sampleRate { plan.sampleRate = e }
        if let w = wantedRate, let e = effective, w != e {
            notes.append(L10n("\(target.title.en) does not accept \(AudRates.label(w)); \(AudRates.label(e)) was used.", "\(target.title.ru) не принимает \(AudRates.label(w)); использовано \(AudRates.label(e))."))
        }
        plan.bitDepth = AudBitDepth(rawValue: v.string(AudioKeys.bitDepth, "keep")) ?? .keep
        plan.flacLevel = v.int(AudioKeys.flacLevel, 5)
        plan.opusApplication = v.string(AudioKeys.opusApp, "audio")
        plan.opusVBR = v.string(AudioKeys.opusVBR, "on")
        plan.mp3Joint = v.bool(AudioKeys.mp3Joint, true)
        plan.id3Version = v.string(AudioKeys.mp3ID3, "v23") == "v24" ? 4 : 3
        if target == .ogg && !env.hasVorbis && env.hasSoxVorbis {
            plan.oggViaSox = true
            notes.append(L10n("This ffmpeg has no libvorbis, so sox encoded the Ogg Vorbis file.", "В этом ffmpeg нет libvorbis, файл Ogg Vorbis закодирован через sox."))
        }

        // Sound.
        plan.gainDB = v.double(AudioKeys.gain, 0)
        plan.norm = AudNorm.from(v)
        plan.limiter = v.bool(AudioKeys.limiter, false)
        plan.silenceTrim = v.bool(AudioKeys.silence, false)
        plan.silenceDB = v.double(AudioKeys.silenceDB, -50)
        plan.highpass = v.int(AudioKeys.highpass, 0)
        plan.eq = ["bass", "treble", "voice"].contains(v.string(AudioKeys.eq, "flat")) ? v.string(AudioKeys.eq) : "flat"
        plan.dither = AudDither(rawValue: v.string(AudioKeys.dither, "triangular")) ?? .triangular
        plan.fadeIn = max(0, v.double(AudioKeys.fadeIn, 0))
        plan.fadeOut = max(0, v.double(AudioKeys.fadeOut, 0))
        plan.speed = max(0.25, min(4, v.double(AudioKeys.speed, 1)))

        // Range.
        plan.trimStart = max(0, v[AudioKeys.trimStart]?.asDouble ?? 0)
        plan.trimEnd = v[AudioKeys.trimEnd]?.asDouble
        plan.trimCopy = v.string(AudioKeys.trimMode, "accurate") == "copy"
        if plan.trimCopy && requested != .same {
            plan.trimCopy = false
            notes.append(L10n("Fast copy only works when the format stays the same, so the range was cut exactly.", "Быстрая копия работает, только если формат не меняется, поэтому фрагмент вырезан точно."))
        }
        if let end = plan.trimEnd {
            if end <= plan.trimStart {
                throw ConversionError.invalidOption(key: AudioKeys.trimEnd, reason: L10n("The end must come after the start.", "Конец должен быть позже начала."))
            }
        }
        if let d = info?.duration, plan.trimStart >= d {
            throw ConversionError.invalidOption(key: AudioKeys.trimStart, reason: L10n("The start is after the end of the file (\(Util.formatTime(d))).", "Начало находится после конца файла (\(Util.formatTime(d)))."))
        }

        // Tags and artwork.
        plan.tagsMode = AudTagsMode(rawValue: v.string(AudioKeys.tagsMode, "keep")) ?? .keep
        if plan.tagsMode == .custom {
            for (key, name) in AudioKeys.tagFields {
                let text = v.string(key).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { plan.tagEdits[name] = text }
            }
        }
        plan.coverMode = AudCoverMode(rawValue: v.string(AudioKeys.coverMode, "keep")) ?? .keep
        let coverPath = v.string(AudioKeys.coverFile).trimmingCharacters(in: .whitespaces)
        if plan.coverMode == .replace {
            guard !coverPath.isEmpty, FileManager.default.fileExists(atPath: coverPath) else {
                throw ConversionError.invalidOption(key: AudioKeys.coverFile, reason: L10n("Choose a picture for the cover.", "Выберите картинку для обложки."))
            }
            plan.coverFile = URL(fileURLWithPath: coverPath)
        }
        plan.coverMax = v.int(AudioKeys.coverMax, 0)

        // Size limit.
        let mb = v.double(AudioKeys.fitMB, 0)
        if mb > 0, target.isLossy, !passthrough {
            plan.fitBytes = Int64(mb * 1_000_000)
            if let d = plan.outputDuration(sourceDuration: info?.duration), d > 0 {
                let overhead = AudFit.overheadBytes(target: target, coverBytes: info?.hasCover == true && plan.coverMode != .remove ? 60_000 : 0)
                let kbps = AudFit.kbps(durationSeconds: d, targetBytes: plan.fitBytes!, overheadBytes: overhead)
                plan.kbps = AudBitrates.clamp(kbps, target: target, channels: outChannels)
                plan.useQuality = false
                if kbps < AudBitrates.range(for: target, channels: outChannels).lowerBound {
                    notes.append(L10n("The size limit is very small for this length; the lowest bit rate was used and the file may be larger.", "Лимит размера слишком мал для такой длительности; использован минимальный битрейт, файл может получиться больше."))
                }
            }
        }
        // The system AAC encoder has a floor per sample rate (stereo AAC-LC at 44.1 kHz starts at 64 kbit/s). Below it HE-AAC is the right tool, and below
        // that the sample rate steps down, so the bit rate asked for (or needed to fit a size limit) is the bit rate delivered, never silently more.
        if target.isAAC, !plan.useQuality, !passthrough, plan.aacProfile == .lc {
            let rate = plan.sampleRate ?? info?.sampleRate ?? 44_100
            let adapted = AudAAC.adapt(kbps: plan.kbps, rate: rate, channels: outChannels)
            if adapted.profile != .lc || adapted.rate != rate || adapted.kbps != plan.kbps {
                plan.aacProfile = adapted.profile
                plan.kbps = adapted.kbps
                if adapted.rate != rate { plan.sampleRate = adapted.rate }
                notes.append(L10n("\(adapted.requested) kbit/s is below what AAC-LC can do at \(AudRates.label(rate)); \(adapted.profile == .lc ? "" : "HE-AAC")\(adapted.rate != rate ? " at \(AudRates.label(adapted.rate))" : "") was used to deliver it.",
                                  "\(adapted.requested) кбит/с меньше, чем AAC-LC даёт на \(AudRates.label(rate)); чтобы получить его, использован \(adapted.profile == .lc ? "" : "HE-AAC")\(adapted.rate != rate ? " на \(AudRates.label(adapted.rate))" : "")."))
            }
        }
        // A file is only kept untouched when nothing else is asked of it.
        if plan.passthrough {
            let untouched = plan.tagsMode == .keep && plan.coverMode == .keep && !plan.hasDSP && !plan.isTrimmed && plan.sampleRate == nil
                && plan.channels == nil && plan.speed == 1 && plan.highpass == 0 && plan.eq == "flat" && !plan.silenceTrim && !plan.limiter
            if untouched, let n = compactNote { notes.append(n) } else { plan.passthrough = false; plan.fileExtension = target.fileExtension }
        }
        plan.notes = notes
        return plan
    }
}

extension AudBitrates {
    /// "Automatic" bit rate: the next ladder step above the source's bit rate when the source is lossy (never above the target's own default),
    /// the target's default otherwise.
    static func auto(target: AudTarget, info: AudInfo?, channels: Int) -> Int {
        let def = defaultKbps(target, channels: channels)
        guard let info, !info.isLossless, let k = info.kbps, k > 0 else { return def }
        return max(64, min(def, roundUp(k)))
    }
}

/// What the system AAC encoder (AudioToolbox on macOS 26) accepts: the lowest and highest total bit rate per profile, sample rate and channel count.
/// The native engine still asks the encoder for the nearest applicable value; this table only decides between LC, HE and a lower sample rate.
enum AudAAC {
    struct Plan { var profile: AudAACProfile; var rate: Int; var kbps: Int; var requested: Int }

    static func floorKbps(_ profile: AudAACProfile, rate: Int, channels: Int) -> Int {
        let stereo = channels >= 2
        switch profile {
        case .lc:
            switch rate {
            case 44_100...: return stereo ? 64 : 32
            case 32_000...: return stereo ? 48 : 24
            case 22_050...: return stereo ? 32 : 16
            case 16_000...: return stereo ? 24 : 12
            default: return stereo ? 16 : 8
            }
        case .he, .hev2:
            switch rate {
            case 44_100...: return stereo ? 32 : 16
            case 32_000...: return stereo ? 24 : 12
            case 22_050...: return stereo ? 20 : 10
            default: return stereo ? 20 : 10
            }
        }
    }

    static func ceilingKbps(_ profile: AudAACProfile, channels: Int) -> Int {
        profile == .lc ? (channels >= 2 ? 320 : 256) : (channels >= 2 ? 80 : 40)
    }

    /// LC when the bit rate fits; else HE at the same rate; else HE at the highest lower rate that accepts it; else the lowest HE bit rate there is.
    static func adapt(kbps: Int, rate: Int, channels: Int) -> Plan {
        let keep = Plan(profile: .lc, rate: rate, kbps: kbps, requested: kbps)
        guard kbps < floorKbps(.lc, rate: rate, channels: channels) else { return keep }
        if kbps >= floorKbps(.he, rate: rate, channels: channels) { return Plan(profile: .he, rate: rate, kbps: kbps, requested: kbps) }
        for r in [32_000, 24_000, 22_050, 16_000] where r < rate {
            if kbps >= floorKbps(.he, rate: r, channels: channels) { return Plan(profile: .he, rate: r, kbps: kbps, requested: kbps) }
        }
        return Plan(profile: .he, rate: min(rate, 16_000), kbps: floorKbps(.he, rate: 16_000, channels: channels), requested: kbps)
    }
}

/// Smallest-file maths for the "fit under N MB" field.
enum AudFit {
    /// Bytes the container, tags and cover add on top of the audio payload.
    static func overheadBytes(target: AudTarget, coverBytes: Int) -> Int64 {
        let base: Int64 = target.isMP4Family ? 4_000 : 1_500
        return base + Int64(coverBytes)
    }

    /// Constant bit rate (kbit/s) that lands just under `targetBytes`. A 1.5 percent margin covers VBR drift in "average" modes.
    static func kbps(durationSeconds: Double, targetBytes: Int64, overheadBytes: Int64) -> Int {
        guard durationSeconds > 0 else { return 0 }
        let payload = Double(max(0, targetBytes - overheadBytes)) * 0.985
        return max(1, Int((payload * 8 / durationSeconds / 1000).rounded(.down)))
    }
}

/// Which concrete format "keep the format" and "automatic" mean for one file.
enum AudSmart {
    static func same(inputKey: String, info: AudInfo?, env: AudEnvironment) -> (target: AudTarget, notes: [L10n]) {
        var t: AudTarget
        switch inputKey {
        case "mp3": t = .mp3
        case "m4a", "mp4", "m4v", "mov": t = info?.codec == "alac" ? .alac : .aac
        case "m4b": t = .m4b
        case "aac": t = .aac
        case "wav": t = .wav
        case "aiff": t = .aiff
        case "flac": t = .flac
        case "caf": t = .caf
        case "ogg": t = .ogg
        case "opus": t = .opus
        case "ac3": t = .ac3
        default: t = env.canEncodeMP3 ? .mp3 : .aac     // wma, amr, mka and video containers
        }
        if inputKey == "wma" || inputKey == "amr" || inputKey == "mka" { t = env.canEncodeMP3 ? .mp3 : .aac }
        if !env.canEncode(t) {
            return (.aac, [L10n("\(t.title.en) cannot be written on this Mac, so AAC was used.", "Формат \(t.title.ru) недоступен на этом Mac, использован AAC.")])
        }
        return (t, [])
    }

    static func auto(inputKey: String, info: AudInfo?, requestedKbps: Int, env: AudEnvironment) -> (target: AudTarget, passthrough: Bool, notes: [L10n], compactNote: L10n?) {
        guard let info, info.hasAudio else { return (env.canEncodeMP3 ? .mp3 : .aac, false, [], nil) }
        var t: AudTarget
        switch info.codec {
        case "mp3": t = .mp3
        case "aac": t = inputKey == "m4b" ? .m4b : .aac
        case "opus": t = env.hasOpus ? .opus : .aac
        case "vorbis": t = env.canEncode(.ogg) ? .ogg : (env.hasOpus ? .opus : .aac)
        default: t = .aac      // lossless and everything else: AAC is the best small format that plays on every Apple device
        }
        var notes: [L10n] = []
        if !env.canEncode(t) { t = .aac; notes.append(L10n("MP3 is not available here, so AAC was used.", "MP3 здесь недоступен, использован AAC.")) }
        // A file that is already as small as requested is kept: re-encoding it could only make it worse.
        if !info.isLossless, let k = info.kbps, k > 0, Double(k) <= Double(requestedKbps) * tolerance, ["mp3", "aac", "opus", "vorbis"].contains(info.codec) {
            return (t, true, notes, L10n("The file is already compact (\(k) kbit/s), so it was kept as it is.", "Файл уже лёгкий (\(k) кбит/с), поэтому он оставлен как есть."))
        }
        return (t, false, notes, nil)
    }

    private static let tolerance = AudPlanner.tolerance
}
