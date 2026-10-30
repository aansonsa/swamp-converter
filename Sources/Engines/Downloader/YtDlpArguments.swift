import Foundation

// Builds the argv of yt-dlp. ALWAYS arrays, never a shell string. The URL is the LAST element, after `--`, so it can never be read as an
// option. Output paths are confined to one folder: the output template is validated, `-P` gives the folder, nothing else decides where files go.

enum YtDlpArguments {
    /// The progress template the downloader passes (parsed back by `YtDlpProgressParser`).
    static var progressTemplate: String { YtDlpProgressParser.template }

    /// argv (without the executable) for `yt-dlp -J`: info only, no download.
    /// `flatPlaylist` lists the entries of a playlist / channel cheaply (a single video still returns its full information).
    /// By default a link to one video inside a list means that one video (`--no-playlist`); `wholePlaylist` asks for the list instead.
    static func infoArguments(url: URL, flatPlaylist: Bool, cookies: CookieBrowser, jsRuntime: JSRuntime?, wholePlaylist: Bool = false,
                              supportsJSRuntimes: Bool = true) -> [String] {
        var a = commonArguments(jsRuntime: jsRuntime, supportsJSRuntimes: supportsJSRuntimes)
        a += ["-J", "--no-warnings", "--socket-timeout", "30"]
        a.append(wholePlaylist ? "--yes-playlist" : "--no-playlist")
        if flatPlaylist { a.append("--flat-playlist") }
        if let c = cookies.ytDlpName { a += ["--cookies-from-browser", c] }
        a += ["--", url.absoluteString]
        return a
    }

    /// yt-dlp's cache (signature / player data) lives inside the app's own folder, never in ~/.cache.
    static var cacheDirectory: URL { AppPaths.supportDir.appendingPathComponent("yt-dlp-cache", isDirectory: true) }

    /// Arguments shared by every invocation: no user config file (deterministic), the app's own cache folder, the JS runtime for YouTube.
    static func commonArguments(jsRuntime: JSRuntime?, supportsJSRuntimes: Bool = true) -> [String] {
        var a = ["--ignore-config", "--cache-dir", cacheDirectory.path]
        if let rt = jsRuntime, supportsJSRuntimes { a += ["--js-runtimes", rt.argument] }
        return a
    }

    /// argv (without the executable) for a download.
    /// Always: `--newline` + `--progress-template`, `-P` home and temp, `-o`, `--no-overwrites --continue` (resume), `--print-to-file after_move:filepath`
    /// when `resultListFile` is set, the URL last after `--`. Present only when asked for: `--ffmpeg-location`, `--js-runtimes`, `--cookies-from-browser`,
    /// `--limit-rate`, `--download-sections`, subtitle options, `--embed-metadata` / `--embed-thumbnail`, `-x --audio-format`, playlist options.
    static func downloadArguments(_ request: DownloadRequest, ffmpegDirectory: URL?, jsRuntime: JSRuntime?, supportsJSRuntimes: Bool = true) throws -> [String] {
        if let r = LinkParsing.rejection(for: request.url) { throw ConversionError.message(r.message) }
        guard isSafeTemplate(request.filenameTemplate) else {
            throw ConversionError.message(L10n("The file name template is not allowed (it must stay inside the download folder).",
                                               "Шаблон имени файла недопустим (файл должен оставаться в папке загрузки)."))
        }
        // yt-dlp expands $VARIABLES inside -P paths, so a folder name with "$" cannot be passed safely.
        guard request.outputDirectory.isFileURL, request.outputDirectory.path.hasPrefix("/"), !request.outputDirectory.path.contains("$"),
              !(request.workDirectory?.path.contains("$") ?? false) else {
            throw ConversionError.message(L10n("The download folder must be a full path without a $ sign.", "Папка загрузки должна быть указана полным путём без знака $."))
        }
        var a = commonArguments(jsRuntime: jsRuntime, supportsJSRuntimes: supportsJSRuntimes)
        a += ["--newline", "--progress", "--progress-template", YtDlpProgressParser.template]
        a += ["--no-overwrites", "--continue", "--no-mtime", "--socket-timeout", "30", "--retries", "5", "--fragment-retries", "5"]
        if let ff = ffmpegDirectory { a += ["--ffmpeg-location", ff.path] }
        a += ["-P", "home:" + request.outputDirectory.path]
        a += ["-P", "temp:" + (request.workDirectory ?? request.outputDirectory).path]
        a += ["-o", request.filenameTemplate]
        if let list = request.resultListFile { a += ["--print-to-file", "after_move:filepath", list.path.replacingOccurrences(of: "%", with: "%%")] }

        // What to download
        let selector = request.formatSelector ?? FormatSelector.expression(for: request.mode, maxHeight: request.maxHeight)
        a += ["-f", selector]
        if request.mode.isAudioOnly {
            let fmt = request.mode == .audioMP3 ? DownloadAudioFormat.mp3 : request.audioFormat
            a += ["-x", "--audio-format", fmt.rawValue, "--audio-quality", request.audioQuality > 0 ? "\(request.audioQuality)K" : "0"]
        } else {
            a += ["--merge-output-format", "mp4/mkv"]
        }

        // Playlist
        switch request.playlistItems {
        case nil: a.append("--no-playlist")
        case let items?:
            a.append("--yes-playlist")
            if !items.isEmpty {
                guard isSafePlaylistItems(items) else {
                    throw ConversionError.message(L10n("Playlist items must look like 1,3,5-7.", "Номера в плейлисте должны выглядеть так: 1,3,5-7."))
                }
                a += ["--playlist-items", items]
            }
        }

        // Part of the video
        if request.sectionStart != nil || request.sectionEnd != nil {
            // Cuts snap to the nearest keyframe: fast and lossless (an exact cut would re-encode the whole section).
            a += ["--download-sections", sectionArgument(start: request.sectionStart, end: request.sectionEnd)]
        }

        // Subtitles
        if request.subtitles != .none {
            let langs = request.subtitleLanguages.filter(isSafeLanguage)
            a += ["--write-subs", "--write-auto-subs", "--sub-langs", (langs.isEmpty ? ["en"] : langs).joined(separator: ",")]
            switch request.subtitles {
            case .soft: a.append("--embed-subs")
            case .external, .burn: a += ["--convert-subs", "srt"]     // burn: the convert stage draws the .srt into the picture
            case .none: break
            }
        }

        // Metadata, picture, network
        if request.embedMetadata { a += ["--embed-metadata", "--embed-chapters"] }
        if request.embedThumbnail { a += ["--embed-thumbnail", "--convert-thumbnails", "jpg"] }
        if let c = request.cookies.ytDlpName { a += ["--cookies-from-browser", c] }
        if request.rateLimitKBps > 0 { a += ["--limit-rate", "\(request.rateLimitKBps)K"] }
        if request.concurrentFragments > 1 { a += ["--concurrent-fragments", "\(min(request.concurrentFragments, 8))"] }

        a += ["--", request.url.absoluteString]
        return a
    }

    // MARK: Validation

    /// True when the output template cannot escape the directory: no "..", no leading "/" or "~", no NUL / control characters,
    /// not empty, and it must name a file (no trailing "/").
    static func isSafeTemplate(_ template: String) -> Bool {
        let t = template.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 400 else { return false }
        if t.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("\\") || t.hasSuffix("/") { return false }
        if t.contains("\\") { return false }
        for part in t.split(separator: "/", omittingEmptySubsequences: false) where part == ".." || part == "." { return false }
        // A field value can never add a "..": yt-dlp sanitises "/" inside values. Absolute-looking expansions are blocked by the checks above.
        return true
    }

    /// "1,3,5-7" (also "2-" and "3:" slices): digits, commas, dashes and colons only.
    static func isSafePlaylistItems(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && s.allSatisfy { $0.isNumber || ",-:".contains($0) } && s.first.map { $0.isNumber || $0 == "-" } == true
    }

    /// Language codes for `--sub-langs`: letters, digits, "-", "_" and the wildcard "*".
    static func isSafeLanguage(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 24 && s.allSatisfy { $0.isLetter || $0.isNumber || "-_*".contains($0) } && !s.hasPrefix("-")
    }

    /// `*10-20` (seconds); an open end is `inf`, an open start is 0.
    static func sectionArgument(start: Double?, end: Double?) -> String {
        func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.3f", v) }
        let s = max(0, start ?? 0)
        let e = end.map { fmt(max($0, s)) } ?? "inf"
        return "*\(fmt(s))-\(e)"
    }
}
