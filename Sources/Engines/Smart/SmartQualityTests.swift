import Foundation

/// Measured quality (SSIM / PSNR through ffmpeg filters on a hard, noisy clip), the estimate against reality, and the verifier proven on files that
/// are NOT fine (wrong tag, truncated, wrong size, missing audio): a verifier that always says yes would be worse than none.
enum SmartQualityTests {
    private static let need = ["tool.ffmpeg"]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "quality targets: hardware HEVC, libx265, libx264 and VideoToolbox H.264 stay visually transparent on a noisy 720p clip",
                   requires: need + ["ff.enc.libvpx-vp9", "ff.enc.hevc_videotoolbox", "ff.enc.libx265", "ff.enc.libx264", "ff.enc.h264_videotoolbox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.noisyVP9(fx)
            let srcSize = TestFile.size(src)
            struct Row { var name: String; var size: Int64; var ssim: Double; var psnr: Double }
            var rows: [Row] = []
            func measure(_ name: String, mode: SmartMode = .bestForApple, caps: SmartCapabilities? = nil, _ tweak: @escaping (inout SmartOptions) -> Void = { _ in }) async throws {
                let r = try await SK.run(src, mode: mode, caps: caps, base: name.replacingOccurrences(of: " ", with: "-"), tweak)
                let s = try await SK.similarity(r.url, src, in: fx.root)
                rows.append(Row(name: name, size: TestFile.size(r.url), ssim: s.ssim, psnr: s.psnr))
            }
            var hwH264 = SmartCapabilities.current; hwH264.libx264 = false
            try await measure("hevc hardware default")
            try await measure("hevc hardware q-10") { $0.qualityOffset = -10 }
            try await measure("hevc libx265 slow") { $0.maximumQualitySlow = true }
            try await measure("h264 libx264 universal", mode: .universal)
            try await measure("h264 hardware universal", mode: .universal, caps: hwH264)
            let report = rows.map { "\($0.name): \($0.size / 1000) kB, SSIM \(String(format: "%.4f", $0.ssim)), PSNR \(String(format: "%.1f", $0.psnr)) dB" }.joined(separator: "; ")
            for r in rows where r.name != "hevc hardware q-10" {
                // The 2 s clip is a single group of pictures and the hardware rate control needs a moment to settle: 0.985 / 43 dB is the floor on it
                // (the 4 s clip of the SmartQuality table gives 0.9945 / 45.5 dB); the software encoders measure 0.992 here.
                try expect(r.ssim >= 0.985 && r.psnr >= 43, "\(r.name) is not transparent: \(report)")
            }
            let low = try unwrap(rows.first { $0.name == "hevc hardware q-10" }), def = rows[0]
            try expect(low.size < def.size / 2 && low.ssim < def.ssim && low.ssim >= SmartQuality.minimumSSIM, "a lower offset trades quality for size: \(report)")
            try expect(def.size < srcSize * 2, "the default HEVC stays in the size class of the VP9 source (\(srcSize / 1000) kB): \(report)")
        }

        t.register("smart", "estimate: the Studio size estimate is within a factor of two of the real result for a remux and for a VP9 transcode",
                   requires: need + ["ff.enc.libvpx-vp9", "ff.enc.hevc_videotoolbox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let op = try unwrap(SmartCatalog.operations()[0] as? SmartOperation)
            for (name, src) in [("remux", try await SK.clip(fx, "est.mp4", size: "640x360", seconds: 3)), ("transcode", try await SK.noisyVP9(fx, "est.webm", seconds: 3))] {
                let info = try await MediaProbe.probe(src)
                let source = MediaProbe.sourceInfo(from: info, kind: .video)
                let guess = try unwrap(op.estimate(options: [SmartKeys.mode: "best"], items: [FileItem(url: src)], source: source), "\(name): no estimate")
                let real = try await SK.run(src, base: "est-\(name)")
                let actual = Double(TestFile.size(real.url)), predicted = Double(guess.bytes ?? 0)
                try expect(predicted > actual / 2 && predicted < actual * 2, "\(name): estimated \(predicted) bytes, real \(actual)")
            }
        }

        t.register("smart", "verifier: accepts a good file with frames decoded at start, middle and end; rejects wrong tag, truncation, wrong size and missing audio",
                   requires: need + ["ff.enc.libx265", "ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.vp9(fx, seconds: 4)
            let good = try await SK.run(src, base: "good")
            try expect(good.verification?.passed == true && (good.verification?.readableFrames ?? 0) >= 9, "three windows of frames: \(good.verification?.readableFrames ?? 0)")
            try expectEqual(good.verification?.judge, "avfoundation")
            try expectEqual(good.verification?.codecTag, "hvc1")
            let info = try await MediaProbe.probe(src)
            let plan = good.plan

            // 1. hev1 where hvc1 was promised.
            let hev1 = try await SK.clip(fx, "hev1.mp4", seconds: 1, video: ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-tag:v", "hev1"])
            let tag = await SmartVerifier.verify(output: hev1, against: plan, source: info, durationTolerance: 5)
            try expect(!tag.passed && tag.problems.contains { $0.contains("codec tag") }, "a wrong tag must be reported: \(tag.problems)")

            // 2. Truncated file.
            let cut = fx.url("cut.mp4")
            let data = try Data(contentsOf: good.url)
            try data.prefix(data.count / 3).write(to: cut)
            let broken = await SmartVerifier.verify(output: cut, against: plan, source: info)
            try expect(!broken.passed, "a truncated file must not pass: \(broken)")

            // 3. Wrong picture size and 4. audio missing.
            var wrong = plan
            wrong.targetWidth = 1280; wrong.targetHeight = 720
            let size = await SmartVerifier.verify(output: good.url, against: wrong, source: info)
            try expect(size.problems.contains { $0.contains("size is") }, "\(size.problems)")
            let silent = try await SK.vp9(fx, "silent.webm", seconds: 4, audio: false)
            let silentOut = try await SK.run(silent, base: "silent")
            let audio = await SmartVerifier.verify(output: silentOut.url, against: plan, source: info)
            try expect(audio.problems.contains { $0.contains("audio") }, "\(audio.problems)")

            // 5. Duration far from the source.
            var shorter = plan
            shorter.sourceDuration = 30
            let dur = await SmartVerifier.verify(output: good.url, against: shorter, source: info)
            try expect(dur.problems.contains { $0.contains("duration") }, "\(dur.problems)")

            // 6. Missing file.
            let gone = await SmartVerifier.verify(output: fx.url("nothing.mp4"), against: plan, source: info)
            try expect(!gone.passed && !gone.problems.isEmpty)
        }

        t.register("smart", "run: names with spaces, unicode, dots and a leading dash work; an existing output is never overwritten; a read-only folder is a clean error",
                   requires: need) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let base = try await SK.clip(fx, "tmp.mp4", seconds: 1)
            var results: [URL] = []
            for name in ["-dash first.mp4", "Видео с точками.v2.final.mp4", "日本語 clip.mov", "plain.mp4"] {
                let src = fx.url(name)
                try FileManager.default.copyItem(at: base, to: src)
                let r = try await SK.run(src)
                results.append(r.url)
                try expect(FileManager.default.fileExists(atPath: r.url.path) && r.url.deletingLastPathComponent().path == fx.root.path, "\(name) -> \(r.url.lastPathComponent)")
            }
            // Same source twice: the second result gets a new name.
            let again = try await SK.run(fx.url("plain.mp4"))
            try expect(again.url != results[3] && FileManager.default.fileExists(atPath: results[3].path), "second run: \(again.url.lastPathComponent) next to \(results[3].lastPathComponent)")
            // Read-only output folder.
            let ro = try fx.makeDirectory("readonly")
            let roSrc = ro.appendingPathComponent("a.mp4")
            try FileManager.default.copyItem(at: base, to: roSrc)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
            let err = try await expectThrows("a read-only folder must fail cleanly") { _ = try await SK.run(roSrc) }
            try expect(!(err is CancellationError), "\(err)")
            try expect(TestFile.partials(in: ro).isEmpty, "no partial file in the read-only folder")
        }
    }
}
