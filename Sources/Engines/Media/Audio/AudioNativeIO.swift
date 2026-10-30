import Foundation
import AVFoundation
import AudioToolbox

// Reading, resampling and writing with the frameworks that ship in macOS (AVAudioFile / AVAudioConverter, i.e. AudioToolbox).
// Everything streams in small chunks: a 3-hour file never sits in memory.

/// One decoded input. Frames are read in chunks of at most `chunkFrames`.
final class AudNativeReader {
    static let chunkFrames = 32_768

    let file: AVAudioFile
    let rate: Int
    let channels: Int
    /// Frames of the requested range that have not been read yet.
    private(set) var remaining: Int
    /// Frames in the requested range.
    let rangeFrames: Int
    private let buffer: AVAudioPCMBuffer

    /// - Parameters: `start` / `end` in seconds of the file (end nil = to the end).
    init(url: URL, start: Double = 0, end: Double? = nil) throws {
        let f: AVAudioFile
        do { f = try AVAudioFile(forReading: url) } catch { throw ConversionError.fileUnreadable(url) }
        file = f
        let sampleRate = Int(f.processingFormat.sampleRate.rounded())
        rate = sampleRate
        channels = Int(f.processingFormat.channelCount)
        let total = Int(f.length)
        let s = min(total, max(0, Int((start * Double(sampleRate)).rounded())))
        let e = end.map { min(total, Int(($0 * Double(sampleRate)).rounded())) } ?? total
        rangeFrames = max(0, e - s)
        remaining = rangeFrames
        if s > 0 { f.framePosition = AVAudioFramePosition(s) }
        guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.chunkFrames)) else { throw ConversionError.fileUnreadable(url) }
        buffer = b
    }

    var framesRead: Int { rangeFrames - remaining }

    /// The next chunk, or nil at the end of the range.
    func next() throws -> AudChunk? {
        let n = min(Self.chunkFrames, remaining)
        guard n > 0 else { return nil }
        buffer.frameLength = 0
        try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
        let got = Int(buffer.frameLength)
        if got == 0 { remaining = 0; return nil }
        remaining -= got
        guard let data = buffer.floatChannelData else { return nil }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: got)) }
    }
}

/// Sample-rate conversion with the system's mastering-grade converter.
final class AudResampler {
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let ratio: Double
    let channels: Int

    init?(inRate: Int, outRate: Int, channels: Int) {
        guard inRate != outRate, channels > 0,
              let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(inRate), channels: AVAudioChannelCount(channels), interleaved: false),
              let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(outRate), channels: AVAudioChannelCount(channels), interleaved: false),
              let c = AVAudioConverter(from: i, to: o) else { return nil }
        c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter = c; inFormat = i; outFormat = o
        ratio = Double(outRate) / Double(inRate)
        self.channels = channels
    }

    /// Converts one chunk. Output length varies slightly from chunk to chunk (converter latency); the total is right after `flush()`.
    func process(_ chunk: AudChunk) throws -> AudChunk {
        guard let frames = chunk.first?.count, frames > 0 else { return Array(repeating: [], count: channels) }
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)),
              let data = input.floatChannelData else { throw ConversionError.noOutput }
        input.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { chunk[c].withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: frames) } }
        return try convert(input: input, final: false, capacityFrames: Int(Double(frames) * ratio) + 2048)
    }

    /// Drains the converter at the end of the stream.
    func flush() throws -> AudChunk {
        try convert(input: nil, final: true, capacityFrames: 8192)
    }

    private func convert(input: AVAudioPCMBuffer?, final: Bool, capacityFrames: Int) throws -> AudChunk {
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(capacityFrames)) else { throw ConversionError.noOutput }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if let input, !supplied { supplied = true; inputStatus.pointee = .haveData; return input }
            inputStatus.pointee = final ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error { throw ConversionError.message(L10n("The sample rate could not be converted.", "Не удалось изменить частоту дискретизации.")) }
        let n = Int(out.frameLength)
        guard n > 0, let data = out.floatChannelData else { return Array(repeating: [], count: channels) }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }
}

/// A destination for float chunks: an AVAudioFile in the plan's format, or a hand-written PCM file (WAV, AIFF, and the float32 WAV that external
/// encoders read).
final class AudNativeSink {
    private var file: AVAudioFile?
    private var pcm: AudPCMWriter?
    let url: URL
    private(set) var framesWritten = 0

    init(url: URL, settings: [String: Any], rate: Int, channels: Int) throws {
        self.url = url
        do { file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw ConversionError.message(L10n("This sound format cannot be written with these settings.", "Этот формат звука нельзя записать с такими параметрами.")) }
    }

    init(url: URL, container: AudPCMWriter.Container, rate: Int, channels: Int, bits: Int) throws {
        self.url = url
        pcm = try AudPCMWriter(url: url, container: container, rate: rate, channels: channels, bits: bits)
    }

    func write(_ chunk: AudChunk) throws {
        guard let frames = chunk.first?.count, frames > 0 else { return }
        if let pcm { try pcm.write(chunk); framesWritten += frames; return }
        guard let file else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData, chunk.count == Int(file.processingFormat.channelCount) else { throw ConversionError.noOutput }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<chunk.count { chunk[c].withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: frames) } }
        do { try file.write(from: buffer) }
        catch { throw ConversionError.message(L10n("Writing the sound failed. Check the free space and the output folder.", "Не удалось записать звук. Проверьте свободное место и папку результата.")) }
        framesWritten += frames
    }

    /// Flushes and closes the file (an AVAudioFile writes its trailer when it goes away; the PCM writer patches its sizes).
    func close() throws {
        file = nil
        try pcm?.close()
        pcm = nil
    }
}

/// Encoder settings for the targets macOS writes itself.
enum AudNativeSettings {
    static func floatWAV(rate: Int, channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(rate), AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    static func settings(plan: AudPlan, rate: Int, channels: Int, info: AudInfo?) -> [String: Any] {
        var s: [String: Any] = [AVSampleRateKey: Double(rate), AVNumberOfChannelsKey: channels]
        let depth = AudFFmpegArgs.resolvedDepth(plan.bitDepth, info)
        switch plan.target {
        case .aac, .m4b, .m4r:
            switch (plan.aacProfile, channels) {
            case (.hev2, 2): s[AVFormatIDKey] = kAudioFormatMPEG4AAC_HE_V2
            case (.he, _), (.hev2, _): s[AVFormatIDKey] = kAudioFormatMPEG4AAC_HE
            default: s[AVFormatIDKey] = kAudioFormatMPEG4AAC
            }
            if plan.useQuality {
                s[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Variable
                s[AVEncoderAudioQualityForVBRKey] = AudQuality.aacNativeVBR(plan.quality)
            } else {
                let kbps = nearestAACBitrate(requested: plan.kbps, rate: rate, channels: channels, profile: plan.aacProfile)
                s[AVEncoderBitRateKey] = kbps * 1000
                s[AVEncoderBitRateStrategyKey] = plan.fitBytes != nil ? AVAudioBitRateStrategy_LongTermAverage : AVAudioBitRateStrategy_Constant
            }
        case .alac:
            s[AVFormatIDKey] = kAudioFormatAppleLossless
            s[AVEncoderBitDepthHintKey] = depth >= 24 ? 24 : 16
        case .flac:
            s[AVFormatIDKey] = kAudioFormatFLAC
        case .wav, .caf:
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = depth; s[AVLinearPCMIsFloatKey] = depth == 32
            s[AVLinearPCMIsBigEndianKey] = false; s[AVLinearPCMIsNonInterleaved] = false
        case .aiff:
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = depth >= 24 ? 24 : 16; s[AVLinearPCMIsFloatKey] = false
            s[AVLinearPCMIsBigEndianKey] = true; s[AVLinearPCMIsNonInterleaved] = false
        default:
            s = floatWAV(rate: rate, channels: channels)
        }
        return s
    }

    /// The AAC encoder only accepts certain total bit rates for a given rate and channel count (8 kHz mono tops out low, 96 kHz stereo has a floor).
    /// Returns the accepted value nearest to `requested`; `requested` itself when the system cannot tell.
    static func nearestAACBitrate(requested: Int, rate: Int, channels: Int, profile: AudAACProfile) -> Int {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: AVAudioChannelCount(channels), interleaved: false) else { return requested }
        let id: AudioFormatID = profile == .lc ? kAudioFormatMPEG4AAC : (profile == .he || channels != 2 ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC_HE_V2)
        guard let out = AVAudioFormat(settings: [AVFormatIDKey: id, AVSampleRateKey: Double(rate), AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: inFormat, to: out) else { return requested }
        let rates = converter.applicableEncodeBitRates?.map { $0.intValue / 1000 }.filter { $0 > 0 } ?? []
        guard !rates.isEmpty else { return requested }
        return rates.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? requested
    }
}
