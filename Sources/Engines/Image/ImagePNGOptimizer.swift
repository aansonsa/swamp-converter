import Foundation
import zlib

/// Lossless PNG recompression. ImageIO writes every PNG with filter type "none" and the fastest zlib setting, which makes photographs and screenshots 15 to 25 percent
/// larger than they need to be. This takes a finished PNG, picks the best of the five PNG row filters for each row (the minimum-sum-of-absolute-differences heuristic of
/// the PNG specification), deflates the result again with zlib at a level that suits the size, and keeps it only when it is smaller. Every other chunk (profile,
/// resolution, metadata) is copied untouched and the pixels are bit-identical. Palette and low-bit-depth files keep their rows as they are and are only re-deflated;
/// interlaced files and pictures too large to hold in memory twice are left alone.
enum PNGOptimizer {
    /// Pictures above this many pixels are not recompressed (about 400 MB of working memory for RGBA).
    static let maxPixels = 40_000_000

    /// The recompressed file, or nil when it would not be smaller or the input is not a plain non-interlaced PNG this code understands.
    static func optimized(_ png: Data) throws -> Data? {
        let bytes = [UInt8](png)
        guard bytes.count > 57, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }

        struct Chunk { var type: [UInt8]; var start: Int; var dataStart: Int; var end: Int }
        let idatType = Array("IDAT".utf8)
        var chunks: [Chunk] = []
        var pos = 8
        while pos + 12 <= bytes.count {
            let len = Int(be32(bytes, pos))
            let end = pos + 12 + len
            guard end <= bytes.count else { return nil }
            chunks.append(Chunk(type: Array(bytes[(pos + 4)..<(pos + 8)]), start: pos, dataStart: pos + 8, end: end))
            pos = end
        }
        guard let ihdr = chunks.first, ihdr.type == Array("IHDR".utf8), ihdr.end - ihdr.start == 25 else { return nil }
        let w = Int(be32(bytes, ihdr.dataStart)), h = Int(be32(bytes, ihdr.dataStart + 4))
        let depth = Int(bytes[ihdr.dataStart + 8]), colorType = Int(bytes[ihdr.dataStart + 9]), interlace = Int(bytes[ihdr.dataStart + 12])
        guard w > 0, h > 0, w * h <= maxPixels, interlace == 0, bytes[ihdr.dataStart + 10] == 0, bytes[ihdr.dataStart + 11] == 0,
              let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colorType] else { return nil }
        let bitsPerPixel = channels * depth
        let bpp = max(1, bitsPerPixel / 8), rowBytes = (w * bitsPerPixel + 7) / 8
        let refilter = colorType != 3 && depth >= 8

        var idat: [UInt8] = []
        for c in chunks where c.type == idatType { idat.append(contentsOf: bytes[c.dataStart..<(c.end - 4)]) }
        guard idat.count > 6 else { return nil }

        let expected = h * (rowBytes + 1)
        guard var raw = inflate(idat, expected: expected) else { return nil }
        try Task.checkCancellation()

        if refilter {
            var pix = [UInt8](repeating: 0, count: h * rowBytes)
            var valid = true
            let zero = [UInt8](repeating: 0, count: rowBytes)
            raw.withUnsafeBufferPointer { r in
                pix.withUnsafeMutableBufferPointer { p in
                    zero.withUnsafeBufferPointer { z in
                        for y in 0..<h {
                            let f = r[y * (rowBytes + 1)]
                            if f > 4 { valid = false; return }
                            let up = y > 0 ? UnsafePointer(p.baseAddress! + (y - 1) * rowBytes) : z.baseAddress!
                            unfilterRow(Int(f), r.baseAddress! + y * (rowBytes + 1) + 1, p.baseAddress! + y * rowBytes, up, rowBytes, bpp)
                        }
                    }
                }
            }
            guard valid else { return nil }
            try Task.checkCancellation()

            // Rows are independent once the pixels are known: choose their filters on all cores.
            let bands = max(1, min(ProcessInfo.processInfo.activeProcessorCount, h / 16))
            let perBand = (h + bands - 1) / bands
            pix.withUnsafeBufferPointer { p in
                raw.withUnsafeMutableBufferPointer { out in
                    zero.withUnsafeBufferPointer { z in
                        let pbase = p.baseAddress!, obase = out.baseAddress!, zbase = z.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: bands) { band in
                            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes * 2)
                            defer { scratch.deallocate() }
                            let y0 = band * perBand, y1 = min(h, y0 + perBand)
                            if y0 >= y1 { return }
                            for y in y0..<y1 {
                                let cur = pbase + y * rowBytes
                                let up = y > 0 ? pbase + (y - 1) * rowBytes : zbase
                                var best = 0, bestScore = Int.max
                                for f in 0..<5 {
                                    let score = filterRow(f, cur, up, scratch, rowBytes, bpp)
                                    if score < bestScore {
                                        bestScore = score; best = f
                                        (scratch + rowBytes).update(from: scratch, count: rowBytes)
                                    }
                                }
                                let o = obase + y * (rowBytes + 1)
                                o[0] = UInt8(best)
                                (o + 1).update(from: scratch + rowBytes, count: rowBytes)
                            }
                        }
                    }
                }
            }
            try Task.checkCancellation()
        }

        guard let z = try deflate(raw, level: level(forBytes: raw.count), filtered: refilter, mustBeBelow: idat.count), z.count < idat.count else { return nil }

        // Reassemble: everything except IDAT is copied; the new IDAT sits where the first one was.
        var out = [UInt8](bytes[0..<8])
        out.reserveCapacity(bytes.count)
        var wrote = false
        for c in chunks {
            if c.type == idatType {
                if !wrote { appendChunk("IDAT", z, to: &out); wrote = true }
            } else {
                out.append(contentsOf: bytes[c.start..<c.end])
            }
        }
        return Data(out)
    }

    /// Strong settings for small pictures, quick ones for huge pictures (zlib level 9 is about 15 times slower than 6 on photographs for a few percent more).
    static func level(forBytes n: Int) -> Int32 { n <= 3_000_000 ? 9 : (n <= 12_000_000 ? 6 : (n <= 48_000_000 ? 4 : 3)) }

    // MARK: Filters

    @inline(__always) private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
    }

    private static func unfilterRow(_ f: Int, _ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ up: UnsafePointer<UInt8>, _ n: Int, _ bpp: Int) {
        switch f {
        case 0: dst.update(from: src, count: n)
        case 1:
            for i in 0..<min(bpp, n) { dst[i] = src[i] }
            if n > bpp { for i in bpp..<n { dst[i] = src[i] &+ dst[i - bpp] } }
        case 2:
            for i in 0..<n { dst[i] = src[i] &+ up[i] }
        case 3:
            for i in 0..<min(bpp, n) { dst[i] = src[i] &+ UInt8(Int(up[i]) >> 1) }
            if n > bpp { for i in bpp..<n { dst[i] = src[i] &+ UInt8((Int(dst[i - bpp]) + Int(up[i])) >> 1) } }
        default:
            for i in 0..<min(bpp, n) { dst[i] = src[i] &+ up[i] }
            if n > bpp { for i in bpp..<n { dst[i] = src[i] &+ UInt8(paeth(Int(dst[i - bpp]), Int(up[i]), Int(up[i - bpp]))) } }
        }
    }

    /// Filters `cur` into `out` and returns the sum of absolute values of the result read as signed bytes (smaller compresses better).
    private static func filterRow(_ f: Int, _ cur: UnsafePointer<UInt8>, _ up: UnsafePointer<UInt8>, _ out: UnsafeMutablePointer<UInt8>, _ n: Int, _ bpp: Int) -> Int {
        var score = 0
        @inline(__always) func put(_ i: Int, _ v: UInt8) { out[i] = v; let x = Int(v); score += x < 128 ? x : 256 - x }
        let head = min(bpp, n)
        switch f {
        case 0: for i in 0..<n { put(i, cur[i]) }
        case 1:
            for i in 0..<head { put(i, cur[i]) }
            if n > bpp { for i in bpp..<n { put(i, cur[i] &- cur[i - bpp]) } }
        case 2:
            for i in 0..<n { put(i, cur[i] &- up[i]) }
        case 3:
            for i in 0..<head { put(i, cur[i] &- UInt8(Int(up[i]) >> 1)) }
            if n > bpp { for i in bpp..<n { put(i, cur[i] &- UInt8((Int(cur[i - bpp]) + Int(up[i])) >> 1)) } }
        default:
            for i in 0..<head { put(i, cur[i] &- up[i]) }
            if n > bpp { for i in bpp..<n { put(i, cur[i] &- UInt8(paeth(Int(cur[i - bpp]), Int(up[i]), Int(up[i - bpp])))) } }
        }
        return score
    }

    // MARK: zlib

    /// The decompressed IDAT stream, only when it is exactly `expected` bytes.
    private static func inflate(_ data: [UInt8], expected: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: expected)
        var strm = z_stream()
        guard inflateInit_(&strm, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&strm) }
        var status: Int32 = Z_OK
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                strm.next_in = UnsafeMutablePointer(mutating: src.baseAddress!)
                strm.avail_in = UInt32(src.count)
                strm.next_out = dst.baseAddress!
                strm.avail_out = UInt32(dst.count)
                status = zlib.inflate(&strm, Z_FINISH)
            }
        }
        return status == Z_STREAM_END && Int(strm.total_out) == expected ? out : nil
    }

    /// A zlib stream of `data`, fed in 64 KiB pieces so a cancel is noticed quickly. nil on failure.
    private static func deflate(_ data: [UInt8], level: Int32, filtered: Bool, mustBeBelow limit: Int) throws -> [UInt8]? {
        var strm = z_stream()
        guard deflateInit2_(&strm, level, Z_DEFLATED, 15, 8, filtered ? Z_FILTERED : Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&strm) }
        let bufferSize = 1 << 18
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 2)
        let piece = 1 << 16
        var offset = 0
        var checkpoint = max(2_000_000, data.count / 8)
        return try data.withUnsafeBufferPointer { src -> [UInt8]? in
            while true {
                try Task.checkCancellation()
                let n = min(piece, data.count - offset)
                let last = offset + n >= data.count
                strm.next_in = UnsafeMutablePointer(mutating: src.baseAddress!.advanced(by: offset))
                strm.avail_in = UInt32(n)
                offset += n
                repeat {
                    strm.next_out = buffer
                    strm.avail_out = UInt32(bufferSize)
                    let status = zlib.deflate(&strm, last ? Z_FINISH : Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { return nil }
                    out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: bufferSize - Int(strm.avail_out)))
                    if status == Z_STREAM_END { return out }
                    // Noise does not compress: when the first part already shows no gain over the original, stop instead of spending seconds on the rest.
                    if offset >= checkpoint, !last {
                        checkpoint = Int.max
                        if Double(out.count) * Double(data.count) / Double(offset) > Double(limit) * 0.985 { return nil }
                    }
                } while strm.avail_out == 0 || strm.avail_in > 0
                if last { return nil }
            }
        }
    }

    // MARK: Chunks

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 255)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }

    private static func appendChunk(_ type: String, _ body: [UInt8], to out: inout [UInt8]) {
        let n = UInt32(body.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        let tb = Array(type.utf8)
        out.append(contentsOf: tb)
        out.append(contentsOf: body)
        let crc = crc32(tb + body)
        out.append(contentsOf: [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)])
    }
}
