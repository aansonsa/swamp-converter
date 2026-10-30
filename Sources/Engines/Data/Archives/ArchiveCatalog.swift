import Foundation

// 6 archive operations (spec/catalog.md 3.9). Native: ZipKit and TarKit (own code), libarchive's bsdtar for bz2 / xz / zstd / 7z / rar, system gunzip-class tools for bare files.

enum ArchiveCatalog {
    static let inputs = Formats.archiveInputs

    @MainActor
    static func operations() -> [Operation] {
        var ops: [Operation] = [
            ArchiveOperation(.make("archive.extract", .convert, .archive, L10n("Extract", "Распаковать"), symbol: "archivebox", schema: ArchiveSchemas.extractID, inputs: inputs)) { _ in OptionValues() }
        ]
        for key in ["zip", "tar", "tar.gz"] {
            ops.append(ArchiveOperation(.convert("archive.to.\(key)", .archive, to: key, symbol: "archivebox", schema: ArchiveSchemas.packID, inputs: inputs)) { _ in [ArchiveKeys.format: .string(key)] })
        }
        // Pack: any files and folders (>= 1), one archive for the whole selection.
        for (key, sub) in [("zip", L10n("ZIP")), ("tar.gz", L10n("TAR.GZ"))] {
            var m = OperationMeta.make("pack.\(key)", .tools, .archive, L10n("Archive", "В архив"), sub: sub, symbol: "archivebox", schema: ArchiveSchemas.packID, folders: true, anyFile: true)
            m.suffix = nil
            ops.append(PackOperation(meta: m, format: key))
        }
        return ops
    }
}

/// archive.extract (schema archive.extract) and archive.to.* (schema archive.pack): the work is chosen by the schema, never by the operation id.
final class ArchiveOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues
    private var isExtract: Bool { meta.schemaID == ArchiveSchemas.extractID }
    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) { self.quick = quick; super.init(meta: meta) }
    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { isExtract ? ArchiveSchemas.extract(items: items) : ArchiveSchemas.pack(items: items) }
    override func privacyOverrides() -> OptionValues { isExtract ? OptionValues() : [ArchiveKeys.keepDates: false] }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        isExtract ? try await ArchiveRun.extract(item, ctx: ctx, progress: progress) : try await ArchiveRun.repack(item, ctx: ctx, progress: progress)
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        if isExtract {
            let unpacked = source?.number("archive.unpacked").map { Int64($0) }
            return OperationEstimate(bytes: unpacked ?? total * 3, seconds: Double(total) / 60_000_000 + 0.3, confidence: unpacked == nil ? .rough : .sampled)
        }
        return OperationEstimate(bytes: ArchiveRun.packedEstimate(total * 3, options: options), seconds: Double(total) / 25_000_000 + 0.3, confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        if isExtract {
            let place: [String: String] = ["smart": L("smart", "умно"), "folder": L("in a folder", "в папку"), "here": L("next to the archive", "рядом с архивом")]
            return [place[options.string(ArchiveKeys.extractTo, "smart")] ?? ""].filter { !$0.isEmpty }
        }
        return ArchiveRun.packChips(options)
    }
}

/// pack.zip / pack.tar.gz: ALL dropped items together (files and folders).
final class PackOperation: BatchOperation, @unchecked Sendable {
    let format: String
    init(meta: OperationMeta, format: String) { self.format = format; super.init(meta: meta) }
    override func quickOverrides(settings: SettingsData) -> OptionValues { [ArchiveKeys.format: .string(format)] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { ArchiveSchemas.pack(items: items) }
    override func privacyOverrides() -> OptionValues { [ArchiveKeys.keepDates: false] }

    override func process(_ items: [FileItem], ctx: OperationContext) async throws -> [URL] {
        [try await ArchiveRun.pack(items, ctx: ctx)]
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        return OperationEstimate(bytes: ArchiveRun.packedEstimate(total, options: options), seconds: Double(total) / 25_000_000 + 0.3, confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] { ArchiveRun.packChips(options) }
}

/// Formats the app can write right now: tar.bz2 / tar.xz / tar.zst / 7z come from libarchive; each one is tried once on a tiny archive and remembered.
enum ArchiveCapabilities {
    static func register() {
        for f in ["bz2", "xz", "zst", "7z"] {
            Capabilities.shared.register("native.archive.write.\(f)") { canWrite(f) }
        }
    }

    static func canWrite(_ key: String) -> Bool {
        guard let exe = ToolLocator.shared.url(.bsdtar) else { return false }
        let dir = AppPaths.makeTempDirectory(purpose: "archcap")
        defer { AppPaths.removeTemp(dir) }
        let src = dir.appendingPathComponent("a.txt")
        guard (try? Data("probe".utf8).write(to: src)) != nil else { return false }
        let out = dir.appendingPathComponent("o")
        let flags: [String]
        switch key {
        case "bz2": flags = ["--bzip2"]
        case "xz": flags = ["--xz"]
        case "zst": flags = ["--zstd"]
        default: flags = ["--format", "7zip"]
        }
        _ = SyncProcess.run(exe, flags + ["-cf", out.path, "-C", dir.path, "a.txt"], timeout: 5)
        return ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0) > 0
    }
}
