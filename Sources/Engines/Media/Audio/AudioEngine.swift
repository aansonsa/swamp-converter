import Foundation

// MODULE media-audio (owner: audio engineer). Prefix for new top-level types: Aud*.
// Spec: spec/catalog.md 3.2, 5.1 (audio presets), 6.2; spec/backends.md 3.2 and facts 4, 5, 9, 11; spec/handbrake.md 3.2, 4.3, 5.4.
// Native route first (AVAudioFile / AudioToolbox: AAC, ALAC, FLAC, WAV, AIFF, CAF); ffmpeg (+ lame) for MP3, Ogg, Opus, AC-3 and the filters
// only ffmpeg has (speed, high-pass, silence trim, limiter, fast-copy trim).
//
// Files: AudioFormats (tables) . AudioSchemas . AudioPlan (typed plan, smart targets) . AudioEnvironment (what this Mac can encode)
//        AudioProbe . AudioFFmpegArgs (pure argv) . AudioFFmpegEngine . AudioNative* (decode, DSP, encode) . AudioDSP (mixing, loudness, joiner)
//        AudioMetadata (tags, cover art) . AudioLame . AudioTranscoder (router) . AudioJoin . AudioOperations . AudioCatalog . AudioPresets . Audio*Tests

enum AudioEngine {
    @MainActor
    static func registerOperations() {
        MediaCapabilities.register()
        AudCapabilities.register()
        OperationRegistry.shared.register(AudioCatalog.operations())
        PresetStore.shared.registerBuiltins(AudioPresets.builtins)
        SourceProbeRegistry.shared.register(kinds: [.audio], probe: AudioSourceProbe())
    }
    #if !SC_SHIPPING
    static func registerSelfTests() {
        AudioTests.register()
        AudioFormatTests.register()
        AudioNativeTests.register()
        AudioOracleTests.register()
        AudioFFmpegTests.register()
        AudioGatingTests.register()
        AudioJoinTests.register()
        AudioConformance.register()
        AudioPresetTests.register()
    }
    #endif
}
