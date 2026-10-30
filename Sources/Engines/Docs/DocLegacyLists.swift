import Foundation

// Binary .doc and RTF reach us through textutil, which turns their lists into plain paragraphs that begin with a bullet character or a number ("•\tone", "2\ttwo").
// This pass gives those paragraphs back their list structure: consecutive bullet paragraphs become one bullet list, consecutive numbered paragraphs (n, n+1, ...)
// one numbered list starting at n. It is applied to the legacy route only, never to HTML or DOCX, where lists are real.

enum DocLegacyLists {
    private static let bullets = Set("\u{2022}\u{25E6}\u{25AA}\u{2023}\u{00B7}\u{2043}\u{25CF}\u{25CB}\u{25A0}\u{2013}")

    private enum Marker: Equatable { case bullet, number(Int) }

    /// The marker of a paragraph and its content without the marker.
    private static func marker(of inlines: [DocInline]) -> (Marker, [DocInline])? {
        guard case .text(let t)? = inlines.first else { return nil }
        let s = t.drop { $0 == " " || $0 == "\t" }
        guard let first = s.first else { return nil }
        if bullets.contains(first) {
            let rest = s.dropFirst()
            guard rest.first == " " || rest.first == "\t" || rest.first == "\u{00A0}" else { return nil }
            var out = inlines
            out[0] = .text(String(rest.drop { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }))
            return (.bullet, out)
        }
        guard first.isASCII, first.isNumber else { return nil }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard digits.count <= 3, let n = Int(digits) else { return nil }
        var rest = s.dropFirst(digits.count)
        if rest.first == "." || rest.first == ")" { rest = rest.dropFirst() }
        guard rest.first == " " || rest.first == "\t" || rest.first == "\u{00A0}" else { return nil }
        var out = inlines
        out[0] = .text(String(rest.drop { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }))
        return (.number(n), out)
    }

    static func recover(_ blocks: [DocBlock]) -> [DocBlock] {
        var out: [DocBlock] = []
        var i = 0
        while i < blocks.count {
            guard case .paragraph(let c) = blocks[i], let (m, content) = marker(of: c) else { out.append(blocks[i]); i += 1; continue }
            var items = [DocListItem(blocks: [.paragraph(content)])]
            var j = i + 1
            var expected: Int?
            if case .number(let n) = m { expected = n + 1 }
            while j < blocks.count, case .paragraph(let c2) = blocks[j], let (m2, content2) = marker(of: c2) {
                if m == .bullet, m2 == .bullet { items.append(DocListItem(blocks: [.paragraph(content2)])); j += 1; continue }
                if case .number(let n2) = m2, let e = expected, n2 == e { items.append(DocListItem(blocks: [.paragraph(content2)])); expected = e + 1; j += 1; continue }
                break
            }
            switch m {
            case .bullet: out.append(.list(DocList(ordered: false, items: items)))
            case .number(let n):
                if items.count >= 2 { out.append(.list(DocList(ordered: true, start: n, items: items))) }
                else { out.append(blocks[i]) }     // a lone "2020 results" is not a list
            }
            i = j
        }
        return out
    }
}
