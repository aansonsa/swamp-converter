import Foundation

// DocModel -> RTF 1.9 written by hand. The system writer (textutil / NSAttributedString) loses pictures and heading semantics (spec/platform.md 5.1); this one keeps
// headings (sizes + bold + outline level), lists (marker text with a hanging indent), tables (\trowd cells with borders), block quotes, code blocks, rules, links as
// fields and pictures as \pngblip / \jpegblip. The output is 7-bit ASCII: every non-ASCII character is written as a \u escape (with surrogate pairs for emoji).

enum DocRtfWriter {
    struct Options {
        var page = DocPageSetup(size: "a4", marginMillimetres: 20)
        var includeAuthorAndTitle = true
        var includeDates = true
        var font = "Helvetica Neue"
        var fontSize = 11.0
        var lineSpacing = 1.15
    }

    static func write(_ model: DocModel, options: Options = Options(), to url: URL) throws {
        let data = Data(render(model, options: options).utf8)
        try data.write(to: url)
    }

    static func render(_ model: DocModel, options o: Options) -> String {
        var w = Writer(model: model, o: o)
        let body = w.blocks(model.blocks, indent: 0)
        var s = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2700\\uc1\\deff0\n"
        s += "{\\fonttbl{\\f0\\fnil\\fcharset0 \(w.asciiName(o.font));}{\\f1\\fmodern\\fcharset0 Menlo;}}\n"
        s += "{\\colortbl;\\red0\\green0\\blue0;\\red5\\green99\\blue193;\\red242\\green242\\blue242;\\red166\\green166\\blue166;}\n"
        s += "{\\info"
        if o.includeAuthorAndTitle {
            if let t = model.meta.title, !t.isEmpty { s += "{\\title \(w.escape(t))}" }
            if let a = model.meta.author, !a.isEmpty { s += "{\\author \(w.escape(a))}" }
        }
        if o.includeDates {
            let c = Calendar(identifier: .gregorian)
            let d = c.dateComponents(in: TimeZone(identifier: "UTC")!, from: model.meta.created ?? Date())
            s += "{\\creatim\\yr\(d.year ?? 2000)\\mo\(d.month ?? 1)\\dy\(d.day ?? 1)\\hr\(d.hour ?? 0)\\min\(d.minute ?? 0)}"
        }
        s += "}\n"
        s += "\\paperw\(o.page.widthTwips)\\paperh\(o.page.heightTwips)\\margl\(o.page.marginTwips)\\margr\(o.page.marginTwips)\\margt\(o.page.marginTwips)\\margb\(o.page.marginTwips)\n"
        s += "\\f0\\fs\(Int((o.fontSize * 2).rounded()))\n"
        return s + body + "}\n"
    }

    private struct Writer {
        let model: DocModel
        let o: Options
        var wrotePicture = false

        init(model: DocModel, o: Options) { self.model = model; self.o = o }

        var halfPoints: Int { Int((o.fontSize * 2).rounded()) }
        var lineTwips: Int { Int((o.lineSpacing * 240).rounded()) }

        func asciiName(_ s: String) -> String { String(s.unicodeScalars.filter { $0.isASCII && $0 != ";" && $0 != "{" && $0 != "}" && $0 != "\\" }) }

        /// RTF text: backslash escapes, \u for everything outside ASCII, \line / \tab for controls.
        func escape(_ s: String) -> String {
            var out = ""
            for u in s.unicodeScalars {
                switch u {
                case "\\": out += "\\\\"
                case "{": out += "\\{"
                case "}": out += "\\}"
                case "\n": out += "\\line "
                case "\t": out += "\\tab "
                case "\r": break
                default:
                    if u.value < 0x20 { continue }
                    if u.value < 0x80 { out.unicodeScalars.append(u) } else {
                        for unit in String(u).utf16 { out += "\\u\(Int16(bitPattern: unit))?" }
                    }
                }
            }
            return out
        }

        mutating func blocks(_ bs: [DocBlock], indent: Int, quote: Bool = false) -> String {
            var out = ""
            for b in bs {
                switch b {
                case .heading(let level, let c):
                    let l = max(1, min(6, level))
                    let sizes: [Double] = [2.0, 1.5, 1.17, 1.0, 1.0, 1.0]       // the browser defaults: the HTML reader maps sizes back to levels 1 to 3
                    out += "\\pard\\keepn\\sb\(l == 1 ? 360 : 240)\\sa80\\li\(indent)\\outlinelevel\(l - 1)\\b\\fs\(Int((Double(halfPoints) * sizes[l - 1]).rounded())) \(inline(c))\\b0\\fs\(halfPoints)\\par\n"
                case .paragraph(let c):
                    if c.isBlank { continue }
                    out += "\\pard\\sa120\\sl\(lineTwips)\\slmult1\\li\(indent + (quote ? 720 : 0))" + (quote ? "\\i" : "") + " \(inline(c))" + (quote ? "\\i0" : "") + "\\par\n"
                case .list(let l):
                    for (i, item) in l.items.enumerated() {
                        let marker = l.ordered ? "\(l.start + i)." : "\\u8226?"
                        var first = true
                        for ib in item.blocks {
                            if first, case .paragraph(let c) = ib {
                                let box = item.checked.map { $0 ? "\\u9745? " : "\\u9744? " } ?? ""
                                out += "\\pard\\sa60\\sl\(lineTwips)\\slmult1\\li\(indent + 720)\\fi-360 \(marker)\\tab \(box)\(inline(c))\\par\n"
                                first = false
                                continue
                            }
                            if first { out += "\\pard\\sa60\\li\(indent + 720)\\fi-360 \(marker)\\par\n"; first = false }
                            out += blocks([ib], indent: indent + 720)
                        }
                        if first { out += "\\pard\\sa60\\li\(indent + 720)\\fi-360 \(marker)\\par\n" }
                    }
                case .quote(let inner): out += blocks(inner, indent: indent, quote: true)
                case .code(_, let text):
                    for line in text.components(separatedBy: "\n") {
                        out += "\\pard\\li\(indent)\\cbpat3\\f1\\fs\(max(12, halfPoints - 2)) \(escape(line))\\f0\\fs\(halfPoints)\\par\n"
                    }
                case .table(let t): out += table(t, indent: indent)
                case .rule: out += "\\pard\\sb120\\sa120\\brdrb\\brdrs\\brdrw10\\brsp1\\brdrcf4\\par\n"
                case .pageBreak: out += "\\pard\\page\\par\n"
                }
            }
            return out
        }

        private mutating func table(_ t: DocTable, indent: Int) -> String {
            let cols = max(1, t.columnCount)
            let width = Int(o.page.contentWidth * 20) - indent
            let cell = max(500, width / cols)
            func row(_ r: [[DocInline]], header: Bool) -> String {
                var s = "\\trowd\\trgaph108\\trleft\(indent)" + (header ? "\\trhdr" : "")
                for i in 0..<cols {
                    s += "\\clbrdrt\\brdrs\\brdrw10\\brdrcf4\\clbrdrl\\brdrs\\brdrw10\\brdrcf4\\clbrdrb\\brdrs\\brdrw10\\brdrcf4\\clbrdrr\\brdrs\\brdrw10\\brdrcf4"
                    if header { s += "\\clcbpat3" }
                    s += "\\cellx\(indent + cell * (i + 1))"
                }
                s += "\n"
                for i in 0..<cols {
                    let al = i < t.align.count ? t.align[i] : DocAlign.none
                    let jc = al == .center ? "\\qc" : (al == .right ? "\\qr" : "\\ql")
                    s += "\\pard\\intbl\(jc) " + (header ? "\\b " : "") + inline(i < r.count ? r[i] : []) + (header ? "\\b0" : "") + "\\cell\n"
                }
                return s + "\\row\n"
            }
            var s = ""
            if let h = t.header { s += row(h, header: true) }
            for r in t.rows { s += row(r, header: false) }
            return s + "\\pard\\sa0\\par\n"
        }

        // MARK: Inlines

        mutating func inline(_ items: [DocInline]) -> String {
            var out = ""
            for i in items {
                switch i {
                case .text(let t): out += escape(t)
                case .code(let c): out += "{\\f1 \(escape(c))}"
                case .emphasis(let c): out += "{\\i \(inline(c))}"
                case .strong(let c): out += "{\\b \(inline(c))}"
                case .strike(let c): out += "{\\strike \(inline(c))}"
                case .underline(let c): out += "{\\ul \(inline(c))}"
                case .link(let url, _, let c):
                    let inner = inline(c)
                    if url.isEmpty || url.hasPrefix("#") { out += inner } else {
                        out += "{\\field{\\*\\fldinst{HYPERLINK \"\(url.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "%22"))\"}}{\\fldrslt{\\cf2\\ul \(inner)}}}"
                    }
                case .image(let src, let alt, _):
                    if let p = picture(src) { out += p } else if !alt.isEmpty { out += escape("[\(alt)]") }
                case .lineBreak: out += "\\line "
                case .softBreak: out += " "
                }
            }
            return out
        }

        private func picture(_ src: String) -> String? {
            guard var m = model.media[src] else { return nil }
            if m.mime != "image/png" && m.mime != "image/jpeg" {
                guard let png = DocMediaKind.pngData(m.data) else { return nil }
                m = DocMedia(name: m.name, mime: "image/png", data: png)
            }
            let px = DocMediaKind.pixelSize(m.data) ?? (400, 300)
            var wPt = Double(px.width) * 0.75, hPt = Double(px.height) * 0.75
            let scale = min(1, o.page.contentWidth / wPt, o.page.contentHeight * 0.9 / hPt)
            wPt *= scale; hPt *= scale
            let blip = m.mime == "image/png" ? "\\pngblip" : "\\jpegblip"
            var hex = ""
            hex.reserveCapacity(m.data.count * 2 + m.data.count / 32)
            let digits = Array("0123456789abcdef")
            for (i, byte) in m.data.enumerated() {
                hex.append(digits[Int(byte >> 4)]); hex.append(digits[Int(byte & 15)])
                if i % 38 == 37 { hex.append("\n") }
            }
            return "{\\pict\(blip)\\picw\(px.width)\\pich\(px.height)\\picwgoal\(Int(wPt * 20))\\pichgoal\(Int(hPt * 20))\n\(hex)}"
        }
    }
}
