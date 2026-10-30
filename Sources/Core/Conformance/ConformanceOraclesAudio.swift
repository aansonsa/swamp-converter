import Foundation

// Default oracles for audio conversions. The fixture is a stereo chirp / tone / burst / noise mix (see ConformanceFixtures.chirp), so channel mix-ups,
// delay, clipping and codec damage all show up as numbers. Lossless targets must be sample-exact; lossy ones must reach an SNR floor measured against
// real encoders on the same fixture (see the conformance.calibration self-test) and be as good as afconvert / LAME at the same file size.

extension ConformanceOracles {
    static let audioTargets: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aac", "caf"]
    static let losslessAudio: Set<String> = ["wav", "flac", "aiff", "caf"]
    /// Expected codec name of each target (ffprobe vocabulary).
    static let audioCodecs: [String: String] = ["wav": "pcm_s16le", "aiff": "pcm_s16be", "flac": "flac", "mp3": "mp3", "m4a": "aac", "aac": "aac", "ogg": "vorbis", "opus": "opus"]
    /// SNR floors (dB) against the source after alignment. The calibration self-test shows what real encoders reach on the fixture (afconvert AAC 192k 32.5 dB,
    /// LAME V2 28.7 dB, Opus 128k 26.2 dB) and demands a margin of 3 dB or more between each reference and its floor.
    static let audioSNRFloor: [String: Double] = ["m4a": 26, "aac": 26, "mp3": 22, "ogg": 16, "opus": 18]

    static let audioConvert = ConformanceOracle(
        id: "audio.convert", priority: 0,
        match: { m in m.wheel == .convert && (m.targetFormat.map { audioTargets.contains($0) } ?? false) && (m.inputs?.isDisjoint(with: Formats.audioInputs) == false) },
        timeout: 300,
        cases: { meta, fx in
            let target = meta.targetFormat ?? "mp3"
            let stereo = try fx.chirp("stereo.wav", seconds: 3, rate: 44_100, channels: 2)
            let mono = try fx.chirp("mono.wav", seconds: 2, rate: 22_050, channels: 1)
            func asInput(_ u: URL) -> URL? {
                if target != "wav" { return u }
                return fx.audioVariant(of: u, ext: "flac")   // wav is hidden when the input is already wav
            }
            return [("stereo44", stereo), ("mono22", mono)].compactMap { label, u in asInput(u).map { ConformanceCase(label: label, inputs: [$0]) } }
        },
        verify: { run in try await verifyAudioConvert(run) },
        proves: "decodes to the same sound: lossless targets sample-exact, lossy ones above an SNR floor after alignment and as good as afconvert/LAME at the same size; duration within 20 ms; channels kept; codec as named")

    @MainActor
    static func verifyAudioConvert(_ run: ConformanceRun) async throws {
        let target = run.meta.targetFormat ?? ""
        let out = try run.sole()
        guard let ref = AudioFidelity.decode(run.input), var got = AudioFidelity.decode(out) else { throw run.fail("cannot decode source or output") }
        let sniffed = FormatSniffer.sniff(out)
        if let codec = audioCodecs[target] { try expect(sniffed?.codecs.contains(codec) ?? (target == "mp3"), "\(target) should hold \(codec), the container says \(sniffed?.codecs ?? [])") }
        try expectEqual(got.channelCount, ref.channelCount, "channel count must be kept")
        var reference = ref
        if abs(got.sampleRate - ref.sampleRate) > 0.5 {
            // Allowed only where the format forces a rate (Opus is always 48 kHz); the comparison is then made at the output rate.
            try expect(target == "opus" || run.options.has("audio.sampleRate") || run.options.has("sampleRate"), "sample rate changed from \(Int(ref.sampleRate)) to \(Int(got.sampleRate)) Hz without a reason")
            guard let r = AudioFidelity.resampled(ref, to: got.sampleRate) else { throw run.fail("cannot resample the source for comparison") }
            reference = r
            run.note("rate \(Int(ref.sampleRate))->\(Int(got.sampleRate)) Hz")
        }
        let dur = abs(got.duration - reference.duration)
        try expect(dur <= 0.020, String(format: "duration %.3f s vs source %.3f s differs by %.0f ms (limit 20 ms)", got.duration, reference.duration, dur * 1000))
        if losslessAudio.contains(target), abs(got.sampleRate - ref.sampleRate) < 0.5 {
            let r = AudioFidelity.bitExact(ref, got)
            try expect(r.equal, "lossless \(target.uppercased()) must reproduce every sample: \(r.detail)")
            run.note("sample-exact (\(r.detail))")
            return
        }
        // Trim the decoded streams to the common length before measuring.
        let n = min(reference.frames, got.frames)
        reference.channels = reference.channels.map { Array($0.prefix(n)) }
        got.channels = got.channels.map { Array($0.prefix(n)) }
        guard let m = AudioFidelity.match(ref: reference, test: got) else { throw run.fail("cannot align and compare the sound") }
        if let floor = audioSNRFloor[target] {
            try expect(m.snr >= floor, "\(m.summary) is below the \(Int(floor)) dB floor for \(target)")
            try expect(m.correlation >= (target == "opus" ? 0.95 : 0.98), "correlation \(m.correlation) too low: \(m.summary)")
        }
        try expect(AudioFidelity.peak(got) <= 1.2, "decoded peak \(AudioFidelity.peak(got)) clips")
        run.note(m.summary)
        guard run.testCase.label == "stereo44" else { return }
        try await verifyAudioTwin(run, out: out)
        try await verifyAudioKnob(run, ref: reference)
        try verifyAudioParity(run, out: out, ours: m.snr, target: target)
    }

    /// Quick and Studio share one engine: the Studio run with the quick run's resolved options must decode to exactly the same samples.
    @MainActor
    private static func verifyAudioTwin(_ run: ConformanceRun, out: URL) async throws {
        let twin = try await ConformanceRunner.studioTwin(of: run)
        guard let a = AudioFidelity.decode(out), let b = AudioFidelity.decode(try twin.sole()) else { throw run.fail("cannot decode the Studio result") }
        let r = AudioFidelity.bitExact(a, b)
        try expect(r.equal, "Studio and Quick sound different for the same options: \(r.detail)")
    }

    @MainActor
    private static func verifyAudioKnob(_ run: ConformanceRun, ref: AudioSamples) async throws {
        guard let (f, r) = ConformanceSchema.knob(of: run, names: ["bitrate", "quality", "vbr"]) else { return }
        var sizes: [Int64] = [], snrs: [Double] = []
        let low = r.lowerBound + (r.upperBound - r.lowerBound) * 0.15, high = r.upperBound
        for v in [low, high] {
            let again = try await ConformanceRunner.execute(run.operation, run.testCase, with: [f.key: .double(v.rounded())], fx: run.fx)
            let o = try again.sole()
            guard let got = AudioFidelity.decode(o) else { throw run.fail("cannot decode the sweep output") }
            var base = ref
            if abs(got.sampleRate - ref.sampleRate) > 0.5, let rs = AudioFidelity.resampled(ref, to: got.sampleRate) { base = rs }
            let n = min(base.frames, got.frames)
            var a = base, b = got
            a.channels = a.channels.map { Array($0.prefix(n)) }; b.channels = b.channels.map { Array($0.prefix(n)) }
            sizes.append(TestFile.size(o)); snrs.append(AudioFidelity.match(ref: a, test: b)?.snr ?? 0)
        }
        // The knob is "bitrate" or "quality" where more is better; if the field is a VBR scale where lower is better the order flips.
        let ordered = sizes[0] <= sizes[1]
        try expect(sizes[0] != sizes[1], "\(f.key) has no effect on the file size (\(sizes[0]) B at both ends)")
        let (smallSNR, bigSNR) = ordered ? (snrs[0], snrs[1]) : (snrs[1], snrs[0])
        try expect(smallSNR <= bigSNR + 0.5, String(format: "%@: the smaller file must not sound better (%.1f dB small, %.1f dB big)", f.key, smallSNR, bigSNR))
        run.note("\(f.key) \(Int(low))->\(Int(high)): \(sizes[0])->\(sizes[1]) B, \(String(format: "%.1f->%.1f", snrs[0], snrs[1])) dB")
    }

    private static func verifyAudioParity(_ run: ConformanceRun, out: URL, ours: Double, target: String) throws {
        guard let ref = AudioFidelity.decode(run.input) else { return }
        let dir = AppPaths.makeTempDirectory(purpose: "ref")
        defer { AppPaths.removeTemp(dir) }
        func snr(_ u: URL) -> Double? { AudioFidelity.decode(u).flatMap { g in
            let n = min(ref.frames, g.frames)
            var a = ref, b = g
            a.channels = a.channels.map { Array($0.prefix(n)) }; b.channels = b.channels.map { Array($0.prefix(n)) }
            return AudioFidelity.match(ref: a, test: b)?.snr
        } }
        let verdict: ReferenceParity.Verdict?
        switch target {
        case "m4a", "aac":
            verdict = ReferenceParity.compare(oursBytes: TestFile.size(out), oursMetric: ours, range: 32...320, tolerance: 2.0, render: { ReferenceParity.afconvertAAC(run.input, kbps: $0, into: dir) }, metric: snr)
        case "mp3":
            // LAME's VBR scale runs the other way (0 = best): param p stands for -V (9 - p), so a larger p is a larger file.
            verdict = ReferenceParity.compare(oursBytes: TestFile.size(out), oursMetric: ours, range: 0...9, tolerance: 2.0, render: { ReferenceParity.lameVBR(run.input, q: 9 - $0, into: dir) }, metric: snr)
        default: verdict = nil
        }
        if let v = verdict {
            try expect(v.passes, "worse than the reference encoder at the same size: " + v.summary)
            run.note("parity: " + v.summary)
        }
    }
}
