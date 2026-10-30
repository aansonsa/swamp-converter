import SwiftUI

/// The quality ladder: "Best available" first, then one row per picture height the page offers (8K/4K/1440p/1080p ...) with codec, frame rate, an HDR flag and the estimated size.
/// For an audio-only download the same control lists the audio formats (M4A, MP3, Opus, FLAC) instead. Rows are real buttons with a selected trait; the selection ring is the
/// brand tint (a graphic), the text keeps the normal label colour.
struct QualityPickerView: View {
    var options: [QualityOption]
    @Binding var selectedID: String?
    /// Non-nil: show the audio formats instead of the video ladder.
    var audioFormat: Binding<DownloadAudioFormat>?

    init(options: [QualityOption], selectedID: Binding<String?>, audioFormat: Binding<DownloadAudioFormat>? = nil) {
        self.options = options; self._selectedID = selectedID; self.audioFormat = audioFormat
    }

    /// Past this many rows the list scrolls inside its own box.

    var body: some View {
        let rows = VStack(spacing: DS.Space.xs) {
            if let audioFormat {
                ForEach(DownloadAudioFormat.choices, id: \.self) { f in
                    PickerRow(selected: audioFormat.wrappedValue == f, action: { audioFormat.wrappedValue = f }) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(f.title).font(DS.Typo.body)
                            Text(f.detail.text).font(DS.Typo.caption).foregroundStyle(.secondary)
                        }
                    } trailing: { EmptyView() }
                }
            } else {
                PickerRow(selected: selectedID == nil, action: { selectedID = nil }) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(L("Best available", "Лучшее доступное")).font(DS.Typo.body)
                        if let best = options.first {
                            Text(L("Up to \(DownloadFormatText.resolutionName(best.height))", "До \(DownloadFormatText.resolutionName(best.height))"))
                                .font(DS.Typo.caption).foregroundStyle(.secondary)
                        }
                    }
                } trailing: { sizeText(options.first?.estimatedBytes) }
                ForEach(options) { option in
                    PickerRow(selected: selectedID == option.id, action: { selectedID = option.id }) {
                        HStack(spacing: DS.Space.sm) {
                            Text(Self.title(option)).font(DS.Typo.body.monospacedDigit())
                            FlowLayout { ForEach(Self.details(option), id: \.self) { InfoChip($0) } }
                        }
                    } trailing: { sizeText(option.estimatedBytes) }
                }
            }
        }
        // Always inline: a list scrolling inside the window's grouped form caught the scroll wheel, and there are only a handful of qualities.
        rows
    }

    private func sizeText(_ bytes: Int64?) -> some View {
        Text(DownloadFormatText.sizeColumn(bytes)).font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary)
    }

    /// The row title: the engine's label without the HDR suffix (HDR is a chip).
    static func title(_ option: QualityOption) -> String { option.label.replacingOccurrences(of: " HDR", with: "") }

    /// Chips of one row: codec, an unusual frame rate (60 fps is already in the title), HDR.
    static func details(_ option: QualityOption) -> [String] {
        var out: [String] = []
        if let c = DownloadFormatText.codecName(option.codec) { out.append(c) }
        if let f = option.fps, f >= 31, f < 49 { out.append("\(Int(f.rounded())) fps") }
        if option.isHDR { out.append("HDR") }
        return out
    }
}

/// One selectable row: a selection mark, the content, an optional trailing column.
struct PickerRow<Content: View, Trailing: View>: View {
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.a11y) private var a11y

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(selected ? .palette : .monochrome)
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.onPink) : AnyShapeStyle(Color.secondary), selected ? AnyShapeStyle(Brand.tint) : AnyShapeStyle(Color.secondary))
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                content().frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? Brand.tint.opacity(0.10) : Color.primary.opacity(0.04), in: Self.shape)
            .overlay { if selected { Self.shape.strokeBorder(Brand.tint, lineWidth: a11y.increaseContrast ? 2 : 1.5) } }
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
