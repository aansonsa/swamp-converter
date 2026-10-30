import Foundation

// Canonical PCM files written by hand: WAV (RIFF) and AIFF (FORM). AVAudioFile writes a 28-byte JUNK chunk in front of "fmt " and 4 KB of FLLR padding,
// and calls a big-endian file AIFC; both are legal but many readers (and byte sniffers) expect the plain layout: "fmt " first, "data" next, a true AIFF.
// The writer streams: a header with zero sizes goes out first, samples are appended as they arrive, `close()` patches the sizes.

final class AudPCMWriter {
    enum Container { case wav, aiff }

    private let handle: FileHandle
    private let container: Container
    let rate: Int
    let channels: Int
    /// 16, 24 or 32 (32 means IEEE float; AIFF supports 16 and 24 only).
    let bits: Int
    private(set) var frames = 0
    private var closed = false
    private var headerSize = 0
    private let sizeFieldOffsets: (riff: Int, data: Int, fact: Int?)

    /// WAV holds at most 4 GiB; the writer refuses to go beyond rather than wrap the size field.
    static let maxDataBytes: Int64 = 0xFFFF_FFFF - 1_000

    init(url: URL, container: Container, rate: Int, channels: Int, bits: Int) throws {
        guard channels >= 1, rate > 0, [16, 24, 32].contains(bits), !(container == .aiff && bits == 32) else {
            throw ConversionError.message(L10n("This sound format cannot be written with these settings.", "Этот формат звука нельзя записать с такими параметрами."))
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        handle = h
        self.container = container; self.rate = rate; self.channels = channels; self.bits = bits
        let built = container == .wav ? Self.wavHeader(rate: rate, channels: channels, bits: bits) : Self.aiffHeader(rate: rate, channels: channels, bits: bits)
        let header = built.0
        sizeFieldOffsets = built.1
        headerSize = header.count
        do { try handle.write(contentsOf: header) } catch { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
    }

    deinit { if !closed { try? handle.close() } }

    var dataBytes: Int64 { Int64(frames) * Int64(channels) * Int64(bits / 8) }

    /// Appends planar float samples (-1...1; values beyond are clipped).
    func write(_ chunk: AudChunk) throws {
        guard let n = chunk.first?.count, n > 0, chunk.count == channels else { return }
        guard dataBytes + Int64(n * channels * (bits / 8)) <= Self.maxDataBytes else {
            throw ConversionError.message(L10n("The sound is too long for a WAV or AIFF file (4 GB). Choose FLAC or CAF.", "Звук слишком длинный для WAV или AIFF (4 ГБ). Выберите FLAC или CAF."))
        }
        let bytes = bits / 8
        var out = Data(count: n * channels * bytes)
        let wav = container == .wav
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            for c in 0..<channels {
                chunk[c].withUnsafeBufferPointer { src in
                    var o = c * bytes
                    for i in 0..<n {
                        let x = src[i]
                        switch bits {
                        case 32:
                            let u = x.bitPattern
                            p[o] = UInt8(truncatingIfNeeded: u); p[o + 1] = UInt8(truncatingIfNeeded: u >> 8); p[o + 2] = UInt8(truncatingIfNeeded: u >> 16); p[o + 3] = UInt8(truncatingIfNeeded: u >> 24)
                        case 24:
                            let s = Int32(max(-8_388_608, min(8_388_607, (Double(x) * 8_388_608).rounded())))
                            if wav { p[o] = UInt8(truncatingIfNeeded: s); p[o + 1] = UInt8(truncatingIfNeeded: s >> 8); p[o + 2] = UInt8(truncatingIfNeeded: s >> 16) }
                            else { p[o] = UInt8(truncatingIfNeeded: s >> 16); p[o + 1] = UInt8(truncatingIfNeeded: s >> 8); p[o + 2] = UInt8(truncatingIfNeeded: s) }
                        default:
                            let s = Int16(max(-32_768, min(32_767, (Double(x) * 32_768).rounded())))
                            if wav { p[o] = UInt8(truncatingIfNeeded: s); p[o + 1] = UInt8(truncatingIfNeeded: s >> 8) }
                            else { p[o] = UInt8(truncatingIfNeeded: s >> 8); p[o + 1] = UInt8(truncatingIfNeeded: s) }
                        }
                        o += channels * bytes
                    }
                }
            }
        }
        do { try handle.write(contentsOf: out) }
        catch { throw ConversionError.message(L10n("Writing the sound failed. Check the free space and the output folder.", "Не удалось записать звук. Проверьте свободное место и папку результата.")) }
        frames += n
    }

    /// Pads to an even length, patches the size fields and closes the file.
    func close() throws {
        guard !closed else { return }
        closed = true
        defer { try? handle.close() }
        let data = dataBytes
        if data % 2 == 1 { try handle.write(contentsOf: Data([0])) }       // chunk bodies end on an even byte
        let padded = data + data % 2
        let total = Int64(headerSize) + padded
        func put(_ value: Int64, at offset: Int, bigEndian: Bool) throws {
            var b = Data(count: 4)
            let v = UInt32(truncatingIfNeeded: value)
            for i in 0..<4 { b[i] = UInt8(truncatingIfNeeded: v >> UInt32(bigEndian ? 8 * (3 - i) : 8 * i)) }
            try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: b)
        }
        switch container {
        case .wav:
            try put(total - 8, at: sizeFieldOffsets.riff, bigEndian: false)
            try put(data, at: sizeFieldOffsets.data, bigEndian: false)
            if let f = sizeFieldOffsets.fact { try put(Int64(frames), at: f, bigEndian: false) }
        case .aiff:
            try put(total - 8, at: sizeFieldOffsets.riff, bigEndian: true)
            try put(data + 8, at: sizeFieldOffsets.data, bigEndian: true)            // SSND size includes offset + block size
            if let f = sizeFieldOffsets.fact { try put(Int64(frames), at: f, bigEndian: true) }
        }
    }

    // MARK: Headers

    private static func wavHeader(rate: Int, channels: Int, bits: Int) -> (Data, (riff: Int, data: Int, fact: Int?)) {
        var d = Data()
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: x).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: x).littleEndian) { d.append(contentsOf: $0) } }
        let isFloat = bits == 32
        let extensible = channels > 2
        let block = channels * bits / 8
        d.append(contentsOf: Array("RIFF".utf8)); u32(0); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(extensible ? 40 : 16)
        u16(extensible ? 0xFFFE : (isFloat ? 3 : 1)); u16(channels); u32(rate); u32(rate * block); u16(block); u16(bits)
        if extensible {
            u16(22); u16(bits)
            let mask: Int
            switch channels { case 6: mask = 0x3F; case 8: mask = 0x63F; default: mask = (1 << min(channels, 30)) - 1 }
            u32(mask)
            u16(isFloat ? 3 : 1)
            d.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        var factOffset: Int? = nil
        if isFloat {            // the RIFF specification asks for a fact chunk in front of non-integer data
            d.append(contentsOf: Array("fact".utf8)); u32(4)
            factOffset = d.count
            u32(0)
        }
        d.append(contentsOf: Array("data".utf8))
        let dataOffset = d.count
        u32(0)
        return (d, (4, dataOffset, factOffset))
    }

    private static func aiffHeader(rate: Int, channels: Int, bits: Int) -> (Data, (riff: Int, data: Int, fact: Int?)) {
        var d = Data()
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: x).bigEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: x).bigEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("FORM".utf8)); u32(0); d.append(contentsOf: Array("AIFF".utf8))
        d.append(contentsOf: Array("COMM".utf8)); u32(18); u16(channels)
        let framesOffset = d.count
        u32(0); u16(bits); d.append(extended80(Double(rate)))
        d.append(contentsOf: Array("SSND".utf8))
        let ssndOffset = d.count
        u32(0); u32(0); u32(0)            // size (patched), data offset, block size
        return (d, (4, ssndOffset, framesOffset))
    }

    /// IEEE 754 80-bit extended precision (the sample rate field of AIFF's COMM chunk).
    static func extended80(_ value: Double) -> Data {
        guard value > 0 else { return Data(count: 10) }
        let exponent = Int(floor(log2(value)))
        let mantissa = UInt64(value * pow(2.0, Double(63 - exponent)))
        let biased = UInt16(exponent + 16383)
        var d = Data()
        d.append(UInt8(biased >> 8)); d.append(UInt8(biased & 0xFF))
        for i in (0..<8).reversed() { d.append(UInt8(truncatingIfNeeded: mantissa >> UInt64(8 * i))) }
        return d
    }
}
