import Foundation

// The subtitle runner: read (encoding detection) -> parse -> clean -> merge -> retime -> shift -> repair -> serialise -> encode -> ctx.produceFile.
// A pure function of (file, ctx.options); it never looks at the operation id.

enum SubsConvert {
    static func encodingLabel(_ key: String, bom: Bool) -> String {
        switch key {
        case "utf-8": return bom ? "UTF-8 BOM" : "UTF-8"
        case "utf-16": return "UTF-16"
        default: return DataEncoding(key: key)?.displayName ?? key
        }
    }

    /// The cue pipeline of the options (pure; also used by tests and by other modules' external-subtitle options).
    static func transform(_ cues: [SubtitleCue], options o: OptionValues, format: SubtitleFormat) -> [SubtitleCue] {
        var out = SubtitleTools.stripped(cues, removeTags: o.bool(SubsKeys.removeTags), removeHearingImpaired: o.bool(SubsKeys.removeSDH))
        guard format != .txt else { return out }
        if o.bool(SubsKeys.mergeShort) { out = SubtitleTools.merged(out, minDuration: o.double(SubsKeys.mergeMin, 0.7)) }
        if let from = Double(o.string(SubsKeys.fpsFrom, "off")), let to = Double(o.string(SubsKeys.fpsTo, "off")) {
            out = SubtitleTools.retimed(out, fromFPS: from, toFPS: to)
        }
        out = SubtitleTools.shifted(out, by: o.double(SubsKeys.offset))
        if o.bool(SubsKeys.overlap) { out = SubtitleTools.overlapFixed(out) }
        return out
    }

    static func run(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        let formatKey = o.string(SubsKeys.format, "srt")
        let target = SubtitleKit.format(forKey: formatKey) ?? .srt
        let encKey = o.string(SubsKeys.encodingIn, "auto")
        let (text, encName) = try SubtitleKit.readText(item.url, encoding: encKey == "auto" ? nil : DataEncoding(key: encKey))
        ctx.log("Source encoding: \(encName)")
        progress.report(0.2)
        try ctx.checkCancelled()
        let cues = try SubtitleKit.parse(text, format: SubtitleKit.format(forKey: item.key) ?? SubtitleKit.sniff(text))
        let result = transform(cues, options: o, format: target)
        guard !result.isEmpty else {
            throw ConversionError.message(L10n("Every cue was removed by the clean-up options, so nothing is left to save.", "Все реплики удалены параметрами очистки, сохранять нечего."))
        }
        var body = SubtitleKit.serialize(result, as: target)
        if target == .txt, o.string(SubsKeys.txtJoin, "cue") == "paragraphs" { body = SubtitleKit.plainText(result, paragraphs: true) }
        let encoded = SubtitleOutput.encode(body, format: target, eol: o.string(SubsKeys.eol, "auto"), encodingKey: o.string(SubsKeys.encodingOut, "utf-8"), bom: o.bool(SubsKeys.bom))
        if encoded.replaced > 0 { ctx.log("\(encoded.replaced) characters are not in the chosen encoding and were replaced.") }
        progress.report(0.8)
        let url = try await ctx.produceFile(for: item, ext: target.rawValue) { temp in try encoded.data.write(to: temp) }
        progress.report(1)
        return [url]
    }
}
