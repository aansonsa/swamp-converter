import Foundation
import CoreGraphics

// MODULE pdfocr (owner: PDF/OCR engineer). Prefix for new top-level types: Pdf* / Ocr*.
// Spec: spec/catalog.md 3.4, 3.10 (OCR), 5.1; spec/backends.md 3.3, 3.9, facts 8, 9 and traps 14, 15, 26; spec/handbrake.md 3.3, 4.5, 5.4.
// PDFKit + CoreGraphics render/merge/split/rotate/optimise/encrypt; Vision OCR (Russian + English, 30 languages) incl. searchable PDF.
// pdf.to.docx / .html / .epub / .pptx extract Markdown here and hand it to the docs module through `DocConverter`.
//
// Files: PdfCatalog (rows) / PdfOperations + PdfOcrOperation (classes) / PdfJobs (the work of each target) / PdfSchemas + PdfSchemasPages (option pages) /
// PdfRasterizer (render, encode) / OcrService + PdfOcrPipeline (Vision, searchable PDF) / PdfComposer (CoreGraphics writer) / PdfPageOps / PdfOptimizer /
// PdfProtection / PdfMarkdown (text formatting) / PdfProbe / PdfStudio (messages, estimates, previews) / PdfPresets / PdfTests*.

enum PdfEngine {
    /// Registered BEFORE docs/data/archives (wheel order: PDF tools come before "Archive").
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(PdfCatalog.operations())
        PresetStore.shared.registerBuiltins(PdfPresets.builtins)
        SourceProbeRegistry.shared.register(kinds: [.pdf], probe: PdfSourceProbe())
        PdfCapabilities.register()
    }

    /// Registered AFTER archives: "Extract text" is the last Tools slice of images and PDFs (spec/wheel.md 11.6).
    @MainActor
    static func registerOCR() {
        OperationRegistry.shared.register(PdfCatalog.ocrOperations())
    }

    #if !SC_SHIPPING
    static func registerSelfTests() {
        PdfTests.register()
        PdfTestsPages.register()
        PdfTestsOcr.register()
        PdfConformance.register()
    }
    #endif
}

enum PdfCapabilities {
    /// Ids: `native.vision.lang.<code>` per recognisable language (ru-RU, en-US ...), `native.vision.ocr` (any language). The checks run lazily: Vision is
    /// loaded the first time something asks, never at launch. Latvian, Lithuanian and Estonian have no id because Vision does not read them.
    static func register() {
        for code in OcrService.knownLanguageCodes {
            Capabilities.shared.register("native.vision.lang.\(code)") { OcrService.isSupported(code) }
        }
        Capabilities.shared.register("native.vision.ocr") { !OcrService.supportedIdentifiers().isEmpty }
    }
}
