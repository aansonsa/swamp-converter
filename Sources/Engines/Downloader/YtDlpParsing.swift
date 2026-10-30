import Foundation

// Pure parsers around yt-dlp. No process, no network: everything here is covered by golden tests with the JSON fixtures.
// (Selectors: FormatSelector.swift. Arguments: YtDlpArguments.swift. Progress lines: YtDlpProgress.swift.)

enum YtDlpInfoParser {
    /// `yt-dlp -J --no-warnings <url>` (one JSON object) -> DownloadInfo. Playlists (`_type: "playlist"`) fill `entries`.
    /// Tolerant: missing fields stay nil, unknown fields are ignored, null playlist entries (unavailable videos) are skipped but keep their
    /// numbering; throws `ConversionError.message` for non-JSON / error output.
    static func parse(json: Data) throws -> DownloadInfo {
        guard let obj = jsonObject(from: json) else {
            throw ConversionError.message(L10n("The site’s answer could not be read. Try again, or update yt-dlp in Settings > Downloader.",
                                               "Ответ сайта не удалось прочитать. Повторите попытку или обновите yt-dlp в Настройки > Загрузка."))
        }
        let id = string(obj["id"]) ?? ""
        let type = string(obj["_type"])
        let rawEntries = obj["entries"] as? [Any]
        let isPlaylist = type == "playlist" || type == "multi_video" || rawEntries != nil && obj["formats"] == nil
        guard let page = url(from: obj["webpage_url"]) ?? url(from: obj["original_url"]) ?? url(from: obj["url"]) else {
            throw ConversionError.message(L10n("The answer has no address of the page.", "В ответе нет адреса страницы."))
        }
        var info = DownloadInfo(id: id, webpageURL: page, title: string(obj["title"]) ?? string(obj["fulltitle"]) ?? (id.isEmpty ? page.host ?? "" : id))
        info.channel = string(obj["channel"]) ?? string(obj["uploader"]) ?? string(obj["creator"])
        info.duration = number(obj["duration"])
        info.thumbnail = url(from: obj["thumbnail"]) ?? thumbnails(obj["thumbnails"])
        info.uploadDate = string(obj["upload_date"])
        info.extractor = string(obj["extractor_key"]) ?? string(obj["extractor"])
        let liveStatus = string(obj["live_status"])
        info.isLive = (obj["is_live"] as? Bool) == true || liveStatus == "is_live"
        if isPlaylist {
            info.isListing = true
            info.entries = playlistEntries(rawEntries ?? [], fallbackChannel: info.channel)
            return info
        }
        info.formats = (obj["formats"] as? [[String: Any]] ?? []).compactMap(format(from:))
        info.subtitles = subtitleTracks(obj["subtitles"], automatic: false) + subtitleTracks(obj["automatic_captions"], automatic: true)
        info.chapters = (obj["chapters"] as? [[String: Any]] ?? []).compactMap { c in
            guard let s = number(c["start_time"]), let e = number(c["end_time"]) else { return nil }
            return MediaChapterInfo(start: s, end: e, title: string(c["title"]) ?? "")
        }
        // A page whose only "format" is a direct file (generic extractor) lists its URL at the top level.
        if info.formats.isEmpty, obj["url"] != nil, let ext = string(obj["ext"]) {
            info.formats = [DownloadFormat(id: string(obj["format_id"]) ?? "0", ext: ext, vcodec: string(obj["vcodec"]) ?? "unknown", acodec: string(obj["acodec"]) ?? "unknown",
                                           width: int(obj["width"]), height: int(obj["height"]), fps: number(obj["fps"]),
                                           dynamicRange: string(obj["dynamic_range"]), filesize: int64(obj["filesize"]), filesizeApprox: int64(obj["filesize_approx"]),
                                           tbr: number(obj["tbr"]), note: nil)]
        }
        return info
    }

    // MARK: JSON helpers

    /// yt-dlp may print warnings before the JSON on stdout in rare cases: parse from the first "{".
    private static func jsonObject(from data: Data) -> [String: Any]? {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return o }
        guard let start = data.firstIndex(of: UInt8(ascii: "{")), start > data.startIndex else { return nil }
        return (try? JSONSerialization.jsonObject(with: data[start...])) as? [String: Any]
    }
    private static func string(_ v: Any?) -> String? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }   // numeric ids
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    private static func int(_ v: Any?) -> Int? { number(v).map { Int($0.rounded()) } }
    private static func int64(_ v: Any?) -> Int64? { number(v).map { Int64($0.rounded()) } }
    private static func url(from v: Any?) -> URL? {
        guard let s = string(v), let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }
    private static func thumbnails(_ v: Any?) -> URL? {
        guard let list = v as? [[String: Any]] else { return nil }
        // Entries are ordered worst to best.
        return list.reversed().lazy.compactMap { url(from: $0["url"]) }.first
    }

    private static func format(from f: [String: Any]) -> DownloadFormat? {
        guard let id = string(f["format_id"]) else { return nil }
        let ext = string(f["ext"]) ?? ""
        let protocolName = string(f["protocol"])
        let note = string(f["format_note"])
        // Storyboards (thumbnail sheets) and anything that is neither video nor audio are not downloadable media.
        if ext == "mhtml" || protocolName == "mhtml" || note == "storyboard" { return nil }
        let height = int(f["height"]), width = int(f["width"])
        let vcodecRaw = string(f["vcodec"]), acodecRaw = string(f["acodec"])
        if vcodecRaw == "none" && acodecRaw == "none" { return nil }
        let vcodec = vcodecRaw ?? ((height != nil || width != nil) ? "unknown" : "none")
        let acodec = acodecRaw ?? (vcodec == "none" ? "unknown" : (string(f["audio_ext"]) == "none" ? "none" : "unknown"))
        var out = DownloadFormat(id: id, ext: ext, vcodec: vcodec, acodec: acodec, width: width, height: height, fps: number(f["fps"]),
                                 dynamicRange: string(f["dynamic_range"]), filesize: int64(f["filesize"]), filesizeApprox: int64(f["filesize_approx"]),
                                 tbr: number(f["tbr"]) ?? number(f["abr"]).map { $0 + (number(f["vbr"]) ?? 0) }, note: note)
        out.language = string(f["language"])
        out.hasDRM = (f["has_drm"] as? Bool) == true || (note?.localizedCaseInsensitiveContains("drm") ?? false)
        return out
    }

    private static func subtitleTracks(_ v: Any?, automatic: Bool) -> [DownloadSubtitleTrack] {
        guard let dict = v as? [String: Any] else { return [] }
        var out: [DownloadSubtitleTrack] = []
        for key in dict.keys.sorted() where key != "live_chat" {
            let variants = dict[key] as? [[String: Any]]
            out.append(DownloadSubtitleTrack(language: key, name: variants?.lazy.compactMap { string($0["name"]) }.first, isAutomatic: automatic))
        }
        return out
    }

    private static func playlistEntries(_ raw: [Any], fallbackChannel: String?) -> [PlaylistEntry] {
        var out: [PlaylistEntry] = []
        for (i, item) in raw.enumerated() {
            guard let e = item as? [String: Any] else { continue }   // null = unavailable video: skipped, numbering kept
            let id = string(e["id"]) ?? ""
            var link = url(from: e["url"]) ?? url(from: e["webpage_url"])
            if link == nil, !id.isEmpty, (string(e["ie_key"]) ?? string(e["extractor_key"]))?.lowercased() == "youtube" {
                link = URL(string: "https://www.youtube.com/watch?v=\(id)")
            }
            guard link != nil || !id.isEmpty else { continue }
            out.append(PlaylistEntry(index: int(e["playlist_index"]) ?? i + 1, id: id,
                                     title: string(e["title"]) ?? (id.isEmpty ? L("Untitled", "Без названия") : id),
                                     url: link, duration: number(e["duration"]), thumbnail: url(from: e["thumbnail"]) ?? thumbnails(e["thumbnails"]),
                                     channel: string(e["channel"]) ?? string(e["uploader"]) ?? fallbackChannel))
        }
        return out
    }

    // MARK: Friendly messages

    /// Maps yt-dlp's stderr to a calm localised sentence: unsupported URL / "no video on this page", private video, sign-in required
    /// (offer cookies), geo-blocked, DRM-protected (cannot be downloaded: no circumvention), age-gated, live not started, network down.
    /// Unknown messages are passed through shortened.
    static func friendlyMessage(forStderr text: String) -> L10n {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let errorLines = lines.filter { $0.hasPrefix("ERROR:") }
        let main = (errorLines.last ?? lines.last(where: { !$0.isEmpty }) ?? "")
        let haystack = (errorLines.isEmpty ? lines : errorLines).joined(separator: " ").lowercased()
        let all = lines.joined(separator: " ").lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { haystack.contains($0) } }

        if has("drm protected", "protected by drm", "drm-protected", "uses drm", "has drm", "with drm", "drm content") { return L10n("This video is protected by DRM and can’t be downloaded.", "Это видео защищено DRM, его нельзя скачать.") }
        if has("private video", "video is private") {
            return L10n("This video is private. It can only be downloaded if you are signed in to an account that may watch it: pick your browser under Settings > Downloader > Cookies.",
                        "Это видео закрытое. Скачать его можно только из аккаунта с доступом: выберите браузер в Настройки > Загрузка > Cookies.")
        }
        if has("confirm your age", "age-restricted", "age restricted", "inappropriate for some users") {
            return L10n("This video is age-restricted. Pick your browser under Settings > Downloader > Cookies so the app can use your sign-in, then try again.",
                        "У видео возрастное ограничение. Выберите браузер в Настройки > Загрузка > Cookies, чтобы приложение использовало ваш вход, и повторите.")
        }
        if has("sign in", "log in", "login required", "authentication", "--cookies", "members-only", "members only") {
            return L10n("This site asks you to sign in. Pick the browser you are signed in with under Settings > Downloader > Cookies, then try again.",
                        "Сайт просит войти в аккаунт. Выберите браузер, где вы вошли, в Настройки > Загрузка > Cookies и повторите.")
        }
        if has("not made this video available in your country", "geo restrict", "geo-restrict", "blocked it in your country", "not available in your country", "available in your country") {
            return L10n("This video is not available in your country.", "Это видео недоступно в вашей стране.")
        }
        if has("premieres in", "will begin in", "live event will begin", "this live event", "premiere will begin", "is upcoming") {
            return L10n("This live stream or premiere has not started yet. Try again once it has begun.", "Эта трансляция или премьера ещё не началась. Повторите, когда она начнётся.")
        }
        if has("unsupported url") {
            return L10n("There is no video on this page that can be downloaded.", "На этой странице нет видео, которое можно скачать.")
        }
        if has("http error 404", "404: not found", "does not exist", "has been removed", "video unavailable", "no longer available", "this video is unavailable", "been terminated") {
            return L10n("This video is not available any more, or the address is wrong.", "Это видео больше недоступно, либо адрес неверный.")
        }
        if has("http error 429", "too many requests") {
            return L10n("The site is limiting requests right now. Wait a few minutes and try again.", "Сайт сейчас ограничивает запросы. Подождите несколько минут и повторите.")
        }
        if has("http error 403", "forbidden") {
            return L10n("The site refused the download (error 403). Try again later, update yt-dlp, or sign in through Settings > Downloader > Cookies.",
                        "Сайт отказал в загрузке (ошибка 403). Повторите позже, обновите yt-dlp или войдите через Настройки > Загрузка > Cookies.")
        }
        if has("requested format is not available", "no video formats found", "only images are available") {
            if all.contains("javascript runtime") || all.contains("n challenge") || all.contains("signature solving") {
                return L10n("YouTube needs a JavaScript runtime to offer this video. \(JSRuntimeAdvice.explanation.en)", "Для этого видео YouTube нужен JavaScript-движок. \(JSRuntimeAdvice.explanation.ru)")
            }
            return L10n("The chosen quality is not available for this video. Pick another one, or use Best for Apple.", "Выбранное качество для этого видео недоступно. Выберите другое или «Лучшее для Apple».")
        }
        if all.contains("no supported javascript runtime") && has("error") {
            return L10n(JSRuntimeAdvice.explanation.en, JSRuntimeAdvice.explanation.ru)
        }
        if has("no space left", "disk full", "not enough space") {
            return L10n("The disk is full. Free up space or choose another folder in Settings > Downloader.", "Диск заполнен. Освободите место или выберите другую папку в Настройки > Загрузка.")
        }
        if has("operation not permitted") && all.contains("cookie") {
            return L10n("The app may not read the browser’s cookies. Give it Full Disk Access in System Settings > Privacy & Security, or choose another browser.",
                        "Приложению не разрешено читать cookies браузера. Дайте ему «Полный доступ к диску» в Системные настройки > Конфиденциальность и безопасность или выберите другой браузер.")
        }
        if has("no such option") {
            return L10n("This version of yt-dlp is too old for the app. Update it in Settings > Downloader.", "Эта версия yt-dlp слишком старая для приложения. Обновите её в Настройки > Загрузка.")
        }
        if has("ffmpeg", "ffprobe") && has("not found", "not installed", "not available", "required") {
            return L10n("ffmpeg is needed to join video and sound. Install it (brew install ffmpeg) and try again.", "Для склейки видео и звука нужен ffmpeg. Установите его (brew install ffmpeg) и повторите.")
        }
        if has("unable to download webpage", "urlopen error", "name or service not known", "nodename nor servname", "network is unreachable", "timed out",
               "connection reset", "temporary failure in name resolution", "getaddrinfo", "connection refused", "ssl:", "remote end closed", "unable to download video data") {
            return L10n("Could not reach the site. Check the internet connection and try again.", "Не удалось связаться с сайтом. Проверьте подключение к интернету и повторите.")
        }
        // Unknown: pass the message through, shortened and without the "ERROR: [site] id:" prefix.
        var msg = main
        if msg.hasPrefix("ERROR:") { msg.removeFirst(6) }
        msg = msg.trimmingCharacters(in: .whitespaces)
        if msg.hasPrefix("["), let close = msg.firstIndex(of: "]") { msg = String(msg[msg.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
        if let colon = msg.firstIndex(of: ":"), msg[msg.startIndex..<colon].count <= 16, !msg[msg.startIndex..<colon].contains(" ") { msg = String(msg[msg.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        if msg.isEmpty { return L10n("The link could not be downloaded.", "Не удалось скачать по ссылке.") }
        if msg.count > 220 { msg = String(msg.prefix(220)) + "..." }
        return L10n("The site reported: \(msg)", "Сайт сообщил: \(msg)")
    }
}
