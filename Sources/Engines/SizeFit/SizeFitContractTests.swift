import Foundation
import AVFoundation

// The SIZE CONTRACT on real files: the result is never above the limit, lands within 5 percent below it where physically possible, is really the
// format it claims to be (sniffed by tools that did not write it), keeps the content (duration, picture, sound), reports a downscale, and leaves
// no partial file behind. Tests that need ffmpeg SKIP with the reason.

enum SizeFitContractTests {
    static func register() {
        registerVideo()
        registerAudio()
        SizeFitContractImagePdf.register()
        SizeFitContractExtras.register()
    }

    private typealias S = FitTestSupport

    // MARK: Video

    private static func registerVideo() {
        let t = SelfTestRegistry.shared

        t.register("sizefit", "conformance.fit.video: 5 s clip into a small limit with two passes lands in 95-100% of it, stays H.264 + AAC, same picture and length",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 180) {
            let fx = TestFixtures(label: "fitvideo"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 5)
            let limit: Int64 = 600_000
            let run = try await S.run(src, id: "fit.video", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            let size = TestFile.size(out)
            try expect(size <= limit, "result \(size) is above the limit \(limit)")
            try expect(Double(size) >= Double(limit) * 0.95, "result \(size) is more than 5% under the limit \(limit)")
            try expect(out.lastPathComponent.contains("("), "the name carries the suffix: \(out.lastPathComponent)")
            try expect(out.pathExtension == "mp4")
            let mime = try await FitOracle.mime(out)
            try expect(mime == "video/mp4", "sniffed as \(mime)")
            let f = try await S.videoFacts(out), original = try await S.videoFacts(src)
            try expectEqual(f.videoCodec, "h264"); try expectEqual(f.audioCodec, "aac")
            try expectEqual(f.width, original.width); try expectEqual(f.height, original.height)
            try expectClose(f.duration, original.duration, tolerance: 0.15, "duration")
            try expectClose(f.fps, original.fps, tolerance: 0.5, "frame rate")
            try await S.expectPlayable(out)
            // Reference encoder: plain x264 (medium, single-pass ABR) at the video bitrate our file really has. Ours must be as good or better at the same size.
            let ssim = try await FitOracle.videoSSIM(source: src, output: out, width: f.width, height: f.height)
            let ref = try await S.x264Reference(src, kbps: try await S.videoBitrateKbps(out), in: fx)
            let refSSIM = try await FitOracle.videoSSIM(source: src, output: ref, width: f.width, height: f.height)
            try expect(Double(TestFile.size(ref)) <= Double(size) * 1.04, "reference file \(TestFile.size(ref)) is not comparable with ours \(size)")
            try expect(ssim >= refSSIM - 0.015, "ours SSIM \(ssim) is worse than plain x264 at the same size \(refSSIM)")
            try expect(ssim > 0.5, "picture too far from the source: SSIM \(ssim)")
            try expect(TestFile.partials(in: fx.root).isEmpty, "partial files left: \(TestFile.partials(in: fx.root))")
            try expect(try fx.root.fitStrayFiles().isEmpty, "stray attempt files left")
        }

        t.register("sizefit", "conformance.fit.video: a bigger limit gives a bigger file and a better picture (quality is monotonic)",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 240) {
            let fx = TestFixtures(label: "fitmono"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 4)
            let small = try unwrap(try await S.run(src, id: "fit.video", extra: S.target(bytes: 350_000)).result.outputs.first)
            let large = try unwrap(try await S.run(src, id: "fit.video", extra: S.target(bytes: 900_000)).result.outputs.first)
            try expect(TestFile.size(small) < TestFile.size(large), "sizes \(TestFile.size(small)) vs \(TestFile.size(large))")
            let a = try await FitOracle.videoSSIM(source: src, output: small, width: 640, height: 360)
            let b = try await FitOracle.videoSSIM(source: src, output: large, width: 640, height: 360)
            try expect(a < b, "SSIM small \(a) must be below large \(b)")
        }

        t.register("sizefit", "conformance.fit.video: hardware encoder (single pass + verify and retry) also lands under the limit and above 90%",
                   requires: ["tool.ffmpeg", "ff.enc.h264_videotoolbox"], timeout: 180) {
            let fx = TestFixtures(label: "fitvt"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 5)
            let limit: Int64 = 700_000
            let out = try unwrap(try await S.run(src, id: "fit.video", extra: S.target(bytes: limit), preferHardware: true).result.outputs.first)
            let size = TestFile.size(out)
            try expect(size <= limit, "hardware result \(size) above \(limit)")
            try expect(Double(size) >= Double(limit) * 0.90, "hardware result \(size) is far under \(limit)")
            try await S.expectPlayable(out)
            let f = try await S.videoFacts(out)
            try expectEqual(f.videoCodec, "h264")
        }

        t.register("sizefit", "conformance.fit.video: a tight limit on 720p footage reduces the picture, says so, and stays under the limit",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 240) {
            let fx = TestFixtures(label: "fitdown"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 4, width: 1280, height: 720)
            let limit: Int64 = 250_000
            let run = try await S.run(src, id: "fit.video", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            try expect(TestFile.size(out) <= limit, "result \(TestFile.size(out)) above \(limit)")
            let f = try await S.videoFacts(out)
            try expect(f.height < 720, "the picture should have been reduced, got \(f.width)x\(f.height)")
            try expect(abs(Double(f.width) / Double(f.height) - 16.0 / 9.0) < 0.03, "aspect ratio kept: \(f.width)x\(f.height)")
            let note = try unwrap(run.result.note, "the downscale must be reported")
            try expect(note.en.contains("Reduced to"), note.en); try expect(note.ru.contains("Уменьшено"), note.ru)
            try await S.expectPlayable(out)
        }

        t.register("sizefit", "conformance.fit.video: with downscaling off the picture size stays and the file still fits",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 240) {
            let fx = TestFixtures(label: "fitnodown"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 4, width: 1280, height: 720)
            let limit: Int64 = 400_000
            var extra = S.target(bytes: limit); extra[FitKeys.allowDownscale] = false
            let out = try unwrap(try await S.run(src, id: "fit.video", extra: extra).result.outputs.first)
            try expect(TestFile.size(out) <= limit, "result \(TestFile.size(out)) above \(limit)")
            let f = try await S.videoFacts(out)
            try expectEqual(f.height, 720)
        }

        t.register("sizefit", "conformance.fit.video: a limit that cannot be met fails with a calm message and leaves nothing behind",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 120) {
            let fx = TestFixtures(label: "fitimpossible"); defer { fx.cleanup() }
            // 4 minutes of tiny picture: 50 KB is a bitrate of ~1.6 kbit/s in total, below what makes a picture at all.
            let src = try await S.makeVideo(fx, seconds: 240, width: 160, height: 90, fps: 5, noise: 4)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            let error = try await expectThrows { _ = try await S.run(src, id: "fit.video", extra: S.target(bytes: 50_000)) }
            let text = ConversionError.describe(error)
            try expect(text.lowercased().contains("limit") || text.contains("лимит"), text)
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path)), before, "no output or partial may remain")
        }

        t.register("sizefit", "fit.video odd inputs: silent clip, clip shorter than a second, and a source already under the limit",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 180) {
            let fx = TestFixtures(label: "fitodd"); defer { fx.cleanup() }
            // Silent
            let silent = try await S.makeVideo(fx, "silent.mp4", seconds: 4, audio: false)
            let limit: Int64 = 400_000
            let a = try unwrap(try await S.run(silent, id: "fit.video", extra: S.target(bytes: limit)).result.outputs.first)
            try expect(TestFile.size(a) <= limit && Double(TestFile.size(a)) >= Double(limit) * 0.93, "silent: \(TestFile.size(a))")
            let silentFacts = try await S.videoFacts(a)
            try expect(silentFacts.audioCodec == nil, "a silent clip must not gain a sound track")
            // Shorter than a second
            let tiny = try await S.makeVideo(fx, "tiny.mp4", seconds: 0.6, width: 320, height: 180)
            let tinyLimit: Int64 = 60_000
            let b = try unwrap(try await S.run(tiny, id: "fit.video", extra: S.target(bytes: tinyLimit)).result.outputs.first)
            try expect(TestFile.size(b) <= tinyLimit, "tiny: \(TestFile.size(b)) above \(tinyLimit)")
            let tinyFacts = try await S.videoFacts(b)
            try expectClose(tinyFacts.duration, 0.6, tolerance: 0.2, "tiny duration")
            // Already smaller than the limit: copied, with a note, never grown
            let small = TestFile.size(tiny)
            let run = try await S.run(tiny, id: "fit.video", extra: S.target(bytes: small + 500_000))
            let c = try unwrap(run.result.outputs.first)
            try expectEqual(TestFile.size(c), small, "a file under the limit is copied unchanged")
            try expect(run.result.note != nil, "the copy must be explained")
            try expect(c != tiny, "the original is never overwritten")
        }
    }

    // MARK: Audio

    private static func registerAudio() {
        let t = SelfTestRegistry.shared

        t.register("sizefit", "conformance.fit.audio: 20 s of noise into 300 KB becomes AAC in M4A, 95-100% of the limit, same length, decodable",
                   requires: ["tool.ffmpeg"], timeout: 120) {
            let fx = TestFixtures(label: "fitaudio"); defer { fx.cleanup() }
            let src = try await S.makeAudioNoise(fx, seconds: 20)
            let limit: Int64 = 300_000
            let run = try await S.run(src, id: "fit.audio", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            let size = TestFile.size(out)
            try expect(size <= limit, "result \(size) above \(limit)")
            try expect(Double(size) >= Double(limit) * 0.95, "result \(size) more than 5% under \(limit)")
            try expectEqual(out.pathExtension, "m4a")
            let mime = try await FitOracle.mime(out)
            try expect(mime.hasPrefix("audio/") || mime == "video/mp4", "sniffed as \(mime)")
            let facts = try await S.audioFacts(out)
            try expectEqual(facts.codec, "aac")
            let dur = try await S.duration(out)
            try expectClose(dur, 20, tolerance: 0.1, "duration")
            try expectEqual(facts.sampleRate, 44_100)
        }

        t.register("sizefit", "conformance.fit.audio: a bigger limit gives a higher bitrate (monotonic) and the top of the range is not exceeded",
                   requires: ["tool.ffmpeg"], timeout: 120) {
            let fx = TestFixtures(label: "fitaudiomono"); defer { fx.cleanup() }
            let src = try await S.makeAudioNoise(fx, seconds: 30)
            let a = try unwrap(try await S.run(src, id: "fit.audio", extra: S.target(bytes: 300_000)).result.outputs.first)
            let b = try unwrap(try await S.run(src, id: "fit.audio", extra: S.target(bytes: 600_000)).result.outputs.first)
            try expect(TestFile.size(a) < TestFile.size(b))
            let (fa, fb) = (try await S.audioFacts(a), try await S.audioFacts(b))
            try expect(fa.bitrate < fb.bitrate, "bitrates \(fa.bitrate) vs \(fb.bitrate)")
            // Plenty of room: the sound stops at the best AAC bitrate and the file is smaller than the limit, with a note.
            let big = try await S.run(src, id: "fit.audio", extra: S.target(bytes: 5_000_000))
            let out = try unwrap(big.result.outputs.first)
            try expect(TestFile.size(src) > 5_000_000 && TestFile.size(out) < 5_000_000, "size \(TestFile.size(out))")
            try expect(big.result.note != nil, "stopping below the limit must be explained")
            let topFacts = try await S.audioFacts(out)
            try expect(topFacts.bitrate <= 330_000, "bitrate \(topFacts.bitrate)")
        }

        t.register("sizefit", "conformance.fit.audio: MP3 and Opus come out in their own formats under the limit when the encoders exist",
                   requires: ["tool.ffmpeg", "ff.enc.libmp3lame", "ff.enc.libopus"], timeout: 120) {
            let fx = TestFixtures(label: "fitaudiocodec"); defer { fx.cleanup() }
            let src = try await S.makeAudioNoise(fx, seconds: 12)
            let limit: Int64 = 150_000
            for (codec, ext, name) in [("mp3", "mp3", "mp3"), ("opus", "opus", "opus")] {
                var extra = S.target(bytes: limit); extra[FitKeys.audioCodec] = .string(codec)
                let out = try unwrap(try await S.run(src, id: "fit.audio", extra: extra).result.outputs.first)
                try expectEqual(out.pathExtension, ext)
                try expect(TestFile.size(out) <= limit, "\(codec): \(TestFile.size(out)) above \(limit)")
                try expect(Double(TestFile.size(out)) >= Double(limit) * 0.70, "\(codec): \(TestFile.size(out)) far under \(limit)")
                let facts = try await S.audioFacts(out)
                try expectEqual(facts.codec, name)
            }
        }

        t.register("sizefit", "fit.audio: a recording too long for the limit fails calmly and leaves nothing behind; a small file is copied with a note",
                   requires: ["tool.ffmpeg"], timeout: 60) {
            let fx = TestFixtures(label: "fitaudioimp"); defer { fx.cleanup() }
            let src = try fx.wav("tone.wav", seconds: 30, sampleRate: 22_050)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            let error = try await expectThrows { _ = try await S.run(src, id: "fit.audio", extra: S.target(bytes: 4_000)) }
            try expect(ConversionError.describe(error).count > 20)
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path)), before)
            let tiny = try fx.wav("tiny.wav", seconds: 0.5, sampleRate: 8_000)
            let run = try await S.run(tiny, id: "fit.audio", extra: S.target(bytes: 1_000_000))
            let copy = try unwrap(run.result.outputs.first)
            try expectEqual(TestFile.size(copy), TestFile.size(tiny))
            try expect(run.result.note != nil)
        }
    }
}

extension URL {
    /// Hidden attempt files of the fit loops (".fit-...") left in the folder: must be none after a run.
    func fitStrayFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasPrefix(".fit-") }
    }
}
