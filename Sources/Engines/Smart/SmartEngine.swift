import Foundation

// MODULE smart (owner: smart-transcode engineer). Prefix for new top-level types: Smart* / Transcode*.
// Files: Sources/Engines/Smart/*.
// Spec: the SMART TRANSCODE block of the project brief; spec/handbrake.md 2.1 (encoder routing), 2.12 (container x codec), 0.3 (measured mappings),
//       spec/backends.md 3.2 (ffmpeg), facts 2, 3, 4 (ffmpeg build, odd sizes, AVFoundation limits); docs/ARCHITECTURE.md "Smart transcode".
//
// "Best quality AND plays everywhere" for ANY video, in one gesture:
//   Best for Apple (default)   Apple-friendly streams (H.264/HEVC in mp4/mov with AAC/ALAC) -> lossless REMUX (stream copy); VP9 / AV1 / other
//                              -> high-quality HEVC with the hvc1 tag, 10-bit when the source is 10-bit or HDR, HDR10/HLG tags + metadata kept,
//                              original resolution and frame rate (4K / 8K stay); hardware encoder (hevc_videotoolbox) by default, libx265 when
//                              "maximum quality (slow)" is on and the ffmpeg has it; audio AAC 256k (ALAC when lossless is chosen), channel layout kept
//   Maximum quality            no transcode; MKV/WebM remux where needed
//   Universal                  H.264 up to 1080p + AAC in MP4: plays on anything
// The planner is PURE (MediaProbe result -> TranscodePlan) and unit-tested; the engine runs ffmpeg; the verifier proves playability with AVFoundation.

enum SmartEngine {
    /// Registers `smart.best`, `smart.max`, `smart.universal` on the CONVERT wheel for any video ("Best for Apple" first), the schema `smart.transcode`,
    /// built-in presets, capability ids `smart.hevc.hw`, `smart.hevc.sw`, `smart.h264.hw`. Called BEFORE VideoEngine so the sector is first.
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(SmartCatalog.operations())
        PresetStore.shared.registerBuiltins(SmartPresets.builtins)
        // Cheap closures: answered (and cached by Capabilities) only when somebody asks.
        Capabilities.shared.register("smart.hevc.hw") { SmartCapabilities.current.hevcHardware }
        Capabilities.shared.register("smart.hevc.sw") { SmartCapabilities.current.libx265 }
        Capabilities.shared.register("smart.h264.hw") { SmartCapabilities.current.h264Hardware }
    }

    #if !SC_SHIPPING
    /// Planner decision tables, golden argv, quality-target measurements (size + SSIM/PSNR with ffmpeg filters), real runs on generated clips
    /// (remux of H.264, HEVC from VP9, 10-bit/HDR tags kept, odd sizes), AVFoundation playability (AVURLAsset.isPlayable + AVAssetReader reads frames),
    /// codec tag hvc1, pix_fmt, resolution, fps, duration tolerance, audio present, cancellation leaves no partial.
    static func registerSelfTests() { SmartTests.register() }
    #endif
}
