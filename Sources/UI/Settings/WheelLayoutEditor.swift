import SwiftUI

/// The wheel layout editor (spec/wheel.md 18.3 item 2): a wheel selector (Convert / Tools / Actions / Download), the kinds of files with their counts, a reorderable list
/// (drag a row onto another, or use the context menu / VoiceOver actions; star = favourite on the axes; switch = shown on the wheel; hidden rows are listed apart; rows beyond the
/// 7 + 8 slots are flagged "Studio only") next to a live preview of the first ring, "Reset this wheel for this kind" and "Reset all". Writes `WheelLayout`.
struct WheelLayoutEditor: View {
    @StateObject private var model: LayoutEditorModel
    @ObservedObject private var layout: WheelLayout
    @State private var confirmResetAll = false

    init(layout: WheelLayout = .shared, registry: OperationRegistry = .shared) {
        _model = StateObject(wrappedValue: LayoutEditorModel(layout: layout, registry: registry))
        _layout = ObservedObject(wrappedValue: layout)
    }

    /// For snapshots and tests: start on a given wheel and kind.
    init(model: LayoutEditorModel) {
        _model = StateObject(wrappedValue: model)
        _layout = ObservedObject(wrappedValue: model.layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            AdaptivePicker(L("Wheel", "Колесо"), selection: $model.wheel,
                           options: WheelKind.allCases.map { ($0, $0.title.text) })
            // Plain stacks, not Lists: a scrolling list inside the grouped Form swallowed the scroll wheel, so neither the list nor the page could be scrolled
            // to the last rows. Now the editor is as tall as its rows and the page scrolls as one.
            HStack(alignment: .top, spacing: DS.Space.md) {
                profileList.frame(width: 172)
                rowsList.frame(minWidth: 220, maxWidth: .infinity)
                previewColumn.frame(width: 208)
            }
            .frame(minHeight: 360, alignment: .top)
        }
        .padding(.vertical, DS.Space.xs)
        .confirmationDialog(L("Reset all wheel layouts?", "Сбросить раскладку всех колёс?"), isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button(L("Reset All", "Сбросить всё"), role: .destructive) { model.resetAll() }
            Button(L("Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("Order, hidden items and favorites go back to the defaults for every wheel and every kind of file.",
                   "Порядок, скрытые пункты и избранное вернутся к значениям по умолчанию для всех колёс и видов файлов."))
        }
    }

    // MARK: Kinds

    private var profileList: some View {
        VStack(spacing: 2) {
            ForEach(LayoutEditorModel.profiles(for: model.wheel), id: \.self) { p in
                let selected = model.profile == p
                Button { model.profile = p } label: {
                    HStack {
                        Text(p.title.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.xs)
                        Text("\(model.visibleCount(wheel: model.wheel, profile: p))")
                            .font(DS.Typo.numeric(.caption)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 5)
                    .background(selected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(p.title.text))
                .accessibilityValue(Text(L("\(model.visibleCount(wheel: model.wheel, profile: p)) on the wheel", "на колесе: \(model.visibleCount(wheel: model.wheel, profile: p))")))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(DS.Space.xs)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Kinds of files", "Виды файлов")))
    }

    // MARK: Rows

    private var rowsList: some View {
        let rows = model.rows()
        let shown = rows.filter { !$0.hidden }
        let hidden = rows.filter(\.hidden)
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(L("The wheel has nothing for this kind of file.", "Для этого вида файлов на колесе ничего нет.")).foregroundStyle(.secondary)
                    .padding(DS.Space.sm)
            }
            if !shown.isEmpty {
                sectionHeader(L("On the wheel", "На колесе"))
                ForEach(shown) { row in
                    rowView(row, canMove: true)
                        .draggable(row.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, id != row.id else { return false }
                            model.move(id: id, onto: row.id)
                            return true
                        }
                    if row.id != shown.last?.id { Divider().padding(.leading, 30) }
                }
            }
            if !hidden.isEmpty {
                sectionHeader(L("Hidden", "Скрытые"))
                ForEach(hidden) { row in
                    rowView(row, canMove: false)
                    if row.id != hidden.last?.id { Divider().padding(.leading, 30) }
                }
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.bottom, DS.Space.xs)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Operations of this wheel", "Операции этого колеса")))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(DS.Typo.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, DS.Space.sm).padding(.bottom, DS.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: LayoutRow, canMove: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            SymbolIcon(row.symbol, style: .secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.label.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let note = Self.note(for: row.slot) {
                    Text(note).font(DS.Typo.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Space.xs)
            if !row.hidden {
                Button { model.toggleFavorite(id: row.id) } label: {
                    Image(systemName: row.favorite ? "star.fill" : "star").foregroundStyle(row.favorite ? Brand.pinkInk : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("Favorite: takes a spot on the axes of the ring", "Избранное: занимает место на осях кольца"))
                .accessibilityLabel(Text(row.favorite ? L("Remove from favorites", "Убрать из избранного") : L("Add to favorites", "Добавить в избранное")))
            }
            Toggle(L("Show on the Wheel", "Показывать на колесе"), isOn: Binding(get: { !row.hidden }, set: { model.setHidden(!$0, id: row.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 5)
        .opacity(row.hidden ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { inside in model.highlighted = inside ? row.id : (model.highlighted == row.id ? nil : model.highlighted) }
        .contextMenu {
            if canMove {
                Button(L("Move Up", "Переместить выше")) { model.move(id: row.id, .up) }
                Button(L("Move Down", "Переместить ниже")) { model.move(id: row.id, .down) }
                Button(L("Move to the Top", "В начало")) { model.move(id: row.id, .top) }
                Button(L("Move to the End", "В конец")) { model.move(id: row.id, .bottom) }
                Divider()
            }
            Button(row.hidden ? L("Show on the Wheel", "Показывать на колесе") : L("Hide from the Wheel", "Скрыть с колеса")) { model.setHidden(!row.hidden, id: row.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if canMove {
                Button(L("Move Up", "Переместить выше")) { model.move(id: row.id, .up) }
                Button(L("Move Down", "Переместить ниже")) { model.move(id: row.id, .down) }
            }
        }
    }

    static func note(for slot: LayoutSlot) -> String? {
        switch slot {
        case .more: return L("Behind “More…”", "За пунктом «Ещё…»")
        case .studioOnly: return L("Studio only: no room on the wheel", "Только в Студии: на колесе нет места")
        case .ring, .hidden: return nil
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: DS.Space.md) {
            WheelRingPreview(sectors: model.previewRing(), wheel: model.wheel, highlighted: model.highlighted)
            Text(L("The first ring as the wheel draws it. Favorites take the top, right, bottom and left spots when the ring has 4 or 8 slots.",
                   "Первое кольцо так, как его рисует колесо. Избранное занимает верхнее, правое, нижнее и левое места, если на кольце 4 или 8 пунктов."))
                .font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: DS.Space.sm) {
                Button { model.resetCurrent() } label: { Text(L("Reset this wheel for this kind", "Сбросить это колесо для этого вида")).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
                    .frame(maxWidth: .infinity)
                Button(L("Reset All", "Сбросить всё"), role: .destructive) { confirmResetAll = true }
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
    }
}
