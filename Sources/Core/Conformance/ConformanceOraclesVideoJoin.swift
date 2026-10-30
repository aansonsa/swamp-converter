import Foundation
import CoreGraphics

// Oracle of video.concat (Tools > Join). Three clips of different size, frame rate and sound (one has no sound at all) go in, in the "wrong" order for a plain
// string sort; one video comes out whose length is the sum of the clips, whose frames are the clips' frames in natural order (each third compared with its own
// clip by SSIM), whose sound is kept and in step, and which AVFoundation and ffmpeg both read to the end.

extension ConformanceOracles {
    typealias JoinClip = (name: String, size: CGSize, fps: Int, seconds: Double, audio: Bool)
    static let joinClips: [JoinClip] = [
        ("clip1.mp4", CGSize(width: 320, height: 180), 25, 1.0, true),
        ("clip2.mp4", CGSize(width: 256, height: 144), 30, 1.5, false),
        ("clip10.mp4", CGSize(width: 192, height: 108), 24, 2.0, true)
    ]

    static let videoConcat = ConformanceOracle(
        id: "video.concat", priority: 10, match: { $0.id == "video.concat" }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 600,
        cases: { _, fx in
            var inputs: [URL] = []
            for c in joinClips.reversed() {   // dropped in reverse: the operation must sort them itself
                inputs.append(try await fx.movingVideo(c.name, ConformanceFixtures.VideoSpec(seconds: c.seconds, size: c.size, fps: c.fps, audio: c.audio, bitrate: 1_200_000)))
            }
            return [ConformanceCase(label: "3 clips, 3 sizes, 3 rates", inputs: inputs)]
        },
        verify: { run in
            let out = try run.sole()
            let expectedTotal = joinClips.reduce(0) { $0 + $1.seconds }
            guard let info = ExternalProbe.ffprobe(out, countFrames: true), let v = info.video.first else { throw run.fail("ffprobe cannot read the joined video") }
            try expect(abs((info.duration ?? 0) - expectedTotal) <= ConformanceThresholds.joinDurationSeconds, String(format: "length %.3f s, the clips add up to %.3f s", info.duration ?? 0, expectedTotal))
            let fps = v.fps ?? 25
            let wantFrames = expectedTotal * fps
            try expect(abs(Double(v.frames ?? 0) - wantFrames) <= wantFrames * ConformanceThresholds.joinFrameCountTolerance + 2, "frame count \(v.frames ?? 0), expected about \(Int(wantFrames)) (\(expectedTotal) s at \(fps) fps)")
            try expect(v.width == 320 && v.height == 180, "the largest clip sets the size, got \(v.width ?? 0)x\(v.height ?? 0)")
            try expect(info.audio.count == 1, "the sound of the clips is kept in one track (\(info.audio.count) found)")
            if let a = info.audio.first?.duration { try expect(abs(a - (info.duration ?? 0)) <= 0.15, String(format: "sound %.3f s against picture %.3f s: out of step", a, info.duration ?? 0)) }
            let decode = VideoFidelity.decodesCleanly(out)
            try expect(decode.ok, "ffmpeg cannot decode the result to its end: \(decode.message)")
            let play = await VideoFidelity.playback(of: out, maxVideoFrames: 10_000)
            try expect(play.isPlayable && play.readError == nil && play.videoFrames > 0, "AVFoundation cannot play it: " + play.summary)
            // Each part is its own clip, in natural order (clip1, clip2, clip10): cut the part out losslessly and compare with the source clip.
            guard let ffmpeg = ExternalProbe.path(.ffmpeg) else { throw run.fail("ffmpeg is needed to cut the parts") }
            var start = 0.0
            var worst = 1.0
            for c in joinClips {
                let part = run.workDir.appendingPathComponent(".part-\(c.name).mkv")
                defer { try? FileManager.default.removeItem(at: part) }
                let cut = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-ss", String(start + 0.04), "-t", String(c.seconds - 0.12), "-i", out.path, "-an", "-c:v", "ffv1", part.path], timeout: 120)
                guard cut.status == 0 else { throw run.fail("cannot cut the part of \(c.name): \(cut.error.prefix(160))") }
                let source = run.inputs.first { $0.lastPathComponent == c.name }!
                guard let sim = VideoFidelity.similarity(reference: source, test: part, size: (192, 108), fps: 24, referenceFilter: "trim=start=0.04:end=\(c.seconds - 0.08),setpts=PTS-STARTPTS") else { throw run.fail("cannot measure similarity for \(c.name)") }
                try expect(sim.ssim >= 0.80, "the part at \(start) s is not \(c.name): " + sim.summary)
                worst = min(worst, sim.ssim)
                start += c.seconds
            }
            // A wrong order would put clip10 second: the three parts above would not match their clips.
            let name = out.lastPathComponent
            try expect(name.hasPrefix("clip1 (") && (name.contains("(joined)") || name.contains("(объединено)")), "named after the first sorted clip with the suffix: \(name)")
            run.note(String(format: "%.2f s, %d frames, %dx%d, worst part SSIM %.3f", info.duration ?? 0, v.frames ?? 0, v.width ?? 0, v.height ?? 0, worst))
        },
        proves: "length = sum of the clips, frame count = length x rate, the largest size, one sound track in step, every part equal (SSIM) to its own clip in natural order, readable by ffmpeg and AVFoundation")
}
