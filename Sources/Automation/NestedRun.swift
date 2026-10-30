import Foundation

// Helpers shared by chains and multi-output packs: they run other operations INSIDE their own job (one card, one progress bar, one cancel).

extension OperationContext {
    /// Like `runNested`, but the progress of the nested run is mapped into a slice of the current stage (`map`), and invalid options stop the step with their message
    /// instead of running with half-valid values. Pause, cancel and the process set are shared with the parent exactly as `runNested` does.
    @discardableResult
    func runNestedMapped(_ op: Operation, items: [FileItem], overrides: OptionValues = OptionValues(), outputRules: OutputRules? = nil,
                         mode: RunMode? = nil, map: @escaping @Sendable (Double) -> Double = { $0 }) async throws -> OperationResult {
        try checkCancelled()
        let runMode = mode ?? self.mode
        let resolved = QuickRecipes.resolve(op, items: items, source: nil, settings: settings, extra: [overrides], mode: runMode)
        if resolved.hasErrors, let first = resolved.messages.first(where: { $0.severity == .error }) {
            throw ConversionError.message(first.text)
        }
        let child = OperationContext(jobID: jobID, operationID: op.meta.id, mode: runMode, resolved: resolved, outputRules: outputRules ?? self.outputRules,
                                     settings: settings, tools: tools, isBackground: isBackground, preferHardware: preferHardware, parent: self)
        child.onProgress = { [weak self] f, message, eta in self?.report(f.map(map), message: message, eta: eta) }
        child.onLog = { [weak self] line in self?.log(line) }
        child.onCurrentItem = onCurrentItem
        defer { child.cleanupTemp() }
        return try await op.execute(items: items, ctx: child)
    }
}

enum AutomationRun {
    /// The operation a recipe names: a concrete operation id, else the primary operation of a Studio target.
    static func operation(for recipe: Recipe, registry: OperationRegistry) -> Operation? {
        guard !recipe.operationID.isEmpty else { return nil }
        return registry.operation(id: recipe.operationID) ?? registry.primaryOperation(forTarget: recipe.operationID)
    }

    /// Option layers of one nested run: the recipe's values, and on top of them the global "always strip metadata" switch (nested runs use Studio semantics so that
    /// "already in this format" never skips a step, which also skips the layer Core adds for quick runs).
    static func overrides(for op: Operation, recipe: Recipe, settings: SettingsData) -> OptionValues {
        var values = recipe.values
        if settings.alwaysStripMetadata { values = values.overlaying(op.privacyOverrides()) }
        return values
    }

    /// Strips characters that would be read as template tokens or break a file name.
    static func literalName(_ s: String) -> String {
        Util.safeFileName(s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""), fallback: "output")
    }
}
