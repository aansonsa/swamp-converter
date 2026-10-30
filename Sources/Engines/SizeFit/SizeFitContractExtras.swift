import Foundation
import AVFoundation

// Cancellation, odd file names, metadata, HDR, rotation and the estimate against the real result.

enum SizeFitContractExtras {
    private typealias S = FitTestSupport

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("sizefit", "fit.video: cancelling stops ffmpeg within a second and leaves no partial or attempt file behind",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 180) {
            let fx = TestFixtures(label: "fitcancel"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 20, width: 1280, height: 720)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            let task = Task { @MainActor in try await S.run(src, id: "fit.video", extra: S.target(bytes: 2_500_000)) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let started = Date()
            task.cancel()
            let outcome = await task.result
            let took = Date().timeIntervalSince(started)
            if case .success = outcome { throw TestFailure(message: "the run finished before it could be cancelled; make the fixture longer", file: #fileID, line: #line) }
            if case .failure(let e) = outcome { try expect(e is CancellationError, "cancellation must surface as CancellationError, got \(e)") }
            try expect(took < 1.0, "cancel took \(took) s")
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path)), before, "nothing may remain after a cancel")
        }

        t.register("sizefit", "fit.image / fit.audio / fit.pdf: file names with spaces, unicode, dots and a leading dash work and the result name carries the suffix",
                   requires: ["tool.ffmpeg"], timeout: 120) {
            let fx = TestFixtures(label: "fitnames"); defer { fx.cleanup() }
            let photo = try S.makePhoto(fx, "-Фото мая.2026 (копия).jpg")
            let a = try unwrap(try await S.run(photo, id: "fit.image", extra: S.target(bytes: 300_000)).result.outputs.first)
            try expect(a.lastPathComponent.hasPrefix("-Фото мая.2026 (копия) ("), a.lastPathComponent)
            try expect(TestFile.size(a) <= 300_000)
            let wav = try await S.makeAudioNoise(fx, "-звук. тест.wav", seconds: 8)
            let b = try unwrap(try await S.run(wav, id: "fit.audio", extra: S.target(bytes: 100_000)).result.outputs.first)
            try expect(TestFile.size(b) <= 100_000 && b.pathExtension == "m4a", b.lastPathComponent)
            let pdf = try S.makePictureHeavyPDF(fx, "-Отчёт 1.pdf", pages: 2)
            let c = try unwrap(try await S.run(pdf, id: "fit.pdf", extra: S.target(bytes: 500_000)).result.outputs.first)
            try expect(TestFile.size(c) <= 500_000)
            // Running twice never overwrites: the second result gets a numbered name.
            let again = try unwrap(try await S.run(photo, id: "fit.image", extra: S.target(bytes: 300_000)).result.outputs.first)
            try expect(again != a && TestFile.exists(a) && TestFile.exists(again), "\(again.lastPathComponent)")
            let clip = try await S.makeVideo(fx, "-кино тест.mp4", seconds: 3)
            let d = try unwrap(try await S.run(clip, id: "fit.video", extra: S.target(bytes: 300_000)).result.outputs.first)
            try expect(TestFile.size(d) <= 300_000, d.lastPathComponent)
        }

        t.register("sizefit", "fit.video: location and title tags are kept by default and removed with 'remove location and camera info'",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 120) {
            let fx = TestFixtures(label: "fitvmeta"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, seconds: 3, metadata: ["-metadata", "title=Secret holiday", "-metadata", "location=+50.0800+014.4200/", "-metadata", "com.apple.quicktime.model=iPhone Test"])
            let limit: Int64 = 400_000
            let kept = try unwrap(try await S.run(src, id: "fit.video", extra: S.target(bytes: limit)).result.outputs.first)
            let k = try await S.videoFacts(kept)
            try expectEqual(k.tags["title"], "Secret holiday")
            try expect(k.tags["location"] != nil, "location is kept by default: \(k.tags)")
            var extra = S.target(bytes: limit); extra[FitKeys.stripMetadata] = true
            let clean = try unwrap(try await S.run(src, id: "fit.video", extra: extra).result.outputs.first)
            let c = try await S.videoFacts(clean)
            try expect(c.tags["title"] == nil && c.tags["location"] == nil && c.tags["com.apple.quicktime.model"] == nil, "tags must be gone: \(c.tags)")
            try expect(TestFile.size(clean) <= limit)
        }

        t.register("sizefit", "fit.audio: title and artist survive the AAC re-encode and disappear with the privacy option",
                   requires: ["tool.ffmpeg", "ff.enc.libmp3lame"], timeout: 120) {
            let fx = TestFixtures(label: "fitameta"); defer { fx.cleanup() }
            let wav = try await S.makeAudioNoise(fx, seconds: 30)
            let mp3 = fx.url("song.mp3")
            try await ProcessRunner.run(try ToolLocator.shared.require(.ffmpeg), ["-hide_banner", "-loglevel", "error", "-y", "-i", wav.path, "-c:a", "libmp3lame", "-b:a", "192k",
                                                                                  "-metadata", "title=Swamp Song", "-metadata", "artist=Andris", mp3.path])
            let limit: Int64 = 250_000
            try expect(TestFile.size(mp3) > limit)
            let kept = try unwrap(try await S.run(mp3, id: "fit.audio", extra: S.target(bytes: limit)).result.outputs.first)
            let tags = try await S.formatTags(kept)
            try expectEqual(tags["title"], "Swamp Song"); try expectEqual(tags["artist"], "Andris")
            try expect(TestFile.size(kept) <= limit && Double(TestFile.size(kept)) >= Double(limit) * 0.93, "size \(TestFile.size(kept))")
            var extra = S.target(bytes: limit); extra[FitKeys.stripMetadata] = true
            let clean = try unwrap(try await S.run(mp3, id: "fit.audio", extra: extra).result.outputs.first)
            let cleanTags = try await S.formatTags(clean)
            try expect(cleanTags["title"] == nil && cleanTags["artist"] == nil, "tags must be gone: \(cleanTags)")
            try expect(TestFile.size(clean) <= limit)
        }

        t.register("sizefit", "fit.video: HDR (10-bit HLG) stays 10-bit HEVC with its colour tags and hvc1, and fits",
                   requires: ["tool.ffmpeg", "ff.enc.libx265", "ff.enc.hevc_videotoolbox"], timeout: 240) {
            let fx = TestFixtures(label: "fithdr"); defer { fx.cleanup() }
            let src = try await S.makeVideo(fx, "hdr.mp4", seconds: 4, width: 960, height: 540, noise: 4, pixelFormat: "yuv420p10le",
                                            extraVideoArgs: ["-c:v", "libx265", "-tag:v", "hvc1", "-x265-params", "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"])
            let limit: Int64 = 900_000
            let out = try unwrap(try await S.run(src, id: "fit.video", extra: S.target(bytes: limit)).result.outputs.first)
            try expect(TestFile.size(out) <= limit, "size \(TestFile.size(out))")
            let v = try await S.videoStreamFacts(out)
            try expectEqual(v["codec_name"] as? String, "hevc"); try expectEqual(v["codec_tag_string"] as? String, "hvc1")
            try expect((v["pix_fmt"] as? String)?.contains("10") == true, "10-bit kept: \(String(describing: v["pix_fmt"]))")
            try expectEqual(v["color_transfer"] as? String, "arib-std-b67"); try expectEqual(v["color_primaries"] as? String, "bt2020")
            try await S.expectPlayable(out)
        }

        t.register("sizefit", "fit.video: a clip stored sideways (rotation metadata) comes out upright with the portrait size the viewer sees",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 120) {
            let fx = TestFixtures(label: "fitrot"); defer { fx.cleanup() }
            let flat = try await S.makeVideo(fx, "flat.mp4", seconds: 3, width: 640, height: 360)
            let rotated = fx.url("rotated.mov")
            try await ProcessRunner.run(try ToolLocator.shared.require(.ffmpeg), ["-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0", "90", "-i", flat.path, "-c", "copy", rotated.path])
            let limit: Int64 = 350_000
            let out = try unwrap(try await S.run(rotated, id: "fit.video", extra: S.target(bytes: limit)).result.outputs.first)
            let f = try await S.videoFacts(out)
            try expect(f.height > f.width, "portrait expected, got \(f.width)x\(f.height)")
            try expect(TestFile.size(out) <= limit && Double(TestFile.size(out)) >= Double(limit) * 0.93, "size \(TestFile.size(out))")
        }

        t.register("sizefit", "fit.video: a second soundtrack and subtitles are not kept, and the result says so",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 120) {
            let fx = TestFixtures(label: "fitmulti"); defer { fx.cleanup() }
            let srt = try fx.srt()
            let src = fx.url("multi.mp4")
            try await ProcessRunner.run(try ToolLocator.shared.require(.ffmpeg), ["-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=4,noise=alls=5:allf=t",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-f", "lavfi", "-i", "sine=frequency=880:duration=4", "-i", srt.path,
                "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", "libx264", "-crf", "20", "-c:a", "aac", "-c:s", "mov_text", src.path])
            let limit: Int64 = 400_000
            let run = try await S.run(src, id: "fit.video", extra: S.target(bytes: limit))
            let out = try unwrap(run.result.outputs.first)
            try expect(TestFile.size(out) <= limit)
            let json = try await ProcessRunner.run(try ToolLocator.shared.require(.ffprobe), ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", out.path], captureStdout: true)
            let kinds = json.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            try expectEqual(kinds.filter { $0 == "audio" }.count, 1); try expectEqual(kinds.filter { $0 == "subtitle" }.count, 0)
            let note = try unwrap(run.result.note)
            try expect(note.en.contains("first audio track") && note.en.contains("Subtitles"), note.en)
        }

        t.register("sizefit", "estimate vs reality: the Studio estimate is within 10% of the limit of what the engines really produce (video, audio)",
                   requires: ["tool.ffmpeg", "ff.enc.libx264"], timeout: 120) {
            let fx = TestFixtures(label: "fitest"); defer { fx.cleanup() }
            let limit: Int64 = 500_000
            let clip = try await S.makeVideo(fx, seconds: 5)
            let vf = try await S.videoFacts(clip)
            var info = SourceInfo(url: clip, kind: .video)
            info.facts = ["duration": .double(vf.duration), "size": .int(Int(TestFile.size(clip))), "video.width": .int(vf.width), "video.height": .int(vf.height), "video.fps": .double(vf.fps), "audio.count": .int(1)]
            let est = try unwrap(try unwrap(SizeEstimator.estimate(kind: .video, options: S.target(bytes: limit), source: info)).bytes)
            let real = TestFile.size(try unwrap(try await S.run(clip, id: "fit.video", extra: S.target(bytes: limit)).result.outputs.first))
            try expect(abs(Double(est - real)) <= Double(limit) * 0.10, "video estimate \(est) vs real \(real)")
            let wav = try await S.makeAudioNoise(fx, seconds: 20)
            var ainfo = SourceInfo(url: wav, kind: .audio)
            ainfo.facts = ["duration": .double(20.0), "size": .int(Int(TestFile.size(wav)))]
            let aest = try unwrap(try unwrap(SizeEstimator.estimate(kind: .audio, options: S.target(bytes: 200_000), source: ainfo)).bytes)
            let areal = TestFile.size(try unwrap(try await S.run(wav, id: "fit.audio", extra: S.target(bytes: 200_000)).result.outputs.first))
            try expect(abs(Double(aest - areal)) <= 20_000, "audio estimate \(aest) vs real \(areal)")
        }
    }
}
