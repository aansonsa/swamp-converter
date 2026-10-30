import Foundation
import AVFoundation
import Accelerate

// Sample-level comparison of audio for the conformance checks: decode both files to float PCM (AVAudioFile first, ffmpeg for the formats CoreAudio
// does not read), align them (codecs add a priming delay), then measure SNR and correlation, or demand a bit-exact match for lossless pairs.

struct AudioSamples: @unchecked Sendable {
    var sampleRate: Double
    /// One float array per channel (planar), -1...1.
    var channels: [[Float]]
    /// Which decoder produced it ("AVAudioFile" or "ffmpeg").
    var decoder: String

    var frames: Int { channels.first?.count ?? 0 }
    var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    var channelCount: Int { channels.count }

    /// Mono mix used for alignment and level measurements.
    var mono: [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var out = first
        for c in channels.dropFirst() { vDSP.add(out, c, result: &out) }
        vDSP.divide(out, Float(channels.count), result: &out)
        return out
    }

    /// RMS level in dB full scale.
    var rmsDB: Double {
        let m = mono
        guard !m.isEmpty else { return -200 }
        let rms = Double(vDSP.rootMeanSquare(m))
        return rms > 0 ? 20 * log10(rms) : -200
    }

    /// 16-bit quantisation of one channel (what a 16-bit WAV, AIFF or FLAC stores).
    func int16(_ channel: Int) -> [Int16] { channels[channel].map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) } }
}

enum AudioFidelity {
    // MARK: Decoding

    static func decode(_ url: URL) -> AudioSamples? {
        // CoreAudio's own Vorbis decoder reads some valid streams wrongly (a mono 22.05 kHz file correlates at 0.15 there and 0.9999 in ffmpeg), so Ogg goes to ffmpeg first.
        if ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased()), ExternalProbe.has(.ffmpeg), let s = decodeWithFFmpeg(url) { return s }
        if let s = decodeWithAVAudioFile(url) { return s }
        return decodeWithFFmpeg(url)
    }

    static func decodeWithAVAudioFile(_ url: URL) -> AudioSamples? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0, file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }
        var planes = [[Float]](repeating: [], count: channelCount)
        for i in 0..<channelCount { planes[i].reserveCapacity(Int(file.length)) }
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: 65_536) } catch { return nil }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            for c in 0..<channelCount { planes[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n)) }
        }
        return AudioSamples(sampleRate: format.sampleRate, channels: planes, decoder: "AVAudioFile")
    }

    static func decodeWithFFmpeg(_ url: URL) -> AudioSamples? {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg), let info = ExternalProbe.ffprobe(url), let a = info.audio.first,
              let rate = a.sampleRate, let ch = a.channels, ch > 0 else { return nil }
        let tmp = AppPaths.makeTempDirectory(purpose: "aud").appendingPathComponent("decoded.f32")
        defer { AppPaths.removeTemp(tmp.deletingLastPathComponent()) }
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", url.path, "-map", "0:a:0", "-f", "f32le", "-acodec", "pcm_f32le", tmp.path], timeout: 180)
        guard r.status == 0, let data = try? Data(contentsOf: tmp, options: .mappedIfSafe), data.count >= ch * 4 else { return nil }
        let total = data.count / 4
        let frames = total / ch
        var planes = [[Float]](repeating: [Float](repeating: 0, count: frames), count: ch)
        data.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<frames { for c in 0..<ch { planes[c][i] = f[i * ch + c] } }
        }
        return AudioSamples(sampleRate: Double(rate), channels: planes, decoder: "ffmpeg")
    }

    // MARK: Resampling

    /// Converts to another sample rate with CoreAudio's mastering-grade converter (for formats that force a rate, such as Opus at 48 kHz).
    static func resampled(_ s: AudioSamples, to rate: Double) -> AudioSamples? {
        if abs(s.sampleRate - rate) < 0.5 { return s }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: s.sampleRate, channels: AVAudioChannelCount(s.channelCount), interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(s.channelCount), interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(s.frames)) else { return nil }
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(s.frames)
        for c in 0..<s.channelCount { s.channels[c].withUnsafeBufferPointer { input.floatChannelData![c].update(from: $0.baseAddress!, count: s.frames) } }
        let outCapacity = AVAudioFrameCount(Double(s.frames) * rate / s.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = conv.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .endOfStream; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let data = output.floatChannelData else { return nil }
        let n = Int(output.frameLength)
        let planes = (0..<s.channelCount).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return AudioSamples(sampleRate: rate, channels: planes, decoder: s.decoder + "+SRC")
    }

    // MARK: Comparison

    /// Sample-for-sample equality of the 16-bit quantised signals (lossless round trips). Returns the index of the first difference.
    static func bitExact(_ a: AudioSamples, _ b: AudioSamples) -> (equal: Bool, detail: String) {
        guard a.channelCount == b.channelCount else { return (false, "channels \(a.channelCount) vs \(b.channelCount)") }
        guard a.frames == b.frames else { return (false, "frames \(a.frames) vs \(b.frames)") }
        for c in 0..<a.channelCount {
            let x = a.int16(c), y = b.int16(c)
            if x != y, let i = (0..<x.count).first(where: { x[$0] != y[$0] }) { return (false, "channel \(c) differs first at frame \(i): \(x[i]) vs \(y[i])") }
        }
        return (true, "\(a.frames) frames equal")
    }

    /// Delay (in frames of `test`) that best aligns `test` to `ref`: `test[i + lag] ~ ref[i]`. Searches +-`maxLag` frames.
    static func bestLag(ref: AudioSamples, test: AudioSamples, maxLag: Int = 6000) -> Int {
        let r = decimate(ref.mono, 4), t = decimate(test.mono, 4)
        let window = min(r.count, t.count, 44_100 * 6 / 4)
        guard window > 2000 else { return 0 }
        let start = min(max(0, r.count / 4), max(0, r.count - window))
        func score(_ lag: Int) -> Float {
            let a0 = start, b0 = start + lag
            guard b0 >= 0, b0 + window <= t.count, a0 + window <= r.count else { return -.infinity }
            var d: Float = 0
            r.withUnsafeBufferPointer { pr in t.withUnsafeBufferPointer { pt in vDSP_dotpr(pr.baseAddress! + a0, 1, pt.baseAddress! + b0, 1, &d, vDSP_Length(window)) } }
            return d
        }
        var best = 0, bestScore = -Float.infinity
        for lag in stride(from: -maxLag / 4, through: maxLag / 4, by: 1) { let s = score(lag); if s > bestScore { bestScore = s; best = lag } }
        // Refine on the full-rate mono signals around 4 * best.
        let fr = ref.mono, ft = test.mono
        let fwindow = min(fr.count, ft.count, 44_100 * 4)
        let fstart = min(max(0, fr.count / 4), max(0, fr.count - fwindow))
        var fbest = best * 4, fbestScore = -Float.infinity
        for lag in (best * 4 - 6)...(best * 4 + 6) {
            let b0 = fstart + lag
            guard b0 >= 0, b0 + fwindow <= ft.count else { continue }
            var d: Float = 0
            fr.withUnsafeBufferPointer { pr in ft.withUnsafeBufferPointer { pt in vDSP_dotpr(pr.baseAddress! + fstart, 1, pt.baseAddress! + b0, 1, &d, vDSP_Length(fwindow)) } }
            if d > fbestScore { fbestScore = d; fbest = lag }
        }
        return fbest
    }

    private static func decimate(_ x: [Float], _ k: Int) -> [Float] {
        guard x.count >= k else { return x }
        var out = [Float](repeating: 0, count: x.count / k)
        for i in 0..<out.count { var s: Float = 0; for j in 0..<k { s += x[i * k + j] }; out[i] = s / Float(k) }
        return out
    }

    struct Match {
        var lag: Int
        var snr: Double
        var correlation: Double
        var comparedFrames: Int
        var summary: String { String(format: "SNR %.1f dB, correlation %.4f, lag %d frames", snr, correlation, lag) }
    }

    /// Aligned SNR and correlation of `test` against `ref` (same rate and channel count required; resample first when they differ).
    /// The first and last `trim` frames are ignored (codec priming and padding).
    static func match(ref: AudioSamples, test: AudioSamples, trim: Int = 2048) -> Match? {
        guard abs(ref.sampleRate - test.sampleRate) < 0.5, ref.channelCount == test.channelCount, ref.frames > 4 * trim, test.frames > 4 * trim else { return nil }
        let lag = bestLag(ref: ref, test: test)
        var signal = 0.0, noise = 0.0, cross = 0.0, energyT = 0.0
        var compared = 0
        for c in 0..<ref.channelCount {
            let r = ref.channels[c], t = test.channels[c]
            let lo = max(trim, -lag + trim), hi = min(r.count - trim, t.count - lag - trim)
            guard hi > lo else { return nil }
            let n = hi - lo
            compared += n
            var diff = [Float](repeating: 0, count: n)
            r.withUnsafeBufferPointer { pr in t.withUnsafeBufferPointer { pt in
                vDSP_vsub(pt.baseAddress! + lo + lag, 1, pr.baseAddress! + lo, 1, &diff, 1, vDSP_Length(n))
                var s: Float = 0, e: Float = 0, x: Float = 0, d: Float = 0
                vDSP_svesq(pr.baseAddress! + lo, 1, &s, vDSP_Length(n))
                vDSP_svesq(pt.baseAddress! + lo + lag, 1, &e, vDSP_Length(n))
                vDSP_dotpr(pr.baseAddress! + lo, 1, pt.baseAddress! + lo + lag, 1, &x, vDSP_Length(n))
                vDSP_svesq(diff, 1, &d, vDSP_Length(n))
                signal += Double(s); energyT += Double(e); cross += Double(x); noise += Double(d)
            } }
        }
        guard signal > 0, energyT > 0 else { return nil }
        let snr = noise == 0 ? Double.infinity : 10 * log10(signal / noise)
        return Match(lag: lag, snr: snr, correlation: cross / (signal * energyT).squareRoot(), comparedFrames: compared)
    }

    /// Peak sample magnitude (clipping check).
    static func peak(_ s: AudioSamples) -> Float { s.channels.map { vDSP.maximumMagnitude($0) }.max() ?? 0 }
}
