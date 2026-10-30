import Foundation

// MODULE media-video (owner: video engineer; also owns Sources/Engines/Media/Common). Prefix: Vid* / Video* / Media* / FFmpeg*.
// Spec: spec/handbrake.md section 2 (the whole HandBrake-class schema), 4.2 (video presets), 4.6 (wheel quick recipes), 5 (engine plan, oracles);
// spec/catalog.md 3.3, 5.1, 6.2; spec/backends.md 3.2 and facts 2, 3, 4, 7, 29, 30.
//
// Two back ends behind one `VideoEncodePlan`: AVFoundation (VideoToolbox, no dependency) and ffmpeg (everything else).
// Files: VideoSchemas + VideoSchema{Format,Picture,Filters,Audio,Text}  (the option pages)
//        VideoPlan . VideoPlanner{,Codec,Encoder,Picture,Audio,Streams}  (options -> typed plan, pure)
//        VideoFFmpegArgs . VideoOverlay . VideoCues  (plan -> ffmpeg argv, burned-in text, subtitle files)
//        VideoRunner . VideoAnalyzer  (analyses, passes, size attempts, fallbacks)
//        VideoAVFExporter . VideoCI  (the no-ffmpeg route)
//        VideoFrames  (frame service, thumbnails)    VideoEstimator . VideoPreview . VideoStudioSupport  (Studio)
//        VideoPresets  (built-in presets and quick recipes)    VideoOperations . VideoCatalog    VideoTests*

enum VideoEngine {
    @MainActor
    static func registerOperations() {
        MediaCapabilities.register()
        OperationRegistry.shared.register(VideoCatalog.operations())
        PresetStore.shared.registerBuiltins(VideoPresets.builtins)
        SourceProbeRegistry.shared.register(kinds: [.video], probe: VideoSourceProbe())
    }
    #if !SC_SHIPPING
    static func registerSelfTests() { VideoTests.register() }
    #endif
}
