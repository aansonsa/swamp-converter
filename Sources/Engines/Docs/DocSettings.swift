import Foundation

// The document options of one run, read once from the resolved `OptionValues` (keys of `DocKeys`). Every field here is read by exactly one place of the pipeline and has an
// oracle test; unknown or missing keys fall back to the quick recipe. `DocConverter.write(markdown:...)` (the PDF module's door) passes a sparse set, so defaults matter.

struct DocSettings: Equatable, Sendable {
    var target = "pdf"
    var engine = "auto"

    // Text
    var encodingIn = "auto"
    var encodingOut = "utf-8"
    var bom = false
    var eol = "lf"
    var wrap = 0
    var reflow: DocPlainText.Reflow = .auto

    // Page-based outputs (pdf, docx, odt, rtf)
    var pageSize = "a4"
    var marginMM = 20.0
    var font = "auto"
    var fontSize = 11.0
    var lineSpacing = 1.15
    var pageNumbers = false

    // Markdown, web, e-book
    var markdownGFM = true
    var extractMedia = false
    var frontMatter = false
    var htmlEmbed = true
    var epubSplit = 1
    var epubCover = ""

    // Metadata and pictures
    var stripMetadata = false
    var title: String?
    var author: String?
    var language: String?
    var stripImages = false

    init() {}

    init(_ o: OptionValues) {
        target = o.string(DocKeys.format, target)
        engine = o.string(DocKeys.engine, engine)
        encodingIn = o.string(DocKeys.encodingIn, encodingIn)
        encodingOut = o.string(DocKeys.encodingOut, encodingOut)
        bom = o.bool(DocKeys.bom, bom)
        eol = o.string(DocKeys.eol, eol)
        wrap = max(0, o.int(DocKeys.wrap, wrap))
        reflow = DocPlainText.Reflow(rawValue: o.string(DocKeys.reflow, "auto")) ?? .auto
        pageSize = o.string(DocKeys.pageSize, pageSize)
        marginMM = Util.clamp(o.double(DocKeys.margins, marginMM), 0, 80)
        font = o.string(DocKeys.font, font)
        fontSize = Util.clamp(o.double(DocKeys.fontSize, fontSize), 4, 96)
        lineSpacing = Util.clamp(o.double(DocKeys.lineSpacing, lineSpacing), 0.8, 3)
        pageNumbers = o.bool(DocKeys.pageNumbers, pageNumbers)
        markdownGFM = o.string(DocKeys.mdFlavor, "gfm") != "commonmark"
        extractMedia = o.bool(DocKeys.extractMedia, extractMedia)
        frontMatter = o.bool(DocKeys.mdFrontMatter, frontMatter)
        htmlEmbed = o.bool(DocKeys.htmlSingleFile, htmlEmbed)
        epubSplit = ["none": 0, "h1": 1, "h2": 2][o.string(DocKeys.epubSplit, "h1")] ?? 1
        epubCover = o.string(DocKeys.epubCover, epubCover)
        stripMetadata = o.string(DocKeys.metaMode, "keep") == "strip"
        title = o.string(DocKeys.title).nonEmpty
        author = o.string(DocKeys.author).nonEmpty
        language = o.string(DocKeys.language).nonEmpty
        stripImages = o.string(DocKeys.images, "keep") == "remove"
    }

    var page: DocPageSetup { DocPageSetup(size: pageSize, marginMillimetres: marginMM) }

    /// Font family for `target`: the choice, or the usual default of that format.
    func fontFamily(for target: String) -> String {
        if font != "auto", !font.isEmpty { return font }
        switch target {
        case "docx": return "Calibri"
        case "odt": return "Times New Roman"
        default: return "Helvetica Neue"
        }
    }

    /// The effective metadata: the source's, overridden by the fields, or nothing at all (apart from the language) when stripping.
    func metadata(of source: DocMeta) -> DocMeta {
        var m = source
        if stripMetadata {
            m.title = nil; m.author = nil; m.created = nil; m.modified = nil
            return m
        }
        if let t = title { m.title = t }
        if let a = author { m.author = a }
        if let l = language { m.language = l }
        return m
    }

    /// HTML `charset` name of an output encoding id.
    static func charsetName(_ id: String) -> String {
        switch id.lowercased() {
        case "utf-16", "utf-16le": return "utf-16le"
        case "utf-16be": return "utf-16be"
        case "cp866": return "ibm866"
        case "macroman": return "macintosh"
        default: return id.lowercased()
        }
    }
}
