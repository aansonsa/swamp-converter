import Foundation

/// Stable option keys of the PDF schemas (spec/handbrake.md 3.3). Adding keys is free; renaming/removing breaks presets.
enum PdfKeys {
    // Pages, rotation, page size
    static let pages = "pdf.pages"                  // "all", "1-3, 5, 8-" (PageRange in Core validates it)
    static let rotate = "pdf.rotate"                // 0, 90, 180, 270 (clockwise, added to the current rotation)
    static let rotateScope = "pdf.rotate.scope"     // all, odd, even, selected
    static let pageSize = "pdf.size"                // keep, a3, a4, a5, letter, legal
    static let pageSizeFit = "pdf.size.fit"         // fit, fill, none
    static let margins = "pdf.margins"              // mm, only with a page size
    static let trim = "pdf.trim"                    // mm cut from every side of every page (crop box)

    // Optimise
    static let level = "pdf.level"                  // screen, standard, high, custom
    static let mode = "pdf.mode"                    // keepText, raster
    static let imageDPI = "pdf.img.dpi"
    static let imageQuality = "pdf.img.q"
    static let imageGray = "pdf.img.gray"
    static let flatten = "pdf.flatten"
    static let stripMeta = "pdf.stripMeta"

    // OCR
    static let ocr = "pdf.ocr"
    static let ocrLanguages = "pdf.ocr.langs"       // rows: [{"lang": "ru-RU"}, ...] (order = priority)
    static let ocrAuto = "pdf.ocr.auto"
    static let ocrSkipText = "pdf.ocr.skipText"
    static let ocrDPI = "pdf.ocr.dpi"
    static let ocrOutput = "pdf.ocr.out"            // searchablePdf, txt, md, json
    static let ocrClipboard = "pdf.ocr.clipboard"

    // To images
    static let rasterFormat = "pdf.raster.fmt"      // png, jpeg, heic, tiff
    static let rasterDPI = "pdf.raster.dpi"
    static let rasterQuality = "pdf.raster.q"
    static let rasterBackground = "pdf.raster.bg"
    static let rasterTransparent = "pdf.raster.transparent"
    static let rasterGray = "pdf.raster.gray"
    static let rasterAnnotations = "pdf.raster.annots"

    // To text and documents
    static let textFormat = "pdf.text.fmt"          // txt, md
    static let textLayout = "pdf.text.layout"       // pdftotext -layout
    static let textSeparators = "pdf.text.pages"    // auto, marker, formfeed, none
    static let textEncoding = "pdf.text.enc"        // utf8, utf8bom, utf16, cp1251
    static let textReflow = "pdf.text.reflow"       // join wrapped lines into paragraphs
    static let exportFormat = "pdfx.format"         // docx, html, epub, pptx

    // Merge, split, extract
    static let mergeOrder = "pdf.merge.order"       // name, date, selection
    static let mergeBookmarks = "pdf.merge.bookmarks"
    static let mergeNormalize = "pdf.merge.norm"
    static let splitMode = "pdf.split.mode"         // eachPage, everyN, ranges, bySize, byBookmark
    static let splitEvery = "pdf.split.n"
    static let splitRanges = "pdf.split.ranges"
    static let splitMegabytes = "pdf.split.mb"
    static let extractMode = "pdf.extract.mode"     // keep, remove
    static let extractOrder = "pdf.extract.order"   // keep, reverse

    // Protection (secrets are never persisted: OptionField.persist = false)
    static let openPassword = "pdf.pw.open"
    static let ownerPassword = "pdf.pw.owner"
    static let allowPrint = "pdf.perm.print"
    static let allowCopy = "pdf.perm.copy"
    static let allowEdit = "pdf.perm.edit"
}

/// Schema ids of the PDF engine (Studio targets).
enum PdfTargets {
    static let images = "pdf.images", text = "pdf.text", export = "pdf.export", merge = "pdf.merge", split = "pdf.split"
    static let pages = "pdf.pages", optimize = "pdf.optimize", protect = "pdf.protect", ocr = "pdf.ocr"
    static let unlock = "pdf.unlock", extract = "pdf.extract"
}
