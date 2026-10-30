import Foundation

// Plain text <-> DocModel. Reading never interprets Markdown (a .txt is not Markdown unless the user asks). It splits paragraphs on blank lines, decides whether line
// breaks inside a paragraph are real or hard-wrapping at a fixed width, and recognises two obvious structures: bullet / numbered lists and preformatted (indented) blocks.
// Writing renders the model the way a person would type it: headings as lines, lists with "-" and "1.", tables as aligned columns, optional hard wrap.

enum DocPlainText {
    enum Reflow: String { case auto, keep, join }

    // MARK: Reading

    static func read(_ text: String, reflow: Reflow = .auto) -> [DocBlock] {
        let normalized = DocTextCodec.normalizeLineEndings(text, to: "lf")
        var paragraphs: [[String]] = []
        var current: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        let wrapWidth = reflow == .auto ? hardWrapWidth(paragraphs) : nil
        var blocks: [DocBlock] = []
        for lines in paragraphs {
            if let list = listBlock(lines) { blocks.append(list); continue }
            if lines.allSatisfy({ $0.hasPrefix("    ") || $0.hasPrefix("\t") }) && lines.count >= 1 && reflow != .join {
                blocks.append(.code(language: nil, text: lines.map { $0.hasPrefix("\t") ? String($0.dropFirst()) : String($0.dropFirst(4)) }.joined(separator: "\n")))
                continue
            }
            let join: Bool
            switch reflow {
            case .join: join = true
            case .keep: join = false
            case .auto: join = wrapWidth != nil && lines.count > 1 && lines.dropLast().allSatisfy { $0.trimmingCharacters(in: .whitespaces).count >= Int(Double(wrapWidth!) * 0.8) }
            }
            blocks.append(.paragraph(join ? [.text(lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))] : hardBreaks(lines)))
        }
        return blocks
    }

    private static func hardBreaks(_ lines: [String]) -> [DocInline] {
        var out: [DocInline] = []
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(.lineBreak) }
            out.append(.text(l.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)))
        }
        return out
    }

    /// The column at which the document was hard-wrapped, or nil when its line breaks look intentional.
    private static func hardWrapWidth(_ paragraphs: [[String]]) -> Int? {
        var interior: [Int] = []
        for p in paragraphs where p.count > 1 { interior += p.dropLast().map { $0.trimmingCharacters(in: .whitespaces).count } }
        guard interior.count >= 3, let w = interior.max(), w >= 40 else { return nil }
        let near = interior.filter { Double($0) >= Double(w) * 0.85 }.count
        return Double(near) / Double(interior.count) >= 0.6 ? w : nil
    }

    private static let bulletRegex = try! NSRegularExpression(pattern: "^\\s{0,3}([-*+•–—])\\s+(.*)$")
    private static let orderedRegex = try! NSRegularExpression(pattern: "^\\s{0,3}(\\d{1,4})[.)]\\s+(.*)$")

    private static func listBlock(_ lines: [String]) -> DocBlock? {
        guard lines.count >= 2 else { return nil }
        func matches(_ re: NSRegularExpression) -> [(String, String)]? {
            var out: [(String, String)] = []
            for l in lines {
                let ns = l as NSString
                guard let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { return nil }
                out.append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
            }
            return out
        }
        if let b = matches(bulletRegex) {
            return .list(DocList(ordered: false, items: b.map { DocListItem(blocks: [.paragraph([.text($0.1)])]) }))
        }
        if let o = matches(orderedRegex) {
            return .list(DocList(ordered: true, start: Int(o[0].0) ?? 1, items: o.map { DocListItem(blocks: [.paragraph([.text($0.1)])]) }))
        }
        return nil
    }

    // MARK: Writing

    /// Renders blocks as plain text. `wrap` > 0 hard-wraps paragraphs, list items and quotes at that many characters.
    static func render(_ blocks: [DocBlock], wrap: Int = 0) -> String {
        var out: [String] = []
        for b in blocks {
            let s = renderBlock(b, wrap: wrap, indent: "")
            if !s.isEmpty { out.append(s) }
        }
        return out.joined(separator: "\n\n") + (out.isEmpty ? "" : "\n")
    }

    private static func renderBlock(_ block: DocBlock, wrap: Int, indent: String) -> String {
        switch block {
        case .heading(_, let c), .paragraph(let c):
            return wrapped(inlineText(c), wrap: wrap, indent: indent)
        case .list(let l):
            var lines: [String] = []
            for (i, item) in l.items.enumerated() {
                let marker = l.ordered ? "\(l.start + i). " : "- "
                let pad = String(repeating: " ", count: marker.count)
                var inner: [String] = []
                for (j, b) in item.blocks.enumerated() {
                    let s = renderBlock(b, wrap: wrap, indent: indent + pad)
                    if s.isEmpty { continue }
                    if j > 0, case .list = b { inner.append(s) } else if j > 0 { inner.append(""); inner.append(s) } else { inner.append(s) }
                }
                guard var first = inner.first else { lines.append(indent + marker.trimmingCharacters(in: .whitespaces)); continue }
                // The first line carries the marker instead of the plain indentation.
                if first.hasPrefix(indent + pad) { first = indent + marker + first.dropFirst((indent + pad).count) }
                else { first = indent + marker + first }
                lines.append(first)
                lines += inner.dropFirst()
            }
            return lines.joined(separator: "\n")
        case .quote(let bs):
            return bs.map { renderBlock($0, wrap: wrap, indent: indent + "    ") }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .code(_, let text):
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { indent + "    " + $0 }.joined(separator: "\n")
        case .table(let t):
            return renderTable(t, indent: indent)
        case .rule:
            return indent + String(repeating: "-", count: 40)
        case .pageBreak:
            return ""
        }
    }

    private static func wrapped(_ text: String, wrap: Int, indent: String) -> String {
        let width = wrap > 0 ? max(10, wrap - indent.count) : 0
        let body = width > 0 ? DocTextCodec.wrap(text, width: width) : text
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
    }

    /// Inline content as plain text: link text only, image alt text, hard breaks kept.
    static func inlineText(_ inlines: [DocInline]) -> String { inlines.plainText }

    private static func renderTable(_ t: DocTable, indent: String) -> String {
        var rows: [[String]] = []
        if let h = t.header { rows.append(h.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }) }
        rows += t.rows.map { $0.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") } }
        let n = t.columnCount
        guard n > 0 else { return "" }
        var widths = [Int](repeating: 0, count: n)
        for r in rows { for (i, c) in r.enumerated() where i < n { widths[i] = max(widths[i], c.count) } }
        func line(_ r: [String]) -> String {
            let cells = (0..<n).map { i -> String in
                let c = i < r.count ? r[i] : ""
                return c + String(repeating: " ", count: max(0, widths[i] - c.count))
            }
            return indent + cells.joined(separator: " | ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var lines: [String] = []
        for (i, r) in rows.enumerated() {
            lines.append(line(r))
            if i == 0, t.header != nil { lines.append(indent + widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")) }
        }
        return lines.joined(separator: "\n")
    }
}
