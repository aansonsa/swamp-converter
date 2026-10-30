import SwiftUI
import AppKit

/// Preview: image before / after with a draggable divider + size delta chip + zoom to 100%; video frame scrubber with a "Render 3 s Test" loop; audio waveform + loudness; PDF page strip
/// with OCR overlay; subtitles cue table with encoding picker; spreadsheet first 100 rows as a Table with delimiter hint; archive tree with checkboxes and unsafe-path flags; a link's info
/// card. Everything is cancellable and keyed by the options hash (the session owns the key); the scrubber track is Swamp Blue.
struct PreviewPane: View {
    @StateObject private var model: StudioWindowModel
    init(session: StudioSession) { _model = StateObject(wrappedValue: StudioWindowModel(session: session)) }
    init(model: StudioWindowModel) { _model = StateObject(wrappedValue: model) }

    var body: some View { PreviewPaneContent(model: model, session: model.session) }
}

/// What the session has rendered for the focused source, as plain values the preview views take (so they re-render only when the pictures change).
struct PreviewFrames {
    var before: CGImage?
    var after: CGImage?
    var note: String?
    var resultBytes: Int64?
    var isWorking: Bool

    var token: Int { PreviewFrames.identity(before) &* 31 &+ PreviewFrames.identity(after) }
    static func identity(_ image: CGImage?) -> Int { image.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0 }

    init(before: CGImage? = nil, after: CGImage? = nil, note: String? = nil, resultBytes: Int64? = nil, isWorking: Bool = false) {
        self.before = before; self.after = after; self.note = note; self.resultBytes = resultBytes; self.isWorking = isWorking
    }

    @MainActor
    init(session: StudioSession, appliesToFocus: Bool) {
        isWorking = session.isPreviewing
        resultBytes = session.estimate?.bytes
        guard appliesToFocus, let p = session.preview else { return }
        before = p.before
        after = p.after
        note = p.note?.text
        if let b = p.sampleOutputBytes, resultBytes == nil { resultBytes = b }
    }
}

struct PreviewPaneContent: View {
    @ObservedObject var model: StudioWindowModel
    @ObservedObject var session: StudioSession

    var body: some View {
        let row = model.state.focused
        let firstUsableID = session.sources.first(where: { $0.isUsableForStudio })?.id
        let applies = row?.id == firstUsableID
        let frames = model.previewOverride?.frames ?? PreviewFrames(session: session, appliesToFocus: applies)
        let bindings = PreviewBindings.discover(in: session.schema)
        Group {
            if let row {
                if let reason = row.failureReason {
                    PreviewMessage(symbol: "exclamationmark.triangle", title: L("This file can’t be used", "Этот файл нельзя использовать"), text: reason)
                } else {
                    content(row, frames: frames, bindings: bindings, applies: applies)
                }
            } else {
                PreviewMessage(symbol: "square.dashed", title: L("Nothing to preview", "Нечего показывать"), text: L("Add a file to see it here.", "Добавьте файл, чтобы увидеть его здесь."))
            }
        }
        .accessibilityIdentifier(StudioIdentifiers.preview)
    }

    @ViewBuilder
    private func content(_ row: StudioSourceRow, frames: PreviewFrames, bindings: PreviewBindings, applies: Bool) -> some View {
        switch row.kind {
        case .image:
            PreviewImageView(model: model, session: session, row: row, frames: frames, bindings: bindings, appliesToFocus: applies)
        case .video, .audio:
            PreviewMediaView(model: model, session: session, row: row, frames: frames, bindings: bindings, appliesToFocus: applies)
        case .pdf:
            PreviewPDFView(model: model, session: session, row: row, bindings: bindings)
        case .subtitle:
            PreviewSubtitleView(session: session, row: row, bindings: bindings)
        case .spreadsheet:
            PreviewSheetView(session: session, row: row, bindings: bindings)
        case .archive:
            PreviewArchiveView(session: session, row: row, bindings: bindings)
        case .link:
            PreviewLinkView(row: row, source: session.sources.first { $0.id == row.id })
        case .document, .folder, .other, .empty:
            PreviewGenericView(row: row)
        }
    }
}

/// A centred calm message with a symbol (empty and error states inside the preview).
struct PreviewMessage: View {
    var symbol: String
    var title: String
    var text: String?

    var body: some View {
        EmptyStateView(symbol: symbol, title: title, message: text)
    }
}

/// Documents and folders: the file's Quick Look picture and its size. Their options are all in the inspector.
struct PreviewGenericView: View {
    var row: StudioSourceRow

    var body: some View {
        VStack(spacing: DS.Space.md) {
            if let url = row.url {
                ThumbnailView(url: url, kind: row.fileKind, width: 280, height: 360, cornerRadius: DS.Radius.card, fit: true, label: row.name)
            }
            Text(row.detail).font(DS.Typo.callout).foregroundStyle(.secondary)
            if let b = row.sizeBytes { Text(Util.formatBytes(b)).font(DS.Typo.numeric(DS.Typo.callout)).foregroundStyle(.secondary) }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The row of small controls under a preview. Items wrap to a new line instead of truncating (Russian is longer).
struct PreviewControlBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        StudioWrapLayout(spacing: DS.Space.sm, lineSpacing: DS.Space.sm) { content() }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small icon toggle for the control bar (zoom, loupe, crop, keyframes): symbol, text, on / off state shown by tint AND by a filled symbol.
struct PreviewToggleButton: View {
    var title: String
    var symbol: String
    @Binding var isOn: Bool
    var isEnabled = true
    @Environment(\.a11y) private var a11y

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(DS.Typo.caption.weight(.medium))
                .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
                .background(isOn ? Brand.pink.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                .overlay { if isOn || a11y.increaseContrast { Capsule().strokeBorder(isOn ? Brand.pinkInk : Color.primary.opacity(0.4), lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(Text(isOn ? L("On", "Вкл.") : L("Off", "Выкл.")))
    }
}

/// "About 1.2 MB, 68% smaller": the size chip of the preview.
struct PreviewSizeChip: View {
    var original: Int64?
    var result: Int64?

    var body: some View {
        if let result {
            let delta = PreviewMath.sizeDeltaPercent(original: original, result: result)
            InfoChip(L("About \(Util.formatBytes(result))", "Около \(Util.formatBytes(result))") + (delta.map { " \u{00B7} " + PreviewMath.sizeDeltaText(percent: $0) } ?? ""),
                     symbol: "arrow.down.right.and.arrow.up.left")
        }
    }
}
