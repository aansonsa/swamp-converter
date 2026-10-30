import AppKit

/// Picks the font size of a sector or hub title so that it wraps only BETWEEN words: SwiftUI breaks a word that is wider than its box in the middle ("Объединит" / "ь PDF"),
/// and `minimumScaleFactor` does not prevent that. Pure and measured with the same system font the label uses, so it is unit-tested without a window.
enum WheelLabelFit {
    /// The largest size in `minimum...base` (steps of half a point) at which every word fits `width` on its own line and the text takes at most `maxLines` lines.
    /// nil when even `minimum` does not fit (the caller then lets the text truncate with an ellipsis instead of breaking a word).
    static func size(for text: String, width: CGFloat, base: CGFloat, minimum: CGFloat, maxLines: Int, weight: NSFont.Weight = .semibold) -> CGFloat? {
        guard width > 0, base >= minimum, maxLines > 0 else { return nil }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !words.isEmpty else { return base }
        var s = base
        while s >= minimum - 0.001 {
            if lineCount(words, width: width, size: s, weight: weight) <= maxLines { return s }
            s -= 0.5
        }
        return nil
    }

    /// Lines needed for `words` at `size` when wrapping at word boundaries; `Int.max` when a single word is wider than the box.
    static func lineCount(_ words: [String], width: CGFloat, size: CGFloat, weight: NSFont.Weight) -> Int {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        let space = w(" ")
        var lines = 1, used: CGFloat = 0
        for word in words {
            let ww = w(word)
            if ww > width { return Int.max }
            if used == 0 { used = ww }
            else if used + space + ww <= width { used += space + ww }
            else { lines += 1; used = ww }
        }
        return lines
    }
}
