import SwiftUI

/// Source facts as chips (container, codec, resolution, fps, HDR, duration, size) + warnings in plain words; click opens a popover listing every stream with language / channels / codec.
/// A link shows its host and title; a file that is still being read shows a quiet progress indicator; a file that cannot be read says why.
struct SourceInspectorView: View {
    var source: StudioSource
    @State private var streamsShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            switch source.input {
            case .link(let link): linkContent(link)
            case .file(let file): fileContent(file)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: File

    @ViewBuilder private func fileContent(_ file: FileItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(file.name).font(DS.Typo.headline).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
            if case .probing = source.status { ProgressView().controlSize(.small).accessibilityLabel(Text(L("Reading the file", "Чтение файла"))) }
        }
        switch source.status {
        case .failed(let reason):
            OptionMessageRow(reason, severity: .error)
        case .probing:
            OptionFlow { KindChip(kind: file.kind) }
        case .ready:
            if let info = source.info {
                Button { streamsShown.toggle() } label: {
                    OptionFlow {
                        KindChip(kind: file.kind)
                        ForEach(Array(info.chips.enumerated()), id: \.offset) { _, c in InfoChip(c.text, symbol: c.symbol) }
                        if info.chips.isEmpty, let size = info.sizeBytes { InfoChip(Util.formatBytes(size), symbol: "internaldrive") }
                    }
                }
                .buttonStyle(.plain)
                .disabled(info.streams.isEmpty)
                .accessibilityLabel(Text(L("Source details", "Сведения об источнике")))
                .accessibilityHint(Text(info.streams.isEmpty ? "" : L("Shows every stream of the file", "Показывает все потоки файла")))
                .popover(isPresented: $streamsShown, arrowEdge: .bottom) { StreamListView(info: info) }
                ForEach(Array(info.warnings.enumerated()), id: \.offset) { _, w in OptionMessageRow(w.text, severity: .warning) }
            } else {
                OptionFlow { KindChip(kind: file.kind) }
            }
        }
    }

    // MARK: Link

    @ViewBuilder private func linkContent(_ link: LinkItem) -> some View {
        Text(link.displayTitle).font(DS.Typo.headline).lineLimit(2).truncationMode(.tail)
        OptionFlow {
            InfoChip(L("Link", "Ссылка"), symbol: "link")
            InfoChip(link.host, symbol: "globe")
            if let s = link.sourceName { InfoChip(s, symbol: "arrow.down.right.square") }
        }
        if case .failed(let reason) = source.status { OptionMessageRow(reason, severity: .error) }
    }
}

/// Every stream of a probed file: kind symbol, title, detail (codec, channels, size), language, "default" marker.
struct StreamListView: View {
    var info: SourceInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(info.streams) { s in
                    HStack(alignment: .top, spacing: DS.Space.sm) {
                        Image(systemName: Self.symbol(s.kind)).symbolRenderingMode(.hierarchical).frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title.isEmpty ? s.kind.rawValue.capitalized : s.title).font(DS.Typo.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            let detail = [s.detail, s.language].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
                            if !detail.isEmpty { Text(detail).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                        if s.isDefault { InfoChip(L("Default", "Основной")) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 340)
        .frame(maxHeight: 360)
    }

    static func symbol(_ kind: SourceStreamKind) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .subtitle: return "captions.bubble"
        case .chapter: return "list.number"
        case .data: return "number"
        case .image: return "photo"
        case .page: return "doc"
        }
    }
}
