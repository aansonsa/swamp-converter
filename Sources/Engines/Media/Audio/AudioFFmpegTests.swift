import Foundation

// Real conversions that need ffmpeg (MP3, Opus, Ogg, AC-3, loudnorm, speed, high-pass, limiter, silence trim, fast-copy trim, size limit, FLAC
// extras) or lame, plus the gating tests that pretend the tools are missing. Each output is read back by ffprobe / ffmpeg / the file's own bytes.

enum AudioFFmpegTests {
    static func source(_ fx: TestFixtures, _ name: String = "mix.wav", seconds: Double = 3, rate: Int = 44_100, channels: Int = 2) throws -> (url: URL, ref: AudSig) {
        let url = try AudTestKit.writeWAV(AudTestKit.chirp(seconds: seconds, rate: rate, channels: channels), to: fx.url(name))
        return (url, try unwrap(AudTestKit.parseWAV(url)))
    }

    static func snr(_ ref: AudSig, _ out: URL, _ fx: TestFixtures) throws -> Double {
        let decoded = try unwrap(AudTestKit.decode(out, in: fx.root))
        let back = try unwrap(AudTestKit.resampled(decoded, to: ref.rate), "resampling for the comparison")
        return try unwrap(AudTestKit.fidelity(ref: ref.mono(), test: back.mono())).snr
    }

    static func register() {
        let t = SelfTestRegistry.shared
        registerMP3(t)
        registerOpus(t)
        registerFilters(t)
        registerSizeAndCopy(t)
    }

    // MARK: MP3

    private static func registerMP3(_ t: SelfTestRegistry) {
        t.register("audio.ffmpeg", "MP3 quick recipe: a real MP3 (V2), rate and channels kept, duration right, fidelity high") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-mp3"); defer { fx.cleanup() }
            let (src, ref) = try source(fx)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.mp3"), [src]).outputs[0]
            try expectEqual(AudTestKit.sniff(out), "mp3"); try expectEqual(out.pathExtension, "mp3")
            try expect(AudTestKit.mime(out).contains("audio/mpeg") || AudTestKit.mime(out).contains("audio/mp3"), "file --mime-type says \(AudTestKit.mime(out))")
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.codec, "mp3"); try expectEqual(fp.formatName, "mp3"); try expectEqual(fp.rate, 44_100); try expectEqual(fp.channels, 2)
            try expect(fp.bitRate > 130_000 && fp.bitRate < 260_000, "V2 averages about 190 kbit/s, got \(fp.bitRate)")
            try expectClose(fp.duration, 3.0, tolerance: 0.06)
            try expect(try snr(ref, out, fx) > 15, "MP3 V2 SNR")
        }

        t.register("audio.ffmpeg", "MP3 bit rate is honoured (CBR within 15 percent) and quality knobs are monotonic") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-mp3q"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, seconds: 4)
            let op = try AudTestKit.operation("audio.to.mp3")
            var sizes: [Int64] = [], snrs: [Double] = []
            for kbps in [64, 128, 256] {
                let out = try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: .int(kbps)]).outputs[0]
                let fp = try unwrap(AudTestKit.probe(out))
                try expect(abs(Double(fp.bitRate) - Double(kbps * 1000)) / Double(kbps * 1000) < 0.15, "\(kbps) kbit/s read back as \(fp.bitRate)")
                sizes.append(TestFile.size(out)); snrs.append(try snr(ref, out, fx))
                try? FileManager.default.removeItem(at: out)
            }
            try expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "sizes \(sizes)")
            try expect(snrs[0] < snrs[1] && snrs[1] < snrs[2], "SNRs \(snrs)")
            var q: [Int64] = []
            for quality in [10, 50, 100] { q.append(TestFile.size(try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "quality", AudioKeys.quality: .int(quality)]).outputs[0])) }
            try expect(q[0] < q[1] && q[1] < q[2], "VBR sizes \(q)")
        }

        t.register("audio.ffmpeg", "MP3 encoder details reach the file: joint stereo flag in the frame header, ID3 version, mono/stereo") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-mp3d"); defer { fx.cleanup() }
            let (src, _) = try source(fx)
            let op = try AudTestKit.operation("audio.to.mp3")
            let joint = try await AudTestKit.run(op, [src], [AudioKeys.mp3Joint: true, AudioKeys.bitrate: 192, AudioKeys.rateControl: "bitrate"]).outputs[0]
            let plain = try await AudTestKit.run(op, [src], [AudioKeys.mp3Joint: false, AudioKeys.bitrate: 192, AudioKeys.rateControl: "bitrate"]).outputs[0]
            try expectEqual(AudTestKit.mp3ChannelMode(joint), 1, "joint stereo"); try expectEqual(AudTestKit.mp3ChannelMode(plain), 0, "plain stereo")
            let v24 = try await AudTestKit.run(op, [src], [AudioKeys.mp3ID3: "v24", AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "x"]).outputs[0]
            let v23 = try await AudTestKit.run(op, [src], [AudioKeys.mp3ID3: "v23", AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "x"]).outputs[0]
            try expectEqual(AudTestKit.id3Version(v24), 4); try expectEqual(AudTestKit.id3Version(v23), 3)
            let mono = try await AudTestKit.run(op, [src], [AudioKeys.channels: "mono"]).outputs[0]
            try expectEqual(AudTestKit.mp3ChannelMode(mono), 3); try expectEqual(try unwrap(AudTestKit.probe(mono)).channels, 1)
        }

        t.register("audio.ffmpeg", "MP3 tags and cover art round-trip, Cyrillic included; strip leaves no tags") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-mp3t"); defer { fx.cleanup() }
            let (src, _) = try source(fx, seconds: 2)
            let cover = try fx.jpeg("cover.jpg", width: 900, height: 600)
            let op = try AudTestKit.operation("audio.to.mp3")
            let out = try await AudTestKit.run(op, [src], [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Привет, мир", AudioKeys.tagArtist: "Žluťák", AudioKeys.tagAlbum: "Болото",
                                                            AudioKeys.tagYear: "2021", AudioKeys.tagTrack: "3", AudioKeys.tagTrackTotal: "12", AudioKeys.tagGenre: "Ambient",
                                                            AudioKeys.tagAlbumArtist: "Various", AudioKeys.tagComposer: "Composer Ž", AudioKeys.tagComment: "ok ✓", AudioKeys.tagDisc: "2",
                                                            AudioKeys.coverMode: "replace", AudioKeys.coverFile: .string(cover.path), AudioKeys.coverMax: "500"]).outputs[0]
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.tags["title"], "Привет, мир"); try expectEqual(fp.tags["artist"], "Žluťák"); try expectEqual(fp.tags["album"], "Болото")
            try expectEqual(fp.tags["genre"], "Ambient"); try expectEqual(fp.tags["album_artist"], "Various"); try expectEqual(fp.tags["track"], "3/12")
            try expectEqual(fp.tags["composer"], "Composer Ž"); try expectEqual(fp.tags["comment"], "ok ✓"); try expect((fp.tags["disc"] ?? "").hasPrefix("2"), "disc \(fp.tags["disc"] ?? "nil")")
            try expect((fp.tags["date"] ?? "").hasPrefix("2021"), "date \(fp.tags["date"] ?? "nil")"); try expect(fp.hasPicture, "cover present")
            let picture = try unwrap(await AudCover.extract(from: out, ctx: nil))
            let size = try unwrap(AudCover.pixelSize(picture))
            try expectEqual(max(size.width, size.height), 500, "cover scaled to 500 px")
            // Keep (default) carries tags and cover on; strip removes both.
            let kept = try await AudTestKit.run(op, [out], [AudioKeys.bitrate: .int(128), AudioKeys.rateControl: "bitrate"]).outputs[0]
            let keptProbe = try unwrap(AudTestKit.probe(kept))
            try expectEqual(keptProbe.tags["title"], "Привет, мир"); try expect(keptProbe.hasPicture, "cover kept")
            let bare = try await AudTestKit.run(op, [out], [AudioKeys.tagsMode: "strip", AudioKeys.coverMode: "remove"]).outputs[0]
            let bareProbe = try unwrap(AudTestKit.probe(bare))
            try expect(bareProbe.tags.filter { $0.key != "encoder" }.isEmpty, "no tags left: \(bareProbe.tags)")
            try expect((bareProbe.tags["encoder"] ?? "").rangeOfCharacter(from: .decimalDigits) == nil, "no encoder version string (only the LAME frame's fixed name may stay): \(bareProbe.tags)")
            try expect(!bareProbe.hasPicture, "no cover left")
        }
    }

    // MARK: Opus, Ogg, AC-3

    private static func registerOpus(_ t: SelfTestRegistry) {
        t.register("audio.ffmpeg", "Opus quick recipe: real Opus in Ogg at 48 kHz, bit rate on target, good fidelity; mode and rate-control knobs act") {
            try AudTestKit.needsEncoder("libopus")
            let fx = TestFixtures(label: "aud-opus"); defer { fx.cleanup() }
            let (src, ref) = try source(fx)
            let op = try AudTestKit.operation("audio.to.opus")
            let out = try await AudTestKit.run(op, [src]).outputs[0]
            try expectEqual(AudTestKit.sniff(out), "ogg"); try expectEqual(out.pathExtension, "opus")
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.codec, "opus"); try expect(fp.formatName.contains("ogg"), fp.formatName); try expectEqual(fp.rate, 48_000); try expectEqual(fp.channels, 2)
            try expect(abs(Double(fp.bitRate) - 128_000) / 128_000 < 0.15, "bit rate \(fp.bitRate)")
            try expectClose(fp.duration, 3.0, tolerance: 0.06)
            try expect(try snr(ref, out, fx) > 8, "Opus 128k keeps the waveform roughly (Opus is perceptual, so SNR is modest)")
            let back = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expectEqual(back.rate, 48_000)
            let cbr = try await AudTestKit.run(op, [src], [AudioKeys.opusVBR: "off", AudioKeys.bitrate: .int(64)]).outputs[0]
            let vbr = try await AudTestKit.run(op, [src], [AudioKeys.opusVBR: "on", AudioKeys.bitrate: .int(64)]).outputs[0]
            try expect(try Data(contentsOf: cbr) != Data(contentsOf: vbr), "rate-control mode changes the stream")
            let voice = try await AudTestKit.run(op, [src], [AudioKeys.opusApp: "voip", AudioKeys.bitrate: .int(32), AudioKeys.channels: "mono"]).outputs[0]
            let music = try await AudTestKit.run(op, [src], [AudioKeys.opusApp: "audio", AudioKeys.bitrate: .int(32), AudioKeys.channels: "mono"]).outputs[0]
            try expect(try Data(contentsOf: voice) != Data(contentsOf: music), "application mode changes the stream")
            try expectEqual(try unwrap(AudTestKit.probe(voice)).channels, 1)
        }

        t.register("audio.ffmpeg", "Ogg is always real Vorbis (libvorbis, or sox when ffmpeg lacks it), at the source's rate and layout") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-ogg"); defer { fx.cleanup() }
            let (src, ref) = try source(fx)
            guard AudEnvironment.current().canEncodeVorbis else { try skipTest("neither libvorbis nor sox is available; Ogg is reported unavailable") }
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.ogg"), [src]).outputs[0]
            try expectEqual(AudTestKit.sniff(out), "ogg"); try expectEqual(out.pathExtension, "ogg")
            try expectEqual(FormatSniffer.sniff(out)?.key, "ogg", "Core's byte sniffer: an Ogg Vorbis stream, not Opus")
            let fp = try unwrap(AudTestKit.probe(out))
            try expect(fp.formatName.contains("ogg"), fp.formatName); try expectEqual(fp.codec, "vorbis")
            try expectEqual(fp.rate, 44_100); try expectEqual(fp.channels, 2)
            try expectClose(fp.duration, 3.0, tolerance: 0.1)
            try expect(try snr(ref, out, fx) > 12, "Vorbis q5 keeps the waveform")
        }

        t.register("audio.ffmpeg", "sox writes the Ogg when ffmpeg has no libvorbis (simulated): mono stays mono, quality and bit rate act, tags are Vorbis comments") {
            try AudTestKit.needs(.sox)
            let fx = TestFixtures(label: "aud-ogg2"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, seconds: 3, channels: 1)
            var env = AudEnvironment.current(); env.encoders.remove("libvorbis")
            guard env.hasSoxVorbis else { try skipTest("this sox cannot write Ogg Vorbis") }
            let op = try AudTestKit.operation("audio.to.ogg")
            let (run, low, high, kb) = try await AudTestKit.withEnvironment(env) {
                let tagged = try await AudTestKit.run(op, [src], [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Привет", AudioKeys.tagArtist: "Žluťák", AudioKeys.tagTrack: "3", AudioKeys.tagTrackTotal: "9"])
                let low = try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "quality", AudioKeys.quality: 10]).outputs[0]
                let high = try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "quality", AudioKeys.quality: 90]).outputs[0]
                let kb = try await AudTestKit.run(op, [src], [AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 64]).outputs[0]
                return (tagged, low, high, kb)
            }
            let out = run.outputs[0]
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.codec, "vorbis"); try expectEqual(fp.channels, 1); try expectEqual(fp.rate, 44_100)
            try expectEqual(fp.tags["title"], "Привет"); try expectEqual(fp.tags["artist"], "Žluťák"); try expectEqual(fp.tags["track"], "3"); try expectEqual(fp.tags["tracktotal"], "9")
            try expect(TestFile.size(low) < TestFile.size(high), "quality 10 (\(TestFile.size(low))) < 90 (\(TestFile.size(high)))")
            try expect(try snr(ref, low, fx) < (try snr(ref, high, fx)), "more quality, more fidelity")
            let kbFp = try unwrap(AudTestKit.probe(kb))
            try expect(kbFp.bitRate > 40_000 && kbFp.bitRate < 90_000, "64 kbit/s asked, nominal rate \(kbFp.bitRate)")
            try expect(run.log.contains { $0.contains("sox") }, "the person is told sox did it: \(run.log)")
        }

        t.register("audio.ffmpeg", "AC-3 (Studio target): a real Dolby Digital stream at the asked bit rate") {
            try AudTestKit.needsEncoder("ac3")
            let fx = TestFixtures(label: "aud-ac3"); defer { fx.cleanup() }
            let (src, _) = try source(fx, seconds: 2, rate: 48_000)
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.opus"), [src], [AudioKeys.target: "ac3", AudioKeys.bitrate: .int(192)]).outputs[0]
            try expectEqual(out.pathExtension, "ac3"); try expectEqual(AudTestKit.sniff(out), "ac3")
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.codec, "ac3"); try expectEqual(fp.bitRate, 192_000); try expectEqual(fp.rate, 48_000)
        }
    }

    // MARK: Filters

    private static func registerFilters(_ t: SelfTestRegistry) {
        t.register("audio.ffmpeg", "two-pass loudness on a lossy file lands within 1 LU of -16 and -23; a single pass is close too") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-ln"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "quiet.wav", seconds: 10)
            let mp3 = try await AudTestKit.run(try AudTestKit.operation("audio.to.mp3"), [src], [AudioKeys.gain: -20.0, AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 192]).outputs[0]
            let before = try unwrap(AudTestKit.loudness(mp3))
            let norm = try AudTestKit.operation("audio.normalize")
            let two = try await AudTestKit.run(norm, [mp3]).outputs[0]
            try expectEqual(try unwrap(AudTestKit.probe(two)).codec, "mp3", "the format is kept")
            let a = try unwrap(AudTestKit.loudness(two))
            try expectClose(a.lufs, -16, tolerance: 1.0, "two-pass from \(before.lufs) LUFS")
            let ebu = try await AudTestKit.run(norm, [mp3], [AudioKeys.normalize: "ebu"]).outputs[0]
            try expectClose(try unwrap(AudTestKit.loudness(ebu)).lufs, -23, tolerance: 1.0, "EBU R128 target")
            let single = try await AudTestKit.run(norm, [mp3], [AudioKeys.normTwoPass: false]).outputs[0]
            let s = try unwrap(AudTestKit.loudness(single))
            try expectClose(s.lufs, -16, tolerance: 2.0, "single pass is looser but close")
            try expect(abs(a.lufs + 16) <= abs(s.lufs + 16) + 0.05, "measuring first is at least as accurate: \(a.lufs) vs \(s.lufs)")
            try expect(try Data(contentsOf: two) != Data(contentsOf: single), "the two modes are different encodes")
            let custom = try await AudTestKit.run(norm, [mp3], [AudioKeys.normalize: "custom", AudioKeys.normLUFS: -20.0, AudioKeys.normTP: -2.0]).outputs[0]
            try expectClose(try unwrap(AudTestKit.loudness(custom)).lufs, -20, tolerance: 1.0, "custom target")
        }

        t.register("audio.ffmpeg", "loudness range option: a small range evens out loud and quiet parts, a large one leaves them") {
            try AudTestKit.needs(.ffmpeg); try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-lra"); defer { fx.cleanup() }
            let loud = AudTestKit.chirp(seconds: 6, rate: 44_100, channels: 1, amplitude: 0.4)
            let quiet = AudTestKit.chirp(seconds: 6, rate: 44_100, channels: 1, seed: 9, amplitude: 0.02)
            let src = try AudTestKit.writeWAV(AudSig(rate: 44_100, ch: [loud.ch[0] + quiet.ch[0]]), to: fx.url("dynamic.wav"))
            let norm = try AudTestKit.operation("audio.normalize")
            let wide = try await AudTestKit.run(norm, [src], [AudioKeys.normalize: "custom", AudioKeys.normLUFS: -16.0, AudioKeys.normLRA: 20]).outputs[0]
            let narrow = try await AudTestKit.run(norm, [src], [AudioKeys.normalize: "custom", AudioKeys.normLUFS: -16.0, AudioKeys.normLRA: 3]).outputs[0]
            let w = try unwrap(AudTestKit.loudness(wide)), n = try unwrap(AudTestKit.loudness(narrow))
            AudTestKit.debug("LRA wide \(w.lra) narrow \(n.lra), source \(AudTestKit.loudness(src)?.lra ?? -1)")
            try expect(n.lra + 2 < w.lra, "LRA 3 target gives \(n.lra) LU, LRA 20 gives \(w.lra) LU")
        }

        t.register("audio.ffmpeg", "dither through ffmpeg (16-bit FLAC from 24-bit) has the same effect: triangular noise on top of rounding") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-dith2"); defer { fx.cleanup() }
            let (src, ref) = try AudioNativeTests.source(fx, "deep.wav", seconds: 3, rate: 48_000, bits: 24)
            let flac = try AudTestKit.operation("audio.to.flac")
            func rms(_ mode: String) async throws -> Double {
                let r = try await AudTestKit.run(flac, [src], [AudioKeys.bitDepth: "16", AudioKeys.dither: .string(mode)])
                let out = r.outputs[0]
                try expectEqual(try unwrap(AudTestKit.probe(out)).bitsPerSample, 16)
                let s = try unwrap(AudTestKit.decode(out, in: fx.root))
                var sum = 0.0
                for c in 0..<s.channels { for i in 0..<s.frames { let e = (Double(s.ch[c][i]) - Double(ref.ch[c][i])) * 32_768; sum += e * e } }
                try? FileManager.default.removeItem(at: out)
                return (sum / Double(s.frames * s.channels)).squareRoot()
            }
            let none = try await rms("none"), tri = try await rms("triangular")
            AudTestKit.debug("ffmpeg error RMS: none \(none), triangular \(tri)")
            try expectClose(none, 0.289, tolerance: 0.04); try expect(tri > none * 1.4 && tri < 0.7, "triangular \(tri) vs plain \(none)")
        }

        t.register("audio.ffmpeg", "the tone control moves the right bands: bass, treble, and voice clarity") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-eq"); defer { fx.cleanup() }
            let wav = try AudTestKit.operation("audio.to.wav")
            func level(_ url: URL, _ extra: OptionValues) async throws -> Double {
                let s = try unwrap(AudTestKit.decode(try await AudTestKit.run(wav, [url], extra).outputs[0], in: fx.root))
                return 20 * log10(max(AudTestKit.rms(s.ch[0], from: s.rate / 4, to: s.frames - s.rate / 4), 1e-9))
            }
            func tone(_ hz: Double) throws -> URL { try AudTestKit.writeWAV(AudTestKit.sine(seconds: 2, rate: 44_100, channels: 1, frequency: hz, amplitude: 0.1), to: fx.url("t\(Int(hz)).wav")) }
            let lowTone = try tone(50), midTone = try tone(3_000), highTone = try tone(10_000), rumble = try tone(40)
            let flat = try await level(lowTone, [:]), sameFlat = try await level(lowTone, [AudioKeys.eq: "flat"]), bass = try await level(lowTone, [AudioKeys.eq: "bass"])
            try expectClose(sameFlat, flat, tolerance: 0.1, "flat changes nothing")
            try expect(bass > flat + 3, "bass boosts 50 Hz: \(flat) -> \(bass) dB")
            let flatHigh = try await level(highTone, [:]), treble = try await level(highTone, [AudioKeys.eq: "treble"])
            try expect(treble > flatHigh + 2.5, "treble boosts 10 kHz: \(flatHigh) -> \(treble) dB")
            let flatMid = try await level(midTone, [:]), voiceMid = try await level(midTone, [AudioKeys.eq: "voice"])
            let flatRumble = try await level(rumble, [:]), voiceRumble = try await level(rumble, [AudioKeys.eq: "voice"])
            try expect(voiceMid > flatMid + 2, "voice lifts the 3 kHz presence band: \(flatMid) -> \(voiceMid) dB")
            try expect(voiceRumble < flatRumble - 6, "voice cuts the rumble below 80 Hz: \(flatRumble) -> \(voiceRumble) dB")
        }

        t.register("audio.ffmpeg", "speed really re-times the sound: 2x halves the length (not just the header) and keeps the pitch") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-speed"); defer { fx.cleanup() }
            let tone = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 4, rate: 44_100, channels: 1, frequency: 500), to: fx.url("tone.wav"))
            let out = try await AudTestKit.run(try AudTestKit.operation("audio.to.wav"), [tone], [AudioKeys.speed: 2.0]).outputs[0]
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expectClose(s.seconds, 2.0, tolerance: 0.06, "duration")
            try expectClose(AudTestKit.dominantFrequency(s), 500, tolerance: 8, "atempo changes the tempo, not the pitch")
        }

        t.register("audio.ffmpeg", "high-pass removes the rumble below the cut-off and leaves the voice band") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-hp"); defer { fx.cleanup() }
            let low = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 2, rate: 44_100, channels: 1, frequency: 60), to: fx.url("low.wav"))
            let mid = try AudTestKit.writeWAV(AudTestKit.sine(seconds: 2, rate: 44_100, channels: 1, frequency: 2_000), to: fx.url("mid.wav"))
            let op = try AudTestKit.operation("audio.to.wav")
            let l = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [low], [AudioKeys.highpass: 300]).outputs[0], in: fx.root))
            let m = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [mid], [AudioKeys.highpass: 300]).outputs[0], in: fx.root))
            let ref = 0.5 / 2.0.squareRoot()
            try expect(AudTestKit.rms(l.ch[0], from: 20_000, to: 80_000) < ref * 0.1, "60 Hz is cut by more than 20 dB")
            try expectClose(AudTestKit.rms(m.ch[0], from: 20_000, to: 80_000) / ref, 1, tolerance: 0.05, "2 kHz passes")
        }

        t.register("audio.ffmpeg", "limiter keeps a boosted signal under the ceiling where the plain boost clips") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-lim"); defer { fx.cleanup() }
            let loud = try AudTestKit.writeWAV(AudTestKit.chirp(seconds: 3, rate: 44_100, channels: 1, amplitude: 0.7), to: fx.url("loud.wav"))
            let op = try AudTestKit.operation("audio.to.wav")
            let clipped = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [loud], [AudioKeys.gain: 8.0]).outputs[0], in: fx.root))
            let limited = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [loud], [AudioKeys.gain: 8.0, AudioKeys.limiter: true]).outputs[0], in: fx.root))
            try expect(AudTestKit.peakDB(clipped) > -0.1, "without the limiter the boost reaches full scale (\(AudTestKit.peakDB(clipped)))")
            try expect(AudTestKit.peakDB(limited) < -0.7 && AudTestKit.peakDB(limited) > -3, "limited peak \(AudTestKit.peakDB(limited)) dBFS sits near the 0.89 ceiling")
        }

        t.register("audio.ffmpeg", "silence trim removes leading and trailing silence only") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-sil"); defer { fx.cleanup() }
            let core = AudTestKit.chirp(seconds: 2, rate: 44_100, channels: 1, amplitude: 0.4, noise: 0.0)
            let padded = AudTestKit.silencePadded(core: core, lead: 1.5, tail: 1.0)
            let src = try AudTestKit.writeWAV(padded, to: fx.url("padded.wav"))
            let op = try AudTestKit.operation("audio.to.wav")
            let trimmed = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [src], [AudioKeys.silence: true, AudioKeys.silenceDB: -50]).outputs[0], in: fx.root))
            try expectClose(trimmed.seconds, 2.0, tolerance: 0.15, "only the 2 s of sound is left")
            let untouched = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [src], [:]).outputs[0], in: fx.root))
            try expectClose(untouched.seconds, 4.5, tolerance: 0.01)
        }

        t.register("audio.ffmpeg", "silence threshold decides what counts as silence: low noise survives at -50 dB and goes at -30 dB") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-silt"); defer { fx.cleanup() }
            let core = AudTestKit.chirp(seconds: 2, rate: 44_100, channels: 1, amplitude: 0.4, noise: 0.0)
            let hiss = AudTestKit.chirp(seconds: 1.0, rate: 44_100, channels: 1, seed: 3, amplitude: 0, noise: 0.01)      // peaks about -40 dBFS
            let src = try AudTestKit.writeWAV(AudSig(rate: 44_100, ch: [hiss.ch[0] + core.ch[0] + hiss.ch[0]]), to: fx.url("hiss.wav"))
            let op = try AudTestKit.operation("audio.to.wav")
            let strict = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [src], [AudioKeys.silence: true, AudioKeys.silenceDB: -50]).outputs[0], in: fx.root))
            let loose = try unwrap(AudTestKit.decode(try await AudTestKit.run(op, [src], [AudioKeys.silence: true, AudioKeys.silenceDB: -30]).outputs[0], in: fx.root))
            try expectClose(strict.seconds, 4.0, tolerance: 0.1, "-50 dB: the hiss is sound, nothing is cut")
            try expectClose(loose.seconds, 2.0, tolerance: 0.15, "-30 dB: the hiss is silence")
        }

        t.register("audio.ffmpeg", "FLAC through ffmpeg: compression level shrinks the file, the sound stays bit-exact; 24-bit depth is kept") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-flac"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, seconds: 3)
            let op = try AudTestKit.operation("audio.to.flac")
            let fast = try await AudTestKit.run(op, [src], [AudioKeys.flacLevel: 0]).outputs[0]
            let small = try await AudTestKit.run(op, [src], [AudioKeys.flacLevel: 12]).outputs[0]
            try expect(TestFile.size(small) <= TestFile.size(fast), "level 12 (\(TestFile.size(small))) must not be bigger than level 0 (\(TestFile.size(fast)))")
            try expectClose(AudTestKit.maxDiff(try unwrap(AudTestKit.decode(small, in: fx.root)), ref), 0, tolerance: 1.0 / 32_768 * 1.01)
            let wide = try AudTestKit.writeWAV(AudTestKit.chirp(seconds: 2, rate: 48_000, channels: 2), to: fx.url("wide.wav"), bits: 24)
            let flac24 = try await AudTestKit.run(op, [wide], [AudioKeys.flacLevel: 8]).outputs[0]
            let fp = try unwrap(AudTestKit.probe(flac24))
            try expectEqual(fp.codec, "flac"); try expectEqual(fp.rate, 48_000); try expect(fp.bitsPerSample == 24, "24-bit kept: \(fp.bitsPerSample)")
            let sixteen = try await AudTestKit.run(op, [wide], [AudioKeys.flacLevel: 8, AudioKeys.bitDepth: "16"]).outputs[0]
            try expectEqual(try unwrap(AudTestKit.probe(sixteen)).bitsPerSample, 16)
        }

        t.register("audio.ffmpeg", "FLAC tags and cover art are written (the native FLAC writer cannot) and fade runs through ffmpeg when asked") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-flact"); defer { fx.cleanup() }
            let (src, _) = try source(fx, seconds: 3)
            let cover = try fx.jpeg("cover.jpg", width: 400, height: 400)
            let op = try AudTestKit.operation("audio.to.flac")
            let out = try await AudTestKit.run(op, [src], [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Привет", AudioKeys.tagArtist: "A", AudioKeys.coverMode: "replace",
                                                            AudioKeys.coverFile: .string(cover.path), AudioKeys.fadeIn: 1.0]).outputs[0]
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.tags["title"], "Привет"); try expectEqual(fp.tags["artist"], "A"); try expect(fp.hasPicture, "FLAC picture block")
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expect(AudTestKit.rms(s.ch[0], from: 0, to: s.rate / 50) < 0.03, "fade-in starts at silence")
        }
    }

    // MARK: Size limit, copy trim, compress

    private static func registerSizeAndCopy(_ t: SelfTestRegistry) {
        t.register("audio.ffmpeg", "size limit: AAC, MP3 and Opus end at or under the limit and within 8 percent of it") {
            try AudTestKit.needsEncoder("libmp3lame"); try AudTestKit.needsEncoder("libopus")
            let fx = TestFixtures(label: "aud-fit"); defer { fx.cleanup() }
            let (src, _) = try source(fx, "long.wav", seconds: 40)
            let limit = 300_000.0
            for (op, target) in [("audio.to.m4a", "aac"), ("audio.to.mp3", "mp3"), ("audio.to.opus", "opus")] {
                let out = try await AudTestKit.run(try AudTestKit.operation(op), [src], [AudioKeys.fitMB: .double(limit / 1_000_000), AudioKeys.target: .string(target)]).outputs[0]
                let size = Double(TestFile.size(out))
                try expect(size <= limit, "\(target): \(Int(size)) bytes must not exceed \(Int(limit))")
                try expect(size >= limit * 0.92, "\(target): \(Int(size)) bytes should be within 8 percent below \(Int(limit))")
                try? FileManager.default.removeItem(at: out)
            }
        }

        t.register("audio.ffmpeg", "fast-copy trim cuts the stream without re-encoding: same codec, same bit rate, identical decoded samples") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-copy"); defer { fx.cleanup() }
            let (src, _) = try source(fx, seconds: 6)
            let mp3 = try await AudTestKit.run(try AudTestKit.operation("audio.to.mp3"), [src], [AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 128]).outputs[0]
            let cut = try await AudTestKit.run(try AudTestKit.operation("audio.trim"), [mp3], [AudioKeys.trimStart: 1.0, AudioKeys.trimEnd: 4.0, AudioKeys.trimMode: "copy"]).outputs[0]
            let fp = try unwrap(AudTestKit.probe(cut))
            try expectEqual(fp.codec, "mp3"); try expectEqual(fp.formatName, "mp3"); try expectClose(fp.duration, 3.0, tolerance: 0.1, "snaps to a frame")
            try expect(abs(Double(fp.bitRate) - 128_000) < 3_000, "bit rate untouched: \(fp.bitRate)")
            let whole = try unwrap(AudTestKit.decode(mp3, in: fx.root)), part = try unwrap(AudTestKit.decode(cut, in: fx.root))
            let offset = try unwrap(AudTestKit.exactOffset(of: part.ch[0], at: 40_000, length: 4_000, in: whole.ch[0]), "the cut part must contain the very same decoded samples as the original")
            try expectClose(Double(offset) / 44_100, 1.0, tolerance: 0.05, "the part starts where it was cut (within one frame)")
            let exact = try await AudTestKit.run(try AudTestKit.operation("audio.trim"), [mp3], [AudioKeys.trimStart: 1.0, AudioKeys.trimEnd: 4.0]).outputs[0]
            try expectClose(try unwrap(AudTestKit.decode(exact, in: fx.root)).seconds, 3.0, tolerance: 0.03, "the exact mode re-encodes to the asked length")
        }

        t.register("audio.ffmpeg", "compress: a heavy MP3 shrinks in the MP3 family, a compact one is kept as it is and the person is told") {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-comp"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, seconds: 5)
            let mp3 = try AudTestKit.operation("audio.to.mp3")
            let heavy = try await AudTestKit.run(mp3, [src], [AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 320]).outputs[0]
            let comp = try AudTestKit.operation("audio.compress")
            let small = try await AudTestKit.run(comp, [heavy]).outputs[0]
            try expectEqual(try unwrap(AudTestKit.probe(small)).codec, "mp3", "the family is kept")
            try expect(TestFile.size(small) < TestFile.size(heavy) * 6 / 10, "320k -> 128k must shrink by more than 40 percent: \(TestFile.size(heavy)) -> \(TestFile.size(small))")
            try expect(try snr(ref, small, fx) > 10)
            let tiny = try await AudTestKit.run(mp3, [src], [AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 64]).outputs[0]
            let run = try await AudTestKit.run(comp, [tiny])
            try expect(try Data(contentsOf: run.outputs[0]) == Data(contentsOf: tiny), "a 64 kbit/s file is kept byte for byte, not squeezed again")
            try expect(run.log.contains { $0.contains("already compact") }, "declared in the log: \(run.log)")
            try expectEqual(try AudTestKit.operation("audio.compress").meta.passthrough, .conditional, "the metadata declares the possible pass-through")
            // A lossless source becomes AAC, never an MP3 re-encode of an MP3.
            let flacSmall = try await AudTestKit.run(comp, [src]).outputs[0]
            try expectEqual(try unwrap(AudTestKit.probe(flacSmall)).codec, "aac")
            try expect(TestFile.size(flacSmall) < TestFile.size(src) / 4)
        }

        t.register("audio.ffmpeg", "the lame route (no ffmpeg encoder) writes a real MP3 with Cyrillic tags and a cover") {
            try AudTestKit.needs(.lame); try AudTestKit.needs(.ffprobe)
            let fx = TestFixtures(label: "aud-lame"); defer { fx.cleanup() }
            let (src, ref) = try source(fx, seconds: 3)
            let cover = try fx.jpeg("cover.jpg", width: 300, height: 300)
            var env = AudEnvironment.none; env.hasLame = true
            let run = try await AudTestKit.withEnvironment(env) {
                try await AudTestKit.run(try AudTestKit.operation("audio.to.mp3"), [src], [AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 192, AudioKeys.tagsMode: "custom",
                                                                                           AudioKeys.tagTitle: "Привет", AudioKeys.tagArtist: "Žluťák", AudioKeys.coverMode: "replace",
                                                                                           AudioKeys.coverFile: .string(cover.path), AudioKeys.mp3Joint: false])
            }
            let out = run.outputs[0]
            try expectEqual(AudTestKit.sniff(out), "mp3")
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.codec, "mp3"); try expectEqual(fp.rate, 44_100); try expectEqual(fp.channels, 2)
            try expect(abs(Double(fp.bitRate) - 192_000) / 192_000 < 0.15, "bit rate \(fp.bitRate)")
            try expectEqual(fp.tags["title"], "Привет"); try expectEqual(fp.tags["artist"], "Žluťák"); try expect(fp.hasPicture, "cover")
            try expectEqual(AudTestKit.mp3ChannelMode(out), 0, "joint stereo off reaches lame")
            try expect(try snr(ref, out, fx) > 15)
        }
    }
}
