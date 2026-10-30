import Foundation

// Inline Markdown: code spans, escapes, entities, emphasis / strong (CommonMark delimiter-run algorithm with the flanking and "multiple of three" rules),
// GFM strikethrough, links (inline, reference, collapsed, shortcut), images, autolinks (angle brackets and, in GFM, bare http / https / www), hard and soft breaks,
// and the small set of inline HTML tags people really use (br, b, strong, i, em, u, s, del, code, kbd, a, img).

final class InlineParser {
    private let gfm: Bool
    private let references: [String: DocMarkdown.Reference]

    init(gfm: Bool, references: [String: DocMarkdown.Reference]) { self.gfm = gfm; self.references = references }

    private struct Delim { var ch: Unicode.Scalar; var count: Int; var origCount: Int; var canOpen: Bool; var canClose: Bool }
    private enum Item {
        case node(DocInline)
        case delim(Delim)
        case bracket(isImage: Bool, srcStart: Int, active: Bool)
        case htmlOpen(tag: String, attrs: [String: String])
        case htmlClose(tag: String)
    }

    private static let asciiPunct = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)

    private func isPunct(_ u: Unicode.Scalar?) -> Bool {
        guard let u else { return false }
        if Self.asciiPunct.contains(u) { return true }
        return CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u)
    }
    private func isSpace(_ u: Unicode.Scalar?) -> Bool { u == nil || CharacterSet.whitespacesAndNewlines.contains(u!) }

    func parse(_ text: String) -> [DocInline] {
        let s = Array(text.unicodeScalars)
        var items = scan(s)
        processEmphasis(&items)
        let tree = resolveHTML(items)
        return gfm ? linkify(tree) : tree
    }

    /// GFM extended autolinks, applied to the finished tree like cmark-gfm does: only text that is not already inside a link, a code span or a picture, so
    /// `[http://example.com](/page)` stays one link and a URL never swallows the bracket and destination after it.
    private func linkify(_ inlines: [DocInline]) -> [DocInline] {
        var out: [DocInline] = []
        for node in inlines {
            switch node {
            case .text(let t): out += splitBareURLs(t)
            case .emphasis(let c): out.append(.emphasis(linkify(c)))
            case .strong(let c): out.append(.strong(linkify(c)))
            case .strike(let c): out.append(.strike(linkify(c)))
            case .underline(let c): out.append(.underline(linkify(c)))
            default: out.append(node)
            }
        }
        return out
    }

    private func splitBareURLs(_ t: String) -> [DocInline] {
        guard t.contains("http") || t.contains("HTTP") || t.lowercased().contains("www.") else { return [.text(t)] }
        let s = Array(t.unicodeScalars)
        var out: [DocInline] = []
        var plain = String.UnicodeScalarView()
        var i = 0
        func flush() { if !plain.isEmpty { out.append(.text(String(plain))); plain = String.UnicodeScalarView() } }
        while i < s.count {
            let c = s[i]
            if "hHwW".unicodeScalars.contains(c), i == 0 || !CharacterSet.alphanumerics.contains(s[i - 1]), let (url, len) = bareURL(s, at: i) {
                flush()
                out.append(.link(url: url, title: nil, content: [.text(String(String.UnicodeScalarView(s[i..<(i + len)])))]))
                i += len
            } else { plain.append(c); i += 1 }
        }
        flush()
        return out
    }

    // MARK: Scanning

    private func scan(_ s: [Unicode.Scalar]) -> [Item] {
        var items: [Item] = []
        var buf = String.UnicodeScalarView()
        var i = 0
        func flush() { if !buf.isEmpty { items.append(.node(.text(String(buf)))); buf = String.UnicodeScalarView() } }
        func appendText(_ str: String) { buf.append(contentsOf: str.unicodeScalars) }
        while i < s.count {
            let c = s[i]
            switch c {
            case "\\":
                if i + 1 < s.count, s[i + 1] == "\n" { flush(); items.append(.node(.lineBreak)); i += 2; while i < s.count, s[i] == " " { i += 1 }; continue }
                if i + 1 < s.count, Self.asciiPunct.contains(s[i + 1]) { buf.append(s[i + 1]); i += 2; continue }
                buf.append(c); i += 1
            case "`":
                var run = 0
                while i + run < s.count, s[i + run] == "`" { run += 1 }
                if let close = findClosingBackticks(s, from: i + run, count: run) {
                    var code = String(String.UnicodeScalarView(s[(i + run)..<close])).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) { code = String(code.dropFirst().dropLast()) }
                    flush(); items.append(.node(.code(code))); i = close + run
                } else { for _ in 0..<run { buf.append("`") }; i += run }
            case "*", "_", "~":
                if c == "~" && !gfm { buf.append(c); i += 1; continue }
                var run = 0
                while i + run < s.count, s[i + run] == c { run += 1 }
                if c == "~" && run > 2 { for _ in 0..<run { buf.append(c) }; i += run; continue }
                let before: Unicode.Scalar? = i > 0 ? s[i - 1] : nil
                let after: Unicode.Scalar? = i + run < s.count ? s[i + run] : nil
                let leftFlank = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before))
                let rightFlank = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after))
                let canOpen: Bool, canClose: Bool
                if c == "_" { canOpen = leftFlank && (!rightFlank || isPunct(before)); canClose = rightFlank && (!leftFlank || isPunct(after)) }
                else { canOpen = leftFlank; canClose = rightFlank }
                flush()
                items.append(.delim(Delim(ch: c, count: run, origCount: run, canOpen: canOpen, canClose: canClose)))
                i += run
            case "[":
                flush(); items.append(.bracket(isImage: false, srcStart: i + 1, active: true)); i += 1
            case "!":
                if i + 1 < s.count, s[i + 1] == "[" { flush(); items.append(.bracket(isImage: true, srcStart: i + 2, active: true)); i += 2 } else { buf.append(c); i += 1 }
            case "]":
                flush()
                i = closeBracket(s, at: i, items: &items)
            case "<":
                if let (node, len) = angleConstruct(s, at: i) {
                    flush()
                    items.append(node); i += len
                } else { buf.append(c); i += 1 }
            case "&":
                // Only a real entity shape (&name; &#123; &#x1F;) counts: a plain "&" followed by other text and a later ";" must not swallow the escapes in between.
                var semi = i + 1
                while semi < s.count, semi - i <= 33, (semi == i + 1 && s[semi] == "#") || CharacterSet.alphanumerics.contains(s[semi]) { semi += 1 }
                if semi < s.count, s[semi] == ";", semi > i + 1 {
                    let ent = String(String.UnicodeScalarView(s[i...semi]))
                    let dec = DocEntities.decode(ent)
                    if dec != ent { appendText(dec); i = semi + 1; continue }
                }
                buf.append(c); i += 1
            case "\n":
                // Two or more trailing spaces make a hard break.
                var trailing = 0
                var idx = buf.endIndex
                while idx > buf.startIndex, buf[buf.index(before: idx)] == " " { trailing += 1; idx = buf.index(before: idx) }
                if trailing > 0 { buf.removeLast(trailing) }
                flush()
                items.append(.node(trailing >= 2 ? .lineBreak : .softBreak))
                i += 1
                while i < s.count, s[i] == " " { i += 1 }
            default:
                buf.append(c); i += 1
            }
        }
        flush()
        // Trailing spaces at the very end are not content.
        if case .node(.text(let t))? = items.last, t.hasSuffix(" ") { items[items.count - 1] = .node(.text(t.replacingOccurrences(of: " +$", with: "", options: .regularExpression))) }
        return items
    }

    private func findClosingBackticks(_ s: [Unicode.Scalar], from: Int, count: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == "`" {
                var run = 0
                while i + run < s.count, s[i + run] == "`" { run += 1 }
                if run == count { return i }
                i += run
            } else { i += 1 }
        }
        return nil
    }

    // MARK: Links, images

    /// Handles a `]`: returns the new scan position.
    private func closeBracket(_ s: [Unicode.Scalar], at pos: Int, items: inout [Item]) -> Int {
        guard let idx = items.lastIndex(where: { if case .bracket = $0 { return true } else { return false } }),
              case .bracket(let isImage, let srcStart, let active) = items[idx] else {
            items.append(.node(.text("]"))); return pos + 1
        }
        guard active else { items[idx] = .node(.text(isImage ? "![" : "[")); items.append(.node(.text("]"))); return pos + 1 }
        var dest: (url: String, title: String?)?
        var next = pos + 1
        if next < s.count, s[next] == "(", let (u, t, end) = inlineDestination(s, from: next + 1) { dest = (u, t); next = end }
        else {
            var label = String(String.UnicodeScalarView(s[srcStart..<pos]))
            var consumed = pos + 1
            if next < s.count, s[next] == "[", let close = s[(next + 1)...].firstIndex(of: "]") {
                let l2 = String(String.UnicodeScalarView(s[(next + 1)..<close]))
                if !l2.isEmpty { label = l2 }
                consumed = close + 1
            }
            if let ref = references[BlockParser.normalizeLabel(label)] { dest = (ref.url, ref.title); next = consumed }
        }
        guard let d = dest else { items[idx] = .node(.text(isImage ? "![" : "[")); items.append(.node(.text("]"))); return pos + 1 }
        var inner = Array(items[(idx + 1)...])
        processEmphasis(&inner)
        let content = resolveHTML(inner)
        items.removeSubrange(idx...)
        if isImage {
            items.append(.node(.image(src: d.url, alt: content.plainText, title: d.title)))
        } else {
            items.append(.node(.link(url: d.url, title: d.title, content: content)))
            for k in 0..<items.count { if case .bracket(let img, let st, _) = items[k], !img { items[k] = .bracket(isImage: false, srcStart: st, active: false) } }
        }
        return next
    }

    /// Parses `url "title")` after the opening parenthesis; returns the position after `)`.
    private func inlineDestination(_ s: [Unicode.Scalar], from start: Int) -> (String, String?, Int)? {
        var i = start
        func skipWS() { while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\t" { i += 1 } }
        skipWS()
        var url = ""
        if i < s.count, s[i] == "<" {
            i += 1
            while i < s.count, s[i] != ">", s[i] != "\n" { if s[i] == "\\", i + 1 < s.count { i += 1 }; url.unicodeScalars.append(s[i]); i += 1 }
            guard i < s.count, s[i] == ">" else { return nil }
            i += 1
        } else {
            var depth = 0
            while i < s.count {
                let c = s[i]
                if c == " " || c == "\n" || c == "\t" { break }
                if c == "\\", i + 1 < s.count, Self.asciiPunct.contains(s[i + 1]) { url.unicodeScalars.append(s[i + 1]); i += 2; continue }
                if c == "(" { depth += 1 } else if c == ")" { if depth == 0 { break }; depth -= 1 }
                url.unicodeScalars.append(c); i += 1
            }
        }
        skipWS()
        var title: String?
        if i < s.count, s[i] == "\"" || s[i] == "'" || s[i] == "(" {
            let open = s[i]
            let close: Unicode.Scalar = open == "(" ? ")" : open
            i += 1
            var t = ""
            while i < s.count, s[i] != close { if s[i] == "\\", i + 1 < s.count { i += 1 }; t.unicodeScalars.append(s[i]); i += 1 }
            guard i < s.count else { return nil }
            i += 1; title = t
            skipWS()
        }
        guard i < s.count, s[i] == ")" else { return nil }
        return (DocEntities.decode(url), title, i + 1)
    }

    // MARK: Angle brackets: autolinks and inline HTML

    private static let autolinkRegex = try! NSRegularExpression(pattern: "^<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\\s]*)>")
    private static let emailRegex = try! NSRegularExpression(pattern: "^<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)>")
    private static let tagRegex = try! NSRegularExpression(pattern: "^<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+))?)*)\\s*(/?)>")

    private func angleConstruct(_ s: [Unicode.Scalar], at i: Int) -> (Item, Int)? {
        let tail = String(String.UnicodeScalarView(s[i..<min(s.count, i + 2048)]))
        let ns = tail as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = Self.autolinkRegex.firstMatch(in: tail, range: full) {
            let url = ns.substring(with: m.range(at: 1))
            return (.node(.link(url: url, title: nil, content: [.text(url.hasPrefix("mailto:") ? String(url.dropFirst(7)) : url)])), m.range.length)
        }
        if let m = Self.emailRegex.firstMatch(in: tail, range: full) {
            let mail = ns.substring(with: m.range(at: 1))
            return (.node(.link(url: "mailto:" + mail, title: nil, content: [.text(mail)])), m.range.length)
        }
        if tail.hasPrefix("<!--"), let end = tail.range(of: "-->") { return (.node(.text("")), tail.distance(from: tail.startIndex, to: end.upperBound)) }
        if let m = Self.tagRegex.firstMatch(in: tail, range: full) {
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let tag = ns.substring(with: m.range(at: 2)).lowercased()
            let selfClose = ns.substring(with: m.range(at: 4)) == "/"
            let attrs = Self.parseAttributes(ns.substring(with: m.range(at: 3)))
            let len = m.range.length
            if tag == "br" { return (.node(.lineBreak), len) }
            if tag == "img" { return (.node(.image(src: attrs["src"] ?? "", alt: attrs["alt"] ?? "", title: attrs["title"])), len) }
            if closing { return (.htmlClose(tag: tag), len) }
            if selfClose { return (.node(.text("")), len) }
            return (.htmlOpen(tag: tag, attrs: attrs), len)
        }
        return nil
    }

    static func parseAttributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: "([A-Za-z_:][A-Za-z0-9_.:-]*)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?") else { return out }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var v = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound { v = ns.substring(with: m.range(at: g)) }
            out[name] = DocEntities.decode(v)
        }
        return out
    }

    /// GFM extended autolink at a word boundary: `http(s)://...` and `www....`, trailing punctuation excluded.
    private func bareURL(_ s: [Unicode.Scalar], at i: Int) -> (String, Int)? {
        let head = String(String.UnicodeScalarView(s[i..<min(s.count, i + 8)])).lowercased()
        let isWWW = head.hasPrefix("www.")
        guard head.hasPrefix("http://") || head.hasPrefix("https://") || isWWW else { return nil }
        var j = i
        while j < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[j]), s[j] != "<" { j += 1 }
        var end = j
        while end > i {
            let last = s[end - 1]
            if ".,:;!?\"'*_~".unicodeScalars.contains(last) { end -= 1; continue }
            if last == ")" {
                let slice = s[i..<end]
                if slice.filter({ $0 == ")" }).count > slice.filter({ $0 == "(" }).count { end -= 1; continue }
            }
            break
        }
        let text = String(String.UnicodeScalarView(s[i..<end]))
        guard end - i > (isWWW ? 6 : 9) else { return nil }
        return (isWWW ? "http://" + text : text, end - i)
    }

    // MARK: Emphasis

    private func processEmphasis(_ items: inout [Item]) {
        var closer = 0
        while closer < items.count {
            guard case .delim(let c) = items[closer], c.canClose, c.count > 0 else { closer += 1; continue }
            var opener = closer - 1
            var found = false
            while opener >= 0 {
                if case .delim(let o) = items[opener], o.ch == c.ch, o.canOpen, o.count > 0 {
                    if c.ch == "~" { if o.count == c.count { found = true; break } }
                    else if !((c.canOpen || o.canClose) && (o.origCount + c.origCount) % 3 == 0 && !(o.origCount % 3 == 0 && c.origCount % 3 == 0)) { found = true; break }
                }
                opener -= 1
            }
            guard found, case .delim(var o) = items[opener], case .delim(var cl) = items[closer] else {
                if case .delim(var d) = items[closer], !d.canOpen { d.canClose = false; items[closer] = .delim(d) } else { closer += 1 }
                continue
            }
            let use = c.ch == "~" ? o.count : (o.count >= 2 && cl.count >= 2 ? 2 : 1)
            let inner = resolveHTML(Array(items[(opener + 1)..<closer]))
            let node: DocInline
            switch (c.ch, use) {
            case ("~", _): node = .strike(inner)
            case (_, 2): node = .strong(inner)
            default: node = .emphasis(inner)
            }
            o.count -= use; cl.count -= use
            var replacement: [Item] = []
            if o.count > 0 { replacement.append(.delim(o)) }
            replacement.append(.node(node))
            let closerPos = opener + replacement.count
            if cl.count > 0 { replacement.append(.delim(cl)) }
            items.replaceSubrange(opener...closer, with: replacement)
            closer = closerPos
        }
    }

    // MARK: Inline HTML pairs and final flattening

    private func resolveHTML(_ items: [Item]) -> [DocInline] {
        var stack: [(tag: String, attrs: [String: String], out: [DocInline])] = [("", [:], [])]
        func push(_ n: DocInline) { stack[stack.count - 1].out.append(n) }
        func wrap(_ tag: String, _ attrs: [String: String], _ c: [DocInline]) -> [DocInline] {
            switch tag {
            case "b", "strong": return [.strong(c)]
            case "i", "em": return [.emphasis(c)]
            case "u", "ins": return [.underline(c)]
            case "s", "strike", "del": return [.strike(c)]
            case "code", "kbd", "tt", "samp": return [.code(c.plainText)]
            case "a": if let h = attrs["href"] { return [.link(url: h, title: attrs["title"], content: c)] } else { return c }
            default: return c
            }
        }
        for it in items {
            switch it {
            case .node(let n): push(n)
            case .delim(let d): push(.text(String(repeating: String(d.ch), count: d.count)))
            case .bracket(let img, _, _): push(.text(img ? "![" : "["))
            case .htmlOpen(let tag, let attrs): stack.append((tag, attrs, []))
            case .htmlClose(let tag):
                if let k = stack.lastIndex(where: { $0.tag == tag }), k > 0 {
                    while stack.count - 1 > k { let t = stack.removeLast(); stack[stack.count - 1].out += t.out }   // unclosed inner tags: keep their content
                    let frame = stack.removeLast()
                    for n in wrap(frame.tag, frame.attrs, frame.out) { push(n) }
                }
            }
        }
        while stack.count > 1 { let t = stack.removeLast(); stack[stack.count - 1].out += t.out }
        return stack[0].out.normalized()
    }
}
