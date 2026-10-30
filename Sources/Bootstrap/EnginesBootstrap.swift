import Foundation

// The ONE list of modules. Registration ORDER is the catalogue order of the wheels (spec/catalog.md 2.1): images, audio, smart (so "Best for Apple" is first among video), video, PDF,
// documents + slides, spreadsheets + subtitles + archives, fit-to-size, intelligence, OCR ("Extract text" stays last among tools), downloads, actions, then presets / chains / multi-output.
// This file belongs to the CORE module: it never changes when an engine is implemented (every entry point exists in the skeleton from day one).
// Every entry is cheap: registering builds operation DESCRIPTORS only; option schemas are built when first asked for.

@MainActor
enum EnginesBootstrap {
    private static var registered = false

    /// What registration cost: wall time, child processes it started (must be 0: everything heavy is lazy) and operations it added. Read by the `core.perf` self-tests
    /// and by `scripts/measure.sh`.
    struct RegistrationStats: Sendable {
        var seconds: Double = 0
        var processesStarted = 0
        var operations = 0
        var footprintGrowth: Int64 = 0
    }
    private(set) static var registrationStats = RegistrationStats()

    /// Registers every operation, preset, probe and capability of every engine. Idempotent. Called by the app, the CLI, `--self-test` and `--snapshot`.
    static func registerAll() {
        guard !registered else { return }
        registered = true
        let t0 = DispatchTime.now().uptimeNanoseconds
        let processesBefore = ProcessStats.started
        let footprintBefore = MemoryProbe.physFootprint()
        defer {
            registrationStats = RegistrationStats(seconds: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000,
                                                  processesStarted: ProcessStats.started - processesBefore,
                                                  operations: OperationRegistry.shared.staticCount,
                                                  footprintGrowth: MemoryProbe.physFootprint() - footprintBefore)
        }
        ImageEngine.registerOperations()
        AudioEngine.registerOperations()
        SmartEngine.registerOperations()
        VideoEngine.registerOperations()
        PdfEngine.registerOperations()
        DocsEngine.registerOperations()
        DataEngine.registerOperations()
        SizeFitEngine.registerOperations()
        IntelligenceEngine.registerOperations()
        PdfEngine.registerOCR()
        Downloader.registerOperations()
        ActionsEngine.registerOperations()
        AutomationEngine.registerOperations()
    }

    #if !SC_SHIPPING
    /// Every module's self-tests (called by `Harness.runSelfTests`). Suites are named after the module id so `./build.sh selftest <module>` runs one module.
    static func registerSelfTests() {
        CoreTests.register()
        SharedModule.registerSelfTests()
        ImageEngine.registerSelfTests()
        AudioEngine.registerSelfTests()
        VideoEngine.registerSelfTests()
        PdfEngine.registerSelfTests()
        DocsEngine.registerSelfTests()
        DataEngine.registerSelfTests()
        Downloader.registerSelfTests()
        SmartEngine.registerSelfTests()
        SizeFitEngine.registerSelfTests()
        IntelligenceEngine.registerSelfTests()
        CLI.registerSelfTests()
        StudioCoreModule.registerSelfTests()
        StudioWindowModule.registerSelfTests()
        ActionsEngine.registerSelfTests()
        AutomationEngine.registerSelfTests()
        WheelModule.registerSelfTests()
        SettingsModule.registerSelfTests()
        JobsModule.registerSelfTests()
        DownloadUIModule.registerSelfTests()
        AppModule.registerSelfTests()
    }
    #endif

    #if !SC_SHIPPING
    /// Every module's offscreen snapshots (called by `Harness.runSnapshots`). Names are "<module>.<what>".
    static func registerSnapshots() {
        CoreSnapshots.register()
        SharedModule.registerSnapshots()
        StudioCoreModule.registerSnapshots()
        ActionsEngine.registerSnapshots()
        StudioWindowModule.registerSnapshots()
        WheelModule.registerSnapshots()
        SettingsModule.registerSnapshots()
        JobsModule.registerSnapshots()
        DownloadUIModule.registerSnapshots()
        AppModule.registerSnapshots()
    }
    #endif
}
