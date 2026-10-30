import SwiftUI

/// Edit several waiting rows at once. Every field shows the value the rows share, or "Mixed" when they differ; a field changes only after the person switches "Change" on for it,
/// and only the touched fields are written (each row keeps everything else it had).
struct QueueBulkEditSheet: View {
    @ObservedObject var model: QueuePanelModel
    var ids: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var enabled = Set<String>()
    @State private var newValues: [String: OptionValue] = [:]

    private let jobs: [Job]
    private let schema: OptionSchema?
    private let effective: [OptionValues]

    init(model: QueuePanelModel, ids: Set<UUID>) {
        self.model = model; self.ids = ids
        let list = model.jobs(for: ids)
        jobs = list
        if let first = list.first, let op = model.registry.operation(id: first.operationID) { schema = op.studioSchema(for: first.items) } else { schema = nil }
        effective = model.effectiveValues(of: list)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(Loc.plural(jobs.count, enOne: "Edit \(jobs.count) item", enOther: "Edit \(jobs.count) items", ruOne: "Изменить \(jobs.count) элемент", ruFew: "Изменить \(jobs.count) элемента", ruMany: "Изменить \(jobs.count) элементов"))
                    .font(DS.Typo.title)
                Text(L("Switch on only what you want to change. Everything else stays as each item has it.", "Включите только то, что хотите изменить. Остальное у каждого элемента останется как было."))
                    .font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(L("Search options", "Найти параметр"), text: $query).textFieldStyle(.roundedBorder)
            }
            .padding(DS.Space.xl)
            Divider()
            List {
                ForEach(rows(), id: \.field.key) { r in
                    row(r.field, page: r.page)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text(enabled.isEmpty ? L("Nothing will change.", "Ничего не изменится.") : L("Changing \(enabled.count)", "Изменится параметров: \(enabled.count)"))
                    .font(DS.Typo.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel", "Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).secondaryButtonLook()
                Button(L("Apply", "Применить")) { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent).disabled(enabled.isEmpty)
            }
            .padding(DS.Space.lg)
        }
        .frame(minWidth: 560, minHeight: 520)
        .appRoot()
    }

    // MARK: Rows

    private struct FieldRow { var field: OptionField; var page: String }

    private func rows() -> [FieldRow] {
        guard let schema else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [FieldRow] = []
        for p in schema.pages {
            for g in p.groups {
                for f in g.fields {
                    if case .tracks = f.kind { continue }
                    let hit = q.isEmpty ? f.level != .expert : ([f.label.en, f.label.ru, f.help?.en ?? "", f.help?.ru ?? "", f.key] + f.aliases).contains { $0.looseContains(q) }
                    if hit { out.append(FieldRow(field: f, page: p.title.text)) }
                }
            }
        }
        return out
    }

    @ViewBuilder private func row(_ f: OptionField, page: String) -> some View {
        let common = QueueBulkEdit.common(key: f.key, in: effective)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label.text).font(DS.Typo.body)
                    Text(page).font(DS.Typo.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.sm)
                Text(Self.describe(common, field: f)).font(DS.Typo.callout).foregroundStyle(common.isMixed ? Brand.pinkInk : .secondary).multilineTextAlignment(.trailing)
                Toggle(L("Change", "Изменить"), isOn: Binding(get: { enabled.contains(f.key) }, set: { on in toggle(f, on: on, common: common) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(Text(L("Change \(f.label.text)", "Изменить: \(f.label.text)")))
            }
            if enabled.contains(f.key) {
                OptionFieldView(field: f, value: Binding(get: { newValues[f.key] ?? f.defaultOptionValue }, set: { newValues[f.key] = $0 }))
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func toggle(_ f: OptionField, on: Bool, common: QueueBulkEdit.Common) {
        if on {
            enabled.insert(f.key)
            if newValues[f.key] == nil {
                if case .same(let v) = common, let v { newValues[f.key] = v } else { newValues[f.key] = f.defaultOptionValue }
            }
        } else {
            enabled.remove(f.key); newValues[f.key] = nil
        }
    }

    private func apply() {
        var touched = OptionValues()
        for k in enabled { if let v = newValues[k] { touched[k] = v } }
        model.applyBulk(touched, to: ids)
        dismiss()
    }

    /// What the row shows next to the label: the shared value in words, or "Mixed".
    static func describe(_ c: QueueBulkEdit.Common, field f: OptionField) -> String {
        switch c {
        case .mixed: return L("Mixed", "Разные")
        case .same(let v):
            guard let v else { return L("Default", "По умолчанию") }
            switch f.kind {
            case .picker(let opts), .segmented(let opts):
                if let s = v.asString, let o = opts.first(where: { $0.value == s }) { return o.label.text }
            case .toggle:
                if let b = v.asBool { return b ? L("On", "Вкл.") : L("Off", "Выкл.") }
            default: break
            }
            let unit = f.unit.map { " " + $0 } ?? ""
            if let s = v.asString, !s.isEmpty { return s + unit }
            if let d = v.asDouble { return (d == d.rounded() ? String(Int(d)) : String(d)) + unit }
            return L("Set", "Задано")
        }
    }
}
