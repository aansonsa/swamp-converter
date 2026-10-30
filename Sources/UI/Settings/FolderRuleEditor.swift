import SwiftUI

/// The sheet that creates or edits one watched-folder rule: the folder, what happens to new files (an operation or a preset), whether subfolders count, an optional output folder.
struct FolderRuleEditor: View {
    @State var draft: WatchRule
    var isNew: Bool
    var existing: [WatchRule]
    var onSave: (WatchRule) -> Void
    var onCancel: () -> Void

    @State private var showProblem = false
    private let operationGroups = FolderRuleLogic.operationGroups()
    private let presetGroups = FolderRuleLogic.presetGroups()

    private var tagBinding: Binding<String> {
        Binding(get: { FolderRuleLogic.tag(for: draft.recipe) },
                set: { if let r = FolderRuleLogic.recipe(forTag: $0, keeping: draft.recipe) { draft.recipe = r } })
    }

    private var problem: L10n? { FolderRuleLogic.problem(with: draft, existing: existing) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                FormSection(footer: L("New files that appear in this folder are processed in the background, one at a time as they finish arriving. The files that are already there are left alone.",
                                      "Новые файлы, появляющиеся в этой папке, обрабатываются в фоне, как только полностью скопируются. Файлы, которые уже лежат в папке, не затрагиваются.")) {
                    SettingsFolderRow(title: L("Folder to watch", "Отслеживаемая папка"), help: nil, symbol: "folder", placeholder: L("No folder chosen", "Папка не выбрана"),
                                      path: Binding(get: { draft.path.isEmpty ? nil : draft.path }, set: { draft.path = $0 ?? "" }), allowsClear: false)
                    SettingsRow(L("What to do with new files", "Что делать с новыми файлами"), symbol: "wand.and.stars") {
                        Picker(L("What to do with new files", "Что делать с новыми файлами"), selection: tagBinding) {
                            ForEach(operationGroups) { g in
                                Section(g.title) { ForEach(g.items) { Text($0.label).tag($0.tag) } }
                            }
                            ForEach(presetGroups) { g in
                                Section(g.title) { ForEach(g.items) { Text($0.label).tag($0.tag) } }
                            }
                            if draft.recipe.operationID.isEmpty {
                                // A new rule has no action yet: say so instead of "an operation that is no longer available".
                                Text(L("Choose an action", "Выберите действие")).tag(tagBinding.wrappedValue)
                            } else if !allTags.contains(tagBinding.wrappedValue) {
                                Text(FolderRuleLogic.describe(draft.recipe)).tag(tagBinding.wrappedValue)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    SettingsToggleRow(L("Include subfolders", "Включая вложенные папки"), isOn: $draft.includeSubfolders)
                    SettingsFolderRow(title: L("Put results in", "Куда класть результаты"), help: nil, symbol: nil,
                                      placeholder: L("Where results normally go (see General)", "Как обычно (см. «Основные»)"),
                                      path: Binding(get: { draft.outputDir }, set: { draft.outputDir = $0 }))
                    SettingsToggleRow(L("Turn this rule on", "Включить это правило"), isOn: $draft.enabled)
                }
                if showProblem, let p = problem { InlineMessage(p.text, tone: .warning) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена"), role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L("Add Folder", "Добавить папку") : L("Save", "Сохранить")) {
                    if problem == nil { onSave(draft) } else { showProblem = true }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 520, height: 470)
        .appRoot()
    }

    private var allTags: Set<String> {
        Set((operationGroups + presetGroups).flatMap { $0.items.map(\.tag) })
    }
}

/// The confirmation before a one-click template is switched on: what it does, which folder it watches (changeable), and for the drop folder which preset it applies.
struct FolderTemplateSheet: View {
    var template: WatchTemplate
    var onConfirm: (_ folder: URL, _ recipe: Recipe?) -> Void
    var onCancel: () -> Void

    @State private var folder: String?
    @State private var presetTag: String = ""
    private let presetGroups = FolderRuleLogic.presetGroups()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                SymbolIcon(template.symbol, size: 26, style: .secondary).frame(width: 34)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(template.title.text).font(DS.Typo.headline)
                    Text(template.detail.text).font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                SettingsFolderRow(title: L("Folder to watch", "Отслеживаемая папка"), help: nil, symbol: nil,
                                  placeholder: template.defaultFolder().path, path: $folder, allowsClear: true)
                if template.needsRecipe {
                    SettingsRow(L("Preset to apply", "Применяемый шаблон")) {
                        Picker(L("Preset to apply", "Применяемый шаблон"), selection: $presetTag) {
                            Text(L("Choose a preset", "Выберите шаблон")).tag("")
                            ForEach(presetGroups) { g in Section(g.title) { ForEach(g.items) { Text($0.label).tag($0.tag) } } }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Text(L("Nothing happens until files arrive. Files that are already in the folder are not touched. You can turn this off at any time.",
                   "Пока файлов нет, ничего не происходит. Файлы, которые уже лежат в папке, не затрагиваются. Выключить можно в любой момент."))
                .font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена"), role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(L("Turn On", "Включить")) {
                    let url = URL(fileURLWithPath: folder ?? template.defaultFolder().path, isDirectory: true)
                    onConfirm(url, template.needsRecipe ? FolderRuleLogic.recipe(forTag: presetTag) : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.needsRecipe && FolderRuleLogic.recipe(forTag: presetTag) == nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 500)
        .appRoot()
    }
}
