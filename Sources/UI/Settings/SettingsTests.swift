import Foundation
import SwiftUI
import AppKit

/// Self-tests of the Settings module (`./build.sh selftest settings`). Suites: settings (registry, key coverage, pages), settings.hotkeys, settings.layout, settings.params, settings.folders,
/// settings.recipes, settings.tools. Nothing here touches the person's real settings: the harness runs against an isolated home, and tests that need their own store make one.
enum SettingsTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("settings", "pages sort by order and re-registering a page id replaces it") {
            let reg = SettingsPageRegistry()
            reg.register(SettingsPageDescriptor(id: .tools, title: L10n("Tools"), symbol: "wrench", order: 50) { AnyView(EmptyView()) })
            reg.register(SettingsPageDescriptor(id: .general, title: L10n("General"), symbol: "gearshape", order: 0) { AnyView(EmptyView()) })
            reg.register(SettingsPageDescriptor(id: .tools, title: L10n("Tools 2"), symbol: "wrench", order: 50) { AnyView(EmptyView()) })
            try expectEqual(reg.pages.map(\.id.raw), ["general", "tools"]); try expectEqual(reg.pages.last?.title.en, "Tools 2")
        }
        t.register("settings", "built-in pages are registered once, in order, and a richer page registered earlier is left alone") {
            let reg = SettingsPageRegistry()
            reg.register(SettingsPageDescriptor(id: .about, title: L10n("About (app)"), symbol: "info", order: 100) { AnyView(EmptyView()) })
            SettingsModule.ensureBuiltInPages(registry: reg)
            SettingsModule.ensureBuiltInPages(registry: reg)
            try expectEqual(reg.pages.map(\.id.raw), ["general", "wheel", "shortcuts", "recipes", "folders", "tools", "about"])
            try expectEqual(reg.pages.last?.title.en, "About (app)", "the app module's About page must survive")
            for id in ["general", "wheel", "shortcuts", "recipes", "folders", "tools", "about"] {
                try expect(SettingsPageFactory.make(SettingsPageID(id)) != nil, "no view for \(id)")
            }
            try expect(SettingsPageFactory.make(.downloader) == nil, "the downloader page belongs to another module")
        }
        t.register("settings", "installParameterSheet sets the QuickRun hook, and the hook returns the sheet's answers") {
            let quick = QuickRun()
            try expect(quick.parameterPrompt == nil)
            let presenter = ParameterSheetPresenter(memory: ParameterMemory(fileURL: nil))
            var sawFields: [String] = []
            presenter.testResponder = { model in sawFields = model.fields.map(\.key); return model.answers() }
            SettingsModule.installParameterSheet(on: quick, presenter: presenter)
            let hook = try unwrap(quick.parameterPrompt, "the hook must be installed")
            let op = SettingsFixtures.trimOperation
            let fields = op.optionSchema(for: []).allFields.filter { op.meta.quickPromptKeys.contains($0.key) }
            let answers = await hook(op, [], fields, op.optionSchema(for: []).defaults())
            try expectEqual(sawFields, ["trim.start", "trim.end", "pdf.password"])
            try expect(answers != nil && answers?.has("trim.start") == true)
        }
        registerKeyTests(t)
        registerHotkeyTests(t)
        registerLayoutTests(t)
        registerSetupTests(t)
        registerParamTests(t)
        registerFolderTests(t)
        registerRecipeTests(t)
        registerToolTests(t)
        registerStringTests(t)
    }
}
