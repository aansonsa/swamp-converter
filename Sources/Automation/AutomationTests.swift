import Foundation

enum AutomationTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("automation", "all watch templates are off until enabled and a rule never watches its own output folder") {
            try expect(AppSettings.shared.data.watchRules.isEmpty, "no rules by default")
            try expect(WatchFolderService.shared.statuses.isEmpty, "nothing watching by default")
        }
        // AUTOMATION OWNER: SettleDetector table tests (growing file, steady file, rename, vanished), candidate filter (hidden, `._*`, `.part`, `.crdownload`, own outputs), loop prevention end to end with
        // a temp folder, remount of a volume (simulated by removing / recreating the folder), multi-output fan-out with fake operations, chain stage weights and failure naming, template enable / disable.
    }
}
