import Foundation

// Subtitle read-back for the conformance checks: SRT, WebVTT and ASS cues as (start, end, text), parsed here and not by the engines' SubtitleKit.

struct OracleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleFidelity {
    static func read(_ url: URL) -> [OracleCue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...], encoding: .utf8)
        if text == nil { text = String(data: data, encoding: .utf16) }
        guard let t = text else { return nil }
        return parse(t)
    }

    static func parse(_ text: String) -> [OracleCue] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if t.contains("[Script Info]") || t.contains("Dialogue:") { return parseASS(t) }
        return parseBlocks(t)
    }

    /// SRT and VTT: blank-line separated blocks; a block counts when one of its lines is a timing line.
    static func parseBlocks(_ t: String) -> [OracleCue] {
        let timing = try! NSRegularExpression(pattern: #"^\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})"#)
        var cues: [OracleCue] = []
        for block in t.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { timing.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }),
                  let m = timing.firstMatch(in: lines[i], range: NSRange(location: 0, length: (lines[i] as NSString).length)) else { continue }
            let ns = lines[i] as NSString
            guard let s = seconds(ns.substring(with: m.range(at: 1))), let e = seconds(ns.substring(with: m.range(at: 2))) else { continue }
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append(OracleCue(start: s, end: e, text: body))
        }
        return cues
    }

    private static func parseASS(_ t: String) -> [OracleCue] {
        var cues: [OracleCue] = []
        for line in t.components(separatedBy: "\n") where line.hasPrefix("Dialogue:") {
            let parts = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard parts.count >= 10, let s = seconds(String(parts[1]).trimmingCharacters(in: .whitespaces)), let e = seconds(String(parts[2]).trimmingCharacters(in: .whitespaces)) else { continue }
            var body = String(parts[9]).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            cues.append(OracleCue(start: s, end: e, text: body))
        }
        return cues
    }

    /// "01:02:03,456", "02:03.456", "1:02:03.5" to seconds.
    static func seconds(_ s: String) -> Double? {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    static func stripTags(_ s: String) -> String { s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }

    /// First difference between two cue lists (timings within `toleranceMs`, text exact or modulo markup), or nil when they are the same subtitles.
    static func difference(_ a: [OracleCue], _ b: [OracleCue], toleranceMs: Double = 1, ignoreMarkup: Bool = false) -> String? {
        if a.count != b.count { return "cue count \(a.count) vs \(b.count)" }
        for (i, (x, y)) in zip(a, b).enumerated() {
            if abs(x.start - y.start) * 1000 > toleranceMs { return "cue \(i + 1) starts at \(x.start) vs \(y.start)" }
            if abs(x.end - y.end) * 1000 > toleranceMs { return "cue \(i + 1) ends at \(x.end) vs \(y.end)" }
            let tx = ignoreMarkup ? stripTags(x.text) : x.text, ty = ignoreMarkup ? stripTags(y.text) : y.text
            if tx != ty { return "cue \(i + 1) text \"\(tx)\" vs \"\(ty)\"" }
        }
        return nil
    }

    /// What the plain-text export is specified to contain: markup removed, line breaks inside a cue folded to spaces, consecutive duplicates dropped.
    static func plainLines(_ cues: [OracleCue]) -> [String] {
        var out: [String] = []
        for c in cues {
            let line = TextCompare.normalize(stripTags(c.text))
            if line.isEmpty || out.last == line { continue }
            out.append(line)
        }
        return out
    }
}
