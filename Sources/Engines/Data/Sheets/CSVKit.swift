import Foundation

// CSV / TSV: an incremental RFC 4180 parser over UTF-8 bytes, a delimiter sniffer, a streaming file reader (any size, constant memory) and a row writer.
//
// Parser rules (spec/backends.md 3.6.1, kept on purpose): a quote opens a quoted field ONLY at the start of a field (`ab"c` keeps the quote); after the closing quote
// anything that follows is appended unquoted; CR, LF and CRLF all end a row; a blank line is a row with one empty field; rows are not padded; a final row without
// a newline is kept.

struct CSVParser {
    let delimiter: UInt8
    private enum State { case start, unquoted, quoted, afterQuote }
    private var state = State.start
    private var field: [UInt8] = []
    private var row: [String] = []
    private var skipLF = false

    init(delimiter: UInt8) { self.delimiter = delimiter; field.reserveCapacity(64) }

    mutating func feed(_ bytes: [UInt8], emit: ([String]) throws -> Void) rethrows {
        let quote: UInt8 = 0x22, lf: UInt8 = 0x0A, cr: UInt8 = 0x0D
        for b in bytes {
            if skipLF { skipLF = false; if b == lf { continue } }
            switch state {
            case .start:
                if b == quote { state = .quoted }
                else if b == delimiter { endField(); }
                else if b == lf { endField(); try endRow(emit) }
                else if b == cr { endField(); try endRow(emit); skipLF = true }
                else { field.append(b); state = .unquoted }
            case .unquoted:
                if b == delimiter { endField(); state = .start }
                else if b == lf { endField(); try endRow(emit); state = .start }
                else if b == cr { endField(); try endRow(emit); state = .start; skipLF = true }
                else { field.append(b) }
            case .quoted:
                if b == quote { state = .afterQuote } else { field.append(b) }
            case .afterQuote:
                if b == quote { field.append(quote); state = .quoted }
                else if b == delimiter { endField(); state = .start }
                else if b == lf { endField(); try endRow(emit); state = .start }
                else if b == cr { endField(); try endRow(emit); state = .start; skipLF = true }
                else { field.append(b); state = .unquoted }
            }
        }
    }

    /// Flushes the last row when the data does not end with a line break.
    mutating func finish(emit: ([String]) throws -> Void) rethrows {
        if state != .start || !field.isEmpty || !row.isEmpty { endField(); try endRow(emit) }
        state = .start
    }

    private mutating func endField() {
        row.append(String(decoding: field, as: UTF8.self))
        field.removeAll(keepingCapacity: true)
    }
    private mutating func endRow(_ emit: ([String]) throws -> Void) rethrows {
        let r = row
        row = []
        try emit(r)
    }
}

enum CSVSniffer {
    static let candidates: [UInt8] = [0x2C, 0x3B, 0x09, 0x7C]   // , ; TAB |

    /// Chooses the delimiter whose count per line is the most consistent over the first lines (quoted text ignored). Ties favour the order `, ; TAB |`.
    /// A comma that only ever sits between two digits (`1,5`) is a decimal mark, not a delimiter, when another candidate is consistent too.
    static func detect(_ utf8: [UInt8], maxLines: Int = 30) -> UInt8 {
        var counts: [[Int]] = Array(repeating: [], count: candidates.count)
        var current = [Int](repeating: 0, count: candidates.count)
        var inQuotes = false
        var lines = 0
        var hasContent = false
        var prevCR = false
        var prev: UInt8 = 0
        var commaTotal = 0, commaBetweenDigits = 0
        var commaPending = false          // the previous byte was a comma that follows a digit: is the next byte a digit?
        func endLine() {
            if hasContent { for i in 0..<candidates.count { counts[i].append(current[i]) }; lines += 1 }
            current = [Int](repeating: 0, count: candidates.count); hasContent = false
        }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        for b in utf8 {
            if commaPending { if isDigit(b) { commaBetweenDigits += 1 }; commaPending = false }
            if b == 0x22 { inQuotes.toggle(); hasContent = true; prevCR = false; prev = b; continue }
            if !inQuotes && (b == 0x0A || b == 0x0D) {
                if !(b == 0x0A && prevCR) { endLine() }
                prevCR = b == 0x0D
                prev = b
                if lines >= maxLines { break }
                continue
            }
            prevCR = false
            hasContent = true
            if !inQuotes, let i = candidates.firstIndex(of: b) {
                current[i] += 1
                if b == 0x2C { commaTotal += 1; if isDigit(prev) { commaPending = true } }
            }
            prev = b
        }
        if lines < maxLines { endLine() }
        var scores: [(index: Int, score: Int)] = []
        for i in 0..<candidates.count {
            let nonZero = counts[i].filter { $0 > 0 }
            guard !nonZero.isEmpty else { continue }
            var freq: [Int: Int] = [:]
            for c in nonZero { freq[c, default: 0] += 1 }
            let modal = freq.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }!
            scores.append((i, modal.value * 1000 + modal.key))
        }
        guard var best = scores.max(by: { $0.score != $1.score ? $0.score < $1.score : $0.index > $1.index }) else { return candidates[0] }
        if candidates[best.index] == 0x2C, commaTotal > 0, commaBetweenDigits == commaTotal,
           let other = scores.filter({ $0.index != best.index }).max(by: { $0.score != $1.score ? $0.score < $1.score : $0.index > $1.index }) {
            best = other                               // 1,5;2,5: the commas are decimal marks
        }
        return candidates[best.index]
    }

    static func name(of d: UInt8) -> String {
        switch d { case 0x3B: return "semicolon"; case 0x09: return "tab"; case 0x7C: return "pipe"; default: return "comma" }
    }
    static func byte(named n: String) -> UInt8? {
        switch n { case "comma": return 0x2C; case "semicolon": return 0x3B; case "tab": return 0x09; case "pipe": return 0x7C; default: return nil }
    }
}

struct CSVReadOptions {
    var encoding: DataEncoding? = nil
    var delimiter: UInt8? = nil
    /// `.tsv` files default to TAB instead of sniffing.
    var preferTab = false
}

struct CSVFileInfo {
    var encoding: DataEncoding
    var delimiter: UInt8
    var hadBOM: Bool
}

enum CSVFile {
    static let chunkSize = 4 * 1024 * 1024

    /// Streams the rows of a delimited text file. `onRow` returns false to stop early (previews). Memory stays at one chunk plus one row.
    @discardableResult
    static func stream(_ url: URL, options: CSVReadOptions = CSVReadOptions(), progress: ((Double) -> Void)? = nil, onRow: ([String]) throws -> Bool) throws -> CSVFileInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ConversionError.fileUnreadable(url) }
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let first = try? handle.read(upToCount: chunkSize) else { throw ConversionError.fileUnreadable(url) }
        let bom = TextEncodingKit.bom(in: first) != nil
        var enc = options.encoding
        if enc == nil { enc = TextEncodingKit.detect(first, isPartial: Int64(first.count) < total).encoding }
        if enc == .utf16 { enc = TextEncodingKit.bom(in: first)?.0 ?? .utf16le }
        let decoder = TextStreamDecoder(encoding: enc!)
        var pending = decoder.decode(first)
        if first.count < chunkSize || pending.isEmpty { pending += decoder.finish() }
        let delimiter = options.delimiter ?? (options.preferTab ? 0x09 : CSVSniffer.detect(pending))
        var parser = CSVParser(delimiter: delimiter)
        var stopped = false
        func feed(_ bytes: [UInt8]) throws {
            try parser.feed(bytes) { r in
                if stopped { return }
                if try !onRow(r) { stopped = true }
            }
        }
        try feed(pending)
        var consumed = Int64(first.count)
        while !stopped {
            try Task.checkCancellation()
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            consumed += Int64(chunk.count)
            progress?(min(1, Double(consumed) / Double(max(total, 1))))
            try feed(decoder.decode(chunk))
        }
        if !stopped {
            try feed(decoder.finish())
            try parser.finish { r in if try !onRow(r) { stopped = true } }
        }
        return CSVFileInfo(encoding: enc!, delimiter: delimiter, hadBOM: bom)
    }
}

/// Writes rows as delimited text in any supported encoding: quoting per RFC 4180 (a field is quoted when it contains the delimiter, a quote, CR or LF; quotes are doubled),
/// TSV replaces tabs inside values with spaces, optional "quote everything".
final class CSVRowWriter {
    private let handle: FileHandle
    private let dialect: CSVDialect
    private let encoding: DataEncoding
    private var buffer = String()
    private var bomPending: Bool
    private(set) var replacedCharacters = 0
    private(set) var rows = 0
    private let eol: String
    private let delimiter: Character
    private let delimiterByte: UInt8?
    private let isTab: Bool

    init(url: URL, dialect: CSVDialect) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        handle = h
        self.dialect = dialect
        encoding = dialect.resolvedEncoding
        eol = dialect.crlf ? "\r\n" : "\n"
        delimiter = dialect.delimiter
        delimiterByte = dialect.delimiter.asciiValue
        isTab = dialect.delimiter == "\t"
        switch encoding {
        case .utf16: bomPending = true                                   // "Unicode text" as Excel writes it: UTF-16 LE with a byte order mark
        case .utf8, .utf16le, .utf16be: bomPending = dialect.bom
        default: bomPending = false
        }
        buffer.reserveCapacity(1 << 20)
    }

    func write(row: [String]) throws {
        var first = true
        for var f in row {
            if !first { buffer.append(delimiter) }
            first = false
            if isTab { f = f.replacingOccurrences(of: "\t", with: " ") }
            if dialect.quoteAll || needsQuoting(f) {
                buffer.append(dialect.quote)
                buffer.append(f.replacingOccurrences(of: String(dialect.quote), with: String(dialect.quote) + String(dialect.quote)))
                buffer.append(dialect.quote)
            } else {
                buffer.append(f)
            }
        }
        buffer.append(eol)
        rows += 1
        if buffer.utf8.count > 768 * 1024 { try flush() }
    }

    private func needsQuoting(_ f: String) -> Bool {
        if let d = delimiterByte {
            for u in f.utf8 { if u == 0x22 || u == 0x0A || u == 0x0D || u == d { return true } }
            return false
        }
        for u in f.utf8 { if u == 0x22 || u == 0x0A || u == 0x0D { return true } }
        return f.contains(delimiter)
    }

    private func flush() throws {
        if buffer.isEmpty { return }
        let enc = TextEncodingKit.encode(buffer, as: encoding == .utf16 ? .utf16le : encoding, bom: bomPending)
        bomPending = false
        replacedCharacters += enc.replaced
        do { try handle.write(contentsOf: enc.data) } catch { throw FSErrors.map(ENOSPC, path: "") }
        buffer.removeAll(keepingCapacity: true)
    }

    func finish() throws {
        if buffer.isEmpty && bomPending {
            // an empty table still announces its encoding
            try handle.write(contentsOf: TextEncodingKit.encode("", as: encoding == .utf16 ? .utf16le : encoding, bom: true).data)
            bomPending = false
        }
        try flush()
        try handle.close()
    }
}

extension CSVDialect {
    /// The encoding the writer uses: `dataEncoding` when set, otherwise the Foundation encoding mapped to ours.
    var resolvedEncoding: DataEncoding {
        if let d = dataEncoding { return d }
        switch encoding {
        case .utf8: return .utf8
        case .utf16, .unicode: return .utf16
        case .utf16LittleEndian: return .utf16le
        case .utf16BigEndian: return .utf16be
        case .windowsCP1251: return .windows1251
        case .windowsCP1250: return .windows1250
        case .windowsCP1252: return .windows1252
        default: return .utf8
        }
    }
}
