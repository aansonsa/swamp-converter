import Foundation

/// Golden argv (no encoding), the schema contract, registration and presets.
enum SmartCommandTests {
    private static func opts(_ plan: TranscodePlan, caps: SmartCapabilities? = nil) -> [String] {
        SmartCommandBuilder.outputOptions(plan, capabilities: caps ?? SK.fullCaps)
    }
    private static let tail = ["-max_muxing_queue_size", "4096"]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("smart", "golden argv: remux copies every stream, re-tags hevc, keeps faststart") {
            let mp4 = SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("aac", index: 1), SK.audio("ac3", ch: 6, index: 2), SK.sub("subrip", index: 3)]))
            try expectEqual(opts(mp4), ["-map", "0:0", "-map", "0:1", "-map", "0:2", "-map", "0:3", "-c:v", "copy", "-avoid_negative_ts", "make_zero",
                                        "-c:a:0", "copy", "-c:a:1", "copy", "-c:s", "mov_text", "-movflags", "+faststart"] + tail)
            var f = SmartVideoFacts(); f.codecTag = "hev1"
            let hevc = SK.plan(SK.info("a.mp4", [SK.video("hevc"), SK.audio("aac", index: 1)]), facts: f)
            try expectEqual(opts(hevc), ["-map", "0:0", "-map", "0:1", "-c:v", "copy", "-tag:v", "hvc1", "-avoid_negative_ts", "make_zero",
                                         "-c:a:0", "copy", "-movflags", "+faststart"] + tail)
            let mkv = SK.plan(SK.info("a.mp4", [SK.video("h264"), SK.audio("aac", index: 1), SK.sub("subrip", index: 2)])) { $0.container = "mkv" }
            try expectEqual(opts(mkv), ["-map", "0:0", "-map", "0:1", "-map", "0:2", "-c:v", "copy", "-avoid_negative_ts", "make_zero", "-c:a:0", "copy", "-c:s", "copy"] + tail)
        }
        t.register("smart", "golden argv: VP9 to hardware HEVC 8-bit and 10-bit HDR10") {
            let p = SK.plan(SK.info("a.webm", [SK.video("vp9", 1280, 720), SK.audio("opus", index: 1)]))
            try expectEqual(opts(p), ["-map", "0:0", "-map", "0:1", "-c:v", "hevc_videotoolbox", "-q:v", "65", "-profile:v", "main", "-g", "60", "-pix_fmt", "yuv420p",
                                      "-tag:v", "hvc1", "-fps_mode", "vfr", "-c:a:0", "aac_at", "-b:a:0", "256k", "-movflags", "+faststart"] + tail)
            let hdr = SK.plan(SK.info("a.webm", [SK.video("vp9", 3840, 2160, pix: "yuv420p10le", fps: 24, hdr: true), SK.audio("opus", ch: 6, index: 1)]), facts: SK.hdr10Facts())
            try expectEqual(opts(hdr), ["-map", "0:0", "-map", "0:1", "-c:v", "hevc_videotoolbox", "-q:v", "54", "-profile:v", "main10", "-g", "48", "-pix_fmt", "yuv420p10le",
                                        "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-color_range", "tv",
                                        "-fps_mode", "vfr", "-c:a:0", "aac_at", "-b:a:0", "384k", "-movflags", "+faststart"] + tail)
            var noAT = SK.fullCaps; noAT.aacAudioToolbox = false
            try expect(opts(p, caps: noAT).contains("aac"), "falls back to the native AAC encoder")
        }
        t.register("smart", "golden argv: libx265 HDR10 explicit parameters, universal libx264 and VideoToolbox H.264") {
            let sw = SK.plan(SK.info("a.mkv", [SK.video("av1", pix: "yuv420p10le", hdr: true), SK.audio("flac", index: 1)]), facts: SK.hdr10Facts()) { $0.maximumQualitySlow = true; $0.losslessAudio = true }
            let o = opts(sw)
            try expect(o.starts(with: ["-map", "0:0", "-map", "0:1", "-c:v", "libx265", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"]))
            try expect(o.contains("-x265-params"))
            try expectEqual(o[o.firstIndex(of: "-x265-params")! + 1], "log-level=error:hdr10=1:hdr10-opt=1:repeat-headers=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400")
            try expect(o.contains("alac") && !o.contains("-b:a:0"))
            let uni = SK.plan(SK.info("a.mkv", [SK.video("hevc", 1280, 720), SK.audio("opus", index: 1)]), .universal)
            try expectEqual(opts(uni), ["-map", "0:0", "-map", "0:1", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-profile:v", "high", "-pix_fmt", "yuv420p", "-tag:v", "avc1",
                                        "-fps_mode", "vfr", "-c:a:0", "aac_at", "-b:a:0", "256k", "-movflags", "+faststart"] + tail)
            let hw = SK.plan(SK.info("a.mkv", [SK.video("vp9", 1280, 720, fps: 60)]), .universal) { $0.preferHardware = true }
            try expectEqual(opts(hw), ["-map", "0:0", "-c:v", "h264_videotoolbox", "-q:v", "70", "-profile:v", "high", "-g", "120", "-pix_fmt", "yuv420p", "-tag:v", "avc1",
                                       "-fps_mode", "vfr", "-movflags", "+faststart"] + tail)
            let wide = SK.plan(SK.info("a.mkv", [SK.video("h264"), SK.audio("aac", ch: 8, index: 1)]), .universal)
            try expectEqual(wide.audioChannels, [6]); try expect(opts(wide).joined(separator: " ").contains("-b:a:0 384k -ac:a:0 6"))
        }
        t.register("smart", "golden argv: metadata strip drops tags and re-applies languages") {
            let p = SK.plan(SK.info("a.mp4", [SK.video("h264"), SK.audio("aac", index: 1, lang: "rus"), SK.audio("aac", index: 2, lang: "und")])) { $0.stripMetadata = true }
            try expect(opts(p).starts(with: ["-map", "0:0", "-map", "0:1", "-map", "0:2", "-map_metadata", "-1", "-map_metadata:s:v", "-1", "-fflags", "+bitexact", "-metadata:s:a:0", "language=rus", "-c:v"]))
            try expect(!opts(p).contains("language=und"))
            let keep = SK.plan(SK.info("a.mp4", [SK.video("h264")]))
            try expect(!opts(keep).contains("-map_metadata"))
        }
        t.register("smart", "golden argv: complete FFmpegCommand (input options, filters, output path) and keyframe interval") {
            let p = SK.plan(SK.info("a.ts", [SK.video("mpeg2video", 721, 577, interlaced: true), SK.audio("mp2", index: 1)]))
            let out = URL(fileURLWithPath: "/tmp/.x.part.mp4"), input = URL(fileURLWithPath: "/tmp/in put.ts")
            let cmd = SmartTranscoder.command(for: p, input: input, output: out)
            try expectEqual(cmd.inputs.count, 1); try expectEqual(cmd.inputs[0].url, input); try expectEqual(cmd.inputs[0].options, ["-fflags", "+genpts"])
            try expectEqual(cmd.outputs.count, 1); try expectEqual(cmd.outputs[0].url, out)
            try expectEqual(cmd.videoFilters, ["bwdif=mode=send_frame:parity=auto:deint=interlaced", "crop=trunc(iw/2)*2:trunc(ih/2)*2"])
            let remux = SmartTranscoder.command(for: SK.plan(SK.info("a.mp4", [SK.video("h264")])), input: input, output: out)
            try expect(remux.videoFilters.isEmpty && remux.global.isEmpty)
            for (fps, g) in [(24.0, 48), (29.97, 60), (60.0, 120), (120.0, 240), (5.0, 24), (500.0, 240)] { try expectEqual(SmartCommandBuilder.keyframeInterval(fps: fps), g, "\(fps)") }
            try expectEqual(SmartCommandBuilder.keyframeInterval(fps: nil), 60)
            let args = cmd.arguments()
            if args.contains("-i") { try expect(args.contains("/tmp/in put.ts") && args.last == out.path, "one argv element per path, spaces untouched") }
        }
        t.register("smart", "golden argv: tone-map chain for HDR to SDR when zscale and tonemap exist") {
            var tm = SK.fullCaps; tm.hdrToSDR = true
            let p = SK.plan(SK.info("a.mkv", [SK.video("hevc", 1920, 1080, pix: "yuv420p10le", hdr: true)]), .universal, caps: tm, facts: SK.hdr10Facts())
            try expectEqual(p.videoFilters, ["zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"])
            let o = opts(p, caps: tm)
            try expect(o.joined(separator: " ").contains("-color_trc bt709") && !o.joined(separator: " ").contains("smpte2084"))
        }

        t.register("smart", "schema smart.transcode: every field has an oracle, defaults are the quick recipe, empty items work") {
            let s = SmartSchemas.transcode(items: [])
            try expectEqual(s.id, "smart.transcode"); try expect(s.pages.count >= 4)
            let keys = s.allFields.map(\.key)
            try expectEqual(Set(keys).count, keys.count, "unique keys")
            for f in s.allFields { try expect(!f.oracle.isEmpty, "\(f.key) needs an oracle"); try expect(f.key.hasPrefix("smart."), f.key) }
            for key in [SmartKeys.mode, SmartKeys.slowMaxQuality, SmartKeys.losslessAudio, SmartKeys.audioBitrate, SmartKeys.keepAllAudio, SmartKeys.keepSubtitles,
                        SmartKeys.downscale, SmartKeys.downscaleHeight, SmartKeys.container, SmartKeys.faststart, SmartKeys.stripMetadata, SmartKeys.qualityOffset] {
                try expect(s.field(key) != nil, "\(key) is in the schema")
            }
            try expectEqual(SmartOptions(options: s.defaults()), SmartOptions(mode: .bestForApple), "defaults reproduce the quick recipe of smart.best")
            let r = s.resolve(layers: [[SmartKeys.mode: "universal", SmartKeys.audioBitrate: 320, SmartKeys.qualityOffset: 99]])
            try expectEqual(SmartOptions(options: r.values).mode, .universal); try expectEqual(SmartOptions(options: r.values).audioBitrateKbps, 320)
            try expectEqual(SmartOptions(options: r.values).qualityOffset, 10, "clamped to the stepper range")
            try expectEqual(SmartOptions(options: SmartOptions(mode: .maximum).optionValues), SmartOptions(mode: .maximum), "typed options round-trip")
        }
        t.register("smart", "schema smart.transcode: fields switch off when the mode does not use them") {
            let s = SmartSchemas.transcode(items: [])
            let max = s.resolve(layers: [[SmartKeys.mode: "max", SmartKeys.qualityOffset: 5, SmartKeys.losslessAudio: true, SmartKeys.downscale: true]])
            for k in [SmartKeys.qualityOffset, SmartKeys.slowMaxQuality, SmartKeys.losslessAudio, SmartKeys.audioBitrate, SmartKeys.downscale] {
                try expect(!max.isActive(k), "\(k) is inactive in Maximum quality")
            }
            try expectEqual(max.values.int(SmartKeys.qualityOffset), 0, "inactive fields hold their default")
            try expect(max.isActive(SmartKeys.keepAllAudio) && max.isActive(SmartKeys.container) && max.isActive(SmartKeys.stripMetadata))
            let uni = s.resolve(layers: [[SmartKeys.mode: "universal"]])
            try expect(!uni.isActive(SmartKeys.container) && !uni.isActive(SmartKeys.downscale) && uni.isActive(SmartKeys.audioBitrate))
            let mkv = s.resolve(layers: [[SmartKeys.container: "mkv"]])
            try expect(!mkv.isActive(SmartKeys.faststart))
            let ll = s.resolve(layers: [[SmartKeys.losslessAudio: true]])
            try expect(!ll.isActive(SmartKeys.audioBitrate), "the AAC bitrate is moot for lossless audio")
            let best = s.resolve(layers: [[SmartKeys.downscale: true, SmartKeys.downscaleHeight: 1080]])
            try expect(best.isActive(SmartKeys.downscaleHeight)); try expectEqual(SmartOptions(options: best.values).fallbackHeight, 1080)
        }
        t.register("smart", "operations: three sectors share one schema and differ only by the mode") {
            let ops = SmartCatalog.operations()
            try expectEqual(ops.map(\.id), ["smart.best", "smart.max", "smart.universal"])
            try expect(ops.allSatisfy { $0.meta.schemaID == "smart.transcode" && $0.meta.wheel == .convert && $0.meta.requires == [.ffmpeg] && $0.meta.concurrency == .video })
            try expectEqual(ops.map { $0.quickOverrides(settings: SettingsData())[SmartKeys.mode]?.asString }, ["best", "max", "universal"])
            let reg = OperationRegistry()
            reg.register(ops)
            let video = [FileItem(url: URL(fileURLWithPath: "/tmp/a.webm"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: video).count, 3)
            try expect(reg.entries(wheel: .convert, items: [FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)]).isEmpty, "not offered for images")
            try expect(reg.entries(wheel: .convert, items: [FileItem(url: URL(fileURLWithPath: "/tmp/a.mp3"), isDirectory: false)]).isEmpty, "not offered for audio")
            let targets = reg.studioTargets(for: video)
            try expectEqual(targets.map(\.id), ["smart.transcode"]); try expectEqual(targets[0].operations.count, 3)
            try expect(ops[0].privacyOverrides()[SmartKeys.stripMetadata]?.asBool == true)
            // The quick context of a sector resolves to its own mode.
            let ctx = OperationContext.testing(ops[2], items: video)
            try expectEqual(SmartOptions(options: ctx.options).mode, .universal)
        }
        t.register("smart", "presets: built-ins target the schema and resolve cleanly") {
            let store = PresetStore(directory: AppPaths.makeTempDirectory(purpose: "smart-presets"))
            store.registerBuiltins(SmartPresets.builtins)
            let list = store.presets(for: "smart.transcode")
            try expectEqual(list.count, SmartPresets.builtins.count); try expectEqual(Set(list.map(\.id)).count, list.count)
            let schema = SmartSchemas.transcode(items: [])
            for p in list {
                try expect(p.isBuiltin, p.id); try expect(p.operationID?.hasPrefix("smart.") == true, p.id)
                for k in p.values.keys { try expect(schema.field(k) != nil, "\(p.id) sets unknown key \(k)") }
                let r = schema.resolve(layers: [p.values])
                try expect(!r.hasErrors, p.id)
                try expectEqual(SmartOptions(options: r.values).mode.rawValue, p.values.string(SmartKeys.mode), p.id)
            }
            try expect(list.contains { $0.values.bool(SmartKeys.slowMaxQuality) } && list.contains { $0.values.bool(SmartKeys.losslessAudio) })
        }
        t.register("smart", "studio helpers: chips, estimate and live messages come from the plan without probing") {
            let op = SmartCatalog.operations()[0] as! SmartOperation
            var src = SourceInfo(url: URL(fileURLWithPath: "/tmp/clip.webm"), kind: .video)
            src.facts = ["container": "matroska,webm", "duration": 60.0, "size": 30_000_000.0, "bitrate": 4_000_000, "video.codec": "vp9", "video.width": 1920, "video.height": 1080,
                         "video.fps": 30.0, "video.pixfmt": "yuv420p10le", "video.bitdepth": 10, "audio.count": 1, "audio.0.codec": "opus", "audio.0.channels": 2]
            let chips = op.summaryChips(options: [SmartKeys.mode: "best"], source: src)
            try expect(chips.contains("HEVC 10-bit") && chips.contains("hvc1") && chips.contains("AAC 256") && chips.contains("MP4"), chips.joined(separator: ","))
            src.facts["video.codec"] = "h264"; src.facts["video.pixfmt"] = "yuv420p"; src.facts["video.bitdepth"] = 8; src.facts["audio.0.codec"] = "aac"
            try expect(op.summaryChips(options: [SmartKeys.mode: "best"], source: src).contains("Remux"))
            try expect(op.summaryChips(options: [:], source: nil).contains("hvc1"), "no source: generic chips")
            let est = try unwrap(op.estimate(options: [SmartKeys.mode: "best"], items: [], source: src))
            try expect(est.bytes ?? 0 > 20_000_000 && est.bytes ?? 0 < 40_000_000, "remux estimate is about the source size: \(est.bytes ?? 0)")
            src.facts["video.codec"] = "vp9"
            let enc = try unwrap(op.estimate(options: [SmartKeys.mode: "best"], items: [], source: src))
            try expect(enc.bytes ?? 0 > 15_000_000 && enc.bytes ?? 0 < 45_000_000, "VP9 stays about the same: \(enc.bytes ?? 0)")
            let better = try unwrap(op.estimate(options: [SmartKeys.mode: "best", SmartKeys.qualityOffset: 10], items: [], source: src))
            try expect((better.bytes ?? 0) > (enc.bytes ?? 0), "a higher quality offset estimates a larger file")
            try expect(op.estimate(options: [:], items: [], source: nil) == nil)
            src.facts["video.hdr"] = true
            let msgs = op.validate(options: [SmartKeys.mode: "universal"], source: src)
            if !SmartCapabilities.current.hdrToSDR {
                try expect(msgs.contains { $0.severity == .warning }, "HDR in Universal without tone mapping is announced before the run")
            }
            try expect(op.validate(options: [SmartKeys.mode: "best"], source: src).allSatisfy { $0.severity != .error })
        }
    }
}
