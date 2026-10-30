import SwiftUI

/// The whole inspector: summary capsule (sticky, from `SummaryCapsule`), Simple / Advanced control, search field (Cmd-F; matches label, help, key, aliases in both languages and
/// reveals the field), page switcher (icon tabs; labels in the title area), `Form { }.formStyle(.grouped)` of the selected page with disclosure groups (<= 6 visible fields per group in
/// Simple), "Show changes" list. Which fields are shown, collapsed or counted as hidden is decided by `OptionFormLogic` (pure, tested); the session holds the values.
struct OptionFormView: View {
    @ObservedObject var session: StudioSession
    @FocusState private var searchFocused: Bool
    /// Groups whose "Show N more" was pressed.
    @State private var overflowOpen: Set<String> = []
    /// The person's own expand / collapse choices (key = page/group).
    @State private var groupOpen: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(shortcuts)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SummaryCapsule(session: session)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.sm) { densityPicker.fixedSize(); searchField.frame(minWidth: 150) }
                VStack(alignment: .leading, spacing: DS.Space.sm) { densityPicker; searchField }
            }
            if !isSearching, let schema = session.schema {
                pageSwitcher(schema)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private var densityPicker: some View {
        Picker(L("Detail", "Подробность"), selection: $session.density) {
            Text(L("Simple", "Простой")).tag(DensitySetting.simple)
            Text(L("Advanced", "Расширенный")).tag(DensitySetting.advanced)
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel(Text(L("Detail level", "Уровень подробности")))
    }

    private var isSearching: Bool { !session.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var searchField: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("Search options", "Поиск параметров"), text: $session.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { session.searchText = ""; searchFocused = false }
                .accessibilityLabel(Text(L("Search options", "Поиск параметров")))
            if isSearching {
                Button { session.searchText = "" } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(Text(L("Clear search", "Очистить поиск")))
            }
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, 5)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func pageSwitcher(_ schema: OptionSchema) -> some View {
        let pages = OptionFormLogic.visiblePages(schema, env: session.formEnvironment)
        let current = pages.first { $0.id == session.selectedPageID } ?? pages.first
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            if pages.count > 1 {
                Picker(L("Page", "Страница"), selection: Binding(get: { current?.id ?? "" }, set: { session.selectedPageID = $0 })) {
                    ForEach(pages, id: \.id) { p in
                        Image(systemName: p.symbol).tag(p.id).accessibilityLabel(Text(p.title.text)).help(p.title.text)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            }
            if let current {
                Text(current.title.text).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// Cmd-F focuses the search field. (The window's menu command calls `session.focusSearch()`.)
    private var shortcuts: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: session.searchFocusToken) { _, _ in searchFocused = true }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let schema = session.schema {
            if isSearching { searchForm(schema) }
            else if let page = OptionFormLogic.visiblePages(schema, env: session.formEnvironment).first(where: { $0.id == session.selectedPageID })
                        ?? OptionFormLogic.visiblePages(schema, env: session.formEnvironment).first {
                pageForm(page)
            } else { empty }
        } else {
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableView(L("No options yet", "Параметров пока нет"), systemImage: "slider.horizontal.3",
                               description: Text(L("Choose a format to see its settings.", "Выберите формат, чтобы увидеть его настройки.")))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pageForm(_ page: OptionPage) -> some View {
        let env = session.formEnvironment
        let layout = OptionFormLogic.layout(page: page, density: session.density, showExpert: session.showExpert, env: env, expandedOverflow: overflowOpen)
        return Form {
            if let reason = Capabilities.shared.missingReason(page.requires) {
                Section { OptionMessageRow(reason.text, severity: .info) }
            }
            ForEach(layout.groups) { gl in groupSection(gl, page: page) }
            if layout.advancedHidden > 0 && session.density == .simple {
                Section {
                    Button { session.density = .advanced } label: {
                        Label(L("\(layout.advancedHidden) More in Advanced", "Ещё параметров в расширенном режиме: \(layout.advancedHidden)"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain).foregroundStyle(Brand.blueInk)
                }
            }
            if layout.expertHidden > 0 || session.showExpert, session.density == .advanced {
                Section {
                    Toggle(isOn: $session.showExpert) {
                        Text(session.showExpert ? L("Showing expert options", "Показаны экспертные параметры")
                                                : L("Show expert options (\(layout.expertHidden))", "Показать экспертные параметры (\(layout.expertHidden))"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func groupSection(_ gl: OptionFormLogic.GroupLayout, page: OptionPage) -> some View {
        if let title = gl.group.title {
            Section(isExpanded: openBinding(page: page, gl: gl)) {
                rows(gl, page: page)
            } header: {
                Text(title.text).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Section { rows(gl, page: page) }
        }
    }

    @ViewBuilder private func rows(_ gl: OptionFormLogic.GroupLayout, page: OptionPage) -> some View {
        ForEach(gl.fields, id: \.key) { f in fieldRow(f, group: gl.group, page: page) }
        if gl.overflow > 0 {
            Button { overflowOpen.insert(gl.id) } label: {
                Label(L("Show \(gl.overflow) More", "Показать ещё: \(gl.overflow)"), systemImage: "chevron.down")
            }
            .buttonStyle(.plain).foregroundStyle(Brand.blueInk)
        }
        if let footer = gl.group.footer { OptionFootnote(footer.text) }
    }

    private func fieldRow(_ f: OptionField, group: OptionGroup, page: OptionPage) -> some View {
        OptionFieldView(field: f, value: session.binding(for: f), context: session.context(for: f, group: group, page: page),
                        onRevert: { session.revert(key: f.key) },
                        onFix: { session.applyFix($0) },
                        onEditingChanged: { editing in if editing { session.beginEditing(key: f.key) } else { session.endEditing(key: f.key) } })
    }

    private func openBinding(page: OptionPage, gl: OptionFormLogic.GroupLayout) -> Binding<Bool> {
        let key = page.id + "/" + gl.group.id
        return Binding(get: { groupOpen[key] ?? !gl.collapsedByDefault }, set: { groupOpen[key] = $0 })
    }

    // MARK: Search

    private func searchForm(_ schema: OptionSchema) -> some View {
        let result = OptionFormLogic.search(schema, query: session.searchText, env: session.formEnvironment, density: session.density, showExpert: session.showExpert)
        return Form {
            if result.hitCount == 0 {
                Section {
                    Text(L("Nothing found. Try another word, for example “quality” or “bitrate”.", "Ничего не найдено. Попробуйте другое слово, например «качество» или «битрейт»."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if result.includesExpert {
                Section { OptionMessageRow(L("Searching also in expert options.", "Поиск идёт и по экспертным параметрам."), severity: .info) }
            }
            ForEach(result.sections) { sec in
                Section {
                    ForEach(sec.fields, id: \.key) { f in fieldRow(f, group: sec.group, page: sec.page) }
                } header: {
                    Button { reveal(sec) } label: { Text(sec.title).fixedSize(horizontal: false, vertical: true) }
                        .buttonStyle(.plain)
                        .help(L("Show in the page", "Показать на странице"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func reveal(_ sec: OptionFormLogic.SearchSection) {
        if sec.fields.contains(where: { $0.level == .expert }) || sec.group.level == .expert { session.density = .advanced; session.showExpert = true }
        else if sec.fields.contains(where: { $0.level == .standard }) || sec.group.level == .standard { session.density = .advanced }
        groupOpen[sec.page.id + "/" + sec.group.id] = true
        overflowOpen.insert(sec.group.id)
        session.selectedPageID = sec.page.id
        session.searchText = ""
    }
}
