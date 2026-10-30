import Foundation

// 3 subtitle operations (spec/catalog.md 3.8). No tools needed: SubtitleKit is pure Swift. Inputs srt, vtt, ass, ssa, sbv; Studio adds ASS, SSA and SBV as targets.

enum SubsCatalog {
    static let inputs = Formats.subtitleInputs

    @MainActor
    static func operations() -> [Operation] {
        [SubsOperation(.convert("subs.to.srt", .subtitle, to: "srt", symbol: "captions.bubble", schema: SubsSchemas.convertID, inputs: inputs)) { _ in [SubsKeys.format: "srt"] },
         SubsOperation(.convert("subs.to.vtt", .subtitle, to: "vtt", symbol: "captions.bubble", schema: SubsSchemas.convertID, inputs: inputs)) { _ in [SubsKeys.format: "vtt"] },
         SubsOperation(.convert("subs.to.txt", .subtitle, to: "txt", sub: L10n("text only", "только текст"), symbol: "captions.bubble", schema: SubsSchemas.convertID, inputs: inputs)) { _ in [SubsKeys.format: "txt"] }]
    }
}

final class SubsOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues
    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) { self.quick = quick; super.init(meta: meta) }
    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { SubsSchemas.convert(items: items) }

    /// Decodes (detects the encoding), cleans, retimes and writes the chosen format in the chosen encoding (see `SubsConvert`).
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        try await SubsConvert.run(item, ctx: ctx, progress: progress)
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        let txt = options.string(SubsKeys.format) == "txt"
        let wide = options.string(SubsKeys.encodingOut) == "utf-16" ? 2.0 : 1.0
        return OperationEstimate(bytes: Int64(Double(total) * (txt ? 0.55 : 1.0) * wide), seconds: 0.1, confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        var chips = [options.string(SubsKeys.format, "srt").uppercased(), SubsConvert.encodingLabel(options.string(SubsKeys.encodingOut, "utf-8"), bom: options.bool(SubsKeys.bom))]
        let offset = options.double(SubsKeys.offset)
        if offset != 0 { chips.append(String(format: "%+.1f s", offset)) }
        if options.string(SubsKeys.fpsFrom, "off") != "off" { chips.append("\(options.string(SubsKeys.fpsFrom)) > \(options.string(SubsKeys.fpsTo, "off"))") }
        if options.bool(SubsKeys.removeSDH) || options.bool(SubsKeys.removeTags) { chips.append(L("cleaned", "очищено")) }
        return chips
    }
}

/// facts `sub.cues`, `duration`, `text.encoding`, `sub.format`; chips "412 cues", "Windows-1251", "1:32:10".
struct SubsSourceProbe: SourceProbe {
    func probe(_ item: FileItem) async -> SourceInfo {
        var info = SourceInfo(url: item.url, kind: item.kind)
        guard let (text, enc) = try? SubtitleKit.readText(item.url) else { return info }
        info.facts["text.encoding"] = .string(enc)
        info.chips.append(SourceChip(symbol: "textformat", text: enc))
        let format = SubtitleKit.sniff(text)
        info.facts["sub.format"] = .string(format.rawValue)
        guard let cues = try? SubtitleKit.parse(text, format: format) else {
            info.warnings.append(L10n("No subtitles were found in this file.", "В этом файле не найдено субтитров."))
            return info
        }
        info.facts["sub.cues"] = .int(cues.count)
        let end = cues.map(\.end).max() ?? 0
        info.facts["duration"] = .double(end)
        info.chips.insert(SourceChip(symbol: "captions.bubble", text: Loc.plural(cues.count, enOne: "\(cues.count) cue", enOther: "\(cues.count) cues",
                                                                                ruOne: "\(cues.count) реплика", ruFew: "\(cues.count) реплики", ruMany: "\(cues.count) реплик")), at: 0)
        info.chips.append(SourceChip(symbol: "clock", text: Util.formatTime(end)))
        return info
    }
}
