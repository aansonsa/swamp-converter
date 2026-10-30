import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Toolbar preset pop-up (grouped Web, Devices, Social, Archive, Small size, Lossless, Custom, with symbols, last used on top) with the "Modified" badge, Revert, Save Changes, Save as New
/// Preset..., Show changes, Make Default, Duplicate, Rename, Delete (user presets), Import / Export `.swampreset`. Presets are `PresetStore.shared` (or the store the session was given).
struct PresetBar: View {
    @ObservedObject var session: StudioSession
    @ObservedObject private var store: PresetStore
    @State private var showSave = false
    @State private var showChanges = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var renameText = ""
    @State private var problem: String?

    init(session: StudioSession) {
        self.session = session
        self._store = ObservedObject(wrappedValue: session.presetStore)
    }

    private var preset: Preset? { session.currentPreset }
    private var isUserPreset: Bool { preset.map { !$0.isBuiltin } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                presetMenu
                if session.isModified { StudioModifiedBadge(onRevert: { session.revertAll() }) }
            }
            if let problem { OptionMessageRow(problem, severity: .error, onDismiss: { self.problem = nil }) }
        }
        .sheet(isPresented: $showSave) { SavePresetSheet(session: session) }
        .alert(L("Rename Preset", "Переименовать шаблон"), isPresented: $showRename) {
            TextField(L("Name", "Название"), text: $renameText)
            Button(L("Cancel", "Отмена"), role: .cancel) {}
            Button(L("Rename", "Переименовать")) { attempt { try session.renameCurrentPreset(to: renameText) } }
        }
        .confirmationDialog(L("Delete this preset?", "Удалить этот шаблон?"), isPresented: $showDelete, titleVisibility: .visible) {
            Button(L("Delete", "Удалить"), role: .destructive) { attempt { try session.deleteCurrentPreset() } }
            Button(L("Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("Your settings stay as they are; only the saved preset goes away.", "Ваши настройки останутся как есть, удалится только сохранённый шаблон."))
        }
    }

    // MARK: Menu

    private var presetMenu: some View {
        Menu {
            if let last = session.lastUsedPreset, last.id != session.presetID {
                Section(L("Last used", "Недавний")) {
                    Button { session.apply(preset: last) } label: { Label(last.name.text, systemImage: last.symbol) }
                }
            }
            Section(L("Quick recipe", "Быстрый рецепт")) {
                Button { session.clearPreset() } label: {
                    Label(L("Same as the Wheel", "Как на колесе"), systemImage: session.presetID == nil ? "checkmark" : "arrow.triangle.2.circlepath")
                }
            }
            ForEach(session.groupedPresets, id: \.group) { entry in
                Section(entry.group.title.text) {
                    ForEach(entry.presets) { p in
                        Button { session.apply(preset: p) } label: { presetLabel(p) }
                    }
                }
            }
            Divider()
            actions
        } label: {
            Label(menuTitle, systemImage: preset?.symbol ?? "slider.horizontal.3")
        }
        .menuStyle(.button)
        .secondaryButtonLook()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text(L("Preset", "Шаблон")))
        .accessibilityValue(Text(menuTitle + (session.isModified ? ", " + OptionStrings.modified.text : "")))
        .popover(isPresented: $showChanges, arrowEdge: .bottom) { ChangesListView(session: session) }
    }

    private func presetLabel(_ p: Preset) -> Label<Text, Image> {
        let selected = session.presetID == p.id
        return Label(p.name.text, systemImage: selected ? "checkmark" : p.symbol)
    }

    private var menuTitle: String { preset?.name.text ?? L("Quick recipe", "Быстрый рецепт") }

    @ViewBuilder private var actions: some View {
        Button(L("Revert Changes", "Отменить изменения")) { session.revertAll() }.disabled(!session.isModified)
        Button(L("Save Changes to Preset", "Сохранить изменения в шаблоне")) { attempt { try session.saveChangesToPreset() } }
            .disabled(!(session.isModified && isUserPreset))
        Button(L("Save as New Preset…", "Сохранить как новый шаблон…")) { showSave = true }.disabled(session.schema == nil)
        Button(L("Show Changes…", "Показать изменения…")) { showChanges = true }.disabled(!session.isModified)
        Divider()
        Button(L("Make Default", "Сделать основным")) { session.makeDefaultPreset() }.disabled(preset == nil || session.isDefaultPreset)
        Button(L("Duplicate", "Дублировать")) { attempt { try session.duplicateCurrentPreset() } }.disabled(preset == nil)
        Button(L("Rename…", "Переименовать…")) { renameText = preset?.name.text ?? ""; showRename = true }.disabled(!isUserPreset)
        Button(L("Delete…", "Удалить…")) { showDelete = true }.disabled(!isUserPreset)
        Divider()
        Button(L("Import Presets…", "Импортировать шаблоны…")) { importPresets() }
        Button(L("Export Preset…", "Экспортировать шаблон…")) { exportPreset() }.disabled(preset == nil)
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body(); problem = nil } catch { problem = ConversionError.describe(error) }
    }

    // MARK: Import and export

    static var presetFileType: UTType { UTType(filenameExtension: "swampreset") ?? .json }

    private func importPresets() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [Self.presetFileType, .json]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = L("Import", "Импортировать")
        p.begin { r in
            guard r == .OK else { return }
            MainActor.assumeIsolated {
                var imported = 0
                for url in p.urls { if let list = try? session.importPresets(from: url) { imported += list.count } else { problem = PresetError.notAPresetFile.errorDescription } }
                if imported > 0 { problem = nil }
            }
        }
    }

    private func exportPreset() {
        guard let preset else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [Self.presetFileType]
        p.nameFieldStringValue = Util.safeFileName(preset.name.text) + ".swampreset"
        p.prompt = L("Export", "Экспортировать")
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            MainActor.assumeIsolated { attempt { try session.exportCurrentPreset(to: url) } }
        }
    }
}

// MARK: - Show changes

/// "Quality 22 -> 20, Resolution 1080p -> 720p" with a revert button per line.
struct ChangesListView: View {
    @ObservedObject var session: StudioSession

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Text(L("Changes", "Изменения")).font(DS.Typo.headline)
                Spacer()
                if !session.changes.isEmpty { Button { session.revertAll() } label: { Text(L("Revert All", "Вернуть всё")).foregroundStyle(Brand.blueInk) }.buttonStyle(.plain) }
            }
            if session.changes.isEmpty {
                Text(L("Nothing has changed.", "Ничего не менялось.")).foregroundStyle(.secondary)
            } else {
                ForEach(session.changes, id: \.change.key) { item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.field.label.text).font(DS.Typo.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            Text("\(OptionFormat.display(item.change.old, for: item.field)) \u{2192} \(OptionFormat.display(item.change.new, for: item.field))")
                                .font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: DS.Space.sm)
                        Button { session.revert(key: item.change.key) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).foregroundStyle(Brand.blueInk)
                            .help(OptionStrings.revertToDefault.text)
                            .accessibilityLabel(Text(L("Revert \(item.field.label.text)", "Вернуть: \(item.field.label.text)")))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(DS.Space.lg)
    }
}

// MARK: - Save as new preset

struct SavePresetSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "slider.horizontal.3"
    @State private var group: PresetGroup = .custom
    @State private var wheel: WheelKind?
    @State private var locked: Set<String> = []
    @State private var problem: String?

    static let symbols = ["slider.horizontal.3", "star", "bolt", "film", "photo", "waveform", "doc.richtext", "iphone", "globe", "archivebox", "person.2", "arrow.down.right.and.arrow.up.left"]

    private var lockable: [OptionField] {
        let keys = session.valuesForSaving().keys
        return keys.compactMap { session.schema?.field($0) }.sorted { $0.label.text < $1.label.text }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("Name", "Название"), text: $name, prompt: Text(L("My preset", "Мой шаблон")))
                    Picker(L("Group", "Группа"), selection: $group) {
                        ForEach(PresetGroup.allCases, id: \.self) { Label($0.title.text, systemImage: $0.symbol).tag($0) }
                    }
                    LabeledContent(L("Symbol", "Значок")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: DS.Space.xs), count: 6), spacing: DS.Space.xs) {
                            ForEach(Self.symbols, id: \.self) { s in
                                Button { symbol = s } label: {
                                    Image(systemName: s).frame(width: 28, height: 28)
                                        .background(symbol == s ? Brand.tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                                        .overlay { if symbol == s { RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(Brand.tint, lineWidth: 1.5) } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(s))
                                .accessibilityAddTraits(symbol == s ? .isSelected : [])
                            }
                        }
                    }
                    Picker(L("Show on the wheel", "Показывать на колесе"), selection: $wheel) {
                        Text(L("Not on the wheel", "Не показывать")).tag(WheelKind?.none)
                        Text(WheelKind.convert.title.text).tag(WheelKind?.some(.convert))
                        Text(WheelKind.tools.title.text).tag(WheelKind?.some(.tools))
                    }
                }
                if !lockable.isEmpty {
                    Section {
                        ForEach(lockable, id: \.key) { f in
                            Toggle(isOn: Binding(get: { locked.contains(f.key) }, set: { if $0 { locked.insert(f.key) } else { locked.remove(f.key) } })) {
                                Text(f.label.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } header: {
                        Text(L("Lock fields", "Заблокировать параметры"))
                    } footer: {
                        Text(L("A locked field can’t be changed while this preset is selected.", "Заблокированный параметр нельзя менять, пока выбран этот шаблон."))
                    }
                }
                if let problem { Section { OptionMessageRow(problem, severity: .error) } }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).secondaryButtonLook()
                Button(L("Save", "Сохранить")) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 420, height: 520)
        .appRoot()
    }

    private func save() {
        do {
            try session.saveAsPreset(name: name, symbol: symbol, group: group, locks: Array(locked), onWheel: wheel)
            dismiss()
        } catch { problem = ConversionError.describe(error) }
    }
}
