import Foundation

// Oracle coverage: every field of the audio schemas names the probe that proves it ("oracle" id). This table says which self-test runs that proof.
// A field without an entry, or an entry whose test does not exist, fails: a new option cannot ship without a test that reads real output back.

enum AudioOracleTests {
    /// oracle id -> a fragment of "suite/name" of the self-test that proves it.
    static let proofs: [String: String] = [
        // Format
        "aud.o.target": "audio.native/lossless targets",
        "aud.o.rc": "audio.ffmpeg/MP3 bit rate is honoured",
        "aud.o.bitrate": "audio.native/AAC quality knobs are monotonic",
        "aud.o.quality": "audio.native/AAC quality (VBR) mode",
        "aud.o.profile": "audio.native/AAC quality (VBR) mode",
        "aud.o.rate": "audio.native/sample rate, channels and bit depth",
        "aud.o.channels": "audio.native/stereo to mono averages",
        "aud.o.bits": "audio.native/sample rate, channels and bit depth",
        "aud.o.dither": "audio.native/dither",
        "aud.o.flacLevel": "audio.ffmpeg/FLAC through ffmpeg",
        "aud.o.opusApp": "audio.ffmpeg/Opus quick recipe",
        "aud.o.opusVbr": "audio.ffmpeg/Opus quick recipe",
        "aud.o.mp3Joint": "audio.ffmpeg/MP3 encoder details",
        "aud.o.mp3Id3": "audio.ffmpeg/MP3 encoder details",
        "aud.o.fit": "audio.ffmpeg/size limit",
        // Sound
        "aud.o.gain": "audio.native/gain is exact",
        "aud.o.norm": "audio.native/loudness normalisation",
        "aud.o.normLufs": "audio.ffmpeg/two-pass loudness",
        "aud.o.normTp": "audio.native/the true-peak ceiling",
        "aud.o.normLra": "audio.ffmpeg/loudness range option",
        "aud.o.normTwoPass": "audio.ffmpeg/two-pass loudness",
        "aud.o.limiter": "audio.ffmpeg/limiter",
        "aud.o.fadeIn": "audio.native/fade in and fade out",
        "aud.o.fadeOut": "audio.native/fade in and fade out",
        "aud.o.hp": "audio.ffmpeg/high-pass",
        "aud.o.silence": "audio.ffmpeg/silence trim",
        "aud.o.eq": "audio.ffmpeg/the tone control",
        "aud.o.silenceDb": "audio.ffmpeg/silence threshold",
        "aud.o.speed": "audio.ffmpeg/speed really re-times",
        // Range
        "aud.o.trimStart": "audio.native/trim keeps exactly",
        "aud.o.trimEnd": "audio.native/trim keeps exactly",
        "aud.o.trimMode": "audio.ffmpeg/fast-copy trim",
        // Tags and artwork
        "aud.o.tagsMode": "audio.native/tags round-trip",
        "aud.o.tag.title": "audio.native/tags round-trip", "aud.o.tag.artist": "audio.native/tags round-trip", "aud.o.tag.album": "audio.native/tags round-trip",
        "aud.o.tag.albumArtist": "audio.native/tags round-trip", "aud.o.tag.year": "audio.native/tags round-trip", "aud.o.tag.track": "audio.native/tags round-trip",
        "aud.o.tag.trackTotal": "audio.native/tags round-trip", "aud.o.tag.disc": "audio.native/tags round-trip", "aud.o.tag.genre": "audio.native/tags round-trip",
        "aud.o.tag.composer": "audio.native/tags round-trip", "aud.o.tag.comment": "audio.native/tags round-trip",
        "aud.o.coverMode": "audio.native/cover art", "aud.o.coverFile": "audio.native/cover art", "aud.o.coverMax": "audio.native/cover art",
        // Join
        "audjoin.o.order": "audio.join/natural order", "audjoin.o.rate": "audio.join/mono 44.1 kHz + stereo 48 kHz",
        "audjoin.o.channels": "audio.join/the person can override rate and channels", "audjoin.o.gap": "audio.join/silence between files",
        "audjoin.o.crossfade": "audio.join/silence between files"
    ]

    static func register() {
        let t = SelfTestRegistry.shared
        t.register("audio.oracles", "every option of the audio schemas has a registered self-test that proves its effect on real output") {
            let names = SelfTestRegistry.shared.cases.map(\.fullName)
            var missing: [String] = []
            for schema in [AudioSchemas.convert(items: []), AudioSchemas.join(items: [])] {
                for f in schema.allFields {
                    guard let proof = proofs[f.oracle] else { missing.append("\(f.key) (\(f.oracle)): no proof listed"); continue }
                    if !names.contains(where: { $0.contains(proof) }) { missing.append("\(f.key) (\(f.oracle)): no self-test named like '\(proof)'") }
                }
            }
            try expect(missing.isEmpty, "unproven options: \(missing)")
            let known = Set((AudioSchemas.convert(items: []).allFields + AudioSchemas.join(items: []).allFields).map(\.oracle))
            let stale = proofs.keys.filter { !known.contains($0) }
            try expect(stale.isEmpty, "proofs for options that no longer exist: \(stale)")
        }

        t.register("audio.oracles", "every audio operation is judged by a conformance oracle (Core's default or this module's sharper one)") {
            let registry = ConformanceRegistry.shared
            for op in AudioCatalog.operations() {
                let oracle = try unwrap(registry.oracle(for: op.meta), "\(op.meta.id) has no conformance oracle")
                try expect(oracle.id != "generic.format-and-integrity", "\(op.meta.id) is only covered by the generic fallback")
            }
        }
    }
}
