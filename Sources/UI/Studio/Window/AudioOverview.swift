import Foundation
import AVFoundation

// The audio preview: a waveform (peak per bucket) and the loudness of the file (ITU-R BS.1770-4 integrated loudness with the two gates, plus the sample peak).
// The maths is pure and streaming (`LoudnessMeter`, `WaveformAccumulator`); the loader feeds it from AVAssetReader, or from ffmpeg for formats macOS cannot decode.
// Decoding runs at utility priority off the main thread, reads in chunks (a 3 hour file is never in memory) and stops within one chunk of a cancellation.

/// Integrated loudness, streaming. Input: interleaved Float samples at 48 kHz, one or two channels (channel weights are 1, as for front channels).
struct LoudnessMeter {
    static let sampleRate = 48_000

    private struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    // BS.1770-4 K-weighting at 48 kHz: a high-shelf pre-filter and the RLB high-pass.
    private static func shelf() -> Biquad { Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585) }
    private static func highPass() -> Biquad { Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621) }

    let channels: Int
    private var shelves: [Biquad]
    private var highs: [Biquad]
    private var hopSum = 0.0
    private var hopFrames = 0
    private var recentHops: [Double] = []
    /// Mean-square power of every 400 ms block (100 ms hop), summed over channels.
    private(set) var blockPowers: [Double] = []
    private(set) var samplePeak: Float = 0
    private(set) var frames = 0
    private static let hopLength = 4_800

    init(channels: Int) {
        self.channels = max(1, min(channels, 2))
        shelves = Array(repeating: Self.shelf(), count: self.channels)
        highs = Array(repeating: Self.highPass(), count: self.channels)
    }

    mutating func feed(_ samples: UnsafeBufferPointer<Float>) {
        let n = samples.count / channels
        var i = 0
        while i < n {
            var energy = 0.0
            for c in 0..<channels {
                let x = samples[i * channels + c]
                let ax = abs(x)
                if ax > samplePeak { samplePeak = ax }
                let y = highs[c].process(shelves[c].process(Double(x)))
                energy += y * y
            }
            hopSum += energy
            hopFrames += 1
            if hopFrames == Self.hopLength {
                recentHops.append(hopSum)
                if recentHops.count > 4 { recentHops.removeFirst() }
                if recentHops.count == 4 { blockPowers.append(recentHops.reduce(0, +) / Double(4 * Self.hopLength)) }
                hopSum = 0; hopFrames = 0
            }
            i += 1
        }
        frames += n
    }

    mutating func feed(_ samples: [Float]) { samples.withUnsafeBufferPointer { feed($0) } }

    static func lufs(power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }

    /// LUFS with the absolute gate at -70 and the relative gate 10 LU below the gated mean. nil for silence or less than one block.
    func integratedLUFS() -> Double? {
        let absolute = blockPowers.filter { Self.lufs(power: $0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeThreshold = Self.lufs(power: absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { Self.lufs(power: $0) > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        return Self.lufs(power: gated.reduce(0, +) / Double(gated.count))
    }

    /// Sample peak in dBFS (-inf for digital silence).
    var samplePeakDB: Double { samplePeak > 0 ? 20 * log10(Double(samplePeak)) : -.infinity }
}

/// Peak per bucket for the waveform.
struct WaveformAccumulator {
    let buckets: Int
    let totalFrames: Int
    private(set) var peaks: [Float]
    private var frameIndex = 0

    init(buckets: Int, totalFrames: Int) {
        self.buckets = max(1, buckets)
        self.totalFrames = max(1, totalFrames)
        peaks = Array(repeating: 0, count: self.buckets)
    }

    mutating func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let ch = max(1, channels)
        let n = samples.count / ch
        for i in 0..<n {
            var p: Float = 0
            for c in 0..<ch { p = max(p, abs(samples[i * ch + c])) }
            let b = min(buckets - 1, Int(Double(frameIndex) / Double(totalFrames) * Double(buckets)))
            if p > peaks[b] { peaks[b] = p }
            frameIndex += 1
        }
    }
}

struct AudioOverview: Equatable, Sendable {
    var peaks: [Float]
    var integratedLUFS: Double?
    var samplePeakDB: Double
    var channels: Int
}

enum AudioOverviewLoader {
    static let buckets = 480

    /// nil when the file has no decodable audio. Cancel the calling task to stop.
    static func load(url: URL, duration: Double?, channels hint: Int?) async -> AudioOverview? {
        let work = Task.detached(priority: .utility) { () -> AudioOverview? in
            if let native = await native(url: url, duration: duration, hint: hint) { return native }
            return await viaFFmpeg(url: url, duration: duration, hint: hint)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    // MARK: AVFoundation

    private static func native(url: URL, duration: Double?, hint: Int?) async -> AudioOverview? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true, let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        var sourceChannels = hint ?? 2
        if let desc = (try? await track.load(.formatDescriptions))?.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) { sourceChannels = Int(asbd.pointee.mChannelsPerFrame) }
        let channels = max(1, min(sourceChannels, 2))
        var seconds = duration ?? 0
        if duration == nil, let d = (try? await asset.load(.duration))?.seconds, d.isFinite { seconds = d }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: LoudnessMeter.sampleRate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var meter = LoudnessMeter(channels: channels)
        var wave = WaveformAccumulator(buckets: buckets, totalFrames: Int(max(seconds, 0.1) * Double(LoudnessMeter.sampleRate)))
        while let sb = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr, let base = ptr else { continue }
            base.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                let buf = UnsafeBufferPointer(start: p, count: length / 4)
                meter.feed(buf); wave.feed(buf, channels: channels)
            }
        }
        guard meter.frames > 0 else { return nil }
        return AudioOverview(peaks: wave.peaks, integratedLUFS: meter.integratedLUFS(), samplePeakDB: meter.samplePeakDB, channels: channels)
    }

    // MARK: ffmpeg (ogg, opus, wma, mkv audio ...)

    private static func viaFFmpeg(url: URL, duration: Double?, hint: Int?) async -> AudioOverview? {
        guard let ffmpeg = ToolLocator.shared.url(.ffmpeg), let seconds = duration, seconds > 0 else { return nil }
        let channels = max(1, min(hint ?? 2, 2))
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-v", "error", "-nostdin", "-i", url.path, "-vn", "-ac", String(channels), "-ar", String(LoudnessMeter.sampleRate), "-f", "f32le", "pipe:1"]
        ProcessSandbox.apply(to: p)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.qualityOfService = .utility
        do { try p.run() } catch { return nil }
        var meter = LoudnessMeter(channels: channels)
        var wave = WaveformAccumulator(buckets: buckets, totalFrames: Int(seconds * Double(LoudnessMeter.sampleRate)))
        var carry = Data()
        let frameBytes = 4 * channels
        let handle = pipe.fileHandleForReading
        while true {
            if Task.isCancelled { p.terminate(); return nil }
            let chunk = handle.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            carry.append(chunk)
            let usable = carry.count / frameBytes * frameBytes
            if usable == 0 { continue }
            let part = carry.prefix(usable)
            part.withUnsafeBytes { raw in
                let buf = raw.bindMemory(to: Float.self)
                meter.feed(buf); wave.feed(buf, channels: channels)
            }
            carry.removeFirst(usable)
        }
        p.waitUntilExit()
        guard meter.frames > 0 else { return nil }
        return AudioOverview(peaks: wave.peaks, integratedLUFS: meter.integratedLUFS(), samplePeakDB: meter.samplePeakDB, channels: channels)
    }
}
