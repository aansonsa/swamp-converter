import Foundation
import ImageIO
import CoreGraphics

// Fixtures and independent oracles for the video self-tests. Everything is generated in a temp folder with ffmpeg's lavfi sources (moving test
// pattern with noise, a four-quadrant colour card, chirp audio). The oracles read results back with ffprobe / ffmpeg directly (raw JSON, raw pixels,
// psnr / ssim / idet / astats filters), never through the code that wrote the file.

struct VTProbe {
    var json: [String: Any]
    var streams: [[String: Any]] { json["streams"] as? [[String: Any]] ?? [] }
    var format: [String: Any] { json["format"] as? [String: Any] ?? [:] }
    var chapters: [[String: Any]] { json["chapters"] as? [[String: Any]] ?? [] }
    func streams(_ type: String) -> [[String: Any]] { streams.filter { $0["codec_type"] as? String == type } }
    var video: [String: Any]? { streams("video").first { ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 } }
    var audio: [String: Any]? { streams("audio").first }
    var duration: Double { Double(format["duration"] as? String ?? "") ?? 0 }
    var formatName: String { format["format_name"] as? String ?? "" }
    var tags: [String: String] {
        var o: [String: String] = [:]
        for (k, v) in (format["tags"] as? [String: Any]) ?? [:] { if let s = v as? String { o[k.lowercased()] = s } }
        return o
    }
    func str(_ s: [String: Any]?, _ k: String) -> String { s?[k] as? String ?? "" }
    func int(_ s: [String: Any]?, _ k: String) -> Int { (s?[k] as? Int) ?? Int(s?[k] as? String ?? "") ?? 0 }
    func dbl(_ s: [String: Any]?, _ k: String) -> Double { (s?[k] as? Double) ?? Double(s?[k] as? String ?? "") ?? 0 }
    var width: Int { int(video, "width") }
    var height: Int { int(video, "height") }
    var vcodec: String { str(video, "codec_name") }
    var pixFmt: String { str(video, "pix_fmt") }
    /// "30000/1001" -> 29.97
    func rate(_ key: String) -> Double {
        let p = str(video, key).split(separator: "/").compactMap { Double($0) }
        return p.count == 2 && p[1] != 0 ? p[0] / p[1] : (p.first ?? 0)
    }
    var frames: Int { int(video, "nb_frames") }
}

enum VT {
    static var ffmpeg: URL? { ToolLocator.shared.url(.ffmpeg) }
    static var ffprobe: URL? { ToolLocator.shared.url(.ffprobe) }

    // MARK: Running tools synchronously (tests only)

    @discardableResult
    static func run(_ exe: URL, _ args: [String], timeout: TimeInterval = 120) -> String {
        SyncProcess.run(exe, args, timeout: timeout) ?? ""
    }

    static func make(_ fx: TestFixtures, _ name: String, _ args: [String]) throws -> URL {
        guard let ff = ffmpeg else { throw TestSkip(reason: "ffmpeg is not installed") }
        let out = fx.url(name)
        let text = run(ff, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + args + [out.path])
        guard FileManager.default.fileExists(atPath: out.path), VTFile.size(out) > 0 else {
            throw TestFailure(message: "fixture \(name) was not created: \(text.suffix(300))", file: #fileID, line: #line)
        }
        return out
    }

    // MARK: Fixtures

    /// Moving test pattern with a little noise (so lossy metrics mean something) and a chirp-like tone. 320x240, 24 fps by default.
    static func clip(_ fx: TestFixtures, _ name: String = "clip.mp4", seconds: Double = 2, size: String = "320x240", fps: Int = 24, audio: Bool = true,
                     codec: [String] = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p"], audioCodec: [String] = ["-c:a", "aac", "-b:a", "128k"],
                     vf: String? = nil, noise: Int = 6, extra: [String] = []) throws -> URL {
        var args = ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=\(fps):duration=\(seconds)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)"] }
        args += ["-vf", (vf.map { $0 + "," } ?? "") + "noise=alls=\(noise):allf=t"]
        args += codec + (audio ? audioCodec : ["-an"]) + extra
        if audio { args += ["-shortest"] }
        return try make(fx, name, args)
    }

    /// Four quadrants: top-left red, top-right green, bottom-left blue, bottom-right yellow. 160x120 each (320x240 in all).
    static func card(_ fx: TestFixtures, _ name: String = "card.mp4", seconds: Double = 2, extra: [String] = []) throws -> URL {
        let cols = ["red", "green", "blue", "yellow"]
        var args: [String] = []
        for c in cols { args += ["-f", "lavfi", "-i", "color=c=\(c):s=160x120:r=24:d=\(seconds)"] }
        args += ["-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=\(seconds)"]
        args += ["-filter_complex", "[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack[v]", "-map", "[v]", "-map", "4:a",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "12", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-shortest"] + extra
        return try make(fx, name, args)
    }

    /// Letterboxed picture: 320x180 content with 30 black rows above and below.
    static func letterbox(_ fx: TestFixtures, _ name: String = "letterbox.mp4") throws -> URL {
        try clip(fx, name, size: "320x180", vf: "pad=320:240:0:30:black")
    }

    static func surround(_ fx: TestFixtures, _ name: String = "surround.mkv", codec: String = "ac3") throws -> URL {
        try make(fx, name, ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                           "-af", "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", codec, "-b:a", "384k", "-shortest"])
    }

    /// A clip with a stereo AAC track whose level swings (tremolo): for compressor and loudness tests.
    static func dynamic(_ fx: TestFixtures, _ name: String = "dynamic.mp4", seconds: Double = 3) throws -> URL {
        try make(fx, name, ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=\(seconds)", "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=\(seconds),volume=12dB,tremolo=f=0.6:d=0.95,pan=stereo|c0=c0|c1=c0",
                           "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest"])
    }

    /// Two audio tracks: English (440 Hz) and Russian (880 Hz), stereo, in MKV.
    static func multiAudio(_ fx: TestFixtures, _ name: String = "multi.mkv") throws -> URL {
        try make(fx, name, ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2,pan=stereo|c0=c0|c1=c0",
                           "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=2,pan=stereo|c0=c0|c1=c0", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264", "-preset", "veryfast",
                           "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=rus", "-metadata:s:a:0", "title=English", "-metadata:s:a:1", "title=Russian"])
    }

    /// Combed frames (two moving pictures interleaved).
    static func interlaced(_ fx: TestFixtures, _ name: String = "interlaced.mkv") throws -> URL {
        try make(fx, name, ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=50:duration=3", "-vf", "tinterlace=mode=interleave_top,fieldorder=tff", "-c:v", "libx264", "-preset", "veryfast",
                           "-crf", "16", "-flags", "+ilme+ildct", "-pix_fmt", "yuv420p", "-an"])
    }

    /// Variable frame rate: 30 fps in the first second, 10 fps after it.
    static func vfr(_ fx: TestFixtures, _ name: String = "vfr.mp4") throws -> URL {
        try make(fx, name, ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=3", "-vf", "select='lt(t,1)+not(mod(n,3))'", "-fps_mode", "passthrough", "-c:v", "libx264",
                           "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-an"])
    }

    static func tenBit(_ fx: TestFixtures, _ name: String = "tenbit.mkv") throws -> URL {
        try clip(fx, name, codec: ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-x265-params", "log-level=error"])
    }

    /// An odd-sized source (321x241) in a codec that accepts it.
    static func oddSize(_ fx: TestFixtures, _ name: String = "odd.mkv") throws -> URL {
        try clip(fx, name, size: "321x241", codec: ["-c:v", "mpeg4", "-q:v", "3", "-pix_fmt", "yuv420p"], audioCodec: ["-c:a", "libmp3lame", "-b:a", "128k"])
    }

    /// Phone footage: the picture is stored landscape with a 90 degree display matrix.
    static func rotated(_ fx: TestFixtures, from src: URL, _ name: String = "rotated.mp4") throws -> URL {
        try make(fx, name, ["-display_rotation", "90", "-i", src.path, "-c", "copy"])
    }

    static func withSubtitles(_ fx: TestFixtures, from src: URL, srt: URL, _ name: String = "subs.mkv", codec: String = "srt", lang: String = "eng") throws -> URL {
        try make(fx, name, ["-i", src.path, "-i", srt.path, "-map", "0", "-map", "1", "-c", "copy", "-c:s", codec, "-metadata:s:s:0", "language=\(lang)"])
    }

    static func withChapters(_ fx: TestFixtures, from src: URL, _ name: String = "chapters.mp4") throws -> URL {
        let meta = fx.url("chapters.ffmeta")
        let text = ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Intro\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=\u{0413}\u{043b}\u{0430}\u{0432}\u{0430} 2\n"
        try Data(text.utf8).write(to: meta)
        return try make(fx, name, ["-i", src.path, "-i", meta.path, "-map_metadata", "1", "-map_chapters", "1", "-c", "copy"])
    }

    // MARK: ffprobe (independent of MediaProbe)

    static func probe(_ url: URL) throws -> VTProbe {
        guard let fp = ffprobe else { throw TestSkip(reason: "ffprobe is not installed") }
        let text = run(fp, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path])
        guard let data = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "ffprobe could not read \(url.lastPathComponent): \(text.prefix(200))", file: #fileID, line: #line)
        }
        return VTProbe(json: j)
    }

    static func probeFrames(_ url: URL, entries: String = "frame=pict_type,pts_time,key_frame") throws -> [[String: String]] {
        guard let fp = ffprobe else { throw TestSkip(reason: "ffprobe is not installed") }
        let text = run(fp, ["-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of", "json", url.path])
        guard let data = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let frames = j["frames"] as? [[String: Any]] else { return [] }
        return frames.map { f in
            var d: [String: String] = [:]
            for (k, v) in f { d[k] = "\(v)" }
            return d
        }
    }

    // MARK: Pixels

    struct Frame { var w: Int; var h: Int; var rgb: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 3
            return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
        }
        var meanLuma: Double { var s = 0.0; for i in stride(from: 0, to: rgb.count - 2, by: 3) { s += 0.299 * Double(rgb[i]) + 0.587 * Double(rgb[i + 1]) + 0.114 * Double(rgb[i + 2]) }; return s / Double(max(1, rgb.count / 3)) }
        /// Sum of absolute horizontal+vertical differences per pixel: grows with sharpness and noise.
        var edgeEnergy: Double {
            var s = 0.0
            for y in 0..<(h - 1) { for x in 0..<(w - 1) {
                let a = pixel(x, y), b = pixel(x + 1, y), c = pixel(x, y + 1)
                s += Double(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) + abs(a.0 - c.0) + abs(a.1 - c.1) + abs(a.2 - c.2))
            } }
            return s / Double(max(1, (w - 1) * (h - 1)))
        }
        var lumaStdDev: Double {
            var s = 0.0, s2 = 0.0; let n = Double(max(1, rgb.count / 3))
            for i in stride(from: 0, to: rgb.count - 2, by: 3) { let y = 0.299 * Double(rgb[i]) + 0.587 * Double(rgb[i + 1]) + 0.114 * Double(rgb[i + 2]); s += y; s2 += y * y }
            return (s2 / n - (s / n) * (s / n)).squareRoot()
        }
        var meanRed: Double { var s = 0.0; for i in stride(from: 0, to: rgb.count - 2, by: 3) { s += Double(rgb[i]) }; return s / Double(max(1, rgb.count / 3)) }
        var meanBlue: Double { var s = 0.0; for i in stride(from: 2, to: rgb.count, by: 3) { s += Double(rgb[i]) }; return s / Double(max(1, rgb.count / 3)) }
        var meanSaturation: Double {
            var s = 0.0
            for i in stride(from: 0, to: rgb.count - 2, by: 3) { let m = Double(max(rgb[i], rgb[i + 1], rgb[i + 2])), n = Double(min(rgb[i], rgb[i + 1], rgb[i + 2])); s += m > 0 ? (m - n) / m : 0 }
            return s / Double(max(1, rgb.count / 3))
        }
    }

    /// Decodes the frame at `t` seconds (through a lossless PNG, so the size is the DISPLAY size) into RGB.
    static func frame(_ url: URL, at t: Double = 0, scale: String? = nil, autorotate: Bool = true) throws -> Frame {
        guard let ff = ffmpeg else { throw TestSkip(reason: "ffmpeg is not installed") }
        let out = url.deletingLastPathComponent().appendingPathComponent(".vt-frame-\(Util.hex8()).png")
        defer { try? FileManager.default.removeItem(at: out) }
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + (autorotate ? [] : ["-noautorotate"]) + ["-ss", "\(t)", "-i", url.path, "-frames:v", "1"]
        if let s = scale { args += ["-vf", s] }
        args += ["-an", "-sn", out.path]
        run(ff, args)
        guard let src = CGImageSourceCreateWithURL(out as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw TestFailure(message: "no frame at \(t) s in \(url.lastPathComponent)", file: #fileID, line: #line)
        }
        let w = img.width, h = img.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TestFailure(message: "cannot read the frame", file: #fileID, line: #line) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2] }
        return Frame(w: w, h: h, rgb: rgb)
    }

    /// The colours at the centres of the four quarters (top-left, top-right, bottom-left, bottom-right), named like the card's quadrants.
    static func quadrants(_ url: URL, at t: Double = 0.5, autorotate: Bool = true) throws -> [String] {
        let f = try frame(url, at: t, autorotate: autorotate)
        return [(f.w / 4, f.h / 4), (3 * f.w / 4, f.h / 4), (f.w / 4, 3 * f.h / 4), (3 * f.w / 4, 3 * f.h / 4)].map { quadrantColor(f.pixel($0.0, $0.1)) }
    }

    static func probeSize(_ url: URL) -> (Int, Int) {
        guard let fp = ffprobe else { return (0, 0) }
        let t = run(fp, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        let p = t.split(separator: "x").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (0, 0)
    }

    /// Nearest-colour name of an RGB triple among the card's four quadrant colours.
    static func quadrantColor(_ p: (Int, Int, Int)) -> String {
        let refs: [(String, (Int, Int, Int))] = [("red", (255, 0, 0)), ("green", (0, 128, 0)), ("blue", (0, 0, 255)), ("yellow", (255, 255, 0))]
        return refs.min { d($0.1, p) < d($1.1, p) }!.0
    }
    private static func d(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }

    // MARK: Metrics

    /// Average PSNR (dB) of `a` against `b` over the whole clips; `a` is scaled to `b`'s size.
    static func psnr(_ a: URL, _ b: URL) -> Double? {
        guard let ff = ffmpeg else { return nil }
        let (w, h) = probeSize(b)
        let text = run(ff, ["-hide_banner", "-nostdin", "-i", a.path, "-i", b.path, "-lavfi", "[0:v]scale=\(w):\(h):flags=bicubic[a];[a][1:v]psnr", "-f", "null", "-"])
        guard let r = text.range(of: #"average:([0-9.]+|inf)"#, options: .regularExpression) else { return nil }
        let v = text[r].dropFirst(8)
        return v == "inf" ? 99 : Double(v)
    }

    static func ssim(_ a: URL, _ b: URL) -> Double? {
        guard let ff = ffmpeg else { return nil }
        let (w, h) = probeSize(b)
        let text = run(ff, ["-hide_banner", "-nostdin", "-i", a.path, "-i", b.path, "-lavfi", "[0:v]scale=\(w):\(h):flags=bicubic[a];[a][1:v]ssim", "-f", "null", "-"])
        guard let r = text.range(of: #"All:([0-9.]+)"#, options: .regularExpression) else { return nil }
        return Double(text[r].dropFirst(4))
    }

    /// idet verdict over the whole clip: (interlaced frames, progressive frames).
    static func idet(_ url: URL) -> (interlaced: Int, progressive: Int) {
        guard let ff = ffmpeg else { return (0, 0) }
        let text = run(ff, ["-hide_banner", "-nostdin", "-i", url.path, "-vf", "idet", "-an", "-f", "null", "-"])
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.contains("Multi frame detection") }) else { return (0, 0) }
        func n(_ k: String) -> Int {
            guard let r = line.range(of: "\(k):\\s*(\\d+)", options: .regularExpression) else { return 0 }
            return Int(line[r].split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        return (n("TFF") + n("BFF"), n("Progressive"))
    }

    /// Integrated loudness (LUFS) and RMS (dB) of the first audio stream.
    static func loudness(_ url: URL) -> Double? {
        guard let ff = ffmpeg else { return nil }
        let text = run(ff, ["-hide_banner", "-nostdin", "-i", url.path, "-vn", "-af", "ebur128=framelog=quiet", "-f", "null", "-"])
        guard let summary = text.range(of: "Summary:", options: .backwards),
              let r = text.range(of: #"I:\s+(-?[0-9.]+) LUFS"#, options: .regularExpression, range: summary.lowerBound..<text.endIndex) else { return nil }
        return Double(text[r].replacingOccurrences(of: "I:", with: "").replacingOccurrences(of: "LUFS", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// Spread (dB) between the loudest and quietest momentary loudness readings (after the first half second): how much the level swings.
    static func momentarySpread(_ url: URL) -> Double? {
        guard let ff = ffmpeg else { return nil }
        let text = run(ff, ["-hide_banner", "-nostdin", "-v", "verbose", "-i", url.path, "-vn", "-af", "ebur128=framelog=verbose", "-f", "null", "-"])
        var values: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) where line.contains("t:") && line.contains(" M:") {
            guard let tr = line.range(of: #"t:\s*([0-9.]+)"#, options: .regularExpression), let t = Double(line[tr].dropFirst(2).trimmingCharacters(in: .whitespaces)), t > 0.5,
                  let mr = line.range(of: #"M:\s*(-?[0-9.]+)"#, options: .regularExpression), let m = Double(line[mr].dropFirst(2).trimmingCharacters(in: .whitespaces)), m > -100 else { continue }
            values.append(m)
        }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return hi - lo
    }

    /// Peak and RMS level (dB) of the whole first audio stream.
    static func peakAndRMS(_ url: URL) -> (peak: Double, rms: Double)? {
        guard let ff = ffmpeg else { return nil }
        let text = run(ff, ["-hide_banner", "-nostdin", "-i", url.path, "-vn", "-af", "astats=metadata=0", "-f", "null", "-"])
        guard let overall = text.range(of: "Overall", options: .backwards) else { return nil }
        func v(_ key: String) -> Double? {
            guard let r = text.range(of: "\(key):\\s*(-?[0-9.]+|-inf)", options: .regularExpression, range: overall.lowerBound..<text.endIndex) else { return nil }
            let s = text[r].components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return s == "-inf" ? -120 : Double(s)
        }
        guard let p = v("Peak level dB"), let r = v("RMS level dB") else { return nil }
        return (p, r)
    }

    static func rmsDB(_ url: URL, from: Double? = nil, duration: Double? = nil) -> Double? {
        guard let ff = ffmpeg else { return nil }
        var args = ["-hide_banner", "-nostdin"]
        if let f = from { args += ["-ss", "\(f)"] }
        if let d = duration { args += ["-t", "\(d)"] }
        args += ["-i", url.path, "-vn", "-af", "astats=metadata=0", "-f", "null", "-"]
        let text = run(ff, args)
        guard let overall = text.range(of: "Overall", options: .backwards),
              let r = text.range(of: #"RMS level dB:\s*(-?[0-9.]+|-inf)"#, options: .regularExpression, range: overall.lowerBound..<text.endIndex) else { return nil }
        let s = text[r].replacingOccurrences(of: "RMS level dB:", with: "").trimmingCharacters(in: .whitespaces)
        return s == "-inf" ? -120 : Double(s)
    }

    /// Bounding box (x0, y0, x1, y1) of the pixels whose summed colour difference exceeds `threshold`, and their mean difference; nil when the frames are equal.
    static func diffBox(_ a: URL, _ b: URL, at t: Double, threshold: Int = 60) throws -> (x0: Int, y0: Int, x1: Int, y1: Int, mean: Double, w: Int, h: Int)? {
        let fa = try frame(a, at: t), fb = try frame(b, at: t)
        guard fa.w == fb.w, fa.h == fb.h else { throw TestFailure(message: "frames differ in size \(fa.w)x\(fa.h) vs \(fb.w)x\(fb.h)", file: #fileID, line: #line) }
        var x0 = fa.w, y0 = fa.h, x1 = -1, y1 = -1, sum = 0.0, n = 0
        for y in 0..<fa.h { for x in 0..<fa.w {
            let p = fa.pixel(x, y), q = fb.pixel(x, y)
            let d = abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2)
            if d > threshold { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y); sum += Double(d); n += 1 }
        } }
        return n == 0 ? nil : (x0, y0, x1, y1, sum / Double(n), fa.w, fa.h)
    }

    /// Mean absolute difference between the picture at `t` of two clips (0...255), sizes must match.
    static func frameDifference(_ a: URL, _ b: URL, at t: Double) throws -> Double {
        let fa = try frame(a, at: t), fb = try frame(b, at: t)
        guard fa.w == fb.w, fa.h == fb.h else { return 255 }
        var s = 0.0
        for i in 0..<fa.rgb.count { s += Double(abs(Int(fa.rgb[i]) - Int(fb.rgb[i]))) }
        return s / Double(fa.rgb.count)
    }

    /// The first bytes of the file as hex-free ASCII markers: "ftyp", "mdat" / "moov" order for faststart.
    static func atomOrder(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        var order: [String] = []
        var offset: UInt64 = 0
        let end = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        while offset + 8 <= end, order.count < 12 {
            try? h.seek(toOffset: offset)
            guard let d = try? h.read(upToCount: 8), d.count == 8 else { break }
            var size = UInt64(d[0]) << 24 | UInt64(d[1]) << 16 | UInt64(d[2]) << 8 | UInt64(d[3])
            order.append(String(decoding: d[4..<8], as: UTF8.self))
            if size == 1, let e = try? h.read(upToCount: 8), e.count == 8 { size = e.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            if size < 8 { break }
            offset += size
        }
        return order
    }

    // MARK: Running operations

    @MainActor
    static func op(_ id: String) throws -> PerFileOperation {
        let all = VideoCatalog.operations()
        guard let o = all.first(where: { $0.meta.id == id }) as? PerFileOperation else { throw TestFailure(message: "no operation \(id)", file: #fileID, line: #line) }
        return o
    }

    /// Runs an operation on one file with extra option overrides over its quick recipe; returns the outputs. The job temp folder is cleaned.
    @MainActor
    static func run(_ id: String, _ input: URL, set: OptionValues = [:], mode: RunMode = .quick, rules: OutputRules = OutputRules()) async throws -> OperationResult {
        let o = try op(id)
        let items = [FileItem(url: input)]
        let ctx = OperationContext.testing(o, items: items, extra: set, mode: mode, rules: rules)
        if ProcessInfo.processInfo.environment["SC_VT_LOG"] != nil { ctx.onLog = { out("    log: \($0)") } }
        defer { ctx.cleanupTemp() }
        return try await o.execute(items: items, ctx: ctx)
    }

    @MainActor
    static func convert(_ id: String = "video.to.mp4", _ input: URL, _ set: OptionValues = [:]) async throws -> URL {
        let r = try await run(id, input, set: set, mode: .studio)
        guard let u = r.outputs.first else { throw TestFailure(message: "\(id) produced no output", file: #fileID, line: #line) }
        return u
    }
}

enum VTFile {
    static func size(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
}

/// Plans and argv without encoding: a MediaInfo made by hand, the machine's real toolset, options resolved against the schema.
enum VTPlan {
    static func info(video: String = "h264", w: Int = 1920, h: Int = 1080, fps: Double = 30, duration: Double = 60, pix: String = "yuv420p", depth: Int = 8, rotation: Int = 0, hdr: Bool = false,
                     interlaced: Bool = false, audio: [(codec: String, ch: Int, lang: String?)] = [("aac", 2, nil)], subs: [(codec: String, lang: String?)] = [], container: String = "mp4",
                     chapters: Int = 0) -> MediaInfo {
        var m = MediaInfo(url: URL(fileURLWithPath: "/tmp/source.\(container)"), container: container, duration: duration, bitRate: 8_000_000, size: 60_000_000)
        var v = MediaStreamInfo(kind: .video, index: 0, codec: video)
        v.width = w; v.height = h; v.fps = fps; v.maxFps = fps; v.pixelFormat = pix; v.bitDepth = depth; v.rotation = rotation; v.isHDR = hdr; v.interlaced = interlaced
        v.fieldOrder = interlaced ? "tt" : "progressive"; v.colorTransfer = hdr ? "smpte2084" : "bt709"; v.colorPrimaries = hdr ? "bt2020" : "bt709"; v.colorSpace = hdr ? "bt2020nc" : "bt709"
        m.streams = [v]
        for (n, a) in audio.enumerated() {
            var s = MediaStreamInfo(kind: .audio, index: 1 + n, codec: a.codec); s.channels = a.ch; s.sampleRate = 48000; s.language = a.lang; s.bitRate = 160_000
            m.streams.append(s)
        }
        for (n, t) in subs.enumerated() {
            var s = MediaStreamInfo(kind: .subtitle, index: 1 + audio.count + n, codec: t.codec); s.language = t.lang
            m.streams.append(s)
        }
        for c in 0..<chapters { m.chapters.append(MediaChapterInfo(start: Double(c) * 10, end: Double(c + 1) * 10, title: "Chapter \(c + 1)")) }
        return m
    }

    static func resolve(_ quick: OptionValues = [:], _ set: OptionValues = [:], info: MediaInfo? = nil) -> ResolvedOptions {
        let source = info.map { MediaProbe.sourceInfo(from: $0, kind: .video) }
        return VideoSchemas.convert(items: []).resolve(layers: [quick, set], source: source)
    }

    static func plan(_ set: OptionValues = [:], quick: OptionValues = [:], info: MediaInfo? = nil, analysis: VideoAnalysis = VideoAnalysis(), toolset: MediaToolset? = nil, hardware: Bool = false) throws -> VideoEncodePlan {
        // Option capabilities (encoders, filters) are read from the installed ffmpeg when options resolve: without it these tests have nothing to compare.
        if !Capabilities.shared.has("tool.ffmpeg") { throw TestSkip(reason: "ffmpeg is not installed") }
        let i = info ?? Self.info()
        return try VideoPlanBuilder.build(options: resolve(quick, set, info: i), source: i, analysis: analysis, toolset: toolset ?? MediaToolset.detect(), preferHardware: hardware)
    }

    /// The complete argv of the (last) command for a plan, with fixed input/output names.
    static func argv(_ set: OptionValues = [:], quick: OptionValues = [:], info: MediaInfo? = nil, analysis: VideoAnalysis = VideoAnalysis(), pass: Int = -1) throws -> [String] {
        let p = try plan(set, quick: quick, info: info, analysis: analysis)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vt-argv-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cmds = try VideoFFmpegArgs.commands(for: p, input: URL(fileURLWithPath: "/in/source.\(info?.container ?? "mp4")"), output: URL(fileURLWithPath: "/out/result.\(p.container)"), tempDirectory: tmp)
        return (pass >= 0 ? cmds[pass] : cmds.last!).arguments()
    }
}
