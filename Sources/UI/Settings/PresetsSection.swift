import SwiftUI

/// Grouping of the presets for the list in Settings > Recipes.
enum PresetListLogic {
    struct FamilyGroup: Identifiable, Equatable {
        var family: OperationFamily
        var presets: [Preset]
        var id: String { family.rawValue }
    }

    /// Presets by the family of their target: the person's own first, then the built-in ones in the order the engines registered them. Families follow the catalogue order.
    static func groups(_ presets: [Preset], registry: OperationRegistry = .shared) -> [FamilyGroup] {
        var byFamily: [OperationFamily: [Preset]] = [:]
        for p in presets {
            let family = (p.operationID.flatMap { registry.operation(id: $0) } ?? registry.primaryOperation(forTarget: p.targetID))?.meta.family ?? .app
            byFamily[family, default: []].append(p)
        }
        return OperationFamily.allCases.compactMap { f in
            guard let list = byFamily[f], !list.isEmpty else { return nil }
            return FamilyGroup(family: f, presets: list.filter { !$0.isBuiltin } + list.filter(\.isBuiltin))
        }
    }

    /// A new name is acceptable when it is not blank. (Two presets may share a name; they differ by id.)
    static func cleanName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// The preset list of Settings > Recipes: the person's presets and the built-in ones per family. Rename, duplicate, delete (the person's own), import and export `.swampreset`.
/// Presets are created in the Studio ("Save as preset"); this list manages them.
struct PresetsSection: View {
    @ObservedObject private var store: PresetStore
    private let registry: OperationRegistry
    @State private var renaming: Preset?
    @State private var newName = ""
    @State private var deleting: Preset?
    @State private var note: (text: String, tone: StatusTone)?

    init(store: PresetStore = .shared, registry: OperationRegistry = .shared) {
        _store = ObservedObject(wrappedValue: store)
        self.registry = registry
    }

    var body: some View {
        let groups = PresetListLogic.groups(store.all, registry: registry)
        FormSection(L("Presets", "Шаблоны"), symbol: "square.stack.3d.up",
                    footer: L("Presets are saved sets of options. Make one in the Studio with “Save as preset”. Built-in presets can’t be changed, but you can duplicate one and edit the copy.",
                              "Шаблоны - это сохранённые наборы параметров. Создайте шаблон в Студии командой «Сохранить как шаблон». Встроенные шаблоны менять нельзя, но можно сделать копию и изменить её.")) {
            SettingsRow(L("Share presets", "Обмен шаблонами"), help: L("A .swampreset file holds one or more presets.", "Файл .swampreset хранит один или несколько шаблонов.")) {
                Button(L("Import…", "Импорт…")) { importPresets() }
                Button(L("Export My Presets…", "Экспорт моих шаблонов…")) { exportAll() }.disabled(store.userPresets.isEmpty)
            }
            .background {
                Color.clear
                    .alert(L("Rename preset", "Переименовать шаблон"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                        TextField(L("Name", "Название"), text: $newName)
                        Button(L("Rename", "Переименовать")) { rename() }
                        Button(L("Cancel", "Отмена"), role: .cancel) { renaming = nil }
                    }
                    .confirmationDialog(L("Delete this preset?", "Удалить этот шаблон?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                        titleVisibility: .visible, presenting: deleting) { p in
                        Button(L("Delete “\(p.name.en)”", "Удалить «\(p.name.ru)»"), role: .destructive) { delete(p) }
                        Button(L("Cancel", "Отмена"), role: .cancel) {}
                    } message: { _ in
                        Text(L("Watched folders that use it keep the settings it had.", "Отслеживаемые папки, которые его используют, сохранят его параметры."))
                    }
            }
            if let note { InlineMessage(note.text, tone: note.tone, onDismiss: { self.note = nil }) }
            if groups.isEmpty {
                FormFootnote(L("No presets yet.", "Шаблонов пока нет."))
            }
            ForEach(groups) { g in
                DisclosureGroup {
                    ForEach(g.presets) { p in row(p) }
                } label: {
                    HStack {
                        Text(g.family.title.text)
                        Text("\(g.presets.count)").font(DS.Typo.numeric(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ p: Preset) -> some View {
        HStack(spacing: DS.Space.sm) {
            SymbolIcon(p.symbol, style: .secondary).frame(width: 22).accessibilityHidden(true)
            Text(p.name.text).lineLimit(2)
            if p.isBuiltin {
                Text(L("Built-in", "Встроенный")).font(DS.Typo.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule())
            }
            Spacer(minLength: DS.Space.sm)
            Menu {
                if !p.isBuiltin { Button(L("Rename…", "Переименовать…")) { newName = p.name.text; renaming = p } }
                Button(L("Duplicate", "Дублировать")) { duplicate(p) }
                Button(L("Export…", "Экспорт…")) { export([p]) }
                if !p.isBuiltin { Divider(); Button(L("Delete…", "Удалить…"), role: .destructive) { deleting = p } }
            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text(L("Actions for this preset", "Действия для шаблона"))) }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }

    // MARK: Actions

    private func fail(_ error: Error) { note = (ConversionError.describe(error), .warning) }

    private func rename() {
        guard let p = renaming, let name = PresetListLogic.cleanName(newName) else { renaming = nil; return }
        do { try store.rename(id: p.id, to: name) } catch { fail(error) }
        renaming = nil
    }

    private func duplicate(_ p: Preset) {
        do { try store.duplicate(id: p.id); note = (L("A copy was added to “Custom”.", "Копия добавлена в группу «Мои»."), .info) } catch { fail(error) }
    }

    private func delete(_ p: Preset) {
        do { try store.delete(id: p.id) } catch { fail(error) }
    }

    private func export(_ list: [Preset]) {
        let name = list.count == 1 ? Util.safeFileName(list[0].name.text) : "Swamp Presets"
        guard let url = SettingsPanels.saveFile(title: L("Export presets", "Экспорт шаблонов"), name: name + ".swampreset", type: SettingsPanels.presetType) else { return }
        do { try store.export(ids: list.map(\.id), to: url); note = (L("Exported to \(url.lastPathComponent).", "Экспортировано в \(url.lastPathComponent)."), .info) } catch { fail(error) }
    }

    private func exportAll() { export(store.userPresets) }

    private func importPresets() {
        guard let url = SettingsPanels.chooseFile(title: L("Import presets", "Импорт шаблонов"), types: [SettingsPanels.presetType, .json], prompt: L("Import", "Импортировать")) else { return }
        do {
            let list = try store.importFile(url)
            note = (L("Imported \(list.count).", "Импортировано: \(list.count)."), .info)
        } catch { fail(error) }
    }
}
