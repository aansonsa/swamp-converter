import Foundation

// Oracles for the one-tap video tools. Each is judged against what its name promises, with the expected picture built by ffmpeg's own filters applied to
// the SOURCE (transpose for a rotation, setpts for a speed-up, trim for a cut) and compared with the output by SSIM / PSNR on aligned frames.

extension ConformanceOracles {
    private static func videoTool(_ id: String, proves: String, spec: ConformanceFixtures.VideoSpec = ConformanceFixtures.VideoSpec(), label: String = "clip",
                                  extra: OptionValues = OptionValues(),
                                  verify: @escaping @MainActor (ConformanceRun, FFProbeInfo, FFProbeInfo) async throws -> Void) -> ConformanceOracle {
        ConformanceOracle(
            id: id, priority: 10, match: { $0.id == id }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 600,
            cases: { meta, fx in
                let clip = try await fx.movingVideo("clip.mp4", spec)
                var c = ConformanceCase(label: label, inputs: [clip])
                c.extra = extra
                return [c]
            },
            verify: { run in
                guard let src = ExternalProbe.ffprobe(run.input, countFrames: true), let dst = ExternalProbe.ffprobe(try run.sole(), countFrames: true), src.video.first != nil, dst.video.first != nil else {
                    throw run.fail("ffprobe cannot read the source or the output video")
                }
                try await verify(run, src, dst)
            }, proves: proves)
    }

    static let videoCompress = videoTool("video.compress", proves: "H.264 + AAC in MP4, much smaller than the source, same size and length, still close to it (SSIM/PSNR)") { run, src, dst in
        let out = try run.sole()
        let a = TestFile.size(run.input), b = TestFile.size(out)
        try expect(b < a, "compressing made the file larger: \(a) -> \(b) bytes")
        try expectEqual(dst.video[0].codec, "h264", "video codec")
        try expect(abs((dst.video[0].width ?? 0) - (src.video[0].width ?? 0)) <= 1, "the picture size changed")
        try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration changed")
        try expect(!dst.audio.isEmpty, "the sound was dropped")
        guard let sim = VideoFidelity.similarity(reference: run.input, test: out) else { throw run.fail("cannot measure similarity") }
        try expect(sim.ssim >= 0.90 && sim.psnr >= 32, "too much damage: " + sim.summary)
        run.note("\(Util.formatBytes(a)) -> \(Util.formatBytes(b)), " + sim.summary)
    }

    static let video720p = ConformanceOracle(
        id: "video.720p", priority: 10, match: { $0.id == "video.720p" }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 600,
        cases: { _, fx in
            [ConformanceCase(label: "1080p", inputs: [try await fx.movingVideo("hd.mp4", ConformanceFixtures.VideoSpec(seconds: 1, size: CGSize(width: 1920, height: 1080), bitrate: 6_000_000))]),
             ConformanceCase(label: "360p", inputs: [try await fx.movingVideo("sd.mp4", ConformanceFixtures.VideoSpec(seconds: 1.5))])]
        },
        verify: { run in
            guard let src = ExternalProbe.ffprobe(run.input), let dst = ExternalProbe.ffprobe(try run.sole(), countFrames: true), let sv = src.video.first, let dv = dst.video.first else { throw run.fail("ffprobe failed") }
            let expectedH = min(720, sv.height ?? 0) & ~1
            try expect(abs((dv.height ?? 0) - expectedH) <= 1, "height \(dv.height ?? 0) px, expected \(expectedH) (720 at most, never enlarged)")
            try expect(abs(Double(dv.width ?? 1) / Double(dv.height ?? 1) - Double(sv.width ?? 1) / Double(sv.height ?? 1)) < 0.01, "aspect ratio changed")
            try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration changed")
            guard let sim = VideoFidelity.similarity(reference: run.input, test: try run.sole()) else { throw run.fail("cannot measure similarity") }
            try expect(sim.ssim >= 0.88 && sim.psnr >= 30, "the picture is damaged: " + sim.summary)
            run.note("\(dv.width ?? 0)x\(dv.height ?? 0), " + sim.summary)
        }, proves: "height 720 at most (1080p becomes 720p, 360p stays 360p), aspect kept, same length, close to the source")

    static let videoMute = videoTool("video.mute", proves: "no sound track left, the picture untouched (stream copy where the container allows it)") { run, src, dst in
        let out = try run.sole()
        try expect(dst.audio.isEmpty, "the output still has \(dst.audio.count) audio stream(s)")
        try expectEqual(dst.video.count, 1, "video stream count")
        try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration changed")
        if let a = VideoFidelity.videoStreamMD5(run.input), let b = VideoFidelity.videoStreamMD5(out) {
            if a == b { run.note("video stream copied bit for bit, sound removed") } else {
                guard let sim = VideoFidelity.similarity(reference: run.input, test: out) else { throw run.fail("cannot measure similarity") }
                try expect(sim.ssim >= 0.9, "the picture changed: " + sim.summary)
                run.note("video re-encoded (not a stream copy), " + sim.summary)
            }
        }
    }

    static let videoTrim = ConformanceOracle(
        id: "video.trim", priority: 10, match: { $0.id == "video.trim" }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 600,
        cases: { meta, fx in
            var c = ConformanceCase(label: "0.8 s to 2.4 s", inputs: [try await fx.movingVideo("clip.mp4")])
            if meta.quickPromptKeys.count >= 2 { c.extra = [meta.quickPromptKeys[0]: .double(0.8), meta.quickPromptKeys[1]: .double(2.4)] }
            return [c]
        },
        verify: { run in
            guard run.meta.quickPromptKeys.count >= 2 else { throw run.fail("trim should declare its start and end keys as quickPromptKeys") }
            let out = try run.sole()
            guard let dst = ExternalProbe.ffprobe(out, countFrames: true), let dv = dst.video.first else { throw run.fail("ffprobe failed") }
            try expect(abs((dst.duration ?? 0) - 1.6) <= 0.12, String(format: "duration %.3f s, expected 1.6 s (0.8 to 2.4, end is an absolute time)", dst.duration ?? 0))
            try expect(abs((dv.frames ?? 0) - 40) <= 3, "frame count \(dv.frames ?? 0), expected about 40")
            if let a = dst.audio.first?.duration { try expect(abs(a - 1.6) <= 0.15, "the sound is \(a) s long, expected 1.6 s") }
            guard let sim = VideoFidelity.similarity(reference: run.input, test: out, referenceFilter: "trim=start=0.8:end=2.4,setpts=PTS-STARTPTS") else { throw run.fail("cannot measure similarity") }
            try expect(sim.ssim >= 0.88, "the kept part is not the asked part of the source: " + sim.summary)
            run.note("\(String(format: "%.2f", dst.duration ?? 0)) s, " + sim.summary)
        }, proves: "exactly the asked range (start 0.8 s, end 2.4 s absolute) of the source, picture and sound")

    static let videoRotate = videoTool("video.rotate", proves: "turned 90 degrees clockwise: size swapped, picture equal to ffmpeg's transpose of the source") { run, src, dst in
        let out = try run.sole()
        let sv = src.video[0], dv = dst.video[0]
        try expect(abs((dv.width ?? 0) - (sv.height ?? 0)) <= 1 && abs((dv.height ?? 0) - (sv.width ?? 0)) <= 1, "expected \(sv.height ?? 0)x\(sv.width ?? 0), got \(dv.width ?? 0)x\(dv.height ?? 0)")
        try expect(dv.rotation == nil || dv.rotation == 0, "the rotation was left as metadata (\(dv.rotation ?? 0)) instead of turning the picture")
        guard let sim = VideoFidelity.similarity(reference: run.input, test: out, referenceFilter: "transpose=1") else { throw run.fail("cannot measure similarity") }
        try expect(sim.ssim >= 0.88 && sim.psnr >= 30, "the picture is not the source turned clockwise: " + sim.summary)
        run.note(sim.summary)
    }

    static let videoSpeed2 = videoTool("video.speed2", proves: "twice as fast: half the length, picture equal to the source with setpts=0.5*PTS, sound sped up too") { run, src, dst in
        let out = try run.sole()
        try expect(abs((dst.duration ?? 0) - (src.duration ?? 0) / 2) <= 0.12, String(format: "duration %.3f s, expected %.3f s", dst.duration ?? 0, (src.duration ?? 0) / 2))
        if let a = dst.audio.first?.duration { try expect(abs(a - (src.duration ?? 0) / 2) <= 0.15, "the sound is \(a) s long; it must be sped up as well") }
        try expect(!dst.audio.isEmpty || src.audio.isEmpty, "the sound was dropped")
        guard let sim = VideoFidelity.similarity(reference: run.input, test: out, fps: src.video[0].fps, referenceFilter: "setpts=0.5*PTS") else { throw run.fail("cannot measure similarity") }
        try expect(sim.ssim >= 0.80, "the picture is not the source at double speed: " + sim.summary)
        run.note(String(format: "%.2f s from %.2f s, ", dst.duration ?? 0, src.duration ?? 0) + sim.summary)
    }

    static let videoThumbnail = ConformanceOracle(
        id: "video.thumbnail", priority: 10, match: { $0.id == "video.thumbnail" }, requires: ["tool.ffprobe"], timeout: 300,
        cases: { _, fx in [ConformanceCase(label: "clip", inputs: [try await fx.movingVideo("clip.mp4")])] },
        verify: { run in
            let out = try run.sole()
            guard let thumb = ImageFidelity.decode(out), let info = ExternalProbe.ffprobe(run.input), let v = info.video.first else { throw run.fail("cannot decode the thumbnail") }
            try expect(thumb.width == v.width && thumb.height == v.height, "the thumbnail is \(thumb.width)x\(thumb.height), the video \(v.width ?? 0)x\(v.height ?? 0)")
            // The reference frames come from ffmpeg (the engine's decoder family): AVFoundation applies another YUV-to-RGB matrix to untagged H.264 and would differ by a few dB.
            guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { try skipTest("ffmpeg is needed to extract the reference frames") }
            let dir = AppPaths.makeTempDirectory(purpose: "thumb")
            defer { AppPaths.removeTemp(dir) }
            _ = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-i", run.input.path, "-frames:v", "150", dir.appendingPathComponent("f%03d.png").path], timeout: 120)
            let frames = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { ImageFidelity.decode(dir.appendingPathComponent($0)) }
            try expect(frames.count > 10, "cannot extract reference frames of the source")
            let best = frames.compactMap { ImageFidelity.psnr($0, thumb) }.max() ?? 0
            try expect(best >= 34, String(format: "the thumbnail matches no frame of the video (best PSNR %.1f dB)", best))
            run.note(String(format: "equals a real frame (PSNR %.1f dB)", best))
        }, proves: "a PNG of the video's own size that is a real frame of the video")
}
