import Foundation

// The LINK-wheel operations. One class, five registrations; behaviour = f(links, ctx.options) like every other operation.
// Wheel order: Best for Apple, Maximum quality, Universal, Audio M4A, Audio MP3 ("Choose in Studio..." is the wheel's Customise path, not an operation).

enum DownloadCatalog {
    /// The operation id of each wheel sector.
    static func operationID(for mode: DownloadMode) -> String {
        switch mode {
        case .bestForApple: return "link.best"
        case .maximum: return "link.max"
        case .universal: return "link.universal"
        case .audioM4A: return "link.audio.m4a"
        case .audioMP3: return "link.audio.mp3"
        }
    }

    @MainActor
    static func operations() -> [Operation] {
        func op(_ mode: DownloadMode, sub: L10n) -> Operation {
            DownloadLinkOperation(mode: mode, meta: .link(operationID(for: mode), mode.title, sub: sub, symbol: mode.symbol, schema: DownloadSchemas.linkID))
        }
        return [
            op(.bestForApple, sub: L10n("HEVC if needed", "HEVC при необходимости")),
            op(.maximum, sub: L10n("best quality, as is", "лучшее качество, как есть")),
            op(.universal, sub: L10n("H.264, for all", "H.264 для всех")),
            op(.audioM4A, sub: L10n("sound only", "только звук")),
            op(.audioMP3, sub: L10n("sound only", "только звук"))
        ]
    }
}

final class DownloadLinkOperation: LinkOperation, @unchecked Sendable {
    let mode: DownloadMode

    init(mode: DownloadMode, meta: OperationMeta) {
        self.mode = mode
        super.init(meta: meta)
    }

    /// The quick recipe: mode, the after-download action from settings, subtitles / metadata / cookies / rate limit defaults.
    override func quickOverrides(settings: SettingsData) -> OptionValues { DownloadOptionsMapper.quickOptions(mode: mode, settings: settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { DownloadSchemas.link() }

    /// yt-dlp is found or can be installed with one explicit click (the service asks), so the sector is always offered.
    /// ffmpeg is needed to join video and sound; without it the run falls back to single-file formats and says so.
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability { .available }

    /// Two stages when a conversion follows (download 0.6, convert 0.4), otherwise just the download.
    override func stagePlan(options: OptionValues) -> [StageSpec] {
        let mode = DownloadMode(rawValue: options.string(DownloadKeys.mode)) ?? .bestForApple
        let burn = options.string(DownloadKeys.subtitles) == "burn"
        let converts = !mode.isAudioOnly && (DownloadOptionsMapper.effectiveAfter(options) != .keepOriginal || burn)
        return converts ? [.download(), .convert()] : [.download(weight: 1)]
    }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        var out: [OptionMessage] = []
        if let s = options[DownloadKeys.sectionStart]?.asDouble, let e = options[DownloadKeys.sectionEnd]?.asDouble, e <= s {
            out.append(OptionMessage(id: "dl.section.order", severity: .error, text: L10n("The end of the part must come after its start.", "Конец части должен быть позже её начала."), fieldKey: DownloadKeys.sectionEnd))
        }
        if options.string(DownloadKeys.playlist) == "items", options.string(DownloadKeys.playlistItems).trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(OptionMessage(id: "dl.playlist.empty", severity: .error, text: L10n("Enter the numbers of the videos to download, for example 1,3,5-7.", "Введите номера видео, например 1,3,5-7."), fieldKey: DownloadKeys.playlistItems))
        }
        return out
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        let mode = DownloadMode(rawValue: options.string(DownloadKeys.mode)) ?? .bestForApple
        var chips = [mode.title.text]
        let cap = options.int(DownloadKeys.maxHeight, 0)
        if cap > 0, !mode.isAudioOnly { chips.append("\(cap)p") }
        if mode.isAudioOnly { chips.append(mode == .audioMP3 ? "MP3" : options.string(DownloadKeys.audioFormat, "m4a").uppercased()) }
        return chips
    }

    /// Size from the information fetched a moment ago (the info card, or the job's own fetch); nil before that.
    override func estimateLinks(options: OptionValues, links: [LinkItem]) -> OperationEstimate? {
        guard let link = links.first, let info = DownloadInfoCache.shared.latest(forKey: link.canonicalKey), !info.isPlaylist else { return nil }
        let mode = DownloadMode(rawValue: options.string(DownloadKeys.mode)) ?? .bestForApple
        let cap = options.int(DownloadKeys.maxHeight, 0)
        guard let bytes = FormatSelector.choose(info: info, mode: mode, maxHeight: cap > 0 ? cap : nil)?.estimatedBytes else { return nil }
        return OperationEstimate(bytes: bytes, seconds: nil, confidence: .rough, note: L10n("Size of the download; a conversion changes it.", "Размер загрузки; конвертация его изменит."))
    }

    /// Runs `DownloadRunner`: information, format choice, disk check, yt-dlp with progress, the convert stage, files in the output folder.
    override func executeLinks(_ links: [LinkItem], ctx: OperationContext) async throws -> OperationResult {
        try await DownloadRunner(ctx: ctx).run(links: links)
    }
}
