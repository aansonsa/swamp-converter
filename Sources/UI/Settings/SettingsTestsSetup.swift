import Foundation

extension SettingsTests {
    static func registerSetupTests(_ t: SelfTestRegistry) {
        t.register("settings.setup", "the checklist: the shortcut and Automation are what is needed, the rest is recommended; it folds only when nothing needed is missing") {
            var i = SetupInputs(shortcutEnabled: true, shortcutChord: "⌃⌥⌘Space", finder: .granted, browsers: [.granted, .granted], accessibilityTrusted: false, login: .disabled, toolsFound: 2, toolsTotal: 3)
            var items = SetupChecklist.items(i)
            try expectEqual(items.map(\.kind), SetupItem.Kind.allCases, "five rows, always in the same order")
            try expectEqual(items.map(\.status), [.done, .done, .recommended, .recommended, .recommended])
            try expect(!SetupChecklist.needsAttention(items), "only recommended things are open: the section folds")
            try expectEqual(items[0].detail, "⌃⌥⌘Space", "the shortcut row shows the chord that is really registered")
            try expectEqual(items[4].detail, "2 / 3")
            i.browsers = [.granted, .denied]
            items = SetupChecklist.items(i)
            try expectEqual(items[1].status, .needed); try expect(SetupChecklist.needsAttention(items), "one refused browser keeps Automation open")
            i.browsers = []; i.finder = .notDetermined
            try expectEqual(SetupChecklist.items(i)[1].status, .needed, "Finder not asked yet")
            i.finder = .granted; i.shortcutEnabled = false
            let off = SetupChecklist.items(i)
            try expectEqual(off[0].status, .needed); try expectEqual(off[0].detail, nil, "an off shortcut shows no chord")
            i.shortcutEnabled = true; i.shortcutChord = nil
            try expectEqual(SetupChecklist.items(i)[0].status, .needed, "enabled but nothing registered is still not done")
            i.shortcutChord = "⌃⌥Space"; i.accessibilityTrusted = true; i.login = .enabled; i.toolsFound = 3
            try expect(SetupChecklist.items(i).allSatisfy { $0.status == .done }, "everything green")
            i.login = .requiresApproval
            try expectEqual(SetupChecklist.items(i)[3].status, .recommended, "waiting for approval in Login Items is not done")
            i.login = .unavailable
            try expectEqual(SetupChecklist.items(i).map(\.kind), [.shortcut, .automation, .selectedText, .tools], "no login row where macOS cannot offer one")
        }
        t.register("settings.setup", "every row explains itself in both languages and offers a button until it is done") {
            for kind in SetupItem.Kind.allCases {
                let item = SetupItem(kind: kind, status: .needed, detail: nil)
                for text in [item.title, item.why, item.actionTitle] { try expect(!text.en.isEmpty && !text.ru.isEmpty && text.en != text.ru, "\(kind) is written in both languages") }
            }
        }
        t.register("settings.setup", "the model refreshes from its inputs, runs one button at a time, and a button never changes anything it was not asked to") {
            var state = SetupInputs(shortcutEnabled: true, shortcutChord: "⌃⌥Space", finder: .notDetermined)
            let m = SetupChecklistModel()
            m.inputs = { state }
            var calls: [String] = []
            m.allowAutomation = { calls.append("automation"); state.finder = .granted; return "Allowed: Finder." }
            m.allowSelectedText = { calls.append("selectedText"); state.accessibilityTrusted = true }
            m.turnOnLogin = { calls.append("login"); state.login = .enabled }
            m.openShortcuts = { calls.append("shortcuts") }; m.openTools = { calls.append("tools") }
            m.refresh()
            try expect(m.needsAttention)
            await m.perform(.automation)
            try expectEqual(calls, ["automation"]); try expectEqual(m.note, "Allowed: Finder."); try expect(!m.needsAttention, "the row turned green after the answer")
            await m.perform(.selectedText); await m.perform(.loginItem)
            try expectEqual(calls, ["automation", "selectedText", "login"])
            try expectEqual(m.items.first { $0.kind == .selectedText }?.status, .done)
            try expectEqual(m.items.first { $0.kind == .loginItem }?.status, .done)
            await m.perform(.shortcut); await m.perform(.tools)
            try expectEqual(calls.suffix(2), ["shortcuts", "tools"], "the two navigation rows only open their pages")
            try expect(m.busy == nil)
        }
    }
}
