import Foundation
import CoreGraphics
import CoreText
import PDFKit
import AppKit

// Fixtures of the tools oracles: a presentation written by hand (ODP, readable by LibreOffice), a page of rendered text and a scanned-looking PDF (a picture of
// text with no text layer) for OCR, and a PDF whose pages carry their own number in the text for page extraction.

extension ConformanceFixtures {
    /// The text of slide `i` of `odp()`: Latin, a number and Cyrillic.
    static func slideText(_ i: Int) -> String { "Slide \(i) of the swamp deck: Привет \(i)" }

    /// A presentation written by hand (mimetype first and stored): `slides` pages of 28 x 15.75 cm, each with one text frame.
    func odp(_ name: String = "deck.odp", slides: Int = 3) throws -> URL {
        let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:presentation=\"urn:oasis:names:tc:opendocument:xmlns:presentation:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\""
        let decl = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        var pages = ""
        for i in 1...slides {
            pages += "<draw:page draw:name=\"page\(i)\" draw:style-name=\"dp1\" draw:master-page-name=\"Default\"><draw:frame draw:style-name=\"gr1\" draw:name=\"t\(i)\" svg:x=\"1.5cm\" svg:y=\"1.5cm\" svg:width=\"24cm\" svg:height=\"3cm\"><draw:text-box><text:p>\(Self.slideText(i))</text:p></draw:text-box></draw:frame></draw:page>"
        }
        let content = decl + "<office:document-content \(ns) office:version=\"1.2\"><office:automatic-styles><style:style style:name=\"dp1\" style:family=\"drawing-page\"><style:drawing-page-properties presentation:background-visible=\"true\" presentation:background-objects-visible=\"true\" draw:fill=\"none\"/></style:style><style:style style:name=\"gr1\" style:family=\"graphic\"><style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/></style:style></office:automatic-styles><office:body><office:presentation>\(pages)</office:presentation></office:body></office:document-content>"
        let styles = decl + "<office:document-styles \(ns) office:version=\"1.2\"><office:automatic-styles><style:page-layout style:name=\"PM1\"><style:page-layout-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:page-width=\"28cm\" fo:page-height=\"15.75cm\" style:print-orientation=\"landscape\"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"PM1\"/></office:master-styles></office:document-styles>"
        let manifest = decl + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"application/vnd.oasis.opendocument.presentation\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
        return try zipParts(name, ["mimetype": "application/vnd.oasis.opendocument.presentation", "content.xml": content, "styles.xml": styles, "META-INF/manifest.xml": manifest],
                            order: ["mimetype", "META-INF/manifest.xml", "content.xml", "styles.xml"], storeFirst: true)
    }

    /// Black text on white, drawn with the system UI font into a pixel page (`size` px, one line per `lineHeight`). The page is "rendered text", not a photo.
    func textPage(lines: [String], size: CGSize = CGSize(width: 1700, height: 1100), fontSize: CGFloat = 46) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        var y = size.height - fontSize * 2
        for line in lines {
            let attr = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 90, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            y -= fontSize * 1.9
        }
        return ctx.makeImage()!
    }

    /// A PNG of a rendered text page.
    func textPagePNG(_ name: String, lines: [String]) throws -> URL {
        try base.writeImage(textPage(lines: lines), name: name, type: .png)
    }

    /// A scanned-looking PDF: every page is only a picture of text (no text layer), letter size.
    func scannedPDF(_ name: String, pages: [[String]]) throws -> URL {
        let doc = PDFDocument()
        for (i, lines) in pages.enumerated() {
            let image = NSImage(cgImage: textPage(lines: lines, size: CGSize(width: 1836, height: 2376), fontSize: 50), size: NSSize(width: 1836, height: 2376))
            let opts: [PDFPage.ImageInitializationOption: Any] = [.mediaBox: NSValue(rect: NSRect(x: 0, y: 0, width: 612, height: 792)), .compressionQuality: 0.9]
            guard let page = PDFPage(image: image, options: opts) else { throw TestFixtures.fail("cannot make a picture page") }
            doc.insert(page, at: i)
        }
        let u = url(name)
        guard doc.write(to: u) else { throw TestFixtures.fail("cannot write the scanned PDF \(name)") }
        return u
    }
}
