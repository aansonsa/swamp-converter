import Foundation

// MODULE docs (owner: documents engineer). Prefix for new top-level types: Doc* / Slides*.
// Files: Sources/Engines/Docs/*.
// Spec: spec/catalog.md 3.5 (documents), 3.6 (slides), 5.1, 6.2; spec/backends.md 3.4 (documents), 3.5 (Office), facts 6; spec/handbrake.md 3.4 (schema), 4.5 (presets), 5.4 (oracles);
//       spec/platform.md 5.1-5.3 (textutil, document -> PDF without LibreOffice, Markdown without pandoc).
//
// Native first: our own readers and writers (DOCX, ODT, EPUB, RTF, HTML, Markdown, plain text, PDF through CoreText) cover every pair of the eight formats; the two legacy formats
// (binary .doc, RTF) are read through /usr/bin/textutil. Pandoc and LibreOffice (`soffice`) are OPTIONAL upgrades chosen by `DocRouter`: slides need LibreOffice, a Word
// file going to PDF keeps its layout with it. A conversion that needs a missing tool is shown disabled with the install hint, never faked.

enum DocsEngine {
    /// Registers the 8 document operations `doc.to.*` and the 5 slide operations `slides.to.*` (Convert wheel), schemas `doc.convert` / `slides.convert`,
    /// built-in presets and the probe. Called after PdfEngine.registerOperations (wheel order: images, audio, video, PDF, documents, slides ...).
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(DocsCatalog.operations())
        PresetStore.shared.registerBuiltins(DocsPresets.builtins)
        SourceProbeRegistry.shared.register(kinds: [.document, .slides], probe: DocSourceProbe())
        DocCapabilities.register()
    }

    #if !SC_SHIPPING
    static func registerSelfTests() { DocsTests.register() }
    #endif
}

enum DocCapabilities {
    /// `native.textutil` (legacy .doc / RTF reading), `native.doc.pdf` (own CoreText layout) and `native.doc.formats` (own DOCX / ODT / EPUB / RTF readers and writers) are
    /// always present on macOS. The route for a pair is computed by `DocRouter`, not registered here. Closures are cheap and cached by Core.
    static func register() {
        Capabilities.shared.register("native.textutil") { ToolLocator.shared.has(.textutil) }
        Capabilities.shared.register("native.doc.pdf") { true }
        Capabilities.shared.register("native.doc.formats") { true }
    }
}
