import SwiftUI

// Offscreen snapshots of every Settings page and dialog, English and Russian, light and dark (`./build.sh snapshot <dir> settings`). Pages are drawn tall so a whole page can be
// reviewed in one image; the real window scrolls. Pages that need data (folders, layout editor) get a private store, never the person's.

extension SettingsModule {
    @MainActor
    static func registerSnapshots() {
        let r = SnapshotRegistry.shared
        let v = SnapshotVariant.lightDarkRu
        func page<V: View>(_ name: String, _ title: String, _ size: CGSize, @ViewBuilder _ content: @escaping @MainActor () -> V) {
            r.register("settings." + name, size: size, backdrop: .windowBackground, chrome: .window(title: title), variants: v, content)
        }
        page("general", "General", CGSize(width: 680, height: 1480)) { GeneralPage() }
        page("wheel", "Wheel", CGSize(width: 860, height: 1280)) { WheelPage() }
        page("shortcuts", "Shortcuts", CGSize(width: 680, height: 980)) { ShortcutsPage() }
        page("recipes", "Recipes", CGSize(width: 720, height: 1500)) { RecipesPage(initialOperation: "image.to.jpg") }
        page("folders", "Folders", CGSize(width: 760, height: 1000)) { SettingsSnapshotData.foldersPage() }
        page("tools", "Tools", CGSize(width: 720, height: 1750)) { ToolsPage() }
        page("about", "About", CGSize(width: 520, height: 480)) { AboutSettingsPage() }
        r.register("settings.layout-editor", size: CGSize(width: 860, height: 470), backdrop: .windowBackground, chrome: .none, variants: v) {
            Form { Section { SettingsSnapshotData.layoutEditor() } }.formStyle(.grouped).appRoot()
        }
        r.register("settings.hotkey-recorder", size: CGSize(width: 640, height: 430), backdrop: .windowBackground, chrome: .none, variants: v) {
            SettingsSnapshotData.recorderStates()
        }
        r.register("settings.parameter-sheet", size: CGSize(width: 520, height: 470), backdrop: .wallpaper, chrome: .none, variants: v) {
            SettingsSnapshotData.parameterSheet()
        }
        r.register("settings.folder-rule-editor", size: CGSize(width: 520, height: 470), backdrop: .windowBackground, chrome: .none, variants: v) {
            FolderRuleEditor(draft: WatchRule(path: NSHomeDirectory() + "/Downloads", recipe: Recipe(operationID: "image.to.jpg")), isNew: true, existing: [], onSave: { _ in }, onCancel: {})
        }
    }
}

@MainActor
enum SettingsSnapshotData {
    private static func privateSettings() -> AppSettings {
        AppSettings(fileURL: AppPaths.tempRoot.appendingPathComponent("snap-\(UUID().uuidString.prefix(6)).json"), autosave: false)
    }

    static func foldersPage() -> some View {
        let s = privateSettings()
        let downloads = NSHomeDirectory() + "/Downloads"
        var heic = WatchRule(path: downloads, recipe: Recipe(operationID: "image.to.jpg"))
        heic.templateID = WatchTemplates.heicToJPG
        var webp = WatchRule(path: NSHomeDirectory() + "/Desktop", recipe: Recipe(operationID: "image.to.webp"))
        webp.includeSubfolders = true
        var off = WatchRule(path: "/Volumes/Archive/Incoming", recipe: Recipe(operationID: "image.to.png"))
        off.enabled = false
        s.update { $0.watchRules = [heic, webp, off] }
        return FoldersPage(settings: s)
    }

    static func layoutEditor() -> some View {
        let layout = WheelLayout(fileURL: AppPaths.tempRoot.appendingPathComponent("snap-layout-\(UUID().uuidString.prefix(6)).json"), autosave: false)
        let model = LayoutEditorModel(layout: layout, registry: .shared)
        let rows = model.rows(wheel: .convert, profile: .image)
        if rows.count > 4 {
            layout.setFavorite(true, id: rows[2].id)
            layout.setHidden(true, id: rows[4].id, wheel: .convert, profile: .image)
        }
        model.highlighted = rows.count > 1 ? rows[1].id : nil
        return WheelLayoutEditor(model: model)
    }

    static func recorderStates() -> some View {
        let ctrlOpt = HotkeyModifier.control | HotkeyModifier.option
        let fell = HotkeyManager.Registration(requested: HotkeyPresets.wheelDefault, effective: HotkeyPresets.wheelFallbacks[0], fellBack: true, status: 0)
        return Form {
            FormSection("Normal") {
                SettingsRow(L("Download shortcut", "Сочетание для загрузки")) {
                    HotkeyRecorder(setting: .constant(.downloadDefault), other: HotkeySetting(), defaultSetting: .downloadDefault, presets: HotkeyPresets.downloadFallbacks)
                }
            }
            FormSection("macOS owns the chord") {
                SettingsRow(L("Wheel shortcut", "Сочетание для колеса")) {
                    HotkeyRecorder(setting: .constant(HotkeySetting(enabled: true, keyCode: HotkeyCombo.space, modifiers: ctrlOpt)), defaultSetting: HotkeySetting(),
                                   presets: HotkeyPresets.wheelFallbacks, registration: fell)
                }
            }
            FormSection("Turned off") {
                SettingsRow(L("Download shortcut", "Сочетание для загрузки")) {
                    HotkeyRecorder(setting: .constant(HotkeySetting(enabled: false, keyCode: 2, modifiers: ctrlOpt)), defaultSetting: .downloadDefault, presets: [])
                }
            }
        }
        .formStyle(.grouped).appRoot()
    }

    static func parameterSheet() -> some View {
        let op = SettingsFixtures.trimOperation
        let fields = op.meta.quickPromptKeys.compactMap { op.optionSchema(for: []).field($0) }
        let current = QuickRecipes.resolve(op, items: [], settings: SettingsData()).values
        var model = ParamSheetModel(operation: op, items: [FileItem(url: URL(fileURLWithPath: "/Users/me/Movies/Holiday clip.mp4"), isDirectory: false)], fields: fields, current: current)
        model.set("trim.start", .double(48)); model.set("trim.end", .double(30))
        return ParameterSheetView(model: model, onRun: { _ in }, onCancel: {})
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous))
    }
}
