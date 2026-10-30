import Foundation
import AVFoundation
import CoreMedia

// Video read-back for the conformance checks: does AVFoundation really play it (an AVAssetReader that really delivers frames), and how close
// is it to the source (SSIM and PSNR measured by ffmpeg's own filters on aligned frames)?

struct PlaybackReport: Sendable {
    var isPlayable = false
    var duration: Double = 0
    var videoTrackCount = 0
    var audioTrackCount = 0
    var videoFrames = 0
    var audioFrames = 0
    var size: CGSize = .zero
    var fps: Double = 0
    /// Four-character code of the first video sample entry ("avc1", "hvc1", "mp4v" ...) and of the first audio one ("mp4a", "lpcm").
    var videoFourCC = ""
    var audioFourCC = ""
    var readError: String?

    var summary: String {
        "playable=\(isPlayable) \(Int(size.width))x\(Int(size.height)) \(String(format: "%.2f", duration)) s video \(videoFourCC) frames=\(videoFrames) audio \(audioFourCC) frames=\(audioFrames)"
    }
}

enum VideoFidelity {
    // MARK: AVFoundation

    /// Opens `url` the way QuickTime would and decodes up to `maxVideoFrames` frames and all audio samples.
    static func playback(of url: URL, maxVideoFrames: Int = 120) async -> PlaybackReport {
        var report = PlaybackReport()
        let asset = AVURLAsset(url: url)
        do {
            report.isPlayable = try await asset.load(.isPlayable)
            report.duration = (try await asset.load(.duration)).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            report.videoTrackCount = videoTracks.count
            report.audioTrackCount = audioTracks.count
            if let v = videoTracks.first {
                report.size = try await v.load(.naturalSize)
                report.fps = Double(try await v.load(.nominalFrameRate))
                if let d = (try await v.load(.formatDescriptions)).first { report.videoFourCC = fourCC(CMFormatDescriptionGetMediaSubType(d)) }
            }
            if let a = audioTracks.first, let d = (try await a.load(.formatDescriptions)).first { report.audioFourCC = fourCC(CMFormatDescriptionGetMediaSubType(d)) }
            guard let reader = try? AVAssetReader(asset: asset) else { report.readError = "AVAssetReader cannot open the file"; return report }
            var vOut: AVAssetReaderTrackOutput?, aOut: AVAssetReaderTrackOutput?
            if let v = videoTracks.first {
                vOut = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                if let o = vOut, reader.canAdd(o) { reader.add(o) }
            }
            if let a = audioTracks.first {
                aOut = AVAssetReaderTrackOutput(track: a, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                                                           AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
                if let o = aOut, reader.canAdd(o) { reader.add(o) }
            }
            guard reader.startReading() else { report.readError = reader.error?.localizedDescription ?? "startReading failed"; return report }
            if let o = vOut {
                while report.videoFrames < maxVideoFrames, let sb = o.copyNextSampleBuffer() {
                    if CMSampleBufferGetImageBuffer(sb) != nil { report.videoFrames += 1 }
                }
            }
            if let o = aOut {
                while let sb = o.copyNextSampleBuffer() { report.audioFrames += CMSampleBufferGetNumSamples(sb) }
            }
            if reader.status == .failed { report.readError = reader.error?.localizedDescription }
        } catch {
            report.readError = error.localizedDescription
        }
        return report
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "?" })
    }

    // MARK: ffmpeg metrics

    struct Similarity: Sendable {
        var ssim: Double
        var psnr: Double
        var summary: String { String(format: "SSIM %.4f, PSNR %.1f dB", ssim, psnr) }
    }

    /// SSIM (All) and average PSNR of `test` against `reference`, both scaled to `size` and, when given, resampled to `fps` so frames line up.
    /// `referenceFilter` is an ffmpeg filter chain applied to the reference before comparing ("transpose=1" to judge a rotation, "setpts=0.5*PTS" a speed-up,
    /// "trim=start=1:end=2.5,setpts=PTS-STARTPTS" a cut); `size` is the size both sides are compared at (default: the test file's own size).
    static func similarity(reference: URL, test: URL, size: (width: Int, height: Int)? = nil, fps: Double? = nil, referenceFilter: String? = nil, timeout: TimeInterval = 300) -> Similarity? {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let testInfo = ExternalProbe.ffprobe(test)
        guard let w = size?.width ?? testInfo?.video.first?.width, let h = size?.height ?? testInfo?.video.first?.height else { return nil }
        let rate = fps.map { ",fps=\($0)" } ?? ""
        let pre = referenceFilter.map { $0 + "," } ?? ""
        func graph(_ metric: String) -> String {
            "[0:v:0]scale=\(w):\(h):flags=bicubic\(rate),setpts=PTS-STARTPTS[t];[1:v:0]\(pre)scale=\(w):\(h):flags=bicubic\(rate),setpts=PTS-STARTPTS[r];[t][r]\(metric)"
        }
        func run(_ metric: String) -> String {
            let r = ExternalProbe.run(ffmpeg, ["-hide_banner", "-nostdin", "-an", "-sn", "-i", test.path, "-i", reference.path, "-lavfi", graph(metric), "-f", "null", "-"], timeout: timeout)
            return r.error + r.output
        }
        let ssimText = run("ssim"), psnrText = run("psnr")
        guard let s = number(after: "All:", in: ssimText), let p = number(after: "average:", in: psnrText) else { return nil }
        return Similarity(ssim: s, psnr: p)
    }

    private static func number(after marker: String, in text: String) -> Double? {
        // Last occurrence: ffmpeg prints the summary at the end of the run.
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let tail = text[range.upperBound...].prefix(24)
        let digits = tail.prefix { "0123456789.-infINF".contains($0) }
        return Double(digits.lowercased() == "inf" ? "inf" : String(digits))
    }

    /// Decoded pictures at the given times (exact frames: zero tolerance), as RGB rasters. Frames AVFoundation cannot deliver are left out.
    static func frames(of url: URL, at times: [Double]) async -> [RasterImage] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var out: [RasterImage] = []
        for t in times {
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)), let r = ImageFidelity.raster(cg) { out.append(r) }
        }
        return out
    }

    /// MD5 of the (copied) elementary video stream: equal values prove a lossless stream copy.
    static func videoStreamMD5(_ url: URL) -> String? {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "md5", "-"], timeout: 120)
        guard r.status == 0, let line = r.output.split(separator: "\n").first(where: { $0.hasPrefix("MD5=") }) else { return nil }
        return String(line.dropFirst(4))
    }

    /// Decoded frame count of the first video stream (decodes everything: small fixtures only).
    static func frameCount(_ url: URL) -> Int? {
        ExternalProbe.ffprobe(url, countFrames: true)?.video.first?.frames
    }

    /// Whole-stream decode with errors enabled: ffmpeg must read the file to its end without a single complaint.
    static func decodesCleanly(_ url: URL, timeout: TimeInterval = 300) -> (ok: Bool, message: String) {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return (true, "ffmpeg missing, not checked") }
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-f", "null", "-"], timeout: timeout)
        let msg = (r.error + r.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0 && msg.isEmpty, msg.isEmpty ? "decoded to the end" : String(msg.prefix(400)))
    }
}

enum Mp4Layout {
    /// Top-level box types in file order ("ftyp", "moov", "mdat", ...).
    static func topLevelBoxes(_ url: URL) -> [String] {
        guard let r = ByteReader(url: url) else { return [] }
        var pos: UInt64 = 0
        var out: [String] = []
        while pos + 8 <= r.size, out.count < 64 {
            guard let size32 = r.u32be(at: pos) else { break }
            out.append(String(decoding: r.read(at: pos + 4, 4), as: UTF8.self))
            var size = UInt64(size32)
            if size32 == 1 { size = r.u64be(at: pos + 8) ?? 0 } else if size32 == 0 { size = r.size - pos }
            guard size >= 8 else { break }
            pos += size
        }
        return out
    }

    /// True when the index (`moov`) comes before the media data (`mdat`): the file starts playing before it has fully loaded ("fast start").
    static func isFastStart(_ url: URL) -> Bool {
        let boxes = topLevelBoxes(url)
        guard let m = boxes.firstIndex(of: "moov"), let d = boxes.firstIndex(of: "mdat") else { return false }
        return m < d
    }
}
