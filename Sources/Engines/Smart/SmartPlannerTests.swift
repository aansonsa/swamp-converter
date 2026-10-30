import Foundation

/// Decision-table tests of the pure planner: no ffmpeg, no files.
enum SmartPlannerTests {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "planner best: H.264 + AAC in MP4 is a lossless remux") {
            let p = SK.plan(SK.info("a.mp4", [SK.video("h264", profile: "High"), SK.audio("aac", index: 1)]))
            try expectEqual(p.video, .copy); try expectEqual(p.audio, [.copy]); try expectEqual(p.container, "mp4")
            try expect(p.isPureRemux); try expect(p.faststart); try expectEqual(p.videoTag, nil)
            try expectEqual(p.videoStreamIndex, 0); try expectEqual(p.audioStreamIndexes, [1]); try expectEqual(p.targetWidth, 1920)
        }
        t.register("smart", "planner best: HEVC hev1 is re-tagged hvc1 by the remux; MOV stays MOV") {
            var f = SmartVideoFacts(); f.codecTag = "hev1"
            let p = SK.plan(SK.info("a.mp4", [SK.video("hevc", profile: "Main"), SK.audio("alac", index: 1)]), facts: f)
            try expectEqual(p.video, .copy); try expectEqual(p.videoTag, "hvc1"); try expectEqual(p.audio, [.copy])
            let mov = SK.plan(SK.info("a.mov", [SK.video("hevc"), SK.audio("aac", index: 1)]))
            try expectEqual(mov.container, "mov"); try expectEqual(mov.videoTag, "hvc1")
        }
        t.register("smart", "planner best: H.264 + AC-3 in MKV remuxes into MP4 and keeps the AC-3") {
            let p = SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("ac3", ch: 6, index: 1), SK.sub("subrip", index: 2)]))
            try expectEqual(p.video, .copy); try expectEqual(p.container, "mp4"); try expectEqual(p.audio, [.copy])
            try expectEqual(p.subtitleStreamIndexes, [2]); try expectEqual(p.subtitleCodec, "mov_text")
        }
        t.register("smart", "planner best: VP9 + Opus becomes hardware HEVC hvc1 8-bit, size and frame rate kept") {
            let p = SK.plan(SK.info("a.webm", [SK.video("vp9", 1280, 720, fps: 29.97), SK.audio("opus", index: 1)]))
            try expectEqual(p.video, .hevc(encoder: "hevc_videotoolbox", tenBit: false))
            try expectEqual(p.videoTag, "hvc1"); try expectEqual(p.pixelFormat, "yuv420p"); try expectEqual(p.videoProfile, "main")
            try expectEqual(p.container, "mp4"); try expectEqual(p.targetWidth, 1280); try expectEqual(p.targetHeight, 720); try expectEqual(p.targetFPS, nil)
            try expectEqual(p.audio, [.aac(kbps: 256)]); try expectEqual(p.qualityValue, 65)
            try expect(p.videoFilters.isEmpty, "no filter for an even-sized progressive picture")
            try expect(!p.isHDR)
        }
        t.register("smart", "planner best: AV1 10-bit and HDR sources stay 10-bit with main10") {
            let p = SK.plan(SK.info("a.mkv", [SK.video("av1", 3840, 2160, pix: "yuv420p10le"), SK.audio("eac3", ch: 6, index: 1)]))
            try expectEqual(p.video, .hevc(encoder: "hevc_videotoolbox", tenBit: true)); try expectEqual(p.pixelFormat, "yuv420p10le")
            try expectEqual(p.videoProfile, "main10"); try expectEqual(p.targetHeight, 2160, "4K stays 4K"); try expectEqual(p.qualityValue, 54, "10-bit: the 4K target minus 6")
            try expectEqual(p.audio, [.copy], "E-AC-3 plays on Apple devices")
        }
        t.register("smart", "planner best: HDR10 keeps colour tags and mastering data; libx265 gets them explicitly") {
            let f = SK.hdr10Facts()
            let hw = SK.plan(SK.info("a.webm", [SK.video("vp9", pix: "yuv420p10le", hdr: true), SK.audio("opus", index: 1)]), facts: f)
            try expect(hw.isHDR); try expectEqual(hw.color.transfer, "smpte2084"); try expectEqual(hw.color.primaries, "bt2020"); try expectEqual(hw.color.matrix, "bt2020nc")
            try expectEqual(hw.video, .hevc(encoder: "hevc_videotoolbox", tenBit: true))
            let sw = SK.plan(SK.info("a.webm", [SK.video("vp9", pix: "yuv420p10le", hdr: true), SK.audio("opus", index: 1)]), facts: f) { $0.maximumQualitySlow = true }
            try expectEqual(sw.video, .hevc(encoder: "libx265", tenBit: true)); try expectEqual(sw.masteringDisplay, f.masteringDisplay); try expectEqual(sw.maxCLL, "1000,400")
            try expectEqual(sw.encoderPreset, "slow"); try expectEqual(sw.qualityValue, 18)
            let args = SmartCommandBuilder.outputOptions(sw, capabilities: SK.fullCaps)
            try expect(args.contains("-x265-params")); try expect(args.joined(separator: " ").contains("master-display=G(13250,34500)"))
            // Only the pixel flag known (no ffprobe): assumed HDR10.
            let flagOnly = SK.plan(SK.info("a.mkv", [SK.video("hevc", pix: "yuv420p10le", profile: "Main 10", hdr: true)]))
            try expect(flagOnly.video == .copy && flagOnly.color.transfer == "smpte2084", "HEVC HDR10 is copied; transfer assumed PQ")
        }
        t.register("smart", "planner best: HLG keeps arib-std-b67") {
            var f = SK.hdr10Facts(); f.colorTransfer = "arib-std-b67"; f.masteringDisplay = nil; f.maxCLL = nil
            let p = SK.plan(SK.info("a.mkv", [SK.video("av1", pix: "yuv420p10le", hdr: true)]), facts: f)
            try expectEqual(p.color.transfer, "arib-std-b67"); try expect(p.isTenBit)
            try expect(SmartCommandBuilder.outputOptions(p, capabilities: SK.fullCaps).joined(separator: " ").contains("-color_trc arib-std-b67"))
            try expect(p.chips.contains("HLG"))
        }
        t.register("smart", "planner best: odd sizes (321x241) are cropped to even, never rejected") {
            let p = SK.plan(SK.info("a.webm", [SK.video("vp9", 321, 241)]))
            try expectEqual(p.targetWidth, 320); try expectEqual(p.targetHeight, 240); try expectEqual(p.videoFilters, ["crop=trunc(iw/2)*2:trunc(ih/2)*2"])
        }
        t.register("smart", "planner best: 8K goes to libx265 when the hardware encoder is too small, or warns, or scales on request") {
            let src = SK.info("a.webm", [SK.video("vp9", 7680, 4320), SK.audio("opus", index: 1)])
            var small = SK.fullCaps; small.hevcHardwareMaxHeight = 2160
            let sw = SK.plan(src, caps: small)
            try expectEqual(sw.video, .hevc(encoder: "libx265", tenBit: false)); try expectEqual(sw.targetHeight, 4320); try expect(!sw.notes.isEmpty)
            var noSW = small; noSW.libx265 = false
            let warn = SK.plan(src, caps: noSW)
            try expectEqual(warn.video, .hevc(encoder: "hevc_videotoolbox", tenBit: false)); try expect(!warn.warnings.isEmpty, "warning offers the downscale")
            let scaled = SK.plan(src, caps: noSW) { $0.downscaleWhenUnsupported = true; $0.fallbackHeight = 2160 }
            try expectEqual(scaled.targetWidth, 3840); try expectEqual(scaled.targetHeight, 2160); try expectEqual(scaled.videoFilters, ["scale=3840:2160:flags=lanczos"])
            try expect(scaled.warnings.isEmpty)
            let real = SK.plan(src)
            try expectEqual(real.encoderName, "hevc_videotoolbox", "Apple silicon does 8K in hardware")
            try expectEqual(real.qualityValue, 56)
        }
        t.register("smart", "planner best: a limit also scales H.264 that would otherwise be copied") {
            let src = SK.info("a.mp4", [SK.video("h264", 3840, 2160), SK.audio("aac", index: 1)])
            try expectEqual(SK.plan(src).video, .copy)
            let p = SK.plan(src) { $0.downscaleWhenUnsupported = true; $0.fallbackHeight = 1080 }
            try expectEqual(p.encoderName, "hevc_videotoolbox"); try expectEqual(p.targetWidth, 1920); try expectEqual(p.targetHeight, 1080)
            let portrait = SK.plan(SK.info("p.mp4", [SK.video("h264", 2160, 3840)])) { $0.downscaleWhenUnsupported = true; $0.fallbackHeight = 1080 }
            try expectEqual(portrait.targetWidth, 1080); try expectEqual(portrait.targetHeight, 1920)
            let fits = SK.plan(SK.info("f.mp4", [SK.video("h264", 1920, 1080)])) { $0.downscaleWhenUnsupported = true; $0.fallbackHeight = 1080 }
            try expectEqual(fits.video, .copy, "already at the limit")
        }
        t.register("smart", "planner best: audio tracks (copy, copy, re-encode), surround bitrate, first-only, lossless, mono") {
            let src = SK.info("a.mkv", [SK.video("vp9", 640, 360), SK.audio("aac", index: 1, lang: "eng"), SK.audio("ac3", ch: 6, index: 2, lang: "rus"),
                                        SK.audio("dts", ch: 6, index: 3), SK.audio("opus", ch: 1, index: 4), SK.audio("flac", index: 5)])
            let p = SK.plan(src)
            try expectEqual(p.audio, [.copy, .copy, .aac(kbps: 384), .aac(kbps: 128), .aac(kbps: 256)])
            try expectEqual(p.audioStreamIndexes, [1, 2, 3, 4, 5]); try expectEqual(p.audioLanguages.prefix(2).map { $0 ?? "-" }, ["eng", "rus"])
            let first = SK.plan(src) { $0.keepAllAudioTracks = false }
            try expectEqual(first.audioStreamIndexes, [1]); try expect(!first.notes.isEmpty)
            let lossless = SK.plan(src) { $0.losslessAudio = true }
            try expectEqual(lossless.audio, [.copy, .copy, .alac, .alac, .alac], "copy stays copy, the rest becomes ALAC")
            let custom = SK.plan(SK.info("o.webm", [SK.video("vp9"), SK.audio("opus", index: 1)])) { $0.audioBitrateKbps = 160 }
            try expectEqual(custom.audio, [.aac(kbps: 160)])
        }
        t.register("smart", "planner best: text subtitles become mov_text, bitmap subtitles are dropped with a warning") {
            let src = SK.info("a.mkv", [SK.video("h264"), SK.audio("aac", index: 1), SK.sub("subrip", index: 2), SK.sub("ass", index: 3), SK.sub("hdmv_pgs_subtitle", index: 4)])
            let p = SK.plan(src)
            try expectEqual(p.subtitleStreamIndexes, [2, 3]); try expectEqual(p.subtitleCodec, "mov_text"); try expectEqual(p.warnings.count, 1)
            let none = SK.plan(src) { $0.keepSubtitles = false }
            try expect(none.subtitleStreamIndexes.isEmpty && none.subtitleCodec == nil && none.warnings.isEmpty)
        }
        t.register("smart", "planner best: H.264 High 10 / 4:2:2 and MPEG-2 / MPEG-4 / VC-1 are re-encoded, ProRes in MOV is kept") {
            let hi10 = SK.plan(SK.info("a.mkv", [SK.video("h264", pix: "yuv420p10le", profile: "High 10")]))
            try expectEqual(hi10.video, .hevc(encoder: "hevc_videotoolbox", tenBit: true))
            let s422 = SK.plan(SK.info("a.mp4", [SK.video("h264", pix: "yuv422p", profile: "High 4:2:2")]))
            try expectEqual(s422.video, .hevc(encoder: "hevc_videotoolbox", tenBit: false)); try expectEqual(s422.pixelFormat, "yuv420p")
            for codec in ["mpeg2video", "mpeg4", "vc1", "wmv3", "theora", "vp8"] {
                try expectEqual(SK.plan(SK.info("a.avi", [SK.video(codec)])).encoderName, "hevc_videotoolbox", codec)
            }
            try expectEqual(SK.plan(SK.info("a.mov", [SK.video("prores", pix: "yuv422p10le"), SK.audio("pcm_s16le", index: 1)])).video, .copy)
            try expectEqual(SK.plan(SK.info("a.mov", [SK.video("prores", pix: "yuv422p10le"), SK.audio("pcm_s16le", index: 1)])).audio, [.copy], "PCM is fine in MOV")
            try expectEqual(SK.plan(SK.info("a.mkv", [SK.video("prores", pix: "yuv422p10le")])).encoderName, "hevc_videotoolbox")
            let pcmMP4 = SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("pcm_s24le", index: 1)]))
            try expectEqual(pcmMP4.audio, [.aac(kbps: 256)], "PCM is not allowed in MP4")
        }
        t.register("smart", "planner best: phone footage rotation swaps the displayed size; interlaced sources are deinterlaced") {
            let r = SK.plan(SK.info("a.mp4", [SK.video("h264", 1920, 1080, rotation: 90)]))
            try expectEqual(r.video, .copy); try expectEqual(r.targetWidth, 1080); try expectEqual(r.targetHeight, 1920)
            let il = SK.plan(SK.info("a.mpg", [SK.video("mpeg2video", 720, 576, interlaced: true)]))
            try expect(il.deinterlace); try expectEqual(il.videoFilters, ["bwdif=mode=send_frame:parity=auto:deint=interlaced"])
            var noBwdif = SK.fullCaps; noBwdif.bwdif = false
            try expect(SK.plan(SK.info("a.mpg", [SK.video("mpeg2video", 720, 576, interlaced: true)]), caps: noBwdif).videoFilters[0].hasPrefix("yadif"))
            let copy = SK.plan(SK.info("a.mp4", [SK.video("h264", 720, 576, interlaced: true)]))
            try expect(copy.video == .copy && !copy.deinterlace, "an Apple-friendly interlaced H.264 is copied as it is")
            try expect(il.inputOptions.isEmpty, "mpg needs no timestamp repair")
            try expectEqual(SK.plan(SK.info("a.ts", [SK.video("mpeg2video", 1920, 1080)])).inputOptions, ["-fflags", "+genpts"])
        }
        t.register("smart", "planner best: encoder choice follows capabilities, slow flag, battery and quality offset") {
            let src = SK.info("a.webm", [SK.video("vp9", 1920, 1080)])
            var noHW = SK.fullCaps; noHW.hevcHardware = false
            try expectEqual(SK.plan(src, caps: noHW).encoderName, "libx265")
            var none = noHW; none.libx265 = false
            let broken = SK.plan(src, caps: none); try expect(!broken.problems.isEmpty, "no HEVC encoder is a problem the engine reports")
            var noX265 = SK.fullCaps; noX265.libx265 = false
            let slowNoX = SK.plan(src, caps: noX265) { $0.maximumQualitySlow = true }
            try expectEqual(slowNoX.encoderName, "hevc_videotoolbox"); try expect(!slowNoX.warnings.isEmpty)
            let battery = SK.plan(src) { $0.maximumQualitySlow = true; $0.preferHardware = true }
            try expectEqual(battery.encoderName, "hevc_videotoolbox"); try expect(!battery.notes.isEmpty)
            try expectEqual(SK.plan(src) { $0.qualityOffset = 5 }.qualityValue, 75)
            try expectEqual(SK.plan(src) { $0.qualityOffset = -10 }.qualityValue, 45)
            try expectEqual(SK.plan(src) { $0.maximumQualitySlow = true; $0.qualityOffset = 2 }.qualityValue, 16)
            try expectEqual(SK.plan(src, caps: noHW) { $0.qualityOffset = -3 }.qualityValue, 23)
            try expectEqual(SK.plan(src) { $0.container = "mov" }.container, "mov")
            try expectEqual(SK.plan(src) { $0.container = "mkv" }.videoTag, nil, "no hvc1 tag outside MP4 / MOV")
            try expect(!SK.plan(src) { $0.container = "mkv" }.faststart)
        }
        t.register("smart", "planner best: no video track and no ffmpeg encoders are reported as problems") {
            try expect(!SK.plan(SK.info("a.mp4", [SK.audio("aac", index: 0)])).problems.isEmpty)
            let attached = SK.video("mjpeg", index: 0)
            var cover = attached; cover.isAttachedPicture = true
            try expect(!SK.plan(SK.info("a.m4a", [cover, SK.audio("aac", index: 1)])).problems.isEmpty, "cover art is not a video")
        }
    }
}
