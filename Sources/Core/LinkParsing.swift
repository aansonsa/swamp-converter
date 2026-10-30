import Foundation

// Pure URL handling for the link features: find links in free text (selected text, clipboard, a dragged string), decide which
// ones may be handed to the downloader, strip tracking noise and compute a canonical identity for de-duplication.
// No network, no UI, no global state: every function is a pure function of its arguments and is covered by Core self-tests.
//
// Security posture (the downloader and the URL scheme depend on it):
//  * only http(s) is ever downloadable; javascript:, file:, data:, ftp:, ssh:, custom schemes are rejected
//  * no credentials inside the URL (user:pass@host), no control characters or spaces, at most 2048 characters
//  * a host must look like a public host: it needs a dot, and loopback / link-local / private IP literals are refused

enum LinkRejection: Error, Equatable, Sendable {
    case empty
    case malformed
    case tooLong
    case unsupportedScheme(String)
    case noHost
    case credentialsInURL
    case privateHost(String)

    /// Calm localised sentence for the toast / banner.
    var message: L10n {
        switch self {
        case .empty: return L10n("There is no link here.", "Здесь нет ссылки.")
        case .malformed: return L10n("This doesn’t look like a web address.", "Это не похоже на веб-адрес.")
        case .tooLong: return L10n("This web address is too long.", "Этот веб-адрес слишком длинный.")
        case .unsupportedScheme(let s):
            return L10n("Links of type \(s): can’t be downloaded. Only http and https links work.",
                        "Ссылки вида \(s): скачать нельзя. Работают только ссылки http и https.")
        case .noHost: return L10n("The web address has no site name.", "В веб-адресе нет имени сайта.")
        case .credentialsInURL: return L10n("Links that contain a user name or password are not accepted.", "Ссылки с именем пользователя или паролем не принимаются.")
        case .privateHost(let h): return L10n("\(h) is an address on this network or this Mac, not a public site.", "\(h) — адрес в локальной сети или на этом Mac, а не публичный сайт.")
        }
    }
}

enum LinkParsing {
    static let maxLength = 2048
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Query parameters that only track the sender, never change the video. (`t`, `v`, `list`, `index` are kept.)
    static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "utm_name",
        "fbclid", "gclid", "dclid", "msclkid", "igshid", "igsh", "mc_cid", "mc_eid", "si", "feature", "pp", "ref_src", "ref_url", "spm", "share_id"
    ]

    // MARK: Extraction

    /// All web links in `text`, in order of appearance, trimmed of the punctuation that surrounds links in prose
    /// ("see https://a.com/x." -> https://a.com/x), de-duplicated, NOT yet validated. A bare `www.` address gets `https://`.
    static func extractURLs(from text: String) -> [URL] {
        guard !text.isEmpty else { return [] }
        let pattern = "(?i)(?:https?://|www\\.)[^\\s<>\"'`\u{00A0}\u{200B}]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [URL] = []
        var seen = Set<String>()
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = trimTrailingPunctuation(ns.substring(with: m.range))
            if raw.lowercased().hasPrefix("www.") { raw = "https://" + raw }
            guard let url = URL(string: raw), seen.insert(url.absoluteString).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// Removes sentence punctuation and unbalanced closing brackets from the end of a matched link.
    /// Balanced pairs survive: "https://en.wikipedia.org/wiki/Swamp_(film)" keeps its ")", "(https://a.com/x)" loses it.
    static func trimTrailingPunctuation(_ s: String) -> String {
        var chars = Array(s)
        let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        let plain: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\u{201D}", "\u{2019}", "\u{00BB}", "*", "_"]
        while let last = chars.last {
            if plain.contains(last) { chars.removeLast(); continue }
            if let open = closers[last] {
                let opens = chars.filter { $0 == open }.count
                let closes = chars.filter { $0 == last }.count
                if closes > opens { chars.removeLast(); continue }
            }
            break
        }
        return String(chars)
    }

    /// If the text is a single token with a non-web scheme ("javascript:alert(1)", "file:///etc/passwd"), the rejection to show.
    /// nil for text that contains no scheme-looking prefix or an http(s) one.
    static func schemeRejection(forText text: String) -> LinkRejection? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9+.\\-]{1,30}):"),
              let m = regex.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else { return nil }
        let scheme = (t as NSString).substring(with: m.range(at: 1)).lowercased()
        return allowedSchemes.contains(scheme) ? nil : .unsupportedScheme(scheme)
    }

    // MARK: Validation

    /// nil = the URL may be downloaded. Otherwise why not.
    static func rejection(for url: URL) -> LinkRejection? {
        let s = url.absoluteString
        if s.isEmpty { return .empty }
        if s.count > maxLength { return .tooLong }
        if s.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) || s.contains(" ") { return .malformed }
        guard let scheme = url.scheme?.lowercased() else { return .malformed }
        guard allowedSchemes.contains(scheme) else { return .unsupportedScheme(scheme) }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host?.lowercased(), !host.isEmpty else { return .noHost }
        if comps.user != nil || comps.password != nil { return .credentialsInURL }
        if isPrivateHost(host) { return .privateHost(host) }
        if !host.contains(".") && !host.contains(":") { return .privateHost(host) }
        return nil
    }

    static func isDownloadable(_ url: URL) -> Bool { rejection(for: url) == nil }

    /// Loopback, link-local, private-range IP literals, `.local` / `.internal` / `.lan` names and `localhost`.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        if h == "::1" || h == "::" || h.hasPrefix("fe80:") || h.hasPrefix("fc") && h.contains(":") || h.hasPrefix("fd") && h.contains(":") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        return false
    }

    // MARK: Normalisation and identity

    /// Lower-cased scheme and host, no fragment, tracking parameters removed (other parameters keep their order).
    static func normalized(_ url: URL, stripTracking: Bool = true) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.fragment = nil
        if stripTracking, let items = c.queryItems {
            let kept = items.filter { !trackingParameters.contains($0.name.lowercased()) }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        return c.url ?? url
    }

    /// Same video, same key: `youtu.be/ID`, `youtube.com/watch?v=ID`, `/shorts/ID`, `/embed/ID`, `/live/ID` -> "youtube:ID".
    /// Other sites: "host/path?sorted-query" without tracking parameters.
    static func canonicalKey(of url: URL) -> String {
        let n = normalized(url)
        guard let c = URLComponents(url: n, resolvingAgainstBaseURL: false), let rawHost = c.host else { return url.absoluteString }
        let host = displayHost(of: n)
        let path = c.path
        let q = c.queryItems ?? []
        func value(_ name: String) -> String? { q.first { $0.name == name }?.value }
        let youtubeHosts: Set<String> = ["youtube.com", "music.youtube.com", "youtube-nocookie.com", "gaming.youtube.com"]
        if host == "youtu.be" {
            let id = path.split(separator: "/").first.map(String.init) ?? ""
            if !id.isEmpty { return "youtube:" + id }
        } else if youtubeHosts.contains(host) {
            if let v = value("v"), !v.isEmpty { return "youtube:" + v }
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) { return "youtube:" + parts[1] }
            if let l = value("list"), !l.isEmpty { return "youtube:list:" + l }
        }
        let sorted = q.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let trimmedPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        _ = rawHost
        return host + trimmedPath + (sorted.isEmpty ? "" : "?" + sorted)
    }

    /// "youtube.com" for https://www.youtube.com/watch?v=x ; "m.", "mobile." and "www." prefixes are dropped.
    static func displayHost(of url: URL) -> String {
        var h = (url.host ?? url.absoluteString).lowercased()
        for p in ["www.", "m.", "mobile."] where h.hasPrefix(p) && h.dropFirst(p.count).contains(".") { h = String(h.dropFirst(p.count)); break }
        return h
    }

    // MARK: Convenience

    /// Links in free text that pass validation, normalised and de-duplicated by canonical identity. This is what the clipboard
    /// banner, the selected-text reader and `swamp download` use.
    static func downloadableLinks(in text: String, title: String? = nil, source: String? = nil) -> [LinkItem] {
        var seen = Set<String>()
        var out: [LinkItem] = []
        for u in extractURLs(from: text) {
            let n = normalized(u)
            guard isDownloadable(n), seen.insert(canonicalKey(of: n)).inserted else { continue }
            out.append(LinkItem(url: n, title: title, sourceName: source))
        }
        return out
    }

    /// Validates ONE address given as a URL string (URL scheme parameter, CLI argument, bookmarklet): returns the normalised URL or why not.
    static func validate(_ string: String) -> Result<URL, LinkRejection> {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(.empty) }
        if let r = schemeRejection(forText: t) { return .failure(r) }
        var candidate = t
        if candidate.lowercased().hasPrefix("www.") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate) else { return .failure(.malformed) }
        let n = normalized(url)
        if let r = rejection(for: n) { return .failure(r) }
        return .success(n)
    }

    /// First downloadable link of the text, or the reason the text has none (for the hint under the link field).
    static func firstDownloadable(in text: String) -> Result<LinkItem, LinkRejection> {
        if let first = downloadableLinks(in: text).first { return .success(first) }
        if let r = schemeRejection(forText: text) { return .failure(r) }
        // "see file:///tmp/x": a token with a non-web scheme explains better than "malformed".
        for token in text.split(whereSeparator: { $0.isWhitespace }) { if let r = schemeRejection(forText: String(token)) { return .failure(r) } }
        if let u = extractURLs(from: text).first, let r = rejection(for: normalized(u)) { return .failure(r) }
        return .failure(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .malformed)
    }
}
