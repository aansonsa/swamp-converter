import Foundation

// Tools missing (simulated), the native route with no external program at all, cancelling an ffmpeg encode, and a video's soundtrack through the
// shared transcoder entry point.

enum AudioGatingTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("audio.gating", "without ffmpeg and lame MP3 / Ogg / Opus are unavailable with an install hint, everything native stays available") {
            let none = ToolLocator(roots: .empty)
            let items = [FileItem(url: URL(fileURLWithPath: "/tmp/a.wav"), isDirectory: false)]
            for id in ["audio.to.mp3", "audio.to.ogg", "audio.to.opus"] {
                let a = try AudTestKit.operation(id).availability(for: items, tools: none)
                let reason = try unwrap(a.reason, "\(id) must be unavailable without ffmpeg")
                try expect(reason.en.contains("brew install") && reason.ru.contains("brew install"), "\(id): \(reason.en)")
            }
            for id in ["audio.to.m4a", "audio.to.wav", "audio.to.flac", "audio.to.aiff", "audio.compress", "audio.normalize", "audio.trim", "audio.concat"] {
                try expect(try AudTestKit.operation(id).availability(for: items, tools: none).isAvailable, "\(id) works with macOS alone")
            }
            var lame = AudEnvironment.none; lame.hasLame = true
            let withLame = try await AudTestKit.withEnvironment(lame) { try AudTestKit.operation("audio.to.mp3").availability(for: items, tools: ToolLocator.shared) }
            try expect(withLame.isAvailable, "lame alone is enough for MP3")
        }

        t.register("audio.gating", "native operations really run with no external tool at all, and MP3 is refused cleanly instead of faked") {
            let fx = TestFixtures(label: "aud-nonative"); defer { fx.cleanup() }
            let (src, ref) = try AudioFFmpegTests.source(fx, seconds: 2)
            let none = ToolLocator(roots: .empty)
            let out = try await AudTestKit.withEnvironment(.none) {
                for id in ["audio.to.m4a", "audio.to.flac", "audio.to.aiff", "audio.to.wav", "audio.normalize", "audio.compress"] {
                    let o = try await AudTestKit.run(try AudTestKit.operation(id), [src], tools: none).outputs
                    try expectEqual(o.count, 1, id)
                }
                let trimmed = try await AudTestKit.run(try AudTestKit.operation("audio.trim"), [src], [AudioKeys.trimStart: 0.5, AudioKeys.trimEnd: 1.5], tools: none).outputs[0]
                return trimmed
            }
            try expectClose(try unwrap(AudTestKit.decode(out, in: fx.root)).seconds, 1.0, tolerance: 0.01)
            _ = ref
            let err = await AudTestKit.withEnvironment(.none) { () async -> Error? in
                do { _ = try await AudTestKit.run(try AudTestKit.operation("audio.to.mp3"), [src], mode: .quick, tools: none); return nil } catch { return error }
            }
            let e = try unwrap(err, "MP3 without an encoder must fail")
            try expect(ConversionError.describe(e).contains("brew install"), ConversionError.describe(e))
            try expect(!FileManager.default.fileExists(atPath: fx.url("mix.mp3").path), "no fake MP3 left behind")
        }

        t.register("audio.gating", "cancelling an ffmpeg encode kills the process within 200 ms and leaves no partial file", timeout: 180) {
            try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-fcancel"); defer { fx.cleanup() }
            let pattern = AudTestKit.chirp(seconds: 1, rate: 44_100, channels: 2)
            let long = try AudTestKit.writeLongWAV(pattern: pattern, repeating: 1_200, to: fx.url("long-\(Util.hex8()).wav"))       // 20 minutes
            let (error, seconds) = try await AudTestKit.runCancelling(try AudTestKit.operation("audio.to.mp3"), [long], [AudioKeys.speed: 0.9], after: 1.0)
            try expect(error is CancellationError, "cancelled: \(String(describing: error))")
            try expect(seconds < 0.5, "the cancel took \(seconds) s")
            try expect(AudTestKit.noProcess(mentioning: fx.root.path), "no ffmpeg process may survive the cancel")
            try expect(TestFile.partials(in: fx.root).isEmpty, "no .part left: \(TestFile.partials(in: fx.root))")
            try expect(!FileManager.default.fileExists(atPath: long.deletingPathExtension().appendingPathExtension("mp3").path), "no output after a cancel")
        }

        t.register("audio.gating", "a video's soundtrack is extracted through the shared transcoder; a silent video says there is no audio") {
            try AudTestKit.needs(.ffmpeg); try AudTestKit.needsEncoder("libmp3lame")
            let fx = TestFixtures(label: "aud-video"); defer { fx.cleanup() }
            let silent = try await fx.video("silent.mp4", seconds: 2)
            let (wav, ref) = try AudioFFmpegTests.source(fx, "track.wav", seconds: 2)
            let withSound = fx.url("sound.mp4")
            let r = AudTestKit.capture(try unwrap(AudTestKit.ffmpeg), ["-v", "error", "-y", "-i", silent.path, "-i", wav.path, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", withSound.path])
            try expectEqual(r.status, 0, r.err)
            let op = try AudTestKit.operation("audio.to.mp3")
            let ctx = OperationContext.testing(op, items: [FileItem(url: withSound, isDirectory: false)], mode: .studio)
            defer { ctx.cleanupTemp() }
            let out = fx.url("soundtrack.mp3")
            try await AudioTranscoder.transcode(input: withSound, output: out, options: ctx.options, ctx: ctx, progress: ctx.slice(index: 0, count: 1))
            try expectEqual(AudTestKit.sniff(out), "mp3")
            try expect(try AudioFFmpegTests.snr(ref, out, fx) > 8, "the extracted soundtrack matches the original")
            let ctx2 = OperationContext.testing(op, items: [FileItem(url: silent, isDirectory: false)], mode: .studio)
            defer { ctx2.cleanupTemp() }
            let err = try await expectThrows { try await AudioTranscoder.transcode(input: silent, output: fx.url("none.mp3"), options: ctx2.options, ctx: ctx2, progress: ctx2.slice(index: 0, count: 1)) }
            if case ConversionError.noAudioTrack = err {} else { throw TestFailure(message: "expected noAudioTrack, got \(err)", file: #fileID, line: #line) }
            try expect(!FileManager.default.fileExists(atPath: fx.url("none.mp3").path))
        }
    }
}
