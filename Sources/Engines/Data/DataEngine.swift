import Foundation

// MODULE data (owner: data engineer). Prefix for new top-level types: Zip* / Sheet* / Sub* / Archive*.
// Files: Sources/Engines/Data/** -> Zip/ (shared zip layer), Text/ (encodings), Sheets/ (spreadsheets), Subtitles/ (SubtitleKit + operations), Archives/ (pack / extract / repack), Tests/.
// The three families are independent: the owner may hand one over (they share only `ZipKit` and `TextEncodingKit`).
// Spec: spec/catalog.md 3.7 (spreadsheets), 3.8 (subtitles), 3.9 (archives), 1.4; spec/backends.md 3.6 (spreadsheets), 3.7 (subtitles), 3.8 (archives), facts 6, 7, 10;
//       spec/handbrake.md 3.5-3.7 (schemas), 4.5 (presets), 5.4 (oracles); spec/platform.md 5.4-5.7.

enum DataEngine {
    /// Registers (in this order, after the docs engine): spreadsheets `sheet.to.*`, subtitles `subs.to.*`, archives `archive.extract`, `archive.to.*`, `pack.*`;
    /// schemas, presets, probes. Pure Swift for everything native (own CSV / OOXML / ODF / BIFF8 code, SubtitleKit, ZipKit, TarKit); LibreOffice is an optional upgrade
    /// (PDF with the sheet's look, Excel files the native reader cannot open); libarchive's bsdtar writes and reads bz2 / xz / zstd / 7z / rar.
    @MainActor
    static func registerOperations() {
        OperationRegistry.shared.register(SheetCatalog.operations())
        OperationRegistry.shared.register(SubsCatalog.operations())
        OperationRegistry.shared.register(ArchiveCatalog.operations())
        PresetStore.shared.registerBuiltins(DataPresets.builtins)
        SourceProbeRegistry.shared.register(kinds: [.spreadsheet], probe: SheetSourceProbe())
        SourceProbeRegistry.shared.register(kinds: [.subtitle], probe: SubsSourceProbe())
        SourceProbeRegistry.shared.register(kinds: [.archive], probe: ArchiveSourceProbe())
        ArchiveCapabilities.register()
    }

    #if !SC_SHIPPING
    static func registerSelfTests() { DataTests.register() }
    #endif
}
