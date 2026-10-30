import Foundation

// Serialisers of SubtitleKit. Output uses "\n" line breaks and no BOM; callers choose the line ending and the encoding (`SubtitleOutput`).

extension SubtitleKit {
    /// SRT: numbered from 1, `HH:MM:SS,mmm --> HH:MM:SS,mmm`; VTT: `WEBVTT` header, `HH:MM:SS.mmm`; TXT: tags removed, newlines inside a cue become spaces, empty and
    /// consecutive duplicate lines dropped. UTF-8 without BOM (callers add one if asked).
    static func serialize(_ cues: [SubtitleCue], as format: SubtitleFormat) -> String {
        switch format {
        case .srt:
            var out = ""
            out.reserveCapacity(cues.count * 64)
            for (i, c) in cues.enumerated() { out += "\(i + 1)\n\(stamp(c.start, ","))" + " --> " + "\(stamp(c.end, ","))\n\(c.text)\n\n" }
            return out
        case .vtt:
            var out = "WEBVTT\n\n"
            for c in cues { out += "\(stamp(c.start, "."))" + " --> " + "\(stamp(c.end, "."))\n\(encodeEntities(c.text).replacingOccurrences(of: "-->", with: "--&gt;"))\n\n" }
            return out
        case .sbv:
            var out = ""
            for c in cues { out += "\(stamp(c.start, ".", shortHours: true)),\(stamp(c.end, ".", shortHours: true))\n\(c.text)\n\n" }
            return out
        case .ass: return SubtitleASS.serialize(cues, ssa: false)
        case .ssa: return SubtitleASS.serialize(cues, ssa: true)
        case .txt: return plainText(cues, paragraphs: false)
        }
    }

    /// `HH:MM:SS,mmm` from seconds, rounded to the nearest millisecond (hours may exceed 99). `shortHours` prints `H:MM:SS.mmm` (SBV).
    static func stamp(_ seconds: Double, _ separator: String, shortHours: Bool = false) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: shortHours ? "%d:%02d:%02d%@%03d" : "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    /// Plain text: one line per cue (`paragraphs` false) or paragraphs separated by a blank line where the pause between two cues is longer than `pause` seconds.
    static func plainText(_ cues: [SubtitleCue], paragraphs: Bool, pause: Double = 2) -> String {
        var lines: [String] = []        // for paragraphs: one entry per cue, "" marks a paragraph break
        var previous: String?
        var lastEnd: Double?
        for c in cues {
            let t = SubtitleTools.removeTags(in: c.text).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let collapsed = t.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            if collapsed.isEmpty { continue }
            if collapsed == previous { continue }
            if paragraphs, let e = lastEnd, c.start - e > pause, !lines.isEmpty, lines.last != "" { lines.append("") }
            lines.append(collapsed)
            previous = collapsed
            lastEnd = c.end
        }
        if !paragraphs { return lines.map { $0 + "\n" }.joined() }
        var out = ""
        var run: [String] = []
        for l in lines + [""] {
            if l.isEmpty { if !run.isEmpty { out += run.joined(separator: " ") + "\n\n"; run = [] } } else { run.append(l) }
        }
        return out.hasSuffix("\n\n") ? String(out.dropLast()) : out
    }
}
