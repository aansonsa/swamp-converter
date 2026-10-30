import SwiftUI

/// Table of playlist entries with checkboxes, duration, select all / none, "N of M selected" and the estimated total size. Long lists scroll inside their own box
/// (rows are lazy), so a 500-video channel costs no more than a 5-video one.
struct PlaylistPickerView: View {
    var entries: [PlaylistEntry]
    @Binding var selection: Set<Int>
    /// Rough total of the selected entries ("about 1.2 GB"); nil hides the figure.
    var estimatedBytes: Int64?
    @State private var showsAll = false
    static let collapsedCount = 25

    init(entries: [PlaylistEntry], selection: Binding<Set<Int>>, estimatedBytes: Int64? = nil) {
        self.entries = entries; self._selection = selection; self.estimatedBytes = estimatedBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text(DownloadFormatText.selected(selection.count, of: entries.count)).font(DS.Typo.callout.monospacedDigit())
                if let estimatedBytes, !selection.isEmpty {
                    Text("\u{00B7}").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(DownloadFormatText.size(estimatedBytes)).font(DS.Typo.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.sm)
                Button(L("Select All", "Выбрать все")) { selection = Set(entries.map(\.index)) }
                    .buttonStyle(.link).foregroundStyle(Brand.blueInk).disabled(selection.count == entries.count)
                Button(L("Select None", "Снять выбор")) { selection = [] }
                    .buttonStyle(.link).foregroundStyle(Brand.blueInk).disabled(selection.isEmpty)
            }
            // Inline rows, no inner scroll view (it caught the scroll wheel inside the window's form): the first 25, the rest on request.
            let shown = showsAll ? entries : Array(entries.prefix(Self.collapsedCount))
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    row(entry)
                    if entry.id != shown.last?.id { Divider().padding(.leading, 30) }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            if entries.count > Self.collapsedCount {
                Button(showsAll ? L("Show Fewer", "Показать меньше") : L("Show All \(entries.count)", "Показать все \(entries.count)")) { showsAll.toggle() }
                    .buttonStyle(.link).foregroundStyle(Brand.blueInk)
            }
        }
    }

    private func row(_ entry: PlaylistEntry) -> some View {
        Toggle(isOn: Binding(get: { selection.contains(entry.index) },
                             set: { on in if on { selection.insert(entry.index) } else { selection.remove(entry.index) } })) {
            HStack(spacing: DS.Space.sm) {
                Text("\(entry.index)").font(DS.Typo.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                Text(entry.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: DS.Space.sm)
                if let d = DownloadFormatText.duration(entry.duration) { Text(d).font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs + 1)
    }
}
