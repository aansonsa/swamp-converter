import Foundation

/// One wheel sector per preset: `multi.<id>`; applies when the selection's profile equals `inputProfile`.
/// Runs every output of the pack on every input inside ONE job: a stage per output, the failure of one output never stops the others (it is listed in
/// `OperationResult.failures`), files are named `{name} - {suffix}.{ext}` and, when a pack makes more than four files per input, they go into a folder
/// `{name} - {pack}` next to the original (or inside the job's output folder).
final class MultiOutputOperation: OperationBase, @unchecked Sendable {
    let preset: MultiOutputPreset
    private let registry: OperationRegistry
    /// More files than this per input go into their own folder.
    static let flatLimit = 4

    init(preset: MultiOutputPreset, registry: OperationRegistry = .shared) {
        self.preset = preset
        self.registry = registry
        var m = OperationMeta.make("multi.\(preset.id)", preset.wheel, Self.family(of: preset.inputProfile), preset.name,
                                   sub: L10n("\(preset.items.count) files", "файлов: \(preset.items.count)"), symbol: preset.symbol, schema: "multi.pack", anyFile: true)
        m.acceptsDirectories = preset.inputProfile == .folder
        super.init(meta: m)
    }

    static func family(of profile: WheelProfile) -> OperationFamily {
        switch profile {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .pdf: return .pdf
        case .document: return .document
        case .slides: return .slides
        case .spreadsheet: return .spreadsheet
        case .subtitle: return .subtitle
        case .archive: return .archive
        default: return .app
        }
    }

    // MARK: Applicability

    override func appliesTo(_ items: [FileItem]) -> Bool { !items.isEmpty && WheelProfile.profile(for: items) == preset.inputProfile }
    /// Packs are wheel sectors; Studio has one target per engine, not one per pack.
    override func appliesInStudio(_ items: [FileItem]) -> Bool { false }

    /// Operations of the pack that this Mac can run. A pack stays available while at least one output can run (the others are reported as skipped when it runs).
    func runnableOutputs(for items: [FileItem], tools: ToolLocator) -> [(item: MultiOutputItem, operation: Operation)] {
        preset.items.compactMap { out in
            guard let op = AutomationRun.operation(for: out.recipe, registry: registry), op.availability(for: items, tools: tools).isAvailable else { return nil }
            return (out, op)
        }
    }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        if preset.items.isEmpty { return .unavailable(reason: L10n("This pack has no outputs.", "В этом наборе нет результатов."), missing: []) }
        if !runnableOutputs(for: items, tools: tools).isEmpty { return .available }
        for out in preset.items {
            guard let op = AutomationRun.operation(for: out.recipe, registry: registry) else { continue }
            let a = op.availability(for: items, tools: tools)
            if !a.isAvailable { return a }
        }
        return .unavailable(reason: L10n("The operations of this pack are not available.", "Операции этого набора недоступны."), missing: [])
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        return OperationEstimate(bytes: total * Int64(min(preset.items.count, 4)), seconds: nil, confidence: .rough)
    }

    override func stagePlan(options: OptionValues) -> [StageSpec] {
        preset.items.enumerated().map { StageSpec(id: "out\($0.offset)", title: $0.element.label, weight: 1) }
    }

    // MARK: Running

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        guard !preset.items.isEmpty else { throw ConversionError.message(L10n("This pack has no outputs.", "В этом наборе нет результатов.")) }
        var result = OperationResult()
        var failures: [String] = []
        var warnings: [String] = []
        // Where each input's results go. A pack of many files gets its own folder per input, decided (and created) up front so two inputs can never share one.
        var folders: [URL: URL] = [:]
        var createdFolders: [URL] = []
        let wantsFolder = preset.items.count > Self.flatLimit
        for item in items {
            let base = try OutputPaths.outputDirectory(for: item, rules: ctx.outputRules)
            if wantsFolder {
                let name = AutomationRun.literalName("\(item.base) - \(preset.name.text)")
                let folder = ctx.outputRules.collision == .number ? OutputPaths.uniqueDirectory(dir: base, name: name) : base.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                OwnOutputs.shared.register(folder)
                folders[item.url] = folder
                createdFolders.append(folder)
            } else {
                folders[item.url] = base
            }
        }
        defer { for f in createdFolders where Self.isEmptyFolder(f) { try? FileManager.default.removeItem(at: f) } }

        for (i, out) in preset.items.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            ctx.beginStage("out\(i)")
            defer { ctx.finishStage("out\(i)") }
            guard let op = AutomationRun.operation(for: out.recipe, registry: registry) else {
                failures.append("\(out.label.text): " + L("the operation no longer exists", "операции больше нет"))
                continue
            }
            if case .unavailable(let reason, _) = op.availability(for: items, tools: ctx.tools) {
                warnings.append("\(out.label.text): \(reason.text)")
                continue
            }
            let overrides = AutomationRun.overrides(for: op, recipe: out.recipe, settings: ctx.settings)
            for (j, item) in items.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                guard let folder = folders[item.url] else { continue }
                var rules = ctx.outputRules
                rules.dirMode = .custom
                rules.customDir = folder.path
                rules.nameTemplate = "{name} - " + AutomationRun.literalName(out.nameSuffix)
                rules.trashSource = false
                let total = max(items.count, 1), index = j
                do {
                    let r = try await ctx.runNestedMapped(op, items: [item], overrides: overrides, outputRules: rules, mode: .studio) { (Double(index) + $0) / Double(total) }
                    result.outputs += r.outputs
                    failures += r.failures.map { "\(out.label.text): \($0)" }
                    warnings += r.warnings
                    if r.outputs.isEmpty && r.failures.isEmpty { failures.append("\(item.name) - \(out.label.text): " + L("no file was produced", "файл не создан")) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("\(items.count > 1 ? item.name + " - " : "")\(out.label.text): \(ConversionError.describe(error))")
                    ctx.log("FAILED \(item.name) / \(out.label.text): \(ConversionError.describe(error))")
                }
            }
        }
        // A pack that made a folder reports the folder (the files are inside); flat packs report their files.
        if wantsFolder {
            let used = createdFolders.filter { !Self.isEmptyFolder($0) }
            result.outputs = used
        }
        if result.outputs.isEmpty {
            throw ConversionError.aggregate(failures.isEmpty ? warnings : failures)
        }
        result.failures = failures
        result.warnings = warnings
        if !failures.isEmpty || !warnings.isEmpty {
            result.note = L10n("Some files of the pack were not made.", "Не все файлы набора созданы.")
        }
        return result
    }

    private static func isEmptyFolder(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty
    }
}

enum MultiOutputRegistry {
    private static let cache = Locked<(revision: Int, operations: [Operation])?>(nil)

    /// Registers the provider that exposes `MultiOutputStore.shared.all` as wheel operations (rebuilt only when the store changed) and the chains next to it.
    /// Packs run registered operations that the `conformance.*` tests judge themselves (Core's exemption list names `multi.*` like `preset.*` and `chain.*`); the automation tests judge the fan-out.
    @MainActor
    static func install() {
        OperationRegistry.shared.registerProvider(id: "multi-output") { _ in operations() }
        ChainProvider.install()
    }

    static func operations(store: MultiOutputStore = .shared) -> [Operation] {
        let revision = store.revision
        if store === MultiOutputStore.shared, let c = cache.value, c.revision == revision { return c.operations }
        let ops: [Operation] = store.all.map { MultiOutputOperation(preset: $0) }
        if store === MultiOutputStore.shared { cache.value = (revision, ops) }
        return ops
    }
}
