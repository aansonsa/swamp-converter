import Foundation

/// Stable option keys of the document / slides schemas (spec/handbrake.md 3.4). Adding keys is free; renaming or removing breaks presets.
enum DocKeys {
    static let format = "doc.format"             // docx, pdf, odt, md, html, txt, epub, rtf (slides: pdf, png, jpg, pptx, odp)
    static let engine = "doc.engine"             // auto, native, pandoc, soffice
    static let encodingIn = "doc.enc.in"         // auto, utf-8, windows-1251, windows-1257, ...
    static let encodingOut = "doc.enc.out"       // txt / html / md output encoding
    static let bom = "doc.bom"
    static let pageSize = "doc.pdf.size"         // a4, letter, a5, legal, auto  (pdf, docx, odt, rtf)
    static let margins = "doc.pdf.margins"       // mm
    static let font = "doc.pdf.font"
    static let fontSize = "doc.pdf.fontSize"
    static let lineSpacing = "doc.pdf.lineSpacing"
    static let mdFlavor = "doc.md.flavor"        // gfm, commonmark
    static let extractMedia = "doc.md.media"     // extract images to a folder
    static let htmlSingleFile = "doc.html.embed" // embed resources
    static let wrap = "doc.txt.wrap"             // 0 (none), 72, 80, 100
    static let title = "doc.meta.title"
    static let author = "doc.meta.author"
    static let slideDPI = "slides.dpi"
    static let slideRange = "slides.range"
    static let slideFormatQuality = "slides.quality"

    // Added by the documents engineer (all optional: a preset without them keeps the quick recipe).
    static let eol = "doc.eol"                   // lf, crlf (txt, md, html)
    static let reflow = "doc.txt.reflow"         // auto, keep, join: line breaks of plain-text sources
    static let pageNumbers = "doc.pdf.numbers"
    static let mdFrontMatter = "doc.md.front"    // title / author / language as YAML front matter
    static let epubSplit = "doc.epub.split"      // h1, h2, none
    static let epubCover = "doc.epub.cover"      // path of a picture
    static let metaMode = "doc.meta.mode"        // keep, strip
    static let language = "doc.meta.lang"
    static let images = "doc.images"             // keep, remove
    static let slideBackground = "slides.background"   // #RRGGBB behind transparent slide areas (png / jpg)
}

enum DocSchemas {
    static let convertID = "doc.convert"
    static let slidesID = "slides.convert"

    /// Pages Format (target, engine, Studio info line), Text (encodings, line endings, wrapping), Page (size, margins, fonts), Content (Markdown, web, e-book), Metadata.
    /// Every field carries its oracle; the Output page is appended by Core. Works for an empty items array.
    static func convert(items: [FileItem]) -> OptionSchema { DocSchemaBuilder.convert(items: items) }
    /// Slides: target, slide range, DPI / quality / background for pictures.
    static func slides(items: [FileItem]) -> OptionSchema { DocSchemaBuilder.slides(items: items) }
}
