import Foundation
import CoreFoundation

// Text encodings for the document engine: detection (BOM, UTF-8, UTF-16 without BOM, Cyrillic and Baltic code pages), decoding with explicit choice, encoding with
// BOM / line endings / lossy accounting, hard wrapping, and a streaming transcoder that never holds a big text file in memory (the "fix Cyrillic" preset).
// Encoding ids are the values of the `doc.enc.in` / `doc.enc.out` pickers.

enum DocTextCodec {
    /// Ids offered in the pickers, in display order (auto first for input).
    static let inputIDs = ["auto", "utf-8", "utf-16", "windows-1251", "koi8-r", "cp866", "windows-1257", "iso-8859-13", "windows-1252", "windows-1250", "macroman"]
    static let outputIDs = ["utf-8", "utf-16", "utf-16be", "windows-1251", "koi8-r", "cp866", "windows-1257", "windows-1252", "windows-1250"]

    static func displayName(_ id: String) -> L10n {
        switch id {
        case "auto": return L10n("Detect automatically", "Определять автоматически")
        case "utf-8": return L10n("Unicode (UTF-8)")
        case "utf-16": return L10n("Unicode (UTF-16, little-endian)", "Unicode (UTF-16, little-endian)")
        case "utf-16be": return L10n("Unicode (UTF-16, big-endian)", "Unicode (UTF-16, big-endian)")
        case "windows-1251": return L10n("Cyrillic (Windows-1251)", "Кириллица (Windows-1251)")
        case "koi8-r": return L10n("Cyrillic (KOI8-R)", "Кириллица (KOI8-R)")
        case "cp866": return L10n("Cyrillic (DOS 866)", "Кириллица (DOS 866)")
        case "windows-1257": return L10n("Baltic (Windows-1257)", "Балтийская (Windows-1257)")
        case "iso-8859-13": return L10n("Baltic (ISO 8859-13)", "Балтийская (ISO 8859-13)")
        case "windows-1252": return L10n("Western (Windows-1252)", "Западная (Windows-1252)")
        case "windows-1250": return L10n("Central European (Windows-1250)", "Центральная Европа (Windows-1250)")
        case "macroman": return L10n("Western (Mac OS Roman)", "Западная (Mac OS Roman)")
        default: return L10n(id)
        }
    }

    // MARK: Encoding ids <-> String.Encoding

    private static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    /// The Foundation encoding of an id (nil for `auto` and unknown ids).
    static func stringEncoding(_ id: String) -> String.Encoding? {
        switch id.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "windows-1251", "cp1251": return cf(.windowsCyrillic)
        case "koi8-r", "koi8r": return cf(.KOI8_R)
        case "cp866", "ibm866": return cf(.dosRussian)          // dosCyrillic is code page 855; 866 is dosRussian
        case "windows-1257", "cp1257": return cf(.windowsBalticRim)
        case "iso-8859-13": return cf(.isoLatin7)
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1250", "cp1250": return .windowsCP1250
        case "macroman": return .macOSRoman
        default: return nil
        }
    }

    private static func isUnicode(_ id: String) -> Bool { ["utf-8", "utf8", "utf-16", "utf-16le", "utf-16be"].contains(id.lowercased()) }

    // MARK: Detection

    struct Detection: Equatable {
        var id: String
        var bomLength: Int
        var hasBOM: Bool { bomLength > 0 }
    }

    /// Looks at the first bytes of a file (the first MiB is enough).
    static func detect(_ data: Data) -> Detection {
        let b = [UInt8](data.prefix(1 << 20))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return Detection(id: "utf-8", bomLength: 3) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return Detection(id: "utf-16", bomLength: 2) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return Detection(id: "utf-16be", bomLength: 2) }
        if b.count >= 4 {
            var evenZero = 0, oddZero = 0
            for i in stride(from: 0, to: b.count - 1, by: 2) { if b[i] == 0 { evenZero += 1 }; if b[i + 1] == 0 { oddZero += 1 } }
            let pairs = Double(b.count / 2)
            if Double(oddZero) / pairs > 0.3 && evenZero == 0 { return Detection(id: "utf-16", bomLength: 0) }
            if Double(evenZero) / pairs > 0.3 && oddZero == 0 { return Detection(id: "utf-16be", bomLength: 0) }
        }
        if isValidUTF8(b) { return Detection(id: "utf-8", bomLength: 0) }
        return Detection(id: bestEightBit(b), bomLength: 0)
    }

    /// Strict UTF-8 check that accepts a sequence cut off at the very end of the sample.
    static func isValidUTF8(_ b: [UInt8]) -> Bool {
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            let need: Int
            switch c {
            case 0xC2...0xDF: need = 1
            case 0xE0...0xEF: need = 2
            case 0xF0...0xF4: need = 3
            default: return false
            }
            if i + need >= n {                        // cut by the end of the sample: valid so far?
                for j in (i + 1)..<n where b[j] & 0xC0 != 0x80 { return false }
                return true
            }
            for j in 1...need where b[i + j] & 0xC0 != 0x80 { return false }
            if c == 0xE0, b[i + 1] < 0xA0 { return false }
            if c == 0xED, b[i + 1] > 0x9F { return false }
            if c == 0xF0, b[i + 1] < 0x90 { return false }
            if c == 0xF4, b[i + 1] > 0x8F { return false }
            i += need + 1
        }
        return true
    }

    /// Picks the most plausible 8-bit code page for text that is not valid UTF-8 (Russian, Latvian / Lithuanian, Czech / Polish, Western European).
    static func bestEightBit(_ bytes: [UInt8]) -> String {
        let sample = Array(bytes.prefix(1 << 18))
        let candidates = ["windows-1251", "koi8-r", "cp866", "windows-1257", "windows-1250", "windows-1252"]
        // Russian text is mostly high bytes (its letters); French, Czech or Latvian text is mostly ASCII with a few accented letters. The share of high bytes among the
        // letters therefore separates the Cyrillic code pages from the Latin ones before any table is consulted.
        var high = 0, letters = 0
        for b in sample { if b >= 0x80 { high += 1; letters += 1 } else if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) { letters += 1 } }
        let highShare = letters == 0 ? 0 : Double(high) / Double(letters)
        var best = ("windows-1252", -Double.infinity)
        for id in candidates {
            guard let enc = stringEncoding(id), let text = String(data: Data(sample), encoding: enc) ?? lossySingleByte(sample, enc) else { continue }
            var s = plausibility(text, id: id)
            if ["windows-1251", "koi8-r", "cp866"].contains(id) { s *= min(1, highShare / 0.3) }
            if s > best.1 { best = (id, s) }
        }
        return best.0
    }

    private static let baltic = Set("āčēģīķļņšūžĀČĒĢĪĶĻŅŠŪŽąęėįųĄĘĖĮŲ")
    private static let centralEurope = Set("ěščřžýáíéúůďťňĚŠČŘŽÝÁÍÉÚŮĎŤŇłąęśćźżńóĹŁĄĘŚĆŹŻŃÓőűŐŰ")
    private static let western = Set("àâäçéèêëîïôöùûüÿñßœÀÂÄÇÉÈÊËÎÏÔÖÙÛÜÑ")

    static func plausibility(_ text: String, id: String) -> Double {
        var score = 0.0
        var high = 0
        for ch in text.unicodeScalars where ch.value >= 0x80 {
            high += 1
            switch ch.value {
            case 0x0430...0x045F: score += 1.0                                // lower-case Cyrillic dominates real text
            case 0x0400...0x042F: score += 0.3                                // upper case appears at sentence starts only
            case 0x2500...0x25FF, 0x0080...0x009F, 0xFFFD: score -= 1.5       // box drawing, controls, replacement: the wrong table
            default: break
            }
        }
        if high == 0 { return 0 }
        if id == "windows-1257" || id == "windows-1250" || id == "windows-1252" {
            let set = id == "windows-1257" ? baltic : (id == "windows-1250" ? centralEurope : western)
            for ch in text where set.contains(ch) { score += 1.0 }
            for ch in text.unicodeScalars where ch.value >= 0xA0 && ch.value < 0x2000 && !CharacterSet.letters.contains(ch) { score -= 0.4 }
        }
        if id == "windows-1252" { score -= 0.05 * Double(high) }               // the last resort: loses ties
        return score
    }

    /// Byte-wise decode for tables with undefined positions (windows-1251 has holes): each hole becomes U+FFFD.
    private static func lossySingleByte(_ bytes: [UInt8], _ enc: String.Encoding) -> String? {
        var out = ""
        out.reserveCapacity(bytes.count)
        for b in bytes {
            if b < 0x80 { out.unicodeScalars.append(Unicode.Scalar(b)); continue }
            out += String(data: Data([b]), encoding: enc) ?? "\u{FFFD}"
        }
        return out
    }

    // MARK: Decoding

    struct Decoded {
        var text: String
        var encoding: String
        var hadBOM: Bool
        /// Some bytes could not be mapped (replaced by U+FFFD).
        var lossy: Bool
    }

    /// Decodes with the chosen encoding (`auto` = detect). A matching BOM is removed. Never throws: bad bytes become U+FFFD and `lossy` is set.
    static func decode(_ data: Data, as id: String = "auto") -> Decoded {
        let det = detect(data)
        var enc = id.lowercased()
        if enc.isEmpty || enc == "auto" { enc = det.id }
        var bom = 0
        if det.hasBOM, det.id.hasPrefix("utf-16") == enc.hasPrefix("utf-16"), det.id == enc || enc.hasPrefix("utf-16") {
            bom = det.bomLength
            if enc.hasPrefix("utf-16") { enc = det.id }
        }
        let body = bom > 0 ? Data(data.dropFirst(bom)) : data
        let r = decodeBody(body, encoding: enc)
        return Decoded(text: r.text, encoding: enc, hadBOM: bom > 0, lossy: r.lossy)
    }

    /// Decodes bytes that carry no BOM.
    static func decodeBody(_ payload: Data, encoding enc: String) -> (text: String, lossy: Bool) {
        guard let se = stringEncoding(enc) else { return (String(decoding: payload, as: UTF8.self), true) }
        if let s = String(data: payload, encoding: se) { return (s, false) }
        switch enc.lowercased() {
        case "utf-16", "utf-16le", "utf-16be":
            let be = enc.lowercased() == "utf-16be"
            var units: [UInt16] = []
            units.reserveCapacity(payload.count / 2)
            let bytes = [UInt8](payload)
            var i = 0
            while i + 1 < bytes.count { units.append(be ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])); i += 2 }
            return (String(decoding: units, as: UTF16.self), true)
        case "utf-8", "utf8":
            return (String(decoding: payload, as: UTF8.self), true)
        default:
            return (lossySingleByte([UInt8](payload), se) ?? String(decoding: payload, as: UTF8.self), true)
        }
    }

    // MARK: Encoding

    struct Encoded {
        var data: Data
        /// Characters the target code page cannot represent (written as "?").
        var replaced: Int
    }

    /// The bytes that start a file in encoding `id`: UTF-16 variants always carry their BOM, UTF-8 only when asked.
    static func bomBytes(for id: String, utf8BOM: Bool) -> Data {
        switch id.lowercased() {
        case "utf-8", "utf8": return utf8BOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        case "utf-16", "utf-16le": return Data([0xFF, 0xFE])
        case "utf-16be": return Data([0xFE, 0xFF])
        default: return Data()
        }
    }

    /// Encodes without any BOM.
    static func encodeBody(_ text: String, as id: String) -> Encoded {
        guard let enc = stringEncoding(id) else { return Encoded(data: Data(text.utf8), replaced: 0) }
        if let whole = text.data(using: enc, allowLossyConversion: false) { return Encoded(data: whole, replaced: 0) }
        var out = Data()
        var replaced = 0
        for ch in text {
            if let d = String(ch).data(using: enc, allowLossyConversion: false) { out.append(d) }
            else { replaced += 1; out.append("?".data(using: enc) ?? Data([0x3F])) }
        }
        return Encoded(data: out, replaced: replaced)
    }

    /// Encodes `text` for output: BOM (see `bomBytes`) + body.
    static func encode(_ text: String, as id: String, bom: Bool = false) -> Encoded {
        var e = encodeBody(text, as: id)
        e.data = bomBytes(for: id, utf8BOM: bom) + e.data
        return e
    }

    // MARK: Line endings and wrapping

    /// `eol` is "lf", "crlf" or "cr". Any mix in `text` is normalised first.
    static func normalizeLineEndings(_ text: String, to eol: String) -> String {
        var out = String.UnicodeScalarView()
        var sawCR = false
        let nl: [Unicode.Scalar] = eol == "crlf" ? ["\r", "\n"] : (eol == "cr" ? ["\r"] : ["\n"])
        for u in text.unicodeScalars {
            if u == "\r" { out.append(contentsOf: nl); sawCR = true; continue }
            if u == "\n" { if sawCR { sawCR = false; continue }; out.append(contentsOf: nl); continue }
            sawCR = false
            out.append(u)
        }
        return String(out)
    }

    /// Greedy word wrap of every line of `text` to at most `width` characters (words longer than the width stay whole). Blank lines and leading indentation are kept.
    static func wrap(_ text: String, width: Int) -> String {
        guard width > 0 else { return text }
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.count <= width { result.append(s); continue }
            let indent = String(s.prefix { $0 == " " || $0 == "\t" })
            var current = indent
            var hasWord = false
            for word in s.dropFirst(indent.count).split(separator: " ", omittingEmptySubsequences: true) {
                if !hasWord { current += word; hasWord = true; continue }
                if current.count + 1 + word.count <= width { current += " " + word }
                else { result.append(current); current = indent + word }
            }
            result.append(current)
        }
        return result.joined(separator: "\n")
    }

    // MARK: Streaming (huge files)

    /// Re-encodes `input` into `output` chunk by chunk (4 MiB): constant memory for any size. Returns the detected input encoding and the number of replaced characters.
    static func transcodeFile(input: URL, encodingIn: String, to output: URL, encodingOut: String, bom: Bool, eol: String?, progress: ((Double) -> Void)? = nil) throws -> (detected: String, replaced: Int) {
        let fm = FileManager.default
        guard fm.createFile(atPath: output.path, contents: nil) else { throw ConversionError.outputNotWritable(output.deletingLastPathComponent()) }
        let src = try FileHandle(forReadingFrom: input)
        let dst = try FileHandle(forWritingTo: output)
        defer { try? src.close(); try? dst.close() }
        let total = max(1, ((try? fm.attributesOfItem(atPath: input.path))?[.size] as? NSNumber)?.int64Value ?? 1)
        let head = try src.read(upToCount: 1 << 20) ?? Data()
        try src.seek(toOffset: 0)
        let det = detect(head)
        var inID = encodingIn.lowercased()
        var skip = 0
        if inID.isEmpty || inID == "auto" { inID = det.id; skip = det.bomLength }
        else if det.hasBOM, det.id.hasPrefix("utf-16") == inID.hasPrefix("utf-16"), det.id == inID || inID.hasPrefix("utf-16") { skip = det.bomLength; if inID.hasPrefix("utf-16") { inID = det.id } }
        try dst.write(contentsOf: bomBytes(for: encodingOut, utf8BOM: bom))
        var carry = Data()
        var first = true
        var pendingCR = false
        var done: Int64 = 0
        var replaced = 0
        while true {
            try Task.checkCancellation()
            let piece = try src.read(upToCount: 4 << 20) ?? Data()
            let last = piece.isEmpty
            var bytes = carry + piece
            carry = Data()
            if first, skip > 0 { bytes = Data(bytes.dropFirst(skip)) }
            first = false
            if !last {
                let keep = incompleteTail(bytes, encoding: inID)
                if keep > 0 { carry = Data(bytes.suffix(keep)); bytes = Data(bytes.dropLast(keep)) }
            }
            if !bytes.isEmpty {
                var text = decodeBody(bytes, encoding: inID).text
                if let eol {
                    if pendingCR, text.hasPrefix("\n") { text.removeFirst() }
                    pendingCR = text.hasSuffix("\r")
                    text = normalizeLineEndings(text, to: eol)
                }
                let enc = encodeBody(text, as: encodingOut)
                replaced += enc.replaced
                try dst.write(contentsOf: enc.data)
            }
            done += Int64(piece.count)
            progress?(min(1, Double(done) / Double(total)))
            if last { break }
        }
        return (inID, replaced)
    }

    /// How many bytes at the end of `bytes` belong to a character that continues in the next chunk.
    private static func incompleteTail(_ bytes: Data, encoding id: String) -> Int {
        switch id.lowercased() {
        case "utf-8", "utf8":
            var i = bytes.count - 1
            var back = 0
            while i >= 0, back < 4 {
                let c = bytes[bytes.startIndex + i]
                if c & 0xC0 == 0x80 { i -= 1; back += 1; continue }
                if c < 0x80 { return 0 }
                let need = c >= 0xF0 ? 3 : (c >= 0xE0 ? 2 : 1)
                return back < need ? back + 1 : 0
            }
            return 0
        case "utf-16", "utf-16le", "utf-16be":
            var keep = bytes.count % 2
            let usable = bytes.count - keep
            if usable >= 2 {
                let hi = bytes[bytes.startIndex + usable - (id.lowercased() == "utf-16be" ? 2 : 1)]
                if hi >= 0xD8 && hi <= 0xDB { keep += 2 }
            }
            return keep
        default: return 0
        }
    }

    /// Lines in a text file, counted with a streaming read of at most `limit` bytes (longer files are extrapolated). Cheap enough for the probe.
    static func countLines(_ url: URL, limit: Int = 16 << 20) -> (lines: Int, approximate: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        var count = 0, read = 0
        var lastByte: UInt8 = 10
        while read < limit, let d = try? h.read(upToCount: 1 << 20), !d.isEmpty {
            d.withUnsafeBytes { raw in for b in raw.bindMemory(to: UInt8.self) where b == 10 { count += 1 } }
            lastByte = d.last ?? 10
            read += d.count
        }
        if read == 0 { return (0, false) }
        if lastByte != 10 { count += 1 }
        if size > read { return (Int(Double(count) * Double(size) / Double(read)), true) }
        return (count, false)
    }
}
