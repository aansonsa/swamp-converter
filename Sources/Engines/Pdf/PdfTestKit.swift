import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit

// Fixtures and helpers of the PDF self-tests (suite "pdf"). Everything is generated in a temp folder.

/// oracle id -> name of the test that proves it. `PdfTests` checks that every field of every schema is covered.
enum PdfOracles {
    private static let ledger = Locked<[String: String]>([:])
    static var map: [String: String] { ledger.value }
    static func record(_ ids: [String], test: String) { ledger.withLock { for id in ids { $0[id] = test } } }
}

func pdfTest(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
    PdfOracles.record(proves, test: name)
    SelfTestRegistry.shared.register("pdf", name, requires: requires, timeout: timeout, body)
}

enum PdfFixtures {
    /// 4 coloured quadrants: top-left red, top-right green, bottom-left blue, bottom-right yellow (as the page is displayed).
    @discardableResult
    static func quadrants(_ fx: TestFixtures, _ name: String = "quadrants.pdf", width: CGFloat = 300, height: CGFloat = 100) throws -> URL {
        let u = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(RGBA.red.cgColor); ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        ctx.setFillColor(RGBA.green.cgColor); ctx.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
        ctx.setFillColor(RGBA.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        ctx.setFillColor(RGBA.yellow.cgColor); ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))
        ctx.endPDFPage(); ctx.closePDF()
        return u
    }

    /// A page with nothing on it (no paper fill either), so the renderer's own background shows.
    @discardableResult
    static func blank(_ fx: TestFixtures, _ name: String = "empty.pdf", width: CGFloat = 612, height: CGFloat = 792) throws -> URL {
        let u = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        return u
    }

    /// Text pages "Page N" + a body with Latin and Cyrillic words: `Swamp 12345 Привет мир` by default; `word(i)` gives the body of page i.
    @discardableResult
    static func text(_ fx: TestFixtures, _ name: String = "text.pdf", pages: Int = 3, word: ((Int) -> String)? = nil) throws -> URL {
        try fx.pdf(name, pages: pages, text: word ?? { "Swamp 12345 Привет мир стр\($0 + 1)" })
    }

    /// A page with a smooth photo-like picture plus faint noise: Flate (what Core Graphics writes) cannot shrink it, JPEG can, many times over.
    @discardableResult
    static func photo(_ fx: TestFixtures, _ name: String = "photo.pdf", pages: Int = 1, pixels: Int = 1200, caption: Bool = false) throws -> URL {
        let u = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.draw(photoImage(side: pixels, seed: UInt64(p + 7)), in: CGRect(x: 36, y: 100, width: 540, height: 540))
            if caption {
                let font = CTFontCreateUIFontForLanguage(.system, 20, nil)!
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Swamp 12345 Привет мир", attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
                ctx.textPosition = CGPoint(x: 36, y: 700)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return u
    }

    static func photoImage(side: Int, seed: UInt64) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SplitMix(seed: seed)
        if let p = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * side) {
            for y in 0..<side {
                for x in 0..<side {
                    let o = y * ctx.bytesPerRow + x * 4
                    let n = Int(rng.next() % 9) - 4
                    p[o] = UInt8(max(0, min(255, 40 + x * 200 / side + n)))
                    p[o + 1] = UInt8(max(0, min(255, 60 + y * 180 / side + n)))
                    p[o + 2] = UInt8(max(0, min(255, 200 - (x + y) * 120 / (2 * side) + n)))
                    p[o + 3] = 255
                }
            }
        }
        return ctx.makeImage()!
    }

    /// An image of text lines on white (for recognition): 3x the point size of a letter page so the text is crisp.
    static func textImage(_ lines: [String], size: CGSize = CGSize(width: 1836, height: 2376), fontSize: CGFloat = 96) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        var y = size.height - fontSize * 2
        for line in lines {
            let attr = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 80, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            y -= fontSize * 1.9
        }
        return ctx.makeImage()!
    }

    /// A scanned-looking PDF: every page is only a picture of text (no text layer), letter size.
    @discardableResult
    static func scan(_ fx: TestFixtures, _ name: String = "scan.pdf", pages: [[String]]) throws -> URL {
        let doc = PDFDocument()
        for (i, lines) in pages.enumerated() {
            let img = NSImage(cgImage: textImage(lines), size: NSSize(width: 1836, height: 2376))
            let opts: [PDFPage.ImageInitializationOption: Any] = [.mediaBox: NSValue(rect: NSRect(x: 0, y: 0, width: 612, height: 792)), .compressionQuality: 0.9]
            guard let page = PDFPage(image: img, options: opts) else { throw TestFailure(message: "cannot make a picture page", file: #fileID, line: #line) }
            doc.insert(page, at: i)
        }
        let u = fx.url(name)
        guard doc.write(to: u) else { throw TestFailure(message: "cannot write the scan fixture", file: #fileID, line: #line) }
        return u
    }

    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> RGBA {
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: -CGFloat(x), y: -CGFloat(img.height - 1 - y))
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let a = px[3]
        if a == 0 { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, Int(v) * 255 / Int(a))) }
        return RGBA(r: un(px[0]), g: un(px[1]), b: un(px[2]), a: a)
    }
}

/// Runs operations of the catalogue the way the job runner does.
@MainActor
enum PdfRun {
    static func op(_ id: String) throws -> Operation {
        let all = PdfCatalog.operations() + PdfCatalog.ocrOperations()
        return try unwrap(all.first { $0.meta.id == id }, "operation \(id) is not in the PDF catalogue")
    }

    @discardableResult
    static func run(_ id: String, _ files: [URL], _ extra: OptionValues = OptionValues(), mode: RunMode = .quick, rules: OutputRules = OutputRules(),
                    log: ((String) -> Void)? = nil) async throws -> OperationResult {
        let operation = try op(id)
        let items = FileItem.items(files)
        let ctx = OperationContext.testing(operation, items: items, extra: extra, mode: mode, rules: rules)
        if let log { ctx.onLog = { log($0) } }
        defer { ctx.cleanupTemp() }
        return try await operation.execute(items: items, ctx: ctx)
    }

    nonisolated static func page(_ url: URL, _ i: Int = 0) throws -> PDFPage {
        try unwrap(PDFDocument(url: url)?.page(at: i), "cannot read page \(i + 1) of \(url.lastPathComponent)")
    }

    nonisolated static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? -1 }

    nonisolated static func text(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }
}
