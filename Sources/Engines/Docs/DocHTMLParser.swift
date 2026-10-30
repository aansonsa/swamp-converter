import Foundation

// A tolerant HTML tokenizer and tree builder (no WebKit, any thread): real-world pages and Word / textutil exports are not well-formed XML, so this follows the
// forgiving parts of the HTML rules: void elements, implied end tags (p, li, dt, dd, tr, td, th, thead / tbody), unknown end tags ignored, entities decoded.

final class DocHTMLNode {
    /// Lower-case tag name; "" for text nodes; "#root" for the synthetic root.
    let tag: String
    var text: String
    var attributes: [String: String]
    var children: [DocHTMLNode] = []
    weak var parent: DocHTMLNode?

    init(tag: String, text: String = "", attributes: [String: String] = [:]) { self.tag = tag; self.text = text; self.attributes = attributes }

    var isText: Bool { tag.isEmpty }
    var classes: [String] { (attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    func firstDescendant(_ name: String) -> DocHTMLNode? {
        for c in children { if c.tag == name { return c }; if let d = c.firstDescendant(name) { return d } }
        return nil
    }
    func descendants(_ name: String) -> [DocHTMLNode] {
        var out: [DocHTMLNode] = []
        for c in children { if c.tag == name { out.append(c) }; out += c.descendants(name) }
        return out
    }
    /// All text below this node (no tag interpretation; `br` becomes a newline).
    var textContent: String {
        if isText { return text }
        if tag == "br" { return "\n" }
        return children.map(\.textContent).joined()
    }
}

enum DocHTMLParser {
    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "command", "keygen"]
    private static let rawTextTags: Set<String> = ["script", "style"]
    private static let closesParagraph: Set<String> = ["address", "article", "aside", "blockquote", "center", "details", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "table", "ul"]

    static func parse(_ html: String) -> DocHTMLNode {
        let root = DocHTMLNode(tag: "#root")
        var stack: [DocHTMLNode] = [root]
        let s = Array(html.unicodeScalars)
        var i = 0
        var text = String.UnicodeScalarView()

        func flushText() {
            guard !text.isEmpty else { return }
            let raw = String(text)
            text = String.UnicodeScalarView()
            let decoded = DocEntities.decode(raw)
            let node = DocHTMLNode(tag: "", text: decoded)
            node.parent = stack.last
            stack.last?.children.append(node)
        }
        func open(_ tag: String, _ attrs: [String: String], selfClosing: Bool) {
            flushText()
            implicitClose(for: tag, stack: &stack)
            let node = DocHTMLNode(tag: tag, attributes: attrs)
            node.parent = stack.last
            stack.last?.children.append(node)
            if !voidTags.contains(tag) && !selfClosing { stack.append(node) }
        }
        func close(_ tag: String) {
            flushText()
            guard let k = stack.lastIndex(where: { $0.tag == tag }), k > 0 else { return }
            // Do not let a stray </p> or </li> pop through a table cell or a list boundary.
            stack.removeSubrange(k...)
        }

        while i < s.count {
            let c = s[i]
            guard c == "<" else { text.append(c); i += 1; continue }
            // Comment / CDATA / doctype / processing instruction.
            if matches(s, i, "<!--") {
                flushText()
                var j = i + 4
                while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                i = min(s.count, j + 3); continue
            }
            if matches(s, i, "<![CDATA[") {
                var j = i + 9
                var cdata = String.UnicodeScalarView()
                while j + 2 < s.count, !(s[j] == "]" && s[j + 1] == "]" && s[j + 2] == ">") { cdata.append(s[j]); j += 1 }
                flushText()
                let node = DocHTMLNode(tag: "", text: String(cdata)); node.parent = stack.last; stack.last?.children.append(node)
                i = min(s.count, j + 3); continue
            }
            if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" {
                var j = i + 2
                while j < s.count, s[j] != ">" { j += 1 }
                i = min(s.count, j + 1); continue
            }
            // End tag.
            if i + 1 < s.count, s[i + 1] == "/" {
                var j = i + 2
                var name = ""
                while j < s.count, isNameChar(s[j]) { name.unicodeScalars.append(s[j]); j += 1 }
                while j < s.count, s[j] != ">" { j += 1 }
                if name.isEmpty { text.append(c); i += 1; continue }
                close(name.lowercased())
                i = min(s.count, j + 1); continue
            }
            // Start tag.
            guard i + 1 < s.count, isNameStart(s[i + 1]) else { text.append(c); i += 1; continue }
            var j = i + 1
            var name = ""
            while j < s.count, isNameChar(s[j]) { name.unicodeScalars.append(s[j]); j += 1 }
            var attrs: [String: String] = [:]
            var selfClosing = false
            attributeLoop: while j < s.count {
                while j < s.count, isSpace(s[j]) { j += 1 }
                guard j < s.count else { break }
                if s[j] == ">" { j += 1; break attributeLoop }
                if s[j] == "/" { selfClosing = true; j += 1; if j < s.count, s[j] == ">" { j += 1; break attributeLoop }; continue }
                var an = ""
                while j < s.count, !isSpace(s[j]), s[j] != "=", s[j] != ">", s[j] != "/" { an.unicodeScalars.append(s[j]); j += 1 }
                if an.isEmpty { j += 1; continue }
                var av = ""
                while j < s.count, isSpace(s[j]) { j += 1 }
                if j < s.count, s[j] == "=" {
                    j += 1
                    while j < s.count, isSpace(s[j]) { j += 1 }
                    if j < s.count, s[j] == "\"" || s[j] == "'" {
                        let q = s[j]; j += 1
                        while j < s.count, s[j] != q { av.unicodeScalars.append(s[j]); j += 1 }
                        j += 1
                    } else {
                        while j < s.count, !isSpace(s[j]), s[j] != ">" { av.unicodeScalars.append(s[j]); j += 1 }
                    }
                }
                attrs[an.lowercased()] = DocEntities.decode(av)
            }
            let tag = name.lowercased()
            open(tag, attrs, selfClosing: selfClosing && !rawTextTags.contains(tag))
            i = j
            if rawTextTags.contains(tag), !selfClosing {
                var raw = String.UnicodeScalarView()
                let endMarker = "</" + tag
                while i < s.count {
                    if s[i] == "<", matchesCI(s, i, endMarker) { break }
                    raw.append(s[i]); i += 1
                }
                if !raw.isEmpty { let n = DocHTMLNode(tag: "", text: String(raw)); n.parent = stack.last; stack.last?.children.append(n) }
                while i < s.count, s[i] != ">" { i += 1 }
                i = min(s.count, i + 1)
                close(tag)
            }
        }
        flushText()
        return root
    }

    // MARK: Implied end tags

    private static func implicitClose(for tag: String, stack: inout [DocHTMLNode]) {
        func popTo(_ names: Set<String>, stopAt boundaries: Set<String>) {
            var k = stack.count - 1
            while k > 0 {
                let t = stack[k].tag
                if names.contains(t) { stack.removeSubrange(k...); return }
                if boundaries.contains(t) { return }
                k -= 1
            }
        }
        let listBoundary: Set<String> = ["ul", "ol", "table", "div", "blockquote", "td", "th", "body", "#root"]
        if closesParagraph.contains(tag) { popTo(["p"], stopAt: ["div", "td", "th", "li", "blockquote", "body", "table", "#root"]) }
        switch tag {
        case "li": popTo(["li"], stopAt: ["ul", "ol", "table", "td", "th", "#root"])
        case "dt", "dd": popTo(["dt", "dd"], stopAt: ["dl", "#root"])
        // A new row ends the open row WITH its open cell (popping only the cell would leave the old row open and nest the new one in it).
        case "tr": popTo(["tr"], stopAt: ["table", "thead", "tbody", "tfoot", "#root"])
        case "td", "th": popTo(["td", "th"], stopAt: ["tr", "table", "#root"])
        case "thead", "tbody", "tfoot": popTo(["thead", "tbody", "tfoot", "tr", "td", "th"], stopAt: ["table", "#root"])
        case "option": popTo(["option"], stopAt: ["select", "#root"])
        default: _ = listBoundary
        }
    }

    // MARK: Scanning helpers

    private static func isSpace(_ u: Unicode.Scalar) -> Bool { u == " " || u == "\n" || u == "\t" || u == "\r" || u == "\u{0C}" }
    private static func isNameStart(_ u: Unicode.Scalar) -> Bool { (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") }
    private static func isNameChar(_ u: Unicode.Scalar) -> Bool { isNameStart(u) || (u >= "0" && u <= "9") || u == "-" || u == ":" || u == "_" }
    private static func matches(_ s: [Unicode.Scalar], _ i: Int, _ lit: String) -> Bool {
        let l = Array(lit.unicodeScalars)
        guard i + l.count <= s.count else { return false }
        for k in 0..<l.count where s[i + k] != l[k] { return false }
        return true
    }
    private static func matchesCI(_ s: [Unicode.Scalar], _ i: Int, _ lit: String) -> Bool {
        let l = Array(lit.lowercased().unicodeScalars)
        guard i + l.count <= s.count else { return false }
        for k in 0..<l.count where Unicode.Scalar(String(s[i + k]).lowercased().unicodeScalars.first ?? s[i + k]) != l[k] { return false }
        return true
    }
}

// MARK: - Entities

enum DocEntities {
    /// Decodes `&name;`, `&#123;` and `&#x1F;`. Unknown names stay as written.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = String.UnicodeScalarView()
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            if u[i] == "&", let semi = u[i...].prefix(34).firstIndex(of: ";"), semi > i + 1 {
                let body = String(String.UnicodeScalarView(u[(i + 1)..<semi]))
                if let rep = replacement(body) { out.append(contentsOf: rep.unicodeScalars); i = semi + 1; continue }
            }
            out.append(u[i]); i += 1
        }
        return String(out)
    }

    private static func replacement(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") { value = UInt32(digits.dropFirst(), radix: 16) } else { value = UInt32(digits) }
            guard let v = value, let sc = Unicode.Scalar(v == 0 ? 0xFFFD : v) else { return nil }
            return String(Character(sc))
        }
        guard let cp = table[body] ?? table[body.lowercased() == body ? body : ""] else { return nil }
        return String(Character(Unicode.Scalar(cp)!))
    }

    private static let latin1 = "nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml"
    private static let greekUpper = "Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu Xi Omicron Pi Rho _ Sigma Tau Upsilon Phi Chi Psi Omega"
    private static let greekLower = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigmaf sigma tau upsilon phi chi psi omega"

    /// Latin Extended-A (the letters of Latvian, Lithuanian, Czech, Polish, Turkish ...), ASCII punctuation names and some typographic symbols.
    private static let extra: [String: UInt32] = {
        let extA = "Amacr amacr Abreve abreve Aogon aogon Cacute cacute Ccirc ccirc Cdot cdot Ccaron ccaron Dcaron dcaron Dstrok dstrok Emacr emacr _ _ Edot edot Eogon eogon Ecaron ecaron Gcirc gcirc Gbreve gbreve Gdot gdot Gcedil _ Hcirc hcirc Hstrok hstrok Itilde itilde Imacr imacr _ _ Iogon iogon Idot imath IJlig ijlig Jcirc jcirc Kcedil kcedil kgreen Lacute lacute Lcedil lcedil Lcaron lcaron Lmidot lmidot Lstrok lstrok Nacute nacute Ncedil ncedil Ncaron ncaron napos ENG eng Omacr omacr _ _ Odblac odblac OElig oelig Racute racute Rcedil rcedil Rcaron rcaron Sacute sacute Scirc scirc Scedil scedil Scaron scaron Tcedil tcedil Tcaron tcaron Tstrok tstrok Utilde utilde Umacr umacr Ubreve ubreve Uring uring Udblac udblac Uogon uogon Wcirc wcirc Ycirc ycirc Yuml Zacute zacute Zdot zdot Zcaron zcaron"
        var t: [String: UInt32] = [:]
        for (i, n) in extA.split(separator: " ").enumerated() where n != "_" { t[String(n)] = UInt32(0x100 + i) }
        let ascii: [String: UInt32] = ["excl": 33, "num": 35, "dollar": 36, "percnt": 37, "lpar": 40, "rpar": 41, "ast": 42, "midast": 42, "plus": 43, "comma": 44, "period": 46, "sol": 47,
            "colon": 58, "semi": 59, "equals": 61, "quest": 63, "commat": 64, "lsqb": 91, "lbrack": 91, "bsol": 92, "rsqb": 93, "rbrack": 93, "Hat": 94, "lowbar": 95, "UnderBar": 95,
            "grave": 96, "lcub": 123, "lbrace": 123, "verbar": 124, "vert": 124, "VerticalLine": 124, "rcub": 125, "rbrace": 125, "NewLine": 10, "Tab": 9,
            "hyphen": 0x2010, "dash": 0x2010, "horbar": 0x2015, "nldr": 0x2025, "hairsp": 0x200A, "puncsp": 0x2008, "numsp": 0x2007, "emsp13": 0x2004, "emsp14": 0x2005,
            "ZeroWidthSpace": 0x200B, "check": 0x2713, "cross": 0x2717, "star": 0x2606, "starf": 0x2605, "phone": 0x260E, "female": 0x2640, "male": 0x2642, "sung": 0x266A,
            "numero": 0x2116, "angst": 0x212B, "ohm": 0x2126, "mho": 0x2127, "copysr": 0x2117, "rightarrow": 0x2192, "leftarrow": 0x2190, "uparrow": 0x2191, "downarrow": 0x2193,
            "bigstar": 0x2605, "hearts": 0x2665, "half": 0xBD, "ThinSpace": 0x2009, "NonBreakingSpace": 0xA0, "lsquor": 0x201A, "ldquor": 0x201E, "OpenCurlyQuote": 0x2018,
            "CloseCurlyQuote": 0x2019, "OpenCurlyDoubleQuote": 0x201C, "CloseCurlyDoubleQuote": 0x201D, "centerdot": 0xB7, "bullet": 0x2022, "mldr": 0x2026, "tdot": 0x20DB]
        for (k, v) in ascii { t[k] = v }
        return t
    }()

    private static let table: [String: UInt32] = {
        var t: [String: UInt32] = ["quot": 34, "amp": 38, "apos": 39, "lt": 60, "gt": 62, "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402,
            "circ": 710, "tilde": 732, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212, "lsquo": 8216,
            "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
            "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "frasl": 8260, "euro": 8364, "image": 8465, "weierp": 8472, "real": 8476, "trade": 8482, "alefsym": 8501,
            "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596, "crarr": 8629, "lArr": 8656, "uArr": 8657, "rArr": 8658, "dArr": 8659, "hArr": 8660,
            "forall": 8704, "part": 8706, "exist": 8707, "empty": 8709, "nabla": 8711, "isin": 8712, "notin": 8713, "ni": 8715, "prod": 8719, "sum": 8721, "minus": 8722,
            "lowast": 8727, "radic": 8730, "prop": 8733, "infin": 8734, "ang": 8736, "and": 8743, "or": 8744, "cap": 8745, "cup": 8746, "int": 8747, "there4": 8756, "sim": 8764,
            "cong": 8773, "asymp": 8776, "ne": 8800, "equiv": 8801, "le": 8804, "ge": 8805, "sub": 8834, "sup": 8835, "nsub": 8836, "sube": 8838, "supe": 8839, "oplus": 8853,
            "otimes": 8855, "perp": 8869, "sdot": 8901, "lceil": 8968, "rceil": 8969, "lfloor": 8970, "rfloor": 8971, "lang": 9001, "rang": 9002, "loz": 9674, "spades": 9824,
            "clubs": 9827, "hearts": 9829, "diams": 9830, "thetasym": 977, "upsih": 978, "piv": 982]
        for (name, cp) in extra { t[name] = cp }
        for (i, n) in latin1.split(separator: " ").enumerated() { t[String(n)] = UInt32(160 + i) }
        for (i, n) in greekUpper.split(separator: " ").enumerated() where n != "_" { t[String(n)] = UInt32(913 + i) }
        for (i, n) in greekLower.split(separator: " ").enumerated() { t[String(n)] = UInt32(945 + i) }
        return t
    }()
}
