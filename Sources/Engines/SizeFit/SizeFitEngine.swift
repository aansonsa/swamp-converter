import Foundation

// MODULE sizefit (owner: size-fit engineer). Prefix for new top-level types: Fit* / SizeFit* / SizeTarget*.
// Files: Sources/Engines/SizeFit/*.
// Spec: the LIFE-IMPROVER block A of the project brief ("Fit to size"); spec/handbrake.md 2.14 (size estimate), 2.3 (rate control size, two-pass),
//       3.1 (image target size), 3.3 (PDF optimise); spec/backends.md 3.2.6 (verified Studio recipes: target size), 3.3.3 (PDF recompress).
//
// "Compress to N MB" for video, audio, image and PDF with one-tap presets (WhatsApp, Telegram, Discord 10/25/50 MB, e-mail 20/25 MB, Instagram,
// custom). The result must be <= the target and within about 5 percent below it where physically possible; when the target is unreachable the
// engine downscales (video / image) or says so. The media engines call these planners for their own "rate control = size" fields; this module
// also registers one Tools-wheel sector per kind ("Fit to size") whose quick run asks only for the target.

enum SizeFitEngine {
    /// Registers `fit.video`, `fit.audio`, `fit.image`, `fit.pdf` (Tools wheel, `quickPromptKeys: [FitKeys.target]` so the quick path asks the target
    /// in the small parameter sheet) and the built-in presets. Called after the base engines so the sectors follow "Compress".
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(FitCatalog.operations())
        PresetStore.shared.registerBuiltins(FitPresets.builtins)
    }

    #if !SC_SHIPPING
    /// Size-contract tests: for generated fixtures the result is <= target and >= 95% of it when reachable; unreachable targets downscale and
    /// report it; monotonic planners; estimate vs real within the stated band; cancellation leaves no partial.
    static func registerSelfTests() { SizeFitTests.register() }
    #endif
}
