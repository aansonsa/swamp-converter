import Foundation

// Schema, presets and quick recipes: structure and consistency (no encoding). Suite "video.schema".

enum VideoSchemaTests {
    static func reg(_ name: String, requires: [String] = [], _ body: @escaping SelfTestBody) {
        SelfTestRegistry.shared.register("video.schema", name, requires: requires, timeout: 60, body)
    }

    static func register() {
        reg("every field of video.convert and video.frames has an oracle that a test proves") {
            var unproven: [String] = []
            for schema in [VideoSchemas.convert(items: []), VideoSchemas.frames(items: [])] {
                var seen = Set<String>()
                for f in schema.allFields {
                    try expect(!f.oracle.isEmpty, "field \(f.key) has no oracle")
                    try expect(seen.insert(f.key).inserted, "duplicate key \(f.key)")
                    if VideoOracles.proven.value[f.oracle] == nil { unproven.append("\(f.key) (\(f.oracle))") }
                    try expect(!f.label.en.isEmpty && !f.label.ru.isEmpty, "label of \(f.key) is missing a language")
                }
            }
            try expect(unproven.isEmpty, "fields whose oracle no test proves: \(unproven.joined(separator: ", "))")
            // The test names that prove oracles exist.
            let names = Set(SelfTestRegistry.shared.cases.map { $0.name })
            for (id, test) in VideoOracles.proven.value { try expect(names.contains(test), "oracle \(id) names the test \"\(test)\", which is not registered") }
        }

        reg("every option has English and Russian text, help where it is not obvious, and options with both languages") {
            var noHelp: [String] = []
            for f in VideoSchemas.convert(items: []).allFields {
                try expect(f.label.en != f.label.ru || f.label.en.allSatisfy { !$0.isLetter || $0.isASCII && $0.isUppercase || $0.isNumber } || f.label.en.count < 12, "\(f.key): the Russian label equals the English one (\(f.label.en))")
                if case .picker(let opts) = f.kind { for o in opts { try expect(!o.label.en.isEmpty && !o.label.ru.isEmpty, "\(f.key).\(o.value) option label") } }
                if case .segmented(let opts) = f.kind { for o in opts { try expect(!o.label.en.isEmpty && !o.label.ru.isEmpty, "\(f.key).\(o.value) option label") } }
                if f.level == .expert, f.help == nil, !f.key.hasPrefix("md."), !f.key.hasPrefix("crop"), !f.key.hasPrefix("pad") { noHelp.append(f.key) }
            }
            try expect(noHelp.isEmpty, "expert fields without help text: \(noHelp.joined(separator: ", "))")
            let pages = VideoSchemas.convert(items: []).pages
            try expectEqual(pages.map(\.id), ["format", "video", "picture", "filters", "audio", "subtitles", "tags", "range", "gif"])
            for p in pages { try expect(!p.symbol.isEmpty && !p.title.ru.isEmpty, "page \(p.id)") }
        }

        reg("defaults resolve to a valid plan for common sources, without errors", requires: ["tool.ffmpeg"]) {
            for info in [VTPlan.info(), VTPlan.info(w: 3840, h: 2160, fps: 60, depth: 10, hdr: true, audio: [("eac3", 6, "eng")], subs: [("hdmv_pgs_subtitle", "eng")], container: "mkv"),
                         VTPlan.info(video: "mpeg2video", w: 720, h: 576, fps: 25, interlaced: true, audio: [("ac3", 2, nil)], container: "avi"), VTPlan.info(rotation: 90, audio: [])] {
                let r = VTPlan.resolve(info: info)
                try expect(!r.hasErrors, "defaults produce errors: \(r.messages.map(\.id))")
                _ = try VTPlan.plan(info: info)
            }
        }

        reg("every schema rule fires on the situation it describes and stays quiet otherwise") {
            func ids(_ set: OptionValues, _ info: MediaInfo = VTPlan.info()) -> Set<String> { Set(VTPlan.resolve([:], set, info: info).messages.map(\.id)) }
            try expect(ids([VideoKeys.container: "mp4", VideoKeys.vcodec: "vp9"]).contains("V03") || !Capabilities.shared.has("ff.enc.libvpx-vp9"), "V03 VP9 in MP4")
            try expect(ids([VideoKeys.vcodec: "hevc", VideoKeys.appleTag: false]).contains("V04"), "V04 HEVC without the Apple tag")
            try expect(!ids([VideoKeys.vcodec: "hevc"]).contains("V04"), "V04 quiet by default")
            try expect(ids([VideoKeys.vcodec: "copy", VideoKeys.rotate: "90"]).contains("V05"), "V05 copy with a filter")
            try expect(!ids([VideoKeys.vcodec: "copy"]).contains("V05"), "V05 quiet for a plain copy")
            try expect(ids([VideoKeys.vcodec: "h264", VideoKeys.bitdepth: "10"]).contains("V07"), "V07 10-bit H.264")
            try expect(ids([VideoKeys.audioCodec: "opus", VideoKeys.container: "mp4"]).contains("V09") || !Capabilities.shared.has("ff.enc.libopus"), "V09 Opus in MP4")
            try expect(ids([VideoKeys.sizeMode: "limit", VideoKeys.sizeUpscale: true]).contains("V17"), "V17 upscaling")
            try expect(ids([:], VTPlan.info(depth: 10, hdr: true)).contains("V22"), "V22 HDR kept")
            try expect(ids([VideoKeys.vcodec: "h264"], VTPlan.info(depth: 10, hdr: true)).contains("V21"), "V21 HDR into H.264")
            try expect(ids([VideoKeys.reverse: true], VTPlan.info(duration: 300)).contains("V26"), "V26 reverse over two minutes")
            try expect(ids([VideoKeys.deinterlace: "on"], VTPlan.info(interlaced: false)).contains("V28"), "V28 forced deinterlacing of progressive footage")
            try expect(ids([VideoKeys.container: "gif"], VTPlan.info(duration: 40)).contains("V15"), "V15 long GIF")
            // One-click fixes change the option they name.
            let m = VTPlan.resolve([:], [VideoKeys.vcodec: "copy", VideoKeys.rotate: "90"]).messages.first { $0.id == "V05" }
            try expectEqual(m?.fix?.set[VideoKeys.vcodec], .string("h264"))
        }

        reg("the numeric rules: end before start, a fast cut, a size too small for the clip, extreme quality, a lowered frame rate") {
            let src = MediaProbe.sourceInfo(from: VTPlan.info(duration: 120), kind: .video)
            func ids(_ set: OptionValues) -> Set<String> { Set(VideoValidation.messages(options: set, source: src).map(\.id)) }
            try expect(ids([VideoKeys.trimStart: 30.0, VideoKeys.trimEnd: 10.0]).contains("V19"), "V19")
            try expect(ids([VideoKeys.trimStart: 500.0]).contains("V19"), "V19 start beyond the end")
            try expect(ids([VideoKeys.trimStart: 5.0, VideoKeys.trimAccurate: false]).contains("V20"), "V20")
            try expect(!ids([VideoKeys.trimStart: 5.0]).contains("V20"), "V20 quiet for an exact cut")
            try expect(ids([VideoKeys.rateControl: "size", VideoKeys.targetMB: 0.3]).contains("V16"), "V16 tiny target for two minutes")
            try expect(!ids([VideoKeys.rateControl: "size", VideoKeys.targetMB: 200]).contains("V16"), "V16 quiet for a big target")
            try expect(ids([VideoKeys.cq: 8, VideoKeys.venc: "software"]).contains("V25"), "V25 huge files")
            try expect(ids([VideoKeys.cq: 40, VideoKeys.venc: "software"]).contains("V25"), "V25 detail loss")
            try expect(!ids([VideoKeys.cq: 22, VideoKeys.venc: "software"]).contains("V25"), "V25 quiet in the sweet spot")
            try expect(ids([VideoKeys.fpsMode: "constant", VideoKeys.fps: "15"]).contains("V18"), "V18 frame rate lowered")
        }

        reg("built-in presets: every key exists in the schema, every value survives resolving, and each one plans on a typical clip", requires: ["tool.ffmpeg"]) {
            let schema = VideoSchemas.convert(items: [])
            let keys = Set(schema.allFields.map(\.key))
            let info = VTPlan.info(w: 1920, h: 1080, fps: 30, duration: 120, audio: [("ac3", 6, "eng"), ("aac", 2, "rus")], subs: [("subrip", "eng")], container: "mkv", chapters: 3)
            let source = MediaProbe.sourceInfo(from: info, kind: .video)
            var ids = Set<String>()
            for p in VideoPresets.builtins {
                try expect(ids.insert(p.id).inserted, "duplicate preset id \(p.id)")
                try expectEqual(p.targetID, "video.convert")
                try expect(!p.name.en.isEmpty && !p.name.ru.isEmpty, "\(p.id) name")
                for (k, v) in p.values.storage {
                    try expect(keys.contains(k), "\(p.id): unknown key \(k)")
                    let r = schema.resolve(layers: [p.values], source: source)
                    if r.isActive(k), !(schema.field(k).map { if case .tracks = $0.kind { return true } else { return false } } ?? false) {
                        let got = r.values[k]
                        try expect(got == v || got?.asString == v.asString || (got?.asDouble != nil && got?.asDouble == v.asDouble), "\(p.id): \(k) = \(v.displayText) became \(got?.displayText ?? "nil")")
                    }
                }
                let r = schema.resolve(layers: [p.values], source: source)
                try expect(!r.hasErrors, "\(p.id): errors \(r.messages.filter { $0.severity == .error }.map(\.id))")
                let plan = try VideoPlanBuilder.build(options: r, source: info, toolset: MediaToolset.detect())
                try expect(!plan.container.isEmpty, "\(p.id): a plan")
            }
            try expect(VideoPresets.builtins.count >= 30, "\(VideoPresets.builtins.count) presets")
            try expect(Set(VideoPresets.builtins.map(\.group)).count >= 5, "preset groups")
        }

        reg("quick recipes: every operation's recipe resolves without errors, sets what the catalogue says and plans", requires: ["tool.ffmpeg"]) {
            let info = VTPlan.info(w: 1920, h: 1080, fps: 30, duration: 60, container: "mp4")
            let settings = SettingsData()
            let ops = VideoCatalog.operations().filter { $0.meta.schemaID == VideoSchemas.convertID }
            try expectEqual(ops.count, 14, "6 conversions + 2 GIF conversions + 6 tools use video.convert (thumbnail uses video.frames)")
            for op in ops {
                let quick = op.quickOverrides(settings: settings)
                let r = VTPlan.resolve(quick, [:], info: info)
                try expect(!r.hasErrors, "\(op.meta.id): \(r.messages.filter { $0.severity == .error }.map(\.id))")
                _ = try VideoPlanBuilder.build(options: r, source: info, toolset: MediaToolset.detect())
            }
            func plan(_ id: String, _ info: MediaInfo = info) throws -> VideoEncodePlan {
                let op = try unwrap(ops.first { $0.meta.id == id })
                return try VTPlan.plan(quick: op.quickOverrides(settings: settings), info: info)
            }
            var p = try plan("video.to.mp4"); try expect(p.container == "mp4" && p.videoCodec == "h264" && p.movFlagsFaststart, "to.mp4"); try expectEqual(p.audioTracks.first?.bitrateKbps, 160)
            if case .quality(let q) = p.rate { try expectEqual(q, 23, "CRF 23 from the settings") } else { throw TestFailure(message: "constant quality expected", file: #fileID, line: #line) }
            p = try plan("video.to.webm"); try expect(p.container == "webm" && p.videoCodec == "vp9" && p.audioTracks.first?.codec == "opus", "to.webm: \(p.videoEncoder) \(p.audioCodec)")
            p = try plan("video.compress"); if case .quality(let q) = p.rate { try expectEqual(q, 28, "compress CRF 28") }; try expectEqual(p.audioTracks.first?.bitrateKbps, 128)
            p = try plan("video.720p"); try expect((p.picture.outputSize?.h ?? 0) == 720, "720p: \(String(describing: p.picture.outputSize))")
            p = try plan("video.mute"); try expect(p.videoCodec == "copy" && p.audioTracks.isEmpty && p.container == "mp4", "mute is a stream copy with no audio")
            p = try plan("video.rotate"); try expectEqual(p.picture.rotate, 90)
            p = try plan("video.speed2"); try expectEqual(p.picture.speed, 2)
            p = try plan("video.to.gif"); try expect(p.gif?.fps == 12 && p.gif?.width == 640, "gif 12 fps, 640 px")
            let trim = try unwrap(ops.first { $0.meta.id == "video.trim" })
            p = try VTPlan.plan([VideoKeys.trimStart: 5.0, VideoKeys.trimEnd: 20.0], quick: trim.quickOverrides(settings: settings), info: info)
            try expect(p.trimStart == 5 && p.trimEnd == 20 && !p.copyTrim, "trim re-encodes and cuts exactly: \(p.trimStart) - \(String(describing: p.trimEnd)) copy=\(p.copyTrim)")
            let mp3 = try plan("video.to.mp3"); try expect(mp3.noVideo && mp3.container == "mp3", "to.mp3 is audio only")
            // The user's quality setting reaches the recipe.
            var custom = settings; custom.quality.videoCrf = 19
            let op = try unwrap(ops.first { $0.meta.id == "video.to.mp4" })
            if case .quality(let q) = try VTPlan.plan(quick: op.quickOverrides(settings: custom), info: info).rate { try expectEqual(q, 19) }
            try expectEqual(try unwrap(ops.first { $0.meta.id == "video.mute" }).privacyOverrides()[VideoKeys.metadataMode], .string("strip"))
        }
    }
}
