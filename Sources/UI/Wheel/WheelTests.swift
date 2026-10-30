import Foundation

enum WheelTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "context switching: browsers choose the link wheel, Finder and others the file wheel") {
            for kind in BrowserKind.allCases {
                try expectEqual(WheelContext.decide(frontmostBundleID: kind.bundleID), .linkFirst(kind))
            }
            try expectEqual(WheelContext.decide(frontmostBundleID: "com.apple.finder"), .filesFirst)
            try expectEqual(WheelContext.decide(frontmostBundleID: nil), .filesFirst)
            try expect(!BrowserKind.firefox.exposesTabURL && BrowserKind.safari.exposesTabURL)
            try expectEqual(BrowserKind(bundleID: "COM.APPLE.SAFARI"), .safari)
        }
        t.register("wheel", "the global hotkeys resolve to free chords and never collide with each other") {
            let s = SettingsData()
            try expect(s.hotkey.combo != s.downloadHotkey.combo)
            let r = HotkeyPolicy.resolve(preferred: s.hotkey.combo, taken: HotkeyManager.systemCombos(), candidates: HotkeyPresets.wheelFallbacks)
            try expect(r != nil, "a free chord exists")
        }
        t.register("wheel", "benchmark budgets: a result inside the budget passes, each exceeded number is named, a debug build gets the looser budget") {
            var r = WheelBenchmarkResult()
            r.openMS = 40; r.frameMeanMS = 4; r.heapBlockGrowth = 100
            try expect(r.failures(budget: WheelBenchmarkResult.release).isEmpty, "inside the release budget")
            r.openMS = 120; r.frameMeanMS = 9; r.heapBlockGrowth = 500
            let bad = r.failures(budget: WheelBenchmarkResult.release)
            try expectEqual(bad.count, 3)
            try expect(bad[0].hasPrefix("open ") && bad[1].hasPrefix("mean frame ") && bad[2].hasPrefix("heap grew"), "\(bad)")
            try expect(r.failures(budget: WheelBenchmarkResult.debug).isEmpty, "the same numbers are fine for a debug build")
            try expectEqual(WheelBenchmarkResult.release.openMS, 80, "the brief's budget: the wheel is visible within 80 ms")
        }
        registerGeometry()
        registerLayout()
        registerModel()
        registerGestures()
        registerBrowser()
        registerController()
        registerContent()
    }
}
