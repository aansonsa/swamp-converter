import Foundation

// Reading subtitle files with encoding detection and writing them back in any supported encoding.

extension SubtitleKit {
    static let maxFileBytes = 64 * 1024 * 1024

    /// Reads a file with encoding detection (UTF-8 strict, UTF-16 BOM, then Windows-1251 / 1257 / 1250 / ISO-8859-x by plausibility); returns the text and the name of the encoding used.
    static func readText(_ url: URL, encodingOverride: String.Encoding? = nil) throws -> (text: String, encoding: String) {
        try readText(url, encoding: encodingOverride.flatMap { DataEncoding.from($0) })
    }

    /// Same with the data module's encoding type (the Studio picker value). nil = detect.
    static func readText(_ url: URL, encoding: DataEncoding?) throws -> (text: String, encoding: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ConversionError.fileUnreadable(url) }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Int64(maxFileBytes) else {
            throw ConversionError.message(L10n("This file is too large to be a subtitle file.", "Этот файл слишком велик для файла субтитров."))
        }
        guard let data = try? handle.readToEnd() else { throw ConversionError.fileUnreadable(url) }
        let d = TextEncodingKit.decode(data, override: encoding)
        return (d.text, d.encoding.displayName + (d.hadBOM ? " BOM" : ""))
    }
}

/// Line endings, BOM and encoding of a subtitle result.
enum SubtitleOutput {
    /// "\n" text -> bytes: `eol` "crlf" / "lf" / "auto" (CRLF for SRT, LF for the rest), encoding by picker key, BOM on request (UTF-8 and UTF-16 only).
    static func encode(_ text: String, format: SubtitleFormat, eol: String, encodingKey: String, bom: Bool) -> TextEncodingKit.EncodedText {
        let useCRLF = eol == "crlf" || (eol == "auto" && format == .srt)
        let body = useCRLF ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        let enc = DataEncoding(key: encodingKey) ?? .utf8
        return TextEncodingKit.encode(body, as: enc, bom: bom || enc == .utf16)
    }
}
