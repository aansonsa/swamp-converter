import Foundation
import AVFoundation

/// Unusual sources through the real engine: AC-3 in Matroska, interlaced MPEG-2 transport streams, phone footage with a rotation flag, 4:2:2 H.264
/// and an audio-only file. Each result is read back with ffprobe / AVFoundation.
enum SmartEdgeTests {
    private static let need = ["tool.ffmpeg"]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "run best: H.264 + AC-3 in MKV is remuxed into MP4 keeping the AC-3 track bit for bit", requires: need + ["ff.enc.ac3"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "ac3.mkv", audio: ["-c:a", "ac3", "-b:a", "192k"])
            let r = try await SK.run(src)
            try expect(r.plan.isPureRemux, "\(r.plan.chips)")
            try expectEqual(r.url.pathExtension, "mp4")
            let a = try unwrap(await SK.streams(r.url, "audio").first)
            try expectEqual(SK.str(a, "codec_name"), "ac3")
            try await SK.expectSameStream(r.url, src, audio: true, "AC-3 must be copied")
            try await SK.expectSameStream(r.url, src, audio: false, "the picture must be copied")
            try await SK.expectPlayable(r)
        }

        t.register("smart", "run best: interlaced MPEG-2 transport stream is deinterlaced into progressive HEVC with the right duration", requires: need + ["ff.enc.mpeg2video", "ff.filter.bwdif"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "interlaced.ts", size: "720x576", fps: 25, seconds: 2, filter: "interlace=scan=tff", pixFmt: "yuv420p",
                                        video: ["-c:v", "mpeg2video", "-b:v", "6M", "-flags", "+ilme+ildct"], audio: ["-c:a", "mp2"], extra: ["-f", "mpegts"])
            let r = try await SK.run(src)
            try expect(r.plan.deinterlace, "an interlaced source must be deinterlaced: \(r.plan.videoFilters)")
            let v = try unwrap(await SK.streams(r.url, "video").first)
            try expectEqual(SK.str(v, "codec_name"), "hevc"); try expectEqual(SK.str(v, "field_order"), "progressive")
            try expectEqual(SK.int(v, "width"), 720); try expectEqual(SK.int(v, "height"), 576)
            let dur = await SK.duration(r.url)
            try expectClose(dur, 2, tolerance: 0.3, "duration")
            try await SK.expectPlayable(r)
        }

        t.register("smart", "run best: phone footage keeps its orientation, copied (H.264) and re-encoded (MPEG-4)", requires: need + ["ff.enc.mpeg4"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            // 640x360 stored, flagged to display as 360x640.
            func rotated(_ name: String, _ video: [String]) async throws -> URL {
                let plain = try await SK.clip(fx, "plain-\(name)", size: "640x360", seconds: 1, video: video)
                let out = fx.url(name)
                try await SK.ffmpeg(["-display_rotation", "90", "-i", plain.path, "-c", "copy", out.path])
                return out
            }
            func displaySize(_ url: URL) async throws -> (Int, Int) {
                let asset = AVURLAsset(url: url)
                let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                return (Int(abs(rect.width).rounded()), Int(abs(rect.height).rounded()))
            }
            let h264 = try await rotated("rot-h264.mp4", ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"])
            let before = try await displaySize(h264)
            try expectEqual(before.0, 360, "the fixture must display as portrait")
            let copy = try await SK.run(h264)
            try expect(copy.plan.video == .copy)
            let afterCopy = try await displaySize(copy.url)
            try expectEqual(afterCopy.0, 360); try expectEqual(afterCopy.1, 640)

            let mp4v = try await rotated("rot-mpeg4.mp4", ["-c:v", "mpeg4", "-q:v", "4"])
            let enc = try await SK.run(mp4v)
            try expect(enc.plan.video != .copy)
            let afterEnc = try await displaySize(enc.url)
            try expectEqual(afterEnc.0, 360); try expectEqual(afterEnc.1, 640)
            try await SK.expectPlayable(enc)
        }

        t.register("smart", "run best: H.264 4:2:2 10-bit (not playable on Apple devices) is re-encoded to HEVC instead of being copied", requires: need) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let src = try await SK.clip(fx, "hi422.mp4", pixFmt: "yuv422p10le", video: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv422p10le"])
            let r = try await SK.run(src)
            try expect(r.plan.video != .copy, "4:2:2 is not Apple-friendly: \(r.plan.chips)")
            let v = try unwrap(await SK.streams(r.url, "video").first)
            try expectEqual(SK.str(v, "codec_name"), "hevc"); try expectEqual(SK.str(v, "pix_fmt"), "yuv420p10le")
            try await SK.expectPlayable(r)
        }

        t.register("smart", "run: a file without video is refused with a plain message, nothing is written", requires: need) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let wav = try fx.wav()
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path))
            let err = try await expectThrows("audio is not video") { _ = try await SK.run(wav) }
            try expect(ConversionError.describe(err).lowercased().contains("video") || ConversionError.describe(err).contains("видео"), ConversionError.describe(err))
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fx.root.path)), before)
        }
    }
}
