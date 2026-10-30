import Foundation

// "Ours must be as good or better than a reference encoder at the same file size."
// A reference encoder (sips, cwebp, afconvert, ffmpeg) is run over a range of quality settings; the two settings whose outputs bracket OUR file size give,
// by interpolation, the quality the reference reaches at our size. Ours must reach at least that, within a small tolerance.

enum ReferenceParity {
    struct Point { var param: Int; var bytes: Int64; var metric: Double }

    struct Verdict {
        var ours: Double
        var reference: Double
        var lower: Point
        var upper: Point
        var tolerance: Double
        var passes: Bool { ours >= reference - tolerance }
        var summary: String { String(format: "ours %.2f vs reference %.2f at the same size (reference settings %d to %d)", ours, reference, lower.param, upper.param) }
    }

    /// `render(param)` encodes with the reference at that setting and returns the file (nil if it failed); `metric(file)` scores it against the source.
    /// Sizes must grow with `param`. Returns nil when the reference cannot reach our size within `range` (then no judgement is made).
    static func compare(oursBytes: Int64, oursMetric: Double, range: ClosedRange<Int>, tolerance: Double,
                        render: (Int) -> URL?, metric: (URL) -> Double?) -> Verdict? {
        var cache: [Int: Point] = [:]
        func point(_ p: Int) -> Point? {
            if let c = cache[p] { return c }
            guard let u = render(p), let m = metric(u) else { return nil }
            let pt = Point(param: p, bytes: TestFile.size(u), metric: m)
            cache[p] = pt
            return pt
        }
        var lo = range.lowerBound, hi = range.upperBound
        guard let pLo = point(lo), let pHi = point(hi), pLo.bytes <= oursBytes, pHi.bytes >= oursBytes else {
            // Ours is smaller than the reference's smallest or larger than its largest: compare with the nearest end instead of skipping silently.
            guard let a = point(range.lowerBound), let b = point(range.upperBound) else { return nil }
            let nearest = oursBytes < a.bytes ? a : b
            return Verdict(ours: oursMetric, reference: nearest.metric, lower: nearest, upper: nearest, tolerance: tolerance)
        }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            guard let m = point(mid) else { return nil }
            if m.bytes <= oursBytes { lo = mid } else { hi = mid }
        }
        guard let a = point(lo), let b = point(hi) else { return nil }
        let t = b.bytes == a.bytes ? 0 : Double(oursBytes - a.bytes) / Double(b.bytes - a.bytes)
        let ref = a.metric + (b.metric - a.metric) * min(1, max(0, t))
        return Verdict(ours: oursMetric, reference: ref, lower: a, upper: b, tolerance: tolerance)
    }

    // MARK: Reference encoders

    /// JPEG by the system's sips (ImageIO/AppleJPEG): `quality` 1...100.
    static func sipsJPEG(_ source: URL, quality: Int, into dir: URL) -> URL? {
        let out = dir.appendingPathComponent("ref-sips-\(quality).jpg")
        let r = ExternalProbe.run("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", String(quality), source.path, "--out", out.path], timeout: 30)
        return r.status == 0 ? out : nil
    }

    /// WebP by libwebp's cwebp: `quality` 1...100, default method 4.
    static func cwebp(_ source: URL, quality: Int, into dir: URL) -> URL? {
        guard let exe = ExternalProbe.path(.cwebp) else { return nil }
        let out = dir.appendingPathComponent("ref-cwebp-\(quality).webp")
        let r = ExternalProbe.run(exe, ["-quiet", "-q", String(quality), source.path, "-o", out.path], timeout: 30)
        return r.status == 0 ? out : nil
    }

    /// AAC in M4A by Apple's afconvert at a fixed bit rate (kbit/s).
    static func afconvertAAC(_ source: URL, kbps: Int, into dir: URL) -> URL? {
        let out = dir.appendingPathComponent("ref-afconvert-\(kbps).m4a")
        let r = ExternalProbe.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", String(kbps * 1000), source.path, out.path], timeout: 60)
        return r.status == 0 ? out : nil
    }

    /// MP3 by LAME at VBR quality `q` (0 best ... 9 smallest) when the lame tool exists, else ffmpeg's libmp3lame.
    static func lameVBR(_ source: URL, q: Int, into dir: URL) -> URL? {
        let out = dir.appendingPathComponent("ref-lame-\(q).mp3")
        if let lame = ExternalProbe.path(.lame) {
            let r = ExternalProbe.run(lame, ["--silent", "-V", String(q), source.path, out.path], timeout: 60)
            if r.status == 0 { return out }
        }
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", source.path, "-c:a", "libmp3lame", "-q:a", String(q), out.path], timeout: 60)
        return r.status == 0 ? out : nil
    }

    /// H.264 by ffmpeg's libx264 at a constant rate factor (preset medium, yuv420p).
    static func x264(_ source: URL, crf: Int, into dir: URL) -> URL? {
        guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { return nil }
        let out = dir.appendingPathComponent("ref-x264-\(crf).mp4")
        let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", source.path, "-an", "-c:v", "libx264", "-preset", "medium", "-crf", String(crf), "-pix_fmt", "yuv420p", out.path], timeout: 300)
        return r.status == 0 ? out : nil
    }
}
