import Foundation

// Writing archives: zip (ZipWriter), tar and tar.gz (TarWriter + zlib) are written in-process with deterministic order, no owner names and optional fixed dates;
// tar.bz2, tar.xz, tar.zst and 7z are made by libarchive (bsdtar) from a tar the app wrote itself, so Mac junk, ordering and names stay under the app's control.

enum ArchivePacker {
    /// Extensions whose content is already compressed: stored in a zip instead of deflated again (smaller CPU cost, the same size).
    static let storedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "jp2", "mp3", "m4a", "aac", "ogg", "opus", "flac", "mp4", "m4v", "mov", "mkv", "webm", "avi",
                                                "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "jar", "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "dmg"]

    static func compressionLevel(for format: ArchiveFormat, level: Int) -> Int {
        let l = max(0, min(9, level))
        switch format {
        case .tarBz2: return max(1, l)
        case .tarZst: return min(19, 1 + l * 2)
        default: return l
        }
    }

    /// Writes `entries` to `url`. `progress` gets 0...1. The file at `url` is partial after an error: callers use `ctx.produceFile`.
    static func write(_ entries: [ArchivePackEntry], format: ArchiveFormat, level: Int, to url: URL, ctx: OperationContext?, progress: @escaping (Double) -> Void) async throws {
        let total = Double(max(ArchiveSource.totalBytes(entries), 1))
        var done = 0.0
        func tick(_ n: Int64) { done += Double(n); progress(min(done / total, 0.99)) }
        switch format {
        case .zip:
            let zip = try ZipWriter(url: url, level: level)
            for e in entries {
                try Task.checkCancellation()
                switch e.kind {
                case .directory: try zip.addDirectory(e.name, modified: e.modified)
                case .symlink: try zip.addSymlink(target: e.linkTarget ?? "", as: e.name, modified: e.modified)
                case .file:
                    let stored = level == 0 || storedExtensions.contains((e.name as NSString).pathExtension.lowercased())
                    try zip.add(file: e.url!, as: e.name, method: stored ? .stored : .deflate, modified: e.modified)
                    tick(e.size)
                }
            }
            try zip.finish()
        case .tar:
            let out = try FDWriter(url: url)
            try writeTar(entries, sink: { try out.write($0) }, tick: tick)
            try out.close()
        case .tarGz:
            let out = try FDWriter(url: url)
            let deflater = StreamDeflater(level: level, window: 31)
            try writeTar(entries, sink: { chunk in try deflater.write(chunk) { try out.write($0) } }, tick: tick)
            try deflater.finish { try out.write($0) }
            try out.close()
        case .tarBz2, .tarXz, .tarZst, .sevenZip:
            guard let ctx else { throw ConversionError.unsupported(L10n("This archive format needs a running job.", "Для этого формата архива нужна запущенная задача.")) }
            let tmp = ctx.tempDir.appendingPathComponent("pack-\(Util.hex8()).tar")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = try FDWriter(url: tmp)
            try writeTar(entries, sink: { try out.write($0) }, tick: { tick($0) })
            try out.close()
            progress(0.9)
            try await ArchiveTools.recompress(tar: tmp, as: format, level: level, to: url, ctx: ctx)
        case .gz, .bz2, .xz, .zst, .rar:
            throw ConversionError.unsupported(L10n("This archive format cannot be written.", "Этот формат архива нельзя создать."))
        }
        progress(1)
    }

    private static func writeTar(_ entries: [ArchivePackEntry], sink: @escaping (UnsafeRawBufferPointer) throws -> Void, tick: (Int64) -> Void) throws {
        let tar = TarWriter(sink: sink)
        for e in entries {
            try Task.checkCancellation()
            let mtime = Int64(e.modified.timeIntervalSince1970)
            switch e.kind {
            case .directory: try tar.addDirectory(e.name, mode: e.mode, mtime: mtime)
            case .symlink: try tar.addSymlink(e.name, target: e.linkTarget ?? "", mtime: mtime)
            case .file: try tar.addFile(e.name, from: e.url!, size: e.size, mode: e.mode, mtime: mtime); tick(e.size)
            }
        }
        try tar.finish()
    }

    // MARK: Verification

    /// Reads the finished archive back and checks it: every entry decodes (zip: sizes and CRC-32; tar: headers and data; others: libarchive lists it) and the entry count matches.
    /// Returns the number of entries found.
    static func verify(_ url: URL, format: ArchiveFormat, expectedEntries: Int, ctx: OperationContext) async throws -> Int {
        var found = 0
        switch format {
        case .zip:
            try ZipKit.test(url)
            found = try ZipKit.list(url).count
        case .tar, .tarGz:
            let source = try TarByteSource(url: url, gzip: format == .tarGz)
            try TarReader.stream(source) { entry, _ in if entry.kind != .other { found += 1 } }
        default:
            found = try await ArchiveTools.list(url, ctx: ctx).count
        }
        guard found == expectedEntries else {
            throw ConversionError.message(L10n("The archive failed its check: it holds \(found) entries instead of \(expectedEntries). Nothing was saved.",
                                               "Архив не прошёл проверку: в нём \(found) записей вместо \(expectedEntries). Результат не сохранён."))
        }
        return found
    }
}

/// libarchive's bsdtar (always present on macOS) plus the small system tools around it. Arguments are arrays; stdin is /dev/null so an encrypted archive fails at once
/// instead of asking for a passphrase in a loop.
enum ArchiveTools {
    static func bsdtar(_ ctx: OperationContext) throws -> URL { try ctx.tools.require(.bsdtar) }

    /// bsdtar -cf out [--xz ...] @tar
    static func recompress(tar: URL, as format: ArchiveFormat, level: Int, to out: URL, ctx: OperationContext) async throws {
        let exe = try bsdtar(ctx)
        let n = ArchivePacker.compressionLevel(for: format, level: level)
        var args: [String]
        switch format {
        case .tarBz2: args = ["--bzip2", "--options", "bzip2:compression-level=\(n)"]
        case .tarXz: args = ["--xz", "--options", "xz:compression-level=\(n)"]
        case .tarZst: args = ["--zstd", "--options", "zstd:compression-level=\(n)"]
        case .sevenZip: args = ["--format", "7zip", "--options", level == 0 ? "7zip:compression=copy" : "7zip:compression-level=\(n)"]
        default: throw ConversionError.unsupported(L10n("This archive format cannot be written.", "Этот формат архива нельзя создать."))
        }
        args += ["-cf", out.path, "@" + tar.path]
        try await ctx.runProcess(exe, args)
    }

    /// Entry names as libarchive lists them (`bsdtar -tf`). Encrypted archives throw `.encryptedArchive`.
    static func list(_ url: URL, ctx: OperationContext) async throws -> [String] {
        let exe = try bsdtar(ctx)
        let out = try await ctx.runProcess(exe, ["-tf", url.path], captureStdout: true, onStderrLine: { _ in }, allowNonZeroExit: true)
        if out.exitCode != 0 {
            let tail = out.stderrTail.joined(separator: "\n").lowercased()
            if tail.contains("passphrase") || tail.contains("encrypted") { throw ConversionError.encryptedArchive }
            throw ConversionError.message(L10n("Cannot read the archive: \(out.stderrTail.last ?? "unknown format").", "Не удалось прочитать архив: \(out.stderrTail.last ?? "неизвестный формат")."))
        }
        return out.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Same without a job (probes): a short blocking run.
    static func listQuick(_ url: URL, timeout: TimeInterval = 2.5) -> [String]? {
        guard let exe = ToolLocator.shared.url(.bsdtar) else { return nil }
        guard let text = SyncProcess.run(exe, ["-tf", url.path], timeout: timeout) else { return nil }
        if text.lowercased().contains("passphrase") || text.contains("Unrecognized archive format") || text.contains("bsdtar: Error") { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
