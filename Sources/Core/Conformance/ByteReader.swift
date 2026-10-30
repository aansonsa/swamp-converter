import Foundation

// Random-access reads for the format sniffer and the container walkers: a file is never loaded whole.

final class ByteReader {
    private let handle: FileHandle
    let size: UInt64
    let _url: URL

    init?(url: URL) {
        _url = url
        guard let h = try? FileHandle(forReadingFrom: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        handle = h
        size = n
    }

    deinit { try? handle.close() }

    /// Up to `count` bytes at `offset` (fewer at the end of the file, empty past it).
    func read(at offset: UInt64, _ count: Int) -> [UInt8] {
        guard offset < size, count > 0 else { return [] }
        do {
            try handle.seek(toOffset: offset)
            return Array(try handle.read(upToCount: count) ?? Data())
        } catch { return [] }
    }

    func head(_ count: Int = 4096) -> [UInt8] { read(at: 0, count) }

    func tail(_ count: Int) -> [UInt8] {
        let n = UInt64(count)
        return read(at: size > n ? size - n : 0, count)
    }

    func u32be(at offset: UInt64) -> UInt32? {
        let b = read(at: offset, 4)
        guard b.count == 4 else { return nil }
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func u64be(at offset: UInt64) -> UInt64? {
        let b = read(at: offset, 8)
        guard b.count == 8 else { return nil }
        return b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

extension Array where Element == UInt8 {
    func hasPrefix(_ s: String, at offset: Int = 0) -> Bool {
        let p = Array(s.utf8)
        guard offset >= 0, count >= offset + p.count else { return false }
        return Array(self[offset..<(offset + p.count)]) == p
    }

    func hasBytes(_ p: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, count >= offset + p.count else { return false }
        return Array(self[offset..<(offset + p.count)]) == p
    }

    /// ASCII text of `range`, non-printable bytes as "?".
    func ascii(_ range: Range<Int>) -> String {
        let lo = Swift.max(0, range.lowerBound), hi = Swift.min(count, range.upperBound)
        guard lo < hi else { return "" }
        return String(self[lo..<hi].map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "?" })
    }

    func u32be(at i: Int) -> UInt32? {
        guard i >= 0, count >= i + 4 else { return nil }
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    func u32le(at i: Int) -> UInt32? {
        guard i >= 0, count >= i + 4 else { return nil }
        return (UInt32(self[i + 3]) << 24) | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 1]) << 8) | UInt32(self[i])
    }

    func u16le(at i: Int) -> UInt16? {
        guard i >= 0, count >= i + 2 else { return nil }
        return (UInt16(self[i + 1]) << 8) | UInt16(self[i])
    }

    func u16be(at i: Int) -> UInt16? {
        guard i >= 0, count >= i + 2 else { return nil }
        return (UInt16(self[i]) << 8) | UInt16(self[i + 1])
    }
}
