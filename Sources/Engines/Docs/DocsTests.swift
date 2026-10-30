import Foundation
import PDFKit

// Entry point of the documents self-tests (suite "docs"). The files DocsTests*.swift are grouped by what they prove:
//   DocsTests            catalogue, schemas, presets, probe, operation behaviour
//   DocsTestsConformance every operation against independent oracles (generated from the catalogue)
//   DocsTestsOptions     one test per schema option (the oracle ledger)
//   DocsTestsText        encodings, Markdown, HTML, plain text
//   DocsTestsRoutes      router, Pandoc / LibreOffice argument lists, fake tools, the real LibreOffice, cancellation

enum DocsTests {
    static func register() {
        registerCatalogue()
        DocsConformance.register()
        DocsOptionTests.register()
        DocsPageTests.register()
        DocsTextTests.register()
        DocsRouteTests.register()
        DocsSlidesTests.register()
        registerLedger()
    }

    // MARK: Catalogue

    private static func registerCatalogue() {
        docTest("wheel contents: a DOCX offers the other seven document targets, slides need LibreOffice") {
            let reg = OperationRegistry()
            reg.register(DocsCatalog.operations())
            let docx = [FileItem(url: URL(fileURLWithPath: "/tmp/a.docx"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: docx).map(\.id), ["doc.to.pdf", "doc.to.odt", "doc.to.md", "doc.to.html", "doc.to.txt", "doc.to.epub", "doc.to.rtf"])
            let pptx = [FileItem(url: URL(fileURLWithPath: "/tmp/a.pptx"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: pptx).map(\.id), ["slides.to.pdf", "slides.to.png", "slides.to.jpg", "slides.to.odp"])
        }

        docTest("every input format is offered every other target, and a mixed selection hides a target only when all files already have it") {
            let reg = OperationRegistry()
            reg.register(DocsCatalog.operations())
            for key in ["docx", "doc", "odt", "rtf", "md", "txt", "html", "epub"] {
                let ids = reg.entries(wheel: .convert, items: [FileItem(url: URL(fileURLWithPath: "/tmp/a.\(key)"), isDirectory: false)]).map(\.id)
                try expectEqual(ids.count, key == "doc" ? 8 : 7, "\(key) offers the targets other than itself")
                try expect(!ids.contains("doc.to.\(key)"), "\(key) does not offer itself")
            }
            let mixed = [FileItem(url: URL(fileURLWithPath: "/tmp/a.docx"), isDirectory: false), FileItem(url: URL(fileURLWithPath: "/tmp/b.pdf"), isDirectory: false)]
            try expect(reg.entries(wheel: .convert, items: mixed).allSatisfy { !$0.id.hasPrefix("doc.to.") }, "a PDF among DOCX files makes the document slices disappear")
            let two = [FileItem(url: URL(fileURLWithPath: "/tmp/a.docx"), isDirectory: false), FileItem(url: URL(fileURLWithPath: "/tmp/b.odt"), isDirectory: false)]
            try expect(reg.entries(wheel: .convert, items: two).map(\.id).contains("doc.to.docx"), "docx stays when one of the files is an odt")
        }

        docTest("subtitles follow Formats.friendlyName with the Russian words for text and web page") {
            let ops = DocsCatalog.operations()
            func sub(_ id: String) -> L10n? { ops.first { $0.meta.id == id }?.meta.subtitle }
            try expectEqual(sub("doc.to.docx")?.en, "Word")
            try expectEqual(sub("doc.to.md")?.en, "Markdown")
            try expectEqual(sub("doc.to.txt")?.ru, "текст")
            try expectEqual(sub("doc.to.html")?.ru, "веб-страница")
            try expectEqual(sub("doc.to.epub")?.ru, "электронная книга")
            try expect(sub("doc.to.pdf") == nil && sub("doc.to.odt") == nil && sub("doc.to.rtf") == nil, "pdf, odt and rtf have no subtitle")
            try expectEqual(sub("slides.to.png")?.ru, "все слайды")
        }

        docTest("slides operations need LibreOffice, run exclusively, and are shown disabled with the install hint when it is missing") {
            let slides = DocsCatalog.operations().filter { $0.meta.id.hasPrefix("slides.") }
            try expectEqual(slides.count, 5)
            let hasLO = ToolLocator.shared.has(.soffice)
            for op in slides {
                try expect(op.meta.requires == [.soffice], "\(op.meta.id) requires LibreOffice")
                try expectEqual(op.meta.concurrency, .exclusive)
                let a = op.availability(for: [FileItem(url: URL(fileURLWithPath: "/tmp/a.pptx"), isDirectory: false)], tools: .shared)
                if hasLO { try expect(a.isAvailable, "\(op.meta.id) is available when LibreOffice is installed") } else {
                    try expect(!a.isAvailable, "\(op.meta.id) unavailable without LibreOffice")
                    try expect(a.reason?.en.contains("brew install --cask libreoffice") == true && a.reason?.ru.contains("libreoffice") == true, "the reason carries the install command")
                }
            }
            // The reason text itself, independent of this Mac.
            let reason = Capabilities.reason(for: "tool.soffice")
            try expect(reason.en.contains("brew install --cask libreoffice") && reason.ru.contains("LibreOffice"), "the install hint for a missing LibreOffice")
            let docOp = try DocRun.op("doc.to.pdf")
            try expect(docOp.meta.concurrency == .light, "document operations stay light (the LibreOffice gate serialises their LibreOffice runs)")
        }

        docTest("document operations are available for every pair: the built-in engine reaches all of them") {
            for op in DocsCatalog.operations() where op.meta.id.hasPrefix("doc.to.") {
                for key in ["docx", "doc", "odt", "rtf", "md", "txt", "html", "epub"] where key != op.meta.targetFormat {
                    let a = op.availability(for: [FileItem(url: URL(fileURLWithPath: "/tmp/a.\(key)"), isDirectory: false)], tools: .shared)
                    try expect(a.isAvailable, "\(key) -> \(op.meta.targetFormat ?? "?") is available")
                }
            }
        }

        docTest("registration is cheap and the native capabilities are registered") {
            let t0 = Date()
            let ops = DocsCatalog.operations()
            _ = DocsPresets.builtins
            for op in ops { _ = op.meta; _ = op.quickOverrides(settings: SettingsData()) }
            try expect(Date().timeIntervalSince(t0) < 0.25, "building the catalogue, presets and recipes takes milliseconds")
            DocCapabilities.register()
            try expect(Capabilities.shared.has("native.doc.pdf") && Capabilities.shared.has("native.textutil"), "native capabilities are present")
        }

        docTest("quick recipes: a document operation sets only its target; slides pull dpi and JPG quality from the settings") {
            var settings = SettingsData()
            settings.quality.pdfDpi = 200
            settings.quality.jpegQuality = 77
            let md = try DocRun.op("doc.to.md")
            try expectEqual(md.quickOverrides(settings: settings), [DocKeys.format: "md"])
            let png = try DocRun.op("slides.to.png"), jpg = try DocRun.op("slides.to.jpg"), pdf = try DocRun.op("slides.to.pdf")
            try expectEqual(png.quickOverrides(settings: settings).int(DocKeys.slideDPI), 200)
            try expectEqual(jpg.quickOverrides(settings: settings).int(DocKeys.slideFormatQuality), 77)
            try expect(pdf.quickOverrides(settings: settings).has(DocKeys.slideDPI) == false, "slides.to.pdf has no picture options")
            try expectEqual(md.privacyOverrides(), [DocKeys.metaMode: "strip"])
        }

        docTest("every schema builds without items, has unique keys, valid defaults and conditions that reference existing keys") {
            for schema in [DocSchemas.convert(items: []), DocSchemas.slides(items: [])] {
                let keys = schema.allFields.map(\.key)
                try expectEqual(Set(keys).count, keys.count, "\(schema.id): unique keys")
                for f in schema.allFields {
                    try expect(!f.oracle.isEmpty, "\(f.key) has an oracle")
                    try expect(!f.label.en.isEmpty && !f.label.ru.isEmpty, "\(f.key) has both labels")
                }
                let known = Set(keys)
                for p in schema.pages {
                    for e in [p.visibleWhen].compactMap({ $0 }) { try expect(e.referencedKeys.isSubset(of: known), "\(p.id): page condition keys exist") }
                    for g in p.groups {
                        for e in [g.visibleWhen].compactMap({ $0 }) { try expect(e.referencedKeys.isSubset(of: known), "\(g.id): group condition keys exist") }
                        for f in g.fields {
                            for e in [f.visibleWhen, f.enabledWhen].compactMap({ $0 }) { try expect(e.referencedKeys.isSubset(of: known), "\(f.key): condition keys exist") }
                        }
                    }
                }
                let resolved = schema.resolve(layers: [])
                try expect(!resolved.hasErrors, "\(schema.id): defaults validate cleanly")
            }
            // The defaults of the document schema ARE the quick recipe the code assumes.
            let r = DocSchemas.convert(items: []).resolve(layers: [[DocKeys.format: "pdf"]])
            try expectEqual(DocSettings(r.values), { var s = DocSettings(); s.target = "pdf"; return s }(), "schema defaults equal DocSettings defaults")
        }

        docTest("conditions: page options appear for page formats, text options for text formats, nothing leaks into the others") {
            let schema = DocSchemas.convert(items: [])
            func inactive(_ format: String) -> Set<String> { schema.resolve(layers: [[DocKeys.format: .string(format)]]).inactive }
            try expect(!inactive("pdf").contains(DocKeys.pageSize) && !inactive("pdf").contains(DocKeys.pageNumbers), "pdf has page options")
            try expect(inactive("docx").contains(DocKeys.pageNumbers) && !inactive("docx").contains(DocKeys.pageSize), "page numbers are PDF only")
            try expect(inactive("txt").contains(DocKeys.pageSize) && inactive("md").contains(DocKeys.font), "text formats have no page options")
            try expect(!inactive("txt").contains(DocKeys.wrap) && inactive("md").contains(DocKeys.wrap), "wrapping is for TXT only")
            try expect(!inactive("md").contains(DocKeys.mdFlavor) && inactive("html").contains(DocKeys.mdFlavor), "flavour is for Markdown only")
            try expect(!inactive("epub").contains(DocKeys.epubSplit) && inactive("pdf").contains(DocKeys.epubSplit), "chapters are for EPUB only")
            try expect(!inactive("html").contains(DocKeys.htmlSingleFile) && inactive("txt").contains(DocKeys.images), "pictures do not exist in plain text")
            let strip = schema.resolve(layers: [[DocKeys.format: "docx", DocKeys.metaMode: "strip", DocKeys.title: "Kept?"]])
            try expect(strip.inactive.contains(DocKeys.title), "title and author are disabled while metadata is removed")
            try expectEqual(strip.values.string(DocKeys.title), "", "an inactive title resets to its default")
        }
    }

    // MARK: Ledger

    private static func registerLedger() {
        docTest("every option of both schemas names an oracle that a test proves") {
            let proved = DocOracles.map
            var missing: [String] = []
            for schema in [DocSchemas.convert(items: []), DocSchemas.slides(items: [])] {
                for f in schema.allFields where proved[f.oracle] == nil { missing.append("\(schema.id) \(f.key) -> \(f.oracle)") }
            }
            try expect(missing.isEmpty, "options without a proving test: \(missing.joined(separator: "; "))")
        }
    }
}
