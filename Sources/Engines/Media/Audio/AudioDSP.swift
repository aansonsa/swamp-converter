import Foundation

// Small, dependency-free signal processing used by the native route: channel mixing, fades, an EBU R128 / ITU-R BS.1770-4 loudness meter,
// and the joiner (gap and crossfade). All of it works on `[[Float]]` (channels x frames) so it is easy to test with synthetic signals.

typealias AudChunk = [[Float]]

enum AudMix {
    /// Mixes `chunk` to `target` channels (1 or 2). 5.1 and 7.1 follow ITU-R BS.775 coefficients (centre and surrounds at -3 dB), scaled by the sum of the
    /// coefficients so even fully correlated full-scale channels cannot clip (the same normalisation swresample applies); the LFE is left out.
    static func apply(_ chunk: AudChunk, to target: Int) -> AudChunk {
        let n = chunk.count
        guard n > 0, n != target else { return chunk }
        let frames = chunk[0].count
        if n == 1 { return Array(repeating: chunk[0], count: target) }
        // Stereo fold-down first.
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        switch n {
        case 2:
            left = chunk[0]; right = chunk[1]
        case 6, 8:
            let k: Float = 0.70710678, scale: Float = 1 / (1 + k * (n == 8 ? 3 : 2))
            for i in 0..<frames {
                var l = chunk[0][i] + k * chunk[2][i] + k * chunk[4][i]
                var r = chunk[1][i] + k * chunk[2][i] + k * chunk[5][i]
                if n == 8 { l += k * chunk[6][i]; r += k * chunk[7][i] }
                left[i] = l * scale; right[i] = r * scale
            }
        default:
            let evens = stride(from: 0, to: n, by: 2).map { $0 }, odds = stride(from: 1, to: n, by: 2).map { $0 }
            let le = 1 / Float(max(evens.count, 1)), ro = 1 / Float(max(odds.count, 1))
            for i in 0..<frames {
                var l: Float = 0, r: Float = 0
                for c in evens { l += chunk[c][i] }
                for c in odds { r += chunk[c][i] }
                left[i] = l * le; right[i] = r * ro
            }
        }
        if target == 2 { return [left, right] }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = 0.5 * (left[i] + right[i]) }
        return [mono]
    }
}

enum AudDB {
    static func linear(_ db: Double) -> Float { Float(pow(10.0, db / 20.0)) }
    static func db(_ linear: Double) -> Double { linear > 0 ? 20 * log10(linear) : -200 }
}

/// Gain with fade-in / fade-out ramps, evaluated by output frame index so it is independent of chunking.
struct AudGainStage: Sendable {
    var gain: Float
    var fadeInFrames: Int
    var fadeOutFrames: Int
    /// Total output frames (needed for the fade-out). 0 = unknown, no fade-out.
    var totalFrames: Int

    var isIdentity: Bool { gain == 1 && fadeInFrames == 0 && fadeOutFrames == 0 }

    /// Applies the stage in place to `chunk` whose first frame has index `start` in the output.
    func apply(_ chunk: inout AudChunk, start: Int) {
        if isIdentity { return }
        let frames = chunk.first?.count ?? 0
        let fadeOutStart = fadeOutFrames > 0 && totalFrames > 0 ? max(0, totalFrames - fadeOutFrames) : Int.max
        for c in 0..<chunk.count {
            chunk[c].withUnsafeMutableBufferPointer { p in
                for i in 0..<frames {
                    var g = gain
                    let idx = start + i
                    if idx < fadeInFrames { g *= Float(idx) / Float(fadeInFrames) }
                    if idx >= fadeOutStart { g *= max(0, Float(totalFrames - idx) / Float(fadeOutFrames)) }
                    p[i] *= g
                }
            }
        }
    }
}

/// Dither for a reduction to 16 bits: noise of one least-significant bit added before the rounding (triangular: sum of two uniform values, which makes
/// the rounding error independent of the signal; rectangular: one uniform value of one bit width). The generator is seeded, so a run is reproducible.
final class AudDitherStage {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    private let triangular: Bool
    static let lsb: Float = 1.0 / 32_768

    init(mode: AudDither) { triangular = mode == .triangular }

    @inline(__always) private func uniform() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(state >> 40) / Float(1 << 24)       // 0 ..< 1
    }

    func apply(_ chunk: inout AudChunk) {
        for c in 0..<chunk.count {
            chunk[c].withUnsafeMutableBufferPointer { p in
                for i in 0..<p.count { p[i] += (triangular ? (uniform() - uniform()) : (uniform() - 0.5)) * Self.lsb }
            }
        }
    }
}

// MARK: Loudness

/// Streaming integrated-loudness meter (BS.1770-4 K-weighting, 400 ms blocks with 75 percent overlap, absolute gate -70 LUFS,
/// relative gate -10 LU) and sample-peak tracker.
final class AudLoudnessMeter {
    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private let rate: Double
    private let channels: Int
    private var shelf: [Biquad]
    private var highpass: [Biquad]
    private let weights: [Double]
    private let subBlock: Int
    private var subSum = 0.0
    private var subCount = 0
    /// Weighted mean-square power of every 100 ms sub-block.
    private var subBlocks: [Double] = []
    private(set) var samplePeak: Double = 0

    init(rate: Int, channels: Int) {
        self.rate = Double(rate)
        self.channels = channels
        subBlock = max(1, Int(Double(rate) / 10.0))
        // Stage 1: high shelf (+4 dB above ~1.7 kHz). Stage 2: RLB high-pass at 38 Hz.
        let fs = Double(rate)
        var s = Biquad(), h = Biquad()
        do {
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / fs), vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            s.b0 = (vh + vb * k / q + k * k) / a0
            s.b1 = 2 * (k * k - vh) / a0
            s.b2 = (vh - vb * k / q + k * k) / a0
            s.a1 = 2 * (k * k - 1) / a0
            s.a2 = (1 - k / q + k * k) / a0
        }
        do {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f0 / fs)
            let a0 = 1 + k / q + k * k
            h.b0 = 1; h.b1 = -2; h.b2 = 1
            h.a1 = 2 * (k * k - 1) / a0
            h.a2 = (1 - k / q + k * k) / a0
        }
        shelf = Array(repeating: s, count: channels)
        highpass = Array(repeating: h, count: channels)
        // Channel weights: surround channels count 1.41, the LFE nothing (SMPTE order L R C LFE Ls Rs ...).
        var w = Array(repeating: 1.0, count: channels)
        if channels >= 6 { w[3] = 0; w[4] = 1.41; w[5] = 1.41 }
        if channels >= 8 { w[6] = 1.41; w[7] = 1.41 }
        weights = w
    }

    func feed(_ chunk: AudChunk) {
        let frames = chunk.first?.count ?? 0
        guard frames > 0, chunk.count == channels else { return }
        for i in 0..<frames {
            var power = 0.0
            for c in 0..<channels {
                let x = Double(chunk[c][i])
                let ax = abs(x)
                if ax > samplePeak { samplePeak = ax }
                if weights[c] == 0 { continue }
                let y = highpass[c].process(shelf[c].process(x))
                power += weights[c] * y * y
            }
            subSum += power
            subCount += 1
            if subCount == subBlock {
                subBlocks.append(subSum / Double(subBlock))
                subSum = 0; subCount = 0
            }
        }
    }

    var peakDB: Double { AudDB.db(samplePeak) }

    /// Integrated loudness in LUFS, nil when the signal is shorter than one block or entirely below the absolute gate.
    var integratedLUFS: Double? {
        guard subBlocks.count >= 4 else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count)
        var window = subBlocks[0] + subBlocks[1] + subBlocks[2] + subBlocks[3]
        blocks.append(window / 4)
        if subBlocks.count > 4 {
            for i in 4..<subBlocks.count {
                window += subBlocks[i] - subBlocks[i - 4]
                blocks.append(max(0, window) / 4)
            }
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeThreshold = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let kept = absolute.filter { lufs($0) > relativeThreshold }
        guard !kept.isEmpty else { return nil }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }
}

// MARK: Joiner

/// Concatenates sources into one stream with an optional silent gap or a crossfade (equal-power) between neighbours.
/// Feed frames with `append`, call `endSource()` after each source and `finish()` at the very end; output goes to `sink`.
final class AudJoiner {
    private let channels: Int
    private let rate: Int
    private let gapFrames: Int
    private let fadeFrames: Int
    private let sink: (AudChunk) throws -> Void
    private var tail: AudChunk = []          // held back frames of the previous source (crossfade only)
    private var head: AudChunk = []          // first frames of the current source while waiting for the crossfade
    private var holding: AudChunk = []       // current source frames, newest `fadeFrames` held back
    private var sourceIndex = -1
    private var inHead = false

    init(channels: Int, rate: Int, gapSeconds: Double, crossfadeSeconds: Double, sink: @escaping (AudChunk) throws -> Void) {
        self.channels = channels; self.rate = rate
        fadeFrames = crossfadeSeconds > 0 ? Int((crossfadeSeconds * Double(rate)).rounded()) : 0
        gapFrames = fadeFrames == 0 && gapSeconds > 0 ? Int((gapSeconds * Double(rate)).rounded()) : 0
        self.sink = sink
        tail = Array(repeating: [], count: channels)
        head = tail; holding = tail
    }

    func beginSource() throws {
        sourceIndex += 1
        if sourceIndex > 0, gapFrames > 0 { try sink(Array(repeating: [Float](repeating: 0, count: gapFrames), count: channels)) }
        inHead = sourceIndex > 0 && fadeFrames > 0
        head = Array(repeating: [], count: channels)
    }

    func append(_ chunk: AudChunk) throws {
        guard chunk.count == channels, let n = chunk.first?.count, n > 0 else { return }
        if fadeFrames == 0 { try sink(chunk); return }
        var rest = chunk
        if inHead {
            let need = fadeFrames - head[0].count
            let take = min(need, n)
            for c in 0..<channels { head[c] += rest[c][0..<take] }
            for c in 0..<channels { rest[c] = Array(rest[c][take...]) }
            if head[0].count >= fadeFrames { try mixHead(); inHead = false } else { return }
            if (rest.first?.count ?? 0) == 0 { return }
        }
        for c in 0..<channels { holding[c] += rest[c] }
        let extra = holding[0].count - fadeFrames
        if extra > 0 {
            try sink(holding.map { Array($0[0..<extra]) })
            holding = holding.map { Array($0[extra...]) }
        }
    }

    /// Call when the source has no more frames.
    func endSource() throws {
        if fadeFrames == 0 { return }
        if inHead {          // the source was shorter than the crossfade: mix what exists
            if head[0].count > 0 { try mixHead() } else { try sink(tail); tail = Array(repeating: [], count: channels) }
            inHead = false
            // after mixing, the (shorter) source is fully consumed; nothing left to hold
            holding = Array(repeating: [], count: channels)
            tail = Array(repeating: [], count: channels)
            return
        }
        tail = holding
        holding = Array(repeating: [], count: channels)
    }

    func finish() throws {
        if fadeFrames > 0, (tail.first?.count ?? 0) > 0 { try sink(tail); tail = Array(repeating: [], count: channels) }
    }

    /// Equal-power mix of the held tail (fading out) with the collected head (fading in).
    private func mixHead() throws {
        let tailCount = tail[0].count, headCount = head[0].count
        let n = min(tailCount, headCount)
        if tailCount > n { try sink(tail.map { Array($0[0..<(tailCount - n)]) }) }
        var mixed = Array(repeating: [Float](repeating: 0, count: n), count: channels)
        for c in 0..<channels {
            let t = tail[c].suffix(n), h = head[c].prefix(n)
            var i = 0
            for (a, b) in zip(t, h) {
                let p = Float(i) / Float(max(n - 1, 1))
                mixed[c][i] = a * cos(p * .pi / 2) + b * sin(p * .pi / 2)
                i += 1
            }
        }
        if n > 0 { try sink(mixed) }
        // Anything of the head beyond n (head longer than the tail) is plain output.
        if headCount > n { try sink(head.map { Array($0[n...]) }) }
        tail = Array(repeating: [], count: channels)
        head = Array(repeating: [], count: channels)
    }
}
