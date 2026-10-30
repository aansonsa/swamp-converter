import Foundation

// Real runs: subtitles (soft, from a file, burned in), chapters, tags and metadata, the range (spec/handbrake.md 2.7 - 2.9).

enum VideoRealTextTests {
    typealias R = VideoRealTests
    static let fast: OptionValues = [VideoKeys.venc: "software", VideoKeys.speed: "ultrafast", VideoKeys.cq: 18, VideoKeys.audioMode: "none"]
    static let lossless: OptionValues = [VideoKeys.rateControl: "lossless", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast", VideoKeys.container: "mkv", VideoKeys.audioMode: "none"]

    static func srt(_ fx: TestFixtures, _ name: String = "t.srt", encoding: String.Encoding = .utf8) throws -> URL {
        try fx.srt(name, cues: [TestFixtures.Cue(start: 1.0, end: 2.0, text: "HELLO WORLD"), TestFixtures.Cue(start: 2.5, end: 3.5, text: "Привет, мир")], encoding: encoding)
    }

    /// The cues of the first subtitle stream of `url`, read back by ffmpeg into SRT and parsed here.
    static func readCues(_ url: URL, stream: Int = 0) throws -> [(Double, Double, String)] {
        guard let ff = VT.ffmpeg else { throw TestSkip(reason: "ffmpeg missing") }
        let out = url.deletingLastPathComponent().appendingPathComponent(".cues-\(Util.hex8()).srt")
        defer { try? FileManager.default.removeItem(at: out) }
        VT.run(ff, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", url.path, "-map", "0:s:\(stream)", "-f", "srt", out.path])
        guard let text = try? String(contentsOf: out, encoding: .utf8) else { return [] }
        func t(_ s: String) -> Double { let p = s.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }; return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0 }
        var result: [(Double, Double, String)] = []
        for block in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let halves = lines[i].components(separatedBy: " --> ")
            result.append((t(halves[0]), t(halves[1]), lines[(i + 1)...].joined(separator: "\n")))
        }
        return result
    }

    static func register() {
        R.reg("subtitles: Keep puts text tracks into every container in its own subtitle codec; None removes them; a file is added as a track", oracles: ["s.mode.streams", "s.ext.track"], timeout: 240) {
            let base = try VT.clip(VTShared.fx, "sbase.mp4", seconds: 4, audio: false)
            let subs = try VTShared.get("srt") { try srt($0) }
            let mkv = try VTShared.get("withsubs") { try VT.withSubtitles($0, from: base, srt: subs) }
            func codecs(_ op: String, _ set: OptionValues) async throws -> [String] { try VT.probe(try await VT.go(op, mkv, fast.merged(over: [:]).overlaying(set)).url).streams("subtitle").map { $0["codec_name"] as? String ?? "" } }
            let inMP4 = try await codecs("video.to.mp4", [:]), inMKV = try await codecs("video.to.mkv", [:]), inWebM = try await codecs("video.to.webm", [:])
            let none = try await codecs("video.to.mp4", [VideoKeys.subMode: "none"])
            try expectEqual(inMP4, ["mov_text"]); try expectEqual(inMKV, ["subrip"]); try expectEqual(inWebM, ["webvtt"]); try expectEqual(none, [])
            let plain = try VT.clip(VTShared.fx, "nosubs.mp4", seconds: 4, audio: false)
            let ext = try await VT.go("video.to.mp4", plain, fast.overlaying([VideoKeys.subMode: "external", VideoKeys.extFile: .string(subs.path)])).url
            try expectEqual(try VT.probe(ext).streams("subtitle").count, 1)
            let cues = try readCues(ext)
            try expectEqual(cues.count, 2); try expectEqual(cues[1].2, "Привет, мир"); try expectClose(cues[0].0, 1.0, tolerance: 0.05)
        }

        R.reg("subtitle rules: languages, forced only and the default track", oracles: ["s.langs.streams", "s.forced.streams", "s.default.disposition"], timeout: 240) {
            let base = try VT.clip(VTShared.fx, "sbase2.mp4", seconds: 4, audio: false)
            let a = try srt(VTShared.fx, "a.srt"), b = try srt(VTShared.fx, "b.srt"), c = try srt(VTShared.fx, "c.srt")
            let multi = try VT.make(VTShared.fx, "msubs.mkv", ["-i", base.path, "-i", a.path, "-i", b.path, "-i", c.path, "-map", "0:v", "-map", "1", "-map", "2", "-map", "3", "-c", "copy", "-c:s", "srt",
                                                              "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=rus", "-metadata:s:s:2", "language=rus", "-disposition:s:2", "forced"])
            func streams(_ set: OptionValues) async throws -> [[String: Any]] { try VT.probe(try await VT.go("video.to.mkv", multi, fast.overlaying(set)).url).streams("subtitle") }
            func lang(_ s: [String: Any]) -> String { (s["tags"] as? [String: Any])?["language"] as? String ?? "" }
            var s = try await streams([:]); try expectEqual(s.count, 3)
            s = try await streams([VideoKeys.subLangs: "rus"]); try expectEqual(s.map(lang), ["rus", "rus"])
            s = try await streams([VideoKeys.subForcedOnly: true]); try expectEqual(s.count, 1); try expectEqual((s[0]["disposition"] as? [String: Any])?["forced"] as? Int, 1)
            s = try await streams([VideoKeys.subDefault: "first"]); try expectEqual((s[0]["disposition"] as? [String: Any])?["default"] as? Int, 1)
            s = try await streams([VideoKeys.subDefault: "forced"]); try expectEqual(s.map { ($0["disposition"] as? [String: Any])?["default"] as? Int ?? 0 }, [0, 0, 1])
        }

        R.reg("subtitle file: the offset shifts the times, the text encoding is detected or chosen, and the language tag is written", oracles: ["s.ext.offset", "s.ext.charset", "s.ext.lang"]) {
            let plain = try VT.clip(VTShared.fx, "nosubs2.mp4", seconds: 4, audio: false)
            let cp = try srt(VTShared.fx, "cp1251.srt", encoding: .windowsCP1251)
            let auto = try await VT.go("video.to.mp4", plain, fast.overlaying([VideoKeys.subMode: "external", VideoKeys.extFile: .string(cp.path), VideoKeys.extOffset: 1000, VideoKeys.extLang: "rus"])).url
            let cues = try readCues(auto)
            try expectEqual(cues.map(\.2), ["HELLO WORLD", "Привет, мир"], "Windows-1251 detected")
            try expectClose(cues[0].0, 2.0, tolerance: 0.06, "shifted by +1000 ms")
            let tags = try VT.probe(auto).streams("subtitle").first?["tags"] as? [String: Any]
            try expectEqual(tags?["language"] as? String, "rus")
            let wrong = try await VT.go("video.to.mp4", plain, fast.overlaying([VideoKeys.subMode: "external", VideoKeys.extFile: .string(cp.path), VideoKeys.extCharset: "koi8-r"])).url
            try expect(try readCues(wrong).map(\.2).last != "Привет, мир", "a wrong charset shows other letters")
            let right = try await VT.go("video.to.mp4", plain, fast.overlaying([VideoKeys.subMode: "external", VideoKeys.extFile: .string(cp.path), VideoKeys.extCharset: "windows-1251"])).url
            try expectEqual(try readCues(right).map(\.2).last, "Привет, мир")
        }

        R.reg("burned-in subtitles appear only inside the cue window, where the position, size and colour say, and nothing else changes", oracles: ["s.burn.window", "s.burn.pos", "s.burn.size", "s.burn.color"], timeout: 300) {
            let src = try VTShared.get("burnsrc") { try VT.clip($0, "burn-src.mp4", seconds: 4, size: "640x360", audio: false, noise: 0) }
            let subs = try VTShared.get("srt") { try srt($0) }
            let base = try await VT.go("video.to.mp4", src, lossless).url
            func burn(_ set: OptionValues = [:]) async throws -> URL {
                try await VT.go("video.to.mp4", src, lossless.overlaying([VideoKeys.subMode: "burn", VideoKeys.extFile: .string(subs.path)]).overlaying(set)).url
            }
            let b = try await burn()
            let inside = try unwrap(try VT.diffBox(b, base, at: 1.5), "the cue shows at 1.5 s")
            try expect(try VT.diffBox(b, base, at: 0.5) == nil, "nothing before the cue")
            try expect(try VT.diffBox(b, base, at: 2.2) == nil, "nothing between the cues")
            let second = try unwrap(try VT.diffBox(b, base, at: 3.0), "the second cue shows at 3.0 s")
            try expect(second.x0 > 0, "second cue box \(second)")
            try expect(inside.y0 > inside.h * 6 / 10 && abs((inside.x0 + inside.x1) / 2 - inside.w / 2) < inside.w / 8, "bottom centre: \(inside)")
            let top = try unwrap(try VT.diffBox(try await burn([VideoKeys.burnPos: "top"]), base, at: 1.5)); try expect(top.y1 < top.h * 4 / 10, "top: \(top)")
            let mid = try unwrap(try VT.diffBox(try await burn([VideoKeys.burnPos: "middle"]), base, at: 1.5)); try expect(abs((mid.y0 + mid.y1) / 2 - mid.h / 2) < mid.h / 8, "middle: \(mid)")
            let small = try unwrap(try VT.diffBox(try await burn([VideoKeys.burnSize: 3.0]), base, at: 1.5)), big = try unwrap(try VT.diffBox(try await burn([VideoKeys.burnSize: 9.0]), base, at: 1.5))
            try expect((big.x1 - big.x0) > (small.x1 - small.x0) * 2, "size 9 is wider than 3: \(big.x1 - big.x0) vs \(small.x1 - small.x0)")
            let red = try await burn([VideoKeys.burnColor: "#FF0000", VideoKeys.burnOutline: 0.0, VideoKeys.burnShadow: 0.0])
            let f = try VT.frame(red, at: 1.5), baseFrame = try VT.frame(base, at: 1.5), r = try unwrap(try VT.diffBox(red, base, at: 1.5))
            var redPixels = 0, other = 0
            for y in r.y0...r.y1 { for x in r.x0...r.x1 { let p = f.pixel(x, y), q = baseFrame.pixel(x, y); if abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) > 90 { if p.0 > 200 && p.1 < 80 && p.2 < 80 { redPixels += 1 } else { other += 1 } } } }
            try expect(redPixels > other, "red text: \(redPixels) red vs \(other) other changed pixels")
        }

        R.reg("burned-in text styles: outline, shadow, box, font and margin each change the picture", oracles: ["s.burn.outline", "s.burn.shadow", "s.burn.box", "s.burn.font"], timeout: 300) {
            let src = try VTShared.get("burnsrc") { try VT.clip($0, "burn-src.mp4", seconds: 4, size: "640x360", audio: false, noise: 0) }
            let subs = try VTShared.get("srt") { try srt($0) }
            func burn(_ set: OptionValues) async throws -> URL {
                try await VT.go("video.to.mp4", src, lossless.overlaying([VideoKeys.subMode: "burn", VideoKeys.extFile: .string(subs.path)]).overlaying(set)).url
            }
            let ref = try await burn([:])
            for (name, set) in [("outline", [VideoKeys.burnOutline: 6.0] as OptionValues), ("shadow", [VideoKeys.burnShadow: 4.0]), ("box", [VideoKeys.burnBox: true, VideoKeys.burnBoxOpacity: 80]),
                                ("font", [VideoKeys.burnFont: "Menlo"]), ("margin", [VideoKeys.burnMargin: 15.0])] {
                let other = try await burn(set)
                let d = try VT.frameDifference(ref, other, at: 1.5)
                try expect(d > 0.05, "\(name) changes the picture (difference \(d))")
                try expect(try VT.diffBox(other, ref, at: 0.5) == nil, "\(name): nothing outside the window")
            }
            let box = try unwrap(try VT.diffBox(try await burn([VideoKeys.burnBox: true, VideoKeys.burnBoxOpacity: 100]), try await VT.go("video.to.mp4", src, lossless).url, at: 1.5))
            let plain = try unwrap(try VT.diffBox(ref, try await VT.go("video.to.mp4", src, lossless).url, at: 1.5))
            try expect((box.x1 - box.x0) * (box.y1 - box.y0) > (plain.x1 - plain.x0) * (plain.y1 - plain.y0), "the box is larger than the text alone")
        }

        R.reg("burn-in takes the text from an embedded track, and the track choice matters", oracles: []) {
            let src = try VTShared.get("burnsrc") { try VT.clip($0, "burn-src.mp4", seconds: 4, size: "640x360", audio: false, noise: 0) }
            let a = try srt(VTShared.fx, "ba.srt")
            let b = try VTShared.fx.srt("bb.srt", cues: [TestFixtures.Cue(start: 1.0, end: 2.0, text: "A MUCH LONGER SECOND TRACK LINE"), TestFixtures.Cue(start: 2.5, end: 3.5, text: "x")])
            let two = try VT.make(VTShared.fx, "two.mkv", ["-i", src.path, "-i", a.path, "-i", b.path, "-map", "0:v", "-map", "1", "-map", "2", "-c", "copy", "-c:s", "srt"])
            let base = try await VT.go("video.to.mp4", two, lossless).url
            let first = try unwrap(try VT.diffBox(try await VT.go("video.to.mp4", two, lossless.overlaying([VideoKeys.subMode: "burn"])).url, base, at: 1.5), "the first text track is burned in")
            let second = try unwrap(try VT.diffBox(try await VT.go("video.to.mp4", two, lossless.overlaying([VideoKeys.subMode: "burn", VideoKeys.burnTrack: "1"])).url, base, at: 1.5))
            try expect((second.x1 - second.x0) > (first.x1 - first.x0) + 40, "the second track has the longer line: \(second.x1 - second.x0) vs \(first.x1 - first.x0)")
        }

        R.reg("chapters: keep, remove, every N minutes and a custom list (Cyrillic titles survive)", oracles: ["ch.list"], timeout: 240) {
            let base = try VT.clip(VTShared.fx, "cbase.mp4", seconds: 2)
            let withCh = try VT.withChapters(VTShared.fx, from: base)
            func chapters(_ set: OptionValues, _ src: URL = withCh) async throws -> [(Double, String)] {
                let p = try VT.probe(try await VT.go("video.to.mp4", src, fast.overlaying(set)).url)
                return p.chapters.map { (Double($0["start_time"] as? String ?? "") ?? -1, ($0["tags"] as? [String: Any])?["title"] as? String ?? "") }
            }
            var c = try await chapters([:]); try expectEqual(c.map(\.1), ["Intro", "Глава 2"]); try expectClose(c[1].0, 1.0, tolerance: 0.05)
            c = try await chapters([VideoKeys.chapterMode: "none"]); try expectEqual(c.count, 0)
            let rows: [[String: OptionValue]] = [["start": 0.0, "title": "Один"], ["start": 1.0, "title": "Два"]]
            c = try await chapters([VideoKeys.chapterMode: "custom", VideoKeys.chapterRows: .rows(rows)]); try expectEqual(c.map(\.1), ["Один", "Два"])
            let long = try VTShared.get("long130") { try VT.clip($0, "long130.mp4", seconds: 130, size: "64x48", fps: 5) }
            c = try await chapters([VideoKeys.chapterMode: "auto", VideoKeys.chapterInterval: 1, VideoKeys.vcodec: "copy", VideoKeys.audioCodec: "copy", VideoKeys.audioMode: "first"], long)
            try expectEqual(c.count, 3, "0, 60 and 120 s"); try expectClose(c[1].0, 60, tolerance: 0.1)
        }

        R.reg("metadata: keep, remove everything, remove the location only, write your own tags, add a cover, drop the creation date", oracles: ["md.strip", "md.noGPS", "md.tags", "md.cover", "md.dates"], timeout: 240) {
            let src = try VT.clip(VTShared.fx, "tags.mp4", seconds: 2, extra: ["-metadata", "title=Original title", "-metadata", "artist=Some Artist", "-metadata", "location=+37.7749-122.4194/",
                                                                       "-metadata", "creation_time=2020-01-02T03:04:05Z"])
            func tags(_ set: OptionValues) async throws -> [String: String] { try VT.probe(try await VT.go("video.to.mp4", src, fast.overlaying(set)).url).tags }
            var t = try await tags([:]); try expectEqual(t["title"], "Original title"); try expect(t["location"] != nil, "location kept: \(t)")
            t = try await tags([VideoKeys.metadataMode: "strip"]); try expect(t["title"] == nil && t["artist"] == nil && t["location"] == nil && t["creation_time"] == nil, "everything removed: \(t)")
            t = try await tags([VideoKeys.metadataNoGPS: true]); try expect(t["location"] == nil && t["title"] == "Original title" && t["artist"] == "Some Artist", "only the location removed: \(t)")
            t = try await tags([VideoKeys.metadataMode: "custom", VideoKeys.mdTitle: "Новое название", VideoKeys.mdComment: "A comment", VideoKeys.mdArtist: "Автор"])
            try expectEqual(t["title"], "Новое название"); try expectEqual(t["comment"], "A comment"); try expectEqual(t["artist"], "Автор")
            let keptDate = try await tags([:]); try expect((keptDate["creation_time"] ?? "").hasPrefix("2020-01-02"), "creation date kept: \(keptDate["creation_time"] ?? "-")")
            let newDate = try await tags([VideoKeys.mdKeepDates: false])
            let year = Calendar.current.component(.year, from: Date())
            try expect((newDate["creation_time"] ?? "").hasPrefix("\(year)") || (newDate["creation_time"] ?? "").hasPrefix("\(year - 1)"), "creation date is new: \(newDate["creation_time"] ?? "-")")
            let cover = try VT.make(VTShared.fx, "cover.jpg", ["-f", "lavfi", "-i", "testsrc2=size=200x200:rate=1:duration=1", "-frames:v", "1"])
            let p = try VT.probe(try await VT.go("video.to.mp4", src, fast.overlaying([VideoKeys.mdCover: .string(cover.path)])).url)
            let pics = p.streams("video").filter { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }
            try expectEqual(pics.count, 1, "an attached picture stream"); try expectEqual(p.streams("video").count, 2)
        }

        R.reg("range: a frame-accurate cut has the length asked for; a fast cut copies and starts at a key frame, and says where", oracles: ["t.duration", "t.copy"], timeout: 240) {
            let src = try VT.clip(VTShared.fx, "gop.mp4", seconds: 4, codec: ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-g", "12", "-keyint_min", "12", "-sc_threshold", "0"])
            let both = try VT.probe(try await VT.go("video.to.mp4", src, fast.overlaying([VideoKeys.trimStart: 0.5, VideoKeys.trimEnd: 1.5])).url)
            try expectClose(both.duration, 1.0, tolerance: 0.07); try expect(both.frames >= 23 && both.frames <= 25, "frames \(both.frames)")
            let tail = try VT.probe(try await VT.go("video.to.mp4", src, fast.overlaying([VideoKeys.trimStart: 1.0])).url); try expectClose(tail.duration, 3.0, tolerance: 0.1)
            let head = try VT.probe(try await VT.go("video.to.mp4", src, fast.overlaying([VideoKeys.trimEnd: 1.0])).url); try expectClose(head.duration, 1.0, tolerance: 0.07)
            let r = try await VT.go("video.to.mp4", src, [VideoKeys.vcodec: "h264", VideoKeys.trimStart: 0.75, VideoKeys.trimEnd: 2.5, VideoKeys.trimAccurate: false])
            let copy = try VT.probe(r.url)
            try expectEqual(copy.vcodec, "h264")
            try expect(copy.duration >= 1.75 && copy.duration <= 2.4, "snapped to the key frame at 0.5: \(copy.duration) s")
            try expect(r.result.warnings.contains { $0.contains("0:00.500") || $0.contains("0.5") }, "the warning names the real start: \(r.result.warnings)")
            try expect(VT.containsText(r.url, "x264") == VT.containsText(src, "x264"), "streams were copied, not re-encoded")
        }
    }
}
