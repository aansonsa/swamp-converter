import Foundation

/// One oracle test per schema option: the option is switched, the engine runs for real, and the output is read back with an independent probe.
/// The text "(oracle smart.xyz)" in a test name is what `SmartConformanceTests` matches against the `.oracle(...)` of the schema fields.
enum SmartOptionTests {
    private static let need = ["tool.ffmpeg"]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "option (oracle smart.mode): the three modes give three different files from the same VP9 source", requires: need + ["ff.enc.libvpx-vp9", "ff.enc.libopus"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.vp9(fx)
            var codecs: [String: String] = [:], containers: [String: String] = [:]
            for mode in SmartMode.allCases {
                let r = try await SK.run(src, mode: mode, base: "out-\(mode.rawValue)")
                codecs[mode.rawValue] = SK.str(try unwrap(await SK.streams(r.url, "video").first), "codec_name")
                containers[mode.rawValue] = r.url.pathExtension
            }
            try expectEqual(codecs, ["best": "hevc", "max": "vp9", "universal": "h264"])
            try expectEqual(containers, ["best": "mp4", "max": "webm", "universal": "mp4"])
        }

        t.register("smart", "option (oracle smart.x265): maximum quality uses libx265 and still keeps hvc1, 10-bit and the HDR side data",
                   requires: need + ["ff.enc.libvpx-vp9", "ff.enc.libx265", "ff.enc.hevc_videotoolbox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.hdr10VP9(fx)
            let hw = try await SK.run(src, base: "hw")
            try expect(!SK.containsMarker(hw.url, "x265"), "the default is the hardware encoder")
            let sw = try await SK.run(src, base: "sw") { $0.maximumQualitySlow = true }
            try expectEqual(sw.plan.encoderName, "libx265")
            try expect(SK.containsMarker(sw.url, "x265"), "the stream must carry the x265 signature")
            let v = try unwrap(await SK.streams(sw.url, "video").first)
            try expectEqual(SK.str(v, "codec_tag_string"), "hvc1"); try expectEqual(SK.str(v, "pix_fmt"), "yuv420p10le")
            try expectEqual(SK.str(v, "color_transfer"), "smpte2084"); try expectEqual(SK.str(v, "color_primaries"), "bt2020")
            let side = await SK.hasHDRSideData(sw.url)
            try expect(side.mastering && side.cll, "libx265 gets the mastering display and light level explicitly (mastering \(side.mastering), cll \(side.cll))")
            let sim = try await SK.similarity(sw.url, src, in: fx.root)
            try expect(sim.ssim >= SmartQuality.minimumSSIM, "SSIM \(sim.ssim)")
            try await SK.expectPlayable(sw)
        }

        t.register("smart", "option (oracle smart.q.offset): a higher offset gives a larger file and a higher PSNR, monotonically",
                   requires: need + ["ff.enc.libvpx-vp9", "ff.enc.hevc_videotoolbox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.noisyVP9(fx, size: "960x540", seconds: 2)
            var sizes: [Int64] = [], psnrs: [Double] = []
            for offset in [-10, 0, 5] {
                let r = try await SK.run(src, base: "q\(offset)") { $0.qualityOffset = offset }
                sizes.append(TestFile.size(r.url))
                psnrs.append(try await SK.similarity(r.url, src, in: fx.root).psnr)
            }
            try expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "sizes must grow with the offset: \(sizes)")
            try expect(psnrs[0] < psnrs[1] && psnrs[1] < psnrs[2], "PSNR must grow with the offset: \(psnrs)")
        }

        t.register("smart", "option (oracle smart.downscale) (oracle smart.downscale.h): large pictures are scaled to the chosen height, aspect kept, even sizes",
                   requires: need + ["ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.vp9(fx, size: "1280x720", seconds: 1, audio: false)
            let keep = try await SK.run(src, base: "keep")
            let kept = try unwrap(await SK.streams(keep.url, "video").first)
            try expectEqual(SK.int(kept, "width"), 1280); try expectEqual(SK.int(kept, "height"), 720)
            let small = try await SK.run(src, base: "small") { $0.downscaleWhenUnsupported = true; $0.fallbackHeight = 480 }
            let v = try unwrap(await SK.streams(small.url, "video").first)
            try expectEqual(SK.int(v, "height"), 480); try expect(abs(SK.int(v, "width") - 853) <= 1 && SK.int(v, "width") % 2 == 0, "width \(SK.int(v, "width"))")
            try await SK.expectPlayable(small)
            let sim = try await SK.similarity(small.url, src, size: (1280, 720), in: fx.root)
            try expect(sim.ssim >= 0.9, "a downscaled picture still looks like the source (SSIM after scaling back \(sim.ssim))")
        }

        t.register("smart", "option (oracle smart.audio.all) (oracle smart.subs): off keeps one audio track and no subtitles; on keeps all of them", requires: need + ["ff.enc.libopus"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.multiTrack(fx)
            let all = try await SK.run(src, base: "all")
            let allAudio = await SK.streams(all.url, "audio"), allSubs = await SK.streams(all.url, "subtitle")
            try expectEqual(allAudio.count, 2); try expectEqual(allSubs.count, 1)
            let lean = try await SK.run(src, base: "lean") { $0.keepAllAudioTracks = false; $0.keepSubtitles = false }
            let audio = await SK.streams(lean.url, "audio"), subs = await SK.streams(lean.url, "subtitle")
            try expectEqual(audio.count, 1); try expectEqual(subs.count, 0)
            try await SK.expectPlayable(lean)
        }

        t.register("smart", "option (oracle smart.abr) (oracle smart.alac): AAC follows the chosen bit rate; lossless audio is ALAC and decodes to the same samples",
                   requires: need + ["ff.enc.libopus", "ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "noise.webm", seconds: 3, pixFmt: "yuv420p", video: ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "35", "-deadline", "realtime", "-cpu-used", "8"],
                                        audio: ["-c:a", "libopus", "-b:a", "192k", "-ac", "2"], audioSource: "anoisesrc=color=pink:sample_rate=48000:amplitude=0.3")
            var rates: [Int: Double] = [:]
            for kbps in [128, 320] {
                let r = try await SK.run(src, base: "abr\(kbps)") { $0.audioBitrateKbps = kbps }
                let a = try unwrap(await SK.streams(r.url, "audio").first)
                try expectEqual(SK.str(a, "codec_name"), "aac")
                rates[kbps] = SK.bitRate(a) / 1000
                try expect(abs(rates[kbps]! - Double(kbps)) / Double(kbps) < 0.2, "\(kbps) kbit/s requested, \(rates[kbps]!) measured")
            }
            try expect(rates[320]! > rates[128]! * 1.8, "a higher setting must give a much higher rate: \(rates)")
            let ll = try await SK.run(src, base: "alac") { $0.losslessAudio = true }
            let a = try unwrap(await SK.streams(ll.url, "audio").first)
            try expectEqual(SK.str(a, "codec_name"), "alac")
            // ffmpeg's ALAC encoder stores 24 bits, so the comparison is on float samples: the error must stay below one 24-bit step.
            let before = try await SK.pcmFloats(src, in: fx.root), after = try await SK.pcmFloats(ll.url, in: fx.root)
            try expect(before.count > 90_000 && abs(before.count - after.count) <= 2, "sample counts \(before.count) / \(after.count)")
            let worst = zip(before, after).map { abs($0 - $1) }.max() ?? 1
            try expect(worst < 1e-6, "ALAC must decode to the samples of the source; worst difference \(worst)")
        }

        t.register("smart", "option (oracle smart.container) (oracle smart.faststart): MOV, MKV and MP4 files are what they say; faststart moves the index to the front",
                   requires: need + ["ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.vp9(fx, audio: false)
            let mov = try await SK.run(src, base: "as-mov") { $0.container = "mov" }
            try expectEqual(mov.url.pathExtension, "mov")
            let movHead = TestFile.magic(mov.url, 12)
            try expectEqual(String(decoding: movHead[4..<12], as: UTF8.self), "ftypqt  ", "QuickTime brand")
            let mkv = try await SK.run(src, base: "as-mkv") { $0.container = "mkv" }
            try expectEqual(mkv.url.pathExtension, "mkv")
            let mkvFormat = await SK.formatName(mkv.url)
            try expect(mkvFormat.contains("matroska"), "format \(mkvFormat)")
            try expect(TestFile.magic(mkv.url, 4) == [0x1A, 0x45, 0xDF, 0xA3], "EBML header")
            let mkvVideo = try unwrap(await SK.streams(mkv.url, "video").first)
            try expectEqual(SK.str(mkvVideo, "codec_name"), "hevc")
            try await SK.expectPlayable(mkv)
            let mp4 = try await SK.run(src, base: "as-mp4") { $0.container = "mp4" }
            try expect(String(decoding: TestFile.magic(mp4.url, 12)[4..<8], as: UTF8.self) == "ftyp")
            let fast = SK.topLevelBoxes(mp4.url)
            try expect(try unwrap(fast.firstIndex(of: "moov")) < (try unwrap(fast.firstIndex(of: "mdat"))), "faststart on: \(fast)")
            let slow = try await SK.run(src, base: "no-fast") { $0.faststart = false }
            let boxes = SK.topLevelBoxes(slow.url)
            try expect(try unwrap(boxes.firstIndex(of: "mdat")) < (try unwrap(boxes.firstIndex(of: "moov"))), "faststart off keeps the index at the end: \(boxes)")
            try await SK.expectPlayable(slow)
        }

        t.register("smart", "engine: fake capabilities choose the software encoder; a failing hardware encode is retried once with libx265 and said so",
                   requires: need + ["ff.enc.libx265", "ff.enc.libvpx-vp9", "ff.enc.hevc_videotoolbox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.vp9(fx, seconds: 1, audio: false)
            var noHW = SmartCapabilities.current; noHW.hevcHardware = false
            let sw = try await SK.run(src, caps: noHW, base: "fake-sw")
            try expectEqual(sw.plan.encoderName, "libx265"); try expect(SK.containsMarker(sw.url, "x265"))
            let battery = try await SK.run(src, base: "battery") { $0.maximumQualitySlow = true; $0.preferHardware = true }
            try expect(battery.plan.isHardwareEncode && !SK.containsMarker(battery.url, "x265"), "Low Power Mode prefers the hardware encoder over the slow one")

            // 20000x1080 is wider than VideoToolbox accepts: the planner is told it can, the real encoder refuses, the engine falls back.
            let wide = fx.url("wide.mkv")
            try await SK.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=20000x1080:rate=1:duration=2", "-c:v", "ffv1", "-g", "1", wide.path])
            var optimistic = SmartCapabilities.current; optimistic.hevcHardwareMaxHeight = 100_000
            let r = try await SK.run(wide, caps: optimistic, rules: OutputRules(verify: false), base: "retried")
            try expectEqual(r.plan.encoderName, "libx265", "the plan that finally ran")
            try expect(r.warnings.contains { $0.lowercased().contains("software") || $0.contains("программный") }, "the fallback is announced: \(r.warnings)")
            let v = try unwrap(await SK.streams(r.url, "video").first)
            try expectEqual(SK.str(v, "codec_name"), "hevc"); try expectEqual(SK.int(v, "width"), 20000); try expectEqual(SK.str(v, "codec_tag_string"), "hvc1")
            let leftovers = (try FileManager.default.contentsOfDirectory(atPath: fx.root.path)).filter { $0.hasPrefix(".") && $0.hasSuffix(".part") }
            try expect(leftovers.isEmpty, "no partial file after the failed hardware attempt: \(leftovers)")
        }

        t.register("smart", "engine: progress is monotone and stays below 100 percent until ffmpeg has exited", requires: need + ["ff.enc.libx265", "ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.noisyVP9(fx, seconds: 4)
            let seen = Locked<[Double]>([])
            let r = try await SK.run(src, { $0.maximumQualitySlow = true },
                                     ctxTweak: { ctx in ctx.onProgress = { f, _, _ in if let f { seen.withLock { $0.append(f) } } } })
            _ = r
            let values = seen.value
            try expect(values.count >= 3, "a multi-second encode reports several times: \(values)")
            try expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "progress must never go backwards: \(values)")
            try expect(values.dropLast().allSatisfy { $0 < 1 }, "100 percent only after the process exited: \(values)")
            try expectClose(values.last ?? 0, 1, tolerance: 0.0001, "the final report")
        }

        t.register("smart", "engine: cancelling stops ffmpeg within a fraction of a second and leaves no partial file", requires: need + ["ff.enc.libx265", "ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.noisyVP9(fx, seconds: 8)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            let task = Task { @MainActor in try await SK.run(src) { $0.maximumQualitySlow = true } }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let asked = Date()
            task.cancel()
            let outcome = await task.result
            let took = Date().timeIntervalSince(asked)
            if case .success = outcome { throw TestFailure(message: "the run finished before the cancel; make the fixture longer", file: #fileID, line: #line) }
            if case .failure(let e) = outcome { try expect(e is CancellationError, "cancel must surface as CancellationError, got \(e)") }
            try expect(took < 0.6, "cancel took \(took) s (budget 200 ms for the tool, the rest is process teardown)")
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            try expectEqual(after, before, "no .part file and no output after a cancel")
        }
    }
}
