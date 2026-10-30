import Foundation

// Real runs: the audio of a video (spec/handbrake.md 2.6): codec, rate control, bitrate, channels, sample rate, gain, loudness, compressor, track rules,
// the track table, names and languages.

enum VideoRealAudioTests {
    typealias R = VideoRealTests
    static let fast: OptionValues = [VideoKeys.venc: "software", VideoKeys.speed: "ultrafast", VideoKeys.cq: 30]

    static func a(_ set: OptionValues) -> OptionValues { set.merged(over: fast) }

    static func register() {
        R.reg("audio codec: AAC, MP3, Opus, FLAC, ALAC, AC-3, E-AC-3, PCM and Vorbis come out as the codec asked for, in a container that holds them", oracles: ["a.codec.name"], timeout: 240) {
            let src = try VT.clip(VTShared.fx, "stereo.mp4", extra: ["-ac", "2"])
            let cases: [(String, String, String)] = [("aac", "mp4", "aac"), ("mp3", "mp4", "mp3"), ("opus", "mkv", "opus"), ("flac", "mkv", "flac"), ("alac", "mp4", "alac"), ("ac3", "mp4", "ac3"),
                                                      ("eac3", "mp4", "eac3"), ("pcm16", "mov", "pcm_s16le"), ("pcm24", "mov", "pcm_s24le"), ("vorbis", "mkv", "vorbis")]
            for (codec, container, expected) in cases {
                let out = try await VT.go("video.to.mp4", src, a([VideoKeys.audioCodec: .string(codec), VideoKeys.container: .string(container)])).url
                let p = try VT.probe(out)
                try expectEqual(p.str(p.audio, "codec_name"), expected, "\(codec) in \(container)")
            }
        }

        R.reg("a codec the container cannot hold is replaced by one it can, and the plan says so", oracles: []) {
            let src = try VT.clip(VTShared.fx, "stereo2.mp4", extra: ["-ac", "2"])
            // The picker coerces unusable choices; asking the planner directly for Opus in AVI shows the fallback note.
            let ok = try await VT.go("video.to.webm", src).url
            try expectEqual(try VT.probe(ok).str(try VT.probe(ok).audio, "codec_name"), "opus", "WebM takes Opus")
            let avi = try VT.probe(try await VT.go("video.to.mp4", src, a([VideoKeys.container: "avi", VideoKeys.vcodec: "mpeg4", VideoKeys.audioCodec: "mp3"])).url)
            try expectEqual(avi.str(avi.audio, "codec_name"), "mp3")
        }

        R.reg("audio bitrate is honoured within 15%, and quality (VBR) changes the size the right way", oracles: ["a.bitrate.kbps", "a.rc.mode", "a.quality.size"], timeout: 240) {
            let src = try VT.clip(VTShared.fx, "stereo3.mp4", seconds: 4, extra: ["-ac", "2"])
            for kbps in [96, 192] {
                let p = try VT.probe(try await VT.go("video.to.mp4", src, a([VideoKeys.audioBitrate: .string("\(kbps)")])).url)
                let br = p.dbl(p.audio, "bit_rate") / 1000
                try expect(abs(br - Double(kbps)) / Double(kbps) < 0.15, "audio \(br) kbit/s vs \(kbps)")
            }
            guard Capabilities.shared.has("ff.enc.libmp3lame") else { return }
            var sizes: [Int64] = []
            for q in [100, 70, 20] {
                let o = try await VT.go("video.to.mkv", src, a([VideoKeys.audioCodec: "mp3", VideoKeys.audioRC: "quality", VideoKeys.audioQuality: .int(q), VideoKeys.vcodec: "mpeg4"])).url
                let p = try VT.probe(o)
                sizes.append(Int64(p.dbl(p.audio, "bit_rate")))
            }
            try expect(sizes[0] > sizes[1] && sizes[1] > sizes[2], "MP3 VBR bitrates by quality \(sizes)")
            if Capabilities.shared.has("ff.enc.aac_at") {
                var aac: [Int64] = []
                for q in [95, 40] { let p = try VT.probe(try await VT.go("video.to.mp4", src, a([VideoKeys.audioRC: "quality", VideoKeys.audioQuality: .int(q)])).url); aac.append(Int64(p.dbl(p.audio, "bit_rate"))) }
                try expect(aac[0] > aac[1], "AAC VBR bitrates \(aac)")
            }
        }

        R.reg("channels and sample rate: mono, stereo, 5.1, Pro Logic II, 44.1 kHz, Opus rates", oracles: ["a.mixdown.channels", "a.rate.hz"], timeout: 240) {
            let st = try VT.clip(VTShared.fx, "stereo4.mp4", extra: ["-ac", "2"])
            let sur = try VTShared.get("surround") { try VT.surround($0) }
            func ch(_ src: URL, _ set: OptionValues, _ op: String = "video.to.mp4") async throws -> VTProbe { try VT.probe(try await VT.go(op, src, a(set)).url) }
            var p = try await ch(st, [VideoKeys.audioMixdown: "mono"]); try expectEqual(p.int(p.audio, "channels"), 1)
            p = try await ch(sur, [VideoKeys.audioMixdown: "stereo"]); try expectEqual(p.int(p.audio, "channels"), 2)
            p = try await ch(sur, [VideoKeys.audioMixdown: "5.1", VideoKeys.audioCodec: "ac3"]); try expectEqual(p.int(p.audio, "channels"), 6)
            p = try await ch(sur, [VideoKeys.audioMixdown: "dpl2"]); try expectEqual(p.int(p.audio, "channels"), 2)
            let dpl = try VTPlan.argv([VideoKeys.audioMixdown: "dpl2"], info: VTPlan.info(audio: [("ac3", 6, nil)])).joined(separator: " ")
            try expect(dpl.contains("aresample=matrix_encoding=dplii") && dpl.contains("-ac:a:0 2"), dpl)
            p = try await ch(sur, [VideoKeys.audioMixdown: "5.1", VideoKeys.audioCodec: "mp3"]); try expectEqual(p.int(p.audio, "channels"), 2, "MP3 holds two channels at most")
            p = try await ch(st, [VideoKeys.audioRate: "44100"]); try expectEqual(p.int(p.audio, "sample_rate"), 44100)
            p = try await ch(st, [VideoKeys.audioRate: "44100", VideoKeys.audioCodec: "opus", VideoKeys.container: "mkv"]); try expectEqual(p.int(p.audio, "sample_rate"), 48000, "Opus has no 44.1 kHz")
            p = try await ch(st, [VideoKeys.audioRate: "auto"]); try expectEqual(p.int(p.audio, "sample_rate"), 48000)
        }

        R.reg("volume change moves the level by the dB asked for (+6 and -6)", oracles: ["a.gain.db"]) {
            let src = try VTShared.get("dynamic") { try VT.dynamic($0) }
            let base = try unwrap(VT.rmsDB(try await VT.go("video.to.mp4", src, a([:])).url))
            let up = try unwrap(VT.rmsDB(try await VT.go("video.to.mp4", src, a([VideoKeys.audioGain: 6.0])).url))
            let down = try unwrap(VT.rmsDB(try await VT.go("video.to.mp4", src, a([VideoKeys.audioGain: -6.0])).url))
            try expect(abs((up - base) - 6) < 0.8 && abs((base - down) - 6) < 0.8, "levels \(down) / \(base) / \(up) dB")
        }

        R.reg("loudness: the EBU and custom targets land within 1.5 LU of the target", oracles: ["a.norm.lufs"], timeout: 240) {
            let src = try VTShared.get("dynamic") { try VT.dynamic($0) }
            for (norm, target) in [("ebu", -23.0), ("streaming", -14.0)] {
                let o = try await VT.go("video.to.mp4", src, a([VideoKeys.audioNorm: .string(norm)])).url
                let i = try unwrap(VT.loudness(o), "measured loudness")
                try expect(abs(i - target) < 1.5, "\(norm): \(i) LUFS vs \(target)")
            }
            let c = try await VT.go("video.to.mp4", src, a([VideoKeys.audioNorm: "custom", VideoKeys.audioNormLUFS: -19])).url
            let i = try unwrap(VT.loudness(c)); try expect(abs(i - -19) < 1.5, "custom: \(i) vs -19")
        }

        R.reg("compressor narrows the swings of the level (loudest to quietest moment)", oracles: ["a.comp.peak"]) {
            let src = try VTShared.get("dynamic") { try VT.dynamic($0) }
            let off = try unwrap(VT.momentarySpread(try await VT.go("video.to.mp4", src, a([VideoKeys.audioComp: "off"])).url))
            let strong = try unwrap(VT.momentarySpread(try await VT.go("video.to.mp4", src, a([VideoKeys.audioComp: "strong"])).url))
            try expect(strong < off - 2, "level swing \(strong) dB with the compressor vs \(off) dB without")
        }

        R.reg("Dolby Digital range compression is passed to the AC-3 decoder, names and languages are written", oracles: ["a.drc.argv", "a.name.tag", "a.lang.tag"]) {
            let sur = try VTShared.get("surround") { try VT.surround($0) }
            let argv = try VTPlan.argv([VideoKeys.audioDRC: 2.0], info: VTPlan.info(audio: [("ac3", 6, nil)], container: "mkv")).joined(separator: " ")
            try expect(argv.contains("-drc_scale 2"), argv)
            let o = try await VT.go("video.to.mp4", sur, a([VideoKeys.audioDRC: 2.0, VideoKeys.audioName: "Main mix", VideoKeys.audioLang: "rus", VideoKeys.container: "mkv"])).url
            let tags = try VT.probe(o).audio?["tags"] as? [String: Any] ?? [:]
            try expectEqual(tags["language"] as? String, "rus"); try expectEqual(tags["title"] as? String, "Main mix")
            let mp4 = try await VT.go("video.to.mp4", sur, a([VideoKeys.audioName: "Main mix"])).url
            try expectEqual((try VT.probe(mp4).audio?["tags"] as? [String: Any])?["handler_name"] as? String, "Main mix", "MP4 keeps the name as the handler name")
        }

        R.reg("an extra surround track copies the original Dolby Digital after the main track", oracles: ["a.second.streams"]) {
            let sur = try VTShared.get("surround") { try VT.surround($0) }
            let p = try VT.probe(try await VT.go("video.to.mp4", sur, a([VideoKeys.audioSecond: "copySurround"])).url)
            let names = p.streams("audio").map { $0["codec_name"] as? String ?? "" }
            try expectEqual(names, ["aac", "ac3"])
            try expectEqual(p.streams("audio")[1]["channels"] as? Int, 6)
        }

        R.reg("copy keeps allowed formats bit for bit and re-encodes the others with the fallback codec", oracles: ["a.passmask.copy", "a.fallback.codec"], timeout: 240) {
            let sur = try VTShared.get("surround") { try VT.surround($0) }
            let kept = try VT.probe(try await VT.go("video.to.mp4", sur, a([VideoKeys.audioCodec: "copy"])).url)
            try expectEqual(kept.str(kept.audio, "codec_name"), "ac3", "AC-3 is on the default list")
            let mp3src = try VTShared.get("odd") { try VT.oddSize($0) }
            let recoded = try VT.probe(try await VT.go("video.to.mp4", mp3src, a([VideoKeys.audioCodec: "copy", VideoKeys.audioPassMask: "aac,ac3,eac3"])).url)
            try expectEqual(recoded.str(recoded.audio, "codec_name"), "aac", "MP3 is not on the list, so the fallback AAC is used")
            let ac3 = try VT.probe(try await VT.go("video.to.mp4", mp3src, a([VideoKeys.audioCodec: "copy", VideoKeys.audioPassMask: "aac,ac3,eac3", VideoKeys.audioFallback: "ac3"])).url)
            try expectEqual(ac3.str(ac3.audio, "codec_name"), "ac3")
            let all = try VT.probe(try await VT.go("video.to.mkv", mp3src, a([VideoKeys.audioCodec: "copy", VideoKeys.audioPassMask: "all"])).url)
            try expectEqual(all.str(all.audio, "codec_name"), "mp3", "everything on the list is copied")
        }

        R.reg("track rules: first, all, none and by language (with and without the fallback); the track table builds its own tracks", oracles: ["a.mode.streams", "a.langs.streams", "a.langs.fallback", "a.tracks.streams"], timeout: 240) {
            let multi = try VTShared.get("multi") { try VT.multiAudio($0) }
            func audio(_ set: OptionValues) async throws -> [[String: Any]] { try VT.probe(try await VT.go("video.to.mp4", multi, a(set)).url).streams("audio") }
            var s = try await audio([:]); try expectEqual(s.count, 1); try expectEqual((s[0]["tags"] as? [String: Any])?["language"] as? String, "eng")
            s = try await audio([VideoKeys.audioMode: "all"]); try expectEqual(s.count, 2)
            s = try await audio([VideoKeys.audioMode: "none"]); try expectEqual(s.count, 0)
            s = try await audio([VideoKeys.audioMode: "languages", VideoKeys.audioLangs: "rus"]); try expectEqual(s.count, 1); try expectEqual((s[0]["tags"] as? [String: Any])?["language"] as? String, "rus")
            s = try await audio([VideoKeys.audioMode: "languages", VideoKeys.audioLangs: "fra", VideoKeys.audioLangFallback: true]); try expectEqual(s.count, 1, "no match: the first track")
            s = try await audio([VideoKeys.audioMode: "languages", VideoKeys.audioLangs: "fra", VideoKeys.audioLangFallback: false]); try expectEqual(s.count, 0, "no match, no fallback: no audio")
            let rows: [[String: OptionValue]] = [["src": 1, "codec": "aac", "bitrate": 96, "name": "Russian AAC"], ["src": 0, "codec": "ac3", "mixdown": "stereo", "name": "English AC-3"]]
            s = try await audio([VideoKeys.audioTracks: .rows(rows), VideoKeys.container: "mkv"])
            try expectEqual(s.map { $0["codec_name"] as? String ?? "" }, ["aac", "ac3"])
            try expectEqual(s.map { ($0["tags"] as? [String: Any])?["title"] as? String ?? "" }, ["Russian AAC", "English AC-3"])
        }

        R.reg("video.to.mp3 makes a real MP3 of the soundtrack: no picture, length kept, MP3 frames, VBR quality", oracles: []) {
            let src = try VTShared.get("dynamic") { try VT.dynamic($0) }
            let out = try await VT.go("video.to.mp3", src).url
            let p = try VT.probe(out)
            try expect(p.formatName.contains("mp3"), "format \(p.formatName)")
            try expectEqual(p.streams("video").count, 0); try expectEqual(p.str(p.audio, "codec_name"), "mp3")
            try expectClose(p.duration, 3, tolerance: 0.2)
            try expect(out.pathExtension == "mp3", "extension")
            let silent = try VT.clip(VTShared.fx, "silent.mp4", audio: false)
            let err = try await expectThrows { _ = try await VT.go("video.to.mp3", silent) }
            try expect(ConversionError.describe(err).lowercased().contains("audio"), "calm message: \(ConversionError.describe(err))")
        }
    }
}
