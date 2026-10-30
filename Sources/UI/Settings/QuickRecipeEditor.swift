import SwiftUI

/// The model behind the quick-recipe editor: one operation, the complete option values its quick path uses, and edits that are stored as the SPARSE difference from the
/// built-in recipe (`QuickRecipes.save`), so a later change of a default still reaches everything the person did not touch.
@MainActor
final class QuickRecipeModel: ObservableObject {
    struct EditorSection: Identifiable {
        var id: String
        var title: L10n?
        var fields: [OptionField]
        var page: OptionPage
        var group: OptionGroup
    }

    let registry: OperationRegistry
    private let settings: AppSettings
    @Published private(set) var operation: Operation?
    @Published private(set) var values = OptionValues()
    @Published private(set) var baseline = OptionValues()
    private var schema: OptionSchema?

    init(registry: OperationRegistry = .shared, settings: AppSettings = .shared) {
        self.registry = registry; self.settings = settings
    }

    func select(operationID: String?) {
        guard let id = operationID, let op = registry.operation(id: id) else { operation = nil; schema = nil; values = OptionValues(); baseline = OptionValues(); return }
        let schema = op.optionSchema(for: [])
        self.operation = op
        self.schema = schema
        baseline = schema.defaults().overlaying(op.quickOverrides(settings: settings.data))
        reload()
    }

    private func reload() {
        guard let op = operation else { return }
        values = QuickRecipes.resolve(op, items: [], settings: settings.data, mode: .studio).values
    }

    /// The edited fields of the page/group structure, expert fields and track tables left out, hidden fields dropped.
    func sections() -> [EditorSection] {
        guard let schema, operation != nil else { return [] }
        let env = ExprEnvironment(values: values, source: nil)
        var out: [EditorSection] = []
        for page in schema.pages {
            if let w = page.visibleWhen, !w.evaluate(env) { continue }
            for group in page.groups where group.level <= .standard {
                if let w = group.visibleWhen, !w.evaluate(env) { continue }
                let fields = group.fields.filter { f in
                    if f.level > .standard { return false }
                    if case .tracks = f.kind { return false }
                    return OptionFormLogic.state(of: f, group: group, page: page, env: env).visible
                }
                if !fields.isEmpty { out.append(EditorSection(id: page.id + "." + group.id, title: group.title ?? (schema.pages.count > 1 ? page.title : nil), fields: fields, page: page, group: group)) }
            }
        }
        return out
    }

    func state(of field: OptionField, in section: EditorSection) -> OptionFormLogic.FieldState {
        OptionFormLogic.state(of: field, group: section.group, page: section.page, env: ExprEnvironment(values: values, source: nil))
    }

    var environment: ExprEnvironment { ExprEnvironment(values: values, source: nil) }

    func isDefault(_ key: String) -> Bool {
        guard let v = values[key], let b = baseline[key] else { return true }
        return v == b || OptionValues([key: v]).diff(against: OptionValues([key: b])).isEmpty
    }

    /// True when the person changed anything from the built-in recipe.
    var isEdited: Bool { operation.map { settings.data.quickRecipes[$0.meta.id]?.isEmpty == false } ?? false }

    /// Fields the quick path asks about every time it runs (`OperationMeta.quickPromptKeys`).
    var askedKeys: Set<String> { Set(operation?.meta.quickPromptKeys ?? []) }

    func set(_ key: String, _ value: OptionValue) {
        guard let op = operation else { return }
        values[key] = value
        QuickRecipes.save(values, for: op)
        reload()
    }

    func revert(_ key: String) {
        guard let base = baseline[key] else { return }
        set(key, base)
    }

    func resetAll() {
        guard let op = operation else { return }
        QuickRecipes.reset(op)
        reload()
    }
}

/// Settings > Recipes: edit what a quick run of one operation does, with the same field controls the Studio uses.
struct QuickRecipeEditor: View {
    @StateObject private var model: QuickRecipeModel
    @ObservedObject private var settings: AppSettings
    @State private var choice: String = ""
    private let groups: [FolderRuleLogic.Group]

    /// `initial` = an operation id to show at once (snapshots).
    init(settings: AppSettings = .shared, registry: OperationRegistry = .shared, initial: String? = nil) {
        _model = StateObject(wrappedValue: QuickRecipeModel(registry: registry, settings: settings))
        _settings = ObservedObject(wrappedValue: settings)
        _choice = State(initialValue: initial.map { "op:" + $0 } ?? "")
        groups = FolderRuleLogic.operationGroups(registry: registry)
    }

    var body: some View {
        FormSection(L("Quick recipe of an operation", "Быстрый рецепт операции"), symbol: "slider.horizontal.3",
                    footer: L("The quick recipe is what the wheel, Services and watched folders do without asking. Only your changes are stored, so everything you leave alone keeps following the app’s defaults.",
                              "Быстрый рецепт - это то, что колесо, Службы и отслеживаемые папки делают без вопросов. Сохраняются только ваши изменения, поэтому всё остальное продолжает следовать значениям по умолчанию.")) {
            SettingsRow(L("Operation", "Операция")) {
                Picker(L("Operation", "Операция"), selection: $choice) {
                    Text(L("Choose an operation", "Выберите операцию")).tag("")
                    ForEach(groups) { g in Section(g.title) { ForEach(g.items) { Text($0.label).tag($0.tag) } } }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .onChange(of: choice) { _, new in model.select(operationID: new.hasPrefix("op:") ? String(new.dropFirst(3)) : nil) }
                .onAppear { if choice.hasPrefix("op:"), model.operation == nil { model.select(operationID: String(choice.dropFirst(3))) } }
            }
            .settingsKey("quickRecipes")
            if model.operation != nil {
                let sections = model.sections()
                if sections.isEmpty {
                    FormFootnote(L("This operation has no options to set.", "У этой операции нет параметров."))
                }
                ForEach(sections) { section in
                    if let title = section.title { Text(title.text).font(DS.Typo.headline).padding(.top, DS.Space.xs) }
                    ForEach(section.fields, id: \.key) { field in fieldRow(field, in: section) }
                }
                SettingsRow(L("Back to the built-in recipe", "Вернуть встроенный рецепт")) {
                    Button(L("Reset", "Сбросить")) { model.resetAll() }.disabled(!model.isEdited)
                }
            }
        }
    }

    private func fieldRow(_ field: OptionField, in section: QuickRecipeModel.EditorSection) -> some View {
        let st = model.state(of: field, in: section)
        let ctx = OptionFieldContext(isEnabled: st.enabled, disabledReason: st.reason, isDefault: model.isDefault(field.key), source: nil,
                                     defaultValue: model.baseline[field.key], optionEnvironment: model.environment, isLocked: false)
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            OptionFieldView(field: field, value: Binding(get: { model.values[field.key] ?? field.defaultOptionValue }, set: { model.set(field.key, $0) }),
                            context: ctx, onRevert: { model.revert(field.key) })
                .disabled(!st.enabled)
            if model.askedKeys.contains(field.key) {
                FormFootnote(L("Also asked each time this operation runs from the wheel.", "Также спрашивается при каждом запуске этой операции с колеса."))
            }
        }
    }
}
