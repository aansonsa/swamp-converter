import Foundation
import SwiftUI
import CoreGraphics

/// One source row of the Studio: the input, its probe, and a status.
struct StudioSource: Identifiable {
    enum Status: Equatable { case probing, ready, failed(String) }
    var input: InputItem
    var info: SourceInfo?
    var status: Status = .probing
    var id: String { input.id }
    var isUsable: Bool { if case .failed = status { return false } else { return true } }
}

/// What `StudioSession` remembers for undo: the user's layer, the active preset and its locks. One entry per edited field (a slider drag is ONE entry).
struct StudioUndoState {
    var values: OptionValues
    var presetID: String?
    var lockedKeys: Set<String>
}

/// The state machine behind one Studio window. UI-free: the window and the renderer observe it; tests drive it directly.
/// Quick and Studio share ONE engine: `recipe()` produces a `Recipe` that `JobRunner.submit(recipe:items:)` runs exactly like the wheel does.
///
/// Value layers, lowest first (the same order `QuickRecipes.resolve` and the job runner use):
///     schema defaults (computed from the probed source)  <  the operation's quick recipe  <  the preset  <  `values` (what the person changed)
/// Everything is derived from those four by `OptionSchema.resolve`, so `resolved` is always complete and clamped.
///
/// Split over files: this one holds state, sources and targets; `+Values` edits and undo; `+Presets`; `+Derived` estimate / chips / preview; `+Run` recipes and queueing.
@MainActor
final class StudioSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()

    // MARK: Environment (injectable: tests and snapshots pass their own)
    let registry: OperationRegistry
    let settings: AppSettings
    var presetStore: PresetStore
    var runner: JobRunner
    /// False in snapshots: the probe results are injected by hand.
    let autoProbe: Bool

    // MARK: Inputs and targets
    @Published var sources: [StudioSource] = []
    /// The source that decides source-dependent defaults, validation, estimate and preview (the sidebar selection). nil = the first usable source.
    @Published var focusedSourceID: String?
    /// Targets that apply to ALL current inputs (files: `OperationRegistry.studioTargets(for:)`; links: `studioTargets(forLinks:)`), grouped by family for the target picker.
    /// With no inputs at all every target is listed, so a recipe can be edited before any file is added.
    @Published var targets: [StudioTarget] = []
    @Published var targetID: String?
    /// The operation whose quick recipe seeds the values (the wheel sector the user came from, or the target's primary).
    @Published var operationID: String?
    var operation: Operation?
    @Published var availability: OperationAvailability = .available

    // MARK: Options
    @Published var schema: OptionSchema?
    /// What the user changed (sparse over the base). Base = schema defaults(source) < operation quick recipe < preset values.
    @Published var values = OptionValues()
    @Published var resolved: ResolvedOptions?
    /// `resolved` without the user's layer: what "default" means for every field (the quick recipe, or the preset when one is selected).
    var baseResolved: ResolvedOptions?
    @Published var messages: [OptionMessage] = []
    @Published var outputRules: OutputRules {
        didSet { if !syncingOutput && oldValue != outputRules { outputRulesAssigned() } }
    }
    var syncingOutput = false

    // MARK: Presets
    @Published var presetID: String?
    /// Fields the selected preset locks: read-only in the form, with the reason.
    @Published var lockedKeys: Set<String> = []
    /// True when the user's layer diverges from the selected preset (or from the quick recipe when no preset is selected): the "Modified" badge.
    @Published var isModified = false
    var changeList: [(field: OptionField, change: OptionChange)] = []

    // MARK: UI state that belongs to the session (remembered per family)
    @Published var density: DensitySetting = .simple {
        didSet { if !restoringUIState && oldValue != density { saveDensity() } }
    }
    @Published var searchText = ""
    @Published var selectedPageID: String? {
        didSet { if !restoringUIState && oldValue != selectedPageID { savePage() } }
    }
    /// "Show expert options" for the whole inspector (Advanced density).
    @Published var showExpert = false
    /// Bumped by `focusSearch()`; the form moves keyboard focus to the search field when it changes.
    @Published var searchFocusToken = 0
    var restoringUIState = false

    // MARK: Undo
    @Published var canUndo = false
    @Published var canRedo = false
    var undoStack: [StudioUndoState] = []
    var redoStack: [StudioUndoState] = []
    var lastUndoKey: String?
    var lastUndoAt = Date.distantPast
    var openGroupKey: String?

    // MARK: Derived (computed off the main thread, keyed by an options hash)
    @Published var estimate: OperationEstimate?
    @Published var summaryChips: [String] = []
    @Published var preview: OperationPreview?
    @Published var isPreviewing = false
    var derivedKey: StudioDerivedKey?
    var previewKey: StudioPreviewKey?
    var previewRequest: (time: Double?, maxPixel: Int)?
    var derivedTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var measureNote: L10n?

    // MARK: Queue editing
    /// The queued job loaded by `load(job:)`: edits are written back to it while it waits.
    @Published var editingJob: Job?
    /// The job started meanwhile; its options can no longer change.
    @Published var editingJobLocked = false

    // MARK: Probing
    var probeTask: Task<Void, Never>?

    static let mixedInputsReason = L("Files and links can’t be combined in one batch.", "Файлы и ссылки нельзя смешивать в одной партии.")

    /// `input` = what was dropped / selected; `targetID` and `recipe` pre-select a target and its values ("Customise..." from the wheel, "Edit in Studio..." from Settings, queue "Edit Options").
    /// The remaining parameters inject the environment (tests, snapshots); the defaults are the app-wide singletons.
    init(input: IncomingInput, targetID: String? = nil, recipe: Recipe? = nil, registry: OperationRegistry = .shared, settings: AppSettings = .shared,
         presetStore: PresetStore = .shared, runner: JobRunner? = nil, autoProbe: Bool = true) {
        self.registry = registry
        self.settings = settings
        self.presetStore = presetStore
        self.runner = runner ?? JobRunner.shared
        self.autoProbe = autoProbe
        self.outputRules = settings.data.output
        sources = Self.makeSources(files: input.files, links: input.links)
        normalizeStatuses()
        refreshTargets()
        let wanted = recipe?.operationID ?? targetID
        if let wanted, let op = registry.operation(id: wanted) ?? registry.primaryOperation(forTarget: wanted) {
            selectTarget(op.meta.schemaID, operationID: registry.operation(id: wanted) != nil ? wanted : nil, seedDefaultPreset: recipe == nil)
        } else if let first = targets.first(where: { $0.availability.isAvailable }) ?? targets.first, !sources.isEmpty {
            selectTarget(first.id)
        }
        if let recipe { adopt(recipe) }
        startProbing()
    }

    static func makeSources(files: [FileItem], links: [LinkItem]) -> [StudioSource] {
        var out: [StudioSource] = []
        var seen = Set<String>()
        for f in files {
            let s = StudioSource(input: .file(f))
            if seen.insert(s.id).inserted { out.append(s) }
        }
        for l in links {
            var s = StudioSource(input: .link(l))
            s.status = .ready
            if seen.insert(s.id).inserted { out.append(s) }
        }
        return out
    }

    // MARK: Sources

    var activeFiles: [FileItem] { sources.filter(\.isUsable).compactMap { $0.input.file } }
    var activeLinks: [LinkItem] { sources.filter(\.isUsable).compactMap { $0.input.link } }
    var activeSource: StudioSource? {
        if let id = focusedSourceID, let s = sources.first(where: { $0.id == id && $0.isUsable }) { return s }
        return sources.first(where: \.isUsable)
    }
    var isLinkSession: Bool { activeFiles.isEmpty && !activeLinks.isEmpty }
    var isProbing: Bool { sources.contains { $0.status == .probing } }

    func addSources(_ inputs: [InputItem]) {
        var changed = false
        for i in inputs where !sources.contains(where: { $0.id == i.id }) {
            var s = StudioSource(input: i)
            if i.isLink { s.status = .ready }
            sources.append(s)
            changed = true
        }
        guard changed else { return }
        sourcesChanged()
    }

    func removeSource(id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources.remove(at: i)
        if focusedSourceID == id { focusedSourceID = nil }
        sourcesChanged()
    }

    func focus(sourceID: String?) {
        focusedSourceID = sourceID
        recompute()
    }

    private func sourcesChanged() {
        normalizeStatuses()
        refreshTargets()
        if let t = targetID, targets.contains(where: { $0.id == t }) {
            refreshSchema()
        } else if let first = targets.first(where: { $0.availability.isAvailable }) ?? targets.first, !sources.isEmpty {
            selectTarget(first.id)
        } else if targetID != nil {
            clearTarget()
        }
        recompute()
        startProbing()
    }

    /// The first source decides whether the batch is files or links; the others of the other kind fail with a calm reason (and recover when the first one goes).
    func normalizeStatuses() {
        guard let firstKind = sources.first?.input.isLink else { return }
        for i in sources.indices {
            let isLink = sources[i].input.isLink
            if isLink != firstKind {
                sources[i].status = .failed(Self.mixedInputsReason)
            } else if sources[i].status == .failed(Self.mixedInputsReason) {
                sources[i].status = isLink ? .ready : .probing
            }
        }
    }

    func refreshTargets() {
        let files = activeFiles, links = activeLinks
        let snap = settings.data
        if !files.isEmpty { targets = registry.studioTargets(for: files, settings: snap) }
        else if !links.isEmpty { targets = registry.studioTargets(forLinks: links, settings: snap) }
        else { targets = allTargets(settings: snap) }
    }

    /// Every Studio target regardless of inputs (an empty Studio, "Edit in Studio..." on a recipe).
    func allTargets(settings snap: SettingsData) -> [StudioTarget] {
        var order: [String] = []
        var groups: [String: [Operation]] = [:]
        for op in registry.allOperations(settings: snap) where !op.meta.isAppAction && !op.meta.id.hasPrefix("preset.") {
            if groups[op.meta.schemaID] == nil { order.append(op.meta.schemaID) }
            groups[op.meta.schemaID, default: []].append(op)
        }
        return order.compactMap { sid in
            guard let list = groups[sid], let first = list.first else { return nil }
            let s = first.optionSchema(for: [])
            return StudioTarget(id: sid, family: first.meta.family, title: s.title, symbol: s.symbol, operations: list,
                                availability: first.availability(for: activeFiles, tools: .shared))
        }
    }

    // MARK: Probing

    func startProbing() {
        guard autoProbe, sources.contains(where: { $0.status == .probing }) else { return }
        if probeTask != nil { return }
        probeTask = Task { [weak self] in
            await self?.probePending()
            self?.probeTask = nil
            // Sources added while probing.
            if let self, self.sources.contains(where: { $0.status == .probing }) { self.startProbing() }
        }
    }

    /// Probes every source that has not been probed yet and waits for the results. Safe to call while background probing runs.
    func probeAll() async {
        if let t = probeTask { await t.value }
        await probePending()
    }

    private func probePending() async {
        let pending = sources.filter { $0.status == .probing }.compactMap { s in s.input.file.map { (s.id, $0) } }
        await withTaskGroup(of: (String, SourceInfo?).self) { group in
            for (id, file) in pending {
                group.addTask {
                    guard FileManager.default.fileExists(atPath: file.url.path) else { return (id, nil) }
                    return (id, await SourceProbeRegistry.shared.info(for: file))
                }
            }
            for await (id, info) in group {
                if let info { applyProbe(info, forSourceID: id) }
                else { markFailed(id, L("The file can’t be found.", "Файл не найден.")) }
            }
        }
    }

    /// Stores a probe result (also used by snapshots and tests that inject a `SourceInfo`).
    func applyProbe(_ info: SourceInfo, forSourceID id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].info = info
        sources[i].status = .ready
        recompute()
    }

    func markFailed(_ id: String, _ reason: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].status = .failed(reason)
        sourcesChanged()
    }

    // MARK: Target

    /// Picks the Studio target `id` (a schema id). `operationID` = the wheel sector the person came from: its quick recipe seeds the values; nil = the target's primary operation
    /// (and then the target's default preset, if the person made one).
    func selectTarget(_ requested: String, operationID requestedOp: String? = nil, seedDefaultPreset: Bool = true) {
        // Be forgiving: an operation id where a target id is expected means "that operation's target, seeded from that operation".
        var id = requested, opID = requestedOp
        if !targets.contains(where: { $0.id == requested }), let op = registry.operation(id: requested), opID == nil {
            id = op.meta.schemaID; opID = requested
        }
        guard let target = targets.first(where: { $0.id == id }) ?? allTargets(settings: settings.data).first(where: { $0.id == id }) else { return }
        let chosen = opID.flatMap { registry.operation(id: $0) }.flatMap { $0.meta.schemaID == id ? $0 : nil } ?? target.primary
        targetID = id
        operation = chosen
        operationID = chosen.meta.id
        availability = chosen.availability(for: activeFiles, tools: .shared)
        schema = buildSchema(for: chosen)
        values = OptionValues()
        presetID = nil
        lockedKeys = []
        editingJob = nil
        editingJobLocked = false
        resetUndo()
        restoreUIState(for: target)
        measureNote = nil
        recompute()
        if seedDefaultPreset, opID == nil, let did = presetStore.defaultPresetID(for: id), let p = presetStore.preset(id: did) {
            apply(preset: p)
        }
    }

    private func clearTarget() {
        targetID = nil; operation = nil; operationID = nil; schema = nil; values = OptionValues(); presetID = nil; lockedKeys = []
        resetUndo()
        recompute()
    }

    func buildSchema(for op: Operation) -> OptionSchema {
        activeFiles.isEmpty ? op.studioSchema(for: []) : op.studioSchema(for: activeFiles)
    }

    /// The set of inputs changed: the schema may depend on them (formats, track lists), the values stay.
    func refreshSchema() {
        guard let op = operation else { return }
        availability = op.availability(for: activeFiles, tools: .shared)
        schema = buildSchema(for: op)
    }

    private func restoreUIState(for target: StudioTarget) {
        restoringUIState = true
        defer { restoringUIState = false }
        density = settings.data.studio.densityByFamily[target.family.rawValue] ?? .simple
        showExpert = false
        searchText = ""
        let saved = settings.data.studio.inspectorPage[target.id]
        selectedPageID = saved.flatMap { id in schema?.pages.contains(where: { $0.id == id }) == true ? id : nil } ?? schema?.pages.first?.id
    }

    private func saveDensity() {
        guard let family = (targets.first { $0.id == targetID }?.family ?? operation?.meta.family) else { return }
        let d = density
        settings.update { $0.studio.densityByFamily[family.rawValue] = d }
    }

    private func savePage() {
        guard let t = targetID, let p = selectedPageID else { return }
        settings.update { $0.studio.inspectorPage[t] = p }
    }

    /// Focus the inspector's search field (Cmd-F).
    func focusSearch() { searchFocusToken += 1 }

    /// Cmd-1 ... Cmd-7: the n-th visible page.
    func selectPage(at index: Int) {
        guard let schema else { return }
        let pages = OptionFormLogic.visiblePages(schema, env: formEnvironment)
        if pages.indices.contains(index) { selectedPageID = pages[index].id }
    }

    // MARK: Environment for conditions

    var formEnvironment: ExprEnvironment {
        ExprEnvironment(values: resolved?.values ?? OptionValues(), source: activeSource?.info)
    }
}
