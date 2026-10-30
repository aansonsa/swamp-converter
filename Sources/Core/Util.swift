import Foundation

// Small, dependency-free helpers shared by every module. All pure functions, safe from any thread.

enum Util {
    /// Natural ("Finder-like") ordering: digit runs compare numerically, text is case- and diacritic-insensitive.
    /// `[p10, p2, p1]` sorts to `[p1, p2, p10]`.
    static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale(identifier: "en_US"))
    }

    static func naturalSorted(_ urls: [URL]) -> [URL] {
        urls.sorted { naturalCompare($0.path, $1.path) == .orderedAscending }
    }

    /// Parses a user-typed time: "90" -> 90, "1:30" -> 90, "01:02:03.5" -> 3723.5, "0,5" -> 0.5.
    /// Returns nil for empty or malformed input. Result is rounded to milliseconds.
    static func parseTime(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 3 { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            let isLast = i == parts.count - 1
            if !isLast && p.contains(".") { return nil }
            total = total * 60 + v
        }
        return (total * 1000).rounded() / 1000
    }

    /// Formats seconds as `H:MM:SS` or `M:SS`, with `.mmm` when `fraction` is true.
    static func formatTime(_ seconds: Double, fraction: Bool = false) -> String {
        let s = max(0, seconds)
        let whole = Int(s)
        let h = whole / 3600, m = (whole % 3600) / 60, sec = whole % 60
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        if fraction {
            let ms = Int(((s - Double(whole)) * 1000).rounded())
            out += String(format: ".%03d", min(ms, 999))
        }
        return out
    }

    /// Byte count in SI units as Finder shows them ("4.2 MB", "1,2 ГБ" follows the language of the app).
    static func formatBytes(_ bytes: Int64) -> String {
        // The language of the app, not of the system: "1,01 ГБ" when the app is set to Russian on an English system, as the rest of the interface.
        ByteCountFormatStyle(style: .file, allowedUnits: [.kb, .mb, .gb, .tb], spellsOutZero: false, includesActualByteCount: false, locale: Loc.shared.locale).format(bytes)
    }

    /// Short duration for ETAs: "42 s", "3 min", "1 h 05 min" (localised).
    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return L("\(s) s", "\(s) с") }
        if s < 3600 { return L("\(s / 60) min", "\(s / 60) мин") }
        return L("\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min",
                 "\(s / 3600) ч \(String(format: "%02d", (s % 3600) / 60)) мин")
    }

    /// Makes a string safe as a single file-name component: no `/` or `:` and no control characters,
    /// no leading dot (hidden files collide with temp-file rules), trimmed, at most 200 UTF-8 bytes.
    static func safeFileName(_ s: String, fallback: String = "file") -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if ch == "/" || ch == ":" || ch.value < 32 || ch == "\\" || ch == "*" || ch == "?" || ch == "\"" || ch == "<" || ch == ">" || ch == "|" {
                out.append("-")
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        out = out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        while out.utf8.count > 200 { out.removeLast() }
        return out.isEmpty ? fallback : out
    }

    /// Suffix used in `name (suffix).ext`: same as `safeFileName` but max 40 characters and falls back to "preset".
    static func safeSuffix(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if "/\\:*?\"<>|".unicodeScalars.contains(ch) || ch.value < 32 { out.append("-") } else { out.unicodeScalars.append(ch) }
        }
        out = out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if out.count > 40 { out = String(out.prefix(40)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))) }
        return out.isEmpty ? "preset" : out
    }

    /// 8 lowercase hex characters, used in temp names.
    static func hex8() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    /// Clamp helper usable on any Comparable.
    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
}

extension String {
    /// Case-insensitive, diacritic-insensitive containment, used by option search and pickers.
    func looseContains(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        return range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A tiny lock-protected box. Use for state touched from several threads when an actor is overkill.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&_value)
    }
}
