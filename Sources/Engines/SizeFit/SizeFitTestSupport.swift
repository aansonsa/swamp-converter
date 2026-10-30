import Foundation
import CoreGraphics
import CoreText
import AVFoundation
import PDFKit
import ImageIO

// Fixtures and read-back oracles of the sizefit self-tests. Everything is generated into a TestFixtures folder; nothing is downloaded.

enum FitTestSupport {
    static var hasFFmpeg: Bool { ToolLocator.shared.has(.ffmpeg) && ToolLocator.shared.has(.ffprobe) }

    static func requireFFmpeg() throws {
        if !hasFFmpeg { try skipTest("needs ffmpeg and ffprobe (brew install ffmpeg)") }
        if !Capabilities.shared.has("ff.enc.libx264") { try skipTest("needs an ffmpeg build with libx264") }
    }

    // MARK: Running

    /// Runs the fit operation `id` for one file the way the quick path does (quick recipe + `extra`), in the folder of the file.
    @MainActor
    static func run(_ file: URL, id: String, extra: OptionValues = OptionValues(), preferHardware: Bool = false) async throws -> (result: OperationResult, ctx: OperationContext) {
        let op = try unwrap(FitCatalog.operations().first { $0.meta.id == id })
        let items = [FileItem(url: file)]
        let ctx = makeContext(op, items: items, extra: extra, preferHardware: preferHardware)
        defer { ctx.cleanupTemp() }
        let result = try await op.execute(items: items, ctx: ctx)
        return (result, ctx)
    }

    @MainActor
    static func makeContext(_ op: Operation, items: [FileItem], extra: OptionValues, preferHardware: Bool = false) -> OperationContext {
        let settings = SettingsData()
        let resolved = op.optionSchema(for: items).resolve(layers: [op.quickOverrides(settings: settings), extra])
        return OperationContext(operationID: op.meta.id, mode: .quick, resolved: resolved, outputRules: OutputRules(), settings: settings, preferHardware: preferHardware)
    }

    static func target(mb: Double) -> OptionValues { [FitKeys.target: "custom", FitKeys.customMB: .double(mb)] }
    static func target(bytes: Int64) -> OptionValues { target(mb: Double(bytes) / 1_000_000) }

    // MARK: Video

    /// A synthetic clip made by ffmpeg (test pattern with noise so it does not compress to nothing, plus a sine track). H.264 in MP4.
    static func makeVideo(_ fx: TestFixtures, _ name: String = "clip.mp4", seconds: Double = 5, width: Int = 640, height: Int = 360, fps: Int = 25, audio: Bool = true,
                          noise: Int = 12, pixelFormat: String = "yuv420p", metadata: [String] = [], extraVideoArgs: [String] = []) async throws -> URL {
        let out = fx.url(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=\(fps):duration=\(seconds),noise=alls=\(noise):allf=t"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=\(seconds)"] }
        args += ["-c:v", "libx264", "-crf", "16", "-pix_fmt", pixelFormat] + extraVideoArgs
        args += audio ? ["-c:a", "aac", "-b:a", "128k", "-shortest"] : ["-an"]
        args += metadata + [out.path]
        try await ProcessRunner.run(try ToolLocator.shared.require(.ffmpeg), args)
        return out
    }

    struct VideoFacts { var width: Int; var height: Int; var duration: Double; var videoCodec: String; var audioCodec: String?; var audioBitrate: Int?; var tags: [String: String]; var fps: Double }

    /// ffprobe, parsed independently of the engine's own parser.
    static func videoFacts(_ url: URL) async throws -> VideoFacts {
        let out = try await ProcessRunner.run(try ToolLocator.shared.require(.ffprobe), ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], captureStdout: true)
        let json = try unwrap(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let streams = (json["streams"] as? [[String: Any]]) ?? []
        let v = try unwrap(streams.first { ($0["codec_type"] as? String) == "video" }, "no video stream")
        let a = streams.first { ($0["codec_type"] as? String) == "audio" }
        let format = (json["format"] as? [String: Any]) ?? [:]
        let fr = (v["avg_frame_rate"] as? String ?? "0/1").split(separator: "/").compactMap { Double($0) }
        return VideoFacts(width: v["width"] as? Int ?? 0, height: v["height"] as? Int ?? 0, duration: Double(format["duration"] as? String ?? "") ?? 0,
                          videoCodec: v["codec_name"] as? String ?? "", audioCodec: a?["codec_name"] as? String, audioBitrate: Int(a?["bit_rate"] as? String ?? ""),
                          tags: (format["tags"] as? [String: String]) ?? [:], fps: fr.count == 2 && fr[1] > 0 ? fr[0] / fr[1] : 0)
    }

    /// AVFoundation can open and play it, and really reads a frame: the "plays everywhere" oracle for outputs.
    static func expectPlayable(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        try expect(playable, "\(url.lastPathComponent) must be playable by AVFoundation")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try unwrap(tracks.first, "no video track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try expect(reader.startReading(), "AVAssetReader must start")
        try expect(output.copyNextSampleBuffer() != nil, "AVAssetReader must read a frame")
        reader.cancelReading()
    }

    // MARK: Audio

    static func makeAudioNoise(_ fx: TestFixtures, _ name: String = "noise.wav", seconds: Double = 20) async throws -> URL {
        let out = fx.url(name)
        try await ProcessRunner.run(try ToolLocator.shared.require(.ffmpeg), ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                    "anoisesrc=d=\(seconds):c=pink:r=44100:a=0.3", "-ac", "2", out.path])
        return out
    }

    /// AVFoundation duration (independent of the engine's probe).
    static func duration(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    // MARK: Images

    /// A large photo-like JPEG: a smooth gradient with noise on top (compresses to a few MB, shrinks gradually with quality).
    static func makePhoto(_ fx: TestFixtures, _ name: String = "photo.jpg", width: Int = 1600, height: Int = 1200, gps: Bool = false, orientation: Int? = nil) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var rng = SplitMix(seed: 7)
        for y in 0..<height { for x in 0..<width {
            let o = y * ctx.bytesPerRow + x * 4, v = rng.next()
            let base = Double(x) / Double(width) * 160 + Double(y) / Double(height) * 60
            p[o] = UInt8(min(255, base + Double(v & 0x3f)))
            p[o + 1] = UInt8(min(255, 120 + base * 0.4 + Double((v >> 8) & 0x3f)))
            p[o + 2] = UInt8(min(255, 200 - base * 0.5 + Double((v >> 16) & 0x3f)))
            p[o + 3] = 255
        } }
        let image = ctx.makeImage()!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 50.08, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 14.42, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "SwampCam", kCGImagePropertyTIFFModel: "Test 1"] as [CFString: Any]
        }
        return try fx.writeImage(image, name: name, type: .jpeg, properties: props)
    }

    // MARK: PDF

    /// `pages` pages with a line of text and a noisy picture each (raw pixels in the PDF: large, shrinks a lot when recompressed).
    static func makePictureHeavyPDF(_ fx: TestFixtures, _ name: String = "scan.pdf", pages: Int = 3, pixels: Int = 900, title: String? = "Swamp report", author: String? = "Andris") throws -> URL {
        let url = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var aux: [CFString: Any] = [:]
        if let title { aux[kCGPDFContextTitle] = title }
        if let author { aux[kCGPDFContextAuthor] = author }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        let font = CTFontCreateUIFontForLanguage(.system, 18, nil)!
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.draw(fx.cgImage(width: pixels, height: pixels, pattern: .noise(seed: UInt64(p + 1))), in: CGRect(x: 36, y: 100, width: 400, height: 400))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Swamp page \(p + 1) Привет мир", attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
            ctx.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// Pages full of small vector strokes and text: no pictures, so only turning pages into pictures can make it small.
    static func makeVectorHeavyPDF(_ fx: TestFixtures, _ name: String = "vector.pdf", pages: Int = 2, strokes: Int = 60_000) throws -> URL {
        let url = fx.url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "no PDF context", file: #fileID, line: #line) }
        let font = CTFontCreateUIFontForLanguage(.system, 18, nil)!
        var rng = SplitMix(seed: 99)
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setLineWidth(0.3)
            for _ in 0..<strokes {
                let v = rng.next()
                ctx.setStrokeColor(CGColor(srgbRed: CGFloat(v & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat((v >> 16) & 255) / 255, alpha: 1))
                let x = CGFloat((v >> 24) & 511) + 50, y = CGFloat((v >> 34) & 511) + 100
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + CGFloat((v >> 44) & 31), y: y + CGFloat((v >> 49) & 31))); ctx.strokePath()
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Vector page \(p + 1) Привет мир", attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
            ctx.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}

extension FitTestSupport {
    struct AudioFacts { var codec: String; var bitrate: Int; var sampleRate: Int; var channels: Int }

    /// ffprobe of the first audio stream (container bit rate when the stream has none).
    static func audioFacts(_ url: URL) async throws -> AudioFacts {
        let out = try await ProcessRunner.run(try ToolLocator.shared.require(.ffprobe), ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], captureStdout: true)
        let json = try unwrap(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let a = try unwrap(((json["streams"] as? [[String: Any]]) ?? []).first { ($0["codec_type"] as? String) == "audio" }, "no audio stream")
        let format = (json["format"] as? [String: Any]) ?? [:]
        let br = Int(a["bit_rate"] as? String ?? "") ?? Int(format["bit_rate"] as? String ?? "") ?? 0
        return AudioFacts(codec: a["codec_name"] as? String ?? "", bitrate: br, sampleRate: Int(a["sample_rate"] as? String ?? "") ?? 0, channels: a["channels"] as? Int ?? 0)
    }
}

extension FitTestSupport {
    /// Video stream bit rate in kbit/s (ffprobe; falls back to size and duration).
    static func videoBitrateKbps(_ url: URL) async throws -> Int {
        let out = try await ProcessRunner.run(try ToolLocator.shared.require(.ffprobe),
                                              ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=bit_rate", "-of", "csv=p=0", url.path], captureStdout: true)
        if let v = Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 { return v / 1000 }
        let f = try await videoFacts(url)
        return Int(Double(TestFile.size(url)) * 8 / max(f.duration, 0.1) / 1000)
    }

    /// The yardstick: plain ffmpeg x264, medium preset, single-pass average bitrate, no audio, no tricks.
    static func x264Reference(_ source: URL, kbps: Int, in fx: TestFixtures) async throws -> URL {
        let out = fx.url("reference-\(kbps).mp4")
        try await ProcessRunner.run(try ToolLocator.shared.require(.ffmpeg), ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-map", "0:v:0", "-c:v", "libx264",
                                                                              "-preset", "medium", "-pix_fmt", "yuv420p", "-b:v", "\(kbps)k", "-an", out.path])
        return out
    }
}

extension FitTestSupport {
    /// The yardstick for pictures: macOS `sips` JPEG at the highest quality whose file is not larger than `maxBytes`.
    static func sipsReference(_ source: URL, maxBytes: Int64, in fx: TestFixtures) async throws -> URL {
        let sips = URL(fileURLWithPath: "/usr/bin/sips")
        let out = fx.url("reference.jpg")
        var lo = 1, hi = 100, best: Int?
        while lo <= hi {
            let q = (lo + hi) / 2
            try await ProcessRunner.run(sips, ["-s", "format", "jpeg", "-s", "formatOptions", "\(q)", source.path, "--out", out.path])
            if TestFile.size(out) <= maxBytes { best = q; lo = q + 1 } else { hi = q - 1 }
        }
        try await ProcessRunner.run(sips, ["-s", "format", "jpeg", "-s", "formatOptions", "\(best ?? 1)", source.path, "--out", out.path])
        return out
    }
}

extension FitTestSupport {
    static func tinyImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return ctx.makeImage()!
    }
}

extension FitTestSupport {
    /// Container tags (lower-case keys) from ffprobe.
    static func formatTags(_ url: URL) async throws -> [String: String] {
        let out = try await ProcessRunner.run(try ToolLocator.shared.require(.ffprobe), ["-v", "error", "-print_format", "json", "-show_format", url.path], captureStdout: true)
        let json = try unwrap(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let tags = ((json["format"] as? [String: Any])?["tags"] as? [String: String]) ?? [:]
        return Dictionary(uniqueKeysWithValues: tags.map { ($0.key.lowercased(), $0.value) })
    }

    /// Raw ffprobe dictionary of the first video stream.
    static func videoStreamFacts(_ url: URL) async throws -> [String: Any] {
        let out = try await ProcessRunner.run(try ToolLocator.shared.require(.ffprobe), ["-v", "error", "-print_format", "json", "-show_streams", "-select_streams", "v:0", url.path], captureStdout: true)
        let json = try unwrap(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        return try unwrap((json["streams"] as? [[String: Any]])?.first, "no video stream")
    }
}
