import Foundation

/// Pure formatting of transcripts: TXT, SRT, VTT. The cue model and writers are shared with the subtitle tools (`SubtitleKit` in the data module):
/// SRT / VTT are written by `SubtitleKit.serialize`, never by a second writer here. Segment splitting (max line length, max cue duration) lives here.
///
/// Cue rules (deterministic, so golden tests can pin them):
///  1. A cue never spans two recogniser segments.
///  2. Words are packed greedily into at most two lines of `maxCharsPerLine` characters; a cue also ends when it would last longer than `maxDuration`,
///     or when the next word follows a pause longer than `pauseBreak` seconds.
///  3. A cue that needs two lines is balanced (the shorter line first when lengths allow) instead of filling line one to the brim.
///  4. Cues are at least `minDuration` long when the next cue leaves room, and never overlap.
///  5. Without word timestamps the segment time is spread over the words in proportion to their length.
enum TranscriptFormatter {
    static let pauseBreak = 1.0
    static let minDuration = 0.5
    static let minGap = 0.04

    // MARK: Cues

    /// Splits long segments into readable cues: at most `maxCharsPerLine` x 2 lines and `maxDuration` seconds, breaking at word boundaries and
    /// distributing the time by word timestamps (or proportionally to characters when words are missing).
    static func cues(from segments: [TranscriptSegment], maxCharsPerLine: Int = 42, maxDuration: Double = 6) -> [(start: Double, end: Double, text: String)] {
        let maxChars = max(maxCharsPerLine, 8)
        let maxDur = max(maxDuration, 1)
        var out: [(start: Double, end: Double, text: String)] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let words = timedWords(segment)
            var i = 0
            while i < words.count {
                var j = i + 1
                while j < words.count {
                    let gap = words[j].start - words[j - 1].end
                    guard gap <= pauseBreak,
                          words[j].end - words[i].start <= maxDur,
                          fitsInTwoLines(words[i...j], maxChars: maxChars) else { break }
                    j += 1
                }
                let slice = Array(words[i..<j])
                out.append((slice[0].start, max(slice[slice.count - 1].end, slice[0].start), layout(slice, maxChars: maxChars)))
                i = j
            }
        }
        return settle(out)
    }

    /// Minimum duration and overlap repair over an ordered cue list.
    private static func settle(_ cues: [(start: Double, end: Double, text: String)]) -> [(start: Double, end: Double, text: String)] {
        var out = cues
        for k in out.indices {
            var end = max(out[k].end, out[k].start + minDuration)
            if k + 1 < out.count { end = min(end, max(out[k + 1].start, out[k].start + minGap)) }
            out[k].end = max(end, out[k].start + minGap)
        }
        return out
    }

    // MARK: Words

    private struct TimedWord { var text: String; var start: Double; var end: Double }

    private static func timedWords(_ segment: TranscriptSegment) -> [TimedWord] {
        let given = segment.words.compactMap { w -> TimedWord? in
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : TimedWord(text: t, start: w.start, end: w.start + max(w.duration, 0))
        }
        if !given.isEmpty { return given }
        let tokens = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        let span = max(segment.end - segment.start, 0)
        var t = segment.start
        return zip(tokens, weights).map { token, weight in
            let share = span * weight / total
            defer { t += share }
            return TimedWord(text: token, start: t, end: t + share)
        }
    }

    // MARK: Layout

    /// True when no space belongs between the two words (CJK text has none).
    private static func glued(_ a: String, _ b: String) -> Bool {
        func isCJK(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
            default: return false
            }
        }
        guard let x = a.unicodeScalars.last, let y = b.unicodeScalars.first else { return false }
        return isCJK(x) || isCJK(y)
    }

    private static func joined<S: Sequence>(_ words: S) -> String where S.Element == TimedWord {
        var s = ""
        var previous: String?
        for w in words {
            if let p = previous, !glued(p, w.text) { s += " " }
            s += w.text
            previous = w.text
        }
        return s
    }

    /// Greedy line breaking; a word longer than the limit sits alone on its line.
    private static func greedyLines(_ words: [TimedWord], maxChars: Int) -> [String] {
        var lines: [String] = []
        var current: [TimedWord] = []
        for w in words {
            if current.isEmpty { current = [w]; continue }
            if joined(current + [w]).count <= maxChars { current.append(w) } else { lines.append(joined(current)); current = [w] }
        }
        if !current.isEmpty { lines.append(joined(current)) }
        return lines
    }

    private static func fitsInTwoLines(_ words: ArraySlice<TimedWord>, maxChars: Int) -> Bool {
        greedyLines(Array(words), maxChars: maxChars).count <= 2
    }

    /// One line when it fits, else the most even two-line split that respects the limit (greedy lines when no balanced split exists).
    private static func layout(_ words: [TimedWord], maxChars: Int) -> String {
        let whole = joined(words)
        if whole.count <= maxChars || words.count < 2 { return whole }
        var best: (first: String, second: String, score: Int)?
        for k in 1..<words.count {
            let a = joined(words[0..<k]), b = joined(words[k...])
            guard a.count <= maxChars, b.count <= maxChars else { continue }
            let score = abs(a.count - b.count)
            if best == nil || score < best!.score { best = (a, b, score) }
        }
        if let best { return best.first + "\n" + best.second }
        return greedyLines(words, maxChars: maxChars).joined(separator: "\n")
    }

    // MARK: Plain text

    /// Plain text: one paragraph per pause longer than `paragraphGap` seconds, optional `[00:01:23]` stamps (then one line per recogniser segment).
    static func text(from segments: [TranscriptSegment], timestamps: Bool, paragraphGap: Double = 2.0) -> String {
        let ordered = segments.sorted(by: { $0.start < $1.start }).compactMap { s -> (start: Double, end: Double, text: String)? in
            var t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { t = joined(timedWords(s)) }
            return t.isEmpty ? nil : (s.start, s.end, t)
        }
        guard !ordered.isEmpty else { return "" }
        var paragraphs: [[(start: Double, end: Double, text: String)]] = []
        for seg in ordered {
            if let last = paragraphs.last?.last, seg.start - last.end <= paragraphGap { paragraphs[paragraphs.count - 1].append(seg) } else { paragraphs.append([seg]) }
        }
        let rendered = paragraphs.map { p -> String in
            timestamps ? p.map { "[\(stamp($0.start))] \($0.text)" }.joined(separator: "\n") : p.map(\.text).joined(separator: " ")
        }
        return rendered.joined(separator: "\n\n") + "\n"
    }

    /// `00:01:23` (hours always present, so the stamps align).
    static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: Subtitle files (through SubtitleKit)

    static func srt(from segments: [TranscriptSegment], maxCharsPerLine: Int = 42, maxDuration: Double = 6) -> String {
        SubtitleKit.serialize(subtitleCues(from: segments, maxCharsPerLine: maxCharsPerLine, maxDuration: maxDuration), as: .srt)
    }

    static func vtt(from segments: [TranscriptSegment], maxCharsPerLine: Int = 42, maxDuration: Double = 6) -> String {
        SubtitleKit.serialize(subtitleCues(from: segments, maxCharsPerLine: maxCharsPerLine, maxDuration: maxDuration), as: .vtt)
    }

    static func subtitleCues(from segments: [TranscriptSegment], maxCharsPerLine: Int = 42, maxDuration: Double = 6) -> [SubtitleCue] {
        cues(from: segments, maxCharsPerLine: maxCharsPerLine, maxDuration: maxDuration).map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
    }

    // MARK: Punctuation

    private static let removable: Set<Character> = [".", ",", "!", "?", ";", ":", "…", "¡", "¿", "\"", "“", "”", "„", "«", "»", "(", ")", "[", "]", "{", "}", "—", "–", "、", "。", "，", "！", "？", "；", "："]

    /// Removes sentence punctuation and quotes; apostrophes and hyphens inside words stay ("don't", "co-op"). Capitalisation is untouched.
    static func removingPunctuation(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            String(line.filter { !removable.contains($0) }).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func removingPunctuation(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { s in
            var c = s
            c.text = removingPunctuation(s.text)
            c.words = s.words.compactMap { w in
                var x = w
                x.text = removingPunctuation(w.text)
                return x.text.isEmpty ? nil : x
            }
            return c
        }
    }
}
