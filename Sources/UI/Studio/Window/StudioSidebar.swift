import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sources (files with status dots, links), Queue (count badge, collapsible rows), Presets (Built-in by kind, Mine, search; drop a source onto a preset to apply it).
struct StudioSidebar: View {
    @StateObject private var model: StudioWindowModel
    init(session: StudioSession) { _model = StateObject(wrappedValue: StudioWindowModel(session: session)) }
    init(model: StudioWindowModel) { _model = StateObject(wrappedValue: model) }

    var body: some View { StudioSidebarContent(model: model) }
}

/// What a sidebar row selects: a source (the centre shows its preview) or the queue (the centre shows the queue panel).
enum StudioSidebarItem: Hashable { case source(String), queue }

struct StudioSidebarContent: View {
    @ObservedObject var model: StudioWindowModel
    @State private var queueExpanded = true

    private var selection: Binding<StudioSidebarItem?> {
        Binding(
            get: { model.pane == .queue ? .queue : model.state.focusedSourceID.map { .source($0) } },
            set: { item in
                switch item {
                case .queue: model.pane = .queue
                case .source(let id): model.selectedSourceID = id; model.pane = .source
                case .none: break
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                StudioSidebarHeader()
                    .listRowSeparator(.hidden)
            }
            Section(L("Sources", "Источники")) {
                if model.state.sources.isEmpty {
                    Text(L("Nothing added yet", "Пока ничего не добавлено")).font(DS.Typo.callout).foregroundStyle(.secondary)
                }
                ForEach(model.state.sources) { row in
                    StudioSourceRowView(row: row)
                        .tag(StudioSidebarItem.source(row.id))
                        .contextMenu { sourceMenu(row) }
                }
                Button { model.perform(.addFiles) } label: {
                    Label(L("Add Files", "Добавить файлы"), systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { model.perform(.pasteLink) } label: {
                    Label(L("Add a Link", "Добавить ссылку"), systemImage: "link")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Download a video or audio from a web page into the Studio (Command-L)", "Скачать видео или звук со страницы в Студию (Command-L)"))
            }
            Section(L("Queue", "Очередь")) {
                StudioQueueSidebarRow(queue: model.queue, expanded: $queueExpanded)
                    .tag(StudioSidebarItem.queue)
                if queueExpanded { StudioQueueSidebarJobs(runner: model.runner) }
            }
            StudioPresetsSection(model: model)
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier(StudioIdentifiers.sidebar)
    }

    @ViewBuilder private func sourceMenu(_ row: StudioSourceRow) -> some View {
        if let url = row.url {
            Button(L("Show in Finder", "Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Button(L("Remove", "Убрать"), role: .destructive) { model.removeSource(id: row.id) }
    }
}

/// The wordmark ornament, small, beside the window's name: the one place in the Studio the signature is shown on every screen.
struct StudioSidebarHeader: View {
    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Brand.wordmark(size: 16, color: Brand.pinkInk)
            Text(StudioWindowController.windowTitle).font(DS.Typo.headline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(StudioWindowController.windowTitle))
    }
}

struct StudioSourceRowView: View, Equatable {
    var row: StudioSourceRow

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let url = row.url {
                ThumbnailView(url: url, kind: row.fileKind, size: 28)
            } else {
                Image(systemName: row.kind.symbol).symbolRenderingMode(.hierarchical).frame(width: 28, height: 28).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(DS.Typo.callout).lineLimit(1).truncationMode(.middle)
                Text(row.failureReason ?? row.detail).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: DS.Space.xs)
            StatusDot(row.statusKind, size: 10)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Queue rows

struct StudioQueueSidebarRow: View, Equatable {
    var queue: QueueSnapshot
    @Binding var expanded: Bool

    static func == (a: Self, b: Self) -> Bool { a.queue == b.queue && a.expanded == b.expanded }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Label(L("Queue", "Очередь"), systemImage: "list.bullet.rectangle")
            Spacer(minLength: DS.Space.xs)
            if queue.open > 0 {
                Text("\(queue.open)")
                    .font(DS.Typo.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 1)
                    .background(Brand.blue.opacity(ChipStyle.fillOpacity), in: Capsule())
                    .foregroundStyle(Brand.blueChipInk)
                    .accessibilityLabel(Text(L("\(queue.open) in the queue", "В очереди: \(queue.open)")))
            }
            if !queue.isEmpty {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).font(.caption.weight(.semibold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(Text(expanded ? L("Collapse the queue", "Свернуть очередь") : L("Expand the queue", "Развернуть очередь")))
            }
        }
    }
}

/// The first few queued jobs under the Queue row. The full list is the queue panel.
struct StudioQueueSidebarJobs: View {
    @ObservedObject var runner: JobRunner
    private static let limit = 5

    var body: some View {
        let jobs = runner.jobs.filter { !$0.state.isFinished }
        ForEach(jobs.prefix(Self.limit)) { job in StudioQueueSidebarJob(job: job) }
        if jobs.count > Self.limit {
            Text(L("and \(jobs.count - Self.limit) more", "и ещё \(jobs.count - Self.limit)")).font(DS.Typo.caption).foregroundStyle(.secondary).padding(.leading, DS.Space.xl)
        }
    }
}

struct StudioQueueSidebarJob: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            StatusDot(StatusKind(job.state), size: 8)
            Text(job.title).font(DS.Typo.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if job.state == .running, let p = job.progress { Text(Loc.percent(Int(p * 100))).font(DS.Typo.numeric(DS.Typo.caption)).foregroundStyle(.secondary) }
        }
        .padding(.leading, DS.Space.lg)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Presets

/// Built-in presets by kind, the person's own, a search field. A click applies; a file dropped on a row opens with that preset.
struct StudioPresetsSection: View {
    @ObservedObject var model: StudioWindowModel
    @ObservedObject private var store = PresetStore.shared
    @State private var query = ""
    @State private var renaming: Preset?
    @State private var renameText = ""
    @State private var deleting: Preset?
    @State private var failure: String?

    private var targetID: String? { model.state.targetID }

    var body: some View {
        let layout = Self.layout(presets: targetID.map { store.presets(for: $0) } ?? [], query: query)
        Section(L("Presets", "Шаблоны")) {
            if targetID == nil {
                Text(L("Add a file to see presets for it.", "Добавьте файл, чтобы увидеть шаблоны для него.")).font(DS.Typo.callout).foregroundStyle(.secondary)
            } else {
                TextField(L("Search presets", "Найти шаблон"), text: $query, prompt: Text(L("Search presets", "Найти шаблон")))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .accessibilityLabel(Text(L("Search presets", "Найти шаблон")))
                if layout.isEmpty {
                    Text(L("No preset matches.", "Нет подходящих шаблонов.")).font(DS.Typo.callout).foregroundStyle(.secondary)
                }
                ForEach(layout.builtinGroups, id: \.group) { g in
                    DisclosureGroup {
                        ForEach(g.presets) { row($0) }
                    } label: {
                        Label(g.group.title.text, systemImage: g.group.symbol)
                    }
                }
                if !layout.mine.isEmpty {
                    DisclosureGroup {
                        ForEach(layout.mine) { row($0) }
                    } label: {
                        Label(L("Mine", "Мои"), systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .alert(L("Rename Preset", "Переименовать шаблон"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name", "Название"), text: $renameText)
            Button(L("Rename", "Переименовать")) { commitRename() }
            Button(L("Cancel", "Отмена"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(L("Delete this preset?", "Удалить этот шаблон?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { p in
            Button(L("Delete “\(p.name.text)”", "Удалить «\(p.name.text)»"), role: .destructive) { delete(p) }
            Button(L("Cancel", "Отмена"), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(L("The preset is removed. Files you converted with it stay as they are.", "Шаблон будет удалён. Файлы, уже преобразованные с ним, не изменятся."))
        }
    }

    // MARK: Layout (pure, tested)

    struct Layout {
        struct Group { var group: PresetGroup; var presets: [Preset] }
        var builtinGroups: [Group]
        var mine: [Preset]
        var isEmpty: Bool { builtinGroups.isEmpty && mine.isEmpty }
    }

    /// Built-in presets grouped by kind in the order of `PresetGroup`, the person's own apart, filtered by the search text (name, notes, both languages).
    static func layout(presets: [Preset], query: String) -> Layout {
        let q = query.trimmingCharacters(in: .whitespaces)
        func matches(_ p: Preset) -> Bool {
            q.isEmpty || [p.name.en, p.name.ru, p.notes?.en ?? "", p.notes?.ru ?? ""].contains { $0.looseContains(q) }
        }
        let shown = presets.filter(matches)
        let builtin = shown.filter(\.isBuiltin)
        let groups = PresetGroup.allCases.compactMap { g -> Layout.Group? in
            let list = builtin.filter { $0.group == g }
            return list.isEmpty ? nil : Layout.Group(group: g, presets: list)
        }
        return Layout(builtinGroups: groups, mine: shown.filter { !$0.isBuiltin })
    }

    // MARK: Row

    @ViewBuilder private func row(_ p: Preset) -> some View {
        let isCurrent = model.state.presetID == p.id
        let isDefault = targetID.flatMap { store.defaultPresetID(for: $0) } == p.id
        Button { model.session.apply(preset: p) } label: {
            HStack(spacing: DS.Space.sm) {
                Label(p.name.text, systemImage: p.symbol).lineLimit(2)
                Spacer(minLength: DS.Space.xs)
                if isDefault { InfoChip(L("Default", "По умолчанию"), emphasized: true) }
                if isCurrent { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Brand.pinkInk).accessibilityLabel(Text(L("Selected", "Выбрано"))) }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(p.notes?.text ?? p.name.text)
        .contextMenu { menu(p, isDefault: isDefault) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in dropped(providers, on: p); return true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder private func menu(_ p: Preset, isDefault: Bool) -> some View {
        Button(L("Apply", "Применить")) { model.session.apply(preset: p) }
        Divider()
        Button(L("Duplicate", "Создать копию")) { run { _ = try store.duplicate(id: p.id) } }
        if !p.isBuiltin {
            Button(L("Rename…", "Переименовать…")) { renameText = p.name.text; renaming = p }
            Button(L("Delete…", "Удалить…"), role: .destructive) { deleting = p }
        }
        Button(L("Export…", "Экспортировать…")) { export(p) }
        if let t = targetID {
            Button(isDefault ? L("Remove as Default", "Больше не по умолчанию") : L("Make Default", "Сделать шаблоном по умолчанию")) {
                store.setDefaultPreset(isDefault ? nil : p.id, for: t)
            }
        }
    }

    // MARK: Actions

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { MessageCenter.shared.post((error as? LocalizedError)?.errorDescription ?? ConversionError.describe(error), severity: .warning, symbol: "exclamationmark.triangle") }
    }

    private func commitRename() {
        guard let p = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty else { return }
        run { try store.rename(id: p.id, to: name) }
    }

    private func delete(_ p: Preset) { deleting = nil; run { try store.delete(id: p.id) } }

    private func export(_ p: Preset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Util.safeFileName(p.name.text) + ".swampreset"
        if let t = UTType(filenameExtension: "swampreset") { panel.allowedContentTypes = [t] }
        panel.canCreateDirectories = true
        let id = p.id
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let url = panel.url else { return }
            run { try store.export(ids: [id], to: url) }
        }
        if let w = model.window { panel.beginSheetModal(for: w, completionHandler: handle) } else { panel.begin(completionHandler: handle) }
    }

    /// Files dropped on a preset join the sources and the preset is applied to them.
    private func dropped(_ providers: [NSItemProvider], on p: Preset) {
        Task { @MainActor in
            model.ingest(await StudioDropParser.load(providers))
            if model.session.targetID != p.targetID { model.session.selectTarget(p.targetID, operationID: p.operationID) }
            model.session.apply(preset: p)
        }
    }
}
