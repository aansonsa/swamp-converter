import Foundation

// Default oracles for video conversions. The fixture is a moving 640x360 / 25 fps / 3 s H.264 + AAC clip with film grain (ConformanceFixtures.movingVideo).
// A conversion must keep resolution (even-rounded), frame rate, frame count, duration and the sound, use the codec family its container is meant for, and stay
// close to the source: SSIM / PSNR are measured by ffmpeg on aligned frames. Floors come from the calibration run on the same fixture:
//   x264 CRF 23: SSIM 0.954, PSNR 41.3 dB; CRF 28: 0.946, 39.7 dB; CRF 35: 0.937, 36.6 dB; VP9 CRF 32: 0.951, 41.4 dB; GIF at 10 fps: 0.51, 22.3 dB.

extension ConformanceOracles {
    static let videoContainerTargets: Set<String> = ["mp4", "mov", "mkv", "webm", "gif", "m4v"]
    /// Codecs each container's video track may use for an operation named after the container.
    static let videoCodecsByTarget: [String: Set<String>] = ["mp4": ["h264", "hevc", "av1"], "mov": ["h264", "hevc", "prores"], "mkv": ["h264", "hevc", "av1", "vp9"],
                                                              "webm": ["vp9", "vp8", "av1"], "gif": ["gif"], "m4v": ["h264", "hevc"]]
    static let audioCodecsByTarget: [String: Set<String>] = ["mp4": ["aac", "alac", "mp3", "ac3", "eac3"], "mov": ["aac", "alac", "pcm_s16le", "pcm_s16be", "mp3"], "mkv": ["aac", "opus", "mp3", "vorbis", "flac", "ac3"],
                                                              "webm": ["opus", "vorbis"], "m4v": ["aac", "alac"]]
    /// (SSIM, PSNR dB) floors against the source.
    static let videoFloors: [String: (Double, Double)] = ["mp4": (0.92, 34), "mov": (0.92, 34), "mkv": (0.92, 34), "m4v": (0.92, 34), "webm": (0.92, 34), "gif": (0.40, 18)]

    static let videoConvert = ConformanceOracle(
        id: "video.convert", priority: 0,
        match: { m in
            m.wheel == .convert && (m.targetFormat.map { videoContainerTargets.contains($0) } ?? false)
                && (m.inputs?.isDisjoint(with: Formats.videoInputs.union(["gif"])) == false)
        },
        requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 600,
        cases: { meta, fx in
            let target = meta.targetFormat ?? "mp4"
            if meta.inputs == ["gif"] {
                let clip = try await fx.movingVideo("clip.mov", ConformanceFixtures.VideoSpec(seconds: 2, size: CGSize(width: 480, height: 270)))
                return fx.animatedGIF(from: clip).map { [ConformanceCase(label: "gif", inputs: [$0])] } ?? []
            }
            let nativeKey = target == "mp4" || target == "m4v" ? "mov" : "mp4"
            let clip = try await fx.movingVideo("clip.\(nativeKey)")
            var cases = [ConformanceCase(label: nativeKey, inputs: [clip])]
            if (meta.inputs?.contains("mkv") ?? false), target != "mkv", let mkv = fx.videoVariant(of: clip, ext: "mkv") { cases.append(ConformanceCase(label: "mkv", inputs: [mkv])) }
            return cases
        },
        verify: { run in try await verifyVideoConvert(run) },
        proves: "the output plays and matches the source: container, codec family, resolution, fps, frame count and duration kept; sound kept; SSIM/PSNR above floors and as good as x264 at the same size; quality knob monotonic; mp4 fast start")

    @MainActor
    static func verifyVideoConvert(_ run: ConformanceRun) async throws {
        let target = run.meta.targetFormat ?? "mp4"
        let out = try run.sole()
        guard let src = ExternalProbe.ffprobe(run.input, countFrames: true), let sv = src.video.first, let dst = ExternalProbe.ffprobe(out, countFrames: true), let ov = dst.video.first else {
            throw run.fail("ffprobe cannot read the source or the output video stream")
        }
        let isGIF = target == "gif"
        let codecs = videoCodecsByTarget[target] ?? []
        try expect(codecs.contains(ov.codec), "a .\(target) conversion wrote the video codec \(ov.codec); expected one of \(codecs.sorted())")
        let ew = (sv.width ?? 0) & ~1, eh = (sv.height ?? 0) & ~1
        if isGIF {
            try expect((ov.width ?? 0) <= 640 && (ov.width ?? 0) > 0, "GIF width \(ov.width ?? 0) should be at most 640")
            try expect(abs(Double(ov.width ?? 1) / Double(ov.height ?? 1) - Double(sv.width ?? 1) / Double(sv.height ?? 1)) < 0.03, "GIF aspect ratio changed")
        } else {
            try expect(abs((ov.width ?? 0) - ew) <= 1 && abs((ov.height ?? 0) - eh) <= 1, "resolution \(ov.width ?? 0)x\(ov.height ?? 0) differs from the source \(ew)x\(eh)")
            try expect(abs((ov.fps ?? 0) - (sv.fps ?? 0)) <= 0.2, "frame rate \(ov.fps ?? 0) differs from the source \(sv.fps ?? 0)")
            try expect(abs((ov.frames ?? 0) - (sv.frames ?? 0)) <= 2, "frame count \(ov.frames ?? 0) differs from the source \(sv.frames ?? 0)")
        }
        let tolerance = isGIF ? 0.25 : 0.1
        try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= tolerance, String(format: "duration %.3f s differs from the source %.3f s", dst.duration ?? 0, src.duration ?? 0))
        if !isGIF, !src.audio.isEmpty {
            guard let oa = dst.audio.first else { throw run.fail("the source has sound but the \(target) output has none") }
            try expect(audioCodecsByTarget[target]?.contains(oa.codec) ?? true, "audio codec \(oa.codec) is not usual for .\(target)")
            try expectEqual(oa.channels, src.audio[0].channels, "audio channel count")
            if let ad = oa.duration { try expect(abs(ad - (dst.duration ?? ad)) <= 0.15, "audio and video lengths differ: \(ad) vs \(dst.duration ?? 0)") }
        }
        if target == "mp4", let key = run.options.keys.first(where: { $0.hasSuffix("faststart") }), run.options.bool(key) {
            try expect(Mp4Layout.isFastStart(out), "\(key) is on but the index (moov) is after the media data (mdat)")
        }
        var floor = videoFloors[target] ?? (0.9, 30)
        if run.testCase.label == "gif" { floor = (0.85, 28) }   // a GIF source is already palette-quantised: the second encode starts from a rougher picture
        guard let sim = VideoFidelity.similarity(reference: run.input, test: out, fps: isGIF ? (src.video.first?.fps.map { min($0, 10) } ?? 10) : nil) else { throw run.fail("cannot measure SSIM / PSNR") }
        try expect(sim.ssim >= floor.0, "SSIM \(String(format: "%.3f", sim.ssim)) is below the floor of \(floor.0) for .\(target)")
        try expect(sim.psnr >= floor.1, "PSNR \(String(format: "%.1f", sim.psnr)) dB is below the floor of \(floor.1) dB for .\(target)")
        run.note("\(ov.codec) \(ov.width ?? 0)x\(ov.height ?? 0) \(String(format: "%.1f", ov.fps ?? 0)) fps, " + sim.summary)
        guard !isGIF, run.testCase.label == "mov" || run.testCase.label == "mp4", target == "mp4" else { return }
        try await verifyVideoKnob(run, source: run.input)
        if ov.codec == "h264" { try verifyX264Parity(run, out: out, ssim: sim.ssim) }
    }

    @MainActor
    private static func verifyVideoKnob(_ run: ConformanceRun, source: URL) async throws {
        // "cq" is the software scale (CRF, lower = better), "cq.hw" the VideoToolbox one (higher = better); whichever is active in this run is the quality knob.
        guard let (f, r) = ConformanceSchema.knob(of: run, names: ["cq", "cq.hw", "crf", "video.crf", "video.quality"], exact: true) else { return }
        var points: [(size: Int64, ssim: Double)] = []
        for pos in [0.35, 0.70] {
            let v = (r.lowerBound + (r.upperBound - r.lowerBound) * pos).rounded()
            let again = try await ConformanceRunner.execute(run.operation, run.testCase, with: [f.key: .double(v)], fx: run.fx)
            let o = try again.sole()
            guard let sim = VideoFidelity.similarity(reference: source, test: o) else { throw run.fail("cannot measure the quality sweep") }
            points.append((TestFile.size(o), sim.ssim))
        }
        try expect(points[0].size != points[1].size, "\(f.key) has no effect on the file size")
        let (small, big) = points[0].size < points[1].size ? (points[0], points[1]) : (points[1], points[0])
        try expect(small.ssim <= big.ssim + 0.002, String(format: "%@: the smaller file must not look better (SSIM %.4f small, %.4f big)", f.key, small.ssim, big.ssim))
        run.note("\(f.key) sweep: \(small.size)->\(big.size) B, SSIM \(String(format: "%.4f->%.4f", small.ssim, big.ssim))")
    }

    private static func verifyX264Parity(_ run: ConformanceRun, out: URL, ssim: Double) throws {
        guard ExternalProbe.has(.ffmpeg) else { return }
        let dir = AppPaths.makeTempDirectory(purpose: "ref")
        defer { AppPaths.removeTemp(dir) }
        // Parameter p stands for CRF (51 - p): a larger p is a larger file, as the comparison needs.
        let v = ReferenceParity.compare(oursBytes: TestFile.size(out), oursMetric: ssim, range: 11...41, tolerance: 0.01,
                                        render: { ReferenceParity.x264(run.input, crf: 51 - $0, into: dir) },
                                        metric: { VideoFidelity.similarity(reference: run.input, test: $0)?.ssim })
        if let v {
            try expect(v.passes, "worse than libx264 (preset medium) at the same size: " + v.summary)
            run.note("parity: " + v.summary)
        }
    }

    // MARK: Sound track from a video

    static let videoToAudio = ConformanceOracle(
        id: "video.to-audio", priority: 0,
        match: { m in m.wheel == .convert && (m.targetFormat.map { audioTargets.contains($0) } ?? false) && (m.inputs?.isDisjoint(with: Formats.videoInputs) == false) && (m.inputs?.isDisjoint(with: Formats.audioInputs) ?? true) },
        requires: ["tool.ffprobe"], timeout: 300,
        cases: { _, fx in [ConformanceCase(label: "mp4", inputs: [try await fx.movingVideo("clip.mp4")])] },
        verify: { run in
            let out = try run.sole()
            guard let src = ExternalProbe.ffprobe(run.input), let a = src.audio.first, let dst = ExternalProbe.ffprobe(out) else { throw run.fail("ffprobe cannot read source or output") }
            try expect(dst.video.isEmpty, "an audio-only output still has a video stream")
            try expectEqual(dst.audio.first?.channels, a.channels, "channel count")
            try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration \(dst.duration ?? 0) vs \(src.duration ?? 0)")
            guard let ref = AudioFidelity.decode(run.input), let got = AudioFidelity.decode(out) else { throw run.fail("cannot decode the sound") }
            let n = min(ref.frames, got.frames)
            var r = ref, g = got
            if abs(g.sampleRate - r.sampleRate) > 0.5, let rs = AudioFidelity.resampled(r, to: g.sampleRate) { r = rs }
            r.channels = r.channels.map { Array($0.prefix(min(n, r.frames))) }; g.channels = g.channels.map { Array($0.prefix(min(n, g.frames))) }
            guard let m = AudioFidelity.match(ref: r, test: g) else { throw run.fail("cannot compare the sound") }
            try expect(m.snr >= 20, "the extracted sound differs from the video's sound track: \(m.summary)")
            run.note(m.summary)
        },
        proves: "the output is the video's own sound track (no picture, channels and length kept, SNR against the original sound)")
}
