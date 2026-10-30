import Foundation

// Convert + Tools PDF operations (spec/catalog.md 3.4) plus Studio-only targets (protect) and OCR (3.10).
// With the native engines pdf.to.docx/html/epub need no pandoc (docs module writes them); pptx needs LibreOffice.
// Added to the original set: pdf.extract (page-range extraction) and pdf.unlock (known password; on the wheel only for protected files).

enum PdfCatalog {
    static let inputs: Set<String> = ["pdf"]

    @MainActor
    static func operations() -> [Operation] {
        var ops: [Operation] = []
        func convert(_ key: String, sub: L10n? = nil, symbol: String, schema: String, requires: [Tool] = [], concurrency: ConcurrencyClass = .light) {
            ops.append(PdfOperation(.convert("pdf.to.\(key)", .pdf, to: key, sub: sub, symbol: symbol, schema: schema, inputs: inputs, requires: requires, concurrency: concurrency)) { s in
                PdfQuick.convert(to: key, settings: s)
            })
        }
        convert("docx", sub: L10n("Word"), symbol: "doc.text", schema: PdfTargets.export)
        convert("jpg", sub: L10n("all pages", "все страницы"), symbol: "photo", schema: PdfTargets.images)
        convert("png", sub: L10n("all pages", "все страницы"), symbol: "photo", schema: PdfTargets.images)
        convert("pptx", sub: L10n("PowerPoint"), symbol: "doc", schema: PdfTargets.export, requires: [.soffice], concurrency: .exclusive)
        convert("txt", sub: L10n("text", "текст"), symbol: "text.alignleft", schema: PdfTargets.text)
        convert("md", sub: L10n("Markdown"), symbol: "text.alignleft", schema: PdfTargets.text)
        convert("html", sub: L10n("web", "веб-страница"), symbol: "doc.text", schema: PdfTargets.export)
        convert("epub", sub: L10n("e-book", "электронная книга"), symbol: "doc.text", schema: PdfTargets.export)

        func tool(_ id: String, _ label: L10n, sub: L10n? = nil, symbol: String, suffix: L10n? = nil, schema: String, studio: Bool = false, prompts: [String] = [],
                  encryptedOnly: Bool = false, passthrough: PassthroughKind = .none, quick: @escaping @Sendable (SettingsData) -> OptionValues = { _ in OptionValues() }) {
            ops.append(PdfOperation(.make(id, .tools, .pdf, label, sub: sub, symbol: symbol, schema: schema, inputs: inputs, suffix: suffix, prompts: prompts, studio: studio, passthrough: passthrough),
                                    wheelNeedsEncrypted: encryptedOnly, quick: quick))
        }
        ops.append(PdfMergeOperation(meta: .make("pdf.merge", .tools, .pdf, L10n("Merge PDFs", "Объединить PDF"), symbol: "arrow.triangle.merge", schema: PdfTargets.merge,
                                                 inputs: inputs, suffix: L10n("merged", "объединено"), min: 2)))
        tool("pdf.split", L10n("Split", "Разделить"), sub: L10n("into pages", "на страницы"), symbol: "rectangle.split.2x1", schema: PdfTargets.split)
        tool("pdf.rotate", L10n("Rotate", "Повернуть"), sub: L10n("right", "вправо"), symbol: "rotate.right", suffix: L10n("rotated", "повёрнуто"), schema: PdfTargets.pages,
             quick: { _ in [PdfKeys.rotate: "90", PdfKeys.rotateScope: "all"] })
        tool("pdf.optimize", L10n("Optimize", "Оптимизация"), symbol: "arrow.down.right.and.arrow.up.left", suffix: L10n("optimized", "оптимизировано"), schema: PdfTargets.optimize,
             passthrough: .identity,   // a file that cannot get smaller is handed back unchanged
             quick: { _ in [PdfKeys.mode: "keepText", PdfKeys.level: "standard"] })
        tool("pdf.extract", L10n("Extract pages", "Извлечь страницы"), sub: L10n("a range", "диапазон"), symbol: "doc.on.doc", suffix: L10n("extracted", "извлечено"),
             schema: PdfTargets.extract, prompts: [PdfKeys.pages])
        tool("pdf.unlock", L10n("Remove password", "Снять пароль"), symbol: "lock.open", suffix: L10n("unlocked", "без пароля"), schema: PdfTargets.unlock,
             prompts: [PdfKeys.openPassword], encryptedOnly: true)
        tool("pdf.protect", L10n("Protect", "Защитить"), symbol: "lock", suffix: L10n("protected", "защищено"), schema: PdfTargets.protect, studio: true)
        return ops
    }

    /// `tools.ocr`: images + PDF, no folders. Registered after the archives (see PdfEngine.registerOCR).
    @MainActor
    static func ocrOperations() -> [Operation] {
        [PdfOCROperation(meta: .make("tools.ocr", .tools, .ocr, L10n("Extract text", "Извлечь текст"), sub: L10n("OCR"), symbol: "text.viewfinder",
                                     schema: PdfTargets.ocr, inputs: Formats.imageAndRawInputs.union(["pdf"]), suffix: L10n("text", "текст")))]
    }
}

enum PdfQuick {
    /// Quick recipes: PDF -> images at settings.quality.pdfDpi / jpegQuality; text; export.
    static func convert(to key: String, settings s: SettingsData) -> OptionValues {
        switch key {
        case "jpg": return [PdfKeys.rasterFormat: "jpeg", PdfKeys.rasterDPI: .int(s.quality.pdfDpi), PdfKeys.rasterQuality: .int(s.quality.jpegQuality)]
        case "png": return [PdfKeys.rasterFormat: "png", PdfKeys.rasterDPI: .int(s.quality.pdfDpi)]
        case "txt": return [PdfKeys.textFormat: "txt", PdfKeys.textReflow: false]
        case "md": return [PdfKeys.textFormat: "md", PdfKeys.textReflow: true]
        default: return [PdfKeys.exportFormat: .string(key)]
        }
    }
}
