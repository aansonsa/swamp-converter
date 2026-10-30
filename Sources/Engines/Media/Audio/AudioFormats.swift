import Foundation

// Pure tables of the audio module: targets (container + codec pairs), sample rates, bit depths, bitrate ladders.
// Nothing here touches the file system, so everything is unit-testable.

/// A container + codec pair the person can choose. `auto` and `same` are resolved per file (`AudSmart`).
enum AudTarget: String, CaseIterable, Sendable {
    case auto, same, mp3, aac, alac, flac, wav, aiff, caf, opus, ogg, ac3, eac3, m4b, m4r

    var isConcrete: Bool { self != .auto && self != .same }

    /// File extension of the produced file ("" for the two meta targets).
    var fileExtension: String {
        switch self {
        case .auto, .same: return ""
        case .aac, .alac: return "m4a"
        default: return rawValue
        }
    }

    var isLossless: Bool { [.alac, .flac, .wav, .aiff, .caf].contains(self) }
    var isPCM: Bool { [.wav, .aiff, .caf].contains(self) }
    var isLossy: Bool { isConcrete && !isLossless }
    /// AAC codec inside an MP4 family container.
    var isAAC: Bool { [.aac, .m4b, .m4r].contains(self) }
    var isMP4Family: Bool { [.aac, .alac, .m4b, .m4r].contains(self) }
    /// Encoders that exist in macOS itself (AudioToolbox through AVAudioFile). MP3, Opus-in-Ogg, Vorbis and AC-3 need ffmpeg or lame.
    var hasNativeEncoder: Bool { [.aac, .alac, .flac, .wav, .aiff, .caf, .m4b, .m4r].contains(self) }
    /// Only these targets carry a lossy bitrate / quality setting.
    var usesBitrate: Bool { isLossy }
    /// Targets whose rate control may be "quality" (VBR) as well as a bitrate.
    var hasQualityMode: Bool { [.mp3, .aac, .m4b, .m4r, .ogg].contains(self) }
    var maxChannels: Int { self == .mp3 ? 2 : 8 }

    /// Sample rates the encoder accepts; nil = any.
    var allowedRates: [Int]? {
        switch self {
        case .mp3: return [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        case .opus: return [8000, 12000, 16000, 24000, 48000]
        case .ac3, .eac3: return [32000, 44100, 48000]
        default: return nil
        }
    }

    /// ffmpeg muxer name (always passed explicitly with `-f`).
    var muxer: String {
        switch self {
        case .aac, .alac, .m4b, .m4r: return "ipod"
        case .ogg: return "ogg"
        default: return rawValue
        }
    }

    var title: L10n {
        switch self {
        case .auto: return L10n("Automatic (smart)", "Автоматически (умно)")
        case .same: return L10n("Keep the format", "Тот же формат")
        case .mp3: return L10n("MP3", "MP3")
        case .aac: return L10n("AAC (M4A)", "AAC (M4A)")
        case .alac: return L10n("Apple Lossless (M4A)", "Apple Lossless (M4A)")
        case .flac: return L10n("FLAC (lossless)", "FLAC (без потерь)")
        case .wav: return L10n("WAV", "WAV")
        case .aiff: return L10n("AIFF", "AIFF")
        case .caf: return L10n("CAF", "CAF")
        case .opus: return L10n("Opus", "Opus")
        case .ogg: return L10n("Ogg", "Ogg")
        case .ac3: return L10n("Dolby Digital (AC-3)", "Dolby Digital (AC-3)")
        case .eac3: return L10n("Dolby Digital Plus (E-AC-3)", "Dolby Digital Plus (E-AC-3)")
        case .m4b: return L10n("Audiobook (M4B)", "Аудиокнига (M4B)")
        case .m4r: return L10n("iPhone ringtone (M4R)", "Рингтон iPhone (M4R)")
        }
    }

    /// Target for a file extension key ("m4a" -> aac). Nil when the extension is not something we write.
    static func forExtension(_ key: String) -> AudTarget? {
        switch key.lowercased() {
        case "mp3": return .mp3
        case "m4a", "mp4": return .aac
        case "m4b": return .m4b
        case "m4r": return .m4r
        case "flac": return .flac
        case "wav": return .wav
        case "aiff", "aif", "aifc": return .aiff
        case "caf": return .caf
        case "opus": return .opus
        case "ogg", "oga": return .ogg
        case "ac3": return .ac3
        case "eac3": return .eac3
        default: return nil
        }
    }
}

enum AudBitDepth: String, Sendable {
    case keep, i16 = "16", i24 = "24", f32 = "32f"
    var bits: Int? { switch self { case .keep: return nil; case .i16: return 16; case .i24: return 24; case .f32: return 32 } }
}

enum AudRates {
    /// The choices of the sample-rate picker (Hz).
    static let standard = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000]

    /// The supported rate nearest to `rate` (ties go up). Rates above the maximum fall to the maximum.
    static func nearest(_ rate: Int, in allowed: [Int]) -> Int {
        guard let first = allowed.first else { return rate }
        var best = first
        var bestDistance = Double.infinity
        for a in allowed {
            let d = abs(log(Double(max(rate, 1)) / Double(a)))
            if d < bestDistance - 1e-9 || (abs(d - bestDistance) <= 1e-9 && a > best) { best = a; bestDistance = d }
        }
        return best
    }

    /// Sample rate the encoder will actually get: the requested rate (or the source's) moved onto the target's accepted set.
    static func effective(requested: Int?, source: Int?, target: AudTarget) -> Int? {
        guard let base = requested ?? source else { return nil }
        guard let allowed = target.allowedRates else { return base }
        return allowed.contains(base) ? base : nearest(base, in: allowed)
    }

    static func label(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.3g kHz", Double(hz) / 1000).replacingOccurrences(of: ".", with: Loc.shared.language == .ru ? "," : ".")
    }
}

enum AudBitrates {
    /// Values of the bitrate picker (kbit/s). 0 = automatic.
    static let ladder = [32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let extended = ladder + [384, 448, 512, 640]

    /// Accepted range per target; the engine clamps into it (and tells the log).
    static func range(for target: AudTarget, channels: Int) -> ClosedRange<Int> {
        switch target {
        case .mp3: return 32...320
        case .opus: return 6...510
        case .ogg: return 32...500
        case .ac3: return 32...640
        case .eac3: return 32...1024
        default: return 24...(channels <= 2 ? 320 : 512)
        }
    }

    static func clamp(_ kbps: Int, target: AudTarget, channels: Int) -> Int {
        let r = range(for: target, channels: channels)
        return min(max(kbps, r.lowerBound), r.upperBound)
    }

    /// The default bitrate of a target when the person leaves "automatic".
    static func defaultKbps(_ target: AudTarget, channels: Int) -> Int {
        switch target {
        case .mp3: return 192
        case .aac, .m4b, .m4r: return channels == 1 ? 128 : 256
        case .opus: return channels == 1 ? 64 : 128
        case .ogg: return 160
        case .ac3: return channels > 2 ? 448 : 192
        case .eac3: return channels > 2 ? 384 : 192
        default: return 0
        }
    }

    /// Smallest ladder step at or above `kbps` (a 130 kbit/s source gets 160).
    static func roundUp(_ kbps: Int) -> Int { extended.first(where: { $0 >= kbps }) ?? extended.last! }
}

/// Maps the single 0...100 quality slider onto each encoder's own VBR scale. Higher is always better.
enum AudQuality {
    /// libmp3lame `-q:a` V0 (best) ... V9. 78 is V2 (about 190 kbit/s), the classic default.
    static func mp3V(_ q: Int) -> Int { min(9, max(0, Int((9.0 * Double(100 - q) / 100.0).rounded()))) }
    /// AudioToolbox VBR quality 0...127 (AVEncoderAudioQualityForVBRKey).
    static func aacNativeVBR(_ q: Int) -> Int { min(127, max(0, Int((Double(q) * 127.0 / 100.0).rounded()))) }
    /// ffmpeg aac_at `-q:a` 0 (best) ... 14.
    static func aacAtQ(_ q: Int) -> Int { min(14, max(0, Int((14.0 * Double(100 - q) / 100.0).rounded()))) }
    /// libvorbis `-q:a` -1 ... 10.
    static func vorbisQ(_ q: Int) -> Double { (Double(q) / 10.0 * 10).rounded() / 10 }
    /// Approximate bitrate a quality setting stands for (used for estimates and for encoders without a VBR mode).
    static func approxKbps(target: AudTarget, quality q: Int) -> Int {
        switch target {
        case .mp3: return [245, 225, 190, 175, 165, 130, 115, 100, 85, 65][mp3V(q)]
        case .aac, .m4b, .m4r: return Int((64.0 + Double(q) * 1.92).rounded())
        case .ogg: return Int((64.0 + Double(q) * 1.9).rounded())
        case .opus: return Int((32.0 + Double(q) * 2.24).rounded())
        default: return 192
        }
    }
}

enum AudCodecs {
    private static let lossless: Set<String> = ["flac", "alac", "wavpack", "ape", "tta", "mlp", "truehd", "shorten", "tak"]
    static func isLossless(_ codec: String) -> Bool { codec.hasPrefix("pcm_") || lossless.contains(codec) }

    /// Wheel-style display name of a codec_name.
    static func display(_ codec: String, profile: String? = nil) -> String {
        switch codec {
        case "mp3": return "MP3"
        case "aac":
            if let p = profile, p.contains("HE-AACv2") { return "HE-AAC v2" }
            if let p = profile, p.contains("HE") { return "HE-AAC" }
            return "AAC"
        case "alac": return "Apple Lossless"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "wmav2", "wmav1": return "WMA"
        case "amr_nb", "amr_wb": return "AMR"
        default:
            if codec.hasPrefix("pcm_") { return "PCM" }
            return codec.uppercased()
        }
    }
}
