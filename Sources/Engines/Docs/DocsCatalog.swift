import Foundation

// 8 document operations + 5 slides operations in wheel order (spec/catalog.md 3.5, 3.6). The operations differ only by their quick recipe (the target format); the
// behaviour is DocOperation's, a pure function of the resolved options.

enum DocsCatalog {
    static let docInputs = Formats.documentInputs
    static let slideInputs = Formats.slidesInputs

    @MainActor
    static func operations() -> [Operation] {
        let htmlSub = L10n("web", "веб-страница")
        let docTargets: [(String, L10n?)] = [("docx", Formats.friendlyName("docx")), ("pdf", nil), ("odt", nil), ("md", Formats.friendlyName("md")),
                                             ("html", htmlSub), ("txt", Formats.friendlyName("txt")), ("epub", Formats.friendlyName("epub")), ("rtf", nil)]
        var ops: [Operation] = docTargets.map { key, sub in
            DocOperation(.convert("doc.to.\(key)", .document, to: key, sub: sub, symbol: key == "pdf" ? "doc.richtext" : "doc.text", schema: DocSchemas.convertID, inputs: docInputs)) { _ in
                [DocKeys.format: .string(key)]
            }
        }
        for key in ["pdf", "png", "jpg", "pptx", "odp"] {
            let pictures = key == "png" || key == "jpg"
            ops.append(DocOperation(.convert("slides.to.\(key)", .slides, to: key, sub: pictures ? L10n("all slides", "все слайды") : nil,
                                             symbol: pictures ? "photo" : "rectangle.on.rectangle.angled", schema: DocSchemas.slidesID, inputs: slideInputs,
                                             requires: [.soffice], concurrency: .exclusive)) { settings in
                var v: OptionValues = [DocKeys.format: .string(key)]
                if pictures { v[DocKeys.slideDPI] = .int(settings.quality.pdfDpi) }
                if key == "jpg" { v[DocKeys.slideFormatQuality] = .int(settings.quality.jpegQuality) }
                return v
            })
        }
        return ops
    }
}
