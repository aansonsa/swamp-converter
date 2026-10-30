import Foundation

// The shared zip layer (spec/backends.md 3.8, decision 3: "own zip layer ... approved as a core component"). Used by archives, XLSX / ODS (sheets),
// EPUB (docs module) and DOCX parts. Reading handles Windows-Russian archives whose names are CP866 / CP1251 without the UTF-8 flag (bsdtar, ditto and unzip
// produce mojibake for them: spec fact 7). Everything streams: a multi-GB archive is never loaded into memory. Extraction is zip-slip safe.
//
// Files of the zip layer: ZipIO (positional reads, zlib streams), ZipParser (central directory, names), ZipKit (this file: public API, entry streaming),
// ZipExtraction (safe extraction sink), ZipWriter (streaming writer, zip64).

struct ZipEntry: Identifiable, Hashable, Sendable {
    /// The decoded name (UTF-8 flag respected, otherwise detected CP866 / CP1251 / CP437 by plausibility).
    var name: String
    var rawName: Data
    var isDirectory: Bool
    var compressedSize: Int64
    var uncompressedSize: Int64
    var modified: Date?
    var isEncrypted: Bool
    var crc32: UInt32
    /// 0 = stored, 8 = deflate (the only methods this layer decodes; others make the archive module fall back to bsdtar).
    var method: UInt16 = 0
    var flags: UInt16 = 0
    /// Absolute offset of the local header inside the file.
    var localHeaderOffset: Int64 = 0
    /// Unix permission bits and file type from the external attributes (0 when the archive was not made on Unix).
    var unixMode: UInt32 = 0
    var isSymlink: Bool = false
    var id: String { name }
}

enum ZipKit {
    // MARK: Listing

    /// Reads the central directory only (cheap, even for huge archives). Throws `ConversionError.message` for corrupt archives and `.encryptedArchive` never:
    /// encryption is reported per entry.
    static func list(_ url: URL) throws -> [ZipEntry] { try list(url, nameEncoding: .auto) }

    /// Same, with an explicit decoding for names that lack the UTF-8 flag (the "Names" picker of the extract page).
    static func list(_ url: URL, nameEncoding: ZipNameEncoding) throws -> [ZipEntry] {
        do { return try ZipParser.parse(try RandomAccessFile(url: url), encoding: nameEncoding) }
        catch let e as ZipError { throw e.conversionError }
    }

    /// True when the file starts like a zip archive (local header, empty archive or spanned marker).
    static func looksLikeZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 4)) ?? Data()
        return d.count == 4 && d[d.startIndex] == 0x50 && d[d.startIndex + 1] == 0x4B && [3, 5, 7].contains(d[d.startIndex + 2])
    }

    // MARK: Extraction

    /// Extracts the selected entries (nil = all) into `directory`. Rejects every entry whose resolved path leaves `directory` (`..`, absolute names, symlink games)
    /// with `ConversionError.unsafeArchivePath`; refuses encrypted entries with `.encryptedArchive` BEFORE writing anything; restores modification times; cancellable.
    static func extract(_ url: URL, to directory: URL, entries: [ZipEntry]? = nil, progress: ((Double) -> Void)? = nil) async throws {
        var options = ZipExtractOptions()
        options.entries = entries
        _ = try await unpack(url, to: directory, options: options, progress: progress)
    }

    // MARK: Reading single entries

    /// Reads ONE entry's bytes (OOXML parts: small XML files). Memory-capped by `limit`.
    static func read(_ url: URL, entry name: String, limit: Int = 64_000_000) throws -> Data {
        let file = try RandomAccessFile(url: url)
        do {
            let entries = try ZipParser.parse(file)
            guard let e = find(name, in: entries) else {
                throw ConversionError.message(L10n("The archive has no part named \(name).", "В архиве нет части \(name)."))
            }
            return try readData(file, entry: e, limit: limit)
        } catch let e as ZipError { throw e.conversionError }
    }

    static func find(_ name: String, in entries: [ZipEntry]) -> ZipEntry? {
        if let e = entries.first(where: { $0.name == name }) { return e }
        let norm = name.replacingOccurrences(of: "\\", with: "/")
        return entries.first { $0.name.replacingOccurrences(of: "\\", with: "/") == norm }
    }

    static func readData(_ file: RandomAccessFile, entry: ZipEntry, limit: Int) throws -> Data {
        if entry.uncompressedSize > Int64(limit) {
            throw ConversionError.message(L10n("The part \(entry.name) is too large to read.", "Часть \(entry.name) слишком велика для чтения."))
        }
        var out = Data()
        out.reserveCapacity(Int(min(entry.uncompressedSize, Int64(limit))))
        try ZipEntryStream.stream(file, entry: entry) { out.append(contentsOf: $0) }
        return out
    }

    /// Writes one entry to `destination` (streamed; XLSX sheets of hundreds of MB never sit in memory).
    static func copyEntry(_ url: URL, entry: ZipEntry, to destination: URL) throws {
        let file = try RandomAccessFile(url: url)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let h = try FileHandle(forWritingTo: destination)
        defer { try? h.close() }
        do { try ZipEntryStream.stream(file, entry: entry) { try h.write(contentsOf: Data($0)) } }
        catch let e as ZipError { throw e.conversionError }
    }

    /// Decodes every selected entry and checks size and CRC-32 (the "check the result" step after packing). Throws on the first problem.
    static func test(_ url: URL, entries: [ZipEntry]? = nil) throws {
        let file = try RandomAccessFile(url: url)
        do {
            let all = try entries ?? ZipParser.parse(file)
            for e in all where !e.isDirectory && !e.isEncrypted { try ZipEntryStream.stream(file, entry: e) { _ in } }
        } catch let e as ZipError { throw e.conversionError }
    }
}

/// Streams the uncompressed bytes of one entry and verifies its size and CRC-32.
enum ZipEntryStream {
    static let chunk = 256 * 1024

    static func stream(_ file: RandomAccessFile, entry: ZipEntry, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        if entry.isEncrypted { throw ConversionError.encryptedArchive }
        guard entry.method == 0 || entry.method == 8 else {
            throw ConversionError.unsupported(L10n("This ZIP uses a compression method the app cannot read (\(entry.method)).",
                                                   "Этот ZIP использует метод сжатия, который приложение не читает (\(entry.method))."))
        }
        let header = [UInt8](try file.read(at: entry.localHeaderOffset, count: 30))
        guard header.count == 30, ByteCursor.u32(header, 0) == 0x0403_4B50 else { throw ZipError.damaged("local header") }
        let dataStart = ArchiveMath.add(entry.localHeaderOffset, 30 + Int64(ByteCursor.u16(header, 26)) + Int64(ByteCursor.u16(header, 28)))
        guard entry.compressedSize >= 0, ArchiveMath.add(dataStart, entry.compressedSize) <= file.size else { throw ZipError.truncated }
        var remaining = entry.compressedSize
        var offset = dataStart
        var produced: Int64 = 0
        var crc: UInt32 = 0
        let inflater = entry.method == 8 ? StreamInflater(window: -15) : nil
        let limit = entry.uncompressedSize
        var buffer = Data()
        func emit(_ p: UnsafeRawBufferPointer) throws {
            produced += Int64(p.count)
            if produced > limit { throw ZipError.damaged("entry grows past its declared size") }
            crc = Checksum.crc32(crc, p)
            try sink(p)
        }
        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(min(Int64(chunk), remaining))
            buffer = try file.read(at: offset, count: want)
            if buffer.isEmpty { throw ZipError.truncated }
            offset += Int64(buffer.count); remaining -= Int64(buffer.count)
            try buffer.withUnsafeBytes { raw in
                if let inflater { _ = try inflater.feed(raw, sink: emit) } else { try emit(raw) }
            }
        }
        if let inflater, !inflater.finished, produced < limit { throw ZipError.damaged("deflate stream ended early") }
        if produced != limit { throw ZipError.damaged("size mismatch") }
        if produced > 0 && crc != entry.crc32 {
            throw ConversionError.message(L10n("The archive is damaged: the checksum of \(entry.name) does not match.",
                                               "Архив повреждён: контрольная сумма «\(entry.name)» не совпадает."))
        }
    }
}
