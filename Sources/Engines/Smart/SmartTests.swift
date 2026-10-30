import Foundation

enum SmartTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("smart", "Best for Apple is the first Convert sector of a video") {
            let reg = OperationRegistry()
            reg.register(SmartCatalog.operations())
            let one = [FileItem(url: URL(fileURLWithPath: "/tmp/a.mkv"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: one).map(\.id), ["smart.best", "smart.max", "smart.universal"])
            try expectEqual(try unwrap(reg.operation(id: "smart.universal")).quickOverrides(settings: SettingsData())[SmartKeys.mode]?.asString, "universal")
        }
        SmartPlannerTests.register()
        SmartPlannerModeTests.register()
        SmartCommandTests.register()
        SmartRunTests.register()
        SmartOptionTests.register()
        SmartQualityTests.register()
        SmartEdgeTests.register()
        SmartConformanceTests.register()
    }
}
