import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import CoreMedia

// A moving test video with sound, written with AVFoundation only (H.264 + AAC), so the fixture exists on a Mac without ffmpeg.
// The picture changes in every frame (drifting gradient, shapes crossing the frame, a spoke turning, a frame counter, film grain), which makes SSIM / PSNR
// and frame-count checks meaningful. Other containers and codecs are derived from it with ffmpeg when it is installed.

extension ConformanceFixtures {
    struct VideoSpec {
        var seconds: Double = 3
        var size = CGSize(width: 640, height: 360)
        var fps = 25
        var audio = true
        var bitrate = 3_000_000
    }

    @discardableResult
    func movingVideo(_ name: String = "clip.mp4", _ spec: VideoSpec = VideoSpec()) async throws -> URL {
        let u = url(name)
        let type: AVFileType = name.lowercased().hasSuffix(".mov") ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: u, fileType: type)
        let w = Int(spec.size.width), h = Int(spec.size.height)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: spec.bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoMaxKeyFrameIntervalKey: spec.fps * 2, AVVideoExpectedSourceFrameRateKey: spec.fps]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(vInput) else { throw TestFailure(message: "AVAssetWriter cannot add the video input", file: #fileID, line: #line) }
        writer.add(vInput)
        var aInput: AVAssetWriterInput?
        let rate = 44_100
        let pcm = spec.audio ? chirpSamples(seconds: spec.seconds, rate: rate, channels: 2) : []
        if spec.audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: rate, AVEncoderBitRateKey: 160_000])
            guard writer.canAdd(a) else { throw TestFixtures.fail("AVAssetWriter cannot add the audio input") }
            writer.add(a); aInput = a
        }
        guard writer.startWriting() else { throw writer.error ?? TestFixtures.fail("AVAssetWriter failed to start") }
        writer.startSession(atSourceTime: .zero)
        let grain = Self.grainTile()
        let frames = max(1, Int(spec.seconds * Double(spec.fps)))
        var audioFrame = 0
        var audioClosed = false
        let totalAudio = pcm.count / 2
        // The writer interleaves audio and video by time stamp and stops accepting one kind when the other lags: keep the sound about a second ahead of the picture.
        func feedAudio(upTo target: Int) async throws {
            guard let a = aInput else { return }
            while audioFrame < min(target, totalAudio) {
                var waited = 0
                while !a.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                    waited += 1
                    if waited > 3000 || writer.status == .failed { return }   // video side must make progress; the writer is waiting for video
                }
                let end = min(totalAudio, audioFrame + 4410)
                if let sb = Self.pcmBuffer(Array(pcm[(audioFrame * 2)..<(end * 2)]), channels: 2, rate: Double(rate), startFrame: Int64(audioFrame)) { a.append(sb) }
                audioFrame = end
            }
            // Once the last sample is in, the audio input must be closed: a writer waits for more sound before it takes more picture.
            if audioFrame >= totalAudio, !audioClosed { a.markAsFinished(); audioClosed = true }
        }
        for f in 0..<frames {
            try await feedAudio(upTo: Int((Double(f) / Double(spec.fps) + 1.0) * Double(rate)))
            var waited = 0
            while !vInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                waited += 1
                if waited > 20_000 || writer.status == .failed { throw writer.error ?? TestFixtures.fail("the video writer stalled at frame \(f)") }
            }
            guard let pool = adaptor.pixelBufferPool else { throw TestFixtures.fail("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { throw TestFixtures.fail("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf),
               let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                Self.drawFrame(ctx, index: f, fps: spec.fps, width: w, height: h, grain: grain)
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(spec.fps)))
        }
        try await feedAudio(upTo: totalAudio)
        vInput.markAsFinished()
        if !audioClosed { aInput?.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? TestFixtures.fail("AVAssetWriter did not complete") }
        return u
    }

    /// The same clip re-encoded by ffmpeg into another container / codec (avi, mkv, webm, flv, mpg, ts ...). Nil without ffmpeg or when the encode fails.
    func videoVariant(of source: URL, ext: String, args: [String]? = nil) -> URL? {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let out = url(source.deletingPathExtension().lastPathComponent + "." + ext)
        let defaults: [String: [String]] = [
            "mkv": ["-c", "copy"], "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"],
            "webm": ["-c:v", "libvpx-vp9", "-crf", "34", "-b:v", "0", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus", "-b:a", "96k"],
            "flv": ["-c:v", "flv", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "4"], "mpg": ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2"],
            "mov": ["-c", "copy"], "ts": ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"], "3gp": ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-ar", "44100"],
            "wmv": ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2"], "mp4": ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-c:a", "aac"]]
        guard let a = args ?? defaults[ext] else { return nil }
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", source.path] + a + [out.path], timeout: 180)
        return r.status == 0 ? out : nil
    }

    /// A short animated GIF (a few frames of the clip), made with ffmpeg.
    func animatedGIF(from clip: URL, name: String = "anim.gif") -> URL? {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let out = url(name)
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-t", "1.5", "-i", clip.path, "-vf", "fps=10,scale=320:-1:flags=lanczos", out.path], timeout: 120)
        return r.status == 0 ? out : nil
    }

    // MARK: Frame drawing

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func drawFrame(_ ctx: CGContext, index f: Int, fps: Int, width w: Int, height h: Int, grain: CGImage) {
        let t = Double(f) / Double(fps)
        let W = CGFloat(w), H = CGFloat(h)
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: cs, colors: [hsv(fmod(t * 0.07, 1), 0.55, 0.85), hsv(fmod(t * 0.07 + 0.45, 1), 0.65, 0.55)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])
        // Shapes crossing the frame at different speeds, all with hard edges.
        for i in 0..<5 {
            let x = CGFloat(fmod(t * (90 + Double(i) * 45) + Double(i) * 130, Double(w) + 120)) - 60
            let y = H * (0.2 + 0.14 * CGFloat(i)) + 18 * CGFloat(sin(t * 2 + Double(i)))
            ctx.setFillColor(i % 2 == 0 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.05, alpha: 1))
            if i % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: 70, height: 30)) } else { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 44, height: 44)) }
        }
        // A turning spoke.
        let c = CGPoint(x: W * 0.78, y: H * 0.35), a = CGFloat(t * 1.6)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.1, alpha: 1)); ctx.setLineWidth(5)
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + 90 * cos(a), y: c.y + 90 * sin(a))); ctx.strokePath()
        // A static detailed patch: checker squares and fine lines.
        for yy in 0..<8 { for xx in 0..<12 {
            ctx.setFillColor((xx + yy) % 2 == 0 ? CGColor(gray: 0.95, alpha: 1) : CGColor(gray: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 12 + CGFloat(xx) * 8, y: H - 80 + CGFloat(yy) * 8, width: 8, height: 8))
        } }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.4, alpha: 1))
        for k in 0..<20 { ctx.fill(CGRect(x: 120, y: H - 80 + CGFloat(k) * 3, width: 100, height: 1)) }
        // Frame counter and a Cyrillic caption.
        func text(_ s: String, size: CGFloat, at p: CGPoint, color: CGColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: CTFontCreateUIFontForLanguage(.system, size, nil)!, .foregroundColor: color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: 1, y: -1); ctx.textPosition = .zero; CTLineDraw(line, ctx); ctx.restoreGState()
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85)); ctx.fill(CGRect(x: 10, y: 10, width: 210, height: 34))
        text(String(format: "frame %03d  t=%.2f s", f, t), size: 16, at: CGPoint(x: 18, y: 34), color: CGColor(gray: 0, alpha: 1))
        text("Привет, мир — swamp", size: 20, at: CGPoint(x: W * 0.45, y: H - 24), color: CGColor(gray: 1, alpha: 1))
        // Grain: the same tile at a different offset in every frame.
        let ox = CGFloat((f * 37) % 256), oy = CGFloat((f * 91) % 256)
        var y = -oy
        while y < H { var x = -ox; while x < W { ctx.draw(grain, in: CGRect(x: x, y: y, width: 256, height: 256)); x += 256 }; y += 256 }
    }

    private static func grainTile() -> CGImage {
        var noise = Noise(seed: 1234)
        var px = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for i in 0..<(256 * 256) {
            let v = noise.next(1.0) > 0 ? 255 : 0
            px[i * 4] = UInt8(v) ; px[i * 4 + 1] = UInt8(v); px[i * 4 + 2] = UInt8(v)
            px[i * 4 + 3] = UInt8(5 + Int(noise.unit() * 9))   // faint: premultiplied value below must not exceed alpha
            let a = px[i * 4 + 3]
            if v == 255 { px[i * 4] = a; px[i * 4 + 1] = a; px[i * 4 + 2] = a }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // MARK: Audio sample buffers

    private static func pcmBuffer(_ interleaved: [Int16], channels: Int, rate: Double, startFrame: Int64) -> CMSampleBuffer? {
        let frames = interleaved.count / channels
        guard frames > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let fd = format else { return nil }
        var block: CMBlockBuffer?
        let bytes = interleaved.count * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: 0, blockBufferOut: &block) == noErr, let bb = block else { return nil }
        let status = interleaved.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
        guard status == noErr else { return nil }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: startFrame, timescale: CMTimeScale(rate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: frames, presentationTimeStamp: pts,
                                                                    packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

extension TestFixtures {
    static func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> TestFailure { TestFailure(message: message, file: "\(file)", line: line) }
}
