import Foundation

// Join (audio.concat): the output format is explicit and defaults to the BEST input (the original silently adopted the first file's rate and layout).

enum AudioJoinTests {
    static func tone(_ fx: TestFixtures, _ name: String, seconds: Double, rate: Int, channels: Int, frequency: Double, amplitude: Float = 0.4) throws -> URL {
        try AudTestKit.writeWAV(AudTestKit.sine(seconds: seconds, rate: rate, channels: channels, frequency: frequency, amplitude: amplitude), to: fx.url(name))
    }

    static func join(_ files: [URL], _ extra: OptionValues = OptionValues(), tools: ToolLocator = .shared) async throws -> AudTestKit.Run {
        try await AudTestKit.run(try AudTestKit.operation("audio.concat"), files, extra, tools: tools)
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("audio.join", "mono 44.1 kHz + stereo 48 kHz joins into 48 kHz stereo, 3.000 s, each part intact (best of the inputs, not the first file)") {
            let fx = TestFixtures(label: "aud-join1"); defer { fx.cleanup() }
            let a = try tone(fx, "a mono.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 440)
            let b = try tone(fx, "b stereo.wav", seconds: 2, rate: 48_000, channels: 2, frequency: 880)
            let run = try await join([b, a])      // selection order is irrelevant: natural order puts "a mono" first
            let out = try unwrap(run.outputs.first)
            try expectEqual(out.lastPathComponent, "a mono (joined).wav", "named after the first SORTED item")
            try expectEqual(AudTestKit.sniff(out), "wav")
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.rate, 48_000); try expectEqual(fp.channels, 2)
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            try expectClose(s.seconds, 3.0, tolerance: 0.002, "total duration")
            let r = s.rate
            let first = AudSig(rate: r, ch: s.ch.map { Array($0[r / 10..<(r - r / 10)]) }), second = AudSig(rate: r, ch: s.ch.map { Array($0[(r + r / 10)..<(3 * r - r / 10)]) })
            try expectClose(AudTestKit.dominantFrequency(first), 440, tolerance: 6, "the mono part is kept (and was upsampled)")
            try expectClose(AudTestKit.dominantFrequency(second), 880, tolerance: 8)
            try expectClose(AudTestKit.rms(s.ch[0], from: r / 10, to: r - r / 10), 0.4 / 2.0.squareRoot(), tolerance: 0.01, "level survives the rate change")
            try expectClose(AudTestKit.maxDiff(AudSig(rate: r, ch: [first.ch[0]]), AudSig(rate: r, ch: [first.ch[1]])), 0, tolerance: 1e-6, "mono became centred stereo, not a left-only channel")
        }

        t.register("audio.join", "the person can override rate and channels; both are visible in the schema") {
            let fx = TestFixtures(label: "aud-join2"); defer { fx.cleanup() }
            let a = try tone(fx, "a.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 440)
            let b = try tone(fx, "b.wav", seconds: 1, rate: 48_000, channels: 2, frequency: 880)
            let out = try await join([a, b], [AudioKeys.joinRate: "22050", AudioKeys.joinChannels: "mono"]).outputs[0]
            let fp = try unwrap(AudTestKit.probe(out))
            try expectEqual(fp.rate, 22_050); try expectEqual(fp.channels, 1)
            try expectClose(fp.duration, 2.0, tolerance: 0.01)
            let schema = AudioSchemas.join(items: [])
            let rateField = try unwrap(schema.field(AudioKeys.joinRate))
            if case .picker(let opts) = rateField.kind { try expectEqual(opts.first?.value, "auto") } else { throw TestFailure(message: "rate is a picker", file: #fileID, line: #line) }
        }

        t.register("audio.join", "natural order puts track2 before track10; the selection order is honoured on request") {
            let fx = TestFixtures(label: "aud-join3"); defer { fx.cleanup() }
            let t1 = try tone(fx, "track1.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 300)
            let t2 = try tone(fx, "track2.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 600)
            let t10 = try tone(fx, "track10.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 1_200)
            func order(_ s: AudSig) -> [Double] {
                let r = s.rate
                return (0..<3).map { i in AudTestKit.dominantFrequency(AudSig(rate: r, ch: s.ch.map { Array($0[(i * r + r / 4)..<(i * r + 3 * r / 4)]) })) }
            }
            let natural = try unwrap(AudTestKit.decode(try await join([t10, t2, t1]).outputs[0], in: fx.root))
            let f = order(natural)
            try expect(abs(f[0] - 300) < 15 && abs(f[1] - 600) < 25 && abs(f[2] - 1_200) < 40, "natural order 1, 2, 10: \(f)")
            let selection = try unwrap(AudTestKit.decode(try await join([t10, t2, t1], [AudioKeys.joinOrder: "selection"]).outputs[0], in: fx.root))
            let g = order(selection)
            try expect(abs(g[0] - 1_200) < 40 && abs(g[1] - 600) < 25 && abs(g[2] - 300) < 15, "selection order 10, 2, 1: \(g)")
        }

        t.register("audio.join", "silence between files and crossfades change the length by exactly what they promise") {
            let fx = TestFixtures(label: "aud-join4"); defer { fx.cleanup() }
            let a = try tone(fx, "a.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 440)
            let b = try tone(fx, "b.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 660)
            let c = try tone(fx, "c.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 880)
            let gap = try unwrap(AudTestKit.decode(try await join([a, b, c], [AudioKeys.joinGap: 0.5]).outputs[0], in: fx.root))
            try expectClose(gap.seconds, 4.0, tolerance: 0.002)
            try expect(AudTestKit.rms(gap.ch[0], from: 44_100 + 2_000, to: 44_100 + 20_000) < 1e-4, "the pause is silent")
            try expect(AudTestKit.rms(gap.ch[0], from: 44_100 + 24_000, to: 44_100 + 26_000) > 0.1, "the next file starts after it")
            let fade = try unwrap(AudTestKit.decode(try await join([a, b, c], [AudioKeys.joinCrossfade: 0.2]).outputs[0], in: fx.root))
            try expectClose(fade.seconds, 3.0 - 2 * 0.2, tolerance: 0.002)
            // Equal-power crossfade of two different tones keeps the level through the joint.
            let mid = Int(0.9 * 44_100)
            try expectClose(AudTestKit.rms(fade.ch[0], from: mid - 2_000, to: mid + 2_000), 0.4 / 2.0.squareRoot(), tolerance: 0.05, "no dip at the joint")
        }

        t.register("audio.join", "lossless inputs joined into FLAC give back every sample, one after the other") {
            let fx = TestFixtures(label: "aud-join5"); defer { fx.cleanup() }
            let a = try AudTestKit.writeWAV(AudTestKit.chirp(seconds: 1.5, rate: 44_100, channels: 2, seed: 1), to: fx.url("a.wav"))
            let b = try AudTestKit.writeWAV(AudTestKit.chirp(seconds: 1.0, rate: 44_100, channels: 2, seed: 2), to: fx.url("b.wav"))
            let refA = try unwrap(AudTestKit.parseWAV(a)), refB = try unwrap(AudTestKit.parseWAV(b))
            let out = try await join([a, b], [AudioKeys.target: "flac"]).outputs[0]
            try expectEqual(AudTestKit.sniff(out), "flac")
            let s = try unwrap(AudTestKit.decode(out, in: fx.root))
            let expected = AudSig(rate: 44_100, ch: (0..<2).map { refA.ch[$0] + refB.ch[$0] })
            try expectClose(AudTestKit.maxDiff(s, expected), 0, tolerance: 1.0 / 32_768 * 1.01, "bit-exact concatenation")
        }

        t.register("audio.join", "M4A files joined keep the first file's tags and cover; MP3 output goes through the external encoder") {
            let fx = TestFixtures(label: "aud-join6"); defer { fx.cleanup() }
            let (srcA, _) = try AudioNativeTests.source(fx, "a.wav", seconds: 2)
            let (srcB, _) = try AudioNativeTests.source(fx, "b.wav", seconds: 1)
            let cover = try fx.jpeg("cover.jpg", width: 300, height: 300)
            let toM4A = try AudTestKit.operation("audio.to.m4a")
            let a = try await AudTestKit.run(toM4A, [srcA], [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Первый", AudioKeys.tagArtist: "Me", AudioKeys.coverMode: "replace", AudioKeys.coverFile: .string(cover.path)]).outputs[0]
            let b = try await AudTestKit.run(toM4A, [srcB], [AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Второй"]).outputs[0]
            let joined = try await join([a, b]).outputs[0]
            try expectEqual(AudTestKit.sniff(joined), "m4a")
            let info = try await AudioNativeTests.avf(joined)
            try expectEqual(info.tags.title, "Первый"); try expectEqual(info.tags.artist, "Me"); try expect(info.hasCover, "cover of the first file")
            try expectClose(try unwrap(info.duration), 3.0, tolerance: 0.03)
            try AudTestKit.needsEncoder("libmp3lame")
            let mp3 = try await join([a, b], [AudioKeys.target: "mp3", AudioKeys.bitrate: 192, AudioKeys.rateControl: "bitrate"]).outputs[0]
            let fp = try unwrap(AudTestKit.probe(mp3))
            try expectEqual(fp.codec, "mp3"); try expectEqual(fp.rate, 44_100); try expectEqual(fp.channels, 2); try expectClose(fp.duration, 3.0, tolerance: 0.08)
            try expectEqual(fp.tags["title"], "Первый"); try expect(fp.hasPicture)
        }

        t.register("audio.join", "joining into Ogg Vorbis, Opus and mono MP3 uses the same encoders as converting and keeps the best rate") {
            let fx = TestFixtures(label: "aud-join8"); defer { fx.cleanup() }
            let a = try tone(fx, "a.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 440)
            let b = try tone(fx, "b.wav", seconds: 1, rate: 48_000, channels: 2, frequency: 880)
            let env = AudEnvironment.current()
            if env.canEncodeVorbis {
                let ogg = try await join([a, b], [AudioKeys.target: "ogg"]).outputs[0]
                let fp = try unwrap(AudTestKit.probe(ogg))
                try expectEqual(fp.codec, "vorbis"); try expectEqual(fp.rate, 48_000); try expectEqual(fp.channels, 2); try expectClose(fp.duration, 2.0, tolerance: 0.1)
                try expectEqual(FormatSniffer.sniff(ogg)?.key, "ogg")
            }
            if env.hasSoxVorbis, env.hasVorbis {      // force the sox path as well
                var noLib = env; noLib.encoders.remove("libvorbis")
                let viaSox = try await AudTestKit.withEnvironment(noLib) { try await join([a, b], [AudioKeys.target: "ogg"]) }
                try expectEqual(try unwrap(AudTestKit.probe(viaSox.outputs[0])).codec, "vorbis")
            }
            if env.hasOpus {
                let opus = try await join([a, b], [AudioKeys.target: "opus"]).outputs[0]
                let fp = try unwrap(AudTestKit.probe(opus))
                try expectEqual(fp.codec, "opus"); try expectEqual(fp.rate, 48_000); try expectClose(fp.duration, 2.0, tolerance: 0.1)
            }
            if env.canEncodeMP3 {
                let mono = try await join([a, b], [AudioKeys.target: "mp3", AudioKeys.joinChannels: "mono", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 128]).outputs[0]
                let fp = try unwrap(AudTestKit.probe(mono))
                try expectEqual(fp.codec, "mp3"); try expectEqual(fp.channels, 1); try expectEqual(fp.rate, 48_000); try expectClose(fp.duration, 2.0, tolerance: 0.1)
            }
        }

        t.register("audio.join", "needs two files; a file without sound makes the join fail with a clear message and no output") {
            let fx = TestFixtures(label: "aud-join7"); defer { fx.cleanup() }
            let a = try tone(fx, "a.wav", seconds: 1, rate: 44_100, channels: 1, frequency: 440)
            let junk = try fx.text("broken.wav", "not audio")
            let op = try AudTestKit.operation("audio.concat")
            try expect(!op.appliesTo([FileItem(url: a, isDirectory: false)]), "one file cannot be joined")
            try expect(op.appliesTo([FileItem(url: a, isDirectory: false), FileItem(url: a, isDirectory: false)]))
            let err = try await expectThrows { _ = try await join([a, junk]) }
            try expect(!ConversionError.describe(err).isEmpty)
            try expect(TestFile.partials(in: fx.root).isEmpty, "no partial file")
            try expect(!FileManager.default.fileExists(atPath: fx.url("a (joined).wav").path), "no output for a failed join")
        }
    }
}
