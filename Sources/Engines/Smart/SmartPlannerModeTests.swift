import Foundation

/// Decision tables for Maximum quality and Universal, plus the vocabulary helpers (codec names, containers, ffprobe facts).
enum SmartPlannerModeTests {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "planner max: never transcodes; MP4 / MOV when every stream fits") {
            let h264 = SK.plan(SK.info("a.mkv", [SK.video("h264", 3840, 2160), SK.audio("aac", index: 1), SK.sub("subrip", index: 2)]), .maximum)
            try expectEqual(h264.video, .copy); try expectEqual(h264.container, "mp4"); try expect(h264.isPureRemux); try expectEqual(h264.subtitleCodec, "mov_text")
            try expectEqual(h264.targetHeight, 2160)
            let hev1 = SK.plan(SK.info("a.mp4", [SK.video("hevc"), SK.audio("ac3", ch: 6, index: 1)]), .maximum)
            try expectEqual(hev1.videoTag, "hvc1"); try expectEqual(hev1.container, "mp4")
            let prores = SK.plan(SK.info("a.mov", [SK.video("prores", pix: "yuv422p10le"), SK.audio("pcm_s24le", index: 1)]), .maximum)
            try expectEqual(prores.container, "mov"); try expectEqual(prores.audio, [.copy])
            for codec in ["vp9", "av1", "mpeg2video", "vc1"] {
                try expectEqual(SK.plan(SK.info("a.mkv", [SK.video(codec), SK.audio("aac", index: 1)]), .maximum).video, .copy, codec)
            }
            // 8K, HDR and 10-bit are copied untouched.
            let hdr = SK.plan(SK.info("a.mkv", [SK.video("hevc", 7680, 4320, pix: "yuv420p10le", hdr: true)]), .maximum, facts: SK.hdr10Facts())
            try expect(hdr.video == .copy && hdr.isHDR && hdr.videoFilters.isEmpty)
        }
        t.register("smart", "planner max: WebM for VP9 / AV1 with Opus, MKV when nothing else holds the streams") {
            let webm = SK.plan(SK.info("a.webm", [SK.video("vp9"), SK.audio("opus", index: 1)]), .maximum)
            try expectEqual(webm.container, "webm"); try expect(webm.isPureRemux); try expect(!webm.faststart)
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("av1"), SK.audio("opus", index: 1), SK.audio("vorbis", index: 2)]), .maximum).container, "webm")
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("vp9"), SK.audio("aac", index: 1)]), .maximum).container, "mp4", "VP9 + AAC fits MP4")
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("hevc"), SK.audio("dts", ch: 6, index: 1)]), .maximum).container, "mkv")
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("flac", index: 1)]), .maximum).container, "mkv")
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("mpeg2video"), SK.audio("ac3", index: 1)]), .maximum).container, "mkv")
            let pgs = SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("aac", index: 1), SK.sub("hdmv_pgs_subtitle", index: 2)]), .maximum)
            try expectEqual(pgs.container, "mkv"); try expectEqual(pgs.subtitleCodec, "copy"); try expectEqual(pgs.subtitleStreamIndexes, [2]); try expect(pgs.warnings.isEmpty)
            let noSubs = SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("aac", index: 1), SK.sub("hdmv_pgs_subtitle", index: 2)]), .maximum) { $0.keepSubtitles = false }
            try expectEqual(noSubs.container, "mp4"); try expect(noSubs.subtitleStreamIndexes.isEmpty)
            let forced = SK.plan(SK.info("a.mkv", [SK.video("hevc"), SK.audio("dts", ch: 6, index: 1)]), .maximum) { $0.container = "mp4" }
            try expectEqual(forced.container, "mkv"); try expect(!forced.warnings.isEmpty, "the user is told why MP4 was not possible")
            try expectEqual(SK.plan(SK.info("a.mp4", [SK.video("h264"), SK.audio("aac", index: 1)]), .maximum) { $0.container = "mkv" }.container, "mkv")
            try expectEqual(SK.plan(SK.info("a.mp4", [SK.video("h264"), SK.audio("aac", index: 1)]), .maximum) { $0.container = "mov" }.container, "mov")
        }
        t.register("smart", "planner universal: H.264 High 8-bit within 1080p + AAC is copied") {
            let p = SK.plan(SK.info("a.mp4", [SK.video("h264", 1920, 1080, profile: "High"), SK.audio("aac", index: 1)]), .universal)
            try expect(p.isPureRemux); try expectEqual(p.container, "mp4")
            let wide = SK.plan(SK.info("a.mkv", [SK.video("h264", 1280, 720), SK.audio("aac", ch: 6, index: 1)]), .universal)
            try expectEqual(wide.video, .copy); try expectEqual(wide.audio, [.copy], "AAC 5.1 stays")
        }
        t.register("smart", "planner universal: everything else becomes H.264 High yuv420p inside 1080p + AAC, with software or hardware encoder") {
            let k4 = SK.plan(SK.info("a.mp4", [SK.video("h264", 3840, 2160), SK.audio("aac", index: 1)]), .universal)
            try expectEqual(k4.video, .h264(encoder: "libx264")); try expectEqual(k4.targetWidth, 1920); try expectEqual(k4.targetHeight, 1080)
            try expectEqual(k4.videoFilters, ["scale=1920:1080:flags=lanczos"]); try expectEqual(k4.pixelFormat, "yuv420p"); try expectEqual(k4.videoProfile, "high")
            try expectEqual(k4.qualityValue, 18); try expectEqual(k4.encoderPreset, "medium"); try expectEqual(k4.videoTag, "avc1"); try expectEqual(k4.audio, [.copy])
            let portrait = SK.plan(SK.info("p.mp4", [SK.video("hevc", 2160, 3840)]), .universal)
            try expectEqual(portrait.targetWidth, 1080); try expectEqual(portrait.targetHeight, 1920)
            let ultrawide = SK.plan(SK.info("u.mp4", [SK.video("hevc", 3440, 1440)]), .universal)
            try expect((ultrawide.targetWidth ?? 9999) <= 1920 && (ultrawide.targetHeight ?? 9999) <= 1080, "fits the 1080p box")
            let hevc = SK.plan(SK.info("a.mp4", [SK.video("hevc", 1280, 720), SK.audio("opus", index: 1)]), .universal)
            try expectEqual(hevc.encoderName, "libx264"); try expectEqual(hevc.audio, [.aac(kbps: 256)]); try expect(hevc.videoFilters.isEmpty)
            let ten = SK.plan(SK.info("a.mkv", [SK.video("h264", 1920, 1080, pix: "yuv420p10le", profile: "High 10")]), .universal)
            try expectEqual(ten.encoderName, "libx264"); try expectEqual(ten.pixelFormat, "yuv420p")
            let hw = SK.plan(SK.info("a.mkv", [SK.video("vp9", 1280, 720)]), .universal) { $0.preferHardware = true }
            try expectEqual(hw.video, .h264(encoder: "h264_videotoolbox")); try expectEqual(hw.qualityValue, 70)
            var noX264 = SK.fullCaps; noX264.libx264 = false
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("vp9", 1280, 720)]), .universal, caps: noX264).encoderName, "h264_videotoolbox")
            var none = noX264; none.h264Hardware = false
            try expect(!SK.plan(SK.info("a.mkv", [SK.video("vp9", 1280, 720)]), .universal, caps: none).problems.isEmpty)
            let anamorphic = SK.plan(SK.info("a.mp4", [SK.video("h264", 720, 480)]), .universal, facts: { var f = SmartVideoFacts(); f.sampleAspectRatio = "32:27"; return f }())
            try expectEqual(anamorphic.encoderName, "libx264", "non-square pixels are rendered square for devices that ignore the flag")
            try expectEqual(anamorphic.targetWidth, 852); try expectEqual(anamorphic.targetHeight, 480)
            try expectEqual(anamorphic.videoFilters, ["scale=852:480:flags=lanczos,setsar=1"])
            let odd = SK.plan(SK.info("o.webm", [SK.video("vp9", 321, 241)]), .universal)
            try expectEqual(odd.videoFilters, ["crop=trunc(iw/2)*2:trunc(ih/2)*2"])
        }
        t.register("smart", "planner universal: audio is AAC, at most 5.1; extra tracks follow the option") {
            let src = SK.info("a.mkv", [SK.video("h264"), SK.audio("ac3", ch: 6, index: 1), SK.audio("aac", ch: 8, index: 2), SK.audio("mp3", index: 3)])
            let p = SK.plan(src, .universal)
            try expectEqual(p.audio, [.aac(kbps: 384), .aac(kbps: 384), .aac(kbps: 256)]); try expectEqual(p.audioChannels, [nil, 6, nil])
            try expectEqual(SK.plan(src, .universal) { $0.keepAllAudioTracks = false }.audio.count, 1)
            try expectEqual(SK.plan(src, .universal) { $0.container = "mkv" }.container, "mp4", "Universal is always MP4")
        }
        t.register("smart", "planner universal: HDR is kept with a warning without tone mapping, tone-mapped with it") {
            let src = SK.info("a.mkv", [SK.video("hevc", 3840, 2160, pix: "yuv420p10le", hdr: true), SK.audio("eac3", ch: 6, index: 1)])
            let kept = SK.plan(src, .universal, facts: SK.hdr10Facts())
            try expect(kept.isHDR && kept.isTenBit && kept.encoderName == "hevc_videotoolbox", "no washed-out SDR"); try expect(!kept.warnings.isEmpty)
            try expectEqual(kept.container, "mp4"); try expectEqual(kept.audio, [.aac(kbps: 384)])
            var tm = SK.fullCaps; tm.hdrToSDR = true
            let sdr = SK.plan(src, .universal, caps: tm, facts: SK.hdr10Facts())
            try expectEqual(sdr.encoderName, "libx264"); try expect(!sdr.isHDR); try expectEqual(sdr.color.transfer, "bt709"); try expectEqual(sdr.pixelFormat, "yuv420p")
            try expect(sdr.videoFilters.contains { $0.contains("tonemap=tonemap=hable") }, "tone-map chain")
            try expect(sdr.videoFilters.last == "scale=1920:1080:flags=lanczos")
            try expect(SK.plan(src, .universal, caps: tm, facts: SK.hdr10Facts()).warnings.isEmpty)
        }
        t.register("smart", "codec and container vocabulary: ffprobe and AVFoundation spellings map to one set") {
            for (raw, want) in [("avc1", "h264"), ("H264", "h264"), ("hvc1", "hevc"), ("hev1", "hevc"), ("dvh1", "hevc"), ("vp09", "vp9"), ("av01", "av1"),
                                ("mpeg2video", "mpeg2"), ("mp4v", "mpeg4"), ("apch", "prores"), ("wmv3", "vc1")] {
                try expectEqual(SmartCodec.video(raw), want, raw)
            }
            for (raw, want) in [("mp4a", "aac"), ("aac", "aac"), ("ac-3", "ac3"), ("ec-3", "eac3"), ("pcm_s24le", "pcm"), ("lpcm", "pcm"), ("fLaC", "flac"), ("dca", "dts"), ("mlp", "truehd")] {
                try expectEqual(SmartCodec.audio(raw), want, raw)
            }
            try expect(SmartCodec.isTextSubtitle("subrip") && SmartCodec.isTextSubtitle("mov_text") && !SmartCodec.isTextSubtitle("hdmv_pgs_subtitle"))
            try expect(SmartCodec.isBitmapSubtitle("dvd_subtitle") && !SmartCodec.isBitmapSubtitle("ass"))
            func kind(_ file: String, _ container: String) -> String { SmartContainer.kind(of: SK.info(file, container: container, [])) }
            try expectEqual(kind("a.mov", "mov,mp4,m4a,3gp,3g2,mj2"), "mov"); try expectEqual(kind("a.mp4", "mov,mp4,m4a,3gp,3g2,mj2"), "mp4")
            try expectEqual(kind("a.mkv", "matroska,webm"), "mkv"); try expectEqual(kind("a.webm", "matroska,webm"), "webm")
            try expectEqual(kind("a.avi", "avi"), "avi"); try expectEqual(kind("a.ts", "mpegts"), "ts"); try expectEqual(kind("a.xyz", ""), "other")
            try expectEqual(SmartContainer.fileExtension("mkv"), "mkv"); try expectEqual(SmartContainer.fileExtension("weird"), "mp4")
        }
        t.register("smart", "ffprobe facts parser: tag, colour, mastering display, CLL, Dolby Vision, aspect ratio") {
            let json = """
            {"frames":[{"pix_fmt":"yuv420p10le","color_range":"tv","color_space":"bt2020nc","color_primaries":"bt2020","color_transfer":"smpte2084","sample_aspect_ratio":"1:1",
             "side_data_list":[{"side_data_type":"Mastering display metadata","red_x":"17/25","red_y":"8/25","green_x":"53/200","green_y":"69/100","blue_x":"3/20","blue_y":"3/50",
             "white_point_x":"3127/10000","white_point_y":"329/1000","min_luminance":"1/10000","max_luminance":"1000/1"},
             {"side_data_type":"Content light level metadata","max_content":1000,"max_average":400}]}],
             "streams":[{"codec_name":"hevc","codec_tag_string":"hev1","profile":"Main 10","pix_fmt":"yuv420p10le","field_order":"progressive",
             "side_data_list":[{"side_data_type":"DOVI configuration record","dv_profile":8}]}]}
            """
            let f = SmartVideoFacts.parse(json: Data(json.utf8))
            try expectEqual(f.codecTag, "hev1"); try expectEqual(f.colorTransfer, "smpte2084"); try expectEqual(f.colorPrimaries, "bt2020"); try expectEqual(f.colorSpace, "bt2020nc")
            try expectEqual(f.masteringDisplay, "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"); try expectEqual(f.maxCLL, "1000,400")
            try expectEqual(f.dolbyVisionProfile, 8); try expect(f.hasHDRMetadata); try expect(f.isSquarePixels); try expectEqual(f.pixelFormat, "yuv420p10le")
            var anam = SmartVideoFacts(); anam.sampleAspectRatio = "32:27"; try expect(!anam.isSquarePixels)
            try expectEqual(SmartVideoFacts.parse(json: Data("not json".utf8)), SmartVideoFacts())
            try expectEqual(SmartVideoFacts.parse(json: Data("{}".utf8)).codecTag, nil)
            let unknown = SmartVideoFacts.parse(json: Data(#"{"streams":[{"codec_tag_string":"[0][0][0][0]","color_transfer":"unknown"}]}"#.utf8))
            try expect(unknown.codecTag == nil && unknown.colorTransfer == nil)
            try expectEqual(SmartVideoFacts.bitDepth(ofPixelFormat: "yuv420p10le"), 10); try expectEqual(SmartVideoFacts.bitDepth(ofPixelFormat: "yuv420p"), 8)
            try expectEqual(SmartVideoFacts.bitDepth(ofPixelFormat: "p010le"), 10); try expectEqual(SmartVideoFacts.bitDepth(ofPixelFormat: ""), nil)
            let counts = SmartStreamCounts.parse(json: Data(#"{"streams":[{"codec_type":"video"},{"codec_type":"video","disposition":{"attached_pic":1}},{"codec_type":"audio"},{"codec_type":"audio"},{"codec_type":"subtitle"}]}"#.utf8))
            try expectEqual(counts, SmartStreamCounts(video: 1, audio: 2, subtitle: 1))
        }
    }
}
