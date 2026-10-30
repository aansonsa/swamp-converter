import Foundation

// 11 audio operations in wheel order (spec/catalog.md 3.2). All share the schema "audio.convert" except Join ("audio.join").
// Native targets (M4A, WAV, FLAC, AIFF), Compress, Normalize, Trim and Join work with macOS alone; MP3 / OGG / OPUS check their encoder in
// `AudioOperation.availability` (ffmpeg with the encoder, or lame for MP3).

enum AudioCatalog {
    static let inputs = Formats.audioInputs

    @MainActor
    static func operations() -> [Operation] {
        // (key, quick recipe)
        let converts: [(String, OptionValues)] = [
            ("mp3", [AudioKeys.target: "mp3", AudioKeys.rateControl: "quality", AudioKeys.quality: 78]),          // V2, about 190 kbit/s
            ("m4a", [AudioKeys.target: "aac", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 256]),
            ("wav", [AudioKeys.target: "wav"]),
            ("flac", [AudioKeys.target: "flac"]),
            ("ogg", [AudioKeys.target: "ogg", AudioKeys.rateControl: "quality", AudioKeys.quality: 50]),         // Vorbis q5
            ("opus", [AudioKeys.target: "opus", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 128]),
            ("aiff", [AudioKeys.target: "aiff"])
        ]
        var ops: [Operation] = converts.map { key, recipe in
            AudioOperation(.convert("audio.to.\(key)", .audio, to: key, symbol: "waveform", schema: AudioSchemas.convertID, inputs: inputs)) { _ in recipe }
        }
        ops.append(AudioOperation(.make("audio.compress", .tools, .audio, L10n("Compress", "Сжать"), sub: L10n("smaller, never worse", "меньше, не хуже"),
                                        symbol: "arrow.down.right.and.arrow.up.left", schema: AudioSchemas.convertID, inputs: inputs,
                                        suffix: L10n("compressed", "сжато"), passthrough: .conditional)) { _ in
            // "Automatic" keeps the family of the source and leaves a file that is already compact untouched (the original re-encoded everything to MP3).
            [AudioKeys.target: "auto", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 128]
        })
        ops.append(AudioOperation(.make("audio.normalize", .tools, .audio, L10n("Normalize", "Выровнять"), sub: L10n("loudness", "громкость"),
                                        symbol: "slider.vertical.3", schema: AudioSchemas.convertID, inputs: inputs,
                                        suffix: L10n("normalized", "нормализовано"))) { _ in
            [AudioKeys.target: "same", AudioKeys.normalize: "podcast", AudioKeys.normTwoPass: true]          // -16 LUFS, true peak -1.5, like the original
        })
        ops.append(AudioOperation(.make("audio.trim", .tools, .audio, L10n("Trim", "Обрезать"), sub: L10n("start-end", "начало-конец"), symbol: "timer",
                                        schema: AudioSchemas.convertID, inputs: inputs, suffix: L10n("trimmed", "обрезано"),
                                        prompts: [AudioKeys.trimStart, AudioKeys.trimEnd])) { _ in
            [AudioKeys.target: "same"]
        })
        ops.append(AudioJoinOperation(meta: .make("audio.concat", .tools, .audio, L10n("Join", "Объединить"), symbol: "arrow.triangle.merge",
                                                  schema: AudioSchemas.joinID, inputs: inputs, suffix: L10n("joined", "объединено"), min: 2)))
        return ops
    }
}
