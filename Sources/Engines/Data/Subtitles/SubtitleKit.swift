import Foundation

// SubtitleKit: parse / serialise subtitles (SRT, WebVTT, ASS / SSA, SBV, plain text). PURE and shared: the intelligence module's transcripts, the
// video module's soft / external subtitle options and the smart module use `SubtitleKit.serialize` instead of writing their own writer.
//
// Times are kept as integer milliseconds while parsing and printing (Double seconds in the public cue only carry them), so SRT -> VTT -> SRT is bit-exact.
// Files: SubtitleKit (model + parsers), SubtitleWriters (serialisers), SubtitleTools (shift / retime / strip / merge / overlap), SubtitleText (encodings, files).

struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var identifier: String? = nil
}

enum SubtitleFormat: String, CaseIterable, Sendable { case srt, vtt, ass, ssa, sbv, txt }

enum SubtitleKit {
    // MARK: Parsing

    /// Parses by `format` (or sniffing when nil): blocks with `[h:]mm:ss(,|.)f{1,3} --> ...` timing lines, cue numbers / identifiers / settings ignored, WEBVTT / NOTE / STYLE
    /// blocks dropped, BOM stripped. Zero cues throws `ConversionError.noSubtitles`.
    static func parse(_ text: String, format: SubtitleFormat? = nil) throws -> [SubtitleCue] {
        let normalised = normalise(text)
        let kind = format ?? sniff(normalised)
        var cues: [SubtitleCue]
        switch kind {
        case .ass, .ssa: cues = SubtitleASS.parse(normalised)
        case .sbv: cues = parseBlocks(normalised, vtt: false, sbv: true)
        case .vtt: cues = parseBlocks(normalised, vtt: true, sbv: false)
        case .srt, .txt: cues = parseBlocks(normalised, vtt: false, sbv: false)
        }
        // A wrong format hint (".srt" that is really ASS or SBV) is corrected by the content.
        if cues.isEmpty, format != nil {
            let guessed = sniff(normalised)
            if guessed != kind {
                switch guessed {
                case .ass, .ssa: cues = SubtitleASS.parse(normalised)
                case .sbv: cues = parseBlocks(normalised, vtt: false, sbv: true)
                case .vtt: cues = parseBlocks(normalised, vtt: true, sbv: false)
                default: cues = parseBlocks(normalised, vtt: false, sbv: false)
                }
            }
        }
        guard !cues.isEmpty else { throw ConversionError.noSubtitles }
        return cues
    }

    /// Format of a subtitle text by its content.
    static func sniff(_ text: String) -> SubtitleFormat {
        let t = normalise(text)
        var head = ""
        var seen = 0
        for line in t.split(separator: "\n", omittingEmptySubsequences: true) {
            head += line + "\n"; seen += 1
            if seen >= 60 { break }
        }
        if head.hasPrefix("WEBVTT") { return .vtt }
        if head.contains("[Script Info]") || head.contains("[Events]") || head.contains("\nDialogue:") || head.hasPrefix("Dialogue:") {
            return head.contains("[V4 Styles]") && !head.contains("[V4+ Styles]") ? .ssa : .ass
        }
        if head.range(of: #"(?m)^\d+:\d{2}:\d{2}\.\d{3},\d+:\d{2}:\d{2}\.\d{3}\s*$"#, options: .regularExpression) != nil { return .sbv }
        return .srt
    }

    /// Key of a file extension -> format (`nil` when the key is not a subtitle format).
    static func format(forKey key: String) -> SubtitleFormat? { SubtitleFormat(rawValue: key.lowercased()) }

    /// BOM removed, CRLF / CR -> LF.
    static func normalise(_ text: String) -> String {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        // (a Swift Character "\r\n" is one grapheme: always replace at the string level)
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return t
    }

    // MARK: Timestamps

    /// "01:02:03,5" / "1:02.500" / "00:00:01.12" -> milliseconds. Fractions of one to three digits are decimal fractions ("5" is 500 ms); more digits are cut.
    static func parseTimestamp(_ s: Substring) -> Int? {
        var hours = 0, minutes = 0, seconds = 0, millis = 0
        let comps = s.split(whereSeparator: { $0 == ":" })
        guard comps.count == 2 || comps.count == 3 else { return nil }
        let last = comps[comps.count - 1]
        let secParts = last.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        guard secParts.count <= 2, let sec = Int(secParts[0]) else { return nil }
        seconds = sec
        if secParts.count == 2 {
            let frac = secParts[1].prefix(3)
            guard !frac.isEmpty, frac.allSatisfy({ $0.isASCII && $0.isNumber }), let f = Int(frac) else { return nil }
            millis = f * [100, 10, 1][frac.count - 1]
        }
        guard let mm = Int(comps[comps.count - 2]) else { return nil }
        minutes = mm
        if comps.count == 3 { guard let hh = Int(comps[0]) else { return nil }; hours = hh }
        guard minutes < 100, seconds < 100 else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    /// Timing line of SRT / VTT: `start --> end` followed by optional cue settings (VTT).
    private static let timingRegex = try! NSRegularExpression(pattern: #"^\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})"#)
    private static let sbvRegex = try! NSRegularExpression(pattern: #"^\s*(\d+:\d{2}:\d{2}\.\d{1,3})\s*,\s*(\d+:\d{2}:\d{2}\.\d{1,3})\s*$"#)

    private static func timing(_ line: String, sbv: Bool) -> (Int, Int)? {
        let ns = line as NSString
        guard let m = (sbv ? sbvRegex : timingRegex).firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let a = parseTimestamp(Substring(ns.substring(with: m.range(at: 1)))), let b = parseTimestamp(Substring(ns.substring(with: m.range(at: 2)))) else { return nil }
        return (a, b)
    }

    static func seconds(fromMilliseconds ms: Int) -> Double { Double(ms) / 1000 }

    // MARK: SRT / VTT / SBV blocks

    private static func parseBlocks(_ text: String, vtt: Bool, sbv: Bool) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var block: [String] = []
        func flush() {
            defer { block.removeAll(keepingCapacity: true) }
            guard !block.isEmpty else { return }
            if vtt, let f = block.first, f.hasPrefix("NOTE") || f.hasPrefix("STYLE") || f.hasPrefix("REGION") || f.hasPrefix("WEBVTT") { return }
            let timings = block.indices.compactMap { i in timing(block[i], sbv: sbv).map { (index: i, ms: $0) } }
            guard !timings.isEmpty else { return }
            // A cue number / identifier sits right before its timing line; it is not part of the previous cue's text even when the blank line between them is missing.
            var idLine: [Int?] = []
            for (n, t) in timings.enumerated() {
                if n == 0 { idLine.append(t.index > 0 ? t.index - 1 : nil); continue }
                let c = t.index - 1
                let candidate = block[c].trimmingCharacters(in: .whitespaces)
                idLine.append(c > timings[n - 1].index && !candidate.isEmpty && candidate.allSatisfy(\.isNumber) ? c : nil)
            }
            for (n, t) in timings.enumerated() {
                let bodyEnd = n + 1 < timings.count ? (idLine[n + 1] ?? timings[n + 1].index) : block.count
                var body = Array(block[(t.index + 1)..<max(t.index + 1, bodyEnd)])
                while let l = body.last, l.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }
                var text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if vtt { text = decodeEntities(text) }
                let id = idLine[n].map { block[$0].trimmingCharacters(in: .whitespaces) }
                cues.append(SubtitleCue(start: seconds(fromMilliseconds: t.ms.0), end: seconds(fromMilliseconds: t.ms.1), text: text, identifier: (id?.isEmpty ?? true) ? nil : id))
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(l) }
        }
        flush()
        return cues
    }

    // MARK: Entities (WebVTT)

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (e, r) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}"), ("&lrm;", "\u{200E}"), ("&rlm;", "\u{200F}"), ("&amp;", "&")] { out = out.replacingOccurrences(of: e, with: r) }
        return out
    }

    /// `&` and `<` that are not part of an entity or a tag, escaped for WebVTT.
    static func encodeEntities(_ s: String) -> String {
        guard s.contains("&") || s.contains("<") else { return s }
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "&" {
                let rest = String(chars[i...].prefix(10))
                if rest.range(of: #"^&(#\d+|#x[0-9A-Fa-f]+|[A-Za-z]+);"#, options: .regularExpression) != nil { out.append(c) } else { out += "&amp;" }
            } else if c == "<" {
                let rest = String(chars[i...].prefix(80))
                if rest.range(of: #"^</?[A-Za-z][^<>]*>"#, options: .regularExpression) != nil || rest.range(of: #"^<\d[\d:.]*>"#, options: .regularExpression) != nil { out.append(c) } else { out += "&lt;" }
            } else { out.append(c) }
            i += 1
        }
        return out
    }
}
