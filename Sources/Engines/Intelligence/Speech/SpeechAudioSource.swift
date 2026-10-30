import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Pulls decoded speech audio out of any audio or video file, one buffer at a time, in the format the recogniser asks for.
/// AVFoundation reads mp4 / mov / m4a / mp3 / wav / aiff / caf / flac directly (and resamples + down-mixes in the reader); other containers (mkv, webm, ogg, opus,
/// wma ...) go through a temporary 16 kHz mono WAV made by ffmpeg when it is installed. Nothing is written next to the user's files.
final class SpeechAudioSource: @unchecked Sendable {
    let duration: Double
    let format: AVAudioFormat
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let lock = NSLock()
    private var position: Double = 0

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, duration: Double, format: AVAudioFormat) {
        self.reader = reader; self.output = output; self.duration = duration; self.format = format
    }

    /// Seconds of audio handed out so far (drives the progress bar).
    var consumed: Double { lock.lock(); defer { lock.unlock() }; return position }

    func cancel() { reader.cancelReading() }

    // MARK: Opening

    static func open(_ url: URL, format: AVAudioFormat, ctx: OperationContext) async throws -> SpeechAudioSource {
        if let s = try await openAsset(url, format: format) { return s }
        // AVFoundation cannot read this container: try ffmpeg.
        guard ctx.tools.has(.ffmpeg) else {
            throw ConversionError.message(L10n("This file format cannot be read without ffmpeg. \(Tool.ffmpeg.installHint.en)", "Этот формат нельзя прочитать без ffmpeg. \(Tool.ffmpeg.installHint.ru)"))
        }
        let wav = ctx.tempDir.appendingPathComponent("speech-\(Util.hex8()).wav")
        try await ctx.runTool(.ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", url.path, "-vn", "-sn", "-dn", "-map", "0:a:0?", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path])
        guard FileManager.default.fileExists(atPath: wav.path), let s = try await openAsset(wav, format: format) else { throw ConversionError.noAudioTrack }
        return s
    }

    /// nil when AVFoundation cannot read the file or the file has no audio track at all (the caller decides between "try ffmpeg" and "no audio").
    private static func openAsset(_ url: URL, format: AVAudioFormat) async throws -> SpeechAudioSource? {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable,
              let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first else { return nil }
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let reader = try AVAssetReader(asset: asset)
        let isInt16 = format.commonFormat == .pcmFormatInt16
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: Int(max(format.channelCount, 1)),
            AVLinearPCMBitDepthKey: isInt16 ? 16 : 32, AVLinearPCMIsFloatKey: !isInt16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ConversionError.fileUnreadable(url) }
        return SpeechAudioSource(reader: reader, output: out, duration: seconds.isFinite ? seconds : 0, format: format)
    }

    // MARK: Reading

    /// The next chunk (a fraction of a second to a few seconds of audio) with its time in the file, or nil at the end.
    func next() throws -> AnalyzerInput? {
        while true {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed, let e = reader.error { throw e }
                return nil
            }
            guard CMSampleBufferIsValid(sample), CMSampleBufferGetNumSamples(sample) > 0,
                  let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            var streamDescription = asbd.pointee
            guard let bufferFormat = AVAudioFormat(streamDescription: &streamDescription),
                  let buffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            lock.lock(); position = max(position, start.seconds + Double(frames) / bufferFormat.sampleRate); lock.unlock()
            return AnalyzerInput(buffer: buffer, bufferStartTime: start)
        }
    }
}

/// Pull-based sequence: the recogniser asks for the next chunk when it is ready, so a two-hour video never sits in memory.
struct SpeechAudioSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let source: SpeechAudioSource
    let onProgress: @Sendable (Double) -> Void

    func makeAsyncIterator() -> Iterator { Iterator(source: source, onProgress: onProgress) }

    struct Iterator: AsyncIteratorProtocol {
        let source: SpeechAudioSource
        let onProgress: @Sendable (Double) -> Void
        mutating func next() async throws -> AnalyzerInput? {
            try Task.checkCancellation()
            guard let input = try source.next() else { return nil }
            if source.duration > 0 { onProgress(Swift.min(source.consumed / source.duration, 1)) }
            return input
        }
    }
}
