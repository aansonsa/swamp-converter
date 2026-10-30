import Foundation
import AVFoundation

// Shared helpers of the audio self-tests: realistic synthetic signals (chirps with a moving envelope plus noise, never a flat tone),
// an independent decoder (ffmpeg to float WAV, parsed here by hand), an independent probe (ffprobe), format sniffing by magic bytes,
// and the metrics the oracles use (aligned SNR, RMS, loudness through ffmpeg's ebur128, dominant frequency).

/// A decoded signal: channels x frames of floats in -1...1.
struct AudSig {
    var rate: Int
    var ch: [[Float]]
    var frames: Int { ch.first?.count ?? 0 }
    var channels: Int { ch.count }
    var seconds: Double { rate > 0 ? Double(frames) / Double(rate) : 0 }
    func mono() -> [Float] {
        guard channels > 1 else { return ch.first ?? [] }
        return (0..<frames).map { i in ch.reduce(Float(0)) { $0 + $1[i] } / Float(channels) }
    }
}

/// What ffprobe says about a file (read straight from its JSON, independent of the module's own parser).
struct AudFP {
    var formatName = "", codec = "", profile = ""
    var rate = 0, channels = 0, bitRate = 0, streams = 0
    var duration = 0.0
    var tags: [String: String] = [:]
    var hasPicture = false
    var bitsPerSample = 0
}

enum AudTestKit {
    static var ffmpeg: URL? { ToolLocator.shared.url(.ffmpeg) }
    static var ffprobe: URL? { ToolLocator.shared.url(.ffprobe) }

    // MARK: Signals

    /// A chirp from `f0` to `f1` with a 3 Hz tremolo and white noise. Channel c is shifted in pitch and noise so channels differ.
    static func chirp(seconds: Double, rate: Int, channels: Int = 1, seed: UInt64 = 7, f0: Double = 220, f1: Double = 3_200,
                      amplitude: Float = 0.4, noise: Float = 0.02) -> AudSig {
        let frames = Int(seconds * Double(rate))
        var out: [[Float]] = []
        for c in 0..<channels {
            var rng = SplitMix(seed: seed &+ UInt64(c) &* 1_000_003)
            let shift = 1 + 0.31 * Double(c)
            var x = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let t = Double(i) / Double(rate)
                let phase = 2 * Double.pi * shift * (f0 * t + (f1 - f0) * t * t / (2 * max(seconds, 0.001)))
                let env = 1 + 0.3 * sin(2 * Double.pi * 3 * t)
                let n = (Float(rng.next() >> 40) / Float(1 << 24) - 0.5) * 2 * noise
                x[i] = amplitude * Float(env / 1.3 * sin(phase)) + n
            }
            out.append(x)
        }
        return AudSig(rate: rate, ch: out)
    }

    /// A pure sine (rate / pitch / fade tests need a known frequency).
    static func sine(seconds: Double, rate: Int, channels: Int = 1, frequency: Double = 1_000, amplitude: Float = 0.5) -> AudSig {
        let frames = Int(seconds * Double(rate))
        let one = (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double(($0)) / Double(rate))) }
        return AudSig(rate: rate, ch: Array(repeating: one, count: channels))
    }

    /// Speech-like burst pattern: 0.5 s of noise-modulated tone, 0.5 s of near silence, repeated (silence and loudness tests).
    static func silencePadded(core: AudSig, lead: Double, tail: Double) -> AudSig {
        let l = Int(lead * Double(core.rate)), t = Int(tail * Double(core.rate))
        return AudSig(rate: core.rate, ch: core.ch.map { [Float](repeating: 0, count: l) + $0 + [Float](repeating: 0, count: t) })
    }

    // MARK: WAV (written and parsed by hand)

    /// `bits`: 16 or 24 (integer PCM) or 32 (float).
    @discardableResult
    static func writeWAV(_ sig: AudSig, to url: URL, bits: Int = 16) throws -> URL {
        let n = sig.frames, ch = sig.channels, bytes = bits / 8
        var pcm = Data(capacity: n * ch * bytes)
        for i in 0..<n {
            for c in 0..<ch {
                let v = max(-1, min(1, sig.ch[c][i]))
                switch bits {
                case 32: withUnsafeBytes(of: v.bitPattern.littleEndian) { pcm.append(contentsOf: $0) }
                case 24:
                    let s = Int32((Double(v) * 8_388_607).rounded())
                    pcm.append(UInt8(truncatingIfNeeded: s)); pcm.append(UInt8(truncatingIfNeeded: s >> 8)); pcm.append(UInt8(truncatingIfNeeded: s >> 16))
                default:
                    let s = Int16((Double(v) * 32_767).rounded())
                    withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
                }
            }
        }
        var d = Data()
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(x).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(bits == 32 ? 3 : 1); u16(ch); u32(sig.rate); u32(sig.rate * ch * bytes); u16(ch * bytes); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count); d.append(pcm)
        try d.write(to: url)
        return url
    }

    /// Parses a RIFF WAVE (PCM 8/16/24/32, float 32/64, extensible) into floats. Nil when it is not one.
    static func parseWAV(_ url: URL) -> AudSig? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF" || String(decoding: data[0..<4], as: UTF8.self) == "RF64",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        var pos = 12
        var tag = 0, channels = 0, rate = 0, bits = 0
        while pos + 8 <= data.count {
            let id = String(decoding: data[pos..<pos + 4], as: UTF8.self)
            var size = u32(pos + 4)
            let body = pos + 8
            if id == "fmt " {
                tag = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if tag == 0xFFFE, size >= 26 { tag = u16(body + 24) }
            } else if id == "data" {
                if size == 0xFFFF_FFFF || body + size > data.count { size = data.count - body }
                guard channels > 0, bits > 0 else { return nil }
                let bytes = bits / 8, frames = size / (channels * bytes)
                var out = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
                data.withUnsafeBytes { raw in
                    let p = raw.baseAddress!.advanced(by: body)
                    for i in 0..<frames { for c in 0..<channels {
                        let o = (i * channels + c) * bytes
                        let q = p.advanced(by: o)
                        var v: Float = 0
                        switch (tag, bits) {
                        case (3, 32): v = Float(bitPattern: q.loadUnaligned(as: UInt32.self).littleEndian)
                        case (3, 64): v = Float(Double(bitPattern: q.loadUnaligned(as: UInt64.self).littleEndian))
                        case (_, 8): v = (Float(q.load(as: UInt8.self)) - 128) / 128
                        case (_, 16): v = Float(Int16(littleEndian: q.loadUnaligned(as: Int16.self))) / 32_768
                        case (_, 24):
                            let b0 = Int32(q.load(as: UInt8.self)), b1 = Int32(q.load(fromByteOffset: 1, as: UInt8.self)), b2 = Int32(q.load(fromByteOffset: 2, as: UInt8.self))
                            var s = b0 | b1 << 8 | b2 << 16
                            if s & 0x80_0000 != 0 { s |= ~0xFF_FFFF }
                            v = Float(s) / 8_388_608
                        case (_, 32): v = Float(Int32(littleEndian: q.loadUnaligned(as: Int32.self))) / 2_147_483_648
                        default: break
                        }
                        out[c][i] = v
                    } }
                }
                return AudSig(rate: rate, ch: out)
            }
            pos = body + size + (size & 1)
        }
        return nil
    }

    // MARK: Independent decode and probe

    /// Synchronous capture of a tool's stdout and stderr (short commands only).
    static func capture(_ exe: URL, _ args: [String]) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = exe; p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch { return (-1, Data(), "\(error)") }
        let outData = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        return (p.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
    }

    /// Decodes any audio file into floats at its own rate and channel count. ffmpeg (independent of this module) when present, else AVAudioFile.
    static func decode(_ url: URL, in dir: URL) -> AudSig? {
        if let ff = ffmpeg {
            let tmp = dir.appendingPathComponent("decoded-\(Util.hex8()).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = capture(ff, ["-v", "error", "-nostdin", "-y", "-i", url.path, "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "wav", tmp.path])
            if r.status == 0, let s = parseWAV(tmp) { return s }
        }
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let n = AVAudioFrameCount(f.length)
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n), (try? f.read(into: b)) != nil, let d = b.floatChannelData else { return nil }
        let ch = (0..<Int(f.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: d[$0], count: Int(b.frameLength))) }
        return AudSig(rate: Int(f.processingFormat.sampleRate), ch: ch)
    }

    static func probe(_ url: URL) -> AudFP? {
        guard let fp = ffprobe else { return nil }
        let r = capture(fp, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "--", url.path])
        guard r.status == 0, let root = (try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any] else { return nil }
        var out = AudFP()
        let format = root["format"] as? [String: Any] ?? [:]
        out.formatName = format["format_name"] as? String ?? ""
        out.duration = Double(format["duration"] as? String ?? "") ?? 0
        out.streams = Int(format["nb_streams"] as? Int ?? 0)
        for (k, v) in format["tags"] as? [String: Any] ?? [:] { if let s = v as? String { out.tags[k.lowercased()] = s } }
        for s in root["streams"] as? [[String: Any]] ?? [] {
            if s["codec_type"] as? String == "video", (s["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1 { out.hasPicture = true }
            guard s["codec_type"] as? String == "audio", out.codec.isEmpty else { continue }
            out.codec = s["codec_name"] as? String ?? ""
            out.profile = s["profile"] as? String ?? ""
            out.rate = Int(s["sample_rate"] as? String ?? "") ?? 0
            out.channels = s["channels"] as? Int ?? 0
            out.bitRate = Int(s["bit_rate"] as? String ?? "") ?? Int(format["bit_rate"] as? String ?? "") ?? 0
            let declared = (s["bits_per_sample"] as? Int) ?? 0
            out.bitsPerSample = declared > 0 ? declared : (Int(s["bits_per_raw_sample"] as? String ?? "") ?? 0)
            if let sd = Double(s["duration"] as? String ?? ""), out.duration == 0 { out.duration = sd }
            for (k, v) in s["tags"] as? [String: Any] ?? [:] { if let str = v as? String, out.tags[k.lowercased()] == nil { out.tags[k.lowercased()] = str } }
        }
        return out
    }

    /// The real format by magic bytes: wav, aiff, flac, ogg, mp3, m4a, caf, ac3, unknown.
    static func sniff(_ url: URL) -> String {
        let m = TestFile.magic(url, 16)
        guard m.count >= 4 else { return "unknown" }
        let s4 = String(decoding: m[0..<4], as: UTF8.self)
        if s4 == "RIFF" || s4 == "RF64" { return "wav" }
        if s4 == "FORM" { return "aiff" }
        if s4 == "fLaC" { return "flac" }
        if s4 == "OggS" { return "ogg" }
        if s4 == "caff" { return "caf" }
        if m.count >= 8, String(decoding: m[4..<8], as: UTF8.self) == "ftyp" { return "m4a" }
        if s4.hasPrefix("ID3") { return "mp3" }
        if m[0] == 0xFF, m[1] & 0xE0 == 0xE0 { return "mp3" }
        if m[0] == 0x0B, m[1] == 0x77 { return "ac3" }
        return "unknown"
    }

    /// `file --mime-type` as a second, separate sniffer.
    static func mime(_ url: URL) -> String {
        let r = capture(URL(fileURLWithPath: "/usr/bin/file"), ["--mime-type", "-b", url.path])
        return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Progress line in the test log (diagnostics while calibrating thresholds).
    static func debug(_ s: String) { out("      \(s)") }

    // MARK: Metrics

    /// `test` brought to `rate` with CoreAudio's mastering-grade converter (Opus always decodes at 48 kHz).
    static func resampled(_ test: AudSig, to rate: Int) -> AudSig? {
        if test.rate == rate { return test }
        let samples = AudioSamples(sampleRate: Double(test.rate), channels: test.ch, decoder: "test")
        guard let r = AudioFidelity.resampled(samples, to: Double(rate)) else { return nil }
        return AudSig(rate: rate, ch: r.channels)
    }

    struct Fidelity { var lag: Int; var snr: Double; var gain: Double }

    /// Gain-invariant SNR of `test` against `ref` (both mono, same rate) after finding the delay by cross-correlation (codecs add a delay).
    static func fidelity(ref: [Float], test: [Float], maxLag: Int = 4_096, skip: Int = 3_000) -> Fidelity? {
        guard ref.count > 20_000, test.count > 20_000 else { return nil }
        let start = ref.count / 3, window = min(24_000, ref.count - start - maxLag - 10)
        guard window > 4_000, start + window + maxLag < test.count else { return nil }
        func dot(_ lag: Int, step: Int) -> Double {
            var s = 0.0
            var i = 0
            while i < window { s += Double(ref[start + i]) * Double(test[start + i + lag]); i += step }
            return s
        }
        var best = 0, bestV = -Double.infinity
        var lag = -maxLag
        while lag <= maxLag { let v = dot(lag, step: 4); if v > bestV { bestV = v; best = lag }; lag += 2 }
        for l in (best - 3)...(best + 3) { let v = dot(l, step: 1); if v > bestV { bestV = v; best = l } }
        let from = max(skip, -best + skip), to = min(ref.count - skip, test.count - best - skip)
        guard to - from > 8_000 else { return nil }
        var rr = 0.0, tr = 0.0
        for i in from..<to { let r = Double(ref[i]), t = Double(test[i + best]); rr += r * r; tr += r * t }
        guard rr > 0 else { return nil }
        let g = tr / rr
        var sig = 0.0, err = 0.0
        for i in from..<to { let r = Double(ref[i]) * g, t = Double(test[i + best]); sig += r * r; err += (t - r) * (t - r) }
        return Fidelity(lag: best, snr: err > 0 ? 10 * log10(sig / err) : 200, gain: g)
    }

    static func rms(_ x: [Float], from: Int, to: Int) -> Double {
        let a = max(0, from), b = min(x.count, to)
        guard b > a else { return 0 }
        var s = 0.0
        for i in a..<b { s += Double(x[i]) * Double(x[i]) }
        return sqrt(s / Double(b - a))
    }

    static func peakDB(_ sig: AudSig) -> Double {
        let p = sig.ch.map { $0.map { abs(Double($0)) }.max() ?? 0 }.max() ?? 0
        return p > 0 ? 20 * log10(p) : -200
    }

    /// Dominant frequency of a clean tone by counting rising zero crossings over the middle of the signal.
    static func dominantFrequency(_ sig: AudSig) -> Double {
        let x = sig.mono()
        let a = x.count / 4, b = x.count * 3 / 4
        var crossings = 0
        var first = -1, last = -1
        for i in (a + 1)..<b where x[i - 1] < 0 && x[i] >= 0 { crossings += 1; if first < 0 { first = i }; last = i }
        guard crossings > 2, last > first else { return 0 }
        return Double(crossings - 1) * Double(sig.rate) / Double(last - first)
    }

    /// Integrated loudness (LUFS) and sample peak (dBFS) measured by ffmpeg's ebur128, an implementation independent of the module's meter.
    static func loudness(_ url: URL) -> (lufs: Double, peak: Double, lra: Double)? {
        guard let ff = ffmpeg else { return nil }
        let r = capture(ff, ["-hide_banner", "-nostdin", "-nostats", "-i", url.path, "-af", "ebur128=peak=sample", "-f", "null", "-"])
        guard let summary = r.err.range(of: "Summary:", options: .backwards) else { return nil }
        let tail = String(r.err[summary.upperBound...])
        func number(_ pattern: String) -> Double? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                  let r = Range(m.range(at: 1), in: tail) else { return nil }
            return Double(tail[r])
        }
        guard let i = number(#"\bI:\s+(-?\d+(?:\.\d+)?)\s+LUFS"#) else { return nil }
        return (i, number(#"\bPeak:\s+(-?\d+(?:\.\d+)?)\s+dBFS"#) ?? 0, number(#"\bLRA:\s+(-?\d+(?:\.\d+)?)\s+LU"#) ?? 0)
    }

    // MARK: Running operations

    struct Run { var outputs: [URL]; var log: [String] }

    /// Runs `op` on `files` the way the job runner does, with the quick recipe plus `extra` options. `.studio` mode so the "already in this
    /// format" shortcut of quick runs does not skip identity conversions.
    @MainActor
    static func run(_ op: Operation, _ files: [URL], _ extra: OptionValues = OptionValues(), mode: RunMode = .studio,
                    tools: ToolLocator = .shared, rules: OutputRules = OutputRules()) async throws -> Run {
        let items = files.map { FileItem(url: $0, isDirectory: false) }
        let schema = op.optionSchema(for: items)
        let resolved = schema.resolve(layers: [op.quickOverrides(settings: SettingsData()), extra])
        let ctx = OperationContext(operationID: op.meta.id, mode: mode, resolved: resolved, outputRules: rules, settings: SettingsData(), tools: tools)
        let log = Locked<[String]>([])
        ctx.onLog = { line in log.withLock { $0.append(line) } }
        defer { ctx.cleanupTemp() }
        let result = try await op.execute(items: items, ctx: ctx)
        return Run(outputs: result.outputs, log: log.value)
    }

    /// Channel mode in the first MPEG audio frame header of an MP3: 0 stereo, 1 joint stereo, 2 dual channel, 3 mono.
    static func mp3ChannelMode(_ url: URL) -> Int? {
        let b = TestFile.magic(url, 8192)
        var i = 0
        if b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { i = 10 + (Int(b[6]) << 21 | Int(b[7]) << 14 | Int(b[8]) << 7 | Int(b[9])) }
        let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], rates = [44_100, 48_000, 32_000]
        var frames: [Int] = []
        while i + 4 < b.count, frames.count < 3 {
            if b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 {
                frames.append(i)
                // MPEG-1 Layer III only (the fixtures are 44.1 / 48 kHz): the frame length gets us to the next header.
                let br = Int(b[i + 2] >> 4), sr = Int((b[i + 2] >> 2) & 3)
                guard (b[i + 1] >> 3) & 3 == 3, br > 0, br < 15, sr < 3 else { break }
                i += 144 * bitrates[br] * 1000 / rates[sr] + Int((b[i + 2] >> 1) & 1)
            } else { i += 1 }
        }
        // The first frame is LAME's Info / Xing frame, which always says plain stereo: read the first audio frame.
        guard let f = frames.count > 1 ? frames[1] : frames.first else { return nil }
        return Int(b[f + 3] >> 6) & 3
    }

    /// Where in `whole` the `length` samples of `part` starting at `at` appear exactly (within `tolerance`); nil when nowhere.
    static func exactOffset(of part: [Float], at: Int, length: Int, in whole: [Float], tolerance: Float = 1e-6) -> Int? {
        guard at + length <= part.count else { return nil }
        let probe = part[at..<(at + length)]
        var k = 0
        let first = part[at]
        while k + length <= whole.count {
            if abs(whole[k] - first) <= tolerance {
                var ok = true
                for j in 0..<length where abs(whole[k + j] - probe[at + j]) > tolerance { ok = false; break }
                if ok { return k - at }
            }
            k += 1
        }
        return nil
    }

    /// The ID3v2 major version of an MP3 (3 or 4), nil when there is no ID3v2 header.
    static func id3Version(_ url: URL) -> Int? {
        let b = TestFile.magic(url, 4)
        return b.count == 4 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 ? Int(b[3]) : nil
    }

    /// Environment override for one block of a test (simulates a Mac without some encoder or tool). Always restores.
    @MainActor
    static func withEnvironment<T>(_ env: AudEnvironment, _ body: () async throws -> T) async rethrows -> T {
        // Capabilities caches the answers ("can this Mac write MP3?"); a simulated Mac must not leak into the tests that follow.
        AudEnvironment.testOverride.value = env
        Capabilities.shared.invalidate()
        defer { AudEnvironment.testOverride.value = nil; Capabilities.shared.invalidate() }
        return try await body()
    }

    /// Starts the operation, cancels it after `after` seconds and reports how the run ended and how long the cancel took to take effect.
    @MainActor
    static func runCancelling(_ op: Operation, _ files: [URL], _ extra: OptionValues = OptionValues(), after: TimeInterval) async throws -> (error: Error?, seconds: TimeInterval) {
        let task = Task { @MainActor in try await run(op, files, extra) }
        try await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
        let t0 = Date()
        task.cancel()
        var failure: Error?
        do { _ = try await task.value } catch { failure = error }
        return (failure, Date().timeIntervalSince(t0))
    }

    /// A long WAV made by repeating one second of `pattern` (fast to write: the header, then the same bytes again and again).
    @discardableResult
    static func writeLongWAV(pattern: AudSig, repeating times: Int, to url: URL) throws -> URL {
        let one = try writeWAV(pattern, to: url.deletingLastPathComponent().appendingPathComponent(".pattern-\(Util.hex8()).wav"))
        defer { try? FileManager.default.removeItem(at: one) }
        let data = try Data(contentsOf: one)
        let pcm = data.subdata(in: 44..<data.count)
        let total = pcm.count * times
        var header = Data(data.subdata(in: 0..<44))
        func put(_ x: Int, at o: Int) { for i in 0..<4 { header[o + i] = UInt8((x >> (8 * i)) & 0xFF) } }
        put(36 + total, at: 4); put(total, at: 40)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.write(contentsOf: header)
        for _ in 0..<times { try h.write(contentsOf: pcm) }
        return url
    }

    /// True when no process has `needle` (a unique path) on its command line.
    static func noProcess(mentioning needle: String) -> Bool {
        let r = capture(URL(fileURLWithPath: "/bin/ps"), ["-axo", "command"])
        return !String(decoding: r.out, as: UTF8.self).contains(needle)
    }

    /// Largest absolute sample difference of two equally long signals (inf when shapes differ).
    static func maxDiff(_ a: AudSig, _ b: AudSig) -> Double {
        guard a.channels == b.channels, a.frames == b.frames else { return .infinity }
        var m = 0.0
        for c in 0..<a.channels { for i in 0..<a.frames { m = max(m, abs(Double(a.ch[c][i]) - Double(b.ch[c][i]))) } }
        return m
    }

    @MainActor
    static func operation(_ id: String) throws -> Operation {
        try unwrap(AudioCatalog.operations().first { $0.meta.id == id }, "no operation \(id)")
    }

    /// Operations whose encoders this Mac lacks are skipped by the callers through this.
    static func needs(_ tool: Tool) throws {
        if !ToolLocator.shared.has(tool) { try skipTest("\(tool.displayName) is not installed") }
    }

    static func needsEncoder(_ name: String) throws {
        try needs(.ffmpeg)
        if !AudEnvironment.current().encoders.contains(name) { try skipTest("this ffmpeg has no \(name) encoder") }
    }
}
