import Foundation

/// What this Mac can encode right now: a plain value so routing is a pure function (and tests can pretend ffmpeg is missing).
struct AudEnvironment: Sendable {
    var hasFFmpeg: Bool
    var hasFFprobe: Bool
    var hasLame: Bool
    var encoders: Set<String>
    var filters: Set<String>
    /// A sox that writes Ogg Vorbis (the fallback when ffmpeg has no libvorbis).
    var hasSoxVorbis = false

    /// The real machine. Reads the (cached) ffmpeg capability probe; the first call may take ~150 ms.
    static func current(tools: ToolLocator = .shared) -> AudEnvironment {
        if let o = testOverride.value { return o }
        let ff = tools.has(.ffmpeg)
        let caps = ff ? Capabilities.shared.ffmpeg() : nil
        let sox = tools.url(.sox).map { AudSox.supportsVorbis($0) } ?? false
        return AudEnvironment(hasFFmpeg: ff, hasFFprobe: tools.has(.ffprobe), hasLame: tools.has(.lame),
                              encoders: caps?.encoders ?? [], filters: caps?.filters ?? [], hasSoxVorbis: sox)
    }

    /// Self-tests set this to simulate a Mac without ffmpeg / with a smaller one. Always reset it with `defer`.
    static let testOverride = Locked<AudEnvironment?>(nil)

    static let none = AudEnvironment(hasFFmpeg: false, hasFFprobe: false, hasLame: false, encoders: [], filters: [])

    func has(encoder: String) -> Bool { hasFFmpeg && encoders.contains(encoder) }
    func has(filter: String) -> Bool { hasFFmpeg && filters.contains(filter) }

    var canEncodeMP3: Bool { has(encoder: "libmp3lame") || hasLame }
    var hasVorbis: Bool { has(encoder: "libvorbis") }
    /// Vorbis comes from libvorbis inside ffmpeg, else from sox. ffmpeg's built-in "vorbis" encoder is deliberately never used: it is experimental,
    /// stereo only and far below libvorbis in quality.
    var canEncodeVorbis: Bool { hasVorbis || hasSoxVorbis }
    var hasOpus: Bool { has(encoder: "libopus") }
    var hasAACAudioToolbox: Bool { has(encoder: "aac_at") }

    /// Can this Mac write `target` at all?
    func canEncode(_ target: AudTarget) -> Bool {
        switch target {
        case .auto, .same: return true
        case .mp3: return canEncodeMP3
        case .opus: return hasOpus
        case .ogg: return canEncodeVorbis
        case .ac3: return has(encoder: "ac3")
        case .eac3: return has(encoder: "eac3")
        default: return true
        }
    }

    /// Calm explanation for a target that cannot be written (nil when it can).
    func unavailableReason(for target: AudTarget) -> L10n? {
        guard !canEncode(target) else { return nil }
        switch target {
        case .mp3:
            return L10n("MP3 needs ffmpeg or lame. Install with: brew install ffmpeg", "Для MP3 нужен ffmpeg или lame. Установка: brew install ffmpeg")
        case .ogg:
            return L10n("Ogg Vorbis needs ffmpeg with libvorbis, or sox. Install with: brew install ffmpeg", "Для Ogg Vorbis нужен ffmpeg с libvorbis или sox. Установка: brew install ffmpeg")
        default:
            return L10n("\(target.title.en) needs ffmpeg. Install with: brew install ffmpeg", "Для \(target.title.ru) нужен ffmpeg. Установка: brew install ffmpeg")
        }
    }
}

/// Capability ids used by the schema (`requires`) and by self-tests.
enum AudCapabilities {
    static func register() {
        let c = Capabilities.shared
        c.register("native.audio.enc.mp3") { AudEnvironment.current().canEncodeMP3 }
        c.register("native.audio.enc.opus") { AudEnvironment.current().canEncode(.opus) }
        c.register("native.audio.enc.ogg") { AudEnvironment.current().canEncode(.ogg) }
        c.register("native.audio.enc.ac3") { AudEnvironment.current().canEncode(.ac3) }
        c.register("native.audio.enc.eac3") { AudEnvironment.current().canEncode(.eac3) }
        // The macOS encoders are always there; registered so presets can name them.
        for t in ["aac", "alac", "flac", "wav", "aiff", "caf"] { c.register("native.audio.enc.\(t)") { true } }
    }
}
