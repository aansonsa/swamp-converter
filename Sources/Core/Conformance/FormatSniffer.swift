import Foundation

// The REAL format of a file, decided from its bytes alone: magic numbers and container structure, parsed by code in this file.
// It deliberately shares nothing with the engines (no ImageIO type lookup, no ffprobe, no file extension), so "the output extension says jpg"
// can be checked against "the bytes are a JPEG". A conversion that only renames its input fails here.
//
// `key` uses the same vocabulary as `Formats` ("jpg", "tar.gz", "m4a", ...). Where a container can hold different things the key names what is
// inside: an MPEG-4 file with only sound is "m4a", an Ogg file with Opus is "opus", a Matroska file declared as WebM is "webm".

struct SniffedFormat: Equatable, Sendable, CustomStringConvertible {
    var key: String
    /// Short facts for failure messages ("RIFF WEBP VP8L", "ftyp M4A", "Ogg Opus", "zip 7 entries").
    var detail: String = ""
    /// Codec names read from the container header where that is cheap (MPEG-4 sample entries, Ogg first packet), in the vocabulary of ffprobe.
    var codecs: [String] = []
    var hasVideo = false
    var hasAudio = false

    var description: String { detail.isEmpty ? key : "\(key) (\(detail))" }
}

enum FormatSniffer {
    /// Sniffs `url`. Nil for an empty or unreadable file; "bin" for bytes nothing recognises.
    static func sniff(_ url: URL) -> SniffedFormat? {
        guard let r = ByteReader(url: url), r.size > 0 else { return nil }
        let h = r.head(4096)
        if let f = sniffImage(h, r) { return f }
        if let f = sniffDocumentOrArchive(h, r, url: url) { return f }
        if let f = sniffMedia(h, r) { return f }
        if let f = sniffText(r) { return f }
        return SniffedFormat(key: "bin", detail: "unrecognised, first bytes " + h.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    // MARK: Images

    private static func sniffImage(_ h: [UInt8], _ r: ByteReader) -> SniffedFormat? {
        if h.hasBytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            let tail = r.tail(12)
            let complete = tail.hasPrefix("IEND", at: 4)
            var f = SniffedFormat(key: "png", detail: complete ? "PNG" : "PNG without IEND (truncated)")
            if h.count > 25, h.hasPrefix("IHDR", at: 12) { f.detail += " colour type \(h[25])" }
            return f
        }
        if h.hasBytes([0xFF, 0xD8, 0xFF]) { return SniffedFormat(key: "jpg", detail: h.hasPrefix("JFIF", at: 6) ? "JFIF" : (h.hasPrefix("Exif", at: 6) ? "Exif" : "JPEG")) }
        if h.hasPrefix("GIF87a") || h.hasPrefix("GIF89a") { return SniffedFormat(key: "gif", detail: String(decoding: h.prefix(6), as: UTF8.self)) }
        if h.hasPrefix("RIFF"), h.hasPrefix("WEBP", at: 8) {
            let chunk = h.ascii(12..<16)
            return SniffedFormat(key: "webp", detail: "RIFF WEBP \(chunk.trimmingCharacters(in: .whitespaces))")
        }
        if h.hasBytes([0x49, 0x49, 0x2A, 0x00]) || h.hasBytes([0x4D, 0x4D, 0x00, 0x2A]) || h.hasBytes([0x49, 0x49, 0x2B, 0x00]) {
            return SniffedFormat(key: "tiff", detail: h[0] == 0x49 ? "TIFF little-endian" : "TIFF big-endian")
        }
        if h.hasPrefix("BM"), let dib = h.u32le(at: 14), [12, 40, 52, 56, 108, 124].contains(Int(dib)) { return SniffedFormat(key: "bmp", detail: "BMP DIB \(dib)") }
        if h.hasBytes([0x00, 0x00, 0x01, 0x00]), let n = h.u16le(at: 4), n > 0, n < 64, h.count >= 6 + Int(n) * 16 { return SniffedFormat(key: "ico", detail: "ICO \(n) image(s)") }
        if h.hasPrefix("icns") { return SniffedFormat(key: "icns", detail: "ICNS") }
        if h.hasBytes([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return SniffedFormat(key: "jp2", detail: "JPEG 2000") }
        if h.hasBytes([0xFF, 0x0A]) || h.hasBytes([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return SniffedFormat(key: "jxl", detail: "JPEG XL") }
        if h.hasPrefix("8BPS") { return SniffedFormat(key: "psd", detail: "Photoshop") }
        if h.hasBytes([0x76, 0x2F, 0x31, 0x01]) { return SniffedFormat(key: "exr", detail: "OpenEXR") }
        return nil
    }

    // MARK: Documents and archives

    private static func sniffDocumentOrArchive(_ h: [UInt8], _ r: ByteReader, url: URL) -> SniffedFormat? {
        if let idx = h.firstIndex(of: 0x25), idx < 1024, h.hasPrefix("%PDF-", at: idx) {
            return SniffedFormat(key: "pdf", detail: "PDF " + h.ascii((idx + 5)..<(idx + 8)))
        }
        if h.hasPrefix("PK\u{03}\u{04}") || h.hasPrefix("PK\u{05}\u{06}") { return ZipProbe.classify(r) }
        if h.hasBytes([0x1F, 0x8B, 0x08]) {
            let inner = ExternalProbe.decompressedPrefix(url, tool: "/usr/bin/gzip", args: ["-dc"], bytes: 512)
            return isTar(inner) ? SniffedFormat(key: "tar.gz", detail: "gzip around a tar stream") : SniffedFormat(key: "gz", detail: "gzip (single stream)")
        }
        if h.hasPrefix("BZh") {
            let inner = ExternalProbe.decompressedPrefix(url, tool: "/usr/bin/bzip2", args: ["-dc"], bytes: 512)
            return isTar(inner) ? SniffedFormat(key: "tar.bz2", detail: "bzip2 around a tar stream") : SniffedFormat(key: "bz2", detail: "bzip2")
        }
        if h.hasBytes([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            let listing = ExternalProbe.run("/usr/bin/bsdtar", ["-tf", url.path], timeout: 15)
            return listing.status == 0 && !listing.output.isEmpty ? SniffedFormat(key: "tar.xz", detail: "xz around a tar stream") : SniffedFormat(key: "xz", detail: "xz")
        }
        if h.hasBytes([0x28, 0xB5, 0x2F, 0xFD]) {
            let listing = ExternalProbe.run("/usr/bin/bsdtar", ["-tf", url.path], timeout: 15)
            return listing.status == 0 && !listing.output.isEmpty ? SniffedFormat(key: "tar.zst", detail: "zstd around a tar stream") : SniffedFormat(key: "zst", detail: "zstd")
        }
        if h.hasBytes([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return SniffedFormat(key: "7z", detail: "7-Zip") }
        if h.hasPrefix("Rar!\u{1A}\u{07}") { return SniffedFormat(key: "rar", detail: "RAR") }
        if isTar(h) { return SniffedFormat(key: "tar", detail: "tar (ustar header)") }
        if h.hasBytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return SniffedFormat(key: "ole", detail: "OLE2 compound file (doc, xls, ppt)") }
        if h.hasPrefix("{\\rtf") { return SniffedFormat(key: "rtf", detail: "RTF") }
        return nil
    }

    /// A tar header block: "ustar" at 257 and a header checksum that matches.
    static func isTar(_ block: [UInt8]) -> Bool {
        guard block.count >= 512, block.hasPrefix("ustar", at: 257) else { return false }
        var sum = 0
        for (i, b) in block[0..<512].enumerated() { sum += (148..<156).contains(i) ? 32 : Int(b) }
        let field = String(decoding: block[148..<156].filter { $0 >= 0x30 && $0 <= 0x37 }, as: UTF8.self)
        return Int(field, radix: 8) == sum
    }

    // MARK: Text

    /// UTF-8 / UTF-16 text, further classified by its first lines (subtitles, markup, delimited tables, Markdown).
    private static func sniffText(_ r: ByteReader) -> SniffedFormat? {
        let bytes = r.read(at: 0, 65_536)
        guard let (text, encoding) = decodeText(bytes) else { return nil }
        let head = text.prefix(8000)
        let lower = head.lowercased()
        let lines = head.split(whereSeparator: \.isNewline).map(String.init)
        func f(_ key: String, _ d: String) -> SniffedFormat { SniffedFormat(key: key, detail: "\(d), \(encoding)") }
        if lower.hasPrefix("\u{FEFF}webvtt") || lower.hasPrefix("webvtt") { return f("vtt", "WebVTT") }
        if lower.contains("[script info]") { return f("ass", "ASS/SSA") }
        if lower.hasPrefix("<!doctype html") || lower.contains("<html") || (lower.contains("<body") && lower.contains("</")) { return f("html", "HTML") }
        if lower.hasPrefix("<svg") || (lower.hasPrefix("<?xml") && lower.contains("<svg")) { return f("svg", "SVG") }
        if lower.hasPrefix("<?xml") || lower.hasPrefix("<") && lower.contains("</") { return f("xml", "XML") }
        if isSRT(lines) { return f("srt", "SubRip") }
        if let d = delimiter(text) { return f(d == "\t" ? "tsv" : "csv", "delimited text (\(d == "\t" ? "tab" : d))") }
        if looksLikeMarkdown(lines) { return f("md", "Markdown") }
        return f("txt", "plain text")
    }

    /// Decodes with BOM detection; nil for binary data (NUL bytes, invalid UTF-8, many control characters).
    static func decodeText(_ bytes: [UInt8]) -> (String, String)? {
        if bytes.isEmpty { return nil }
        if bytes.hasBytes([0xFF, 0xFE]) || bytes.hasBytes([0xFE, 0xFF]) {
            let enc: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            return String(data: Data(bytes.dropFirst(2)), encoding: enc).map { ($0, "UTF-16") }
        }
        if bytes.contains(0) { return nil }
        let body = bytes.hasBytes([0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
        var data = Data(body)
        // A read cut in the middle of a multi-byte character must not make valid text look binary.
        var text = String(data: data, encoding: .utf8)
        var trim = 0
        while text == nil, trim < 4, !data.isEmpty { data.removeLast(); trim += 1; text = String(data: data, encoding: .utf8) }
        guard let t = text else { return nil }
        let control = t.unicodeScalars.filter { $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        if t.unicodeScalars.count > 0, Double(control) / Double(t.unicodeScalars.count) > 0.02 { return nil }
        return (t, bytes.hasBytes([0xEF, 0xBB, 0xBF]) ? "UTF-8 with BOM" : "UTF-8")
    }

    private static func isSRT(_ lines: [String]) -> Bool {
        let stamp = #"^\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s+-->\s+\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}"#
        for (i, l) in lines.prefix(6).enumerated() where l.range(of: stamp, options: .regularExpression) != nil {
            let t = l.trimmingCharacters(in: .whitespaces)
            // SRT numbers its cues and uses a comma before the milliseconds; VTT uses a dot and no numbers.
            return t.contains(",") && i >= 1 && Int(lines[i - 1].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))) != nil
        }
        return false
    }

    /// The delimiter (tab `;` `,` `|`) under which a quote-aware parse gives at least three rows of the same number (>= 2) of fields; commas inside prose do not qualify.
    private static func delimiter(_ text: String) -> String? {
        for d in ["\t", ";", ",", "|"] {
            let rows = TableFidelity.parseDelimited(String(text.prefix(8000)), delimiter: Character(d)).filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
            // The last row may be cut by the 8000-character window.
            let complete = rows.count > 3 ? Array(rows.dropLast()) : rows
            if complete.count >= 3, let first = complete.first?.count, first >= 2, complete.allSatisfy({ $0.count == first }) { return d }
        }
        return nil
    }

    private static func looksLikeMarkdown(_ lines: [String]) -> Bool {
        var marks = 0
        for l in lines.prefix(40) {
            if l.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil { marks += 2 }
            else if l.range(of: #"^\s*([-*+]|\d+\.)\s+\S"#, options: .regularExpression) != nil { marks += 1 }
            else if l.range(of: #"^\|.*\|\s*$"#, options: .regularExpression) != nil { marks += 1 }
            else if l.contains("**") || l.contains("](") { marks += 1 }
        }
        return marks >= 3
    }
}

// MARK: - Agreement between an extension and the sniffed bytes

extension FormatSniffer {
    /// The sniffed keys that honestly belong to a file called `*.<ext>`. A `.jpg` holding PNG bytes, an `.m4a` that is really MP3, a `.docx` that is plain
    /// text, a `.ogg` holding Opus are all disagreements.
    static func acceptableSniffs(forExtension ext: String) -> Set<String> {
        let k = Formats.aliases[ext] ?? ext
        switch k {
        case "jpg": return ["jpg"]
        case "tiff": return ["tiff"]
        case "dng", "cr2", "cr3", "nef", "arw": return ["tiff", "dng"]
        case "mp4": return ["mp4"]
        case "m4a": return ["m4a", "mp4"]
        case "m4b": return ["m4a", "mp4"]
        case "m4r": return ["m4a", "mp4"]   // iPhone ringtone: an MPEG-4 audio file with another extension
        case "mov": return ["mov"]
        case "3gp", "3g2": return ["3gp", "mp4"]
        case "mkv": return ["mkv", "webm"]
        case "webm": return ["webm"]
        case "ogg": return ["ogg"]
        case "ogv": return ["ogv", "ogg"]
        case "opus": return ["opus"]
        case "aac": return ["aac"]
        case "aiff": return ["aiff"]
        case "txt": return ["txt", "md", "csv", "tsv", "srt", "vtt", "ass", "xml", "html", "svg"]
        case "md": return ["md", "txt"]
        case "csv": return ["csv", "tsv", "txt"]
        case "tsv": return ["tsv", "csv", "txt"]
        case "html": return ["html"]
        case "xml": return ["xml", "svg", "html"]
        case "srt": return ["srt"]
        case "vtt": return ["vtt"]
        case "gz": return ["gz", "tar.gz"]
        case "doc", "xls", "ppt": return ["ole"]
        default: return [k]
        }
    }

    static func agrees(extension ext: String, with sniffed: SniffedFormat) -> Bool {
        let key = Formats.aliases[ext] ?? ext
        // An extension the catalogue does not know (".sh", ".json", ".swift", ".bin") names no format we could contradict.
        if Formats.kind(forKey: key) == .other, !["xml", "html", "ole", "rtf", "svg", "ass", "caf", "ac3", "amr", "jxl", "jp2"].contains(key), !acceptableKnown.contains(key) { return true }
        return acceptableSniffs(forExtension: key).contains(sniffed.key)
    }

    private static let acceptableKnown: Set<String> = ["m4b", "m4r", "3gp", "3g2", "ogv", "dng", "cr2", "cr3", "nef", "arw", "csv", "tsv", "md", "txt", "srt", "vtt", "xml", "gz", "doc", "xls", "ppt", "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "zip", "tar", "7z", "rar", "bz2", "xz", "zst", "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "icns", "ico", "psd", "exr", "mpg", "ts"]
}
