import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// Generated test inputs (no downloads, no files outside the temp root) and read-back helpers ("oracles") for
// self-tests. Every fixture is written below `root`, a fresh folder inside `AppPaths.tempRoot` (isolated in
// --self-test). Always `defer { fx.cleanup() }`.
//
//   let fx = TestFixtures()
//   defer { fx.cleanup() }
//   let png = try fx.png(width: 400, height: 200, pattern: .quadrants)
//   try expectEqual(TestImage.size(of: png)?.width, 400)

enum TestPattern {
    case solid(RGBA)
    /// Top-left red, top-right green, bottom-left blue, bottom-right yellow. Proves flips, rotations and crops.
    case quadrants
    /// Smooth diagonal gradient (compresses well, quality changes are visible in the byte size).
    case gradient
    /// Pseudo-random noise (does not compress: size differences between quality levels are large).
    case noise(seed: UInt64)
    case checker
}

final class TestFixtures {
    let root: URL

    init(label: String = "fx") {
        root = AppPaths.tempRoot.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { AppPaths.removeTemp(root) }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    @discardableResult
    func makeDirectory(_ name: String) throws -> URL {
        let u = url(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Images

    /// An sRGB RGBA bitmap with the requested pattern. Origin is the TOP-left for `.quadrants` (as a viewer shows it).
    func cgImage(width: Int, height: Int, pattern: TestPattern = .gradient, alpha: Bool = false) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
        // Flip so that y grows downward while drawing.
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        let w = CGFloat(width), h = CGFloat(height)
        func fill(_ c: RGBA, _ r: CGRect) { ctx.setFillColor(c.cgColor); ctx.fill(r) }
        switch pattern {
        case .solid(let c): fill(c, CGRect(x: 0, y: 0, width: w, height: h))
        case .quadrants:
            fill(.red, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
            fill(.green, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
            fill(.blue, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
            fill(.yellow, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        case .gradient:
            let g = CGGradient(colorsSpace: cs, colors: [RGBA(r: 20, g: 60, b: 160).cgColor, RGBA(r: 250, g: 200, b: 90).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        case .noise(let seed):
            var rng = SplitMix(seed: seed)
            if let p = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) {
                let bpr = ctx.bytesPerRow
                for y in 0..<height { for x in 0..<width {
                    let o = y * bpr + x * 4
                    let v = rng.next()
                    p[o] = UInt8(truncatingIfNeeded: v); p[o + 1] = UInt8(truncatingIfNeeded: v >> 8); p[o + 2] = UInt8(truncatingIfNeeded: v >> 16); p[o + 3] = 255
                } }
            }
        case .checker:
            let s = max(4, min(width, height) / 8)
            for y in stride(from: 0, to: height, by: s) { for x in stride(from: 0, to: width, by: s) {
                fill(((x / s + y / s) % 2 == 0) ? .white : .black, CGRect(x: x, y: y, width: s, height: s))
            } }
        }
        if alpha {
            // Make the right half fully transparent so alpha handling (flatten / keep) is observable.
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
        return ctx.makeImage()!
    }

    /// Writes any ImageIO-writable type. `properties` are merged into the destination options (quality, DPI, EXIF ...).
    @discardableResult
    func writeImage(_ image: CGImage, name: String, type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let u = url(name)
        guard let dest = CGImageDestinationCreateWithURL(u as CFURL, type.identifier as CFString, 1, nil) else {
            throw TestFailure(message: "ImageIO cannot write \(type.identifier)", file: #fileID, line: #line)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestFailure(message: "ImageIO failed to finalize \(name)", file: #fileID, line: #line) }
        return u
    }

    @discardableResult
    func png(_ name: String = "image.png", width: Int = 64, height: Int = 48, pattern: TestPattern = .gradient, alpha: Bool = false) throws -> URL {
        try writeImage(cgImage(width: width, height: height, pattern: pattern, alpha: alpha), name: name, type: .png)
    }

    /// JPEG with optional EXIF orientation (1...8) and a GPS dictionary (for the "strip metadata" oracles).
    @discardableResult
    func jpeg(_ name: String = "image.jpg", width: Int = 64, height: Int = 48, pattern: TestPattern = .gradient, quality: Double = 0.9,
              orientation: Int? = nil, gps: Bool = false) throws -> URL {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 50.08, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 14.42, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "SwampCam", kCGImagePropertyTIFFModel: "Test 1"] as [CFString: Any]
        }
        return try writeImage(cgImage(width: width, height: height, pattern: pattern), name: name, type: .jpeg, properties: props)
    }

    @discardableResult
    func tiff(_ name: String = "image.tiff", width: Int = 64, height: Int = 48, pattern: TestPattern = .gradient) throws -> URL {
        try writeImage(cgImage(width: width, height: height, pattern: pattern), name: name, type: .tiff)
    }

    /// A literal SVG file (ImageIO cannot read it; NSImage can).
    @discardableResult
    func svg(_ name: String = "vector.svg", width: Int = 64, height: Int = 48) throws -> URL {
        let s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\"><rect width=\"\(width)\" height=\"\(height)\" fill=\"#ff8800\"/><circle cx=\"\(width / 2)\" cy=\"\(height / 2)\" r=\"\(min(width, height) / 3)\" fill=\"#0044cc\"/></svg>"
        return try text(name, s)
    }

    // MARK: Audio

    /// PCM 16-bit little-endian WAV with a sine tone.
    @discardableResult
    func wav(_ name: String = "tone.wav", seconds: Double = 1.0, frequency: Double = 440, sampleRate: Int = 44_100, channels: Int = 1) throws -> URL {
        let frames = Int(seconds * Double(sampleRate))
        var pcm = Data(capacity: frames * channels * 2)
        for i in 0..<frames {
            let v = Int16(sin(2 * Double.pi * frequency * Double(i) / Double(sampleRate)) * 0.5 * 32767)
            for _ in 0..<channels { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var d = Data()
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(x).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(channels); u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count); d.append(pcm)
        let u = url(name)
        try d.write(to: u)
        return u
    }

    // MARK: PDF

    /// A vector PDF: every page has a title ("Page N"), body text from `text(pageIndex)` (Cyrillic works) and,
    /// when `noisyImage` is true, a noisy raster image (compressible only by recompression).
    @discardableResult
    func pdf(_ name: String = "doc.pdf", pages: Int = 2, text: ((Int) -> String)? = nil, size: CGSize = CGSize(width: 612, height: 792),
             noisyImage: Bool = false) throws -> URL {
        let u = url(name)
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { throw TestFailure(message: "cannot create PDF context", file: #fileID, line: #line) }
        let font = CTFontCreateUIFontForLanguage(.system, 22, nil)!
        let small = CTFontCreateUIFontForLanguage(.system, 14, nil)!
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
            draw("Page \(p + 1)", in: ctx, at: CGPoint(x: 56, y: size.height - 80), font: font)
            draw(text?(p) ?? "Swamp 12345 Привет мир", in: ctx, at: CGPoint(x: 56, y: size.height - 120), font: small)
            if noisyImage { ctx.draw(cgImage(width: 200, height: 200, pattern: .noise(seed: UInt64(p + 1))), in: CGRect(x: 56, y: 200, width: 300, height: 300)) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return u
    }

    private func draw(_ s: String, in ctx: CGContext, at p: CGPoint, font: CTFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    // MARK: Text, tables, subtitles

    @discardableResult
    func text(_ name: String, _ content: String, encoding: String.Encoding = .utf8, bom: Bool = false) throws -> URL {
        var data = Data()
        if bom && encoding == .utf8 { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        guard let body = content.data(using: encoding) else { throw TestFailure(message: "cannot encode fixture text", file: #fileID, line: #line) }
        data.append(body)
        let u = url(name)
        try data.write(to: u)
        return u
    }

    @discardableResult
    func csv(_ name: String = "table.csv", rows: [[String]] = [["name", "count"], ["Žluťák", "42"], ["Привет", "7"]], delimiter: Character = ",",
             encoding: String.Encoding = .utf8, bom: Bool = false, lineEnding: String = "\r\n") throws -> URL {
        func esc(_ f: String) -> String {
            let needs = f.contains(delimiter) || f.contains("\"") || f.contains("\n") || f.contains("\r")
            return needs ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }
        let s = rows.map { $0.map(esc).joined(separator: String(delimiter)) }.joined(separator: lineEnding) + lineEnding
        return try text(name, s, encoding: encoding, bom: bom)
    }

    struct Cue { var start: Double; var end: Double; var text: String }

    @discardableResult
    func srt(_ name: String = "subs.srt", cues: [Cue] = [Cue(start: 1, end: 2.5, text: "Ahoj"), Cue(start: 3, end: 4.25, text: "Привет, мир")],
             encoding: String.Encoding = .utf8) throws -> URL {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        let s = cues.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start)) --> \(stamp($0.element.end))\n\($0.element.text)\n" }.joined(separator: "\n")
        return try text(name, s, encoding: encoding)
    }

    // MARK: Folders and archives

    /// Creates `name/` with the given relative paths and contents ("pod/a.txt": "A").
    @discardableResult
    func folderTree(_ name: String = "tree", files: [String: String] = ["a.txt": "A", "pod/b.txt": "B"]) throws -> URL {
        let dir = try makeDirectory(name)
        for (rel, content) in files {
            let f = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: f)
        }
        return dir
    }

    /// Creates a zip of the given items (relative to `root`) with /usr/bin/zip.
    @discardableResult
    func zip(_ name: String = "archive.zip", items: [String]) throws -> URL {
        let out = url(name)
        try runSync("/usr/bin/zip", ["-q", "-r", out.path] + items)
        return out
    }

    /// Creates a .tar.gz of the given items (relative to `root`) with bsdtar.
    @discardableResult
    func tarGz(_ name: String = "archive.tar.gz", items: [String]) throws -> URL {
        let out = url(name)
        try runSync("/usr/bin/tar", ["-czf", out.path] + items)
        return out
    }

    private func runSync(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.currentDirectoryURL = root
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TestFailure(message: "\(exe) failed: \(msg)", file: #fileID, line: #line)
        }
    }

    // MARK: Video (AVFoundation only, no ffmpeg needed)

    /// An H.264 .mp4 (or .mov) of moving colour bars: `seconds` long, `fps` frames per second, no audio.
    @discardableResult
    func video(_ name: String = "clip.mp4", seconds: Double = 2, size: CGSize = CGSize(width: 320, height: 240), fps: Int = 24) async throws -> URL {
        let u = url(name)
        let type: AVFileType = name.lowercased().hasSuffix(".mov") ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: u, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        guard writer.canAdd(input) else { throw TestFailure(message: "AVAssetWriter cannot add the video input", file: #fileID, line: #line) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestFailure(message: "AVAssetWriter failed to start", file: #fileID, line: #line) }
        writer.startSession(atSourceTime: .zero)
        let frames = max(1, Int(seconds * Double(fps)))
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw TestFailure(message: "no pixel buffer pool", file: #fileID, line: #line) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { throw TestFailure(message: "no pixel buffer", file: #fileID, line: #line) }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                let bars: [RGBA] = [.red, .green, .blue, .yellow, .orange, .white]
                let bw = size.width / CGFloat(bars.count)
                let shift = Int(Double(f) / Double(frames) * Double(bars.count))
                for (i, c) in bars.enumerated() { ctx.setFillColor(bars[(i + shift) % bars.count].cgColor); _ = c; ctx.fill(CGRect(x: CGFloat(i) * bw, y: 0, width: bw, height: size.height)) }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? TestFailure(message: "AVAssetWriter did not complete", file: #fileID, line: #line) }
        return u
    }
}

/// Small deterministic PRNG for noise fixtures.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Read-back helpers (oracles)

enum TestImage {
    struct Info { var width: Int; var height: Int; var type: String?; var dpiX: Double?; var hasAlpha: Bool; var orientation: Int?; var profileName: String? }

    static func info(of url: URL) -> Info? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return Info(width: w, height: h, type: CGImageSourceGetType(src) as String?, dpiX: props[kCGImagePropertyDPIWidth] as? Double,
                    hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false, orientation: props[kCGImagePropertyOrientation] as? Int,
                    profileName: props[kCGImagePropertyProfileName] as? String)
    }

    static func size(of url: URL) -> (width: Int, height: Int)? { info(of: url).map { ($0.width, $0.height) } }

    /// RGBA of one pixel (x right, y DOWN), decoded to sRGB. Orientation tags are NOT applied.
    static func pixel(of url: URL, x: Int, y: Int) -> RGBA? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              x >= 0, y >= 0, x < img.width, y < img.height else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -CGFloat(x), y: -CGFloat(img.height - 1 - y))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let a = px[3]
        if a == 0 { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        // Un-premultiply.
        func un(_ c: UInt8) -> UInt8 { UInt8(min(255, Int(c) * 255 / Int(a))) }
        return RGBA(r: un(px[0]), g: un(px[1]), b: un(px[2]), a: a)
    }

    /// True when the colours are within `tolerance` per channel (ignores alpha unless `alpha` is true).
    static func close(_ a: RGBA?, _ b: RGBA, tolerance: Int = 24, alpha: Bool = false) -> Bool {
        guard let a else { return false }
        func d(_ x: UInt8, _ y: UInt8) -> Int { abs(Int(x) - Int(y)) }
        return d(a.r, b.r) <= tolerance && d(a.g, b.g) <= tolerance && d(a.b, b.b) <= tolerance && (!alpha || d(a.a, b.a) <= tolerance)
    }
}

enum TestFile {
    static func size(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1 }
    /// First `count` bytes (magic numbers: PNG 89 50 4E 47, JPEG FF D8 FF, PDF "%PDF", ZIP "PK", RIFF/WEBP ...).
    static func magic(_ url: URL, _ count: Int = 12) -> [UInt8] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        return Array((try? h.read(upToCount: count)) ?? Data())
    }
    static func magicString(_ url: URL, _ count: Int = 12) -> String { String(decoding: magic(url, count), as: UTF8.self) }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Names of leftover in-flight files (".name.xxxxxxxx.part.ext") directly inside `dir`; must be empty after every operation.
    static func partials(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { OutputPaths.isInFlightName($0) }
    }
}
