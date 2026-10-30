import Foundation

/// facts `archive.format`, `archive.entries`, `archive.encrypted`, `archive.unsafe`, `archive.unpacked`; chips "128 files", "needs a password", "unsafe paths".
/// Cheap: zip reads only the central directory; tar streams are scanned up to 64 MB; the rest asks libarchive for a quick listing.
struct ArchiveSourceProbe: SourceProbe {
    static let scanLimit: Int64 = 64 * 1024 * 1024

    func probe(_ item: FileItem) async -> SourceInfo {
        var info = SourceInfo(url: item.url, kind: item.kind)
        guard let format = ArchiveFormat.resolve(item.url) else { return info }
        info.facts["archive.format"] = .string(format.rawValue)
        info.chips.append(SourceChip(symbol: "archivebox", text: format.displayName))
        let size = item.size ?? 0
        var entries: Int?, unpacked: Int64 = 0, encrypted = false, unsafe = false
        let checker = ExtractSink(root: URL(fileURLWithPath: "/dev/null"), policy: ExtractionPolicy())
        switch format {
        case .zip:
            if let list = try? ZipKit.list(item.url) {
                entries = list.filter { !$0.isDirectory }.count
                unpacked = ArchiveMath.sum(list.map(\.uncompressedSize))
                encrypted = list.contains { $0.isEncrypted }
                unsafe = list.contains { Self.throwsUnsafe(checker, $0.name) }
            }
        case .tar, .tarGz, .gz:      // (.gz here is a bare compressed file: `resolve` reports tar.gz when a tar is inside)
            guard size <= Self.scanLimit else { break }
            if format == .gz { entries = 1; break }
            if let source = try? TarByteSource(url: item.url, gzip: format != .tar) {
                var n = 0
                var names: [String] = []
                if (try? TarReader.stream(source, onEntry: { e, _ in
                    if e.kind != .directory && e.kind != .other { n += 1; unpacked = ArchiveMath.add(unpacked, e.size) }      // files and links; folders are not counted
                    if names.count < 20_000 { names.append(e.name) }
                })) != nil {
                    entries = n
                    unsafe = names.contains { Self.throwsUnsafe(checker, $0) }
                }
            }
        case .tarBz2, .tarXz, .tarZst, .sevenZip, .rar, .bz2, .xz, .zst:
            guard size <= Self.scanLimit else { break }
            if let names = ArchiveTools.listQuick(item.url) {
                entries = names.filter { !$0.hasSuffix("/") }.count
                unsafe = names.contains { Self.throwsUnsafe(checker, $0) }
            } else if format.wrapsSingleFile { entries = 1 }
        }
        if let entries {
            info.facts["archive.entries"] = .int(entries)
            info.chips.append(SourceChip(symbol: "doc.on.doc", text: Loc.plural(entries, enOne: "\(entries) file", enOther: "\(entries) files", ruOne: "\(entries) файл", ruFew: "\(entries) файла", ruMany: "\(entries) файлов")))
        }
        if unpacked > 0 { info.facts["archive.unpacked"] = .double(Double(unpacked)); info.facts["size"] = info.facts["size"] ?? .double(Double(size)) }
        info.facts["archive.encrypted"] = .bool(encrypted)
        info.facts["archive.unsafe"] = .bool(unsafe)
        if encrypted {
            info.chips.append(SourceChip(symbol: "lock", text: L("needs a password", "нужен пароль")))
            info.warnings.append(L10n("This archive is password-protected. The app cannot open it yet.", "Архив защищён паролем. Приложение пока не умеет его открывать."))
        }
        if unsafe {
            info.chips.append(SourceChip(symbol: "exclamationmark.triangle", text: L("unsafe paths", "небезопасные пути")))
            info.warnings.append(L10n("This archive contains paths that would leave the destination folder. It will not be extracted.", "В архиве есть пути, выходящие за пределы папки назначения. Он не будет распакован."))
        }
        return info
    }

    private static func throwsUnsafe(_ sink: ExtractSink, _ name: String) -> Bool {
        do { _ = try sink.relativePath(for: name); return false } catch { return true }
    }
}
