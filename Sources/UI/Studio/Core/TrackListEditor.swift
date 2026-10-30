import SwiftUI

/// Audio / subtitle / chapter row editor for `FieldKind.tracks`: add (from the probed streams or manually), remove, reorder by drag (or Move Up / Move Down for the keyboard
/// and VoiceOver), per-row columns rendered with `OptionFieldView`. A row's columns follow the schema; the conventions for filling a row from a probed stream are in
/// `TrackRows` (the index column gets the stream index, language and title columns are copied).
struct TrackListEditor: View {
    var field: OptionField
    var spec: TrackSpec
    @Binding var rows: [[String: OptionValue]]
    var source: SourceInfo?

    @State private var collapsed: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if rows.isEmpty {
                Text(L("No tracks. Add one below.", "Дорожек нет. Добавьте их ниже."))
                    .font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows.indices, id: \.self) { i in
                rowView(i)
                    .dropDestination(for: String.self) { items, _ in
                        guard let s = items.first, let from = Int(s), rows.indices.contains(from) else { return false }
                        rows = TrackRows.moved(rows, from: from, to: i)
                        return true
                    }
            }
            addControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Row

    private func rowView(_ i: Int) -> some View {
        let sum = TrackRows.summary(of: rows[i], spec: spec, index: i)
        let isOpen = !collapsed.contains(i)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                    .draggable(String(i)) { Text(sum.title).padding(DS.Space.sm) }
                Button { toggle(i) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(sum.title).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
                            if !isOpen && !sum.detail.isEmpty {
                                Text(sum.detail).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sum.title))
                .accessibilityValue(Text(isOpen ? L("expanded", "развёрнуто") : L("collapsed", "свёрнуто")))
                Button { rows = TrackRows.removed(rows, at: i) } label: { Image(systemName: "minus.circle").symbolRenderingMode(.hierarchical) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Remove Track", "Удалить дорожку"))
                    .accessibilityLabel(Text(L("Remove \(sum.title)", "Удалить: \(sum.title)")))
            }
            if isOpen {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(spec.columns, id: \.key) { col in
                        let env = rowEnvironment(i)
                        if col.visibleWhen?.evaluate(env) ?? true {
                            OptionFieldView(field: col, value: binding(i, col), context: columnContext(col, env: env), compact: true)
                        }
                    }
                }
                .padding(.leading, DS.Space.lg)
            }
        }
        .padding(DS.Space.md)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L("Move Up", "Переместить вверх"))) { rows = TrackRows.moved(rows, from: i, to: i - 1) }
        .accessibilityAction(named: Text(L("Move Down", "Переместить вниз"))) { rows = TrackRows.moved(rows, from: i, to: i + 1) }
        .contextMenu {
            Button(L("Move Up", "Переместить вверх")) { rows = TrackRows.moved(rows, from: i, to: i - 1) }.disabled(i == 0)
            Button(L("Move Down", "Переместить вниз")) { rows = TrackRows.moved(rows, from: i, to: i + 1) }.disabled(i == rows.count - 1)
            Divider()
            Button(L("Remove Track", "Удалить дорожку"), role: .destructive) { rows = TrackRows.removed(rows, at: i) }
        }
    }

    private func toggle(_ i: Int) {
        if collapsed.contains(i) { collapsed.remove(i) } else { collapsed.insert(i) }
    }

    private func rowEnvironment(_ i: Int) -> ExprEnvironment {
        ExprEnvironment(values: OptionValues(rows[safe: i] ?? [:]), source: source)
    }

    private func columnContext(_ col: OptionField, env: ExprEnvironment) -> OptionFieldContext {
        let st = OptionFormLogic.state(of: col, group: nil, page: nil, env: env)
        var ctx = OptionFieldContext()
        ctx.isEnabled = st.enabled
        ctx.disabledReason = st.reason
        ctx.source = source
        ctx.optionEnvironment = env
        return ctx
    }

    private func binding(_ i: Int, _ col: OptionField) -> Binding<OptionValue> {
        Binding(get: { rows[safe: i]?[col.key] ?? col.defaultValue.resolve(source) },
                set: { v in if rows.indices.contains(i) { rows[i][col.key] = v } })
    }

    // MARK: Add

    @ViewBuilder private var addControl: some View {
        let addable = TrackRows.addableStreams(field: field, spec: spec, rows: rows, source: source)
        let canAdd = TrackRows.canAdd(rows, spec: spec)
        if addable.isEmpty {
            Button { add(TrackRows.emptyRow(spec, source: source)) } label: { Label(spec.addTitle.text, systemImage: "plus") }
                .secondaryButtonLook().disabled(!canAdd)
        } else {
            Menu {
                Section(L("From the file", "Из файла")) {
                    ForEach(addable) { s in
                        Button(streamTitle(s)) { add(TrackRows.row(from: s, spec: spec, source: source)) }
                    }
                }
                Divider()
                Button(L("Empty Track", "Пустая дорожка")) { add(TrackRows.emptyRow(spec, source: source)) }
            } label: { Label(spec.addTitle.text, systemImage: "plus") }
            .menuStyle(.button).secondaryButtonLook().disabled(!canAdd)
        }
        if !canAdd, let m = spec.maxRows {
            Text(L("At most \(m) tracks.", "Не больше дорожек: \(m)."))
                .font(DS.Typo.caption).foregroundStyle(.secondary)
        }
    }

    private func add(_ row: [String: OptionValue]) {
        guard TrackRows.canAdd(rows, spec: spec) else { return }
        rows.append(row)
    }

    private func streamTitle(_ s: SourceStream) -> String {
        [s.title, s.detail, s.language].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
