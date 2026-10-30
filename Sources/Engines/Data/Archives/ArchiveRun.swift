import Foundation

// The archive runners: extract (stage -> place), repack (extract to a private temp, pack the children) and pack (several items, one archive). Behaviour is a pure function of
// (items, ctx.options); results always go through OutputPaths so nothing half-written is left behind.

enum ArchiveRun {
    /// What "move the archive to the Trash afterwards" does. Tests replace it so no file lands in the user's Trash.
    nonisolated(unsafe) static var trashHook: (URL) -> Void = { _ = try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    static func packOptions(_ o: OptionValues, archiveName: String) -> ArchivePackOptions {
        var p = ArchivePackOptions()
        p.excludeJunk = o.bool(ArchiveKeys.excludeHidden, true)
        p.includeHidden = o.bool(ArchiveKeys.includeHidden, true)
        p.patterns = ArchivePackOptions.patterns(from: o.string(ArchiveKeys.excludePatterns))
        p.root = o.string(ArchiveKeys.rootFolder, "keep")
        p.archiveName = archiveName
        p.keepDates = o.bool(ArchiveKeys.keepDates, true)
        p.normaliseNames = o.bool(ArchiveKeys.normalise, true)
        return p
    }

    static func format(_ o: OptionValues) -> ArchiveFormat {
        let f = ArchiveFormat(key: o.string(ArchiveKeys.format, "zip")) ?? .zip
        return ArchiveFormat.writable.contains(f) ? f : .zip
    }

    // MARK: Extract

    static func extract(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        guard let archiveFormat = ArchiveFormat.resolve(item.url) else {
            throw ConversionError.unsupported(L10n("This file is not an archive the app can open.", "Этот файл не является архивом, который приложение умеет открыть."))
        }
        let dir = try ctx.outputDirectory(for: item)
        OwnOutputs.shared.beginWriting(to: dir)
        defer { OwnOutputs.shared.endWriting(to: dir) }
        let stage = dir.appendingPathComponent(".\(item.base).\(Util.hex8()).part", isDirectory: true)
        do { try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true) } catch { throw ConversionError.outputNotWritable(dir) }
        defer { try? FileManager.default.removeItem(at: stage) }

        var opts = ArchiveExtractOptions()
        opts.nameEncoding = ZipNameEncoding(key: o.string(ArchiveKeys.nameEncoding, "auto"))
        opts.flatten = o.bool(ArchiveKeys.flatten)
        opts.skipJunk = o.bool(ArchiveKeys.excludeHidden, true)
        opts.restoreDates = o.bool(ArchiveKeys.keepDates, true)
        opts.restorePermissions = o.bool(ArchiveKeys.permissions, true)
        let report = try await ArchiveExtractor.extract(item.url, into: stage, format: archiveFormat, options: opts, ctx: ctx, progress: { progress.report($0 * 0.9) })
        for s in report.skipped.prefix(20) { ctx.log("Skipped: \(s)") }
        try ctx.checkCancelled()
        let overwrite = OutputCollision(rawValue: o.string(ArchiveKeys.overwrite, "number")) ?? .number
        let outputs = try await ArchivePlacement.place(stage: stage, in: dir, archiveBase: item.base, mode: o.string(ArchiveKeys.extractTo, "smart"),
                                                       collision: ctx.outputRules.collision, overwrite: overwrite)
        progress.report(1)
        if o.bool(ArchiveKeys.deleteAfter) { trashHook(item.url) }
        return outputs
    }

    // MARK: Pack

    static func pack(_ items: [FileItem], ctx: OperationContext) async throws -> URL {
        let o = ctx.options
        let fmt = format(o)
        let name = items.count == 1 ? ctx.outputBaseName(for: items[0])
            : OutputPaths.expandTemplate(ctx.outputRules.nameTemplate, tokens: ["name": L("Archive", "Архив"), "suffix": ""])
        let entries = try ArchiveSource.collect(items.map(\.url), options: packOptions(o, archiveName: name))
        return try await write(entries, format: fmt, name: name, anchor: items[0], ctx: ctx)
    }

    static func repack(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = ctx.options
        guard let source = ArchiveFormat.resolve(item.url) else {
            throw ConversionError.unsupported(L10n("This file is not an archive the app can open.", "Этот файл не является архивом, который приложение умеет открыть."))
        }
        let stage = ctx.tempDir.appendingPathComponent("repack-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try await ArchiveExtractor.extract(item.url, into: stage, format: source, options: ArchiveExtractOptions(), ctx: ctx, progress: { progress.report($0 * 0.5) })
        // The children of the extracted tree are packed at the root: the new archive has the layout of the old one (no folder is added or lost).
        let children = DirectoryListing.names(stage.path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { stage.appendingPathComponent($0) }
        guard !children.isEmpty else { throw ConversionError.message(L10n("The archive is empty.", "Архив пуст.")) }
        var po = packOptions(o, archiveName: item.base)
        po.root = "keep"
        let entries = try ArchiveSource.collect(children, options: po)
        let url = try await write(entries, format: format(o), name: ctx.outputBaseName(for: item), anchor: item, ctx: ctx, progressBase: 0.5, progress: progress)
        return [url]
    }

    private static func write(_ entries: [ArchivePackEntry], format fmt: ArchiveFormat, name: String, anchor: FileItem, ctx: OperationContext,
                              progressBase: Double = 0, progress: ProgressSlice? = nil) async throws -> URL {
        let o = ctx.options
        guard !entries.isEmpty else { throw ConversionError.message(L10n("There is nothing to put into the archive.", "В архив нечего класть.")) }
        let url = try await ctx.produceFile(for: anchor, ext: fmt.fileExtension, base: name) { temp in
            try await ArchivePacker.write(entries, format: fmt, level: o.int(ArchiveKeys.level, 6), to: temp, ctx: ctx) { f in
                if let progress { progress.report(progressBase + (1 - progressBase) * f * 0.9) } else { ctx.report(f * 0.9) }
            }
            if o.bool(ArchiveKeys.verify, true) {
                let n = try await ArchivePacker.verify(temp, format: fmt, expectedEntries: entries.count, ctx: ctx)
                ctx.log("Checked the archive: \(n) entries")
            }
        }
        return url
    }

    // MARK: Studio helpers

    /// Rough size of an archive of `bytes` of input.
    static func packedEstimate(_ bytes: Int64, options o: OptionValues) -> Int64 {
        let level = Double(o.int(ArchiveKeys.level, 6))
        let ratio: Double
        switch o.string(ArchiveKeys.format, "zip") {
        case "tar": ratio = 1.0
        case "tar.xz", "7z": ratio = 0.45 - level * 0.012
        case "tar.zst": ratio = 0.55
        default: ratio = level == 0 ? 1.0 : 0.62 - level * 0.01
        }
        return Int64(Double(bytes) * max(0.1, min(1.0, ratio)))
    }

    static func packChips(_ o: OptionValues) -> [String] {
        let f = o.string(ArchiveKeys.format, "zip")
        var chips = [Formats.displayName(f)]
        if f != "tar" { chips.append(o.int(ArchiveKeys.level, 6) == 0 ? L("stored", "без сжатия") : L("level \(o.int(ArchiveKeys.level, 6))", "уровень \(o.int(ArchiveKeys.level, 6))")) }
        if !o.bool(ArchiveKeys.keepDates, true) { chips.append(L("no dates", "без дат")) }
        return chips
    }
}
