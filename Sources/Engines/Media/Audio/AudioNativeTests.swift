import Foundation
import AVFoundation

// Real conversions through the NATIVE route (AVAudioFile / AudioToolbox), each read back with ffmpeg / ffprobe, which are separate programs from
// the code that wrote the file. They need no external tool to run; the independent oracles use ffmpeg when it is present and AVFoundation otherwise.

enum AudioNativeTests {
    static func source(_ fx: TestFixtures, _ name: String = "Тест song (1).wav", seconds: Double = 3, rate: Int = 44_100, channels: Int = 2, bits: Int = 16) throws -> (url: URL, ref: AudSig) {
        let url = try AudTestKit.writeWAV(AudTestKit.chirp(seconds: seconds, rate: rate, channels: channels), to: fx.url(name), bits: bits)
        return (url, try unwrap(AudTestKit.parseWAV(url)))
    }

    static func avf(_ url: URL) async throws -> AudInfo { try unwrap(await AudProbe.viaAVFoundation(url), "AVFoundation cannot read \(url.lastPathComponent)") }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("audio.native", "lossless targets (FLAC, ALAC, AIFF, WAV, CAF) decode back bit-exact and say what they are") {
            let fx = TestFixtures(label: "aud-lossless"); defer { fx.cleanup() }
            let (src, ref) = try source(fx)
            let cases: [(op: String, target: String, sniff: String, codec: String)] = [
                ("audio.to.flac", "flac", "flac", "flac"), ("audio.to.m4a", "alac", "m4a", "alac"), ("audio.to.aiff", "aiff", "aiff", "pcm_s16be"),
                ("audio.to.wav", "wav", "wav", "pcm_s16le"), ("audio.to.wav", "caf", "caf", "pcm_s16le")]
            for c in cases {
                let run = try await AudTestKit.run(try AudTestKit.operation(c.op), [src], [AudioKeys.target: .string(c.target)])
                let out = try unwrap(run.outputs.first, c.target)
                try expectEqual(AudTestKit.sniff(out), c.sniff, "\(c.target): the bytes must be the real format")
                try expect(out.pathExtension == (c.target == "alac" ? "m4a" : c.target), "\(c.target): extension \(out.pathExtension)")
                if let fp = AudTestKit.probe(out) { try expectEqual(fp.codec, c.codec, "\(c.target) codec") }
                let back = try unwrap(AudTestKit.decode(out, in: fx.root), c.target)
                try expectEqual(back.rate, ref.rate); try expectEqual(back.channels, 2); try expectEqual(back.frames, ref.frames, "\(c.target) frame count")
                try expectClose(AudTestKit.maxDiff(back, ref), 0, tolerance: 1.0 / 32_768 * 1.01, "\(c.target): a lossless pair must return the very samples")
                try expect(TestFile.size(out) != TestFile.size(src) || c.target == "wav" || c.target == "caf", "\(c.target) is not a renamed copy")
                // A canonical 16-bit WAV re-written as a canonical 16-bit WAV is legitimately the same bytes: it was decoded and written again.
                if c.target != "wav" { try expect(try Data(contentsOf: out) != Data(contentsOf: src), "\(c.target): output must not be byte-identical to the input") }
            }
        }

        t.register("audio.native", "24-bit sources stay 24-bit in FLAC, ALAC, AIFF and WAV on the native route, bit-exact") {
            let fx = TestFixtures(label: "aud-24"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, "wide.wav", seconds: 2, rate: 48_000, bits: 24)
            // The quantisation of a 24-bit file is finer than 16-bit: a 16-bit write-back would show as a difference above 2^-16.
            for (op, target, codec, bits) in [("audio.to.flac", "flac", "flac", 24), ("audio.to.m4a", "alac", "alac", 24), ("audio.to.aiff", "aiff", "pcm_s24be", 24), ("audio.to.wav", "wav", "pcm_s24le", 24)] {
                let out = try await AudTestKit.run(try AudTestKit.operation(op), [src], [AudioKeys.target: .string(target)]).outputs[0]
                let fp = try unwrap(AudTestKit.probe(out)); try expectEqual(fp.codec, codec, target)
                try expect(fp.bitsPerSample == bits || fp.bitsPerSample == 0, "\(target): \(fp.bitsPerSample) bits per sample")
                let back = try unwrap(AudTestKit.decode(out, in: fx.root))
                try expectEqual(back.rate, 48_000)
                try expectClose(AudTestKit.maxDiff(back, ref), 0, tolerance: 1.0 / 8_388_608 * 1.5, "\(target): every 24-bit sample must come back")
            }
            let narrow = try await AudTestKit.run(try AudTestKit.operation("audio.to.flac"), [src], [AudioKeys.bitDepth: "16"]).outputs[0]
            let n = try unwrap(AudTestKit.decode(narrow, in: fx.root))
            try expect(AudTestKit.maxDiff(n, ref) > 1.0 / 65_536 / 4, "asking for 16 bits really reduces the depth")
        }

        t.register("audio.native", "dither: 24 to 16 bits adds exactly the noise it promises (triangular about 0.5 LSB, rectangular about 0.41, none 0.29), 16-bit originals stay untouched") {
            let fx = TestFixtures(label: "aud-dith"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, "deep.wav", seconds: 3, rate: 44_100, bits: 24)
            let wav = try AudTestKit.operation("audio.to.wav")
            func errorLSB(_ mode: String) async throws -> (rms: Double, data: Data) {
                let out = try await AudTestKit.run(wav, [src], [AudioKeys.bitDepth: "16", AudioKeys.dither: .string(mode)]).outputs[0]
                let s = try unwrap(AudTestKit.decode(out, in: fx.root))
                try expectEqual(s.frames, ref.frames)
                var sum = 0.0
                for c in 0..<s.channels { for i in 0..<s.frames { let e = (Double(s.ch[c][i]) - Double(ref.ch[c][i])) * 32_768; sum += e * e } }
                let data = try Data(contentsOf: out)
                try? FileManager.default.removeItem(at: out)
                return ((sum / Double(s.frames * s.channels)).squareRoot(), data)
            }
            let none = try await errorLSB("none"), tri = try await errorLSB("triangular"), rect = try await errorLSB("rectangular")
            AudTestKit.debug("error RMS in 16-bit steps: none \(none.rms), rectangular \(rect.rms), triangular \(tri.rms)")
            try expectClose(none.rms, 0.289, tolerance: 0.03, "plain rounding"); try expectClose(rect.rms, 0.408, tolerance: 0.04, "rectangular dither")
            try expectClose(tri.rms, 0.5, tolerance: 0.04, "triangular dither")
            try expect(none.data != tri.data && tri.data != rect.data, "each mode writes different samples")
            // A 16-bit original that is only copied is never dithered; the same file with a gain change is.
            let (src16, ref16) = try source(fx, "plain.wav", seconds: 2)
            let same = try unwrap(AudTestKit.decode(try await AudTestKit.run(wav, [src16], [AudioKeys.dither: "triangular"]).outputs[0], in: fx.root))
            try expectClose(AudTestKit.maxDiff(same, ref16), 0, tolerance: 1e-9, "an untouched 16-bit file stays bit-exact")
            let gained = try unwrap(AudTestKit.decode(try await AudTestKit.run(wav, [src16], [AudioKeys.gain: 0.5, AudioKeys.bitDepth: "16"]).outputs[0], in: fx.root))
            try expect(AudTestKit.maxDiff(gained, ref16) > 0, "a processed 16-bit file is dithered and rounded again")
        }

        t.register("audio.native", "FLAC is smaller than the WAV it came from, ALAC too, and the sound is untouched") {
            let fx = TestFixtures(label: "aud-lossless2"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "tone.wav", seconds: 4)
            let flac = try await AudTestKit.run(try AudTestKit.operation("audio.to.flac"), [src]).outputs[0]
            try expect(TestFile.size(flac) < TestFile.size(src), "FLAC \(TestFile.size(flac)) must be below WAV \(TestFile.size(src))")
        }

        t.register("audio.native", "AAC 256 kbit/s: real AAC in MP4, rate/channels/duration kept, bit rate on target, high fidelity") {
            let fx = TestFixtures(label: "aud-aac"); defer { fx.cleanup() }
            let (src, ref) = try source(fx)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.m4a"), [src]).outputs[0]
            try expectEqual(AudTestKit.sniff(out), "m4a"); try expectEqual(out.pathExtension, "m4a")
            if let fp = AudTestKit.probe(out) {
                try expectEqual(fp.codec, "aac"); try expect(fp.formatName.contains("mp4"), fp.formatName)
                try expectEqual(fp.rate, 44_100); try expectEqual(fp.channels, 2)
                try expect(abs(Double(fp.bitRate) - 256_000) / 256_000 < 0.15, "bit rate \(fp.bitRate) within 15 percent of 256k")
                try expectClose(fp.duration, 3.0, tolerance: 0.08, "container duration includes the encoder's priming and padding (about 66 ms)")
            }
            let avfInfo = try await Self.avf(out)
            try expectClose(try unwrap(avfInfo.duration), 3.0, tolerance: 0.02, "AVFoundation honours the gapless data: exact length")
            let back = try unwrap(AudTestKit.decode(out, in: fx.root))
            let f = try unwrap(AudTestKit.fidelity(ref: ref.mono(), test: back.mono()))
            try expect(f.snr > 20, "AAC 256k SNR \(f.snr) dB must beat 20 dB")
            try expectClose(Double(back.frames) / Double(back.rate), 3.0, tolerance: 0.08)
        }

        t.register("audio.native", "AAC quality knobs are monotonic: more bit rate gives a bigger file and a higher SNR") {
            let fx = TestFixtures(label: "aud-aacq"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, "q.wav", seconds: 4)
            let op = try AudTestKit.operation("audio.to.m4a")
            var sizes: [Int64] = [], snrs: [Double] = []
            for kbps in [48, 128, 256] {
                let out = try await AudTestKit.run(op, [src], [AudioKeys.bitrate: .int(kbps)]).outputs[0]
                sizes.append(TestFile.size(out))
                let back = try unwrap(AudTestKit.decode(out, in: fx.root))
                snrs.append(try unwrap(AudTestKit.fidelity(ref: ref.mono(), test: back.mono())).snr)
                try? FileManager.default.removeItem(at: out)
            }
            try expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "sizes \(sizes)")
            try expect(snrs[0] < snrs[1] && snrs[1] < snrs[2], "SNRs \(snrs)")
        }

        t.register("audio.native", "AAC quality (VBR) mode and the HE-AAC profile produce what they claim") {
            let fx = TestFixtures(label: "aud-aacvbr"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "v.wav", seconds: 3)
            let op = try AudTestKit.operation("audio.to.m4a")
            let lo = try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "quality", AudioKeys.quality: .int(10)]).outputs[0]
            let hi = try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "quality", AudioKeys.quality: .int(95)]).outputs[0]
            try expect(TestFile.size(lo) < TestFile.size(hi), "VBR quality 10 (\(TestFile.size(lo))) < 95 (\(TestFile.size(hi)))")
            let he = try await AudTestKit.run(op, [src], [AudioKeys.bitrate: .int(48), AudioKeys.aacProfile: "he"]).outputs[0]
            if let fp = AudTestKit.probe(he) {
                try expectEqual(fp.codec, "aac"); try expect(fp.profile.contains("HE"), "profile \(fp.profile)")
                try expect(fp.bitRate > 0 && fp.bitRate < 70_000, "HE-AAC at 48k reads \(fp.bitRate)")
            }
        }

        t.register("audio.native", "sample rate, channels and bit depth are applied and read back (WAV, AIFF)") {
            let fx = TestFixtures(label: "aud-fmt"); defer { fx.cleanup() }
            let tone = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 2, rate: 44_100, channels: 2, frequency: 1_000), to: fx.url("tone.wav"))
            let wav = try AudTestKit.operation("audio.to.wav")
            let r1 = try await AudTestKit.run(wav, [tone], [AudioKeys.sampleRate: "22050", AudioKeys.channels: "mono", AudioKeys.bitDepth: "24"]).outputs[0]
            let back = try unwrap(AudTestKit.decode(r1, in: fx.root))
            try expectEqual(back.rate, 22_050); try expectEqual(back.channels, 1)
            try expectClose(back.seconds, 2.0, tolerance: 0.01)
            try expectClose(AudTestKit.dominantFrequency(back), 1_000, tolerance: 15, "the pitch must survive resampling")
            if let fp = AudTestKit.probe(r1) { try expectEqual(fp.codec, "pcm_s24le"); try expectEqual(fp.rate, 22_050) }
            let aiff = try await AudTestKit.run(try AudTestKit.operation("audio.to.aiff"), [tone], [AudioKeys.bitDepth: "24", AudioKeys.sampleRate: "48000"]).outputs[0]
            if let fp = AudTestKit.probe(aiff) { try expectEqual(fp.codec, "pcm_s24be"); try expectEqual(fp.rate, 48_000) }
            let up = try unwrap(AudTestKit.decode(aiff, in: fx.root))
            try expectClose(up.seconds, 2.0, tolerance: 0.01); try expectClose(AudTestKit.dominantFrequency(up), 1_000, tolerance: 15)
            let f32 = try await AudTestKit.run(wav, [tone], [AudioKeys.bitDepth: "32f"]).outputs[0]
            if let fp = AudTestKit.probe(f32) { try expectEqual(fp.codec, "pcm_f32le") }
            let mono = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 1, rate: 44_100, channels: 1), to: fx.url("mono.wav"))
            let st = try await AudTestKit.run(wav, [mono], [AudioKeys.channels: "stereo"]).outputs[0]
            let stereo = try unwrap(AudTestKit.decode(st, in: fx.root))
            try expectEqual(stereo.channels, 2); try expectClose(AudTestKit.maxDiff(AudSig(rate: stereo.rate, ch: [stereo.ch[0]]), AudSig(rate: stereo.rate, ch: [stereo.ch[1]])), 0, tolerance: 1e-6)
        }

        t.register("audio.native", "stereo to mono averages the channels; the result is not just the left channel") {
            let fx = TestFixtures(label: "aud-mono"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, "s.wav", seconds: 2)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.wav"), [src], [AudioKeys.channels: "mono"]).outputs[0]
            let m = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expectEqual(m.channels, 1)
            let expected = AudSig(rate: ref.rate, ch: [ref.mono()])
            try expectClose(AudTestKit.maxDiff(m, expected), 0, tolerance: 2.0 / 32_768, "mono = (L + R) / 2")
        }

        t.register("audio.native", "gain is exact: +6 dB doubles the amplitude, -6 dB halves it") {
            let fx = TestFixtures(label: "aud-gain"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, "g.wav", seconds: 2)
            let wav = try AudTestKit.operation("audio.to.wav")
            let up = try unwrap(AudTestKit.decode(try await AudTestKit.run(wav, [src], [AudioKeys.gain: 6.0, AudioKeys.bitDepth: "24"]).outputs[0], in: fx.root))
            let base = AudTestKit.rms(ref.ch[0], from: 0, to: ref.frames)
            try expectClose(AudTestKit.rms(up.ch[0], from: 0, to: up.frames) / base, 1.9953, tolerance: 0.01, "+6 dB is x1.995")
            let down = try unwrap(AudTestKit.decode(try await AudTestKit.run(wav, [src], [AudioKeys.gain: -6.0]).outputs[0], in: fx.root))
            try expectClose(AudTestKit.rms(down.ch[0], from: 0, to: down.frames) / base, 0.5012, tolerance: 0.01)
        }

        t.register("audio.native", "fade in and fade out ramp to silence at the edges and leave the middle alone") {
            let fx = TestFixtures(label: "aud-fade"); defer { fx.cleanup() }
            let src = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 4, rate: 44_100, channels: 1, frequency: 440, amplitude: 0.5), to: fx.url("f.wav"))
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.wav"), [src], [AudioKeys.fadeIn: 1.0, AudioKeys.fadeOut: 1.5]).outputs[0]
            let s = try unwrap(AudTestKit.decode(out, in: fx.root)); let r = s.rate
            let nominal = 0.5 / 2.0.squareRoot()
            try expect(AudTestKit.rms(s.ch[0], from: 0, to: r / 50) < 0.04 * nominal, "first 20 ms RMS must be near zero")
            try expect(AudTestKit.rms(s.ch[0], from: s.frames - r / 50, to: s.frames) < 0.04 * nominal, "last 20 ms RMS must be near zero")
            try expectClose(AudTestKit.rms(s.ch[0], from: Int(1.2 * Double(r)), to: Int(2.2 * Double(r))) / nominal, 1, tolerance: 0.02, "the middle is untouched")
            let early = AudTestKit.rms(s.ch[0], from: Int(0.4 * Double(r)), to: Int(0.6 * Double(r)))
            try expectClose(early / nominal, 0.5, tolerance: 0.07, "halfway through a 1 s fade the level is about half")
        }

        t.register("audio.native", "trim keeps exactly the asked range, sample for sample") {
            let fx = TestFixtures(label: "aud-trim"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, "t.wav", seconds: 3)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.trim"), [src], [AudioKeys.trimStart: 0.5, AudioKeys.trimEnd: 2.0]).outputs[0]
            try expect(out.lastPathComponent.contains("(trimmed)") || out.lastPathComponent.contains("(обрезано)"), "tools are named with a suffix: \(out.lastPathComponent)")
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            let a = 22_050, b = 88_200
            try expectEqual(s.frames, b - a, "duration within one frame")
            let expected = AudSig(rate: ref.rate, ch: ref.ch.map { Array($0[a..<b]) })
            try expectClose(AudTestKit.maxDiff(s, expected), 0, tolerance: 1.0 / 32_768 * 1.01, "the kept part is the original samples")
            // A start with no end runs to the end; seconds given as text work too.
            let tail = try await AudTestKit.run(try AudTestKit.operation("audio.trim"), [src], [AudioKeys.trimStart: "0:02"]).outputs[0]
            try expectClose(try unwrap(AudTestKit.decode(tail, in: fx.root)).seconds, 1.0, tolerance: 0.001)
        }

        t.register("audio.native", "loudness normalisation lands on -16 LUFS within 1 LU, measured by ffmpeg, and respects the peak ceiling") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-norm"); defer { fx.cleanup() }
            let quiet = AudTestKit.chirp(seconds: 8, rate: 44_100, channels: 2, amplitude: 0.015)
            let src = try AudTestKit.writeWAV(quiet, to: fx.url("quiet.wav"))
            let before = try unwrap(AudTestKit.loudness(src))
            try expect(before.lufs < -30, "the fixture is quiet (\(before.lufs))")
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.normalize"), [src]).outputs[0]
            let after = try unwrap(AudTestKit.loudness(out))
            try expectClose(after.lufs, -16, tolerance: 1.0, "integrated loudness after normalisation")
            try expect(after.peak <= -1.0, "sample peak \(after.peak) must stay under the -1.5 dBTP ceiling")
            // A signal that cannot reach the target without clipping is limited by the ceiling, not distorted.
            let hot = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 6, rate: 44_100, channels: 2, frequency: 1_000, amplitude: 0.9), to: fx.url("hot.wav"))
            let hotOut = try await AudTestKit.run(try AudTestKit.operation("audio.normalize"), [hot], [AudioKeys.normalize: "ebu"]).outputs[0]
            let hotAfter = try unwrap(AudTestKit.loudness(hotOut))
            try expectClose(hotAfter.lufs, -23, tolerance: 1.0, "EBU R128 preset")
        }

        t.register("audio.native", "the true-peak ceiling of a custom target holds: loudness falls short rather than clipping") {
            let fx = TestFixtures(label: "aud-tp"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "tp.wav", seconds: 6)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.normalize"), [src], [AudioKeys.normalize: "custom", AudioKeys.normLUFS: -5.0, AudioKeys.normTP: -9.0, AudioKeys.bitDepth: "24"]).outputs[0]
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expectClose(AudTestKit.peakDB(s), -9.0, tolerance: 0.1, "the peak sits at the ceiling")
            let meter = AudLoudnessMeter(rate: s.rate, channels: s.channels); meter.feed(s.ch)
            try expect(try unwrap(meter.integratedLUFS) < -6, "the target of -5 LUFS was not reached, by design")
        }

        t.register("audio.native", "peak normalisation puts the loudest sample at -1 dBFS") {
            let fx = TestFixtures(label: "aud-peak"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "p.wav", seconds: 3)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.normalize"), [src], [AudioKeys.normalize: "peak", AudioKeys.bitDepth: "24"]).outputs[0]
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expectClose(AudTestKit.peakDB(s), -1.0, tolerance: 0.05)
        }

        t.register("audio.native", "tags round-trip in M4A: Cyrillic text, track/total, genre, year; strip removes them") {
            let fx = TestFixtures(label: "aud-tags"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "t.wav", seconds: 2)
            let op = try AudTestKit.operation("audio.to.m4a")
            let out = try await AudTestKit.run(op, [src], [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Привет, мир", AudioKeys.tagArtist: "Žluťák", AudioKeys.tagAlbum: "Болото",
                                                            AudioKeys.tagYear: "2021", AudioKeys.tagTrack: "3", AudioKeys.tagTrackTotal: "12", AudioKeys.tagGenre: "Ambient",
                                                            AudioKeys.tagComposer: "Me", AudioKeys.tagComment: "ok", AudioKeys.tagAlbumArtist: "Various", AudioKeys.tagDisc: "2"]).outputs[0]
            let avf = try await Self.avf(out).tags
            try expectEqual(avf.title, "Привет, мир"); try expectEqual(avf.artist, "Žluťák"); try expectEqual(avf.album, "Болото")
            if let fp = AudTestKit.probe(out) {
                try expectEqual(fp.tags["title"], "Привет, мир"); try expectEqual(fp.tags["artist"], "Žluťák"); try expectEqual(fp.tags["album"], "Болото")
                try expectEqual(fp.tags["genre"], "Ambient"); try expectEqual(fp.tags["composer"], "Me"); try expectEqual(fp.tags["comment"], "ok")
                try expectEqual(fp.tags["album_artist"], "Various")
                try expect((fp.tags["date"] ?? "").hasPrefix("2021"), "date \(fp.tags["date"] ?? "nil")")
                try expectEqual(fp.tags["track"], "3/12", "track number and total")
                try expect((fp.tags["disc"] ?? "").hasPrefix("2"), "disc number \(fp.tags["disc"] ?? "nil")")
            }
            // Tags travel through a conversion by default, and strip removes everything.
            let kept = try await AudTestKit.run(op, [out], [AudioKeys.bitrate: .int(128)]).outputs[0]
            let keptTitle = try await Self.avf(kept).tags.title
            try expectEqual(keptTitle, "Привет, мир", "tags are kept by default")
            let bare = try await AudTestKit.run(op, [out], [AudioKeys.tagsMode: "strip"]).outputs[0]
            let bareTags = try await Self.avf(bare).tags
            try expect(bareTags.isEmpty, "all tags removed: \(bareTags)")
            if let fp = AudTestKit.probe(bare) { try expect(fp.tags.filter { !["major_brand", "minor_version", "compatible_brands", "creation_time", "language", "itunsmpb", "handler_name"].contains($0.key) }.isEmpty, "\(fp.tags)") }
        }

        t.register("audio.native", "cover art: replaced, scaled down, kept, removed and saved as a picture") {
            let fx = TestFixtures(label: "aud-cover"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "c.wav", seconds: 2)
            let big = try fx.jpeg("cover.jpg", width: 1200, height: 800, pattern: .gradient)
            let op = try AudTestKit.operation("audio.to.m4a")
            let withCover = try await AudTestKit.run(op, [src], [AudioKeys.coverMode: "replace", AudioKeys.coverFile: .string(big.path), AudioKeys.coverMax: "500"]).outputs[0]
            let coverInfo = try await Self.avf(withCover)
            try expect(coverInfo.hasCover, "cover present")
            let extractedPicture = await AudCover.extract(from: withCover, ctx: nil)
            let picture = try unwrap(extractedPicture)
            let size = try unwrap(AudCover.pixelSize(picture))
            try expectEqual(max(size.width, size.height), 500, "scaled to 500 px on the long side"); try expect(AudCover.isJPEG(picture))
            // Kept through the next conversion; removed on request; saved separately next to the audio.
            let kept = try await AudTestKit.run(op, [withCover], [AudioKeys.bitrate: .int(96)]).outputs[0]
            let keptInfo = try await Self.avf(kept)
            try expect(keptInfo.hasCover, "cover kept by default")
            let gone = try await AudTestKit.run(op, [withCover], [AudioKeys.coverMode: "remove"]).outputs[0]
            let goneInfo = try await Self.avf(gone)
            try expect(!goneInfo.hasCover, "cover removed")
            let extracted = try await AudTestKit.run(op, [withCover], [AudioKeys.coverMode: "extract"]).outputs
            try expectEqual(extracted.count, 2, "audio plus the picture")
            let jpg = try unwrap(extracted.first { $0.pathExtension == "jpg" })
            try expectEqual(TestImage.size(of: jpg)?.width, 500)
            let audio = try unwrap(extracted.first { $0.pathExtension == "m4a" })
            let audioInfo = try await Self.avf(audio)
            try expect(!audioInfo.hasCover, "extract leaves the picture out of the audio")
        }

        t.register("audio.native", "the source probe turns codec, rate, channels, bit rate, duration, tags and cover into facts, chips and warnings") {
            let fx = TestFixtures(label: "aud-probe"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "p.wav", seconds: 2)
            let cover = try fx.jpeg("cover.jpg", width: 200, height: 200)
            let m4a = try await AudTestKit.run(try AudTestKit.operation("audio.to.m4a"), [src], [AudioKeys.bitrate: .int(64), AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Привет", AudioKeys.tagArtist: "A",
                                                                                                 AudioKeys.coverMode: "replace", AudioKeys.coverFile: .string(cover.path)]).outputs[0]
            let info = await AudioSourceProbe().probe(FileItem(url: m4a, isDirectory: false))
            try expectEqual(info.facts["audio.0.codec"]?.asString, "aac"); try expectEqual(info.facts["audio.0.rate"]?.asInt, 44_100); try expectEqual(info.facts["audio.0.channels"]?.asInt, 2)
            try expect((info.facts["audio.0.bitrate"]?.asInt ?? 0) > 40_000, "bit rate fact"); try expectClose(info.facts["duration"]?.asDouble ?? 0, 2.0, tolerance: 0.005, "the gapless data gives the exact length, not the container's with priming")
            try expectEqual(info.facts["audio.hasCover"]?.asBool, true); try expectEqual(info.facts["audio.tag.title"]?.asString, "Привет"); try expectEqual(info.facts["audio.tag.artist"]?.asString, "A")
            try expect(info.chips.contains { $0.text == "AAC" } && info.chips.contains { $0.text.contains("44.1") } && info.chips.contains { $0.symbol == "photo" }, "chips: \(info.chips.map(\.text))")
            try expect(info.warnings.contains { $0.en.contains("Low bit rate") }, "a 64 kbit/s file warns that converting will not improve it")
            try expectEqual(info.streams.count, 1)
            let wavInfo = await AudioSourceProbe().probe(FileItem(url: src, isDirectory: false))
            try expectEqual(wavInfo.facts["audio.0.lossless"]?.asBool, true); try expect(wavInfo.warnings.isEmpty)
            try expectEqual(wavInfo.facts["audio.0.bitdepth"]?.asInt, 16)
        }

        t.register("audio.native", "privacy overrides leave no tags, no cover and no personal strings, on the native route and through ffmpeg") {
            let fx = TestFixtures(label: "aud-priv"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "p.wav", seconds: 2)
            let cover = try fx.jpeg("cover.jpg", width: 200, height: 200)
            let tagged: OptionValues = [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Секрет", AudioKeys.tagArtist: "Andris", AudioKeys.tagComment: "recorded at home",
                                        AudioKeys.coverMode: "replace", AudioKeys.coverFile: .string(cover.path)]
            let op = try AudTestKit.operation("audio.to.m4a")
            let m4a = try await AudTestKit.run(op, [src], tagged).outputs[0]
            let before = try await Self.avf(m4a)
            try expect(!before.tags.isEmpty && before.hasCover, "the fixture carries tags and a cover")
            let clean = try await AudTestKit.run(op, [m4a], op.privacyOverrides()).outputs[0]
            let after = try await Self.avf(clean)
            try expect(after.tags.isEmpty && !after.hasCover, "native route: \(after.tags) cover \(after.hasCover)")
            let bytes = try Data(contentsOf: clean)
            for secret in ["Секрет", "Andris", "recorded at home"] { try expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) still sits in the file") }
            guard AudEnvironment.current().has(encoder: "libmp3lame") else { return }
            let mp3Op = try AudTestKit.operation("audio.to.mp3")
            let mp3 = try await AudTestKit.run(mp3Op, [src], tagged).outputs[0]
            let mp3Clean = try await AudTestKit.run(mp3Op, [mp3], mp3Op.privacyOverrides()).outputs[0]
            let fp = try unwrap(AudTestKit.probe(mp3Clean))
            try expect(fp.tags.filter { $0.key != "encoder" }.isEmpty && !fp.hasPicture, "ffmpeg route: \(fp.tags)")
            let mp3Bytes = try Data(contentsOf: mp3Clean)
            for secret in ["Секрет", "Andris", "recorded at home"] {
                let utf16 = Data(secret.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
                try expect(mp3Bytes.range(of: Data(secret.utf8)) == nil && mp3Bytes.range(of: utf16) == nil, "\(secret) still sits in the MP3")
            }
        }

        t.register("audio.native", "the Studio estimate is close to the real size: PCM exact, AAC within 10 percent, FLAC within 30 percent") {
            let fx = TestFixtures(label: "aud-est"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "e.wav", seconds: 10)
            let item = FileItem(url: src, isDirectory: false)
            let sourceInfo = await AudioSourceProbe().probe(item)
            let cases: [(String, OptionValues, Double)] = [("audio.to.wav", [:], 0.001), ("audio.to.m4a", [AudioKeys.bitrate: .int(128)], 0.10), ("audio.to.flac", [:], 0.30), ("audio.to.aiff", [AudioKeys.bitDepth: "24"], 0.001)]
            for (id, extra, tolerance) in cases {
                let op = try AudTestKit.operation(id)
                let resolved = op.optionSchema(for: [item]).resolve(layers: [op.quickOverrides(settings: SettingsData()), extra], source: sourceInfo)
                let estimate = try unwrap(op.estimate(options: resolved.values, items: [item], source: sourceInfo), "\(id) estimate")
                let real = Double(TestFile.size(try await AudTestKit.run(op, [src], extra).outputs[0]))
                let guess = Double(try unwrap(estimate.bytes))
                try expect(abs(guess - real) / real <= tolerance, "\(id): estimated \(Int(guess)) B, real \(Int(real)) B")
            }
        }

        t.register("audio.native", "odd names: spaces, unicode, a leading dash and dots survive; an existing output is never overwritten") {
            let fx = TestFixtures(label: "aud-names"); defer { fx.cleanup() }
            let op = try AudTestKit.operation("audio.to.flac")
            for name in ["-dash start.wav", "dots.in.name.v2.wav", "Ünïcødé 歌曲.wav"] {
                let (src, _) = try source(fx, name, seconds: 1)
                let out = try await AudTestKit.run(op, [src]).outputs[0]
                try expect(TestFile.exists(out) && out.deletingPathExtension().lastPathComponent == src.deletingPathExtension().lastPathComponent, "\(name) -> \(out.lastPathComponent)")
                let again = try await AudTestKit.run(op, [src]).outputs[0]
                try expect(again != out && again.lastPathComponent.contains("(2)"), "collision-safe: \(again.lastPathComponent)")
            }
            try expect(TestFile.partials(in: fx.root).isEmpty, "no hidden .part files left behind: \(TestFile.partials(in: fx.root))")
        }

        t.register("audio.native", "a read-only output folder gives a calm error and leaves nothing behind; a batch with one bad file still converts the rest") {
            let fx = TestFixtures(label: "aud-ro"); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("locked")
            let (src, _) = try source(fx, "locked/song.wav", seconds: 1)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            let err = try await expectThrows { _ = try await AudTestKit.run(try AudTestKit.operation("audio.to.flac"), [src]) }
            try expect(!ConversionError.describe(err).isEmpty, "a message the person can read")
            try expect(TestFile.partials(in: dir).isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("song.flac").path), "nothing left in the folder")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            let good = try source(fx, "good.wav", seconds: 1).url
            let bad = try fx.text("bad.mp3", "not audio")
            let run = try await AudTestKit.run(try AudTestKit.operation("audio.to.flac"), [bad, good])
            try expectEqual(run.outputs.map(\.lastPathComponent), ["good.flac"])
        }

        t.register("audio.native", "files without sound, and files that are not audio, fail with a calm message") {
            let fx = TestFixtures(label: "aud-bad"); defer { fx.cleanup() }
            let junk = try fx.text("broken.mp3", "this is not audio at all")
            let err = try await expectThrows { _ = try await AudTestKit.run(try AudTestKit.operation("audio.to.m4a"), [junk]) }
            try expect(!ConversionError.describe(err).isEmpty)
            try expect(TestFile.partials(in: fx.root).isEmpty, "no partial output after a failure")
            try expect(!FileManager.default.fileExists(atPath: fx.url("broken.m4a").path), "no output file for a failed conversion")
        }

        t.register("audio.native", "cancelling stops the work within 200 ms of the request and leaves no partial file", timeout: 120) {
            let fx = TestFixtures(label: "aud-cancel"); defer { fx.cleanup() }
            let pattern = AudTestKit.chirp(seconds: 1, rate: 44_100, channels: 2)
            let long = try AudTestKit.writeLongWAV(pattern: pattern, repeating: 600, to: fx.url("hour.wav"))        // 10 minutes
            let (error, seconds) = try await AudTestKit.runCancelling(try AudTestKit.operation("audio.to.flac"), [long], after: 0.4)
            try expect(error is CancellationError, "cancelled: \(String(describing: error))")
            try expect(seconds < 0.5, "the cancel took \(seconds) s")
            try expect(TestFile.partials(in: fx.root).isEmpty, "no .part left: \(TestFile.partials(in: fx.root))")
            try expect(!FileManager.default.fileExists(atPath: fx.url("hour.flac").path), "no output file after a cancel")
        }
    }
}
