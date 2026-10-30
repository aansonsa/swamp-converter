import Foundation

// A Recipe is "what to do and how": an operation id + SPARSE option overrides + optional output rules.
// Everything that used to be a bare operation id is a Recipe: watched folders, repeat-last, presets, chains.
// Quick path:  recipe = Recipe(operationID: op.id) (no overrides) -> options = schema defaults + op quick overrides + user quick edits
// Studio path: recipe = Recipe(operationID:, values: whatever the user changed)
//
// Resolution (see QuickRecipes.resolve): defaults(source) <- op.quickOverrides(settings) <- settings.quickRecipes[op.id] <- preset values <- recipe.values

struct Recipe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Any operation of the target; the engine reads options, not the id (see Operation.schemaID).
    var operationID: String
    /// Sparse overrides on top of the operation's quick recipe.
    var values: OptionValues = OptionValues()
    /// Preset the values came from (Studio shows "Modified" when `values` diverge from it).
    var presetID: String? = nil
    /// Per-recipe output rules; nil = the global rules from settings.
    var output: OutputRules? = nil
    var name: String? = nil

    init(operationID: String, values: OptionValues = OptionValues(), presetID: String? = nil, output: OutputRules? = nil, name: String? = nil) {
        self.operationID = operationID; self.values = values; self.presetID = presetID; self.output = output; self.name = name
    }
}

/// A sequence of recipes run one after another; each step receives the outputs of the previous one.
/// Owned by the automation module (ChainRunner); stored by PresetStore.
struct RecipeChain: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString.prefix(10).lowercased()
    var name: String
    var symbol: String = "link"
    var steps: [Recipe]
    /// Where the chain appears on the wheel (nil = only available from Studio / watched folders).
    var wheel: WheelKind? = .tools
}

enum QuickRecipes {
    /// The complete option set a wheel / Services / watched-folder run uses for `op` on `items`.
    /// `mode` .studio skips the global "always strip metadata" layer (Studio shows the real field and the user decides).
    static func resolve(_ op: Operation, items: [FileItem], source: SourceInfo? = nil,
                        settings: SettingsData = AppSettings.shared.data, extra: [OptionValues] = [], mode: RunMode = .quick) -> ResolvedOptions {
        let schema = op.optionSchema(for: items)
        var layers: [OptionValues] = [op.quickOverrides(settings: settings), settings.quickRecipes[op.meta.id] ?? OptionValues()]
        if settings.alwaysStripMetadata && mode != .studio { layers.append(op.privacyOverrides()) }
        return schema.resolve(layers: layers + extra, source: source)
    }

    /// The editable quick recipe of an operation: user edits on top of its built-in overrides (what Settings > Quick Recipes shows).
    static func current(for op: Operation, settings: SettingsData = AppSettings.shared.data) -> OptionValues {
        op.quickOverrides(settings: settings).overlaying(settings.quickRecipes[op.meta.id] ?? OptionValues())
    }

    /// Stores the user's edited quick recipe (sparse against the built-in overrides).
    static func save(_ values: OptionValues, for op: Operation) {
        AppSettings.shared.update { s in
            let base = op.quickOverrides(settings: s)
            let sparse = values.sparse(against: op.optionSchema(for: []).defaults().overlaying(base))
            if sparse.isEmpty { s.quickRecipes[op.meta.id] = nil } else { s.quickRecipes[op.meta.id] = sparse }
        }
    }

    static func reset(_ op: Operation) {
        AppSettings.shared.update { $0.quickRecipes[op.meta.id] = nil }
    }
}
