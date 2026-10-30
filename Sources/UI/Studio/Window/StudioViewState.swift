import SwiftUI
import AppKit

// A small, Equatable snapshot of what the window needs from the session. The window's views take THIS (and a few closures), not the session, so typing in the inspector or
// dragging a slider does not rebuild the sidebar, the toolbar and the preview: they re-render only when their own slice changed. Snapshots build the state by hand.

/// What the centre column shows for the focused source.
enum StudioContentKind: Equatable, Sendable {
    case empty, image, audio, video, pdf, subtitle, spreadsheet, archive, document, folder, other, link

    init(fileKind: FileKind?, isLink: Bool = false) {
        if isLink { self = .link; return }
        switch fileKind {
        case .none: self = .empty
        case .some(.image), .some(.raw): self = .image
        case .some(.audio): self = .audio
        case .some(.video): self = .video
        case .some(.pdf): self = .pdf
        case .some(.subtitle): self = .subtitle
        case .some(.spreadsheet): self = .spreadsheet
        case .some(.archive): self = .archive
        case .some(.document), .some(.slides): self = .document
        case .some(.folder): self = .folder
        case .some(.other): self = .other
        }
    }

    /// Video and audio have a timeline with In / Out handles.
    var hasTimeline: Bool { self == .video || self == .audio }
    var symbol: String {
        switch self {
        case .empty: return "square.dashed"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .subtitle: return "captions.bubble"
        case .spreadsheet: return "tablecells"
        case .archive: return "archivebox"
        case .document: return "doc.text"
        case .folder: return "folder"
        case .other: return "doc"
        case .link: return "link"
        }
    }
}

struct StudioSourceRow: Identifiable, Equatable {
    var id: String
    var name: String
    /// "3840x2160, HEVC" for a probed file, the host for a link.
    var detail: String
    var kind: StudioContentKind
    var fileKind: FileKind?
    var url: URL?
    var status: StudioSource.Status
    var sizeBytes: Int64?
    var duration: Double?
    var fps: Double?
    var pixelSize: CGSize?
    var pageCount: Int?

    var statusKind: StatusKind {
        switch status { case .probing: return .waiting; case .ready: return .done; case .failed: return .failed }
    }
    var failureReason: String? { if case .failed(let r) = status { return r }; return nil }
}

struct StudioTargetRow: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var family: OperationFamily
    /// nil = usable; otherwise the calm reason it is dimmed ("Needs ffmpeg ...").
    var unavailableReason: String?
}

struct StudioPageRow: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
}

struct StudioViewState: Equatable {
    var sources: [StudioSourceRow] = []
    var focusedSourceID: String?
    var targetID: String?
    var targets: [StudioTargetRow] = []
    var presetID: String?
    var presetName: String?
    var isModified = false
    var canStart = false
    var hasSchema = false
    var pages: [StudioPageRow] = []
    var errorCount = 0
    var warningCount = 0
    var summaryLine: String?
    var isPreviewing = false
    var isLinkSession = false

    /// The selected source, else the first usable one (the same fallback the session uses for its estimate and preview).
    var focused: StudioSourceRow? { sources.first { $0.id == focusedSourceID } ?? sources.first { $0.failureReason == nil } ?? sources.first }
    var kind: StudioContentKind { sources.isEmpty ? .empty : (focused?.kind ?? .empty) }
    var isEmpty: Bool { sources.isEmpty }
}

@MainActor
extension StudioViewState {
    /// Reads the session once. `focusedSourceID` is the window's own selection (the sidebar).
    static func make(from session: StudioSession, focusedSourceID: String?) -> StudioViewState {
        var s = StudioViewState()
        s.sources = session.sources.map(Self.row)
        s.focusedSourceID = focusedSourceID.flatMap { id in session.sources.contains { $0.id == id } ? id : nil }
        s.targetID = session.targetID
        s.targets = session.targets.map { t in
            StudioTargetRow(id: t.id, title: t.title.text, symbol: t.symbol, family: t.family, unavailableReason: t.availability.reason?.text)
        }
        s.presetID = session.presetID
        s.presetName = session.presetID.flatMap { PresetStore.shared.preset(id: $0)?.name.text }
        s.isModified = session.isModified
        s.canStart = session.canStart
        s.hasSchema = session.schema != nil
        s.pages = (session.schema?.pages ?? []).map { StudioPageRow(id: $0.id, title: $0.title.text, symbol: $0.symbol) }
        s.errorCount = session.messages.filter { $0.severity == .error }.count
        s.warningCount = session.messages.filter { $0.severity == .warning }.count
        s.summaryLine = session.summaryChips.isEmpty ? nil : session.summaryChips.joined(separator: " \u{00B7} ")
        s.isPreviewing = session.isPreviewing
        s.isLinkSession = !session.sources.isEmpty && session.sources.allSatisfy { $0.input.isLink }
        return s
    }

    static func row(_ source: StudioSource) -> StudioSourceRow {
        let info = source.info
        var detail = ""
        var kind = StudioContentKind.other
        var fileKind: FileKind?
        var url: URL?
        switch source.input {
        case .link(let l):
            kind = .link; detail = l.host
        case .file(let f):
            fileKind = f.kind; url = f.url; kind = StudioContentKind(fileKind: f.kind)
            detail = (info?.chips.prefix(3).map(\.text).joined(separator: ", ")).flatMap { $0.isEmpty ? nil : $0 } ?? f.kind.title.text
        }
        var row = StudioSourceRow(id: source.id, name: source.input.displayName, detail: detail, kind: kind, fileKind: fileKind, url: url, status: source.status)
        row.sizeBytes = info?.sizeBytes ?? source.input.file?.size
        row.duration = info?.duration
        row.fps = info?.number("video.fps")
        if let w = info?.number("video.width") ?? info?.number("image.width"), let h = info?.number("video.height") ?? info?.number("image.height") { row.pixelSize = CGSize(width: w, height: h) }
        row.pageCount = info?.int("pdf.pages")
        return row
    }
}
