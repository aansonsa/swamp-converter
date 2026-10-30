import Foundation

// 5 spreadsheet operations (spec/catalog.md 3.7). Everything is native: own CSV / OOXML / ODF / BIFF8 code. LibreOffice is only an optional upgrade (PDF that keeps cell
// formatting, Excel files the native reader cannot open), found through ToolLocator and never required.

enum SheetCatalog {
    static let inputs = Formats.spreadsheetInputs

    @MainActor
    static func operations() -> [Operation] {
        let targets: [(String, L10n?)] = [("xlsx", Formats.friendlyName("xlsx")), ("csv", nil), ("tsv", nil), ("ods", nil), ("pdf", L10n("table", "таблица"))]
        return targets.map { key, sub in
            SheetOperation(.convert("sheet.to.\(key)", .spreadsheet, to: key, sub: sub, symbol: "tablecells", schema: SheetSchemas.convertID, inputs: inputs)) { _ in
                [SheetKeys.format: .string(key)]
            }
        }
    }
}

final class SheetOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues
    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) { self.quick = quick; super.init(meta: meta) }

    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { SheetSchemas.convert(items: items) }

    /// Reads the source (encoding / delimiter detection, sheets), cleans cells, writes the chosen format (see `SheetConvert`).
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        try await SheetConvert.run(item, ctx: ctx, progress: progress)
    }

    // MARK: Studio

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        let text: Set<String> = ["csv", "tsv"]
        let fromText = items.allSatisfy { text.contains($0.key) }
        let target = options.string(SheetKeys.format, "xlsx")
        var factor: Double
        switch (fromText, target) {
        case (true, "xlsx"), (true, "ods"): factor = 0.35
        case (true, "pdf"): factor = 1.2
        case (true, _): factor = 1.0
        case (false, "csv"), (false, "tsv"): factor = 5.0
        case (false, "pdf"): factor = 2.0
        default: factor = 1.0
        }
        if (target == "csv" || target == "tsv") && options.string(SheetKeys.encodingOut) == "utf-16" { factor *= 2 }
        return OperationEstimate(bytes: Int64(Double(total) * factor), seconds: max(0.2, Double(total) / 20_000_000), confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        let target = options.string(SheetKeys.format, "xlsx")
        var chips = [Formats.displayName(target)]
        if target == "csv" || target == "tsv" {
            chips.append(SheetSchemas.encodingLabel(options.string(SheetKeys.encodingOut, "utf-8-bom")))
            if target == "csv" { chips.append(SheetSchemas.delimiterLabel(options.string(SheetKeys.delimiterOut, "comma"))) }
        }
        if options.string(SheetKeys.sheets, "all") == "first" { chips.append(L("first sheet", "первый лист")) }
        return chips
    }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        var out: [OptionMessage] = []
        let target = options.string(SheetKeys.format, "xlsx")
        if target == "xlsx", let rows = source?.int("table.rows"), rows > XLSXWriter.maxRows {
            out.append(OptionMessage(id: "sheet.xlsx.rows", severity: .error,
                                     text: L10n("XLSX holds up to 1 048 576 rows per sheet; this table has \(rows). Choose CSV or ODS.", "В листе XLSX не больше 1 048 576 строк, а в таблице их \(rows). Выберите CSV или ODS."),
                                     fieldKey: SheetKeys.format, fix: OptionFix(title: L10n("Use CSV", "Выбрать CSV"), set: [SheetKeys.format: "csv"])))
        }
        return out
    }
}

extension SheetSchemas {
    /// Short names for the summary chips.
    static func encodingLabel(_ key: String) -> String {
        switch key {
        case "utf-8-bom": return "UTF-8 BOM"
        case "utf-8": return "UTF-8"
        case "utf-16": return "UTF-16"
        default: return DataEncoding(key: key)?.displayName ?? key
        }
    }
    static func delimiterLabel(_ key: String) -> String {
        switch key {
        case "semicolon": return L("delimiter ;", "разделитель ;")
        case "pipe": return L("delimiter |", "разделитель |")
        case "tab": return L("tab", "табуляция")
        default: return L("delimiter ,", "разделитель ,")
        }
    }
}
