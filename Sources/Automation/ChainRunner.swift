import Foundation

/// Runs a `RecipeChain` (spec/appfeatures.md 6.2, 6.4): each step receives the OUTPUTS of the previous one; one job, one card, stages per step.
/// Implemented on `ctx` so pause / cancel / progress work as for any operation; intermediate files live in `ctx.tempDir` and only the last step writes
/// into the user's folder. A failing step stops the chain with the step name in the message.
///
/// Steps run with Studio semantics (`.studio`): a step is never skipped because a file "already has the target format", otherwise a skipped step would silently
/// drop files from the chain.
final class ChainOperation: OperationBase, @unchecked Sendable {
    let chain: RecipeChain
    private let registry: OperationRegistry
    private let first: Operation

    /// `chain.<id>` operation for a chain placed on a wheel (`chain.wheel`). nil when its first step does not exist any more.
    init?(chain: RecipeChain, registry: OperationRegistry = .shared) {
        guard let firstStep = chain.steps.first, let op = AutomationRun.operation(for: firstStep, registry: registry) else { return nil }
        self.chain = chain
        self.registry = registry
        self.first = op
        var m = op.meta
        m.id = "chain.\(chain.id)"
        m.wheel = chain.wheel ?? .tools
        m.label = L10n(chain.name)
        m.subtitle = L10n("\(chain.steps.count) steps", "шагов: \(chain.steps.count)")
        m.symbol = chain.symbol
        m.targetFormat = nil
        m.suffix = L10n(Util.safeSuffix(chain.name))
        m.quickPromptKeys = []
        m.minItems = op.meta.minItems
        // Everything any step needs, so the wheel shows the chain dimmed with the right hint when a tool is missing.
        var tools = op.meta.requires
        for step in chain.steps.dropFirst() {
            for t in AutomationRun.operation(for: step, registry: registry)?.meta.requires ?? [] where !tools.contains(t) { tools.append(t) }
        }
        m.requires = tools
        m.concurrency = Self.heaviest(chain, registry: registry, fallback: op.meta.concurrency)
        super.init(meta: m)
    }

    private static func heaviest(_ chain: RecipeChain, registry: OperationRegistry, fallback: ConcurrencyClass) -> ConcurrencyClass {
        var best = fallback
        func rank(_ c: ConcurrencyClass) -> Int { c == .light ? 0 : c == .video ? 1 : 2 }
        for step in chain.steps { if let c = AutomationRun.operation(for: step, registry: registry)?.meta.concurrency, rank(c) > rank(best) { best = c } }
        return best
    }

    override func stagePlan(options: OptionValues) -> [StageSpec] {
        chain.steps.enumerated().map { i, step in
            let label = AutomationRun.operation(for: step, registry: registry)?.meta.label
            return StageSpec(id: "step\(i)", title: L10n("Step \(i + 1): \(label?.en ?? "?")", "Шаг \(i + 1): \(label?.ru ?? "?")"), weight: 1)
        }
    }

    /// Chains show up for whatever their first step accepts; they are not Studio targets.
    override func appliesTo(_ items: [FileItem]) -> Bool { first.appliesInStudio(items) }
    override func appliesInStudio(_ items: [FileItem]) -> Bool { false }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        for (i, step) in chain.steps.enumerated() {
            guard let op = AutomationRun.operation(for: step, registry: registry) else {
                return .unavailable(reason: L10n("Step \(i + 1) of this chain no longer exists.", "Шага \(i + 1) этой цепочки больше не существует."), missing: [])
            }
            let a = op.availability(for: i == 0 ? items : [], tools: tools)
            if !a.isAvailable { return a }
        }
        return .available
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        guard !chain.steps.isEmpty else { throw ConversionError.message(L10n("The chain has no steps.", "В цепочке нет шагов.")) }
        // Every original travels through the chain on its own (so the last step knows where ITS result belongs), except when the first step needs all of them
        // together (merge).
        let originals: [[FileItem]] = first.meta.minItems > 1 ? [items] : items.map { [$0] }
        var lineage: [[FileItem]?] = originals
        var result = OperationResult()
        var failures: [String] = []
        let count = chain.steps.count
        var previousStepDir: URL?
        for (i, step) in chain.steps.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            let stageID = "step\(i)"
            ctx.beginStage(stageID)
            guard let op = AutomationRun.operation(for: step, registry: registry) else {
                throw Self.stepError(i, count, name: step.operationID, L10n("this step no longer exists", "этого шага больше нет"))
            }
            let label = op.meta.label
            let isLast = i == count - 1
            let stepDir = ctx.tempDir.appendingPathComponent("step\(i)", isDirectory: true)
            let overrides = AutomationRun.overrides(for: op, recipe: step, settings: ctx.settings)
            let live = lineage.indices.filter { lineage[$0] != nil }
            for (n, k) in live.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                guard let current = lineage[k] else { continue }
                do {
                    guard op.appliesInStudio(current) else {
                        let kinds = current.kinds.map { $0.title.text }.sorted().joined(separator: ", ")
                        throw StepFailure(reason: L10n("it cannot process \(kinds) (the output of the previous step)", "он не умеет обрабатывать: \(kinds) (результат предыдущего шага)"))
                    }
                    var rules = isLast ? finalRules(ctx.outputRules) : Self.intermediateRules(ctx.outputRules, folder: stepDir.appendingPathComponent("g\(k)", isDirectory: true))
                    if isLast {
                        // Next to the ORIGINAL, never next to an intermediate in the temp folder.
                        rules.customDir = try OutputPaths.outputDirectory(for: originals[k][0], rules: ctx.outputRules).path
                        rules.dirMode = .custom
                    }
                    let total = max(live.count, 1), index = n
                    let r = try await ctx.runNestedMapped(op, items: current, overrides: overrides, outputRules: rules, mode: .studio) { (Double(index) + $0) / Double(total) }
                    guard !r.outputs.isEmpty else { throw StepFailure(reason: L10n("it produced no files", "он не создал файлов")) }
                    result.failures += r.failures.map { "\(label.text): \($0)" }
                    result.warnings += r.warnings
                    lineage[k] = r.outputs.map { FileItem(url: $0) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = (error as? StepFailure)?.reason ?? L10n(ConversionError.describe(error))
                    let wrapped = Self.stepError(i, count, name: label.text, reason)
                    let message = ConversionError.describe(wrapped)
                    if originals.count == 1 { throw wrapped }
                    failures.append("\(originals[k].summaryTitle): \(message)")
                    lineage[k] = nil
                }
            }
            ctx.finishStage(stageID)
            // The intermediate files of the step before are not needed any more: a long video chain must not hold every stage on disk.
            if let prev = previousStepDir { AppPaths.removeTemp(prev) }
            previousStepDir = isLast ? nil : stepDir
        }
        result.outputs = lineage.compactMap { $0 }.flatMap { $0.map(\.url) }
        if result.outputs.isEmpty && !failures.isEmpty { throw ConversionError.aggregate(failures) }
        result.failures += failures
        return result
    }

    // MARK: Output rules

    /// Intermediates: a private folder, the plain name of the input (no tool suffix: the trailing space keeps the template from being the default one, and is trimmed), original dates kept.
    static func intermediateRules(_ base: OutputRules, folder: URL) -> OutputRules {
        var r = base
        r.dirMode = .custom
        r.customDir = folder.path
        r.nameTemplate = "{name} "
        r.collision = .number
        r.trashSource = false
        r.after = .nothing
        return r
    }

    /// The last step writes where the job's rules say; with the default name template the file is named "{name} (chain name)".
    private func finalRules(_ base: OutputRules) -> OutputRules {
        var r = base
        r.trashSource = false
        if r.nameTemplate == "{name}" { r.nameTemplate = "{name} (\(AutomationRun.literalName(Util.safeSuffix(chain.name))))" }
        return r
    }

    private struct StepFailure: Error { var reason: L10n }

    static func stepError(_ index: Int, _ count: Int, name: String, _ reason: L10n) -> ConversionError {
        .message(L10n("Step \(index + 1) of \(count) (\(name)) stopped the chain: \(reason.en)", "Шаг \(index + 1) из \(count) («\(name)») остановил цепочку: \(reason.ru)"))
    }
}

enum ChainProvider {
    private static let cache = Locked<(revision: Int, operations: [Operation])?>(nil)
    private static let buildingKey = "app.swampconverter.automation.chains.building"

    /// Registers a registry provider exposing `PresetStore.shared.chains` that have a wheel as operations. Called from `MultiOutputRegistry.install()` side by side with presets.
    @MainActor static func install() {
        OperationRegistry.shared.registerProvider(id: "chains") { _ in operations() }
    }

    /// The wheel operations of the stored chains, rebuilt only when the preset store changed. A chain whose steps are themselves presets would ask the registry for
    /// them while the registry is asking for the chains: the thread-local flag turns that second round into an empty answer instead of an endless loop.
    static func operations(store: PresetStore = .shared, registry: OperationRegistry = .shared) -> [Operation] {
        let dict = Thread.current.threadDictionary
        if dict[buildingKey] != nil { return [] }
        let revision = store.revision
        if store === PresetStore.shared, registry === OperationRegistry.shared, let c = cache.value, c.revision == revision { return c.operations }
        dict[buildingKey] = true
        defer { dict.removeObject(forKey: buildingKey) }
        let ops: [Operation] = store.chains.filter { $0.wheel != nil }.compactMap { ChainOperation(chain: $0, registry: registry) }
        if store === PresetStore.shared, registry === OperationRegistry.shared { cache.value = (revision, ops) }
        return ops
    }
}
