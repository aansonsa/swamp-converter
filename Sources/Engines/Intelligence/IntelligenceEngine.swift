import Foundation

// MODULE intelligence (owner: on-device intelligence engineer). Prefix for new top-level types: Speech* / Transcri* / Scrub* / Cutout* / Clipboard*.
// Files: Sources/Engines/Intelligence/** (Speech, Vision, Privacy, Clipboard).
// Spec: the LIFE-IMPROVER block B, C, D, E of the project brief; spec/backends.md 3.9 (Vision), fact 8; spec/platform.md 4 (Vision / PDFKit), 8 (pasteboard);
//       spec/appfeatures.md 7.6 (incoming folder: `AppPaths.incomingFolder`).
//
// Everything runs on this Mac, offline. Speech and Vision are linked system frameworks (mapped from the dyld shared cache at launch, which costs next to nothing), but nothing
// of them runs before first use: registration only stores closures (tested), language assets and models are looked up when a transcript or a cut-out is asked for.
// A feature whose model / language is not available is hidden or shown disabled with a calm hint (capability ids `native.speech.*`, `native.vision.foreground`).
//
//   B  Transcription  audio/video -> TXT / SRT / VTT with timestamps via Apple's Speech framework (macOS 26 SpeechAnalyzer / SpeechTranscriber, or
//                     on-device SFSpeechRecognizer); Russian, English, Latvian verified with small experiments; optional burn-in of the subtitles
//   C  Background removal   image -> PNG / WebP with transparency (VNGenerateForegroundInstanceMaskRequest), optional crop-to-subject + background colour
//   D  Share-safe scrub     a Tools sector for every kind that strips location + camera metadata and SHOWS what was removed
//   E  Clipboard source     an image on the clipboard (a screenshot) becomes a file the wheel can convert / compress / cut out; "Paste as file" puts results back

enum IntelligenceEngine {
    /// Registers `speech.transcribe` (audio + video, Tools), `image.removebg` (image, Tools), `scrub.image`, `scrub.video`, `scrub.audio`, `scrub.pdf` (Tools)
    /// and the capability probes. Called after the base engines (the sectors follow "Compress" / "No metadata").
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(IntelligenceCatalog.operations())
        SpeechCapabilities.register()
        VisionCapabilities.register()
    }

    #if !SC_SHIPPING
    static func registerSelfTests() { IntelligenceTests.register() }
    #endif
}

enum IntelligenceCatalog {
    @MainActor
    static func operations() -> [Operation] {
        [TranscribeOperation(meta: .make("speech.transcribe", .tools, .audio, L10n("Transcribe", "Расшифровка"), sub: L10n("speech to text", "речь в текст"), symbol: "text.bubble",
                                         schema: SpeechSchemas.transcribeID, inputs: Formats.audioInputs.union(Formats.videoInputs), suffix: L10n("transcript", "расшифровка"),
                                         concurrency: .video)),
         RemoveBackgroundOperation(meta: .make("image.removebg", .tools, .image, L10n("Remove background", "Убрать фон"), sub: L10n("transparent PNG", "прозрачный PNG"), symbol: "person.crop.rectangle",
                                               schema: CutoutSchemas.removeBackgroundID, inputs: Formats.imageAndRawInputs, suffix: L10n("cutout", "без фона"))),
        ] + ScrubCatalog.operations()
    }
}
