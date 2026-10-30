import Foundation

// video.mute: the sound goes, everything else stays - the picture bit for bit (stream copy) and the soft subtitle tracks (the original dropped them).

enum VideoMuteTests {
    typealias R = VideoRealTests

    static let srt = "1\n00:00:00,200 --> 00:00:01,200\nHello, swamp\n\n2\n00:00:01,300 --> 00:00:01,900\nПривет, болото\n\n"

    static func subtitleText(_ url: URL, index: Int = 0) -> String {
        guard let ff = VT.ffmpeg else { return "" }
        return VT.run(ff, ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:s:\(index)", "-f", "srt", "-"])
    }

    static func register() {
        R.reg("mute: stream copy without sound that keeps the subtitle tracks (MP4 timed text and MKV SubRip), the picture bit for bit", oracles: [], timeout: 150) {
            let fx = VTShared.fx
            let srtURL = fx.url("mute.srt")
            try Data(srt.utf8).write(to: srtURL)
            let plain = try VTShared.clip
            let mp4 = try VT.withSubtitles(fx, from: plain, srt: srtURL, "mute-sub.mp4", codec: "mov_text", lang: "eng")
            let mkv = try VT.withSubtitles(fx, from: plain, srt: srtURL, "mute-sub.mkv", codec: "srt", lang: "rus")
            for (src, container, lang) in [(mp4, "mp4", "eng"), (mkv, "matroska", "rus")] {
                let before = try VT.probe(src)
                try expect(before.audio != nil && before.streams("subtitle").count == 1, "fixture \(src.lastPathComponent): audio and one subtitle track")
                let r = try await VT.run("video.mute", src, mode: .quick, rules: VT.outRules())
                let out = try unwrap(r.outputs.first)
                let p = try VT.probe(out)
                try expect(p.formatName.contains(container), "same container: \(p.formatName)")
                try expect(p.audio == nil, "no sound left")
                try expectEqual(p.streams("subtitle").count, 1, "the subtitle track stays")
                try expectEqual((p.streams("subtitle").first?["tags"] as? [String: Any])?["language"] as? String, lang, "its language stays")
                let text = subtitleText(out)
                try expect(text.contains("Hello, swamp") && text.contains("Привет, болото"), "the cues are intact: \(text.prefix(120))")
                try expectEqual(VideoFidelity.videoStreamMD5(out), VideoFidelity.videoStreamMD5(src), "the picture is the source's bytes")
                try expectClose(p.duration, before.duration, tolerance: 0.1)
            }
            // A clip without subtitles still works (no empty subtitle stream appears).
            let r = try await VT.run("video.mute", plain, mode: .quick, rules: VT.outRules())
            let p = try VT.probe(try unwrap(r.outputs.first))
            try expect(p.audio == nil && p.streams("subtitle").isEmpty, "nothing added")
            // The metadata declares the stream copy.
            try expectEqual(try VT.op("video.mute").meta.passthrough, .remux)
        }
    }
}
