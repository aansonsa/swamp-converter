import Foundation

/// A cheap look at the end of a JPEG or PNG file. ImageIO happily decodes a truncated file and fills the missing part with grey, so a half-downloaded picture
/// would be converted without a word. This only reads the last bytes; it never fails a conversion (the owner may want what is there), it produces a warning.
enum ImageIntegrity {
    /// The warning to show for `url`, or nil when the file looks complete (or is not a JPEG / PNG).
    static func warning(for url: URL) -> L10n? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 16 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 8) else { return nil }
        let isJPEG = head.starts(with: [0xFF, 0xD8, 0xFF]), isPNG = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard isJPEG || isPNG else { return nil }
        let tailLength = min(Int(size), isJPEG ? 65_536 : 4_096)
        try? handle.seek(toOffset: size - UInt64(tailLength))
        guard let tail = try? handle.read(upToCount: tailLength) else { return nil }
        let complete: Bool
        if isPNG {
            // The last chunk of a PNG is IEND (length 0, type, fixed CRC).
            complete = tail.range(of: Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])) != nil
        } else {
            // A JPEG ends with the EOI marker; cameras and editors may append zero padding or a second picture (which ends with EOI as well).
            var bytes = Array(tail)
            while let last = bytes.last, last == 0 { bytes.removeLast() }
            complete = bytes.contains(0xFF) && zip(bytes, bytes.dropFirst()).contains { $0 == 0xFF && $1 == 0xD9 }
        }
        return complete ? nil : L10n("The file looks incomplete or damaged; the missing part of the picture may come out gray.",
                                     "Файл выглядит неполным или повреждённым; недостающая часть картинки может получиться серой.")
    }
}
