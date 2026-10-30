import Foundation

/// Real runs on generated clips (ffmpeg lavfi). Every test reads the produced file back with tools that did not write it: ffprobe (codec, tag, pixel
/// format, size, frame rate, duration, side data), `ffmpeg -f md5` (copied streams), SSIM / PSNR filters, AVFoundation (playable + frames decode).
/// They SKIP without ffmpeg or when the media stack of media-video is not wired up.
enum SmartRunTests {
    private static let need = ["tool.ffmpeg"]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "run best: H.264 + AAC in MP4 is a lossless remux, video and audio bit for bit, faststart", requires: need) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "h264.mp4", seconds: 2)
            let r = try await SK.run(src)
            try expect(r.plan.isPureRemux, "H.264 + AAC must be planned as a pure remux")
            try expectEqual(r.url.pathExtension, "mp4")
            let v = try unwrap(await SK.streams(r.url, "video").first)
            try expectEqual(SK.str(v, "codec_name"), "h264")
            try await SK.expectSameStream(r.url, src, audio: false, "the video packets must be identical")
            try await SK.expectSameStream(r.url, src, audio: true, "the audio packets must be identical")
            let boxes = SK.topLevelBoxes(r.url)
            try expect(try unwrap(boxes.firstIndex(of: "moov")) < (try unwrap(boxes.firstIndex(of: "mdat"))), "faststart: moov before mdat, got \(boxes)")
            try await SK.expectPlayable(r, "AVFoundation must open the remuxed file")
            try expect(r.verification?.passed == true, "built-in verification: \(r.verification?.problems ?? [])")
        }

        t.register("smart", "run best: HEVC tagged hev1 is re-tagged hvc1 without touching the pictures", requires: need + ["ff.enc.libx265"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "hev1.mp4", video: ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-tag:v", "hev1"])
            let srcVideo = try unwrap(await SK.streams(src, "video").first)
            try expectEqual(SK.str(srcVideo, "codec_tag_string"), "hev1", "fixture must start as hev1")
            let r = try await SK.run(src)
            try expect(r.plan.video == .copy, "an HEVC stream is copied, not re-encoded")
            let v = try unwrap(await SK.streams(r.url, "video").first)
            try expectEqual(SK.str(v, "codec_tag_string"), "hvc1")
            try await SK.expectSameStream(r.url, src, audio: false, "re-tagging must keep the packets")
            try await SK.expectPlayable(r, "QuickTime-family players need hvc1")
            try expect(r.verification?.passed == true, "\(r.verification?.problems ?? [])")
        }

        t.register("smart", "run best: VP9 + Opus becomes HEVC hvc1 + AAC with size, frame rate and duration kept and SSIM above the floor", requires: need + ["ff.enc.libvpx-vp9", "ff.enc.libopus"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.vp9(fx)
            let r = try await SK.run(src)
            try expect(r.plan.isTenBit == false && r.plan.isHardwareEncode, "8-bit VP9 -> 8-bit hardware HEVC, got \(r.plan.chips)")
            try expectEqual(r.url.pathExtension, "mp4")
            let v = try unwrap(await SK.streams(r.url, "video").first), a = try unwrap(await SK.streams(r.url, "audio").first)
            try expectEqual(SK.str(v, "codec_name"), "hevc")
            try expectEqual(SK.str(v, "codec_tag_string"), "hvc1")
            try expectEqual(SK.str(v, "pix_fmt"), "yuv420p")
            try expectEqual(SK.int(v, "width"), 640); try expectEqual(SK.int(v, "height"), 360)
            try expectEqual(SK.str(v, "avg_frame_rate"), "24/1")
            try expectEqual(SK.str(a, "codec_name"), "aac")
            let durOut = await SK.duration(r.url), durIn = await SK.duration(src)
            try expectClose(durOut, durIn, tolerance: 0.1, "duration")
            let framesOut = await SK.packetCount(r.url), framesIn = await SK.packetCount(src)
            try expectEqual(framesOut, framesIn, "frame count")
            let sim = try await SK.similarity(r.url, src, in: fx.root)
            try expect(sim.ssim >= SmartQuality.minimumSSIM, "SSIM \(sim.ssim) is below \(SmartQuality.minimumSSIM)")
            try expect(sim.psnr >= 35, "PSNR \(sim.psnr) dB")
            try await SK.expectPlayable(r, "playable: \(r.verification?.problems ?? [])")
            try expect(!FileManager.default.contentsEqual(atPath: r.url.path, andPath: src.path), "a conversion must not return the input")
        }

        t.register("smart", "run best: HDR10 VP9 keeps 10-bit, PQ + BT.2020 tags, mastering display and light level", requires: need + ["ff.enc.libvpx-vp9", "ff.enc.libx265", "ff.enc.hevc_videotoolbox"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.hdr10VP9(fx)
            let srcSide = await SK.hasHDRSideData(src)
            try expect(srcSide.mastering && srcSide.cll, "the fixture must carry HDR side data (mastering \(srcSide.mastering), cll \(srcSide.cll))")
            let r = try await SK.run(src)
            try expect(r.plan.isHDR && r.plan.isTenBit, "\(r.plan.chips)")
            let v = try unwrap(await SK.streams(r.url, "video").first)
            try expectEqual(SK.str(v, "codec_name"), "hevc")
            try expectEqual(SK.str(v, "codec_tag_string"), "hvc1")
            try expectEqual(SK.str(v, "pix_fmt"), "yuv420p10le")
            try expectEqual(SK.str(v, "color_transfer"), "smpte2084")
            try expectEqual(SK.str(v, "color_primaries"), "bt2020")
            try expectEqual(SK.str(v, "color_space"), "bt2020nc")
            let side = await SK.hasHDRSideData(r.url)
            try expect(side.mastering, "mastering display metadata must survive the hardware encoder")
            try expect(side.cll, "content light level must survive the hardware encoder")
            let sim = try await SK.similarity(r.url, src, in: fx.root)
            try expect(sim.ssim >= SmartQuality.minimumSSIM, "SSIM \(sim.ssim)")
            try await SK.expectPlayable(r, "\(r.verification?.problems ?? [])")
        }

        t.register("smart", "run best: 10-bit SDR stays 10-bit; odd sizes are cropped to even, never rejected", requires: need + ["ff.enc.libvpx-vp9"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let ten = try await SK.vp9(fx, "ten.webm", size: "480x270", audio: false, pix: "yuv420p10le")
            let r10 = try await SK.run(ten)
            let v10 = try unwrap(await SK.streams(r10.url, "video").first)
            try expectEqual(SK.str(v10, "pix_fmt"), "yuv420p10le")
            try expect(SK.str(v10, "color_transfer") != "smpte2084", "SDR must not be tagged as HDR")
            try expect(r10.plan.isHDR == false)

            let odd = try await SK.vp9(fx, "odd.webm", size: "321x241", seconds: 1, audio: false)
            let rOdd = try await SK.run(odd)
            let vOdd = try unwrap(await SK.streams(rOdd.url, "video").first)
            try expectEqual(SK.int(vOdd, "width"), 320); try expectEqual(SK.int(vOdd, "height"), 240)
            try await SK.expectPlayable(rOdd, "\(rOdd.verification?.problems ?? [])")
        }

        t.register("smart", "run universal: 1440p MPEG-4 becomes H.264 High yuv420p inside 1080p with AAC, avc1, playable", requires: need + ["ff.enc.mpeg4"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "big.mp4", size: "2560x1440", fps: 12, seconds: 1, video: ["-c:v", "mpeg4", "-q:v", "6"], audio: ["-c:a", "aac"])
            let r = try await SK.run(src, mode: .universal)
            let v = try unwrap(await SK.streams(r.url, "video").first), a = try unwrap(await SK.streams(r.url, "audio").first)
            try expectEqual(SK.str(v, "codec_name"), "h264")
            try expectEqual(SK.str(v, "codec_tag_string"), "avc1")
            try expectEqual(SK.str(v, "pix_fmt"), "yuv420p")
            try expectEqual(SK.int(v, "width"), 1920); try expectEqual(SK.int(v, "height"), 1080)
            try expectEqual(SK.str(v, "profile"), "High")
            try expectEqual(SK.str(a, "codec_name"), "aac")
            // The reference is the source scaled to the target size with a near-lossless encode, so SSIM measures the transcode, not the scaling.
            let ref = fx.url("ref1080.mp4")
            try await SK.ffmpeg(["-i", src.path, "-vf", "scale=1920:1080:flags=bicubic", "-c:v", "libx264", "-crf", "10", "-an", ref.path])
            let simRef = try await SK.similarity(r.url, ref, in: fx.root)
            try expect(simRef.ssim >= SmartQuality.minimumSSIM, "SSIM against the scaled source \(simRef.ssim)")
            try await SK.expectPlayable(r, "\(r.verification?.problems ?? [])")
        }

        t.register("smart", "run universal: a compliant H.264 1080p file is copied; run max: VP9 + Opus stays WebM bit for bit", requires: need + ["ff.enc.libvpx-vp9", "ff.enc.libopus"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let h = try await SK.clip(fx, "ok.mp4", size: "1280x720", fps: 24, seconds: 1)
            let ru = try await SK.run(h, mode: .universal)
            try expect(ru.plan.video == .copy, "already universal: \(ru.plan.chips)")
            try await SK.expectSameStream(ru.url, h, audio: false)

            let src = try await SK.vp9(fx)
            let rm = try await SK.run(src, mode: .maximum)
            try expectEqual(rm.url.pathExtension, "webm")
            let fmt = await SK.formatName(rm.url)
            try expect(fmt.contains("webm"), "format \(fmt)")
            try await SK.expectSameStream(rm.url, src, audio: false, "Maximum must not touch the video")
            try await SK.expectSameStream(rm.url, src, audio: true, "Maximum must not touch the audio")
            try expect(rm.verification?.judge == "ffprobe" && rm.verification?.passed == true, "WebM is judged by ffprobe: \(rm.verification?.problems ?? [])")
        }

        t.register("smart", "run best: several audio tracks and text subtitles survive (copy / AAC / mov_text), languages kept", requires: need + ["ff.enc.libopus", "ff.enc.mov_text"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.multiTrack(fx)
            let r = try await SK.run(src)
            let audio = await SK.streams(r.url, "audio"), subs = await SK.streams(r.url, "subtitle")
            try expectEqual(audio.map { SK.str($0, "codec_name") }, ["aac", "aac"], "AAC copied, Opus re-encoded")
            try expectEqual(audio.map { SK.str(($0["tags"] as? [String: Any]) ?? [:], "language") }, ["eng", "rus"])
            try expectEqual(subs.map { SK.str($0, "codec_name") }, ["mov_text"])
            let text = try await SK.ffmpeg(["-i", r.url.path, "-map", "0:s:0", "-f", "srt", "-"], captureStdout: true).stdout
            try expect(text.contains("Ahoj") && text.contains("Привет, мир"), "subtitle text must survive: \(text)")
            try await SK.expectPlayable(r, "\(r.verification?.problems ?? [])")
        }

        t.register("smart", "run (oracle smart.strip): the metadata strip removes location, device and title; without it they stay", requires: need) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            var meta: [String] = []
            for (k, v) in SK.sourceTags { meta += ["-metadata", "\(k)=\(v)"] }
            let src = try await SK.clip(fx, "tagged.mp4", seconds: 1, extra: meta)
            let before = await SK.formatTags(src)
            try expect(before["location"] != nil || before["title"] != nil, "fixture must carry tags: \(before)")
            let kept = try await SK.run(src)
            let keptTags = await SK.formatTags(kept.url)
            try expectEqual(SK.str(keptTags, "title"), "Private holiday", "without the strip the title stays: \(keptTags)")
            let stripped = try await SK.run(src, base: "stripped") { $0.stripMetadata = true }
            let tags = await SK.formatTags(stripped.url)
            for key in ["title", "location", "com.apple.quicktime.model", "creation_time"] { try expect(tags[key] == nil, "tag \(key) must be gone: \(tags)") }
            try await SK.expectSameStream(stripped.url, src, audio: false, "stripping tags must not touch the pictures")
        }
    }
}
