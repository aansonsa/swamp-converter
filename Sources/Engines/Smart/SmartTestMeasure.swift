import Foundation

/// Independent measuring tools of the smart self-tests: quality (SSIM / PSNR through ffmpeg filters, frame-aligned), stream fingerprints (md5 of
/// the copied packets), top-level MP4 atoms, file type sniffing (`file --mime-type`) and fixtures with specific properties. None of this code is
/// used by the engine, so a test that passes proves the engine's work with a different method than the one that wrote the file.
extension SK {
    // MARK: Quality

    struct Similarity: Sendable {
        var ssim: Double
        var psnr: Double
        var frames: Int
    }

    /// SSIM (mean of the per-frame "All" value) and PSNR (mean of the per-frame average, identical frames count as 100 dB) of `out` against `src`.
    /// Both streams are aligned frame by frame (`setpts=N/FRAME_RATE/TB`), `out` is scaled to `size` (the source size) when it differs, and both sides
    /// are compared as 10-bit 4:2:0 so an 8-bit and a 10-bit file can be measured against each other.
    static func similarity(_ out: URL, _ src: URL, size: (Int, Int)? = nil, in dir: URL) async throws -> Similarity {
        let s = dir.appendingPathComponent("ssim-\(UUID().uuidString.prefix(6)).log")
        let p = dir.appendingPathComponent("psnr-\(UUID().uuidString.prefix(6)).log")
        let scale = size.map { ",scale=\($0.0):\($0.1):flags=bicubic" } ?? ""
        let a = "[0:v:0]setpts=N/FRAME_RATE/TB\(scale),format=yuv420p10le"
        let b = "[1:v:0]setpts=N/FRAME_RATE/TB,format=yuv420p10le"
        func q(_ u: URL) -> String { u.path.replacingOccurrences(of: ":", with: "\\:") }
        try await ffmpeg(["-i", out.path, "-i", src.path, "-lavfi", "\(a)[x];\(b)[y];[x][y]ssim=stats_file=\(q(s))", "-f", "null", "-"])
        try await ffmpeg(["-i", out.path, "-i", src.path, "-lavfi", "\(a)[x];\(b)[y];[x][y]psnr=stats_file=\(q(p))", "-f", "null", "-"])
        func values(_ url: URL, key: String) -> [Double] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
                for part in line.split(separator: " ") where part.hasPrefix(key + ":") {
                    let v = String(part.dropFirst(key.count + 1))
                    return v == "inf" ? 100 : Double(v)
                }
                return nil
            }
        }
        let ss = values(s, key: "All"), ps = values(p, key: "psnr_avg")
        try? FileManager.default.removeItem(at: s); try? FileManager.default.removeItem(at: p)
        guard !ss.isEmpty, !ps.isEmpty else { throw TestFailure(message: "ffmpeg produced no SSIM / PSNR values", file: #fileID, line: #line) }
        return Similarity(ssim: ss.reduce(0, +) / Double(ss.count), psnr: ps.reduce(0) { $0 + min($1, 100) } / Double(ps.count), frames: ss.count)
    }

    // MARK: Fingerprints

    /// md5 of the first video (or audio) stream's packets: equal md5 = the stream was copied bit for bit.
    static func streamMD5(_ url: URL, audio: Bool = false, index: Int = 0) async throws -> String {
        let out = try await ffmpeg(["-i", url.path, "-map", "0:\(audio ? "a" : "v"):\(index)", "-c", "copy", "-f", "md5", "-"], captureStdout: true)
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of video packets / frames the container holds (independent of what the planner expected).
    static func packetCount(_ url: URL) async -> Int {
        let obj = await ffprobeJSON(url, ["-count_packets", "-select_streams", "v:0"])
        let s = (obj["streams"] as? [[String: Any]])?.first ?? [:]
        return Int(str(s, "nb_read_packets")) ?? 0
    }

    /// The two streams are the same bit for bit (a copy): equal md5 of their packets.
    static func expectSameStream(_ a: URL, _ b: URL, audio: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) async throws {
        let x = try await streamMD5(a, audio: audio), y = try await streamMD5(b, audio: audio)
        try expectEqual(x, y, message.isEmpty ? "the \(audio ? "audio" : "video") packets must be identical" : message, file: file, line: line)
    }

    /// AVFoundation opens the result AND the built-in verification (frames decoded at the start, middle and end) passed.
    static func expectPlayable(_ r: SmartTranscodeResult, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) async throws {
        let judge = r.verification?.judge ?? "none"
        if SmartContainer.isQuickTimeFamily(r.plan.container) {
            let ok = await avfPlayable(r.url)
            try expect(ok, "AVFoundation says not playable. \(message)", file: file, line: line)
        }
        try expect(r.verification?.passed == true, "verification (\(judge)) failed: \(r.verification?.problems ?? ["no verdict"]). \(message)", file: file, line: line)
    }

    /// The first audio track decoded to 32-bit float PCM at 48 kHz (interleaved), read from a temp file next to the media.
    static func pcmFloats(_ url: URL, in dir: URL) async throws -> [Float] {
        let raw = dir.appendingPathComponent("pcm-\(UUID().uuidString.prefix(6)).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await ffmpeg(["-i", url.path, "-map", "0:a:0", "-ar", "48000", "-c:a", "pcm_f32le", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: Container

    /// Top-level boxes of an ISO base media file in order ("ftyp", "moov", "mdat", ...): reads headers only, never the payload.
    static func topLevelBoxes(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        var boxes: [String] = []
        var offset: UInt64 = 0
        let end = (try? h.seekToEnd()) ?? 0
        while offset + 8 <= end, boxes.count < 64 {
            try? h.seek(toOffset: offset)
            guard let head = try? h.read(upToCount: 16), head.count >= 8 else { break }
            let b = [UInt8](head)
            var size = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
            boxes.append(String(decoding: b[4..<8], as: UTF8.self))
            if size == 1, b.count >= 16 { size = b[8...15].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            if size == 0 { break }
            offset += size
        }
        return boxes
    }

    /// `file --mime-type -b`: a third opinion about what a file really is (ffprobe is the second, the magic bytes the first).
    static func mimeType(_ url: URL) -> String {
        guard let out = ProcessProbe.run(URL(fileURLWithPath: "/usr/bin/file"), ["--mime-type", "-b", url.path]) else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fixtures

    /// Tags written into the container of a generated clip, used by the strip tests.
    static let sourceTags = ["location": "+56.9496+024.1052/", "com.apple.quicktime.model": "iPhone Test", "title": "Private holiday"]

    /// VP9 + Opus in WebM, 640x360 by default (the typical downloaded source).
    static func vp9(_ fx: TestFixtures, _ name: String = "vp9.webm", size: String = "640x360", seconds: Double = 2, fps: Int = 24, audio: Bool = true,
                    pix: String = "yuv420p") async throws -> URL {
        try await clip(fx, name, size: size, fps: fps, seconds: seconds, pixFmt: pix,
                       video: ["-c:v", "libvpx-vp9", "-pix_fmt", pix, "-b:v", "0", "-crf", "30", "-deadline", "realtime", "-cpu-used", "8"],
                       audio: audio ? ["-c:a", "libopus"] : nil)
    }

    /// A hard-to-encode VP9 clip (moving test pattern + strong temporal noise): grain costs bits, so quality targets mean something on it.
    static func noisyVP9(_ fx: TestFixtures, _ name: String = "noisy.webm", size: String = "1280x720", seconds: Double = 2, fps: Int = 30) async throws -> URL {
        try await clip(fx, name, size: size, fps: fps, seconds: seconds, filter: "noise=alls=10:allf=t+u", pixFmt: "yuv420p",
                       video: ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-deadline", "realtime", "-cpu-used", "8"], audio: ["-c:a", "libopus"])
    }

    /// H.264 + AAC (eng) + Opus (rus) + SRT subtitle in MKV, 320x240, 2 s: one file with every kind of track the planner treats differently.
    static func multiTrack(_ fx: TestFixtures, _ name: String = "multi.mkv") async throws -> URL {
        let srt = try fx.srt(cues: [TestFixtures.Cue(start: 0.2, end: 0.9, text: "Ahoj"), TestFixtures.Cue(start: 1.0, end: 1.8, text: "Привет, мир")])
        let out = fx.url(name)
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=2", "-f", "lavfi", "-t", "2", "-i", "anoisesrc=color=pink:sample_rate=48000:amplitude=0.3",
                          "-f", "lavfi", "-t", "2", "-i", "sine=frequency=660:sample_rate=48000", "-i", srt.path,
                          "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", "libx264", "-preset", "ultrafast", "-c:a:0", "aac", "-c:a:1", "libopus",
                          "-c:s", "srt", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=rus", out.path])
        return out
    }

    /// True when the file contains `marker` (x265 writes its version string into every stream; hardware encoders do not).
    static func containsMarker(_ url: URL, _ marker: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return data.range(of: Data(marker.utf8)) != nil
    }

    /// ffprobe stream bit rate in bit/s (0 when unknown).
    static func bitRate(_ stream: [String: Any]) -> Double { Double(str(stream, "bit_rate")) ?? 0 }

    /// HDR10 (PQ, BT.2020, mastering display + light level) VP9 10-bit in WebM: the side data travels in the Matroska colour element.
    static func hdr10VP9(_ fx: TestFixtures, _ name: String = "hdr10.webm", seconds: Double = 2) async throws -> URL {
        let hevc = try await clip(fx, "hdr10-seed.mp4", seconds: seconds, pixFmt: "yuv420p10le",
                                  video: ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-x265-params",
                                          "log-level=error:hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:"
                                          + "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"],
                                  audio: nil)
        let out = fx.url(name)
        try await ffmpeg(["-i", hevc.path, "-f", "lavfi", "-t", "\(seconds)", "-i", "sine=frequency=330:sample_rate=48000", "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p10le",
                          "-b:v", "0", "-crf", "30", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus", "-shortest", out.path])
        return out
    }
}

/// Tiny synchronous process helper for the sniffing tools (output small, tool fast).
enum ProcessProbe {
    static func run(_ exe: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
