import SwiftUI

/// Settings > Folders: the watched folders (add, edit, turn off, remove, process what is already there) and the one-click templates. Everything is OFF until the person turns
/// it on. `WatchFolderService` follows `settings.watchRules` by itself; this page only edits the rules and shows the service's status.
struct FoldersPage: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var service: WatchFolderService

    @State private var editing: WatchRule?
    @State private var editingIsNew = false
    @State private var confirming: WatchTemplate?
    @State private var runNowRule: WatchRule?
    @State private var note: String?

    init(settings: AppSettings = .shared, service: WatchFolderService? = nil) {
        _settings = ObservedObject(wrappedValue: settings)
        _service = ObservedObject(wrappedValue: service ?? .shared)
    }

    private var rules: [WatchRule] { settings.data.watchRules }

    var body: some View {
        Form {
            rulesSection
            templatesSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            FolderRuleEditor(draft: rule, isNew: editingIsNew, existing: rules, onSave: { save($0) }, onCancel: { editing = nil })
        }
        .sheet(item: Binding(get: { confirming.map { TemplateBox(template: $0) } }, set: { confirming = $0?.template })) { box in
            FolderTemplateSheet(template: box.template, onConfirm: { folder, recipe in enable(box.template, folder: folder, recipe: recipe) }, onCancel: { confirming = nil })
        }
        .confirmationDialog(L("Process the files that are already in this folder?", "Обработать файлы, которые уже лежат в этой папке?"),
                            isPresented: Binding(get: { runNowRule != nil }, set: { if !$0 { runNowRule = nil } }), titleVisibility: .visible, presenting: runNowRule) { rule in
            Button(L("Process Them Now", "Обработать сейчас")) { Task { await service.runNow(rule: rule) } }
            Button(L("Cancel", "Отмена"), role: .cancel) {}
        } message: { rule in
            Text(L("The action “\(FolderRuleLogic.describe(rule.recipe))” is applied to every file in the folder. Originals are not deleted.",
                   "Действие «\(FolderRuleLogic.describe(rule.recipe))» будет применено ко всем файлам в папке. Оригиналы не удаляются."))
        }
        .appRoot()
    }

    // MARK: Rules

    private var rulesSection: some View {
        FormSection(L("Watched folders", "Отслеживаемые папки"), symbol: "folder.badge.gearshape",
                    footer: L("A watched folder converts new files automatically, in the background. Nothing is watched until you add a folder. The wheel’s “Pause” switch pauses watched folders too. Results are never processed again.",
                              "Отслеживаемая папка автоматически конвертирует новые файлы в фоне. Пока вы не добавили папку, ничего не отслеживается. Переключатель «Пауза» на странице колеса приостанавливает и папки. Результаты повторно не обрабатываются.")) {
            if rules.isEmpty {
                EmptyStateView(symbol: "folder.badge.questionmark", title: L("No watched folders", "Нет отслеживаемых папок"),
                               message: L("Add a folder, or turn on one of the ready-made rules below.", "Добавьте папку или включите одно из готовых правил ниже."))
                    .frame(height: 150)
            }
            ForEach(rules) { rule in ruleRow(rule) }
            if let note { InlineMessage(note, tone: .info, onDismiss: { self.note = nil }) }
            SettingsRow(L("Add a folder", "Добавить папку")) {
                Button(L("Add Folder…", "Добавить папку…")) { startNew() }
            }
            .settingsKey("watchRules")
        }
    }

    private func ruleRow(_ rule: WatchRule) -> some View {
        let status = service.statuses[rule.id] ?? WatchFolderService.initialStatus(of: rule, paused: service.isPaused)
        return HStack(alignment: .center, spacing: DS.Space.md) {
            Toggle(L("On", "Вкл."), isOn: Binding(get: { rule.enabled }, set: { setEnabled(rule.id, $0) })).labelsHidden().toggleStyle(.switch)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text((rule.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    if let tid = rule.templateID, let t = WatchTemplates.template(id: tid) {
                        Text(t.title.text).font(DS.Typo.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text(FolderRuleLogic.describe(rule.recipe) + (rule.includeSubfolders ? L(", with subfolders", ", с вложенными папками") : ""))
                    .font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: DS.Space.xs) {
                    StatusDot(FolderRuleLogic.statusKind(status), size: 10)
                    Text(FolderRuleLogic.statusText(status).text).font(DS.Typo.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Space.sm)
            Menu {
                Button(L("Edit…", "Изменить…")) { editingIsNew = false; editing = rule }
                Button(L("Process Files Already in the Folder…", "Обработать файлы, уже лежащие в папке…")) { runNowRule = rule }
                Button(L("Show in Finder", "Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rule.path)]) }
                Divider()
                Button(L("Remove", "Удалить"), role: .destructive) { remove(rule.id) }
            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text(L("Actions for this folder", "Действия для этой папки"))) }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .accessibilityElement(children: .contain)
    }

    private func startNew() {
        editingIsNew = true
        editing = WatchRule(path: "", recipe: Recipe(operationID: ""))
    }

    private func save(_ rule: WatchRule) {
        settings.update { s in
            if let i = s.watchRules.firstIndex(where: { $0.id == rule.id }) { s.watchRules[i] = rule } else { s.watchRules.append(rule) }
        }
        editing = nil
    }

    private func setEnabled(_ id: UUID, _ on: Bool) {
        settings.update { s in if let i = s.watchRules.firstIndex(where: { $0.id == id }) { s.watchRules[i].enabled = on } }
    }

    private func remove(_ id: UUID) {
        settings.update { $0.watchRules.removeAll { $0.id == id } }
    }

    // MARK: Templates

    private struct TemplateBox: Identifiable { var template: WatchTemplate; var id: String { template.id } }

    private var templatesSection: some View {
        FormSection(L("Ready-made rules", "Готовые правила"), symbol: "wand.and.stars",
                    footer: L("All of them are off. Each one watches a single folder, only reacts to the files it describes, and never touches its own results.",
                              "Все они выключены. Каждое следит за одной папкой, реагирует только на описанные файлы и не трогает собственные результаты.")) {
            ForEach(WatchTemplates.all) { t in templateRow(t) }
        }
    }

    private func templateRow(_ t: WatchTemplate) -> some View {
        let on = WatchTemplates.isEnabled(templateID: t.id, settings: settings)
        let availability = t.needsRecipe ? OperationAvailability.available : WatchTemplates.availability(of: t)
        let blocked = !availability.isAvailable && !on
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            SettingsRow(t.title.text, help: t.detail.text, symbol: t.symbol) {
                if t.id == WatchTemplates.dropFolder {
                    Button(on ? L("Add Another…", "Добавить ещё…") : L("Set Up…", "Настроить…")) { confirming = t }
                    if on { Button(L("Turn Off", "Выключить")) { WatchTemplates.disable(templateID: t.id, settings: settings) } }
                } else {
                    Toggle(t.title.text, isOn: Binding(get: { on }, set: { toggle(t, $0) })).labelsHidden().toggleStyle(.switch).disabled(blocked)
                }
            }
            if blocked, let reason = availability.reason { FormFootnote(reason.text) }
        }
    }

    private func toggle(_ t: WatchTemplate, _ on: Bool) {
        if on { confirming = t } else { WatchTemplates.disable(templateID: t.id, settings: settings) }
    }

    private func enable(_ template: WatchTemplate, folder: URL, recipe: Recipe?) {
        var t = template
        if template.needsRecipe, let recipe, let bound = WatchTemplates.dropFolder(boundTo: recipe) { t = bound }
        if WatchTemplates.enable(t, folder: folder, settings: settings) == nil {
            note = L("That rule is already on, or its folder could not be created.", "Это правило уже включено, либо не удалось создать его папку.")
        }
        confirming = nil
    }
}
