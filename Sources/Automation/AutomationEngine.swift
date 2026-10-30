import Foundation

// MODULE automation (owner: automation engineer). Prefix for new top-level types: Watch* / Chain* / MultiOutput* / Drop*.
// Files: Sources/Automation/*.
// Spec: spec/appfeatures.md 5 (watched folders: model, candidate filter, settle detection, loop prevention, execution, output), 6 (presets / chains), 11 (Recipe model);
//       spec/catalog.md 5.1-5.3; spec/platform.md 5-6 (FSEvents / DispatchSource notes); LIFE-IMPROVER blocks F (multi-output presets) and G (watch-folder recipes).
//
// Idle cost rule: NO timers, NO polling. Folder watching is FSEvents / DispatchSource; settle detection uses one-shot dispatch timers armed only while a file is changing.

enum AutomationEngine {
    /// Registers the provider of user presets and chains on the wheels (PresetOperations.install), the multi-output sectors (social pack, web images, favicon pack,
    /// user-defined) as a provider, and nothing else. Registered LAST (presets come after the built-in catalogue, spec/catalog.md 2.1).
    @MainActor
    static func registerOperations() {
        PresetOperations.install()
        MultiOutputRegistry.install()
    }

    /// Starts the watch service for the enabled rules (called by the app once launch finished; does nothing when there are no rules).
    @MainActor
    static func start() { WatchFolderService.shared.start() }

    #if !SC_SHIPPING
    static func registerSelfTests() { AutomationTests.register() }
    #endif
}
