import Foundation
import CoreText
import CoreGraphics

// Fonts, paragraph styles and attributed strings of the native PDF writer. CoreText lays the text out (line breaking, font fallback for Cyrillic / Latvian / CJK, kerning);
// strike-through and link rectangles are not CoreText features, so runs carry custom attributes that the writer turns into lines and PDF link annotations after drawing.

extension NSAttributedString.Key {
    static let docLink = NSAttributedString.Key("swamp.doc.link")
    static let docStrike = NSAttributedString.Key("swamp.doc.strike")
    static let docCode = NSAttributedString.Key("swamp.doc.code")
    static let ctFont = NSAttributedString.Key(kCTFontAttributeName as String)
    static let ctColor = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let ctUnderline = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
    static let ctParagraph = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
}

/// One piece of a paragraph: text, or a picture that is drawn as its own block (CoreText has no inline pictures worth the trouble).
enum PdfSegment {
    case text(NSAttributedString)
    case image(key: String, alt: String)
}

struct PdfTextStyle {
    var size: CGFloat
    var bold = false
    var italic = false
    var color = CGColor(gray: 0, alpha: 1)
    var alignment: CTTextAlignment = .natural
    /// Indent of the first line and of the following lines (hanging indents of list items).
    var firstLineIndent: CGFloat = 0
    var headIndent: CGFloat = 0
    var tabStop: CGFloat? = nil
    var lineHeightMultiple: CGFloat
}

final class PdfFonts {
    let family: String
    private var cache: [String: CTFont] = [:]

    init(family: String) { self.family = family }

    func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> CTFont {
        let key = "\(size)|\(bold)|\(italic)|\(mono)"
        if let f = cache[key] { return f }
        let base = CTFontCreateWithName((mono ? "Menlo" : family) as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        let f = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base)
        cache[key] = f
        return f
    }

    /// Does the family exist on this Mac (CoreText silently substitutes unknown names)?
    static func isInstalled(_ family: String) -> Bool {
        let f = CTFontCreateWithName(family as CFString, 12, nil)
        let name = CTFontCopyFamilyName(f) as String
        return name.caseInsensitiveCompare(family) == .orderedSame || (CTFontCopyFullName(f) as String).hasPrefix(family)
    }
}

enum PdfText {
    static func paragraphStyle(_ s: PdfTextStyle) -> CTParagraphStyle {
        var alignment = s.alignment
        var lhm = s.lineHeightMultiple
        var first = s.firstLineIndent
        var head = s.headIndent
        let tab = s.tabStop.map { CTTextTabCreate(.left, Double($0), nil) }
        var tabs: CFArray = (tab.map { [$0] } ?? []) as CFArray
        var settings: [CTParagraphStyleSetting] = []
        return withUnsafeMutablePointer(to: &alignment) { pa in
            withUnsafeMutablePointer(to: &lhm) { pl in
                withUnsafeMutablePointer(to: &first) { pf in
                    withUnsafeMutablePointer(to: &head) { ph in
                        withUnsafeMutablePointer(to: &tabs) { pt in
                            settings.append(CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pa))
                            settings.append(CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: pl))
                            settings.append(CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: pf))
                            settings.append(CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: ph))
                            if tab != nil { settings.append(CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: pt)) }
                            return CTParagraphStyleCreate(settings, settings.count)
                        }
                    }
                }
            }
        }
    }

    /// Splits inline content into text and picture segments. `style` is the base look of the surrounding block.
    static func segments(_ inlines: [DocInline], style: PdfTextStyle, fonts: PdfFonts, mediaExists: (String) -> Bool) -> [PdfSegment] {
        var out: [PdfSegment] = []
        let current = NSMutableAttributedString()
        let para = paragraphStyle(style)

        struct Flags { var bold: Bool; var italic: Bool; var underline = false; var strike = false; var mono = false; var link: String? }

        func flush() {
            if current.length > 0 { out.append(.text(NSAttributedString(attributedString: current))); current.deleteCharacters(in: NSRange(location: 0, length: current.length)) }
        }
        func add(_ text: String, _ f: Flags) {
            guard !text.isEmpty else { return }
            var attrs: [NSAttributedString.Key: Any] = [
                .ctFont: fonts.font(size: f.mono ? style.size * 0.92 : style.size, bold: f.bold, italic: f.italic, mono: f.mono),
                .ctColor: f.link != nil ? CGColor(srgbRed: 0.02, green: 0.39, blue: 0.76, alpha: 1) : style.color,
                .ctParagraph: para
            ]
            if f.underline || f.link != nil { attrs[.ctUnderline] = NSNumber(value: CTUnderlineStyle.single.rawValue) }
            if f.strike { attrs[.docStrike] = true }
            if f.mono { attrs[.docCode] = true }
            if let l = f.link { attrs[.docLink] = l }
            current.append(NSAttributedString(string: text, attributes: attrs))
        }
        func walk(_ items: [DocInline], _ f: Flags) {
            for i in items {
                switch i {
                case .text(let t): add(t, f)
                case .code(let c): var g = f; g.mono = true; add(c, g)
                case .emphasis(let c): var g = f; g.italic = true; walk(c, g)
                case .strong(let c): var g = f; g.bold = true; walk(c, g)
                case .strike(let c): var g = f; g.strike = true; walk(c, g)
                case .underline(let c): var g = f; g.underline = true; walk(c, g)
                case .link(let url, _, let c): var g = f; g.link = url.hasPrefix("#") || url.isEmpty ? nil : url; walk(c, g)
                case .image(let src, let alt, _):
                    if mediaExists(src) { flush(); out.append(.image(key: src, alt: alt)) }
                    else if !alt.isEmpty { add("[\(alt)]", f) }
                case .lineBreak: add("\u{2028}", f)
                case .softBreak: add(" ", f)
                }
            }
        }
        walk(inlines, Flags(bold: style.bold, italic: style.italic))
        flush()
        return out
    }

    static func plain(_ text: String, style: PdfTextStyle, fonts: PdfFonts, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .ctFont: fonts.font(size: mono ? style.size * 0.92 : style.size, bold: style.bold, italic: style.italic, mono: mono),
            .ctColor: style.color,
            .ctParagraph: paragraphStyle(style)
        ])
    }

    /// Natural single-line width of the widest line of `text` (table column sizing).
    static func naturalWidth(_ text: NSAttributedString) -> CGFloat {
        var widest: CGFloat = 0
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: range))
            widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        return widest
    }
}
