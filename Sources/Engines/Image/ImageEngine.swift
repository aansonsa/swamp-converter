import Foundation
import ImageIO

// MODULE image (owner: image engineer). Prefix for new top-level types: Image* / Img*.
// Spec: spec/catalog.md 1.4, 3.1, 5.1, 6.2; spec/backends.md 3.1; spec/handbrake.md 3.1 (schema), 4.4 (presets), 5.4 (oracles).
//
// Everything here goes through ImageIO / CoreGraphics first. WebP output needs `cwebp` (disabled with a hint when missing), 4:4:4 JPEG needs ffmpeg
// (disabled with a hint), ICNS goes through the built-in `iconutil`. RAW / SVG / HEIC / AVIF / WebP / JXL / ICO are read natively.
//
// Files: ImageLoader (decode) - ImageProcessor / ImageCrop / ImageGeometry (pixels) - ImageEncoder / ImageContainers / ImageExternal / ImageQuantizer / ImagePNGOptimizer (write) -
// ImageMetadata - ImageRunner (one file through the chain) - ImageOperations / ImageMergePDF (operations) - ImageSchemas / ImageOptionKeys - ImageStudio (probe, estimate,
// preview) - ImagePresets - ImageCatalog (wheel rows and quick recipes) - ImageTests*.swift / ImageTestMetrics / ImageTestSupport (self-tests and their independent read-back tools).

enum ImageEngine {
    /// Called once at startup (EnginesBootstrap.registerAll): operations, built-in presets, probe, capability checks.
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(ImageCatalog.operations())
        PresetStore.shared.registerBuiltins(ImagePresets.builtins)
        SourceProbeRegistry.shared.register(kinds: [.image, .raw], probe: ImageSourceProbe())
        ImageCapabilities.register()
    }

    #if !SC_SHIPPING
    /// Called by `--self-test`: one test per option of every schema (oracle in the field), plus the catalogue acceptance tests.
    static func registerSelfTests() { ImageTests.register() }
    #endif
}

/// Registers `native.imageio.*` capability ids so schema fields can say `.needs(["native.imageio.write.heic"])`.
enum ImageCapabilities {
    static func register() {
        for (name, uti) in [("jpeg", "public.jpeg"), ("png", "public.png"), ("heic", "public.heic"), ("avif", "public.avif"), ("tiff", "public.tiff"),
                            ("gif", "com.compuserve.gif"), ("bmp", "com.microsoft.bmp"), ("ico", "com.microsoft.ico"), ("jp2", "public.jpeg-2000"),
                            ("icns", "com.apple.icns"), ("pdf", "com.adobe.pdf"), ("psd", "com.adobe.photoshop-image"), ("tga", "com.truevision.tga-image")] {
            // Evaluated on first use (the destination list is read lazily), then cached by Capabilities.
            Capabilities.shared.register("native.imageio.write.\(name)") { ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(uti) }
        }
    }
}
