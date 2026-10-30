import Foundation

// Compact constructor for catalogue rows. Engines list their operations as one line each:
//
//   .make("image.to.jpg", .convert, .image, "JPG", symbol: "photo", schema: "image.convert", inputs: Formats.imageAndRawInputs, target: "jpg")
//   .make("image.half", .tools, .image, L10n("Shrink", "Уменьшить"), sub: L10n("50%"), symbol: "arrow.down.right.and.arrow.up.left",
//         schema: "image.convert", inputs: Formats.imageAndRawInputs, suffix: L10n("smaller", "уменьшено"))

extension OperationMeta {
    static func make(_ id: String, _ wheel: WheelKind, _ family: OperationFamily, _ label: L10n, sub: L10n? = nil, symbol: String,
                     schema: String, inputs: Set<String>? = nil, target: String? = nil, requires: [Tool] = [], suffix: L10n? = nil,
                     min: Int = 1, concurrency: ConcurrencyClass = .light, folders: Bool = false, anyFile: Bool = false,
                     prompts: [String] = [], studio: Bool = false, passthrough: PassthroughKind = .none) -> OperationMeta {
        OperationMeta(id: id, wheel: wheel, family: family, label: label, subtitle: sub, symbol: symbol, schemaID: schema, requires: requires,
                      targetFormat: target, inputs: inputs, acceptsDirectories: folders, acceptsAnyFile: anyFile, minItems: min, quickPromptKeys: prompts,
                      suffix: suffix, concurrency: concurrency, studioOnly: studio, isAppAction: false, passthrough: passthrough)
    }

    /// Convert wheel tile: the label is the upper-case format key ("JPG", "TAR.GZ"), same in both languages.
    static func convert(_ id: String, _ family: OperationFamily, to target: String, sub: L10n? = nil, symbol: String, schema: String,
                        inputs: Set<String>, requires: [Tool] = [], concurrency: ConcurrencyClass = .light,
                        passthrough: PassthroughKind = .none) -> OperationMeta {
        make(id, .convert, family, L10n(Formats.displayName(target)), sub: sub, symbol: symbol, schema: schema, inputs: inputs, target: target,
             requires: requires, concurrency: concurrency, passthrough: passthrough)
    }

    /// A sector of the LINK wheel: a download mode. Operations are `LinkOperation` subclasses.
    static func link(_ id: String, _ label: L10n, sub: L10n? = nil, symbol: String, schema: String) -> OperationMeta {
        var m = make(id, .link, .download, label, sub: sub, symbol: symbol, schema: schema)
        m.acceptsLinks = true
        m.usesNetwork = true
        return m
    }
}
