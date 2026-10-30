import Foundation

extension SettingsTests {
    static func registerFolderTests(_ t: SelfTestRegistry) {
        t.register("settings.folders", "an operation or a preset becomes a recipe and back") {
            let fx = TestFixtures(label: "folder-logic"); defer { fx.cleanup() }
            let registry = OperationRegistry()
            registry.register(SettingsFakeOperation(id: "fake.a", label: "A"))
            registry.register(SettingsFakeOperation(id: "fake.studio", label: "Studio", studioOnly: true))
            let store = PresetStore(directory: fx.url("presets"))
            let preset = try store.create(name: "Small", targetID: "fake.a", values: ["quality": 40])
            let r1 = try unwrap(FolderRuleLogic.recipe(forTag: "op:fake.a", presets: store, registry: registry))
            try expectEqual(r1.operationID, "fake.a"); try expect(r1.presetID == nil); try expectEqual(FolderRuleLogic.tag(for: r1), "op:fake.a")
            let r2 = try unwrap(FolderRuleLogic.recipe(forTag: "preset:" + preset.id, presets: store, registry: registry))
            try expectEqual(r2.operationID, "fake.a"); try expectEqual(r2.presetID, preset.id); try expectEqual(r2.values.int("quality"), 40)
            try expectEqual(FolderRuleLogic.tag(for: r2), "preset:" + preset.id)
            try expect(FolderRuleLogic.recipe(forTag: "op:nope", presets: store, registry: registry) == nil)
            try expect(FolderRuleLogic.recipe(forTag: "preset:nope", presets: store, registry: registry) == nil)
            try expect(FolderRuleLogic.recipe(forTag: "", presets: store, registry: registry) == nil)
            try expectEqual(FolderRuleLogic.describe(r2, presets: store, registry: registry), "Small")
            try expectEqual(FolderRuleLogic.describe(r1, presets: store, registry: registry), "A")
            let groups = FolderRuleLogic.operationGroups(registry: registry)
            try expectEqual(groups.flatMap { $0.items.map(\.tag) }, ["op:fake.a"], "studio-only operations are not offered to a folder")
            let preGroups = FolderRuleLogic.presetGroups(presets: store, registry: registry)
            try expectEqual(preGroups.flatMap { $0.items.map(\.tag) }, ["preset:" + preset.id])
        }
        t.register("settings.folders", "a rule is checked before it is saved") {
            let fx = TestFixtures(label: "folder-check"); defer { fx.cleanup() }
            let registry = OperationRegistry()
            registry.register(SettingsFakeOperation(id: "fake.a", label: "A"))
            registry.register(SettingsFakeOperation(id: "fake.b", label: "B"))
            let dir = try fx.makeDirectory("watched")
            var rule = WatchRule(path: "", recipe: Recipe(operationID: "fake.a"))
            try expect(FolderRuleLogic.problem(with: rule, existing: [], registry: registry) != nil, "no folder")
            rule.path = fx.url("missing").path
            try expect(FolderRuleLogic.problem(with: rule, existing: [], registry: registry) != nil, "folder missing")
            rule.path = dir.path; rule.recipe = Recipe(operationID: "")
            try expect(FolderRuleLogic.problem(with: rule, existing: [], registry: registry) != nil, "no action")
            rule.recipe = Recipe(operationID: "nope")
            try expect(FolderRuleLogic.problem(with: rule, existing: [], registry: registry) != nil, "unknown action")
            rule.recipe = Recipe(operationID: "fake.a")
            try expect(FolderRuleLogic.problem(with: rule, existing: [], registry: registry) == nil)
            let other = WatchRule(path: dir.path, recipe: Recipe(operationID: "fake.a"))
            try expect(FolderRuleLogic.problem(with: rule, existing: [other], registry: registry) != nil, "same folder, same action")
            let different = WatchRule(path: dir.path, recipe: Recipe(operationID: "fake.b"))
            try expect(FolderRuleLogic.problem(with: rule, existing: [different], registry: registry) == nil, "the same folder may have two different actions")
            try expect(FolderRuleLogic.problem(with: other, existing: [other], registry: registry) == nil, "a rule does not clash with itself")
        }
        t.register("settings.folders", "every status has a calm word in both languages and its own glyph") {
            let all: [WatchFolderService.RuleStatus] = [.watching, .folderMissing, .volumeUnavailable, .paused, .disabled]
            for s in all { let w = FolderRuleLogic.statusText(s); try expect(!w.en.isEmpty && !w.ru.isEmpty && w.en != w.ru) }
            try expectEqual(Set(all.map { FolderRuleLogic.statusKind($0).shapeID }).count, all.count, "meaning never rests on colour alone")
        }
        t.register("settings.folders", "templates are listed, off by default, and say what they do") {
            let settings = AppSettings(fileURL: AppPaths.tempRoot.appendingPathComponent("tpl-\(UUID().uuidString.prefix(6)).json"), autosave: false)
            for tpl in WatchTemplates.all {
                try expect(!WatchTemplates.isEnabled(templateID: tpl.id, settings: settings), "\(tpl.id) must start off")
                try expect(!tpl.detail.en.isEmpty && !tpl.detail.ru.isEmpty)
            }
            try expect(settings.data.watchRules.isEmpty)
        }
    }
}
