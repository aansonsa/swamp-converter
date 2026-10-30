import Foundation

extension SettingsTests {
    @MainActor
    private static func trimModel(remembered: OptionValues = OptionValues(), op: SettingsFakeOperation = SettingsFixtures.trimOperation) -> ParamSheetModel {
        let fields = op.meta.quickPromptKeys.compactMap { op.optionSchema(for: []).field($0) }
        let current = QuickRecipes.resolve(op, items: [], settings: SettingsData()).values
        return ParamSheetModel(operation: op, items: [FileItem(url: URL(fileURLWithPath: "/sample/clip.mp4"), isDirectory: false)], fields: fields, current: current, remembered: remembered)
    }

    static func registerParamTests(_ t: SelfTestRegistry) {
        t.register("settings.params", "the sheet starts from the quick recipe, in the order the operation named its fields") {
            let m = trimModel()
            try expectEqual(m.fields.map(\.key), ["trim.start", "trim.end", "pdf.password"])
            try expectEqual(m.values.string("trim.start"), "", "an empty time means not set")
            try expectEqual(m.values.string("pdf.password"), "")
            try expect(m.values.has("trim.start") && !m.values.has("quality"), "only the asked fields")
        }
        t.register("settings.params", "Run needs the answers the operation can't do without, and the start must come before the end") {
            var m = trimModel()
            try expect(!m.canRun, "the password is empty")
            try expect(m.messages().contains { $0.fieldKey == "pdf.password" && $0.severity == .error })
            m.set("pdf.password", .string("secret"))
            try expect(m.canRun, "start and end are optional")
            m.set("trim.start", .double(10)); m.set("trim.end", .double(5))
            try expect(!m.canRun, "start after end")
            try expect(m.messages().contains { $0.fieldKey == "trim.end" })
            m.set("trim.end", .double(20))
            try expect(m.canRun)
            m.set("trim.start", .double(20))
            try expect(!m.canRun, "start equal to end cuts nothing")
        }
        t.register("settings.params", "the answers hold the asked fields only, coerced like any other value") {
            var m = trimModel()
            m.set("pdf.password", .string("pw")); m.set("trim.start", .string("0:30")); m.set("trim.end", .string("1:30"))
            let a = m.answers()
            try expectEqual(Set(a.keys), ["pdf.password", "trim.end", "trim.start"])
            try expectEqual(a.double("trim.start"), 30); try expectEqual(a.double("trim.end"), 90)
            try expectEqual(a.string("pdf.password"), "pw")
            try expect(!a.has("quality"))
        }
        t.register("settings.params", "last values are remembered per operation, but never a password") {
            let fx = TestFixtures(label: "param-memory"); defer { fx.cleanup() }
            let memory = ParameterMemory(fileURL: fx.url("param-sheet.json"))
            var m = trimModel()
            m.set("pdf.password", .string("hunter2")); m.set("trim.start", .double(12)); m.set("trim.end", .double(48))
            let kept = m.memorable()
            try expectEqual(Set(kept.keys), ["trim.end", "trim.start"], "the password stays out")
            memory.remember(kept, for: "fake.trim")
            try expect(!((try? String(contentsOf: fx.url("param-sheet.json"), encoding: .utf8)) ?? "").contains("hunter2"), "nothing secret on disk")
            let again = trimModel(remembered: memory.values(for: "fake.trim"))
            try expectEqual(again.values.double("trim.start"), 12); try expectEqual(again.values.double("trim.end"), 48)
            try expectEqual(again.values.string("pdf.password"), "", "the password field starts empty")
            // A remembered password in a hand-edited file is ignored.
            let tainted = trimModel(remembered: OptionValues(["pdf.password": "leaked", "trim.start": 3]))
            try expectEqual(tainted.values.string("pdf.password"), ""); try expectEqual(tainted.values.double("trim.start"), 3)
            memory.remember(OptionValues(), for: "fake.trim")
            try expect(memory.values(for: "fake.trim").isEmpty, "empty clears the entry")
        }
        t.register("settings.params", "the presenter remembers an answered sheet and forgets a cancelled one") {
            let fx = TestFixtures(label: "param-presenter"); defer { fx.cleanup() }
            let memory = ParameterMemory(fileURL: fx.url("p.json"))
            let presenter = ParameterSheetPresenter(memory: memory)
            let op = SettingsFixtures.trimOperation
            let fields = op.meta.quickPromptKeys.compactMap { op.optionSchema(for: []).field($0) }
            let current = QuickRecipes.resolve(op, items: [], settings: SettingsData()).values
            presenter.testResponder = { _ in nil }
            let cancelled = await presenter.ask(operation: op, items: [], fields: fields, current: current)
            try expect(cancelled == nil); try expect(memory.values(for: "fake.trim").isEmpty)
            presenter.testResponder = { model in var m = model; m.set("trim.start", .double(7)); m.set("pdf.password", .string("x")); return m.answers() }
            let answered = await presenter.ask(operation: op, items: [], fields: fields, current: current)
            try expectEqual(answered?.double("trim.start"), 7)
            try expectEqual(memory.values(for: "fake.trim").double("trim.start"), 7)
            try expect(!memory.values(for: "fake.trim").has("pdf.password"))
            var seenStart = -1.0
            presenter.testResponder = { model in seenStart = model.values.double("trim.start"); return nil }
            _ = await presenter.ask(operation: op, items: [], fields: fields, current: current)
            try expectEqual(seenStart, 7, "the next sheet opens with the remembered value")
        }
        t.register("settings.params", "a problem that was already there before the person answered does not lock Run") {
            let op = SettingsFakeOperation(id: "fake.rule", label: "Rule", inputs: ["mp4"],
                                           fields: [.time("trim.start", L10n("Start")).basic(),
                                                    .slider("quality", L10n("Quality"), min: 10, max: 100, def: 80).basic()
                                                        .rule(.error("quality.low", when: .lt("quality", 50), L10n("Quality is too low.", "Слишком низкое качество."), field: "quality"))],
                                           prompt: ["trim.start"])
            let fields = [op.optionSchema(for: []).field("trim.start")!]
            var current = QuickRecipes.resolve(op, items: [], settings: SettingsData()).values
            current["quality"] = .int(20)     // the quick recipe itself is broken: the sheet can't fix it, so it must not block
            let m = ParamSheetModel(operation: op, items: [], fields: fields, current: current)
            try expect(m.canRun, "messages: \(m.messages().map(\.id))")
        }
    }
}
