import SwiftUI
import AppKit

/// Centre column: source strip (`SourceInspectorView` chips), the preview, and the timeline (In / Out handles, chapters, keyframes for video; waveform for audio; page strip for PDF).
/// With the Queue selected in the sidebar the same column shows the queue panel.
struct StudioCentreView: View {
    @StateObject private var model: StudioWindowModel
    init(session: StudioSession) { _model = StateObject(wrappedValue: StudioWindowModel(session: session)) }
    init(model: StudioWindowModel) { _model = StateObject(wrappedValue: model) }

    var body: some View { StudioCentreContent(model: model) }
}

struct StudioCentreContent: View {
    @ObservedObject var model: StudioWindowModel
    /// Shorter than this, the column scrolls instead of squeezing the preview to nothing and cutting off the controls under it.
    static let compactHeight: CGFloat = 600

    var body: some View {
        GeometryReader { geo in
            // The queue has its own scrolling list, so only the preview side scrolls as a whole.
            if geo.size.height < Self.compactHeight && model.pane == .source && !model.state.isEmpty {
                ScrollView(.vertical) { column.frame(height: Self.compactHeight) }
            } else {
                column
            }
        }
        .background(DS.Surface.window)
    }

    private var column: some View {
        VStack(spacing: 0) {
            if let notice = model.notice { StudioNoticeBar(text: notice) { model.notice = nil } }
            switch model.pane {
            case .queue:
                QueuePanel(model: model)
            case .source:
                if model.state.isEmpty {
                    StudioEmptyState(model: model)
                } else {
                    StudioSourceStrip(model: model)
                    Divider()
                    PreviewPane(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Surface.window)
    }
}

/// The picture of the file, its name and the facts of the studio-core inspector (chips, warnings in plain words, a popover with every stream). With several sources a row of chips
/// switches between them.
struct StudioSourceStrip: View {
    @ObservedObject var model: StudioWindowModel

    private var focusedSource: StudioSource? {
        guard let id = model.state.focused?.id else { return nil }
        return model.session.sources.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if model.state.sources.count > 1 { chips }
            HStack(alignment: .top, spacing: DS.Space.md) {
                if let row = model.state.focused {
                    if let url = row.url { ThumbnailView(url: url, kind: row.fileKind, size: 48) }
                    else { Image(systemName: row.kind.symbol).symbolRenderingMode(.hierarchical).font(.title2).frame(width: 48, height: 48).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(row.name).font(DS.Typo.headline).lineLimit(1).truncationMode(.middle)
                        if let source = focusedSource { SourceInspectorView(source: source) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(model.state.sources) { row in
                    Button { model.selectedSourceID = row.id } label: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: row.kind.symbol).imageScale(.small)
                            Text(row.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                        }
                        .font(DS.Typo.caption.weight(.medium))
                        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
                        .background(row.id == model.state.focused?.id ? Brand.pink.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                        .overlay { if row.id == model.state.focused?.id { Capsule().strokeBorder(Brand.pink.opacity(0.7), lineWidth: 1) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(row.id == model.state.focused?.id ? .isSelected : [])
                }
            }
        }
    }
}
