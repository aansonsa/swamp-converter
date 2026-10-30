import Foundation

// Sharper conformance oracles for the audio operations Core's default audio oracle does not judge (Compress, Normalize, Trim, Join) plus Ogg.
// Core's `ConformanceOracles.audioConvert` already covers the seven Convert sectors (lossless sample-exact, lossy above an SNR floor and as good as
// afconvert / LAME at the same size); these add what the tools promise: smaller and never worse, the loudness really hit, the range really cut, the join
// really at the best rate and layout. Every comparison decodes the source and the result with decoders that are not the code that wrote the file.

enum AudioConformance {
    static func register() {
        let r = ConformanceRegistry.shared
        r.add(oggOracle); r.add(compressOracle); r.add(normalizeOracle); r.add(trimOracle); r.add(joinOracle)
    }

    // MARK: Shared helpers

    @MainActor
    static func afconvert(_ fx: ConformanceFixtures, _ source: URL, kbps: Int, name: String) -> URL? {
        let out = fx.url(name)
        let r = ExternalProbe.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", String(kbps * 1000), source.path, out.path], timeout: 120)
        return r.status == 0 ? out : nil
    }

    /// The signal scaled by `gain` (a quiet recording for the loudness oracle).
    @MainActor
    static func scaledChirp(_ fx: ConformanceFixtures, name: String, gain: Double, seconds: Double = 8, rate: Int = 44_100) throws -> URL {
        let pcm = fx.chirpSamples(seconds: seconds, rate: rate, channels: 2).map { Int16(max(-32768, min(32767, (Double($0) * gain).rounded()))) }
        return try fx.writeWAV(name, samples: pcm, channels: 2, rate: rate)
    }

    /// Integrated loudness: ffmpeg's ebur128 when present (not this module's meter), else our meter on the decoded file.
    static func lufs(_ url: URL) -> Double? {
        if let l = AudTestKit.loudness(url) { return l.lufs }
        guard let s = AudioFidelity.decode(url) else { return nil }
        let meter = AudLoudnessMeter(rate: Int(s.sampleRate), channels: s.channelCount)
        meter.feed(s.channels)
        return meter.integratedLUFS
    }

    static func sig(_ s: AudioSamples) -> AudSig { AudSig(rate: Int(s.sampleRate), ch: s.channels) }

    /// Gain-invariant SNR of `test` against `ref` (decoded, same rate) after alignment.
    static func snr(_ ref: AudioSamples, _ test: AudioSamples) -> Double? {
        AudTestKit.fidelity(ref: sig(ref).mono(), test: sig(test).mono())?.snr
    }

    // MARK: Ogg

    /// Ogg Vorbis is judged with ffmpeg's decoder: CoreAudio's own Vorbis decoder (what `AudioFidelity.decode` tries first) reads some valid libvorbis streams
    /// wrongly (a mono 22.05 kHz file decodes with correlation 0.15 there and 0.9999 in ffmpeg), so it cannot referee. Without ffmpeg the default oracle runs.
    static let oggOracle = ConformanceOracle(
        id: "audio.ogg", priority: 100, match: { $0.id == "audio.to.ogg" }, timeout: 300,
        cases: { meta, fx in try await ConformanceOracles.audioConvert.cases(meta, fx) },
        verify: { run in
            guard AudTestKit.ffmpeg != nil else { try await ConformanceOracles.verifyAudioConvert(run); return }
            let out = try run.sole()
            let sniffed = try unwrap(FormatSniffer.sniff(out))
            try expectEqual(sniffed.key, "ogg", "an .ogg file holds Ogg Vorbis, not Opus: \(sniffed)")
            let fp = try unwrap(AudTestKit.probe(out), "ffprobe cannot read the result")
            try expectEqual(fp.codec, "vorbis")
            guard let ref = AudioFidelity.decode(run.input), let got = AudTestKit.decode(out, in: run.workDir) else { throw run.fail("cannot decode the source or the result") }
            try expectEqual(got.channels, ref.channelCount, "channels")
            try expectEqual(got.rate, Int(ref.sampleRate), "sample rate")
            try expect(abs(got.seconds - ref.duration) <= 0.02, String(format: "duration %.3f s vs source %.3f s", got.seconds, ref.duration))
            let f = try unwrap(AudTestKit.fidelity(ref: sig(ref).mono(), test: got.mono()), "cannot align")
            try expect(f.snr >= 16, String(format: "Vorbis q5 SNR %.1f dB is below the 16 dB floor", f.snr))
            run.note(String(format: "Vorbis %d kbit/s, SNR %.1f dB (decoded by ffmpeg)", fp.bitRate / 1000, f.snr))
        },
        proves: "an Ogg Vorbis stream (never Opus under an .ogg name), decoded by ffmpeg to the same sound above the Vorbis SNR floor")

    // MARK: Compress

    static let compressOracle = ConformanceOracle(
        id: "audio.compress", priority: 100, match: { $0.id == "audio.compress" }, timeout: 300,
        cases: { _, fx in
            let wav = try fx.chirp("track.wav", seconds: 4)
            var cases = [ConformanceCase(label: "wav", inputs: [wav])]
            if let heavy = afconvert(fx, wav, kbps: 256, name: "heavy.m4a") { cases.append(ConformanceCase(label: "m4a-heavy", inputs: [heavy])) }
            if let mp3 = fx.audioVariant(of: wav, ext: "mp3") { cases.append(ConformanceCase(label: "mp3", inputs: [mp3])) }
            if let compact = afconvert(fx, wav, kbps: 64, name: "compact.m4a") { cases.append(ConformanceCase(label: "m4a-compact", inputs: [compact])) }
            return cases
        },
        verify: { run in
            let out = try run.sole()
            let inKey = Formats.key(of: run.input), outKey = Formats.key(of: out)
            guard let ref = AudioFidelity.decode(run.input), let got = AudioFidelity.decode(out) else { throw run.fail("cannot decode the source or the result") }
            if run.testCase.label == "m4a-compact" {
                try expect(try Data(contentsOf: out) == Data(contentsOf: run.input), "a 64 kbit/s file is already compact: it must be kept byte for byte, not squeezed again")
                try expect(run.log.contains { $0.contains("already compact") }, "the person is told it was kept: \(run.log)")
                run.note("kept as it is (declared pass-through)")
                return
            }
            try expect(TestFile.size(out) < TestFile.size(run.input), "compress made the file bigger: \(TestFile.size(run.input)) -> \(TestFile.size(out)) B")
            if inKey == "wav" { try expectEqual(outKey, "m4a", "a lossless source becomes AAC"); try expect(TestFile.size(out) * 4 < TestFile.size(run.input), "WAV -> AAC must shrink by more than 4x") }
            else { try expectEqual(outKey, inKey, "the format family is kept") }
            try expect(abs(got.duration - ref.duration) <= 0.07, "duration changed: \(ref.duration) -> \(got.duration)")
            try expectEqual(got.channelCount, ref.channelCount, "channels")
            guard let s = snr(ref, got) else { throw run.fail("cannot align the result with the source") }
            // Compressing an already lossy file adds a second generation of damage; the floor is lower for it.
            try expect(s >= (inKey == "wav" ? 18 : 10), String(format: "SNR %.1f dB is too low for a 128 kbit/s result", s))
            run.note(String(format: "%d -> %d B, SNR %.1f dB", TestFile.size(run.input), TestFile.size(out), s))
        },
        proves: "smaller than the source and never an MP3 re-encode of a smaller file: heavy files shrink within their family at high fidelity, a compact file is kept byte for byte and said so")

    // MARK: Normalize

    static let normalizeOracle = ConformanceOracle(
        id: "audio.normalize", priority: 100, match: { $0.id == "audio.normalize" }, timeout: 300,
        cases: { _, fx in
            let quiet = try scaledChirp(fx, name: "quiet.wav", gain: 0.05)
            var cases = [ConformanceCase(label: "wav", inputs: [quiet])]
            if let m4a = afconvert(fx, quiet, kbps: 256, name: "quiet.m4a") { cases.append(ConformanceCase(label: "m4a", inputs: [m4a])) }
            return cases
        },
        verify: { run in
            let out = try run.sole()
            guard let ref = AudioFidelity.decode(run.input), let got = AudioFidelity.decode(out) else { throw run.fail("cannot decode the source or the result") }
            let before = try unwrap(lufs(run.input), "cannot measure the source"), after = try unwrap(lufs(out), "cannot measure the result")
            try expect(before < -28, "the fixture should be quiet, it measures \(before) LUFS")
            try expect(abs(after + 16) <= 1.0, String(format: "integrated loudness %.1f LUFS is not within 1 LU of -16 (source %.1f)", after, before))
            try expectEqual(Formats.key(of: out), Formats.key(of: run.input), "the format is kept")
            try expect(abs(got.duration - ref.duration) <= 0.07, "duration changed")
            try expect(Double(AudioFidelity.peak(got)) <= 0.95, "normalising must not clip: peak \(AudioFidelity.peak(got))")
            guard let s = snr(ref, got) else { throw run.fail("cannot align the result with the source") }
            try expect(s >= (run.testCase.label == "wav" ? 30 : 14), String(format: "the sound itself must be unchanged apart from level: gain-free SNR %.1f dB", s))
            run.note(String(format: "%.1f -> %.1f LUFS, SNR %.1f dB", before, after, s))
        },
        proves: "the integrated loudness (measured by ffmpeg's ebur128) lands within 1 LU of -16 LUFS, without clipping, and the waveform is the source's apart from the gain")

    // MARK: Trim

    static let trimOracle = ConformanceOracle(
        id: "audio.trim", priority: 100, match: { $0.id == "audio.trim" }, timeout: 300,
        cases: { _, fx in
            let wav = try fx.chirp("long.wav", seconds: 4)
            let cut: OptionValues = [AudioKeys.trimStart: 0.5, AudioKeys.trimEnd: 2.0]
            var cases = [ConformanceCase(label: "wav", inputs: [wav], extra: cut)]
            if let m4a = afconvert(fx, wav, kbps: 256, name: "long.m4a") { cases.append(ConformanceCase(label: "m4a", inputs: [m4a], extra: cut)) }
            return cases
        },
        verify: { run in
            let out = try run.sole()
            guard let ref = AudioFidelity.decode(run.input), let got = AudioFidelity.decode(out) else { throw run.fail("cannot decode the source or the result") }
            let lossy = run.testCase.label != "wav"
            try expectEqual(Formats.key(of: out), Formats.key(of: run.input), "the format is kept")
            try expect(abs(got.duration - 1.5) <= (lossy ? 0.07 : 0.001), String(format: "kept %.4f s, asked for 1.5 s (start 0.5, end 2.0)", got.duration))
            let rate = Int(ref.sampleRate)
            let slice = AudioSamples(sampleRate: ref.sampleRate, channels: ref.channels.map { Array($0[(rate / 2)..<min($0.count, rate * 2)]) }, decoder: ref.decoder)
            if lossy {
                guard let s = snr(slice, got) else { throw run.fail("cannot align the result with the asked range") }
                try expect(s >= 15, String(format: "the kept part is not the asked range: SNR %.1f dB", s))
                run.note(String(format: "1.5 s kept, SNR %.1f dB", s))
            } else {
                let r = AudioFidelity.bitExact(slice, got)
                try expect(r.equal, "the kept part must be the original samples 0.5 s ... 2.0 s: \(r.detail)")
                run.note("sample-exact slice (\(r.detail))")
            }
        },
        proves: "exactly the asked range (start 0.5 s, end 2.0 s as an absolute time) is kept: sample-exact for lossless, same waveform for lossy")

    // MARK: Join

    static let joinOracle = ConformanceOracle(
        id: "audio.join", priority: 100, match: { $0.id == "audio.concat" }, timeout: 300,
        cases: { _, fx in
            let mono = try fx.chirp("a mono.wav", seconds: 1, rate: 44_100, channels: 1, seed: 21)
            let stereo = try fx.chirp("b stereo.wav", seconds: 2, rate: 48_000, channels: 2, seed: 22)
            let s1 = try fx.chirp("c.wav", seconds: 1.5, rate: 44_100, channels: 2, seed: 23)
            let s2 = try fx.chirp("d.wav", seconds: 1.0, rate: 44_100, channels: 2, seed: 24)
            return [ConformanceCase(label: "mixed-rates", inputs: [mono, stereo]), ConformanceCase(label: "same-format", inputs: [s1, s2])]
        },
        verify: { run in
            let out = try run.sole()
            guard let got = AudioFidelity.decode(out) else { throw run.fail("cannot decode the result") }
            let parts = try run.inputs.map { u -> AudioSamples in try unwrap(AudioFidelity.decode(u), "cannot decode \(u.lastPathComponent)") }
            let total = parts.reduce(0.0) { $0 + $1.duration }
            try expect(abs(got.duration - total) <= 0.02, String(format: "joined %.3f s, the parts add up to %.3f s", got.duration, total))
            let bestRate = parts.map(\.sampleRate).max() ?? 0
            try expectClose(got.sampleRate, bestRate, tolerance: 0.5, "the rate must be the best of the inputs, not the first file's")
            try expectEqual(got.channelCount, parts.map(\.channelCount).max() ?? 1, "the layout must be the best of the inputs")
            // Each part, in natural order of the file names, is where it should be and sounds like itself.
            var offset = 0
            for (i, p) in parts.enumerated() {
                var want = p
                if abs(p.sampleRate - got.sampleRate) > 0.5 { want = try unwrap(AudioFidelity.resampled(p, to: got.sampleRate), "resample") }
                if want.channelCount != got.channelCount { want.channels = want.channels.map { $0 } + Array(repeating: want.channels[0], count: got.channelCount - want.channelCount) }
                let n = want.frames
                guard offset + n <= got.frames else { throw run.fail("part \(i + 1) runs past the end of the result") }
                let seg = AudioSamples(sampleRate: got.sampleRate, channels: got.channels.map { Array($0[offset..<(offset + n)]) }, decoder: got.decoder)
                let edge = Int(got.sampleRate / 10)
                let inner = { (s: AudioSamples) in AudioSamples(sampleRate: s.sampleRate, channels: s.channels.map { Array($0[edge..<($0.count - edge)]) }, decoder: s.decoder) }
                let s = try unwrap(snr(inner(want), inner(seg)), "cannot compare part \(i + 1)")
                try expect(s >= 30, String(format: "part %d (%@) is damaged in the join: SNR %.1f dB", i + 1, run.inputs[i].lastPathComponent, s))
                offset += n
            }
            try expect(run.returned.first.map { $0.lastPathComponent.hasPrefix(run.inputs[0].deletingPathExtension().lastPathComponent) } ?? false, "named after the first sorted file")
            run.note("\(Int(got.sampleRate)) Hz, \(got.channelCount) ch, \(String(format: "%.3f", got.duration)) s")
        },
        proves: "the parts follow each other in natural order, each sounds like its source, at the best sample rate and channel layout of the inputs and the exact total length")
}
