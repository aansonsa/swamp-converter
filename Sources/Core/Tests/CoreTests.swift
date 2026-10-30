import Foundation

/// Entry point of the Core self-tests (called from EnginesBootstrap.registerSelfTests).
enum CoreTests {
    static func register() {
        CoreTestsFiles.register()
        CoreTestsEngine.register()
        CoreTestsNetwork.register()
        CoreTestsRuntime.register()
        CoreTestsTools.register()
        CoreTestsBudgets.register()
        CoreTestsSniffer.register()
        CoreTestsConformance.register()
        CoreTestsEngineGaps.register()
        CoreTestsProcessGroup.register()
        CoreTestsSandbox.register()
        CoreTestsFuzz.register()
        ConformanceGate.register()
    }
}
