import Foundation
import CoreGraphics

// Planners are PURE (numbers in, numbers out) so the contract can be unit-tested without encoding. Engines run the plans.
// This file: shared numbers, the video plan and the audio bitrate maths. Image search: FitImageSearch.swift. PDF levels: FitPdfSearch.swift.

/// The numbers behind every plan, in one place. Each has a reason.
enum FitTuning {
    /// Fraction of the target kept free for container overhead and rate-control error. Measured on this Mac (ffmpeg 9.0.1, 8 s clip, 2 MB target):
    /// x264 two-pass lands within 0.1% of the bitrate sum, x264 single-pass ABR +0.5%, VideoToolbox H.264 +1.7%, VideoToolbox HEVC +2.6%.
    /// 1.5% plus the verify-and-retry pass keeps the result under the target and above 95% of it.
    static let safetyMargin = 0.015
    /// Bytes for the MP4 header and the sample tables that do not scale with the bitrate (matters for clips shorter than a second).
    static let fixedOverheadBytes = 4096.0
    /// The result should be at least this fraction of the target when that is physically possible (contract: within about 5 percent below).
    static let fillGoal = 0.95
    /// Where the planner aims inside the allowed band, so a small error in either direction still lands in it.
    static let aimFraction = 0.975

    /// Bits per pixel per frame below which H.264 (medium preset, two-pass) starts to look blocky on natural footage. HandBrake's own
    /// "Social 25 MB" ladder (1080p60 at 6 Mbit/s, 720p60 at 3, 540p60 at 1.5, 360p60 at 0.5) works out to 0.036 - 0.054: 0.04 is the
    /// threshold at which the planner prefers a lower rung of the ladder to a starved picture.
    static let comfortBitsPerPixel = 0.040
    /// Below this even the lowest rung is unwatchable noise: the target is reported as unreachable instead of producing garbage.
    static let hardFloorBitsPerPixel = 0.006
    /// Above this H.264 gains nothing visible (transparent for almost any footage): spare budget stays unused instead of inflating the file.
    static let ceilingBitsPerPixel = 0.30
    /// The least video bitrate that still makes a picture.
    static let minVideoKbps = 20
    /// Audio never takes more than this share of the whole budget, and never less than `minAudioKbps`.
    static let maxAudioShare = 0.20
    static let minAudioKbps = 24
    /// Heights (short side of the picture) of the downscale ladder, highest first. The source is always tried before them.
    static let ladder = [1080, 720, 540, 480, 360]
    /// Above this the planner may cap the frame rate before it gives up resolution.
    static let cappedFPS = 30.0
}

/// What a video fit run will do.
struct VideoFitPlan: Equatable, Sendable {
    var videoKbps: Int
    var audioKbps: Int
    /// Output height cap (nil = keep the source height).
    var maxHeight: Int?
    var twoPass: Bool
    /// True when `maxHeight` is lower than the source: tell the user ("The target is small, so the picture is reduced to 720p").
    var downscaled: Bool
    /// Even after the lowest allowed height the target cannot be reached (message: choose a larger size or a shorter clip).
    var unreachable: Bool
    var notes: [L10n] = []
    /// Frame-rate cap (nil = keep the source rate). Set for 50 / 60 fps footage when halving the rate keeps more resolution.
    var maxFPS: Double? = nil
}

enum VideoFit {
    /// Bitrate budget = (targetBytes x 8 / duration) - audio - container overhead (~1-2%), then a downscale ladder (source -> 1080 -> 720 -> 540 -> 480 -> 360)
    /// chosen so that bits per pixel stay above a floor that still looks acceptable (document the floor). Pure; golden-tested.
    ///
    /// Heights of the ladder are the SHORT side of the picture, so a vertical phone clip (1080 x 1920) steps down to 720 x 1280, not to 405 x 720.
    /// `sourceWidth` / `sourceHeight` are display sizes (rotation already applied).
    static func plan(durationSeconds: Double, targetBytes: Int64, audioKbps: Int, sourceWidth: Int, sourceHeight: Int, sourceFPS: Double,
                     hasAudio: Bool, allowDownscale: Bool, preferTwoPass: Bool) -> VideoFitPlan {
        plan(durationSeconds: durationSeconds, targetBytes: targetBytes, audioKbps: audioKbps, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
             sourceFPS: sourceFPS, hasAudio: hasAudio, allowDownscale: allowDownscale, preferTwoPass: preferTwoPass, codecEfficiency: 1.0)
    }

    /// Same with the efficiency of the codec: 1.0 for H.264, about 0.75 for HEVC (the same picture needs a quarter fewer bits, so the floors scale with it).
    static func plan(durationSeconds: Double, targetBytes: Int64, audioKbps: Int, sourceWidth: Int, sourceHeight: Int, sourceFPS: Double,
                     hasAudio: Bool, allowDownscale: Bool, preferTwoPass: Bool, codecEfficiency: Double) -> VideoFitPlan {
        typealias T = FitTuning
        let duration = max(durationSeconds, 0.1)
        let usableBytes = max(0, Double(targetBytes) * (1 - T.safetyMargin) - T.fixedOverheadBytes)
        let totalKbps = usableBytes * 8 / duration / 1000
        var audio = 0
        if hasAudio {
            let cap = max(T.minAudioKbps, Int(totalKbps * T.maxAudioShare))
            audio = min(max(audioKbps, T.minAudioKbps), cap)
        }
        let videoRaw = Int(totalKbps.rounded(.down)) - audio
        let eff = max(codecEfficiency, 0.1)

        let sw = sourceWidth > 0 ? sourceWidth : 1280, sh = sourceHeight > 0 ? sourceHeight : 720
        let fps = sourceFPS > 0.5 ? min(sourceFPS, 120) : 30
        let short = min(sw, sh)
        var rungs: [(w: Int, h: Int, label: Int?)] = [(even(sw), even(sh), nil)]
        if allowDownscale {
            for r in T.ladder where r < short {
                let k = Double(r) / Double(short)
                rungs.append((even(Int((Double(sw) * k).rounded())), even(Int((Double(sh) * k).rounded())), r))
            }
        }
        var fpsOptions: [Double?] = [nil]
        if fps > T.cappedFPS + 0.5 { fpsOptions.append(T.cappedFPS) }
        func bpp(_ rung: (w: Int, h: Int, label: Int?), _ cap: Double?) -> Double {
            Double(max(videoRaw, 0)) * 1000 / (Double(rung.w * rung.h) * (cap ?? fps))
        }

        var chosen = (rung: rungs[0], cap: fpsOptions[0])
        var found = false
        search: for rung in rungs {
            for cap in fpsOptions where bpp(rung, cap) >= T.comfortBitsPerPixel * eff {
                chosen = (rung, cap); found = true; break search
            }
        }
        if !found { chosen = (rungs[rungs.count - 1], fpsOptions[fpsOptions.count - 1]) }

        let density = bpp(chosen.rung, chosen.cap)
        var plan = VideoFitPlan(videoKbps: max(videoRaw, 0), audioKbps: audio, maxHeight: chosen.rung.label == nil ? nil : chosen.rung.h,
                                twoPass: preferTwoPass, downscaled: chosen.rung.label != nil, unreachable: false, maxFPS: chosen.cap)
        if videoRaw < T.minVideoKbps || density < T.hardFloorBitsPerPixel * eff {
            plan.unreachable = true
            plan.notes.append(L10n("The limit is too small for a clip this long. Choose a larger size or a shorter clip.",
                                   "Лимит слишком мал для такого длинного ролика. Выберите размер побольше или ролик покороче."))
            return plan
        }
        if let label = chosen.rung.label {
            plan.notes.append(L10n("Reduced to \(label)p to fit", "Уменьшено до \(label)p, чтобы уложиться"))
        }
        if let cap = chosen.cap {
            plan.notes.append(L10n("Frame rate limited to \(Int(cap)) fps to fit", "Частота кадров ограничена до \(Int(cap)) к/с, чтобы уложиться"))
        }
        if !found {
            plan.notes.append(L10n("The size is tight, so the picture will look soft. A larger limit or a shorter clip helps.",
                                   "Размер очень мал, поэтому картинка будет мягкой. Поможет больший лимит или более короткий ролик."))
        }
        let ceiling = Int((T.ceilingBitsPerPixel * eff * Double(chosen.rung.w * chosen.rung.h) * (chosen.cap ?? fps) / 1000).rounded(.down))
        if plan.videoKbps > ceiling {
            plan.videoKbps = max(ceiling, T.minVideoKbps)
            plan.notes.append(L10n("The picture is already at its best, so the file is smaller than the limit.",
                                   "Качество картинки уже максимальное, поэтому файл меньше лимита."))
        }
        return plan
    }

    /// Bytes a plan is expected to produce (video + audio + overhead): what the estimate shows and what the verify step compares with.
    static func expectedBytes(videoKbps: Int, audioKbps: Int, durationSeconds: Double) -> Int64 {
        let bits = Double(videoKbps + audioKbps) * 1000 * max(durationSeconds, 0.1)
        return Int64(bits / 8 * (1 + FitTuning.safetyMargin / 2) + FitTuning.fixedOverheadBytes)
    }

    /// Libx264 / hardware encoders need even dimensions.
    static func even(_ v: Int) -> Int { max(2, v - v % 2) }
}

/// The corrected value after a measured miss: proportional, on the part of the file the knob controls.
enum FitCorrection {
    /// `previous` produced `achieved` bytes of which `fixedBytes` do not depend on it. Returns the value that should land on `aimBytes`.
    static func next(previous: Double, achieved: Int64, aimBytes: Int64, fixedBytes: Int64 = 0) -> Double {
        let variable = Double(max(achieved - fixedBytes, 1))
        let wanted = Double(max(aimBytes - fixedBytes, 1))
        return previous * wanted / variable
    }

    struct Attempt: Equatable, Sendable {
        var request: Double
        var bytes: Int64
    }

    /// The next value to ask for after the attempts in `history` (what was requested -> how big the file came out), or nil when another run cannot help.
    ///
    /// Rate control is only approximately proportional, so this does not trust one ratio: once one attempt fits and one does not, the answer is interpolated
    /// BETWEEN them (secant on the measured sizes, kept strictly inside the bracket); before that it extrapolates proportionally from the closest attempt, with a
    /// small bias on the safe side. `ceiling` is the most that makes any difference (more bits show nothing), `floor` the least that still makes a file.
    static func nextRequest(history: [Attempt], aimBytes: Int64, targetBytes: Int64, fixedBytes: Int64 = 0, floor: Double, ceiling: Double) -> Double? {
        let aim = Double(aimBytes)
        let fits = history.filter { $0.bytes <= targetBytes }.max { $0.bytes < $1.bytes }
        let over = history.filter { $0.bytes > targetBytes }.min { $0.request < $1.request }
        var next: Double
        switch (fits, over) {
        case let (lo?, hi?):
            guard hi.request - lo.request > 1e-6, hi.bytes > lo.bytes else { return nil }
            let f = (aim - Double(lo.bytes)) / Double(hi.bytes - lo.bytes)
            let t = min(max(f, 0.1), 0.9)
            next = lo.request + (hi.request - lo.request) * t
        case let (nil, hi?):
            next = min(Self.next(previous: hi.request, achieved: hi.bytes, aimBytes: aimBytes, fixedBytes: fixedBytes), hi.request * 0.97)
        case let (lo?, nil):
            next = Self.next(previous: lo.request, achieved: lo.bytes, aimBytes: aimBytes, fixedBytes: fixedBytes)
            if lo.request >= ceiling { return nil }
            next = min(next, ceiling)
        default:
            return nil
        }
        next = min(max(next, floor), ceiling)
        // Not worth a run: it would repeat a request already made, or move by less than the noise of the rate control.
        if history.contains(where: { abs($0.request - next) / max($0.request, 1) < 0.01 }) { return nil }
        return next
    }
}

/// Accepted CBR / ABR bitrates and container overheads of the audio codecs the audio fit writes.
enum AudioFitCodec: String, Sendable, CaseIterable {
    case aac, mp3, opus

    init(name: String) {
        switch name.lowercased() {
        case "mp3": self = .mp3
        case "opus", "ogg", "libopus": self = .opus
        default: self = .aac
        }
    }

    var minKbps: Int { switch self { case .aac: return 24; case .mp3: return 32; case .opus: return 12 } }
    var maxKbps: Int { switch self { case .aac: return 320; case .mp3: return 320; case .opus: return 256 } }
    /// MP3 encoders only accept the classic CBR steps; AAC and Opus take any whole number.
    var steps: [Int]? { self == .mp3 ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] : nil }
    /// Measured: afconvert .m4a adds ~1.5 KB + ~0.45 KB per second of sample tables; MP3 ~2.5 KB of tags and the Xing frame; Ogg Opus ~3 KB + ~0.1 KB per second.
    var fixedBytes: Double { switch self { case .aac: return 1500; case .mp3: return 2500; case .opus: return 3000 } }
    var bytesPerSecond: Double { switch self { case .aac: return 450; case .mp3: return 0; case .opus: return 100 } }
    var fileExtension: String { switch self { case .aac: return "m4a"; case .mp3: return "mp3"; case .opus: return "opus" } }
}

enum AudioFit {
    /// Constant bitrate (kbit/s) that lands just under `targetBytes` for `durationSeconds`, rounded DOWN to a bitrate the codec accepts, never below the codec's floor.
    static func bitrateKbps(durationSeconds: Double, targetBytes: Int64, codec: String) -> Int {
        let c = AudioFitCodec(name: codec)
        let capped = rawKbps(durationSeconds: durationSeconds, targetBytes: targetBytes, codec: codec)
        if let steps = c.steps { return steps.last { $0 <= capped } ?? steps[0] }
        return capped
    }

    /// The same budget without the codec's CBR steps (what an ABR encoder can be asked for): the first guess of the MP3 loop.
    static func rawKbps(durationSeconds: Double, targetBytes: Int64, codec: String) -> Int {
        let c = AudioFitCodec(name: codec)
        guard durationSeconds > 0.05, targetBytes > 0 else { return min(max(128, c.minKbps), c.maxKbps) }
        let usable = Double(targetBytes) * 0.995 - c.fixedBytes - c.bytesPerSecond * durationSeconds
        let raw = Int((max(usable, 0) * 8 / durationSeconds / 1000).rounded(.down))
        return min(max(raw, c.minKbps), c.maxKbps)
    }

    /// Bytes a constant bitrate produces, with the codec's container overhead: used to tell "unreachable" from "fits".
    static func expectedBytes(kbps: Int, durationSeconds: Double, codec: String) -> Int64 {
        let c = AudioFitCodec(name: codec)
        return Int64(Double(kbps) * 125 * durationSeconds + c.fixedBytes + c.bytesPerSecond * durationSeconds)
    }

    /// True when even the lowest bitrate of the codec makes a file larger than the target.
    static func isReachable(durationSeconds: Double, targetBytes: Int64, codec: String) -> Bool {
        let c = AudioFitCodec(name: codec)
        return expectedBytes(kbps: c.minKbps, durationSeconds: durationSeconds, codec: codec) <= targetBytes
    }
}

struct FitResult: Sendable {
    var output: URL
    var achievedBytes: Int64
    var targetBytes: Int64
    /// achieved <= target.
    var reachedTarget: Bool { achievedBytes <= targetBytes }
    /// Fraction below the target (0.03 = 3% under). The contract: <= 0.05 where physically possible.
    var slack: Double { targetBytes > 0 ? Double(targetBytes - achievedBytes) / Double(targetBytes) : 0 }
    var notes: [L10n] = []
}

/// Calm, specific "cannot be done" messages shared by the engines.
enum FitMessages {
    static func tooSmall(kind: FitKind, smallest: Int64, target: Int64) -> ConversionError {
        let s = Util.formatBytes(smallest), t = Util.formatBytes(target)
        switch kind {
        case .image:
            return .message(L10n("Even the smallest version of this picture is about \(s), more than the limit of \(t). Choose a larger limit.",
                                 "Даже самая маленькая версия картинки занимает около \(s), это больше лимита \(t). Выберите лимит побольше."))
        case .pdf:
            return .message(L10n("This PDF cannot get below \(t) while keeping its text and vector drawings (the smallest result is \(s)). Allow converting pages to pictures or choose a larger limit.",
                                 "Этот PDF не уменьшить до \(t), сохранив текст и векторную графику (минимум \(s)). Разрешите превращать страницы в картинки или выберите лимит побольше."))
        case .audio:
            return .message(L10n("The recording is too long for \(t): even the lowest bitrate makes about \(s). Choose a larger limit or trim the recording.",
                                 "Запись слишком длинная для \(t): даже при минимальном битрейте получится около \(s). Выберите лимит побольше или обрежьте запись."))
        case .video:
            return .message(L10n("The clip could not be brought under \(t) (the smallest result is \(s)). Choose a larger limit or a shorter clip.",
                                 "Ролик не удалось уложить в \(t) (минимум \(s)). Выберите лимит побольше или ролик покороче."))
        }
    }

    static var alreadySmall: L10n {
        L10n("Already under the limit, so the file was copied unchanged.", "Файл уже меньше лимита, поэтому он скопирован без изменений.")
    }
}
