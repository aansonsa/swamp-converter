import Foundation

// The logic of the watched-folder editor (no drawing): what a rule can do (an operation or a preset), how that choice becomes a `Recipe`, and the checks before a rule is saved.

enum FolderRuleLogic {
    struct Item: Identifiable, Equatable {
        /// "op:image.to.jpg" or "preset:u-1a2b3c".
        var tag: String
        var label: String
        var id: String { tag }
    }

    struct Group: Identifiable, Equatable {
        var id: String
        var title: String
        var items: [Item]
    }

    // MARK: Choices

    static func tag(for recipe: Recipe) -> String {
        if let p = recipe.presetID, !p.isEmpty { return "preset:" + p }
        return "op:" + recipe.operationID
    }

    /// The recipe of a choice. A preset becomes its target operation with the preset's values, so the rule keeps working if the preset is renamed.
    static func recipe(forTag tag: String, presets: PresetStore = .shared, registry: OperationRegistry = .shared, keeping old: Recipe? = nil) -> Recipe? {
        if tag.hasPrefix("preset:") {
            let id = String(tag.dropFirst(7))
            guard let p = presets.preset(id: id) else { return nil }
            var r = Recipe(operationID: p.operationID ?? p.targetID, values: p.values, presetID: p.id, output: old?.output, name: p.name.text)
            if let old { r.id = old.id }
            return r
        }
        let id = String(tag.dropFirst(3))
        guard tag.hasPrefix("op:"), !id.isEmpty, registry.operation(id: id) != nil else { return nil }
        var r = Recipe(operationID: id, output: old?.output)
        if let old { r.id = old.id }
        return r
    }

    /// Operations a rule may run, grouped by family. Not offered: actions of the Actions wheel (they run in the app), link operations (downloads), operations that exist only
    /// in the Studio (they need answers a folder can't give), and user presets (listed apart).
    static func operationGroups(registry: OperationRegistry = .shared) -> [Group] {
        var byFamily: [OperationFamily: [Item]] = [:]
        for op in registry.allOperations() {
            let m = op.meta
            guard !m.isAppAction, !m.acceptsLinks, !m.studioOnly, !m.id.hasPrefix("preset."), m.family != .download, m.family != .app else { continue }
            byFamily[m.family, default: []].append(Item(tag: "op:" + m.id, label: m.label.text))
        }
        return OperationFamily.allCases.compactMap { f in
            guard let items = byFamily[f], !items.isEmpty else { return nil }
            return Group(id: "op-" + f.rawValue, title: f.title.text, items: items)
        }
    }

    /// Presets (built-in and the person's own), grouped by the family of their target.
    static func presetGroups(presets: PresetStore = .shared, registry: OperationRegistry = .shared) -> [Group] {
        var byFamily: [OperationFamily: [Item]] = [:]
        for p in presets.all {
            guard let family = (p.operationID.flatMap { registry.operation(id: $0) } ?? registry.primaryOperation(forTarget: p.targetID))?.meta.family,
                  family != .download, family != .app else { continue }
            byFamily[family, default: []].append(Item(tag: "preset:" + p.id, label: p.name.text))
        }
        return OperationFamily.allCases.compactMap { f in
            guard let items = byFamily[f], !items.isEmpty else { return nil }
            return Group(id: "preset-" + f.rawValue, title: L("Presets: ", "Шаблоны: ") + f.title.text, items: items)
        }
    }

    /// "Convert to JPG" / "Web 1080p": the readable name of what a recipe does.
    static func describe(_ recipe: Recipe, presets: PresetStore = .shared, registry: OperationRegistry = .shared) -> String {
        if let id = recipe.presetID, let p = presets.preset(id: id) { return p.name.text }
        if let name = recipe.name, !name.isEmpty { return name }
        if let op = registry.operation(id: recipe.operationID) ?? registry.primaryOperation(forTarget: recipe.operationID) { return op.meta.label.text }
        return L("An operation that is no longer available", "Операция, которой больше нет")
    }

    // MARK: Checks

    /// Why `draft` can't be saved yet, or nil. `existing` = the other rules (the folder must not be watched twice).
    static func problem(with draft: WatchRule, existing: [WatchRule], registry: OperationRegistry = .shared) -> L10n? {
        let path = draft.path.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return L10n("Choose the folder to watch.", "Выберите папку для наблюдения.") }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
            return L10n("That folder doesn’t exist.", "Такой папки нет.")
        }
        if draft.recipe.operationID.isEmpty || (registry.operation(id: draft.recipe.operationID) == nil && registry.primaryOperation(forTarget: draft.recipe.operationID) == nil) {
            return L10n("Choose what should happen to new files.", "Выберите, что делать с новыми файлами.")
        }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        for other in existing where other.id != draft.id {
            if URL(fileURLWithPath: other.path).resolvingSymlinksInPath().standardizedFileURL.path == real && other.recipe.operationID == draft.recipe.operationID && other.recipe.presetID == draft.recipe.presetID {
                return L10n("This folder is already watched with the same action.", "Эта папка уже отслеживается с тем же действием.")
            }
        }
        return nil
    }

    // MARK: Status text

    static func statusText(_ s: WatchFolderService.RuleStatus) -> L10n {
        switch s {
        case .watching: return L10n("Watching", "Наблюдение")
        case .folderMissing: return L10n("Folder not found", "Папка не найдена")
        case .volumeUnavailable: return L10n("Waiting for the disk", "Ожидание диска")
        case .paused: return L10n("Paused", "Приостановлено")
        case .disabled: return L10n("Off", "Выключено")
        }
    }

    static func statusKind(_ s: WatchFolderService.RuleStatus) -> StatusKind {
        switch s {
        case .watching: return .done
        case .folderMissing: return .warning
        case .volumeUnavailable: return .waiting
        case .paused: return .paused
        case .disabled: return .idle
        }
    }
}
