import Foundation

// From session to engine: the recipe, the queue ("Add to Queue", "Start") and per-item edits of queued jobs. Part of StudioSession.
//
// THE RULE ("two speeds, one engine"): the recipe a session produces runs through `JobRunner` exactly like a wheel run. The job runner resolves
//     op.quickOverrides < settings.quickRecipes < job.overrides        (no source: it does not probe)
// so `recipe().values` must carry everything the person SEES that those layers would not reproduce: the preset's values, their own changes, and the
// source-dependent defaults of the probed file (a "nearest standard height" default, the audio rows of this file) as explicit values.

extension StudioSession {
    // MARK: Recipe

    /// The preset's values plus the person's changes, without the destination.
    func explicitValues() -> OptionValues {
        let user = OptionValues(values.storage.filter { !Self.isOutputKey($0.key) })
        return (currentPreset?.values ?? OptionValues()).overlaying(user)
    }

    /// Sparse overrides for running `source` (nil = the focused one): `explicitValues()` + the values of source-dependent defaults for that file when they differ from
    /// what the runner would compute without a probe.
    func recipeValues(for source: StudioSource?) -> OptionValues {
        var out = explicitValues()
        guard let schema, let op = operation, let info = (source ?? activeSource)?.info else { return out }
        let quick = QuickRecipes.current(for: op, settings: settings.data)
        let layers = [quick, out]
        let withSource = schema.resolve(layers: layers, source: info)
        let without = schema.resolve(layers: layers, source: nil)
        for c in withSource.values.diff(against: without.values) where out[c.key] == nil && withSource.isActive(c.key) && !Self.isOutputKey(c.key) {
            if let f = schema.field(c.key), case .computed = f.defaultValue, let v = c.new { out[c.key] = v }
        }
        return out
    }

    /// The complete recipe (operation id + sparse values + output rules + preset id) the wheel's engine would run.
    func recipe() -> Recipe {
        Recipe(operationID: operationID ?? targetID ?? "", values: recipeValues(for: activeSource), presetID: presetID, output: outputRulesOverride)
    }

    /// Loads a recipe's values, preset and output rules into the (already selected) target.
    func adopt(_ recipe: Recipe) {
        if let pid = recipe.presetID, let p = presetStore.preset(id: pid), p.targetID == targetID {
            presetID = pid
            lockedKeys = Set(p.locks)
        }
        values = OptionValues(recipe.values.storage.filter { schema?.field($0.key) != nil && !Self.isOutputKey($0.key) })
        if let out = recipe.output {
            syncingOutput = true; outputRules = out; syncingOutput = false
            mirrorOutputRulesIntoValues()
        }
        resetUndo()
        recompute()
    }

    // MARK: Running

    /// Why Start is unavailable, in plain words (nil when it is available).
    var startBlockReason: L10n? {
        guard let op = operation, schema != nil else { return L10n("Choose a format first.", "Сначала выберите формат.") }
        if !sources.contains(where: \.isUsable) { return L10n("Add a file or a link first.", "Сначала добавьте файл или ссылку.") }
        if case .unavailable(let reason, _) = availability { return reason }
        if !isLinkSession && activeFiles.count < op.meta.minItems {
            let n = op.meta.minItems
            return L10n("This needs at least \(n) files.", "Нужно не меньше файлов: \(n).")
        }
        if let e = messages.first(where: { $0.severity == .error }) { return e.text }
        return nil
    }

    var canStart: Bool { startBlockReason == nil }

    /// Adds one job per source (or one for batch operations) HELD in the queue ("Add to Queue"). Returns the jobs.
    @discardableResult func addToQueue() -> [Job] { submitJobs(held: true) }

    /// "Start": submits and runs immediately.
    @discardableResult func start() -> [Job] { submitJobs(held: false) }

    private func submitJobs(held: Bool) -> [Job] {
        guard canStart, let op = operation else { return [] }
        let batch = UUID()
        let rules = outputRulesOverride
        var jobs: [Job] = []
        if isLinkSession {
            for s in sources where s.isUsable {
                guard let link = s.input.link else { continue }
                jobs.append(runner.submit(operation: op, links: [link], overrides: recipeValues(for: s), origin: .studio, mode: .studio, outputRules: rules, held: held, batchID: batch))
            }
        } else if op is BatchOperation || op.meta.minItems > 1 {
            jobs.append(runner.submit(operation: op, items: activeFiles, overrides: recipeValues(for: activeSource), origin: .studio, mode: .studio, outputRules: rules, held: held, batchID: batch))
        } else {
            for s in sources where s.isUsable {
                guard let file = s.input.file else { continue }
                jobs.append(runner.submit(operation: op, items: [file], overrides: recipeValues(for: s), origin: .studio, mode: .studio, outputRules: rules, held: held, batchID: batch))
            }
        }
        return jobs
    }

    // MARK: Per-item edits

    /// Loads a queued job back into the session for per-item option edits ("Edit Options"): the job keeps its place; edits go through `JobRunner.updateOverrides`.
    func load(job: Job) {
        editingJob = nil
        editingJobLocked = false
        sources = Self.makeSources(files: job.items, links: job.links)
        focusedSourceID = nil
        normalizeStatuses()
        refreshTargets()
        guard let op = registry.operation(id: job.operationID) else { return }
        selectTarget(op.meta.schemaID, operationID: job.operationID, seedDefaultPreset: false)
        values = OptionValues(job.overrides.storage.filter { schema?.field($0.key) != nil && !Self.isOutputKey($0.key) })
        syncingOutput = true
        outputRules = OutputRules(options: job.overrides, base: job.outputRules ?? settings.data.output)
        syncingOutput = false
        mirrorOutputRulesIntoValues()
        resetUndo()
        recompute()
        editingJob = job
        editingJobLocked = job.state != .waiting
        startProbing()
    }

    /// Writes the session's options back to the queued job being edited (live, per item). A job that started meanwhile locks the session.
    func persistEditingJob() {
        guard let job = editingJob, !editingJobLocked else { return }
        if !runner.updateOverrides(job, recipeValues(for: activeSource), outputRules: outputRules) { editingJobLocked = true }
    }
}
