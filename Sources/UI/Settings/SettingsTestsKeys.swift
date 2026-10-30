import Foundation
import SwiftUI
import AppKit

// Key coverage: the table in SettingsKit names the page that owns every field of SettingsData, and each page must really show a control for each key it owns.

extension SettingsTests {
    static func registerKeyTests(_ t: SelfTestRegistry) {
        t.register("settings", "key table names every SettingsData field and nothing that no longer exists") {
            func check<T>(_ value: T, _ table: [String: SettingsKeyTable.Entry], _ what: String) throws {
                let fields = Set(SettingsKeyTable.labels(of: value))
                try expectEqual(fields.subtracting(table.keys).sorted(), [], "\(what): fields without an entry")
                try expectEqual(Set(table.keys).subtracting(fields).sorted(), [], "\(what): entries without a field")
            }
            try check(SettingsData(), SettingsKeyTable.top, "SettingsData")
            try check(GestureSettings(), SettingsKeyTable.gestures, "GestureSettings")
            try check(OutputRules(), SettingsKeyTable.output, "OutputRules")
            try check(QualitySettings(), SettingsKeyTable.quality, "QualitySettings")
        }
        t.register("settings", "every key owned by a built-in page is expected there, and internal keys explain themselves") {
            let owners: [SettingsPageID] = [.general, .wheel, .shortcuts, .recipes, .folders, .tools]
            var seen = Set<String>()
            for page in owners {
                let keys = SettingsKeyTable.expectedKeys(for: page)
                try expect(!keys.isEmpty, "\(page.raw) owns no key")
                try expect(seen.isDisjoint(with: keys), "a key is owned by two pages: \(seen.intersection(keys))")
                seen.formUnion(keys)
            }
            for (k, e) in SettingsKeyTable.top where e.owner == nil { try expect(!e.note.isEmpty, "\(k) has no reason") }
        }
        for page in [SettingsPageID.general, .wheel, .shortcuts, .recipes, .folders, .tools] {
            t.register("settings", "page \(page.raw): every key it owns has a control, and it shows no other page's key") {
                guard let view = SettingsPageFactory.make(page) else { throw TestFailure(message: "no view", file: #fileID, line: #line) }
                let found = try await PageProbe.keys(of: view)
                let expected = SettingsKeyTable.expectedKeys(for: page)
                try expectEqual(expected.subtracting(found).sorted(), [], "keys without a control on \(page.raw)")
                try expectEqual(found.subtracting(expected).sorted(), [], "keys on \(page.raw) that another page owns")
            }
        }
    }
}

/// Hosts a page in an offscreen window tall enough to lay out every row, and collects the keys of the controls that appeared.
@MainActor
enum PageProbe {
    static func keys(of view: AnyView, width: CGFloat = 900, height: CGFloat = 5000) async throws -> Set<String> {
        guard !NSScreen.screens.isEmpty else { try skipTest("no window server in this session") }
        let probe = SettingsKeyProbe()
        SettingsKeyProbe.active = probe
        defer { SettingsKeyProbe.active = nil }
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrame(NSRect(x: -9000, y: -9000, width: width, height: height), display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        // Two quiet reads in a row: the set stops growing once every row has appeared.
        var previous = -1
        try await Task.sleep(nanoseconds: 400_000_000)
        for _ in 0..<12 {
            let n = probe.keys.count
            if n == previous { break }
            previous = n
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return probe.keys
    }
}
