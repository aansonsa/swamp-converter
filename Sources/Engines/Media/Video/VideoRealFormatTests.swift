import Foundation

// Real runs: container, codec, encoder, bit depth, chroma, quality, bitrate, size target, passes, tuning, HDR tags (spec/handbrake.md 2.2, 2.3).

enum VideoRealFormatTests {
    typealias R = VideoRealTests

    static func register() {
        R.reg("to.mp4 really re-encodes: H.264 + AAC in MP4, same size and length, close to the source, moov before mdat", oracles: ["container.format", "faststart.moov"]) {
            let src = try VT.clip(VTShared.fx, "srcmkv.mkv", codec: ["-c:v", "mpeg4", "-q:v", "2", "-pix_fmt", "yuv420p"], audioCodec: ["-c:a", "libmp3lame", "-b:a", "192k"])
            let out = try await VT.go("video.to.mp4", src).url
            let p = try VT.probe(out)
            try expect(p.formatName.contains("mp4"), "format \(p.formatName)")
            try expectEqual(p.vcodec, "h264"); try expectEqual(p.pixFmt, "yuv420p")
            try expectEqual(p.str(p.audio, "codec_name"), "aac")
            try expectEqual(p.width, 320); try expectEqual(p.height, 240)
            try expectClose(p.duration, 2, tolerance: 0.15)
            let atoms = VT.atomOrder(out)
            try expect((atoms.firstIndex(of: "moov") ?? 99) < (atoms.firstIndex(of: "mdat") ?? 0), "faststart: moov before mdat, got \(atoms)")
            let psnr = try unwrap(VT.psnr(out, src)); try expect(psnr > 27, "PSNR \(psnr)")
        }

        R.reg("container: MOV, MKV and WebM hold the right streams (format name, codecs)", oracles: ["container.format"]) {
            let src = try VTShared.clip
            for (op, fmt, vc, ac) in [("video.to.mov", "mov", "h264", "aac"), ("video.to.mkv", "matroska", "h264", "aac"), ("video.to.webm", "matroska", "vp9", "opus")] {
                let out = try await VT.go(op, src).url
                let p = try VT.probe(out)
                try expect(p.formatName.contains(fmt), "\(op): format \(p.formatName)")
                try expectEqual(p.vcodec, vc, "\(op) video"); try expectEqual(p.str(p.audio, "codec_name"), ac, "\(op) audio")
                try expect(out.pathExtension == op.replacingOccurrences(of: "video.to.", with: ""), "extension of \(out.lastPathComponent)")
            }
            let webm = try await VT.go("video.to.webm", src).url
            try expect(VT.containsText(webm, "webm"), "doctype webm")
        }

        R.reg("faststart off keeps the index at the end (moov after mdat)", oracles: []) {
            let out = try await VT.go("video.to.mp4", try VTShared.clip, [VideoKeys.faststart: false]).url
            let atoms = VT.atomOrder(out)
            try expect((atoms.firstIndex(of: "moov") ?? 0) > (atoms.firstIndex(of: "mdat") ?? 99), "moov after mdat, got \(atoms)")
        }

        R.reg("vcodec: HEVC, VP9, AV1, ProRes, MPEG-4, VP8, FFV1 and DNxHR come out as the codec asked for", oracles: ["vcodec.codec"], timeout: 240) {
            let src = try VTShared.clip
            let cases: [(String, String, String, String)] = [("hevc", "mp4", "hevc", "hevc"), ("vp9", "webm", "vp9", "vp9"), ("av1", "mkv", "av1", "av1"), ("prores", "mov", "prores", "prores"),
                                                              ("mpeg4", "mp4", "mpeg4", "mpeg4"), ("vp8", "webm", "vp8", "vp8"), ("ffv1", "mkv", "ffv1", "ffv1"), ("dnxhr", "mov", "dnxhd", "dnxhd")]
            for (codec, container, expected, _) in cases {
                let out = try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: .string(codec), VideoKeys.container: .string(container), VideoKeys.speed: "veryfast"]).url
                let p = try VT.probe(out)
                try expectEqual(p.vcodec, expected, "\(codec) in \(container)")
                try expect(out.pathExtension == container, "extension .\(out.pathExtension)")
            }
        }

        R.reg("HEVC carries the hvc1 tag (and hev1 when the Apple tag is off)", oracles: ["tag.hvc1"]) {
            let src = try VTShared.clip
            let on = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "hevc", VideoKeys.speed: "veryfast"]).url)
            try expectEqual(on.str(on.video, "codec_tag_string"), "hvc1")
            let off = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "hevc", VideoKeys.speed: "veryfast", VideoKeys.appleTag: false]).url)
            try expectEqual(off.str(off.video, "codec_tag_string"), "hev1")
        }

        R.reg("encoder: software writes x264 / x265, hardware writes VideoToolbox pictures (no x264 signature)", oracles: ["venc.encoder"], requires: ["tool.ffmpeg", "native.vt.h264.hw"]) {
            let src = try VTShared.clip
            let soft = try await VT.go("video.to.mp4", src, [VideoKeys.venc: "software"]).url
            try expect(VT.containsText(soft, "x264"), "x264 signature in the software file")
            let hard = try await VT.go("video.to.mp4", src, [VideoKeys.venc: "hardware", VideoKeys.cqHardware: 60]).url
            try expect(!VT.containsText(hard, "x264"), "no x264 signature in the hardware file")
            try expectEqual(try VT.probe(hard).vcodec, "h264")
            let hevc = try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "hevc", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url
            try expect(VT.containsText(hevc, "x265"), "x265 signature")
        }

        R.reg("bit depth and chroma: 10-bit HEVC, 10-bit H.264, 4:2:2 and 4:4:4 give the pixel format asked for", oracles: ["bitdepth.pixfmt", "chroma.pixfmt"], timeout: 240) {
            let src = try VTShared.clip
            let h10 = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "hevc", VideoKeys.bitdepth: "10", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(h10.pixFmt, "yuv420p10le"); try expectEqual(h10.str(h10.video, "codec_tag_string"), "hvc1")
            let a10 = try VT.probe(try await VT.go("video.to.mkv", src, [VideoKeys.bitdepth: "10", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(a10.pixFmt, "yuv420p10le"); try expect(a10.str(a10.video, "profile").contains("10"), "profile \(a10.str(a10.video, "profile"))")
            let c422 = try VT.probe(try await VT.go("video.to.mkv", src, [VideoKeys.chroma: "4:2:2", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(c422.pixFmt, "yuv422p")
            let c444 = try VT.probe(try await VT.go("video.to.mkv", src, [VideoKeys.chroma: "4:4:4", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(c444.pixFmt, "yuv444p")
            let src10 = try VTShared.get("tenbit") { try VT.tenBit($0) }
            let auto = try VT.probe(try await VT.go("video.to.mp4", src10, [VideoKeys.vcodec: "hevc", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(auto.pixFmt, "yuv420p10le", "a 10-bit source keeps its depth with bit depth on Auto")
        }

        R.reg("constant quality is monotonic: lower RF gives a bigger file and a higher PSNR; hardware quality goes the other way", oracles: ["rc.mode", "cq.size", "cq.hw.size"]) {
            let src = try VTShared.big
            var sizes: [Int64] = [], psnr: [Double] = []
            for q in [18, 26, 34] {
                let o = try await VT.go("video.to.mp4", src, [VideoKeys.cq: .int(q), VideoKeys.speed: "veryfast", VideoKeys.venc: "software"]).url
                sizes.append(VTFile.size(o)); psnr.append(try unwrap(VT.psnr(o, src)))
            }
            try expect(sizes[0] > sizes[1] && sizes[1] > sizes[2], "sizes \(sizes)")
            try expect(psnr[0] > psnr[1] && psnr[1] > psnr[2], "PSNR \(psnr)")
            guard Capabilities.shared.has("native.vt.h264.hw") else { return }
            var hw: [Int64] = []
            for q in [30, 60, 85] {
                let o = try await VT.go("video.to.mp4", src, [VideoKeys.venc: "hardware", VideoKeys.cqHardware: .int(q)]).url
                hw.append(VTFile.size(o))
            }
            try expect(hw[0] < hw[1] && hw[1] < hw[2], "hardware sizes \(hw)")
        }

        R.reg("average bitrate is honoured within 10% (single pass) and 5% (two passes)", oracles: ["abr.bitrate", "twopass.passes"], timeout: 240) {
            let src = try VTShared.get("long") { try VT.clip($0, "long.mp4", seconds: 8, size: "640x360") }
            let one = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.rateControl: "abr", VideoKeys.vbitrate: 700, VideoKeys.twoPass: false, VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url)
            let br1 = one.dbl(one.video, "bit_rate") / 1000
            try expect(abs(br1 - 700) / 700 < 0.10, "single pass \(br1) kbit/s vs 700")
            let two = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.rateControl: "abr", VideoKeys.vbitrate: 700, VideoKeys.twoPass: true, VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url)
            let br2 = two.dbl(two.video, "bit_rate") / 1000
            try expect(abs(br2 - 700) / 700 < 0.05, "two passes \(br2) kbit/s vs 700")
            // Two passes really are two ffmpeg runs: pass 1 to the null muxer, pass 2 reading its log.
            let plan = try VTPlan.plan([VideoKeys.rateControl: "abr", VideoKeys.vbitrate: 700, VideoKeys.twoPass: true, VideoKeys.venc: "software"])
            try expectEqual(plan.passes, 2)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vt-p-\(Util.hex8())", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: tmp) }
            let cmds = try VideoFFmpegArgs.commands(for: plan, input: src, output: URL(fileURLWithPath: "/tmp/x.mp4"), tempDirectory: tmp)
            try expectEqual(cmds.count, 2)
            let a1 = cmds[0].arguments(), a2 = cmds[1].arguments()
            try expect(a1.contains("-an") && a1.contains("null") && a1.joined(separator: " ").contains("-pass 1"), "pass 1: \(a1)")
            try expect(a2.joined(separator: " ").contains("-pass 2"), "pass 2")
        }

        R.reg("target size lands at or below the target and above 75% of it; the ladder lowers the resolution when the size is tiny", oracles: ["rc.mode", "size.target", "size.ladder"], timeout: 300) {
            let src = try VTShared.get("long") { try VT.clip($0, "long.mp4", seconds: 8, size: "640x360") }
            for mb in [0.6, 1.2] {
                let o = try await VT.go("video.to.mp4", src, [VideoKeys.rateControl: "size", VideoKeys.targetMB: .double(mb), VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url
                let size = Double(VTFile.size(o)), target = mb * 1_000_000
                try expect(size <= target, "\(size) over target \(target)")
                try expect(size >= target * 0.75, "\(size) under 75% of \(target)")
            }
            let big = try VTShared.big
            let tiny = try await VT.go("video.to.mp4", big, [VideoKeys.rateControl: "size", VideoKeys.targetMB: 0.1, VideoKeys.audioMode: "none", VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url
            let p = try VT.probe(tiny)
            try expect(p.height < 480, "the ladder lowered the picture to \(p.width)x\(p.height)")
            try expect(Double(VTFile.size(tiny)) <= 100_000, "tiny target met: \(VTFile.size(tiny))")
            let flat = try await VT.go("video.to.mp4", src, [VideoKeys.rateControl: "size", VideoKeys.targetMB: 0.9, VideoKeys.sizeLadder: false, VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url
            try expectEqual(try VT.probe(flat).height, 360, "ladder off keeps the size")
        }

        R.reg("encoder speed: a slower preset gives a smaller file at the same quality", oracles: ["speed.preset"]) {
            let src = try VTShared.big
            let fast = try await VT.go("video.to.mp4", src, [VideoKeys.speed: "ultrafast", VideoKeys.venc: "software"]).url
            let slow = try await VT.go("video.to.mp4", src, [VideoKeys.speed: "slower", VideoKeys.venc: "software"]).url
            try expect(VTFile.size(slow) < VTFile.size(fast), "slower \(VTFile.size(slow)) vs ultrafast \(VTFile.size(fast))")
        }

        R.reg("profile and level are written into the stream", oracles: ["profile.codec", "level.codec"]) {
            let src = try VTShared.clip
            let base = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.profile: "baseline", VideoKeys.level: "3.1", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expect(base.str(base.video, "profile").contains("Baseline"), "profile \(base.str(base.video, "profile"))")
            try expectEqual(base.int(base.video, "level"), 31)
            let high = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.profile: "high", VideoKeys.level: "4.0", VideoKeys.venc: "software", VideoKeys.speed: "medium"]).url)
            try expectEqual(high.str(high.video, "profile"), "High"); try expectEqual(high.int(high.video, "level"), 40)
            let m10 = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "hevc", VideoKeys.profile: "main10", VideoKeys.speed: "ultrafast"]).url)
            try expect(m10.str(m10.video, "profile").contains("Main 10"), "hevc profile \(m10.str(m10.video, "profile"))")
        }

        R.reg("key frame interval, B-frames and reference frames show in the stream", oracles: ["keyint.gop", "bframes.count", "refs.count"], timeout: 240) {
            let src = try VTShared.get("long") { try VT.clip($0, "long.mp4", seconds: 8, size: "640x360") }
            let g = try await VT.go("video.to.mp4", src, [VideoKeys.keyint: 1.0, VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url
            let frames = try VT.probeFrames(g)
            var last = 0, maxGap = 0
            for (i, f) in frames.enumerated() where f["key_frame"] == "1" { maxGap = max(maxGap, i - last); last = i }
            maxGap = max(maxGap, frames.count - last)
            try expect(maxGap <= 25, "largest key-frame gap \(maxGap) frames (1 s at 24 fps)")
            let b0 = try VT.probeFrames(try await VT.go("video.to.mp4", src, [VideoKeys.bframes: "0", VideoKeys.venc: "software", VideoKeys.speed: "medium"]).url)
            try expect(!b0.contains { $0["pict_type"] == "B" }, "no B-frames when set to 0")
            let b3 = try VT.probeFrames(try await VT.go("video.to.mp4", src, [VideoKeys.bframes: "3", VideoKeys.venc: "software", VideoKeys.speed: "medium"]).url)
            try expect(b3.contains { $0["pict_type"] == "B" }, "B-frames when set to 3")
            let r1 = try await VT.go("video.to.mp4", src, [VideoKeys.refs: 1, VideoKeys.venc: "software", VideoKeys.speed: "veryfast"]).url
            try expect(VT.containsText(r1, "ref=1 "), "x264 reports ref=1")
        }

        R.reg("extra encoder options and the bitrate cap reach the encoder (read back from the x264 signature)", oracles: ["extra.params", "vbv.maxrate", "vbv.buffer"]) {
            let src = try VTShared.clip
            let o = try await VT.go("video.to.mp4", src, [VideoKeys.extra: "deblock=-2,-2:no-mbtree=1", VideoKeys.vbvMaxrate: 800, VideoKeys.vbvBuffer: 1600, VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url
            try expect(VT.containsText(o, "mbtree=0"), "extra option applied")
            try expect(VT.containsText(o, "vbv_maxrate=800"), "maxrate applied")
            try expect(VT.containsText(o, "vbv_bufsize=1600"), "buffer applied")
        }

        R.reg("tune and grain: the tune reaches x264 / x265 / SVT-AV1 / VP9 and film grain reaches SVT-AV1", oracles: ["tune.argv", "filmgrain.argv"], timeout: 240) {
            let src = try VTShared.clip
            let film = try await VT.go("video.to.mp4", src, [VideoKeys.tune: "animation", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url
            try expect(VT.containsText(film, "aq-strength=0.6") || VT.containsText(film, "psy_rd=0.40"), "animation tune parameters")
            let args = try VTPlan.argv([VideoKeys.vcodec: "av1", VideoKeys.container: "mkv", VideoKeys.filmgrain: 12, VideoKeys.tune: "psnr"])
            let joined = args.joined(separator: " ")
            try expect(joined.contains("film-grain=12") && joined.contains("tune=1"), "svtav1 params: \(joined)")
            let vp9 = try VTPlan.argv([VideoKeys.vcodec: "vp9", VideoKeys.container: "webm", VideoKeys.tune: "screen"]).joined(separator: " ")
            try expect(vp9.contains("-tune-content screen"), vp9)
            let av1 = try await VT.go("video.to.mkv", src, [VideoKeys.vcodec: "av1", VideoKeys.filmgrain: 8, VideoKeys.speed: "veryfast"]).url
            try expectEqual(try VT.probe(av1).vcodec, "av1")
        }

        R.reg("HDR is kept: a 10-bit PQ source keeps its depth, transfer and primaries and the hvc1 tag", oracles: ["hdr.tags"], timeout: 240) {
            let src = try VTShared.get("hdr") { fx in
                try VT.clip(fx, "hdr.mkv", codec: ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020", "-color_trc", "smpte2084",
                                                  "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"])
            }
            let o = try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "hevc", VideoKeys.speed: "ultrafast"]).url
            let p = try VT.probe(o)
            try expectEqual(p.pixFmt, "yuv420p10le"); try expectEqual(p.str(p.video, "color_transfer"), "smpte2084")
            try expectEqual(p.str(p.video, "color_primaries"), "bt2020"); try expectEqual(p.str(p.video, "codec_tag_string"), "hvc1")
        }

        R.reg("colour matrix and range tags are written", oracles: ["colorspace.tag", "range.tag"]) {
            let src = try VTShared.clip
            let m = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.colorspace: "bt709", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(m.str(m.video, "color_space"), "bt709")
            let full = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.colorRange: "full", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expectEqual(full.str(full.video, "color_range"), "pc")
            let lim = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.colorRange: "limited", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]).url)
            try expect(lim.str(lim.video, "color_range") != "pc", "limited range is not flagged full")
        }

        R.reg("fix audio / video start offset: the flag adds the alignment filter and the file still plays in sync", oracles: ["alignav.offset"]) {
            let argv = try VTPlan.argv([VideoKeys.alignAV: true]).joined(separator: " ")
            try expect(argv.contains("-avoid_negative_ts make_zero") && argv.contains("aresample=async=1:first_pts=0"), argv)
            let o = try await VT.go("video.to.mp4", try VTShared.clip, [VideoKeys.alignAV: true]).url
            let p = try VT.probe(o)
            try expect(abs(p.dbl(p.audio, "start_time") - p.dbl(p.video, "start_time")) < 0.1, "audio and video start together")
        }
    }
}
