import Foundation

// Extraction into a hidden staging folder. zip: ZipKit (CP866 / CP1251 names, zip-slip and encryption checks before the first write). tar, tar.gz and gz: TarKit with the same
// safe sink. tar.bz2 / tar.xz / tar.zst / 7z / rar: libarchive (bsdtar) after the app has listed and checked every name itself. Bare .gz / .bz2 / .xz / .zst files are decompressed.

struct ArchiveExtractOptions: Sendable {
    var nameEncoding: ZipNameEncoding = .auto
    var flatten = false
    var skipJunk = true
    var restoreDates = true
    var restorePermissions = true

    var policy: ExtractionPolicy {
        var p = ExtractionPolicy()
        p.skipMacJunk = skipJunk; p.flatten = flatten; p.restoreDates = restoreDates; p.restorePermissions = restorePermissions
        return p
    }
}

enum ArchiveExtractor {
    /// Fills `stage` (an existing empty folder) with the archive's content. Throws `.encryptedArchive` first for protected archives and `.unsafeArchivePath` before anything
    /// escapes (nothing leaves `stage` in any case).
    @discardableResult
    static func extract(_ url: URL, into stage: URL, format: ArchiveFormat, options: ArchiveExtractOptions, ctx: OperationContext, progress: @escaping (Double) -> Void) async throws -> ExtractionReport {
        let report = try await extractUnmarked(url, into: stage, format: format, options: options, ctx: ctx, progress: progress)
        ArchiveSafety.propagateQuarantine(from: url, to: stage)        // an archive that came from the internet keeps its Gatekeeper mark on what it contained
        return report
    }

    private static func extractUnmarked(_ url: URL, into stage: URL, format: ArchiveFormat, options: ArchiveExtractOptions, ctx: OperationContext, progress: @escaping (Double) -> Void) async throws -> ExtractionReport {
        switch format {
        case .zip:
            var zo = ZipExtractOptions()
            zo.nameEncoding = options.nameEncoding; zo.policy = options.policy
            return try await ZipKit.unpack(url, to: stage, options: zo, progress: progress)
        case .tar: return try extractTar(url, gzip: false, into: stage, options: options, progress: progress)
        case .tarGz: return try extractTar(url, gzip: true, into: stage, options: options, progress: progress)
        case .gz:
            if try gzipHoldsTar(url) { return try extractTar(url, gzip: true, into: stage, options: options, progress: progress) }
            return try gunzipSingle(url, into: stage, progress: progress)
        case .tarBz2, .tarXz, .tarZst, .sevenZip, .rar, .bz2, .xz, .zst:
            return try await extractWithLibarchive(url, format: format, into: stage, options: options, ctx: ctx, progress: progress)
        }
    }

    // MARK: tar

    private static func extractTar(_ url: URL, gzip: Bool, into stage: URL, options: ArchiveExtractOptions, progress: @escaping (Double) -> Void) throws -> ExtractionReport {
        let sink = ExtractSink(root: stage, policy: options.policy)
        let source = try TarByteSource(url: url, gzip: gzip)
        var last = Date.distantPast
        try TarReader.stream(source) { entry, read in
            switch entry.kind {
            case .directory: try sink.makeDirectory(entry.name, modified: entry.modified, mode: entry.mode)
            case .symlink: try sink.makeSymlink(entry.name, target: entry.linkTarget ?? "", modified: entry.modified)
            case .hardlink: try sink.makeLinkCopy(entry.name, target: entry.linkTarget ?? "", modified: entry.modified)
            case .other: break
            case .file:
                guard let out = try sink.beginFile(entry.name, mode: entry.mode) else { return }
                do {
                    while true {
                        let chunk = try read(1 << 20)
                        if chunk.isEmpty { break }
                        try chunk.withUnsafeBytes { try out.write($0); try sink.addBytes($0.count) }
                    }
                } catch { out.close(modified: nil, mode: nil); throw error }
                sink.closeFile(out, modified: entry.modified, mode: entry.mode)
            }
            if Date().timeIntervalSince(last) > 0.08 {
                last = Date()
                progress(min(0.99, Double(source.consumedCompressed) / Double(max(source.totalCompressed, 1))))
            }
        }
        sink.finish()
        progress(1)
        return sink.report
    }

    /// A .gz file is a tar.gz when the first 512 bytes after inflating look like a tar header.
    static func gzipHoldsTar(_ url: URL) throws -> Bool {
        let source = try TarByteSource(url: url, gzip: true)
        let head = (try? source.read(512)) ?? []
        return TarHeader.looksLikeTar(head)
    }

    private static func gunzipSingle(_ url: URL, into stage: URL, progress: @escaping (Double) -> Void) throws -> ExtractionReport {
        let source = try TarByteSource(url: url, gzip: true)
        let name = Util.safeFileName(Formats.baseName(of: url), fallback: "file")
        let sink = ExtractSink(root: stage, policy: ExtractionPolicy())
        guard let out = try sink.beginFile(name, mode: nil) else { return sink.report }
        var last = Date.distantPast
        do {
            while true {
                let chunk = try source.read(1 << 20)
                if chunk.isEmpty { break }
                try chunk.withUnsafeBytes { try out.write($0); try sink.addBytes($0.count) }
                if Date().timeIntervalSince(last) > 0.08 { last = Date(); progress(min(0.99, Double(source.consumedCompressed) / Double(max(source.totalCompressed, 1)))) }
            }
        } catch { out.close(modified: nil, mode: nil); throw error }
        sink.closeFile(out, modified: (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil, mode: nil)
        progress(1)
        return sink.report
    }

    // MARK: libarchive

    private static func extractWithLibarchive(_ url: URL, format: ArchiveFormat, into stage: URL, options: ArchiveExtractOptions, ctx: OperationContext,
                                             progress: @escaping (Double) -> Void) async throws -> ExtractionReport {
        let names: [String]
        do { names = try await ArchiveTools.list(url, ctx: ctx) }
        catch let e as ConversionError {
            if case .encryptedArchive = e { throw e }
            if let bare = format.wrapsSingleFile ? format : format.bare { return try await decompressSingle(url, format: bare, into: stage, ctx: ctx, progress: progress) }
            throw e
        }
        let sink = ExtractSink(root: stage, policy: options.policy)
        for n in names { _ = try sink.relativePath(for: n) }                       // zip slip: every name is checked before bsdtar writes anything
        let exe = try ArchiveTools.bsdtar(ctx)
        // Permissions only: no ACLs, file flags or extended attributes from the archive (a "-p" alone restores all of them, including flags a user cannot undo), no owner.
        var args = ["-xf", url.path, "-C", stage.path, "--no-same-owner", "-v"]
        if options.restoreDates { args += ["-p", "--no-acls", "--no-fflags", "--no-xattrs"] } else { args.append("-m") }
        if options.skipJunk { args += ["--exclude", "__MACOSX", "--exclude", "._*", "--exclude", ".DS_Store"] }
        let total = Double(max(names.count, 1))
        let counter = Locked(0)
        // A decompression bomb is stopped by the free space, not by a cap: when the volume drops below half the reserve the extraction is killed (checked on the tool's own
        // per-entry output, so nothing polls). The disk itself ends a single endless file with ENOSPC, which is mapped to a calm message below.
        let startFree = DiskReserve.freeBytes(at: stage)
        let floor = startFree.map { DiskReserve.reserve(forFree: $0) / 2 }
        let lastCheck = Locked(Date.distantPast)
        let tripped = Locked(false)
        let out: ProcessOutput
        do {
            out = try await ctx.runProcess(exe, args, onStderrLine: { _ in
                counter.withLock { $0 += 1 }; progress(min(0.99, Double(counter.value) / total))
                guard let floor, Date().timeIntervalSince(lastCheck.value) > 0.25 else { return }
                lastCheck.value = Date()
                if let free = DiskReserve.freeBytes(at: stage), free < floor { tripped.value = true; ctx.processes.cancelAll(immediately: true) }
            }, allowNonZeroExit: true)
        } catch is CancellationError where tripped.value {
            throw ConversionError.message(DiskReserve.message)
        }
        if out.exitCode != 0 {
            let tail = out.stderrTail.joined(separator: "\n").lowercased()
            if tail.contains("passphrase") || tail.contains("encrypted") { throw ConversionError.encryptedArchive }
            if tail.contains("no space left") { throw ConversionError.message(DiskReserve.message) }
            throw ConversionError.message(L10n("Cannot extract the archive: \(out.stderrTail.last ?? "unknown error").", "Не удалось распаковать архив: \(out.stderrTail.last ?? "неизвестная ошибка")."))
        }
        let removed = ArchiveSafety.sanitizeTree(at: stage)
        if !options.restorePermissions { ArchiveSafety.normalisePermissions(in: stage) }
        if options.flatten { try ArchiveSafety.flatten(stage) }
        progress(1)
        var report = ExtractionReport()
        report.files = names.filter { !$0.hasSuffix("/") }.count
        report.skipped = removed
        return report
    }

    /// Bare .bz2 / .xz / .zst files: decompressed with the system's tools into `stage/<name without extension>`.
    private static func decompressSingle(_ url: URL, format: ArchiveFormat, into stage: URL, ctx: OperationContext, progress: @escaping (Double) -> Void) async throws -> ExtractionReport {
        let name = Util.safeFileName(Formats.baseName(of: url), fallback: "file")
        let target = stage.appendingPathComponent(name)
        switch format {
        case .bz2:
            let work = stage.appendingPathComponent(".\(Util.hex8()).bz2")
            try FileManager.default.copyItem(at: url, to: work)
            try await ctx.runProcess(URL(fileURLWithPath: "/usr/bin/bunzip2"), ["-f", work.path])
            try FileManager.default.moveItem(at: work.deletingPathExtension(), to: target)
        case .xz:
            if let xz = ctx.tools.url(.xz) {
                let work = stage.appendingPathComponent(".\(Util.hex8()).xz")
                try FileManager.default.copyItem(at: url, to: work)
                try await ctx.runProcess(xz, ["-d", "-f", work.path])
                try FileManager.default.moveItem(at: work.deletingPathExtension(), to: target)
            } else {
                try await ctx.runProcess(URL(fileURLWithPath: "/usr/bin/compression_tool"), ["-decode", "-a", "lzma", "-i", url.path, "-o", target.path])
            }
        case .zst:
            guard let zstd = ctx.tools.url(.zstd) else { throw ConversionError.toolMissing(.zstd) }
            try await ctx.runProcess(zstd, ["-d", "-q", "-f", url.path, "-o", target.path])
        default:
            throw ConversionError.unsupported(L10n("This archive format cannot be read.", "Этот формат архива нельзя прочитать."))
        }
        progress(1)
        var report = ExtractionReport()
        report.files = 1; report.topLevel = [name]
        return report
    }
}

/// Clean-ups for trees that libarchive wrote (its own links and modes are not under the sink's control).
enum ArchiveSafety {
    static func normalisePermissions(in root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            try? fm.setAttributes([.posixPermissions: v?.isDirectory == true ? 0o755 : 0o644], ofItemAtPath: u.path)
        }
    }

    /// Moves every file to the top of the folder (name clashes get " (2)") and removes the emptied folders.
    static func flatten(_ root: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        var files: [URL] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { files.append(u) }
        var used = Set((try? fm.contentsOfDirectory(atPath: root.path))?.map { $0.lowercased() } ?? [])
        for f in files where f.deletingLastPathComponent().standardizedFileURL.path != root.standardizedFileURL.path {
            var name = f.lastPathComponent, n = 2
            let ns = name as NSString
            while used.contains(name.lowercased()) { name = ns.pathExtension.isEmpty ? "\(ns) (\(n))" : "\(ns.deletingPathExtension) (\(n)).\(ns.pathExtension)"; n += 1 }
            used.insert(name.lowercased())
            try fm.moveItem(at: f, to: root.appendingPathComponent(name))
        }
        for c in (try fm.contentsOfDirectory(atPath: root.path)) {
            var isDir: ObjCBool = false
            let u = root.appendingPathComponent(c)
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { try? fm.removeItem(at: u) }
        }
    }
}

/// Moves the staged result next to the archive with the placement and collision rules of the options.
enum ArchivePlacement {
    /// "smart": one top-level entry goes straight out, several get a folder named like the archive; "folder": always that folder; "here": every top-level entry separately with
    /// `overwrite` as the policy for names that exist. Returns the produced files and folders.
    static func place(stage: URL, in dir: URL, archiveBase: String, mode: String, collision: OutputCollision, overwrite: OutputCollision) async throws -> [URL] {
        let fm = FileManager.default
        let children = DirectoryListing.names(stage.path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard !children.isEmpty else { throw ConversionError.message(L10n("The archive is empty.", "Архив пуст.")) }
        if mode == "here" {
            var out: [URL] = []
            for c in children { out.append(try await single(stage.appendingPathComponent(c), in: dir, collision: overwrite)) }
            return out
        }
        if mode == "smart", children.count == 1 {
            return [try await single(stage.appendingPathComponent(children[0]), in: dir, collision: collision)]
        }
        let folder = try await OutputPaths.produceFolder(dir: dir, name: Util.safeFileName(archiveBase, fallback: "Archive"), collision: collision) { temp in
            for c in children { try fm.moveItem(at: stage.appendingPathComponent(c), to: temp.appendingPathComponent(c)) }
        }
        return [folder]
    }

    /// One file or folder, keeping its name (double extensions like .tar.gz stay together), numbered when the name is taken.
    static func single(_ item: URL, in dir: URL, collision: OutputCollision) async throws -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        let name = item.lastPathComponent
        var base = name, ext = ""
        if !isDir.boolValue {
            let lower = name.lowercased()
            if let d = Formats.doubleExtensions.first(where: { lower.hasSuffix("." + $0) && lower.count > $0.count + 1 }) { base = String(name.dropLast(d.count + 1)); ext = String(name.suffix(d.count)) }
            else if !(name as NSString).pathExtension.isEmpty, !(name as NSString).deletingPathExtension.isEmpty { base = (name as NSString).deletingPathExtension; ext = (name as NSString).pathExtension }
        }
        return try await OutputPaths.produceFile(dir: dir, base: base, ext: ext, collision: collision) { temp in
            try FileManager.default.moveItem(at: item, to: temp)
        }
    }
}
