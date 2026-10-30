import Foundation

/// Stable option keys of the `fit.*` schemas. Adding keys is free; renaming or removing breaks presets.
enum FitKeys {
    static let target = "fit.target"            // SizeTarget id or "custom"
    static let customMB = "fit.customMB"        // megabytes when target == custom
    static let allowDownscale = "fit.downscale" // allow lowering resolution to reach the target (PDF: allow turning pages into pictures)
    static let twoPass = "fit.twopass"          // video: two-pass when the encoder supports it
    static let audioKbps = "fit.audioKbps"      // video: audio budget
    static let minQuality = "fit.minQuality"    // image / PDF: floor of the quality search
    static let keepFormat = "fit.keepFormat"    // image: stay in the source format (else JPEG, or the format chosen in `imageFormat`)
    static let stripMetadata = "fit.strip"
    /// audio: `auto` (AAC in .m4a: the most exact size and plays everywhere), `aac`, `mp3`, `opus`.
    static let audioCodec = "fit.audioCodec"
    /// image, when `keepFormat` is off: `auto` (JPEG; PNG for pictures with transparency), `heic`, `webp`, `jpg`.
    static let imageFormat = "fit.imgFormat"
}

/// The four kinds the module serves. Maps schema ids, file kinds and engines onto each other in one place.
enum FitKind: String, CaseIterable, Sendable {
    case video, audio, image, pdf

    init?(schemaID: String) {
        guard schemaID.hasPrefix("fit."), let k = FitKind(rawValue: String(schemaID.dropFirst(4))) else { return nil }
        self = k
    }

    init?(fileKind: FileKind) {
        switch fileKind {
        case .video: self = .video
        case .audio: self = .audio
        case .image, .raw: self = .image
        case .pdf: self = .pdf
        default: return nil
        }
    }

    var schemaID: String { "fit." + rawValue }

    /// The file kind whose `SizeTargetCatalog` entries apply.
    var fileKind: FileKind {
        switch self {
        case .video: return .video
        case .audio: return .audio
        case .image: return .image
        case .pdf: return .pdf
        }
    }

    var noun: L10n {
        switch self {
        case .video: return L10n("Video", "Видео")
        case .audio: return L10n("Audio", "Аудио")
        case .image: return L10n("Image", "Изображение")
        case .pdf: return L10n("PDF", "PDF")
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        }
    }
}
