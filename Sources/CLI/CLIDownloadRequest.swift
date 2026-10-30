import Foundation

/// `swamp download <url> --set dl.maxHeight=720 ...`: the typed options of the `download.link` schema as the `DownloadRequest` that `DownloadService.start(request:)` takes.
/// The service turns the request back into job options and the runner validates them again (file-name template, folder), so this mapping only has to be faithful.
@MainActor
enum CLIDownloadRequest {
    static func build(url: URL, mode: DownloadMode, sets: [String], settings: SettingsData) -> Result<DownloadRequest, CLIUsageError> {
        let schema = DownloadSchemas.link()
        let typed: OptionValues
        switch CLIArguments.optionValues(from: sets, schema: schema) {
        case .failure(let e): return .failure(e)
        case .success(let v): typed = v
        }
        // The wheel sector's own recipe first (mode, audio container, what happens after), the person's --set values on top.
        var base = OptionValues()
        base[DownloadKeys.mode] = .string(mode.rawValue)
        base[DownloadKeys.audioFormat] = .string(mode == .audioMP3 ? "mp3" : "m4a")
        switch mode {
        case .bestForApple: base[DownloadKeys.after] = .string(settings.downloader.afterDownload.stringValue)
        case .universal: base[DownloadKeys.after] = .string(AfterDownload.universal.stringValue)
        case .maximum, .audioM4A, .audioMP3: base[DownloadKeys.after] = .string(AfterDownload.keepOriginal.stringValue)
        }
        let resolved = schema.resolve(layers: [base, typed])
        if let bad = resolved.messages.first(where: { $0.severity == .error }) {
            return .failure(CLIUsageError(message: (bad.fieldKey.map { "'\($0)': " } ?? "") + bad.text.text))
        }
        let o = resolved.values
        let chosen = DownloadMode(rawValue: o.string(DownloadKeys.mode)) ?? mode

        var r = DownloadRequest(url: url, outputDirectory: DownloadService.shared.outputDirectory(for: chosen, settings: settings.downloader))
        r.mode = chosen
        let audio = chosen.isAudioOnly
        let cap = o.int(DownloadKeys.maxHeight, 0)
        r.maxHeight = (!audio && cap > 0 && resolved.isActive(DownloadKeys.maxHeight)) ? cap : nil
        r.audioFormat = chosen == .audioMP3 ? .mp3 : (DownloadAudioFormat(rawValue: o.string(DownloadKeys.audioFormat, "m4a")) ?? .m4a)
        r.audioQuality = (r.audioFormat == .mp3 && resolved.isActive(DownloadKeys.audioQuality)) ? o.int(DownloadKeys.audioQuality, 0) : 0
        if audio || chosen == .maximum { r.after = .keepOriginal } else { r.after = AfterDownload(string: o.string(DownloadKeys.after, "best")) ?? .bestForApple }
        switch o.string(DownloadKeys.playlist, "single") {
        case "all": r.playlistItems = ""
        case "items":
            let items = o.string(DownloadKeys.playlistItems).replacingOccurrences(of: " ", with: "")
            r.playlistItems = items.isEmpty ? nil : items
        default: r.playlistItems = nil
        }
        if !audio, resolved.isActive(DownloadKeys.subtitles), let s = DownloadSubtitleMode(rawValue: o.string(DownloadKeys.subtitles, "none")) {
            r.subtitles = s
            r.subtitleLanguages = o.string(DownloadKeys.subtitleLanguages).split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        if resolved.isActive(DownloadKeys.sectionStart) { r.sectionStart = o[DownloadKeys.sectionStart]?.asDouble }
        if resolved.isActive(DownloadKeys.sectionEnd) { r.sectionEnd = o[DownloadKeys.sectionEnd]?.asDouble }
        r.embedMetadata = o.bool(DownloadKeys.embedMetadata, true)
        r.embedThumbnail = o.bool(DownloadKeys.embedThumbnail, true)
        let template = o.string(DownloadKeys.filenameTemplate)
        if !template.isEmpty { r.filenameTemplate = template }
        r.cookies = CookieBrowser(rawValue: o.string(DownloadKeys.cookies, "none")) ?? .none
        r.rateLimitKBps = max(0, o.int(DownloadKeys.rateLimit, 0))
        r.concurrentFragments = min(max(o.int(DownloadKeys.fragments, 1), 1), 8)
        let folder = o.string(DownloadKeys.folder)
        if !folder.isEmpty { r.outputDirectory = URL(fileURLWithPath: folder, isDirectory: true) }
        return .success(r)
    }
}
