import Foundation

extension SettingsTests {
    static func registerRecipeTests(_ t: SelfTestRegistry) {
        t.register("settings.recipes", "editing a quick recipe stores only the difference from the built-in recipe, and reverting removes it") {
            let registry = OperationRegistry()
            let op = SettingsFakeOperation(id: "fake.q", label: "Q", fields: [.slider("quality", L10n("Quality", "Качество"), min: 10, max: 100, def: 80).basic(),
                                                                              .toggle("meta.strip", L10n("Strip", "Убрать"), def: false).basic()],
                                           overrides: OptionValues(["quality": 70]))
            registry.register(op)
            let settings = AppSettings.shared
            defer { QuickRecipes.reset(op) }
            let model = QuickRecipeModel(registry: registry, settings: settings)
            model.select(operationID: "fake.q")
            try expectEqual(model.values.int("quality"), 70, "the built-in recipe wins over the schema default")
            try expectEqual(model.baseline.int("quality"), 70)
            try expect(!model.isEdited && model.isDefault("quality"))
            model.set("quality", .int(55))
            try expectEqual(settings.data.quickRecipes["fake.q"]?.int("quality"), 55)
            try expectEqual(settings.data.quickRecipes["fake.q"]?.keys, ["quality"], "sparse: the untouched toggle is not stored")
            try expect(model.isEdited && !model.isDefault("quality"))
            try expectEqual(QuickRecipes.resolve(op, items: [], settings: settings.data).values.int("quality"), 55, "the quick path uses the edit")
            model.set("quality", .int(500))
            try expectEqual(model.values.int("quality"), 100, "out of range values are pulled in")
            model.revert("quality")
            try expect(settings.data.quickRecipes["fake.q"] == nil, "back to the built-in value stores nothing")
            model.set("meta.strip", .bool(true)); try expect(model.isEdited)
            model.resetAll()
            try expect(!model.isEdited && model.values.bool("meta.strip") == false)
        }
        t.register("settings.recipes", "the editor offers basic and standard fields only, honours conditions, and skips track tables") {
            let registry = OperationRegistry()
            let op = SettingsFakeOperation(id: "fake.cond", label: "Cond", fields: [
                .toggle("a", L10n("A"), def: false).basic(),
                .slider("b", L10n("B"), min: 0, max: 10, def: 5).standard().visible(.eq("a", true)),
                .toggle("c", L10n("C"), def: false).expert(),
                .tracks("d", L10n("D"), TrackSpec(columns: [.toggle("x", L10n("X"))]))])
            registry.register(op)
            let model = QuickRecipeModel(registry: registry, settings: .shared)
            model.select(operationID: "fake.cond")
            defer { QuickRecipes.reset(op) }
            try expectEqual(model.sections().flatMap { $0.fields.map(\.key) }, ["a"], "b is hidden until a is on; c is expert; d is a table")
            model.set("a", .bool(true))
            try expectEqual(model.sections().flatMap { $0.fields.map(\.key) }, ["a", "b"])
        }
        t.register("settings.recipes", "presets are grouped by family, the person's own first, and names are trimmed") {
            let fx = TestFixtures(label: "preset-list"); defer { fx.cleanup() }
            let registry = OperationRegistry()
            registry.register(SettingsFakeOperation(id: "fake.img", label: "Img", family: .image))
            registry.register(SettingsFakeOperation(id: "fake.vid", label: "Vid", family: .video, inputs: ["mp4"]))
            let store = PresetStore(directory: fx.url("presets"))
            store.registerBuiltins([Preset(id: "b1", targetID: "fake.img", name: L10n("Built")), Preset(id: "b2", targetID: "fake.vid", name: L10n("BuiltV"))])
            _ = try store.create(name: "Mine", targetID: "fake.img", values: [:])
            let groups = PresetListLogic.groups(store.all, registry: registry)
            try expectEqual(groups.map(\.family), [.image, .video])
            try expectEqual(groups[0].presets.map(\.name.en), ["Mine", "Built"])
            try expectEqual(PresetListLogic.cleanName("  Name \n"), "Name"); try expect(PresetListLogic.cleanName("   ") == nil)
            // The store operations the list calls.
            let mine = try unwrap(store.userPresets.first)
            try store.rename(id: mine.id, to: "Renamed"); try expectEqual(store.preset(id: mine.id)?.name.en, "Renamed")
            let copy = try store.duplicate(id: "builtin.b1"); try expect(!copy.isBuiltin)
            try await expectThrows("built-in presets can't be renamed") { try store.rename(id: "builtin.b1", to: "X") }
            try await expectThrows("built-in presets can't be deleted") { try store.delete(id: "builtin.b1") }
            try store.delete(id: copy.id); try expect(store.preset(id: copy.id) == nil)
            let file = fx.url("out.swampreset")
            try store.export(ids: [mine.id], to: file)
            let imported = try store.importFile(file)
            try expectEqual(imported.count, 1); try expect(imported[0].id != mine.id, "an imported preset never takes over an id")
        }
    }
}
