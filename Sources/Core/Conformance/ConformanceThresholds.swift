import Foundation

// THE threshold table of the conformance suite for the oracles of the tools below. One place, one name per number, each with the reason it has that value: when a
// threshold has to move, it moves here, with the evidence, and not inside an oracle. (Older oracles keep their literals; new oracles take their numbers from here.)

enum ConformanceThresholds {
    /// OCR of a clean, rendered page (system UI font, black on white, 300 dpi): character error rate after whitespace and case folding.
    /// English is read nearly perfectly by Vision's accurate level; Russian has more look-alike glyphs (Cyrillic / Latin), so it gets a little more room.
    static let ocrCharacterErrorEnglish = 0.03
    static let ocrCharacterErrorRussian = 0.05

    /// PDF page extraction keeps the text of a page exactly (PDFKit text layer to PDFKit text layer, modulo layout).
    static let extractedPageWordRecall = 0.99
    /// ... and the page must look the same when both are rendered by PDFKit at 600 px width.
    static let extractedPagePSNR = 40.0

    /// PDF to pictures: PDFKit's own render of the page and the converter's picture (reduced by the same ImageIO scaler) agree to this PSNR; JPEG is lossy, PNG is exact.
    static let pdfRasterPSNRPNG = 30.0
    static let pdfRasterPSNRJPG = 25.0
    /// ... and an unrelated renderer (poppler pdftoppm at 100 dpi, when installed) sees the same page: correlation of the ink layout at 80 px width (anti-aliasing differences
    /// between two renderers average out there; a wrong page, a mirrored or shifted picture does not). The same page must also match better than the neighbouring page.
    static let pdfRasterLayoutCorrelation = 0.95

    /// Fit-to-size on a PDF may land far under the limit only when every page still matches the source this closely (PDFKit render at 900 px): the Quartz re-encoding has a top
    /// JPEG quality and a coarse jump above it, so a limit inside that jump has no better result to offer.
    static let fitPdfNearLosslessPSNR = 38.0

    /// PDF to PowerPoint goes through LibreOffice's PDF import: text frames break lines differently, so the recall is measured over words in order.
    static let pdfToPptxWordRecall = 0.85

    /// Slides to PDF: the text of every slide must be on its page.
    static let slideWordRecall = 0.99
    /// Slides rendered to pictures: PSNR against PDFKit's render of the deck's own PDF (made by LibreOffice directly), and a minimum share of dark "ink" pixels.
    static let slidePicturePSNRPNG = 30.0
    static let slidePicturePSNRJPG = 25.0
    static let slideMinInkFraction = 0.0004

    /// Joined videos (video.concat): total length within this many seconds of the sum of the clips, frame count within this share.
    static let joinDurationSeconds = 0.15
    static let joinFrameCountTolerance = 0.03
}

extension TextCompare {
    /// Character error rate: Levenshtein distance over the folded characters (NFC, case-folded, whitespace removed) divided by the length of `expected`.
    static func characterErrorRate(expected: String, actual: String) -> Double {
        func fold(_ s: String) -> [Character] { Array(normalize(s).lowercased().filter { !$0.isWhitespace }) }
        let a = fold(actual), b = fold(expected)
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))) }
            prev = cur
        }
        return Double(prev[b.count]) / Double(b.count)
    }
}
