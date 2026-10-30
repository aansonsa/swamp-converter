import Foundation

// The one translation between the option set of the `download.link` schema and a `DownloadRequest`.
// Quick path: `quickOverrides` (mode + settings) -> options -> request. Studio / start(request:): request -> options -> the same operation.
// The engine only ever reads `ctx.options`, so both speeds run exactly the same code.

enum DownloadOptionsMapper {
    /// The quick recipe of a mode: what the wheel sector means, with the user's defaults from Settings > Downloader.
    static func quickOptions(mode: DownloadMode, settings: SettingsData) -> OptionValues {
        let d = settings.downloader
        var v = OptionValues()
        v[DownloadKeys.mode] = .string(mode.rawValue)
        v[DownloadKeys.audioFormat] = .string(mode == .audioMP3 ? "mp3" : "m4a")
        switch mode {
        case .bestForApple: v[DownloadKeys.after] = .string(d.afterDownload.stringValue)
        case .universal: v[DownloadKeys.after] = .string(AfterDownload.universal.stringValue)
        case .maximum, .audioM4A, .audioMP3: v[DownloadKeys.after] = .string(AfterDownload.keepOriginal.stringValue)
        }
        // Burning needs an ffmpeg with libass; without it the subtitles stay switchable inside the video instead of vanishing.
        let burn = d.burnSubtitles && Capabilities.shared.has("ff.filter.subtitles")
        v[DownloadKeys.subtitles] = .string(d.subtitles ? (burn ? "burn" : "soft") : "none")
        v[DownloadKeys.subtitleLanguages] = .string(d.subtitleLanguages)
        v[DownloadKeys.embedMetadata] = .bool(d.embedMetadata)
        v[DownloadKeys.embedThumbnail] = .bool(d.embedThumbnail)
        v[DownloadKeys.filenameTemplate] = .string(d.filenameTemplate)
        v[DownloadKeys.cookies] = .string(d.cookies.rawValue)
        v[DownloadKeys.rateLimit] = .int(d.rateLimitKBps)
        v[DownloadKeys.fragments] = .int(d.fragments)
        v[DownloadKeys.folder] = .string(d.folder ?? "")
        return v
    }

    /// The post-download action the options mean (audio and Maximum never convert).
    static func effectiveAfter(_ o: OptionValues) -> AfterDownload {
        let mode = DownloadMode(rawValue: o.string(DownloadKeys.mode)) ?? .bestForApple
        if mode.isAudioOnly || mode == .maximum { return .keepOriginal }
        return AfterDownload(string: o.string(DownloadKeys.after, "best")) ?? .bestForApple
    }

    /// Options (as resolved by the schema, every key present) + the link -> the request for yt-dlp.
    /// Inactive fields are ignored (`active` answers `ctx.isActive`), so a hidden "Numbers" box never leaks into the argv.
    static func request(from o: OptionValues, url: URL, settings: SettingsData, active: (String) -> Bool = { _ in true }) -> DownloadRequest {
        let mode = DownloadMode(rawValue: o.string(DownloadKeys.mode)) ?? .bestForApple
        let audioOnly = mode.isAudioOnly
        let folder = DownloadFolders.resolve(audioOnly: audioOnly, settingsFolder: settings.downloader.folder, override: o.string(DownloadKeys.folder))
        var r = DownloadRequest(url: url, outputDirectory: folder)
        r.mode = mode
        let cap = o.int(DownloadKeys.maxHeight, 0)
        r.maxHeight = (!audioOnly && cap > 0 && active(DownloadKeys.maxHeight)) ? cap : nil
        r.audioFormat = mode == .audioMP3 ? .mp3 : (DownloadAudioFormat(rawValue: o.string(DownloadKeys.audioFormat, "m4a")) ?? .m4a)
        r.audioQuality = (r.audioFormat == .mp3 && active(DownloadKeys.audioQuality)) ? o.int(DownloadKeys.audioQuality, 0) : 0
        r.after = effectiveAfter(o)
        switch o.string(DownloadKeys.playlist, "single") {
        case "all": r.playlistItems = ""
        case "items":
            let items = o.string(DownloadKeys.playlistItems).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            r.playlistItems = items.isEmpty ? nil : items
        default: r.playlistItems = nil
        }
        if !audioOnly, active(DownloadKeys.subtitles), let s = DownloadSubtitleMode(rawValue: o.string(DownloadKeys.subtitles, "none")) {
            r.subtitles = s
            r.subtitleLanguages = o.string(DownloadKeys.subtitleLanguages).split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        if active(DownloadKeys.sectionStart) { r.sectionStart = o[DownloadKeys.sectionStart]?.asDouble }
        if active(DownloadKeys.sectionEnd) { r.sectionEnd = o[DownloadKeys.sectionEnd]?.asDouble }
        r.embedMetadata = o.bool(DownloadKeys.embedMetadata, true)
        r.embedThumbnail = o.bool(DownloadKeys.embedThumbnail, true)
        let template = o.string(DownloadKeys.filenameTemplate)
        r.filenameTemplate = YtDlpArguments.isSafeTemplate(template) ? template : DownloaderSettings().filenameTemplate
        r.cookies = CookieBrowser(rawValue: o.string(DownloadKeys.cookies, "none")) ?? .none
        r.rateLimitKBps = max(0, o.int(DownloadKeys.rateLimit, 0))
        r.concurrentFragments = min(max(o.int(DownloadKeys.fragments, 1), 1), 8)
        return r
    }

    /// The inverse, for `DownloadService.start(request:)` (Studio / the download sheet): every key of the schema is written.
    static func options(from r: DownloadRequest) -> OptionValues {
        var v = OptionValues()
        v[DownloadKeys.mode] = .string(r.mode.rawValue)
        v[DownloadKeys.maxHeight] = .string(String(r.maxHeight ?? 0))
        v[DownloadKeys.audioFormat] = .string(r.mode == .audioMP3 ? "mp3" : r.audioFormat.rawValue)
        v[DownloadKeys.audioQuality] = .string(String(r.audioQuality))
        v[DownloadKeys.after] = .string(r.after.stringValue)
        v[DownloadKeys.subtitles] = .string(r.subtitles.rawValue)
        v[DownloadKeys.subtitleLanguages] = .string(r.subtitleLanguages.joined(separator: ","))
        v[DownloadKeys.sectionStart] = r.sectionStart.map { .double($0) } ?? .string("")
        v[DownloadKeys.sectionEnd] = r.sectionEnd.map { .double($0) } ?? .string("")
        v[DownloadKeys.embedMetadata] = .bool(r.embedMetadata)
        v[DownloadKeys.embedThumbnail] = .bool(r.embedThumbnail)
        v[DownloadKeys.filenameTemplate] = .string(r.filenameTemplate)
        switch r.playlistItems {
        case nil: v[DownloadKeys.playlist] = .string("single")
        case "": v[DownloadKeys.playlist] = .string("all")
        case let items?: v[DownloadKeys.playlist] = .string("items"); v[DownloadKeys.playlistItems] = .string(items)
        }
        v[DownloadKeys.cookies] = .string(r.cookies.rawValue)
        v[DownloadKeys.rateLimit] = .int(r.rateLimitKBps)
        v[DownloadKeys.fragments] = .int(r.concurrentFragments)
        v[DownloadKeys.folder] = .string(r.outputDirectory.path)
        return v
    }

    /// How many items a `--playlist-items` spec names ("1,3,5-7" is 5); nil for open ranges.
    static func itemCount(of spec: String) -> Int? {
        var n = 0
        for part in spec.split(separator: ",") {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if ends.count == 1, Int(ends[0]) != nil { n += 1 }
            else if ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]), b >= a { n += b - a + 1 }
            else { return nil }
        }
        return n > 0 ? n : nil
    }
}
