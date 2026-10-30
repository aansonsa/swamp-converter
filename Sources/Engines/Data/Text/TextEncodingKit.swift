import Foundation

// Text encodings of the data module: CSV files, subtitles and zip entry names all arrive in unknown 8-bit code pages (Windows-1251, Windows-1257, KOI8-R, CP866 ...).
// Foundation's own auto-detection mislabels KOI8-R and CP866 (spec/backends.md fact 20), so detection here is: BOM, UTF-16 without BOM, strict UTF-8, then a plausibility
// score over single-byte candidates. Single-byte decoding goes through 256-entry tables (fast, and undefined bytes become U+FFFD instead of failing the whole file).

enum DataEncoding: String, CaseIterable, Sendable {
    case utf8 = "utf-8"
    /// UTF-16 little endian WITH byte order mark on write (what Excel calls "Unicode text"); BOM-detected on read.
    case utf16 = "utf-16"
    case utf16le = "utf-16le"
    case utf16be = "utf-16be"
    case windows1251 = "windows-1251"
    case windows1250 = "windows-1250"
    case windows1252 = "windows-1252"
    case windows1257 = "windows-1257"
    case koi8r = "koi8-r"
    case cp866 = "cp866"
    case cp437 = "cp437"
    case iso88592 = "iso-8859-2"
    case iso885913 = "iso-8859-13"

    /// Order = tie-break priority of the auto detector (a Russian owner: Cyrillic first, then Baltic, Central European, Western).
    static let singleByteCandidates: [DataEncoding] = [.windows1251, .windows1257, .windows1250, .koi8r, .cp866, .windows1252, .iso885913, .iso88592]

    var isSingleByte: Bool { Self.singleByteCandidates.contains(self) || self == .cp437 }
    var isUnicode: Bool { !isSingleByte }

    /// Parses "utf-8", "UTF8", "cp1251", "1251", "windows-1257", "koi8r" ... (picker values, CLI, presets).
    init?(key: String) {
        let k = key.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespaces)
        switch k {
        case "utf-8", "utf8", "utf-8-bom", "utf8bom": self = .utf8
        case "utf-16", "utf16", "ucs-2": self = .utf16
        case "utf-16le", "utf16le": self = .utf16le
        case "utf-16be", "utf16be": self = .utf16be
        case "windows-1251", "cp1251", "1251", "win1251", "windows1251": self = .windows1251
        case "windows-1250", "cp1250", "1250", "win1250", "windows1250": self = .windows1250
        case "windows-1252", "cp1252", "1252", "win1252", "latin1", "iso-8859-1": self = .windows1252
        case "windows-1257", "cp1257", "1257", "win1257", "windows1257": self = .windows1257
        case "koi8-r", "koi8r", "koi8": self = .koi8r
        case "cp866", "866", "ibm866", "dos-866": self = .cp866
        case "cp437", "437", "ibm437": self = .cp437
        case "iso-8859-2", "latin2", "iso88592": self = .iso88592
        case "iso-8859-13", "iso885913", "latin7": self = .iso885913
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16le: return "UTF-16 LE"
        case .utf16be: return "UTF-16 BE"
        case .windows1251: return "Windows-1251"
        case .windows1250: return "Windows-1250"
        case .windows1252: return "Windows-1252"
        case .windows1257: return "Windows-1257"
        case .koi8r: return "KOI8-R"
        case .cp866: return "CP866"
        case .cp437: return "CP437"
        case .iso88592: return "ISO-8859-2"
        case .iso885913: return "ISO-8859-13"
        }
    }

    fileprivate var foundationEncoding: String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))) }
        switch self {
        case .windows1251: return .windowsCP1251
        case .windows1250: return .windowsCP1250
        case .windows1252: return .windowsCP1252
        case .windows1257: return cf(.windowsBalticRim)
        case .koi8r: return cf(.KOI8_R)
        case .cp866: return cf(.dosRussian)
        case .cp437: return cf(.dosLatinUS)
        case .iso88592: return .isoLatin2
        case .iso885913: return cf(.isoLatin7)
        default: return nil
        }
    }
}

/// 256-entry decode tables (byte -> scalar; U+FFFD for undefined bytes) and the reverse maps, built once per encoding.
private final class SingleByteTables: @unchecked Sendable {
    static let shared = SingleByteTables()
    private let lock = NSLock()
    private var decodeCache: [DataEncoding: [UInt32]] = [:]
    private var encodeCache: [DataEncoding: [UInt32: UInt8]] = [:]

    func decodeTable(_ e: DataEncoding) -> [UInt32] {
        lock.lock(); if let t = decodeCache[e] { lock.unlock(); return t }; lock.unlock()
        var table = [UInt32](repeating: 0xFFFD, count: 256)
        for b in 0..<128 { table[b] = UInt32(b) }
        if let enc = e.foundationEncoding {
            for b in 128..<256 {
                if let s = String(data: Data([UInt8(b)]), encoding: enc), s.unicodeScalars.count == 1, let u = s.unicodeScalars.first { table[b] = u.value }
            }
        }
        lock.lock(); decodeCache[e] = table; lock.unlock()
        return table
    }

    func encodeMap(_ e: DataEncoding) -> [UInt32: UInt8] {
        lock.lock(); if let m = encodeCache[e] { lock.unlock(); return m }; lock.unlock()
        let table = decodeTable(e)
        var map: [UInt32: UInt8] = [:]
        for b in stride(from: 255, through: 0, by: -1) where table[b] != 0xFFFD { map[table[b]] = UInt8(b) }
        lock.lock(); encodeCache[e] = map; lock.unlock()
        return map
    }
}

struct DecodedText: Sendable {
    var text: String
    var encoding: DataEncoding
    /// True when a byte order mark was present (and removed).
    var hadBOM: Bool
}

enum TextEncodingKit {
    // MARK: Detection

    /// Looks at a byte order mark. Returns the encoding and the BOM length.
    static func bom(in head: Data) -> (DataEncoding, Int)? {
        let b = [UInt8](head.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return (.utf8, 3) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return (.utf16le, 2) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return (.utf16be, 2) }
        return nil
    }

    /// UTF-16 without a BOM: text in Latin / Cyrillic scripts has a NUL (or 0x04 for Cyrillic) in every second byte.
    private static func guessBOMlessUTF16(_ sample: [UInt8]) -> DataEncoding? {
        guard sample.count >= 8 else { return nil }
        var even = 0, odd = 0
        let n = sample.count & ~1
        var i = 0
        while i < n { if sample[i] == 0 { even += 1 }; if sample[i + 1] == 0 { odd += 1 }; i += 2 }
        let pairs = n / 2
        if odd * 10 >= pairs * 4 && even * 10 < pairs { return .utf16le }
        if even * 10 >= pairs * 4 && odd * 10 < pairs { return .utf16be }
        return nil
    }

    /// True when `bytes` is valid UTF-8 (strict: no overlong forms, no surrogates). A multi-byte sequence cut off at the very end is accepted when `allowTruncatedTail`.
    static func isValidUTF8(_ bytes: [UInt8], allowTruncatedTail: Bool = false) -> Bool {
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b < 0x80 { i += 1; continue }
            let need: Int
            let minimum: UInt32
            var cp: UInt32
            if b & 0xE0 == 0xC0 { need = 1; cp = UInt32(b & 0x1F); minimum = 0x80 }
            else if b & 0xF0 == 0xE0 { need = 2; cp = UInt32(b & 0x0F); minimum = 0x800 }
            else if b & 0xF8 == 0xF0 { need = 3; cp = UInt32(b & 0x07); minimum = 0x10000 }
            else { return false }
            if i + need > n - 1 {
                return allowTruncatedTail && bytes[(i + 1)..<n].allSatisfy { $0 & 0xC0 == 0x80 }
            }
            for k in 1...need {
                let c = bytes[i + k]
                if c & 0xC0 != 0x80 { return false }
                cp = (cp << 6) | UInt32(c & 0x3F)
            }
            if cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) { return false }
            i += need + 1
        }
        return true
    }

    /// Picks the most plausible single-byte code page for `sample`. `candidates` order breaks ties.
    static func detectSingleByte(_ sample: [UInt8], candidates: [DataEncoding] = DataEncoding.singleByteCandidates) -> DataEncoding {
        guard sample.contains(where: { $0 >= 0x80 }) else { return candidates.first ?? .windows1252 }
        var best = candidates.first ?? .windows1252
        var bestScore = -Double.infinity
        for c in candidates {
            let s = plausibility(sample, as: c)
            if s > bestScore + 1e-9 { bestScore = s; best = c }
        }
        return best
    }

    /// Higher = more like real text in that code page's languages. Counts letters (lower case counts more than upper case, letters of the code page's own
    /// languages more than other letters), penalises symbols, box-drawing characters, control codes, undefined bytes, "wRONG cASE" words (what a mis-decoded Cyrillic
    /// text looks like) and Latin texts in which most letters carry accents (what Cyrillic bytes look like when read as Latin-1).
    static func plausibility(_ bytes: [UInt8], as enc: DataEncoding) -> Double {
        let table = SingleByteTables.shared.decodeTable(enc)
        let profile = languageProfile(enc)
        let cyrillic = enc == .windows1251 || enc == .koi8r || enc == .cp866
        var score = 0.0
        var prevLower = false
        var prevLetter = false
        var scriptsInWord: UInt8 = 0   // bit 0 = Latin, bit 1 = Cyrillic
        var letters = 0, accented = 0
        for b in bytes {
            let u = table[Int(b)]
            if u < 0x80 {
                let isLetter = (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
                if isLetter { scriptsInWord |= 1; prevLower = u >= 0x61; prevLetter = true; letters += 1 }
                else { prevLetter = false; prevLower = false; scriptsInWord = 0 }
                continue
            }
            if u == 0xFFFD { score -= 8; continue }
            guard let sc = Unicode.Scalar(u) else { score -= 8; continue }
            let cat = sc.properties.generalCategory
            switch cat {
            case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter:
                let isCyr = u >= 0x400 && u <= 0x4FF
                scriptsInWord |= isCyr ? 2 : 1
                if scriptsInWord == 3 { score -= 4 }   // Latin and Cyrillic glued into one word never happens in real text
                letters += 1; accented += 1
                let isLower = cat == .lowercaseLetter
                let own = cyrillic ? isCyr : (!isCyr && profile.contains(u))
                if own { score += isLower ? 2.0 : 1.0 } else { score += isLower ? 0.3 : 0.15 }
                if cyrillic && profile.contains(u) { score += 1.0 }
                if !isLower && prevLower && prevLetter { score -= 2.0 }
                prevLower = isLower
                prevLetter = true
            case .spaceSeparator:
                prevLetter = false; prevLower = false; scriptsInWord = 0
                if u != 0xA0 { score -= 1 }
            case .control:
                score -= 10
            default:
                prevLetter = false; prevLower = false; scriptsInWord = 0
                score += commonPunctuation.contains(u) ? 0 : -3
            }
        }
        if !cyrillic && letters > 0 {
            let ratio = Double(accented) / Double(letters)
            if ratio > 0.4 { score -= (ratio - 0.4) * 12.0 * Double(accented) }
        }
        return score
    }

    private static let commonPunctuation: Set<UInt32> = [0xAB, 0xBB, 0x2018, 0x2019, 0x201A, 0x201C, 0x201D, 0x201E, 0x2013, 0x2014, 0x2026, 0x2022, 0x2116, 0xB0, 0xB1, 0xD7, 0xF7, 0x20AC, 0x2122, 0xA7, 0xA9, 0xAE, 0xB7, 0xB6, 0x2039, 0x203A, 0xB4, 0xBF, 0xA1]

    /// Letters that are frequent in the languages of a code page but rare when the same bytes are read with a neighbouring code page.
    private static func languageProfile(_ e: DataEncoding) -> Set<UInt32> {
        func set(_ s: String) -> Set<UInt32> { Set(s.unicodeScalars.map(\.value)) }
        switch e {
        case .windows1257, .iso885913: return set("āčēģīķļņšūžĀČĒĢĪĶĻŅŠŪŽąęėįųĄĘĖĮŲõÕäöüÄÖÜ")
        case .windows1250, .iso88592: return set("áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽąćęłńśźżĄĆĘŁŃŚŹŻőűŐŰ")
        case .windows1252: return set("àâçèêëîïôûùÿñæœßåÀÂÇÈÊËÎÏÔÛÙÑÆŒÅäöüÄÖÜéÉ")
        case .cp437: return set("éüäöçñáíóúÉÜÄÖÇÑ")
        case .koi8r, .windows1251, .cp866: return set("ёЁіїєґІЇЄҐ")
        default: return []
        }
    }

    // MARK: Decoding

    /// Decides the encoding of `data` without decoding all of it. `isPartial` marks a prefix of a bigger file (a multi-byte character may be cut at the end).
    static func detect(_ data: Data, isPartial: Bool = false, candidates: [DataEncoding] = DataEncoding.singleByteCandidates) -> (encoding: DataEncoding, bomLength: Int) {
        if let (enc, len) = bom(in: data) { return (enc, len) }
        let head = [UInt8](data.prefix(4096))
        if let e = guessBOMlessUTF16(head) { return (e, 0) }
        var bytes = [UInt8](data)
        if isPartial {
            // drop an incomplete trailing UTF-8 sequence
            var cut = 0
            while cut < 3, cut < bytes.count, bytes[bytes.count - 1 - cut] & 0xC0 == 0x80 { cut += 1 }
            if cut < bytes.count, bytes[bytes.count - 1 - cut] >= 0xC0 { bytes.removeLast(cut + 1) }
        }
        if isValidUTF8(bytes) { return (.utf8, 0) }
        let enc = detectSingleByte(sampleOfNonASCII(Data(bytes)), candidates: candidates)
        // A few stray bytes in an otherwise UTF-8 file (broken tail, pasted junk): keep UTF-8, the bad bytes become replacement characters.
        if looksLikeUTF8(Data(bytes)) { return (.utf8, 0) }
        return (enc, 0)
    }

    /// Decodes a whole file. `override` forces an encoding (a BOM matching a UTF encoding is still removed); nil = detect.
    static func decode(_ data: Data, override: DataEncoding? = nil, candidates: [DataEncoding] = DataEncoding.singleByteCandidates) -> DecodedText {
        let bomInfo = bom(in: data)
        if let o = override, !(o == .utf8 || o == .utf16 || o == .utf16le || o == .utf16be) {
            return DecodedText(text: decodeSingleByte(data, o), encoding: o, hadBOM: false)
        }
        if let (enc, len) = bomInfo, override == nil || override == enc || (override == .utf16 && (enc == .utf16le || enc == .utf16be)) {
            return DecodedText(text: decodeUnicode(data.dropFirst(len), enc), encoding: enc, hadBOM: true)
        }
        if let o = override {
            if o == .utf8 { return DecodedText(text: decodeUnicode(data, .utf8), encoding: .utf8, hadBOM: false) }
            let e: DataEncoding = o == .utf16 ? .utf16le : o
            return DecodedText(text: decodeUnicode(data, e), encoding: e, hadBOM: false)
        }
        let (enc, _) = detect(data, candidates: candidates)
        if enc.isSingleByte { return DecodedText(text: decodeSingleByte(data, enc), encoding: enc, hadBOM: false) }
        return DecodedText(text: decodeUnicode(data, enc), encoding: enc, hadBOM: false)
    }

    /// More than a quarter of the non-ASCII bytes belong to valid multi-byte UTF-8 sequences.
    private static func looksLikeUTF8(_ data: Data) -> Bool {
        var multi = 0, high = 0
        let bytes = [UInt8](data.prefix(1 << 16))
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b >= 0x80 { high += 1 }
            if b & 0xE0 == 0xC0, i + 1 < bytes.count, bytes[i + 1] & 0xC0 == 0x80 { multi += 2; i += 2; continue }
            if b & 0xF0 == 0xE0, i + 2 < bytes.count, bytes[i + 1] & 0xC0 == 0x80, bytes[i + 2] & 0xC0 == 0x80 { multi += 3; i += 3; continue }
            i += 1
        }
        return high > 0 && multi * 4 >= high * 3
    }

    /// Up to 96 KB of bytes taken around the non-ASCII regions of `data` (enough to decide on the code page of a huge file).
    static func sampleOfNonASCII(_ data: Data, budget: Int = 96 * 1024) -> [UInt8] {
        if data.count <= budget { return [UInt8](data) }
        var out: [UInt8] = []
        out.reserveCapacity(budget)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < p.count && out.count < budget {
                if p[i] >= 0x80 {
                    let lo = max(0, i - 24), hi = min(p.count, i + 200)
                    out.append(contentsOf: p[lo..<hi])
                    i = hi
                } else { i += 1 }
            }
        }
        return out
    }

    static func decodeSingleByte(_ data: Data, _ enc: DataEncoding) -> String {
        guard enc.isSingleByte else { return decodeUnicode(data, enc) }
        let table = SingleByteTables.shared.decodeTable(enc)
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for b in data { scalars.append(Unicode.Scalar(table[Int(b)]) ?? "\u{FFFD}") }
        return String(scalars)
    }

    static func decodeUnicode<D: DataProtocol>(_ data: D, _ enc: DataEncoding) -> String {
        let bytes = [UInt8](data)
        switch enc {
        case .utf8: return String(decoding: bytes, as: UTF8.self)
        case .utf16, .utf16le, .utf16be:
            let be = enc == .utf16be
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var i = 0
            while i + 1 < bytes.count {
                units.append(be ? (UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) : (UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        default: return decodeSingleByte(Data(bytes), enc)
        }
    }

    // MARK: Encoding

    struct EncodedText: Sendable {
        var data: Data
        /// Characters the code page cannot represent (written as "?").
        var replaced: Int
    }

    static func encode(_ text: String, as enc: DataEncoding, bom: Bool = false) -> EncodedText {
        switch enc {
        case .utf8:
            var d = Data()
            if bom { d.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            d.append(contentsOf: text.utf8)
            return EncodedText(data: d, replaced: 0)
        case .utf16, .utf16le, .utf16be:
            let be = enc == .utf16be
            var d = Data()
            if bom || enc == .utf16 { d.append(contentsOf: be ? [0xFE, 0xFF] : [0xFF, 0xFE]) }
            d.reserveCapacity(text.utf16.count * 2 + 2)
            for u in text.utf16 {
                if be { d.append(UInt8(u >> 8)); d.append(UInt8(u & 0xFF)) } else { d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
            }
            return EncodedText(data: d, replaced: 0)
        default:
            let map = SingleByteTables.shared.encodeMap(enc)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            var replaced = 0
            for sc in text.unicodeScalars {
                if sc.value < 0x80 { bytes.append(UInt8(sc.value)); continue }
                if let b = map[sc.value] { bytes.append(b); continue }
                // Try the canonical decomposition's base letter ("č" -> "c") before giving up; the loss is still counted.
                let base = String(sc).decomposedStringWithCanonicalMapping.unicodeScalars.first
                if let base, base.value < 0x80 { bytes.append(UInt8(base.value)) } else { bytes.append(0x3F) }
                replaced += 1
            }
            return EncodedText(data: Data(bytes), replaced: replaced)
        }
    }
}

/// Incremental decoder for streaming readers (big CSV files): feeds raw chunks, returns UTF-8 bytes. Keeps the odd byte / lone surrogate of UTF-16 between calls.
/// A byte order mark at the very start is dropped, even when it is split across chunks. Call `finish()` after the last chunk.
final class TextStreamDecoder {
    let encoding: DataEncoding
    private var carry: [UInt8] = []
    private var pendingHighSurrogate: UInt16?
    private var startBuffer: [UInt8] = []
    private var atStart = true
    private let table: [UInt32]

    init(encoding: DataEncoding) {
        self.encoding = encoding
        self.table = encoding.isSingleByte ? SingleByteTables.shared.decodeTable(encoding) : []
    }

    func decode(_ chunk: Data) -> [UInt8] {
        var bytes = [UInt8](chunk)
        if atStart {
            startBuffer += bytes
            if startBuffer.count < 4 { return [] }
            bytes = startBuffer; startBuffer = []; atStart = false
            if let (enc, len) = TextEncodingKit.bom(in: Data(bytes.prefix(4))), enc == encoding || (encoding == .utf16 && (enc == .utf16le || enc == .utf16be)) { bytes.removeFirst(len) }
        }
        return convert(bytes)
    }

    /// Flushes bytes held back at the start of a very short stream.
    func finish() -> [UInt8] {
        guard atStart else { return [] }
        atStart = false
        var bytes = startBuffer; startBuffer = []
        if let (enc, len) = TextEncodingKit.bom(in: Data(bytes.prefix(4))), enc == encoding || (encoding == .utf16 && (enc == .utf16le || enc == .utf16be)) { bytes.removeFirst(len) }
        return convert(bytes)
    }

    private func convert(_ input: [UInt8]) -> [UInt8] {
        var bytes = input
        switch encoding {
        case .utf8: return bytes
        case .utf16, .utf16le, .utf16be:
            bytes = carry + bytes
            carry = []
            if bytes.count % 2 == 1 { carry = [bytes.removeLast()] }
            let be = encoding == .utf16be
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2 + 1)
            if let h = pendingHighSurrogate { units.append(h); pendingHighSurrogate = nil }
            var i = 0
            while i + 1 < bytes.count {
                units.append(be ? (UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) : (UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])))
                i += 2
            }
            if let last = units.last, last >= 0xD800 && last <= 0xDBFF { pendingHighSurrogate = last; units.removeLast() }
            return Array(String(decoding: units, as: UTF16.self).utf8)
        default:
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + bytes.count / 4)
            for b in bytes {
                if b < 0x80 { out.append(b); continue }
                let sc = Unicode.Scalar(table[Int(b)]) ?? "\u{FFFD}"
                out.append(contentsOf: String(Character(sc)).utf8)
            }
            return out
        }
    }
}
