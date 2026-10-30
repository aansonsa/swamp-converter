import Foundation

// yt-dlp output lines -> progress. Pure: no process, no UI.
//
// Two sources: our own `--progress-template` lines ("SC|downloading|<bytes>|<total>|<estimate>|<speed>|<eta>|<index>|<count>"), which are
// exact, and the plain "[download] ..." / "[Merger] ..." lines, used for phases and as a fallback when the template is missing.

enum YtDlpProgressParser {
    /// The `--progress-template` the downloader passes (parsed back by `parse`).
    static let template = "download:SC|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.playlist_autonumber)s|%(info.n_entries)s"

    /// One stdout line -> progress (templated lines, plus the plain "[Merger]", "[ExtractAudio]", "[EmbedThumbnail]", "[download] Destination:" lines).
    /// nil for lines that carry no progress. "NA" values are nil. Never crashes on unexpected text.
    static func parse(line: String) -> DownloadProgress? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("download:") { text.removeFirst("download:".count) }
        if text.hasPrefix("SC|") { return parseTemplated(text) }
        guard text.hasPrefix("[") else { return nil }

        if text.hasPrefix("[download]") {
            let rest = text.dropFirst("[download]".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("Destination:") {
                return DownloadProgress(phase: .downloading, fraction: nil, fileName: lastComponent(of: String(rest.dropFirst("Destination:".count))))
            }
            if rest.hasPrefix("Resuming download") { return DownloadProgress(phase: .downloading) }
            if rest.hasPrefix("Downloading item") || rest.hasPrefix("Downloading video") { return parseItemLine(text) }
            if rest.hasPrefix("Downloading") { return DownloadProgress(phase: .fetchingInfo) }
            if rest.contains("has already been downloaded") { return DownloadProgress(phase: .finished, fraction: 1) }
            return parsePlainPercent(rest)
        }
        if text.hasPrefix("[Merger]") || text.hasPrefix("[VideoRemuxer]") || text.hasPrefix("[VideoConvertor]") || text.hasPrefix("[FixupM3u8]") {
            return DownloadProgress(phase: .merging, fileName: quotedPath(in: text).map(lastComponent(of:)))
        }
        if text.hasPrefix("[ExtractAudio]") { return DownloadProgress(phase: .extractingAudio, fileName: destinationPath(in: text).map(lastComponent(of:))) }
        for tag in ["[EmbedThumbnail]", "[Metadata]", "[EmbedSubtitle]", "[ThumbnailsConvertor]", "[SubtitlesConvertor]", "[FixupM4a]", "[FixupM4v]", "[EmbedChapters]", "[ModifyChapters]"]
        where text.hasPrefix(tag) { return DownloadProgress(phase: .embedding) }
        if text.hasPrefix("[MoveFiles]") { return DownloadProgress(phase: .finished, fraction: 1, fileName: quotedPaths(in: text).last.map(lastComponent(of:))) }
        for tag in ["[info]", "[youtube]", "[generic]", "[youtube:tab]", "[youtube:playlist]"] where text.hasPrefix(tag) {
            return DownloadProgress(phase: .fetchingInfo)
        }
        return nil
    }

    /// "[download] Destination: /path/file.f137.mp4" / "[Merger] Merging formats into "/path/file.mkv"" / "[ExtractAudio] Destination: /p/f.m4a"
    /// / "[MoveFiles] Moving file "a" to "b"" (the second path) -> the path, for the result list. nil for other lines.
    static func destinationPath(in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[MoveFiles]") { return quotedPaths(in: t).last }
        if t.hasPrefix("[Merger]") { return quotedPath(in: t) }
        for tag in ["[download] Destination:", "[ExtractAudio] Destination:"] where t.hasPrefix(tag) {
            let p = t.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? nil : String(p)
        }
        return nil
    }

    // MARK: Templated lines

    private static func parseTemplated(_ text: String) -> DownloadProgress? {
        let f = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7 else { return nil }
        let status = f[1]
        let downloaded = int64(f[2]), exact = int64(f[3]), estimate = int64(f[4])
        let total = exact ?? estimate
        var fraction: Double? = nil
        if let d = downloaded, let t = total, t > 0 { fraction = min(1, max(0, Double(d) / Double(t))) }
        if status == "finished" { fraction = 1 }
        var p = DownloadProgress(phase: .downloading, fraction: fraction, downloadedBytes: downloaded, totalBytes: total,
                                 bytesPerSecond: double(f[5]), eta: double(f[6]))
        if f.count > 7 { p.itemIndex = int(f[7]) }
        if f.count > 8 { p.itemCount = int(f[8]) }
        return p
    }

    private static func na(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == "NA" || t == "None" || t == "nan") ? nil : t
    }
    private static func double(_ s: String) -> Double? { na(s).flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } }
    private static func int64(_ s: String) -> Int64? { double(s).map { Int64($0.rounded()) } }
    private static func int(_ s: String) -> Int? { double(s).map { Int($0.rounded()) } }

    // MARK: Plain lines

    /// "[download]  45.3% of ~ 10.00MiB at  1.20MiB/s ETA 00:05 (frag 3/20)"
    private static func parsePlainPercent(_ rest: String) -> DownloadProgress? {
        guard let pr = rest.range(of: "^[0-9]+(\\.[0-9]+)?%", options: .regularExpression) else { return nil }
        let pct = Double(rest[pr].dropLast()) ?? 0
        var p = DownloadProgress(phase: .downloading, fraction: min(1, pct / 100))
        if let of = rest.range(of: "of\\s+~?\\s*([0-9.]+)\\s*([KMGT]?i?B)", options: .regularExpression) {
            p.totalBytes = sizeBytes(String(rest[of]).replacingOccurrences(of: "of", with: "").replacingOccurrences(of: "~", with: ""))
        }
        if let at = rest.range(of: "at\\s+([0-9.]+)\\s*([KMGT]?i?B)/s", options: .regularExpression) {
            p.bytesPerSecond = sizeBytes(String(rest[at]).replacingOccurrences(of: "at", with: "").replacingOccurrences(of: "/s", with: "")).map(Double.init)
        }
        if let etaR = rest.range(of: "ETA\\s+([0-9:]+)", options: .regularExpression) {
            let parts = rest[etaR].replacingOccurrences(of: "ETA", with: "").trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
            p.eta = parts.reduce(0) { $0 * 60 + $1 }
        }
        if let t = p.totalBytes, let f = p.fraction { p.downloadedBytes = Int64(Double(t) * f) }
        return p
    }

    /// "10.00MiB" -> bytes (binary units as yt-dlp prints them).
    static func sizeBytes(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: "^[0-9]+(\\.[0-9]+)?", options: .regularExpression), let v = Double(t[r]) else { return nil }
        let unit = t[r.upperBound...].trimmingCharacters(in: .whitespaces).uppercased()
        let mult: Double
        switch unit {
        case "B", "": mult = 1
        case "KIB", "KB": mult = 1024
        case "MIB", "MB": mult = 1024 * 1024
        case "GIB", "GB": mult = 1024 * 1024 * 1024
        case "TIB", "TB": mult = 1024.0 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(v * mult)
    }

    /// "[download] Downloading item 2 of 5" / "[download] Downloading video 2 of 5"
    private static func parseItemLine(_ text: String) -> DownloadProgress? {
        guard let r = text.range(of: "(item|video)\\s+([0-9]+)\\s+of\\s+([0-9]+)", options: .regularExpression) else { return nil }
        let nums = text[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count == 2 else { return nil }
        var p = DownloadProgress(phase: .fetchingInfo)
        p.itemIndex = nums[0]; p.itemCount = nums[1]
        return p
    }

    private static func quotedPaths(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let a = rest.firstIndex(of: "\"") {
            let after = rest.index(after: a)
            guard let b = rest[after...].firstIndex(of: "\"") else { break }
            out.append(String(rest[after..<b]))
            rest = rest[rest.index(after: b)...]
        }
        return out
    }
    private static func quotedPath(in text: String) -> String? { quotedPaths(in: text).first }
    private static func lastComponent(of path: String) -> String { (path.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent }
}

/// Turns the per-file fractions of yt-dlp into ONE monotone fraction for the whole download stage.
///
/// A DASH video arrives as two files (video, then audio), each running 0 to 100 percent; a playlist adds one more level. The mapper weights
/// the files by their expected size, counts files by `[download] Destination:` lines, and never goes backwards.
struct DownloadProgressMapper: Sendable {
    /// Relative sizes of the files of ONE video in download order (e.g. [0.9, 0.1]). One entry for a single file.
    var parts: [Double]
    /// Items of a playlist (1 for a single video); `itemCount` of the progress lines overrides it.
    var items: Int
    /// Share of the stage the post-download steps (merge, extract, embed) take: progress stops there until the run ends.
    var finishingShare = 0.04

    private var partIndex = -1
    /// Ordinal (1-based) of the item being downloaded among the SELECTED ones: `%(info.playlist_autonumber)s` and "Downloading item N of M" both
    /// count that way, unlike `playlist_index`, which is the position in the whole list ("1,3" would give 1 then 3 of 2).
    private var currentItem = 1
    private var last = 0.0
    private(set) var phase: DownloadProgress.Phase = .fetchingInfo

    init(parts: [Double] = [1], items: Int = 1) {
        let total = parts.reduce(0, +)
        self.parts = total > 0 ? parts.map { $0 / total } : [1]
        self.items = max(1, items)
    }

    /// Feeds one parsed line; returns the overall fraction 0...1 (nil = still unknown / indeterminate).
    mutating func feed(_ p: DownloadProgress) -> Double? {
        if let c = p.itemCount, c > 0 { items = c }
        if let i = p.itemIndex, i > 0, min(i, items) != currentItem { currentItem = min(i, items); partIndex = -1 }
        switch p.phase {
        case .fetchingInfo: phase = .fetchingInfo; return nil
        case .merging, .extractingAudio, .embedding:
            phase = p.phase
            return bump(itemBase() + (1.0 / Double(items)) * (1 - finishingShare))
        case .finished:
            phase = .finished
            return bump(itemBase() + (1.0 / Double(items)) * (1 - finishingShare))
        case .downloading:
            phase = .downloading
            if p.fileName != nil && p.fraction == nil && p.downloadedBytes == nil {   // "[download] Destination:" opens the next file
                partIndex += 1
                return bump(fraction(part: min(partIndex, parts.count - 1), within: 0))
            }
            if partIndex < 0 { partIndex = 0 }
            guard let f = p.fraction else { return nil }
            return bump(fraction(part: min(partIndex, parts.count - 1), within: f))
        }
    }

    private func itemBase() -> Double { Double(currentItem - 1) / Double(items) }

    private func fraction(part: Int, within f: Double) -> Double {
        let before = parts[0..<part].reduce(0, +)
        let inVideo = (before + parts[part] * f) * (1 - finishingShare)
        return itemBase() + inVideo / Double(items)
    }

    private mutating func bump(_ v: Double) -> Double {
        last = max(last, min(max(v, 0), 1))
        return last
    }
}
