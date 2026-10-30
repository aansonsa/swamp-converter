import Foundation

// Subtitle cues for burn-in and for external subtitle files: a small, self-contained SRT / WebVTT / ASS reader (the shared
// SubtitleKit belongs to another module and is not a dependency of the video engine), charset detection and an SRT writer.

struct VideoCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct VideoBurnStyle: Equatable, Sendable {
    var font = "SF Pro Text"
    /// Percent of the picture height.
    var sizePercent = 5.5
    var color = "#FFFFFF"
    var outlineColor = "#000000"
    var outline = 2.0
    var shadow = 1.0
    var box = false
    var boxOpacity = 50.0
    /// bottom, middle, top
    var position = "bottom"
    /// Percent of the picture height.
    var margin = 6.0
}

enum VideoCueParser {
    // MARK: Encodings

    /// The encodings of the picker `s.ext.charset`.
    static func encoding(named name: String) -> String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))) }
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1257", "cp1257": return cf(.windowsBalticRim)
        case "koi8-r", "koi8r": return cf(.KOI8_R)
        case "cp866", "ibm866": return cf(.dosCyrillic)
        case "iso-8859-13", "latin7": return cf(.isoLatin7)
        default: return nil
        }
    }

    /// Detects the text encoding: BOM, valid UTF-8, otherwise the candidate whose Cyrillic text looks most like real prose
    /// (lower-case letters dominate), then the Baltic code page when its characteristic letters appear, finally Windows-1252.
    static func detectEncoding(_ data: Data) -> String.Encoding {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return .utf16 }
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        var best: (enc: String.Encoding, score: Double)? = nil
        for name in ["windows-1251", "koi8-r", "cp866"] {
            guard let enc = encoding(named: name), let s = String(data: data, encoding: enc) else { continue }
            var cyr = 0, lower = 0
            for u in s.unicodeScalars where (0x0410...0x044F).contains(u.value) || u.value == 0x0451 || u.value == 0x0401 {
                cyr += 1
                if u.value >= 0x0430 || u.value == 0x0451 { lower += 1 }
            }
            let nonASCII = s.unicodeScalars.filter { $0.value > 127 }.count
            guard cyr > 0, nonASCII > 0 else { continue }
            let score = Double(lower) / Double(cyr) * Double(cyr) / Double(nonASCII)
            if best == nil || score > best!.score { best = (enc, score) }
        }
        if let b = best, b.score > 0.55 { return b.enc }
        if let baltic = encoding(named: "windows-1257"), let s = String(data: data, encoding: baltic) {
            let lv = s.unicodeScalars.filter { "āčēģīķļņšūžĀČĒĢĪĶĻŅŠŪŽąęėįųŠŽ".unicodeScalars.contains($0) }.count
            if lv > 0 { return baltic }
        }
        return .windowsCP1252
    }

    static func decode(_ data: Data, charset: String) -> String {
        let enc = charset.lowercased() == "auto" ? detectEncoding(data) : (encoding(named: charset) ?? detectEncoding(data))
        var text = String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    static func charsetName(of data: Data) -> String {
        switch detectEncoding(data) {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .windowsCP1251: return "Windows-1251"
        case .windowsCP1252: return "Windows-1252"
        default:
            for n in ["koi8-r", "cp866", "windows-1257"] where encoding(named: n) == detectEncoding(data) { return n.uppercased() }
            return "UTF-8"
        }
    }

    // MARK: Parsing

    /// Parses SRT, WebVTT or ASS / SSA text (detected from the content). Cues are sorted by start time; empty cues are dropped.
    static func parse(_ text: String) -> [VideoCue] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [VideoCue]
        if t.contains("[Script Info]") || t.contains("Dialogue:") { cues = parseASS(t) } else { cues = parseTimed(t) }
        cues = cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:00:01,500" / "00:01.500" / "1:02:03.5" -> seconds.
    static func parseTimestamp(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    private static func parseTimed(_ t: String) -> [VideoCue] {
        var cues: [VideoCue] = []
        let blocks = t.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let halves = lines[ti].components(separatedBy: "-->")
            guard halves.count == 2, let a = parseTimestamp(halves[0]),
                  let b = parseTimestamp(String(halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
            cues.append(VideoCue(start: a, end: b, text: stripMarkup(body)))
        }
        return cues
    }

    private static func parseASS(_ t: String) -> [VideoCue] {
        var cues: [VideoCue] = []
        var startIdx = 1, endIdx = 2, textIdx = 9, columns = 10
        for line in t.split(separator: "\n") {
            let l = String(line)
            if l.hasPrefix("Format:"), l.contains("Start"), l.contains("Text") {
                let names = l.dropFirst("Format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                columns = names.count
                startIdx = names.firstIndex(of: "Start") ?? 1; endIdx = names.firstIndex(of: "End") ?? 2; textIdx = names.firstIndex(of: "Text") ?? names.count - 1
            }
            guard l.hasPrefix("Dialogue:") else { continue }
            let fields = l.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: columns - 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count > textIdx, let a = parseTimestamp(fields[startIdx]), let b = parseTimestamp(fields[endIdx]) else { continue }
            var text = fields[textIdx]
            text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            cues.append(VideoCue(start: a, end: b, text: text.trimmingCharacters(in: .whitespaces)))
        }
        return cues
    }

    /// Removes HTML-like tags and ASS override blocks, keeps line breaks.
    static func stripMarkup(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing

    /// UTF-8 SRT text of the cues shifted by `offsetMs` (cues that end before zero are dropped).
    static func srt(_ cues: [VideoCue], offsetMs: Int = 0) -> String {
        func stamp(_ t: Double) -> String {
            let ms = max(0, Int((t * 1000).rounded()))
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = ""
        var n = 1
        for c in cues {
            let a = c.start + Double(offsetMs) / 1000, b = c.end + Double(offsetMs) / 1000
            if b <= 0 { continue }
            out += "\(n)\n\(stamp(a)) --> \(stamp(b))\n\(c.text)\n\n"
            n += 1
        }
        return out
    }
}
