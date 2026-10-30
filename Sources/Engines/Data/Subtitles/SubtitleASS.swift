import Foundation

// ASS / SSA reading: the [Events] section only (styles do not matter for text conversion). Override blocks are reduced to the tags other formats know: {\i1} {\b1} {\u1}
// {\s1} become <i> <b> <u> <s>, positioning and animation tags disappear. \N and \n are line breaks, \h a no-break space. Comment lines are skipped; cues are sorted by time.

enum SubtitleASS {
    static func parse(_ text: String) -> [SubtitleCue] {
        var inEvents = false
        var columns: [String] = []
        var found: [(start: Int, end: Int, text: String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("format:") {
                columns = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard lower.hasPrefix("dialogue:") else { continue }
            let cols = columns.isEmpty ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"] : columns
            let fields = split(String(line.dropFirst(9)), into: cols.count)
            guard let si = cols.firstIndex(of: "start"), let ei = cols.firstIndex(of: "end"), let ti = cols.firstIndex(of: "text"),
                  si < fields.count, ei < fields.count, ti < fields.count,
                  let a = SubtitleKit.parseTimestamp(Substring(fields[si].trimmingCharacters(in: .whitespaces))),
                  let b = SubtitleKit.parseTimestamp(Substring(fields[ei].trimmingCharacters(in: .whitespaces))) else { continue }
            let body = convert(fields[ti])
            found.append((a, b, body))
        }
        return found.enumerated().sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map { SubtitleCue(start: SubtitleKit.seconds(fromMilliseconds: $0.element.start), end: SubtitleKit.seconds(fromMilliseconds: $0.element.end), text: $0.element.text) }
    }

    /// Splits at commas into exactly `count` fields (the last field keeps its commas).
    private static func split(_ s: String, into count: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            if ch == ",", out.count < count - 1 { out.append(current); current = "" } else { current.append(ch) }
        }
        out.append(current)
        return out
    }

    /// Dialogue text -> plain text with <i> <b> <u> <s> tags.
    static func convert(_ s: String) -> String {
        var out = ""
        var open: [Character: Bool] = [:]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{", let close = chars[i...].firstIndex(of: "}") {
                let block = String(chars[(i + 1)..<close])
                for part in block.split(separator: "\\", omittingEmptySubsequences: true) {
                    guard let tag = part.first, "ibus".contains(tag), part.count >= 2 else { continue }
                    let on = part.dropFirst().first.map { $0 == "1" } ?? false
                    let off = part.dropFirst().first.map { $0 == "0" } ?? false
                    if on, open[tag] != true { out += "<\(tag)>"; open[tag] = true }
                    else if off, open[tag] == true { out += "</\(tag)>"; open[tag] = false }
                }
                i = close + 1
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "N" || n == "n" { out += "\n"; i += 2; continue }
                if n == "h" { out += "\u{00A0}"; i += 2; continue }
            }
            out.append(c)
            i += 1
        }
        for tag in ["i", "b", "u", "s"] where open[Character(tag)] == true { out += "</\(tag)>" }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Writing

    static func stamp(_ seconds: Double) -> String {
        let cs = max(0, Int((seconds * 100).rounded()))
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    /// Plain text with <i> <b> <u> <s> tags -> ASS dialogue text.
    static func dialogueText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        for tag in ["i", "b", "u", "s"] {
            t = t.replacingOccurrences(of: "<\(tag)>", with: "{\\\(tag)1}").replacingOccurrences(of: "</\(tag)>", with: "{\\\(tag)0}")
        }
        t = SubtitleTools.removeTags(in: t, keepBraces: true)
        return t.replacingOccurrences(of: "\n", with: "\\N")
    }

    static func serialize(_ cues: [SubtitleCue], ssa: Bool) -> String {
        var s = "[Script Info]\nTitle: \nScriptType: \(ssa ? "v4.00" : "v4.00+")\nWrapStyle: 0\nPlayResX: 640\nPlayResY: 360\n\n"
        if ssa {
            s += "[V4 Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding\n"
            s += "Style: Default,Arial,20,16777215,16777215,0,0,0,0,1,2,1,2,10,10,10,0,1\n\n"
            s += "[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            for c in cues { s += "Dialogue: Marked=0,\(stamp(c.start)),\(stamp(c.end)),Default,,0,0,0,,\(dialogueText(c.text))\n" }
        } else {
            s += "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
            s += "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1\n\n"
            s += "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            for c in cues { s += "Dialogue: 0,\(stamp(c.start)),\(stamp(c.end)),Default,,0,0,0,,\(dialogueText(c.text))\n" }
        }
        return s
    }
}
