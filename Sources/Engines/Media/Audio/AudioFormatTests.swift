import Foundation

// Pure self-tests of the audio module: tables, the planner, golden ffmpeg / lame command lines, the schemas, presets and the DSP maths.
// Nothing here encodes a file, so these run everywhere in milliseconds.

enum AudioFormatTests {
    /// A typical ffmpeg: every encoder and filter the module can use.
    static let fullEnv = AudEnvironment(hasFFmpeg: true, hasFFprobe: true, hasLame: false,
                                        encoders: ["libmp3lame", "libopus", "libvorbis", "aac", "aac_at", "ac3", "eac3", "flac", "alac"],
                                        filters: ["loudnorm", "alimiter", "silenceremove", "atempo", "highpass", "afade", "volumedetect"])

    static func info(codec: String = "pcm_s16le", rate: Int = 44_100, channels: Int = 2, kbps: Int? = nil, duration: Double = 10, key: String = "wav") -> AudInfo {
        var i = AudInfo(url: URL(fileURLWithPath: "/tmp/a.\(key)"))
        i.codec = codec; i.sampleRate = rate; i.channels = channels; i.duration = duration; i.audioStreamCount = 1
        i.bitRate = kbps.map { $0 * 1000 } ?? (codec.hasPrefix("pcm_") ? rate * channels * 16 : nil)
        i.bitDepth = codec.hasPrefix("pcm_") || codec == "flac" ? 16 : nil
        return i
    }

    static func plan(_ v: OptionValues, info: AudInfo? = nil, key: String = "wav", env: AudEnvironment = fullEnv) throws -> AudPlan {
        try AudPlanner.make(values: v, info: info ?? Self.info(), inputKey: key, env: env)
    }

    static func job(_ p: AudPlan, info: AudInfo? = nil, env: AudEnvironment = fullEnv, cover: String? = nil, measurement: AudMeasurement? = nil) -> AudFFmpegJob {
        AudFFmpegJob(input: URL(fileURLWithPath: "/in/a b.wav"), output: URL(fileURLWithPath: "/out/x.part.m4a"), plan: p, info: info ?? Self.info(), env: env,
                     coverInput: cover.map { URL(fileURLWithPath: $0) }, measurement: measurement)
    }

    static func argv(_ v: OptionValues, info: AudInfo? = nil, env: AudEnvironment = fullEnv, key: String = "wav") throws -> [String] {
        let i = info ?? Self.info()
        return AudFFmpegArgs.transcode(job(try plan(v, info: i, key: key, env: env), info: i, env: env))
    }

    /// True when `pair` appears as two consecutive elements.
    static func has(_ a: [String], _ first: String, _ second: String) -> Bool {
        zip(a, a.dropFirst()).contains { $0.0 == first && $0.1 == second }
    }

    static func register() {
        registerTables()
        registerPlanner()
        registerArgv()
        registerSchemas()
        registerDSP()
    }

    // MARK: Tables

    private static func registerTables() {
        let t = SelfTestRegistry.shared
        t.register("audio.pure", "sample-rate, bit-rate and quality tables behave: nearest, clamp, monotonic maps") {
            try expectEqual(AudRates.nearest(44_100, in: [8_000, 12_000, 16_000, 24_000, 48_000]), 48_000)
            try expectEqual(AudRates.nearest(22_050, in: [8_000, 12_000, 16_000, 24_000, 48_000]), 24_000)
            try expectEqual(AudRates.effective(requested: nil, source: 96_000, target: .mp3), 48_000, "MP3 tops out at 48 kHz")
            try expectEqual(AudRates.effective(requested: 44_100, source: 48_000, target: .flac), 44_100)
            try expectEqual(AudBitrates.clamp(500, target: .mp3, channels: 2), 320)
            try expectEqual(AudBitrates.clamp(8, target: .aac, channels: 2), 24)
            try expectEqual(AudBitrates.roundUp(130), 160)
            var last = -1
            for q in stride(from: 0, through: 100, by: 5) {
                let v = AudQuality.aacNativeVBR(q)
                try expect(v >= last, "native AAC VBR quality must not fall as the slider rises"); last = v
            }
            try expect(AudQuality.mp3V(100) == 0 && AudQuality.mp3V(0) == 9 && AudQuality.mp3V(78) == 2, "MP3 V0 best, V9 worst, 78 is V2")
            var prev = 0
            for q in stride(from: 0, through: 100, by: 10) {
                let k = AudQuality.approxKbps(target: .mp3, quality: q)
                try expect(k >= prev, "approximate MP3 bit rate must not fall as quality rises"); prev = k
            }
            try expectEqual(AudTarget.forExtension("M4A"), .aac)
            try expectEqual(AudTarget.forExtension("xyz"), nil)
            try expectEqual(AudTarget.aac.fileExtension, "m4a")
        }
        t.register("audio.pure", "size-limit maths lands just under the limit") {
            let k = AudFit.kbps(durationSeconds: 60, targetBytes: 200_000, overheadBytes: 4_000)
            try expectEqual(k, 25)
            let bytes = Double(k) * 1000 / 8 * 60 + 4_000
            try expect(bytes <= 200_000 && bytes > 200_000 * 0.9, "estimate \(bytes) must sit within 10 percent below the limit")
        }
        t.register("audio.pure", "tag normalisation reads ID3, MP4 and Vorbis spellings") {
            let tags = AudTags.from(raw: ["TITLE": "Žluťák", "ARTIST": "A", "album_artist": "AA", "date": "2021-05-01", "track": "3/12", "DISCNUMBER": "1/2", "genre": "Rock"])
            try expectEqual(tags.title, "Žluťák"); try expectEqual(tags.albumArtist, "AA"); try expectEqual(tags.year, "2021")
            try expectEqual(tags.track, "3"); try expectEqual(tags.trackTotal, "12"); try expectEqual(tags.disc, "1"); try expectEqual(tags.trackText, "3/12")
            try expect(AudTags().isEmpty)
        }
        t.register("audio.pure", "ffprobe JSON is parsed: codec, rate, channels, bit rate, tags, cover") {
            let json = """
            {"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","channels":2,"bit_rate":"192000","tags":{"title":"T"}},
                        {"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}],
             "format":{"format_name":"mp3","duration":"12.5","size":"300000","bit_rate":"192100","tags":{"ARTIST":"Me"}}}
            """
            let i = try unwrap(AudProbe.parse(ffprobeJSON: json, url: URL(fileURLWithPath: "/x.mp3")))
            try expectEqual(i.codec, "mp3"); try expectEqual(i.sampleRate, 44_100); try expectEqual(i.channels, 2); try expectEqual(i.kbps, 192)
            try expect(i.hasCover && !i.hasVideo && i.hasAudio && !i.isLossless)
            try expectEqual(i.tags.artist, "Me"); try expectEqual(i.tags.title, "T")
            try expectClose(i.duration ?? 0, 12.5)
        }
    }

    // MARK: Planner

    private static func registerPlanner() {
        let t = SelfTestRegistry.shared
        t.register("audio.plan", "automatic keeps a compact file untouched and never re-encodes it into something worse") {
            let compact = info(codec: "mp3", kbps: 96, key: "mp3")
            let p = try plan([AudioKeys.target: "auto", AudioKeys.bitrate: 128], info: compact, key: "mp3")
            try expect(p.passthrough, "96 kbit/s is already below 128: keep")
            try expectEqual(p.fileExtension, "mp3")
            try expect(!p.notes.isEmpty, "the decision is explained")
            let big = info(codec: "mp3", kbps: 320, key: "mp3")
            let q = try plan([AudioKeys.target: "auto", AudioKeys.bitrate: 128], info: big, key: "mp3")
            try expect(!q.passthrough); try expectEqual(q.target, .mp3, "the MP3 family is kept"); try expectEqual(q.kbps, 128)
            let touched = try plan([AudioKeys.target: "auto", AudioKeys.bitrate: 128, AudioKeys.tagsMode: "strip"], info: compact, key: "mp3")
            try expect(!touched.passthrough, "asking for stripped tags needs a real write")
            let lossless = try plan([AudioKeys.target: "auto", AudioKeys.bitrate: 128], info: info(codec: "flac", key: "flac"), key: "flac")
            try expectEqual(lossless.target, .aac, "lossless sources become AAC")
        }
        t.register("audio.plan", "keep-the-format resolves per file and degrades with a note when the encoder is missing") {
            try expectEqual(try plan([AudioKeys.target: "same"], key: "wav").target, .wav)
            try expectEqual(try plan([AudioKeys.target: "same"], info: info(codec: "alac", key: "m4a"), key: "m4a").target, .alac)
            try expectEqual(try plan([AudioKeys.target: "same"], info: info(codec: "wmav2", key: "wma"), key: "wma").target, .mp3)
            let noFF = try plan([AudioKeys.target: "same"], info: info(codec: "opus", key: "opus"), key: "opus", env: .none)
            try expectEqual(noFF.target, .aac); try expect(!noFF.notes.isEmpty)
        }
        t.register("audio.plan", "targets this Mac cannot write throw a calm error; Ogg uses the built-in Vorbis encoder when libvorbis is missing, never Opus") {
            var threw = false
            do { _ = try plan([AudioKeys.target: "mp3"], env: .none) } catch let e as ConversionError { if case .unsupported = e { threw = true } }
            try expect(threw, "MP3 without ffmpeg or lame must be refused, not faked")
            var lameOnly = AudEnvironment.none; lameOnly.hasLame = true
            try expectEqual(try plan([AudioKeys.target: "mp3"], env: lameOnly).target, .mp3)
            var noVorbis = fullEnv; noVorbis.encoders.remove("libvorbis"); noVorbis.hasSoxVorbis = true
            let ogg = try plan([AudioKeys.target: "ogg", AudioKeys.rateControl: "quality", AudioKeys.quality: 50, AudioKeys.channels: "mono"], env: noVorbis)
            try expect(ogg.oggViaSox && !ogg.notes.isEmpty && ogg.channels == 1, "sox encodes it, mono stays mono, and the person is told")
            try expect(!(try plan([AudioKeys.target: "ogg"]).oggViaSox), "libvorbis when the encoder exists")
            var neither = fullEnv; neither.encoders.remove("libvorbis")
            var refused = false
            do { _ = try plan([AudioKeys.target: "ogg"], env: neither) } catch let e as ConversionError { if case .unsupported = e { refused = true } }
            try expect(refused, "ffmpeg's experimental Vorbis encoder is not used and Opus never hides under an .ogg name: the target is refused")
        }
        t.register("audio.plan", "MP3 mixes surround down to stereo; rates and bit rates are moved into the encoder's range with notes") {
            let surround = info(codec: "ac3", rate: 48_000, channels: 6, kbps: 448, key: "ac3")
            let p = try plan([AudioKeys.target: "mp3"], info: surround, key: "ac3")
            try expectEqual(p.channels, 2); try expect(!p.notes.isEmpty)
            let r = try plan([AudioKeys.target: "mp3", AudioKeys.sampleRate: "96000", AudioKeys.bitrate: 500])
            try expectEqual(r.sampleRate, 48_000); try expectEqual(r.kbps, 320); try expect(r.notes.count >= 2)
            let op = try plan([AudioKeys.target: "opus"], info: info(rate: 44_100))
            try expectEqual(op.sampleRate, 48_000, "Opus never runs at 44.1 kHz")
        }
        t.register("audio.plan", "impossible ranges are refused: end before start, start after the end, cover without a picture") {
            for (v, key) in [([AudioKeys.trimStart: 5, AudioKeys.trimEnd: 3] as OptionValues, AudioKeys.trimEnd),
                             ([AudioKeys.trimStart: 99] as OptionValues, AudioKeys.trimStart),
                             ([AudioKeys.coverMode: "replace", AudioKeys.coverFile: "/nonexistent.jpg"] as OptionValues, AudioKeys.coverFile)] {
                var got: String?
                do { _ = try plan(v) } catch let e as ConversionError { if case .invalidOption(let k, _) = e { got = k } }
                try expectEqual(got, key)
            }
        }
        t.register("audio.plan", "size limit turns into a constant bit rate under the limit and an honest note when it cannot") {
            let p = try plan([AudioKeys.target: "aac", AudioKeys.fitMB: 0.2], info: info(duration: 60))
            try expectEqual(p.kbps, 25); try expect(!p.useQuality); try expectEqual(p.fitBytes, 200_000)
            let tiny = try plan([AudioKeys.target: "aac", AudioKeys.fitMB: 0.05], info: info(duration: 600))
            try expectEqual(tiny.kbps, 24, "clamped to the encoder floor"); try expect(!tiny.notes.isEmpty)
            let trimmed = try plan([AudioKeys.target: "aac", AudioKeys.fitMB: 0.2, AudioKeys.trimEnd: 30], info: info(duration: 60))
            try expect(trimmed.kbps > p.kbps, "a trimmed clip may use a higher bit rate for the same limit")
        }
        t.register("audio.plan", "estimate is bit rate times duration for lossy and PCM size for WAV") {
            let i = info(duration: 100)
            let aac = try plan([AudioKeys.target: "aac", AudioKeys.bitrate: 128], info: i)
            let e = try unwrap(AudEstimate.estimate(plan: aac, info: i))
            try expect(abs(Double(e.bytes ?? 0) - 1_600_000) < 20_000, "128 kbit/s x 100 s = 1.6 MB")
            let wav = try plan([AudioKeys.target: "wav", AudioKeys.bitDepth: "16"], info: i)
            try expect(abs(Double(try unwrap(AudEstimate.estimate(plan: wav, info: i)).bytes ?? 0) - 17_640_000) < 1_000, "44.1 kHz x 2 x 2 bytes x 100 s")
        }
    }

    // MARK: Golden command lines

    private static func registerArgv() {
        let t = SelfTestRegistry.shared
        t.register("audio.argv", "every ffmpeg-realised option shows up as a visible argument (codecs and rate control)") {
            var a = try argv([AudioKeys.target: "mp3", AudioKeys.rateControl: "quality", AudioKeys.quality: 78])
            try expect(has(a, "-c:a", "libmp3lame") && has(a, "-q:a", "2") && has(a, "-f", "mp3"), "\(a)")
            a = try argv([AudioKeys.target: "mp3", AudioKeys.bitrate: 192, AudioKeys.mp3Joint: false, AudioKeys.mp3ID3: "v24"])
            try expect(has(a, "-b:a", "192k") && has(a, "-joint_stereo", "0") && has(a, "-id3v2_version", "4"), "\(a)")
            a = try argv([AudioKeys.target: "aac", AudioKeys.bitrate: 256])
            try expect(has(a, "-c:a", "aac_at") && has(a, "-b:a", "256k") && has(a, "-f", "ipod"), "\(a)")
            var plain = fullEnv; plain.encoders.remove("aac_at")
            a = try argv([AudioKeys.target: "aac", AudioKeys.bitrate: 256], env: plain)
            try expect(has(a, "-c:a", "aac"), "the built-in AAC encoder is the fallback: \(a)")
            a = try argv([AudioKeys.target: "opus", AudioKeys.bitrate: 32, AudioKeys.opusApp: "voip", AudioKeys.opusVBR: "constrained"])
            try expect(has(a, "-c:a", "libopus") && has(a, "-b:a", "32k") && has(a, "-application", "voip") && has(a, "-vbr", "constrained"), "\(a)")
            a = try argv([AudioKeys.target: "ogg", AudioKeys.rateControl: "quality", AudioKeys.quality: 50])
            try expect(has(a, "-c:a", "libvorbis") && has(a, "-q:a", "5"), "\(a)")
            var tags = AudTags(); tags.title = "Привет"; tags.track = "2"; tags.trackTotal = "9"
            let q = try plan([AudioKeys.target: "ogg", AudioKeys.rateControl: "quality", AudioKeys.quality: 50])
            var s = AudSox.arguments(plan: q, tags: tags, input: URL(fileURLWithPath: "/tmp/in.wav"), output: URL(fileURLWithPath: "/tmp/out.ogg"))
            try expect(has(s, "-C", "5.00") && has(s, "--add-comment", "TITLE=Привет") && has(s, "--add-comment", "TRACKNUMBER=2") && has(s, "--add-comment", "TRACKTOTAL=9") && has(s, "--comment", ""), "\(s)")
            s = AudSox.arguments(plan: try plan([AudioKeys.target: "ogg", AudioKeys.bitrate: 128]), tags: AudTags(), input: URL(fileURLWithPath: "/tmp/in.wav"), output: URL(fileURLWithPath: "/tmp/out.ogg"))
            try expect(has(s, "-C", "4.00") && !s.contains("--add-comment") && s.last == "/tmp/out.ogg", "\(s)")
            try expectClose(AudSox.quality(forKbps: 144), 4.5, tolerance: 0.01); try expectEqual(AudSox.quality(forKbps: 10), -1); try expectEqual(AudSox.quality(forKbps: 900), 10)
            a = try argv([AudioKeys.target: "ac3", AudioKeys.bitrate: 384])
            try expect(has(a, "-c:a", "ac3") && has(a, "-b:a", "384k"), "\(a)")
        }
        t.register("audio.argv", "lossless targets: FLAC level and bit depth, WAV / AIFF sample formats, ALAC depth") {
            var a = try argv([AudioKeys.target: "flac", AudioKeys.flacLevel: 8, AudioKeys.bitDepth: "16"])
            try expect(has(a, "-compression_level", "8") && has(a, "-sample_fmt", "s16"), "\(a)")
            a = try argv([AudioKeys.target: "flac", AudioKeys.bitDepth: "24"])
            try expect(has(a, "-sample_fmt", "s32") && has(a, "-bits_per_raw_sample", "24"), "\(a)")
            a = try argv([AudioKeys.target: "wav", AudioKeys.bitDepth: "24"]); try expect(has(a, "-c:a", "pcm_s24le"), "\(a)")
            a = try argv([AudioKeys.target: "wav", AudioKeys.bitDepth: "32f"]); try expect(has(a, "-c:a", "pcm_f32le"), "\(a)")
            a = try argv([AudioKeys.target: "wav", AudioKeys.bitDepth: "16"]); try expect(has(a, "-c:a", "pcm_s16le"), "\(a)")
            a = try argv([AudioKeys.target: "aiff", AudioKeys.bitDepth: "16"]); try expect(has(a, "-c:a", "pcm_s16be") && has(a, "-f", "aiff"), "\(a)")
            a = try argv([AudioKeys.target: "alac", AudioKeys.bitDepth: "24"]); try expect(has(a, "-c:a", "alac") && has(a, "-bits_per_raw_sample", "24"), "\(a)")
            var floatInfo = info(codec: "pcm_f32le", key: "wav"); floatInfo.isFloat = true; floatInfo.bitDepth = 32
            a = try argv([AudioKeys.target: "wav"], info: floatInfo)
            try expect(has(a, "-c:a", "pcm_f32le"), "keep follows a float source: \(a)")
        }
        t.register("audio.argv", "sound options: gain, high-pass, speed, fades, limiter, silence trim, rate, channels") {
            var a = try argv([AudioKeys.target: "wav", AudioKeys.gain: 3.5, AudioKeys.highpass: 80, AudioKeys.speed: 1.5, AudioKeys.limiter: true, AudioKeys.silence: true])
            let af = try unwrap(zip(a, a.dropFirst()).first { $0.0 == "-af" }?.1)
            for piece in ["volume=3.5dB", "highpass=f=80", "atempo=1.5", "alimiter=limit=0.89:level=false", "silenceremove="] { try expect(af.contains(piece), "\(piece) missing in \(af)") }
            a = try argv([AudioKeys.target: "wav", AudioKeys.speed: 2])
            try expect(AudFFmpegArgs.tempoFilters(4) == ["atempo=2", "atempo=2"] && AudFFmpegArgs.tempoFilters(0.25) == ["atempo=0.5", "atempo=0.5"], "tempo chaining")
            a = try argv([AudioKeys.target: "wav", AudioKeys.fadeIn: 2, AudioKeys.fadeOut: 3], info: info(duration: 10))
            let fades = try unwrap(zip(a, a.dropFirst()).first { $0.0 == "-af" }?.1)
            try expect(fades.contains("afade=t=in:st=0:d=2") && fades.contains("afade=t=out:st=7:d=3"), fades)
            a = try argv([AudioKeys.target: "aac", AudioKeys.sampleRate: "48000", AudioKeys.channels: "mono"])
            try expect(has(a, "-ar", "48000") && has(a, "-ac", "1"), "\(a)")
        }
        t.register("audio.argv", "trim is an exact input option; fast copy drops every filter and copies the stream") {
            var a = try argv([AudioKeys.target: "wav", AudioKeys.trimStart: 1.5, AudioKeys.trimEnd: 5])
            let ss = try unwrap(a.firstIndex(of: "-ss")), i = try unwrap(a.firstIndex(of: "-i"))
            try expect(ss < i && has(a, "-ss", "1.5") && has(a, "-t", "3.5"), "-ss/-t before -i, length = end - start: \(a)")
            a = try argv([AudioKeys.target: "same", AudioKeys.trimStart: 1, AudioKeys.trimEnd: 4, AudioKeys.trimMode: "copy", AudioKeys.gain: 6], info: info(codec: "mp3", kbps: 192, key: "mp3"), key: "mp3")
            try expect(has(a, "-c:a", "copy") && !a.contains("-af"), "copy mode ignores filters: \(a)")
        }
        t.register("audio.argv", "loudness: single-pass and measured two-pass loudnorm, peak gain, the measuring command") {
            let i = info(duration: 10)
            var p = try plan([AudioKeys.target: "wav", AudioKeys.normalize: "podcast"], info: i)
            var f = AudFFmpegArgs.filterChain(job(p, info: i))
            try expect(f.contains("loudnorm=I=-16:TP=-1.5:LRA=11"), "\(f)")
            f = AudFFmpegArgs.filterChain(job(p, info: i, measurement: AudMeasurement(inputI: -24.5, inputTP: -3.1, inputLRA: 6.2, inputThresh: -35, offset: 0.4)))
            try expect(f.joined().contains("measured_I=-24.5") && f.joined().contains("offset=0.4") && f.joined().contains("linear=true"), "\(f)")
            let m = AudFFmpegArgs.measurement(job(p, info: i))
            try expect(m.contains("-f") && m.last == "-" && m.joined(separator: " ").contains("print_format=json"), "\(m)")
            p = try plan([AudioKeys.target: "wav", AudioKeys.normalize: "peak"], info: i)
            f = AudFFmpegArgs.filterChain(job(p, info: i, measurement: AudMeasurement(peakGainDB: 4.25)))
            try expect(f.contains("volume=4.25dB"), "\(f)")
            try expect(AudFFmpegArgs.measurement(job(p, info: i)).joined().contains("volumedetect"))
            let custom = try plan([AudioKeys.target: "wav", AudioKeys.normalize: "custom", AudioKeys.normLUFS: -18, AudioKeys.normTP: -2], info: i)
            try expect(AudFFmpegArgs.filterChain(job(custom, info: i)).first?.hasPrefix("loudnorm=I=-18:TP=-2") == true)
            let json = """
            [Parsed_loudnorm_0 @ 0x1] \n{\n\t"input_i" : "-24.52",\n\t"input_tp" : "-3.10",\n\t"input_lra" : "6.20",\n\t"input_thresh" : "-35.00",\n\t"output_i" : "-16.0",\n\t"target_offset" : "0.41"\n}
            """
            let mm = try unwrap(AudFFmpegArgs.parseLoudnorm([json]))
            try expectClose(mm.inputI, -24.52, tolerance: 0.001); try expectClose(mm.offset, 0.41, tolerance: 0.001)
            try expectClose(try unwrap(AudFFmpegArgs.parseMaxVolume(["[Parsed_volumedetect_0 @ 0x1] max_volume: -6.0 dB"])), -6)
            try expect(AudFFmpegArgs.parseLoudnorm(["{\"input_i\": \"-inf\"}"]) == nil, "silence cannot be measured")
            try expectClose(try unwrap(AudFFmpegArgs.parseProgressSeconds("out_time_us=1500000")), 1.5)
        }
        t.register("audio.argv", "loudnorm runs at the source rate (it upsamples to 192 kHz otherwise)") {
            let i = info(rate: 44_100, duration: 10)
            let a = try argv([AudioKeys.target: "wav", AudioKeys.normalize: "ebu"], info: i)
            try expect(has(a, "-ar", "44100"), "\(a)")
        }
        t.register("audio.argv", "tags and cover: strip, custom edits, track/total, replace, keep") {
            var a = try argv([AudioKeys.target: "mp3", AudioKeys.tagsMode: "strip"])
            try expect(has(a, "-map_metadata", "-1") && has(a, "-fflags", "+bitexact"), "\(a)")
            a = try argv([AudioKeys.target: "mp3", AudioKeys.tagsMode: "custom", AudioKeys.tagTitle: "Привет", AudioKeys.tagArtist: "Me", AudioKeys.tagYear: "2020",
                          AudioKeys.tagTrack: "3", AudioKeys.tagTrackTotal: "12", AudioKeys.tagAlbumArtist: "AA"])
            for kv in ["title=Привет", "artist=Me", "date=2020", "track=3/12", "album_artist=AA"] { try expect(has(a, "-metadata", kv), "\(kv) in \(a)") }
            let p = try plan([AudioKeys.target: "mp3", AudioKeys.coverMode: "remove"], info: { var i = info(); i.hasCover = true; return i }())
            let removed = AudFFmpegArgs.transcode(job(p, info: { var i = info(); i.hasCover = true; return i }()))
            try expect(!removed.contains("0:v:0?") && !removed.contains("attached_pic"), "remove drops the picture: \(removed)")
            var withCover = info(); withCover.hasCover = true
            let keep = AudFFmpegArgs.transcode(job(try plan([AudioKeys.target: "mp3"], info: withCover), info: withCover))
            try expect(has(keep, "-map", "0:v:0?") && has(keep, "-disposition:v", "attached_pic"), "keep copies the picture: \(keep)")
            let rep = AudFFmpegArgs.transcode(job(try plan([AudioKeys.target: "mp3"], info: withCover), info: withCover, cover: "/tmp/c.jpg"))
            try expect(has(rep, "-map", "1:v:0"), "replace maps the second input: \(rep)")
            let wavCover = try argv([AudioKeys.target: "wav"], info: withCover)
            try expect(!wavCover.contains("attached_pic"), "WAV cannot carry a picture")
        }
        t.register("audio.argv", "arguments are an array: spaces, leading dashes and unicode in paths stay one argument") {
            var p = try plan([AudioKeys.target: "wav"])
            p.fileExtension = "wav"
            let j = AudFFmpegJob(input: URL(fileURLWithPath: "/in/-weird name Привет.wav"), output: URL(fileURLWithPath: "/out/o.wav"), plan: p, info: info(), env: fullEnv)
            let a = AudFFmpegArgs.transcode(j)
            try expect(a.contains("/in/-weird name Привет.wav"), "\(a)")
            try expect(has(a, "-i", "/in/-weird name Привет.wav"), "absolute paths cannot be mistaken for options")
        }
        t.register("audio.argv", "lame command line: VBR, CBR, ABR, joint stereo, UTF-16 tags") {
            var tags = AudTags(); tags.title = "Привет"; tags.artist = "A"; tags.track = "2"; tags.trackTotal = "9"
            var p = try plan([AudioKeys.target: "mp3", AudioKeys.rateControl: "quality", AudioKeys.quality: 100])
            var a = AudLameArgs.arguments(plan: p, tags: tags, cover: nil, input: URL(fileURLWithPath: "/i.wav"), output: URL(fileURLWithPath: "/o.mp3"))
            try expect(has(a, "-V", "0") && has(a, "-m", "j") && has(a, "--tt", "Привет") && has(a, "--tn", "2/9") && a.contains("--id3v2-utf16"), "\(a)")
            p = try plan([AudioKeys.target: "mp3", AudioKeys.bitrate: 160, AudioKeys.mp3Joint: false])
            a = AudLameArgs.arguments(plan: p, tags: AudTags(), cover: nil, input: URL(fileURLWithPath: "/i.wav"), output: URL(fileURLWithPath: "/o.mp3"))
            try expect(has(a, "-b", "160") && a.contains("--cbr") && has(a, "-m", "s") && !a.contains("--add-id3v2"), "\(a)")
            try expectClose(try unwrap(AudLameArgs.parsePercent("   123/456   ( 62%)|    0:03/    0:05")), 0.62)
        }
    }

    // MARK: Schemas and presets

    private static func registerSchemas() {
        let t = SelfTestRegistry.shared
        t.register("audio.schema", "every field of both schemas carries an oracle id and a unique key; labels exist in both languages") {
            for schema in [AudioSchemas.convert(items: []), AudioSchemas.join(items: [])] {
                var keys = Set<String>()
                for f in schema.allFields {
                    try expect(!f.oracle.isEmpty, "\(f.key) has no oracle")
                    try expect(keys.insert(f.key).inserted, "duplicate key \(f.key) in \(schema.id)")
                    try expect(!f.label.en.isEmpty && !f.label.ru.isEmpty, "\(f.key) label")
                }
            }
            let convert = AudioSchemas.convert(items: [])
            let oracles = convert.allFields.map(\.oracle)
            try expectEqual(Set(oracles).count, oracles.count, "oracle ids are unique inside audio.convert")
        }
        t.register("audio.schema", "every key the planner reads exists in the schema; defaults make a neutral AAC plan") {
            let schema = AudioSchemas.convert(items: [])
            let known = Set(schema.allFields.map(\.key))
            let used: [String] = [AudioKeys.target, AudioKeys.rateControl, AudioKeys.bitrate, AudioKeys.quality, AudioKeys.aacProfile, AudioKeys.sampleRate, AudioKeys.bitDepth,
                                  AudioKeys.channels, AudioKeys.flacLevel, AudioKeys.opusApp, AudioKeys.opusVBR, AudioKeys.mp3Joint, AudioKeys.mp3ID3, AudioKeys.fitMB, AudioKeys.gain,
                                  AudioKeys.normalize, AudioKeys.normLUFS, AudioKeys.normTP, AudioKeys.normTwoPass, AudioKeys.limiter, AudioKeys.silence, AudioKeys.silenceDB,
                                  AudioKeys.highpass, AudioKeys.fadeIn, AudioKeys.fadeOut, AudioKeys.speed, AudioKeys.trimStart, AudioKeys.trimEnd, AudioKeys.trimMode,
                                  AudioKeys.tagsMode, AudioKeys.coverMode, AudioKeys.coverFile, AudioKeys.coverMax] + AudioKeys.tagFields.map(\.key)
            for k in used { try expect(known.contains(k), "\(k) is not a field") }
            let p = try plan(OptionValues(), env: .none)
            try expect(p.target == .aac && !p.passthrough && !p.hasDSP && !p.isTrimmed && p.norm == nil && p.speed == 1 && p.tagsMode == .keep && p.coverMode == .keep)
            let joinKeys = Set(AudioSchemas.join(items: []).allFields.map(\.key))
            for k in [AudioKeys.joinRate, AudioKeys.joinChannels, AudioKeys.joinOrder, AudioKeys.joinGap, AudioKeys.joinCrossfade, AudioKeys.target] { try expect(joinKeys.contains(k), k) }
        }
        t.register("audio.schema", "the catalogue has the 11 operations; quick recipes only use fields of the shared schema; Join uses its own") {
            let ops = AudioCatalog.operations()
            try expectEqual(ops.map(\.meta.id), ["audio.to.mp3", "audio.to.m4a", "audio.to.wav", "audio.to.flac", "audio.to.ogg", "audio.to.opus", "audio.to.aiff",
                                                "audio.compress", "audio.normalize", "audio.trim", "audio.concat"])
            let convertKeys = Set(AudioSchemas.convert(items: []).allFields.map(\.key))
            for op in ops {
                if op.meta.id == "audio.concat" { try expectEqual(op.meta.schemaID, AudioSchemas.joinID); continue }
                try expectEqual(op.meta.schemaID, AudioSchemas.convertID)
                for k in op.quickOverrides(settings: SettingsData()).keys { try expect(convertKeys.contains(k), "\(op.meta.id) recipe uses unknown key \(k)") }
            }
        }
        t.register("audio.schema", "built-in presets only use real fields and legal values") {
            let schema = AudioSchemas.convert(items: [])
            for p in AudioPresets.builtins {
                try expectEqual(p.targetID, AudioSchemas.convertID)
                for (k, v) in p.values.storage {
                    let f = try unwrap(schema.field(k), "preset \(p.id) uses unknown key \(k)")
                    switch f.kind {
                    case .picker(let opts), .segmented(let opts): try expect(opts.contains { $0.value == v.asString }, "preset \(p.id): \(k)=\(v.displayText) is not an option")
                    case .slider(let s): try expect((v.asDouble ?? -1e9) >= s.min && (v.asDouble ?? 1e9) <= s.max, "preset \(p.id): \(k) out of range")
                    default: break
                    }
                }
                // Every preset must produce a plan (or a clean refusal for a tool this Mac lacks), never a crash.
                let plan = try? AudPlanner.make(values: p.values, info: info(duration: 120), inputKey: "wav", env: fullEnv)
                try expect(plan != nil, "preset \(p.id) does not plan")
            }
            let ids = AudioPresets.builtins.map(\.id)
            try expectEqual(Set(ids).count, ids.count, "preset ids unique")
        }
        t.register("audio.schema", "bit rate and quality controls follow the target: lossless disables both, AAC quality is a real mode") {
            let schema = AudioSchemas.convert(items: [])
            let flac = schema.resolve(layers: [[AudioKeys.target: "flac", AudioKeys.bitrate: 320]])
            try expect(!flac.isActive(AudioKeys.bitrate) && !flac.isActive(AudioKeys.rateControl))
            let mp3q = schema.resolve(layers: [[AudioKeys.target: "mp3", AudioKeys.rateControl: "quality", AudioKeys.quality: 60]])
            try expect(mp3q.isActive(AudioKeys.quality) && !mp3q.isActive(AudioKeys.bitrate))
            let opus = schema.resolve(layers: [[AudioKeys.target: "opus", AudioKeys.rateControl: "quality"]])
            try expect(!opus.isActive(AudioKeys.quality), "Opus has no quality scale: bit rate only")
        }
    }

    // MARK: DSP

    private static func registerDSP() {
        let t = SelfTestRegistry.shared
        t.register("audio.dsp", "loudness meter reads a -20 dBFS stereo sine as about -20 LUFS and finds its peak") {
            let rate = 48_000
            let s = AudTestKit.sine(seconds: 6, rate: rate, channels: 2, frequency: 997, amplitude: 0.1)     // -20 dBFS
            let meter = AudLoudnessMeter(rate: rate, channels: 2)
            meter.feed(s.ch)
            try expectClose(try unwrap(meter.integratedLUFS), -20.0, tolerance: 0.5, "BS.1770 reference: 997 Hz at -20 dBFS stereo is -20 LUFS")
            try expectClose(meter.peakDB, -20, tolerance: 0.1)
            let quiet = AudLoudnessMeter(rate: rate, channels: 2)
            quiet.feed(AudTestKit.sine(seconds: 6, rate: rate, channels: 2, amplitude: 0.00001).ch)
            try expect(quiet.integratedLUFS == nil, "below the absolute gate there is nothing to measure")
        }
        t.register("audio.dsp", "meter agrees with ffmpeg's ebur128 on a realistic signal") {
            try AudTestKit.needs(.ffmpeg)
            let fx = TestFixtures(label: "aud-lufs"); defer { fx.cleanup() }
            let sig = AudTestKit.chirp(seconds: 6, rate: 44_100, channels: 2, amplitude: 0.3)
            let wav = try AudTestKit.writeWAV(sig, to: fx.url("c.wav"))
            let reference = try unwrap(AudTestKit.loudness(wav))
            let meter = AudLoudnessMeter(rate: 44_100, channels: 2)
            meter.feed(try unwrap(AudTestKit.parseWAV(wav)).ch)
            try expectClose(try unwrap(meter.integratedLUFS), reference.lufs, tolerance: 0.3, "our meter vs ffmpeg")
        }
        t.register("audio.dsp", "gain stage: fades are exact ramps independent of chunking, gain is exact") {
            let stage = AudGainStage(gain: 1, fadeInFrames: 100, fadeOutFrames: 100, totalFrames: 1000)
            var whole: AudChunk = [[Float](repeating: 1, count: 1000)]
            stage.apply(&whole, start: 0)
            var pieces: AudChunk = [[]]
            for s in stride(from: 0, to: 1000, by: 77) {
                var c: AudChunk = [[Float](repeating: 1, count: min(77, 1000 - s))]
                stage.apply(&c, start: s); pieces[0] += c[0]
            }
            try expectEqual(whole[0], pieces[0], "chunk size must not change the result")
            try expectClose(Double(whole[0][0]), 0, tolerance: 1e-6); try expectClose(Double(whole[0][50]), 0.5, tolerance: 1e-6)
            try expectClose(Double(whole[0][500]), 1); try expectClose(Double(whole[0][999]), 0.01, tolerance: 1e-6)
            var g: AudChunk = [[0.25]]
            AudGainStage(gain: AudDB.linear(6.0206), fadeInFrames: 0, fadeOutFrames: 0, totalFrames: 0).apply(&g, start: 0)
            try expectClose(Double(g[0][0]), 0.5, tolerance: 1e-4)
        }
        t.register("audio.dsp", "channel mixing: mono duplicates, stereo averages, 5.1 folds down without clipping") {
            try expectEqual(AudMix.apply([[1, 0.5]], to: 2), [[1, 0.5], [1, 0.5]])
            try expectEqual(AudMix.apply([[1, 0], [0, 1]], to: 1), [[0.5, 0.5]])
            let six: AudChunk = (0..<6).map { _ in [Float](repeating: 1, count: 4) }
            let two = AudMix.apply(six, to: 2)
            try expectEqual(two.count, 2)
            try expect(two[0].allSatisfy { $0 <= 1.0001 }, "full-scale surround must not exceed full scale after the fold-down")
        }
        t.register("audio.dsp", "joiner: gap adds silence, crossfade overlaps by exactly the fade length") {
            func join(gap: Double, fade: Double) throws -> Int {
                var total = 0
                let j = AudJoiner(channels: 1, rate: 1000, gapSeconds: gap, crossfadeSeconds: fade) { total += $0.first?.count ?? 0 }
                for _ in 0..<3 {
                    try j.beginSource()
                    for _ in 0..<4 { try j.append([[Float](repeating: 0.5, count: 250)]) }     // 1 s per source, in four chunks
                    try j.endSource()
                }
                try j.finish()
                return total
            }
            try expectEqual(try join(gap: 0, fade: 0), 3000)
            try expectEqual(try join(gap: 0.5, fade: 0), 3000 + 2 * 500)
            try expectEqual(try join(gap: 0, fade: 0.2), 3000 - 2 * 200)
        }
        t.register("audio.dsp", "natural order sorts track2 before track10 and the join keeps the selection order on request") {
            let items = ["track10.mp3", "track2.mp3", "track1.mp3"].map { FileItem(url: URL(fileURLWithPath: "/m/\($0)"), isDirectory: false) }
            try expectEqual(AudJoin.ordered(items, natural: true).map(\.name), ["track1.mp3", "track2.mp3", "track10.mp3"])
            try expectEqual(AudJoin.ordered(items, natural: false).map(\.name), ["track10.mp3", "track2.mp3", "track1.mp3"])
            var mono = AudInfo(url: URL(fileURLWithPath: "/a")); mono.sampleRate = 44_100; mono.channels = 1
            var stereo = AudInfo(url: URL(fileURLWithPath: "/b")); stereo.sampleRate = 48_000; stereo.channels = 2
            try expectEqual(AudJoin.outputRate(choice: "auto", infos: [mono, stereo], target: .wav), 48_000, "best input, not the first file")
            try expectEqual(AudJoin.outputChannels(choice: "auto", infos: [mono, stereo]), 2)
            try expectEqual(AudJoin.outputChannels(choice: "auto", infos: [mono, mono]), 1)
            try expectEqual(AudJoin.outputRate(choice: "44100", infos: [mono, stereo], target: .wav), 44_100)
            try expectEqual(AudJoin.outputRate(choice: "auto", infos: [stereo], target: .opus), 48_000)
        }
    }
}
