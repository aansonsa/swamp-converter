import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Realistic inputs for the conformance checks. A flat colour or a pure sine proves nothing about a lossy codec (it compresses to nothing and every metric
// reads "perfect"), so every fixture here carries what real material carries: gradients, sharp edges, text, fine grain, chirps plus noise, motion,
// multi-page paragraphs, quoted unicode tables. Everything is deterministic (seeded) and written below `root` inside the app's temp folder.

final class ConformanceFixtures {
    let base: TestFixtures
    var root: URL { base.root }

    init(label: String = "conf") { base = TestFixtures(label: label) }

    func cleanup() { base.cleanup() }
    func url(_ name: String) -> URL { base.url(name) }

    @discardableResult
    func folder(_ name: String) throws -> URL { try base.makeDirectory(name) }

    // MARK: Gaussian-ish noise

    struct Noise {
        var rng: SplitMix
        init(seed: UInt64) { rng = SplitMix(seed: seed) }
        /// Roughly normal with standard deviation `sigma` (sum of four uniforms).
        mutating func next(_ sigma: Double) -> Double {
            var s = 0.0
            for _ in 0..<4 { s += Double(rng.next() >> 11) / Double(1 << 53) - 0.5 }
            return s * sigma * 1.7320508
        }
        mutating func unit() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }
    }

    // MARK: Pictures

    /// A photograph-like scene: sky gradient with a sun glow, layered hills, sharp-edged objects, text in two scripts, fine stripes and film grain.
    /// With `alpha`, a soft elliptical vignette makes the border transparent (partial alpha everywhere along the edge).
    func photoImage(width: Int = 640, height: Int = 480, seed: UInt64 = 7, alpha: Bool = false) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)   // y grows downward
        func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a) }
        let sky = CGGradient(colorsSpace: cs, colors: [color(22, 52, 120), color(96, 148, 210), color(250, 196, 140), color(255, 232, 190)] as CFArray, locations: [0, 0.35, 0.72, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h * 0.62), options: [.drawsAfterEndLocation])
        let sun = CGGradient(colorsSpace: cs, colors: [color(255, 250, 220, 1), color(255, 214, 120, 0.55), color(255, 180, 90, 0)] as CFArray, locations: [0, 0.35, 1])!
        ctx.drawRadialGradient(sun, startCenter: CGPoint(x: w * 0.72, y: h * 0.42), startRadius: 0, endCenter: CGPoint(x: w * 0.72, y: h * 0.42), endRadius: h * 0.42, options: [])
        // Hills: three layers of smooth bezier ridges, darker towards the viewer.
        let layers: [(CGFloat, [Int])] = [(0.58, [70, 110, 98]), (0.68, [46, 88, 62]), (0.80, [24, 58, 38])]
        for (i, layer) in layers.enumerated() {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: 0, y: h * layer.0))
            let phase = CGFloat(i) * 1.7
            p.addCurve(to: CGPoint(x: w * 0.5, y: h * (layer.0 - 0.05 * sin(phase + 1))), control1: CGPoint(x: w * 0.15, y: h * (layer.0 - 0.10)), control2: CGPoint(x: w * 0.33, y: h * (layer.0 + 0.04)))
            p.addCurve(to: CGPoint(x: w, y: h * (layer.0 + 0.02 * cos(phase))), control1: CGPoint(x: w * 0.68, y: h * (layer.0 - 0.12)), control2: CGPoint(x: w * 0.86, y: h * (layer.0 + 0.05)))
            p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(color(layer.1[0], layer.1[1], layer.1[2])); ctx.fillPath()
        }
        // Hard-edged objects: a red roof, a white wall with a dark window, a blue disc, a yellow bar.
        ctx.setFillColor(color(190, 40, 36)); ctx.move(to: CGPoint(x: w * 0.08, y: h * 0.62)); ctx.addLine(to: CGPoint(x: w * 0.20, y: h * 0.50)); ctx.addLine(to: CGPoint(x: w * 0.32, y: h * 0.62)); ctx.fillPath()
        ctx.setFillColor(color(242, 242, 236)); ctx.fill(CGRect(x: w * 0.10, y: h * 0.62, width: w * 0.20, height: h * 0.16))
        ctx.setFillColor(color(24, 28, 40)); ctx.fill(CGRect(x: w * 0.16, y: h * 0.66, width: w * 0.05, height: h * 0.08))
        ctx.setFillColor(color(30, 90, 200)); ctx.fillEllipse(in: CGRect(x: w * 0.78, y: h * 0.70, width: h * 0.16, height: h * 0.16))
        ctx.setFillColor(color(250, 210, 30)); ctx.fill(CGRect(x: w * 0.42, y: h * 0.84, width: w * 0.30, height: h * 0.035))
        // Fine stripes (exposes chroma subsampling and quantisation): alternating one-pixel lines of saturated colours.
        for k in 0..<Int(h * 0.05) {
            ctx.setFillColor(k % 2 == 0 ? color(255, 20, 90) : color(20, 200, 255))
            ctx.fill(CGRect(x: w * 0.40, y: h * 0.90 + CGFloat(k), width: w * 0.30, height: 1))
        }
        // Text in Latin, Cyrillic and Czech.
        func text(_ s: String, size: CGFloat, at p: CGPoint, white: Bool) {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: white ? color(255, 255, 255) : color(20, 20, 20)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: 1, y: -1); ctx.textPosition = .zero; CTLineDraw(line, ctx); ctx.restoreGState()
        }
        text("Swamp Converter 0123456789", size: h * 0.06, at: CGPoint(x: w * 0.04, y: h * 0.10), white: true)
        text("Привет, мир — Žluťoučký kůň", size: h * 0.04, at: CGPoint(x: w * 0.04, y: h * 0.17), white: true)
        text("The quick brown fox jumps over the lazy dog", size: h * 0.026, at: CGPoint(x: w * 0.04, y: h * 0.22), white: false)
        // Film grain over everything, written straight into the bitmap (premultiplied: never above alpha).
        var noise = Noise(seed: seed)
        if let p = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height) {
            let bpr = ctx.bytesPerRow
            for y in 0..<height { for x in 0..<width {
                let o = y * bpr + x * 4
                let g = noise.next(2.2)
                for c in 0..<3 { p[o + c] = UInt8(max(0, min(255, Double(p[o + c]) + g + noise.next(0.8)))) }
            } }
        }
        if alpha, let p = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height) {
            let bpr = ctx.bytesPerRow
            for y in 0..<height { for x in 0..<width {
                let dx = (Double(x) / Double(width) - 0.5) * 2, dy = (Double(y) / Double(height) - 0.5) * 2
                let r = (dx * dx + dy * dy).squareRoot()
                let a = max(0, min(1, (1.05 - r) / 0.35))   // opaque inside, linear ramp to transparent at the border
                let o = y * bpr + x * 4
                for c in 0..<3 { p[o + c] = UInt8(Double(p[o + c]) * a) }
                p[o + 3] = UInt8((a * 255).rounded())
            } }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    func photo(_ name: String = "photo.png", width: Int = 640, height: Int = 480, seed: UInt64 = 7, alpha: Bool = false) throws -> URL {
        try base.writeImage(photoImage(width: width, height: height, seed: seed, alpha: alpha), name: name, type: .png)
    }

    /// The scene as a JPEG, optionally stored sideways with an EXIF orientation tag (the viewer shows it upright) and GPS / camera metadata.
    @discardableResult
    func photoJPEG(_ name: String = "photo.jpg", width: Int = 640, height: Int = 480, quality: Double = 0.95, orientation: Int? = nil, gps: Bool = false) throws -> URL {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 50.0755, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 14.4378, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "SwampCam", kCGImagePropertyTIFFModel: "Marsh 1"] as [CFString: Any]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:24 12:00:00"] as [CFString: Any]
        }
        return try base.writeImage(photoImage(width: width, height: height), name: name, type: .jpeg, properties: props)
    }

    // MARK: Audio

    /// 16-bit stereo WAV: two different chirps, two tones, a transient burst and low noise, so channel mix-ups, delays and codec damage are all measurable.
    @discardableResult
    func chirp(_ name: String = "chirp.wav", seconds: Double = 3, rate: Int = 44_100, channels: Int = 2, seed: UInt64 = 11) throws -> URL {
        let pcm = chirpSamples(seconds: seconds, rate: rate, channels: channels, seed: seed)
        return try writeWAV(name, samples: pcm, channels: channels, rate: rate)
    }

    func chirpSamples(seconds: Double, rate: Int, channels: Int, seed: UInt64 = 11) -> [Int16] {
        let frames = Int(seconds * Double(rate))
        var out = [Int16](repeating: 0, count: frames * channels)
        var noise = Noise(seed: seed)
        var phaseA = 0.0, phaseB = 0.0
        for i in 0..<frames {
            let t = Double(i) / Double(rate), u = t / seconds
            let fa = 300 * pow(6000.0 / 300.0, u), fb = 5000 * pow(400.0 / 5000.0, u)   // exponential sweeps up and down
            phaseA += 2 * Double.pi * fa / Double(rate); phaseB += 2 * Double.pi * fb / Double(rate)
            let burst = (t > seconds / 2 && t < seconds / 2 + 0.08) ? sin(2 * Double.pi * 1000 * t) * exp(-(t - seconds / 2) * 40) * 0.5 : 0
            let fade = min(1, t / 0.05) * min(1, (seconds - t) / 0.05)
            let left = (0.25 * sin(2 * Double.pi * 220 * t) + 0.28 * sin(phaseA) + burst + noise.next(0.012)) * fade
            let right = (0.25 * sin(2 * Double.pi * 330 * t) + 0.28 * sin(phaseB) + noise.next(0.012)) * fade
            func q(_ v: Double) -> Int16 { Int16(max(-32768, min(32767, (v * 32767).rounded()))) }
            if channels == 1 { out[i] = q((left + right) / 2) } else { out[i * channels] = q(left); out[i * channels + 1] = q(right) }
        }
        return out
    }

    @discardableResult
    func writeWAV(_ name: String, samples: [Int16], channels: Int, rate: Int) throws -> URL {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(x).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }   // little-endian host
        let u = url(name)
        try d.write(to: u)
        return u
    }

    /// The chirp in another format, made with the system's afconvert (m4a, aac, flac, aiff, caf) or ffmpeg (mp3, ogg, opus, wma). Nil when no tool can.
    func audioVariant(of source: URL, ext: String) -> URL? {
        let out = url(source.deletingPathExtension().lastPathComponent + "." + ext)
        let afconvert: [String: [String]] = ["m4a": ["-f", "m4af", "-d", "aac", "-b", "192000"], "flac": ["-f", "flac", "-d", "flac"], "aiff": ["-f", "AIFF", "-d", "BEI16"],
                                             "caf": ["-f", "caff", "-d", "LEI16"], "wav": ["-f", "WAVE", "-d", "LEI16"]]
        if let args = afconvert[ext] {
            let r = ExternalProbe.run("/usr/bin/afconvert", args + [source.path, out.path], timeout: 120)
            if r.status == 0 { return out }
        }
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let codec: [String: [String]] = ["mp3": ["-c:a", "libmp3lame", "-q:a", "2"], "ogg": ["-c:a", "libvorbis", "-q:a", "5"], "opus": ["-c:a", "libopus", "-b:a", "128k"],
                                         "m4a": ["-c:a", "aac", "-b:a", "192k"], "aac": ["-c:a", "aac", "-b:a", "192k"], "flac": ["-c:a", "flac"], "wma": ["-c:a", "wmav2", "-b:a", "192k"],
                                         "aiff": ["-c:a", "pcm_s16be"], "wav": ["-c:a", "pcm_s16le"]]
        guard let args = codec[ext] else { return nil }
        var r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", source.path, "-vn"] + args + [out.path], timeout: 120)
        if r.status != 0 && ext == "ogg" {   // builds without libvorbis: the native (experimental) encoder
            r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", source.path, "-vn", "-c:a", "vorbis", "-strict", "-2", "-q:a", "5", out.path], timeout: 120)
        }
        return r.status == 0 ? out : nil
    }

    // MARK: Archives

    /// A folder with the awkward things archives meet: nested folders, an executable, an empty file, a 300 KB random blob, unicode names, a read-only file.
    @discardableResult
    func archiveSource(_ name: String = "project") throws -> URL {
        let dir = try folder(name)
        let fm = FileManager.default
        func write(_ rel: String, _ data: Data, mode: Int? = nil) throws {
            let f = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: f)
            if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: f.path) }
        }
        try write("readme.txt", Data("Swamp archive fixture\nПривет, мир\n".utf8))
        try write("bin/run.sh", Data("#!/bin/sh\necho hello\n".utf8), mode: 0o755)
        try write("data/empty.txt", Data())
        var rng = SplitMix(seed: 99)
        var blob = Data(capacity: 300_000)
        for _ in 0..<(300_000 / 8) { var v = rng.next(); withUnsafeBytes(of: &v) { blob.append(contentsOf: $0) } }
        try write("data/blob.bin", blob)
        try write("unicode/Žluťák — тест.txt", Data("unicode name\n".utf8))
        try write("a/b/c/deep.txt", Data("deep\n".utf8))
        try write("locked.txt", Data("read only\n".utf8), mode: 0o444)
        return dir
    }

    /// A ZIP whose members try to leave the extraction folder (zip-slip), plus one honest member.
    @discardableResult
    func hostileZip(_ name: String = "hostile.zip") throws -> URL {
        let data = ArchiveFidelity.zipData(members: [("safe/ok.txt", Data("ok\n".utf8), 0o644), ("../evil.txt", Data("evil\n".utf8), 0o644),
                                                      ("/tmp/swamp-evil-abs.txt", Data("evil\n".utf8), 0o644), ("a/../../evil2.txt", Data("evil\n".utf8), 0o644)])
        let u = url(name)
        try data.write(to: u)
        return u
    }
}
