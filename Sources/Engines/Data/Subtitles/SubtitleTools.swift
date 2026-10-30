import Foundation

// Timing and clean-up tools on cue arrays (pure). Used by the Studio fields of `subs.convert` and by the video module's "external subtitle" options.

enum SubtitleTools {
    private static let htmlTag = try! NSRegularExpression(pattern: #"</?[A-Za-z][^<>]*>|<\d[\d:.]*>"#)
    private static let assOverride = try! NSRegularExpression(pattern: #"\{\\[^}]*\}"#)

    /// Removes `<i>`, `</font>`, `<v Name>`, `<c.class>`, `<00:01.000>` and `{\an8}` style tags; text such as "a < b" or "I <3 you" is not a tag and stays.
    static func removeTags(in s: String, keepBraces: Bool = false) -> String {
        guard s.contains("<") || (!keepBraces && s.contains("{")) else { return s }
        var t = s
        var range = NSRange(location: 0, length: (t as NSString).length)
        t = htmlTag.stringByReplacingMatches(in: t, range: range, withTemplate: "")
        if !keepBraces {
            range = NSRange(location: 0, length: (t as NSString).length)
            t = assOverride.stringByReplacingMatches(in: t, range: range, withTemplate: "")
        }
        return t
    }

    // MARK: Hearing-impaired descriptions

    private static let bracketed = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^)]*\)"#)
    private static let speakerLabel = try! NSRegularExpression(pattern: #"^(?:- ?)?[A-ZА-ЯЁ][A-ZА-ЯЁ0-9 .'\-]{1,24}:\s+"#)

    /// Sound descriptions `[music]` `(door slams)`, music lines (♪ ♫ ♬) and ALL-CAPS speaker labels ("JOHN: ") removed; cues left without text are dropped.
    static func removeHearingImpairedText(in text: String) -> String {
        var kept: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.contains("♪") || line.contains("♫") || line.contains("♬") { continue }
            let r = NSRange(location: 0, length: (line as NSString).length)
            line = bracketed.stringByReplacingMatches(in: line, range: r, withTemplate: "")
            let r2 = NSRange(location: 0, length: (line as NSString).length)
            if let m = speakerLabel.firstMatch(in: line, range: r2) {
                let dash = line.hasPrefix("- ") ? "- " : (line.hasPrefix("-") ? "-" : "")
                line = dash + (line as NSString).substring(from: m.range.upperBound)
            }
            line = line.replacingOccurrences(of: "  +", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let letters = removeTags(in: line).unicodeScalars.contains { CharacterSet.letters.union(.decimalDigits).contains($0) }
            if !letters { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    // MARK: Cue arrays

    static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
    static func sec(_ ms: Int) -> Double { Double(ms) / 1000 }

    static func stripped(_ cues: [SubtitleCue], removeTags tags: Bool, removeHearingImpaired sdh: Bool) -> [SubtitleCue] {
        if !tags && !sdh { return cues }
        var out: [SubtitleCue] = []
        for var c in cues {
            if tags { c.text = removeTags(in: c.text) }
            if sdh { c.text = removeHearingImpairedText(in: c.text) }
            c.text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.text.isEmpty { continue }
            out.append(c)
        }
        return out
    }

    /// Moves every cue by `seconds` (negative = earlier). Cues that end at or before time zero disappear; a cue that starts before zero starts at zero.
    static func shifted(_ cues: [SubtitleCue], by seconds: Double) -> [SubtitleCue] {
        if seconds == 0 { return cues }
        let delta = ms(seconds)
        var out: [SubtitleCue] = []
        for var c in cues {
            let a = ms(c.start) + delta, b = ms(c.end) + delta
            if b <= 0 { continue }
            c.start = sec(max(0, a)); c.end = sec(b)
            out.append(c)
        }
        return out
    }

    /// Stretches the timeline by `fromFPS / toFPS`: subtitles made for a 23.976 fps video play in sync with the same film at 25 fps after `retimed(from: 23.976, to: 25)`.
    static func retimed(_ cues: [SubtitleCue], fromFPS: Double, toFPS: Double) -> [SubtitleCue] {
        guard fromFPS > 0, toFPS > 0, abs(fromFPS - toFPS) > 1e-9 else { return cues }
        let factor = fromFPS / toFPS
        return cues.map { c in
            var n = c
            n.start = sec(Int((c.start * 1000 * factor).rounded())); n.end = sec(Int((c.end * 1000 * factor).rounded()))
            return n
        }
    }

    /// Joins flicker cues: a cue shorter than `minDuration` seconds followed within `maxGap` seconds by another cue becomes one cue with both texts (never removes text).
    static func merged(_ cues: [SubtitleCue], minDuration: Double = 0.7, maxGap: Double = 0.25) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var i = 0
        while i < cues.count {
            var cur = cues[i]
            while i + 1 < cues.count, cur.end - cur.start < minDuration, cues[i + 1].start - cur.end <= maxGap {
                let next = cues[i + 1]
                cur.text = cur.text == next.text ? cur.text : cur.text + "\n" + next.text
                cur.end = max(cur.end, next.end)
                i += 1
            }
            out.append(cur)
            i += 1
        }
        return out
    }

    /// Sorts by start time and trims every cue's end back to the start of the next one when they overlap (a cue never becomes shorter than one millisecond).
    static func overlapFixed(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var sorted = cues.enumerated().sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }.map(\.element)
        for i in 0..<max(0, sorted.count - 1) where sorted[i].end > sorted[i + 1].start {
            sorted[i].end = max(sorted[i].start + 0.001, sorted[i + 1].start)
        }
        return sorted
    }
}

extension SubtitleKit {
    /// Timing tools used by the Studio fields and by video "external subtitle" options.
    static func shifted(_ cues: [SubtitleCue], by seconds: Double) -> [SubtitleCue] { SubtitleTools.shifted(cues, by: seconds) }
    static func retimed(_ cues: [SubtitleCue], fromFPS: Double, toFPS: Double) -> [SubtitleCue] { SubtitleTools.retimed(cues, fromFPS: fromFPS, toFPS: toFPS) }
    static func stripped(_ cues: [SubtitleCue], removeTags: Bool, removeHearingImpaired: Bool) -> [SubtitleCue] {
        SubtitleTools.stripped(cues, removeTags: removeTags, removeHearingImpaired: removeHearingImpaired)
    }
}
