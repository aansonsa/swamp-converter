import Foundation

// SubtitleKit golden files and the subs.convert options, proven on real runs.

@MainActor
enum SubsRun {
    static func operation(_ id: String) throws -> Operation { try unwrap(SubsCatalog.operations().first { $0.meta.id == id }, "operation \(id)") }

    @discardableResult
    static func run(_ id: String, _ src: URL, _ options: OptionValues = OptionValues(), fx: TestFixtures, mode: RunMode = .studio) async throws -> [URL] {
        let out = fx.url("out-\(Util.hex8())")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path
        let op = try operation(id)
        let items = [FileItem(url: src)]
        let ctx = OperationContext.testing(op, items: items, extra: options, mode: mode, rules: rules)
        let result = try await op.execute(items: items, ctx: ctx)
        try expect(TestFile.partials(in: out).isEmpty, "no .part leftovers")
        return result.outputs
    }

    nonisolated static func cues(_ url: URL, encoding: DataEncoding? = nil) throws -> [SubtitleCue] {
        let (t, _) = try SubtitleKit.readText(url, encoding: encoding)
        return try SubtitleKit.parse(t)
    }
}

enum SubsFixtures {
    /// Times in whole milliseconds, Cyrillic / Latvian / Czech text, two-line cues, tags, an entity-looking text.
    static let cues: [SubtitleCue] = [
        SubtitleCue(start: 1.0, end: 2.5, text: "Привет, мир!"),
        SubtitleCue(start: 3.001, end: 5.999, text: "<i>Rīga</i> — Žluťák\nвторая строка"),
        SubtitleCue(start: 61.5, end: 63.25, text: "Tom & Jerry <3 a < b"),
        SubtitleCue(start: 3599.999, end: 3600.0, text: "[музыка]"),
        SubtitleCue(start: 3725.05, end: 3727.5, text: "ИВАН: Конец.\n♪ la la ♪")
    ]

    @discardableResult
    static func write(_ fx: TestFixtures, name: String, cues: [SubtitleCue] = SubsFixtures.cues, as format: SubtitleFormat = .srt, encoding: DataEncoding = .utf8, bom: Bool = false, crlf: Bool = false) throws -> URL {
        var text = SubtitleKit.serialize(cues, as: format)
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        let u = fx.url(name)
        try TextEncodingKit.encode(text, as: encoding, bom: bom).data.write(to: u)
        return u
    }
}

enum DataTestsSubs {
    static func register() {
        registerGolden()
        registerRoundTrips()
        registerOptions()
    }

    // MARK: Golden files

    private static func registerGolden() {
        dataTest("data.subs", "SRT golden file: BOM, CRLF, cue numbers, missing blank lines, multi-line text, 2-digit fractions, hours past 99") {
            let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\nПривет\r\nмир\r\n\r\n2\r\n00:00:03,5 --> 00:00:04,25\r\nsecond\r\n3\r\n00:00:05,00 --> 00:00:06,000\r\nthird (no blank line before the number)\r\n\r\n100:00:00,001 --> 100:00:01,000\r\nlate\r\n"
            let cues = try SubtitleKit.parse(srt)
            try expectEqual(cues.count, 4)
            try expectEqual(cues[0], SubtitleCue(start: 1.0, end: 2.5, text: "Привет\nмир", identifier: "1"))
            try expectEqual(cues[1].start, 3.5); try expectEqual(cues[1].end, 4.25); try expectEqual(cues[1].text, "second")
            try expectEqual(cues[2].text, "third (no blank line before the number)"); try expectEqual(cues[2].identifier, "3")
            try expectEqual(cues[3].start, 360_000.001, "hours beyond 99 parse exactly")
            try expectEqual(SubtitleKit.serialize(cues, as: .srt).contains("100:00:00,001 --> 100:00:01,000"), true)
            _ = try await expectThrows("no cues") { _ = try SubtitleKit.parse("just some text\n\nwithout timing\n") }
        }

        dataTest("data.subs", "WebVTT golden file: header, NOTE / STYLE / REGION blocks dropped, identifiers, cue settings, short timestamps, entities decoded") {
            let vtt = "WEBVTT - title\nKind: captions\n\nSTYLE\n::cue { color: red }\n\nNOTE this is a comment\nover two lines\n\nREGION\nid:r1\n\nintro\n01:15.500 --> 01:17.000 align:start position:10%\n<v Ivan>Tom &amp; Jerry &lt;3</v>\n\n00:01:20.250 --> 00:01:22.000\nline one\nline two\n\n"
            let cues = try SubtitleKit.parse(vtt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 75.5); try expectEqual(cues[0].end, 77.0); try expectEqual(cues[0].identifier, "intro")
            try expectEqual(cues[0].text, "<v Ivan>Tom & Jerry <3</v>", "entities are decoded, voice tags are kept until the tag option removes them")
            try expectEqual(cues[1].text, "line one\nline two")
            let out = SubtitleKit.serialize(cues, as: .vtt)
            try expect(out.hasPrefix("WEBVTT\n\n"), "header"); try expect(out.contains("Tom &amp; Jerry &lt;3"), "the writer escapes & and a stray <: \(out)")
            try expect(out.contains("<v Ivan>"), "real tags stay tags")
            try expectEqual(try SubtitleKit.parse(out).map(\.text), cues.map(\.text), "and it parses back")
        }

        dataTest("data.subs", "ASS / SSA golden file: Dialogue columns, commas in text, \\N, overrides become tags, comments skipped, cues sorted") {
            let ass = "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: Default,Arial\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:05.00,0:00:06.50,Default,,0,0,0,,{\\an8}{\\i1}Second{\\i0}, with comma\\Nline two\nComment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,not a cue\nDialogue: 0,0:00:01.00,0:00:02.25,Default,,0,0,0,,{\\b1}First{\\b0} {\\pos(10,10)}one\n"
            let cues = try SubtitleKit.parse(ass)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].text, "<b>First</b> one"); try expectEqual(cues[0].start, 1.0); try expectEqual(cues[0].end, 2.25)
            try expectEqual(cues[1].text, "<i>Second</i>, with comma\nline two"); try expectEqual(cues[1].start, 5.0)
            try expectEqual(SubtitleKit.sniff(ass), .ass)
            let ssa = "[Script Info]\nScriptType: v4.00\n[V4 Styles]\nFormat: Name\n[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Old school\n"
            try expectEqual(SubtitleKit.sniff(ssa), .ssa); try expectEqual(try SubtitleKit.parse(ssa).first?.text, "Old school")
        }

        dataTest("data.subs", "SBV (YouTube) golden file and format sniffing") {
            let sbv = "0:00:01.000,0:00:02.500\nПривет\n\n0:01:00.000,0:01:02.000\nline one\nline two\n"
            let cues = try SubtitleKit.parse(sbv)
            try expectEqual(cues.map(\.text), ["Привет", "line one\nline two"]); try expectEqual(cues[1].start, 60.0)
            try expectEqual(SubtitleKit.sniff(sbv), .sbv); try expectEqual(SubtitleKit.sniff("WEBVTT\n\n"), .vtt); try expectEqual(SubtitleKit.sniff("1\n00:00:01,000 --> 00:00:02,000\nx\n"), .srt)
            try expectEqual(SubtitleKit.serialize(cues, as: .sbv), sbv + "\n")
            // A file whose extension lies is still read by its content.
            let fx = TestFixtures(); defer { fx.cleanup() }
            let u = fx.url("wrong.srt"); try Data(sbv.utf8).write(to: u)
            try expectEqual(try SubsRun.cues(u).count, 2)
        }

        dataTest("data.subs", "tag, sound-description, timing and merge tools on cue arrays") {
            let tags = SubtitleTools.removeTags(in: "<i>a</i> <font color=\"red\">b</font> {\\an8}c <v Ivan>d</v> <00:01.000>e <c.yellow>f</c> x <3 y a < b > c")
            try expectEqual(tags, "a b c d e f x <3 y a < b > c", "tags go, ordinary < > stay")
            let cues = [SubtitleCue(start: 1, end: 2, text: "[music]"), SubtitleCue(start: 3, end: 4, text: "JOHN: Hello (laughs) there"), SubtitleCue(start: 5, end: 6, text: "♪ song ♪\nreal line"),
                        SubtitleCue(start: 7, end: 8, text: "- [door] Hi\n- (sighs)"), SubtitleCue(start: 9, end: 10, text: "Plain <i>text</i>")]
            let sdh = SubtitleTools.stripped(cues, removeTags: false, removeHearingImpaired: true)
            try expectEqual(sdh.map(\.text), ["Hello there", "real line", "- Hi", "Plain <i>text</i>"])
            let both = SubtitleTools.stripped(cues, removeTags: true, removeHearingImpaired: true)
            try expectEqual(both.last?.text, "Plain text")
            let shifted = SubtitleTools.shifted([SubtitleCue(start: 0.5, end: 1.5, text: "a"), SubtitleCue(start: 2, end: 3, text: "b")], by: -1)
            try expectEqual(shifted.count, 2); try expectEqual(shifted[0].start, 0.0); try expectEqual(shifted[0].end, 0.5, "starts before zero are clipped"); try expectEqual(shifted[1].start, 1.0)
            try expectEqual(SubtitleTools.shifted([SubtitleCue(start: 0.5, end: 1.0, text: "gone")], by: -2).count, 0, "cues that end before zero vanish")
            let re = SubtitleTools.retimed([SubtitleCue(start: 100, end: 110, text: "x")], fromFPS: 23.976, toFPS: 25)
            try expectClose(re[0].start, 95.904, tolerance: 0.001); try expectClose(re[0].end, 105.494, tolerance: 0.001)
            let merged = SubtitleTools.merged([SubtitleCue(start: 1, end: 1.3, text: "a"), SubtitleCue(start: 1.4, end: 3, text: "b"), SubtitleCue(start: 6, end: 6.2, text: "alone"), SubtitleCue(start: 8, end: 9, text: "c")])
            try expectEqual(merged.map(\.text), ["a\nb", "alone", "c"]); try expectEqual(merged[0].end, 3.0)
            let overlap = SubtitleTools.overlapFixed([SubtitleCue(start: 5, end: 9, text: "late"), SubtitleCue(start: 1, end: 6, text: "early")])
            try expectEqual(overlap.map(\.text), ["early", "late"]); try expectEqual(overlap[0].end, 5.0)
        }

        dataTest("data.subs", "encodings of subtitle files: UTF-8, BOM, UTF-16, Windows-1251 / 1257 / 1250 are detected; KOI8-R and CP866 by override", proves: ["subs.enc.in.decode"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let ru = [SubtitleCue(start: 1, end: 2, text: "Привет, как дела? Всё хорошо, спасибо."), SubtitleCue(start: 3, end: 4, text: "Съешь ещё этих мягких французских булок.")]
            let lv = [SubtitleCue(start: 1, end: 2, text: "Šodien ir jauka diena, ķirši un ūdens."), SubtitleCue(start: 3, end: 4, text: "Rīgas pērle — ģimene, šņukst, ļoti žēl.")]
            let cz = [SubtitleCue(start: 1, end: 2, text: "Příliš žluťoučký kůň úpěl ďábelské ódy."), SubtitleCue(start: 3, end: 4, text: "Žluťák se řítí lesem, kde šeptá stín.")]
            for (label, cues, enc, bom) in [("utf8", ru, DataEncoding.utf8, false), ("utf8bom", ru, .utf8, true), ("utf16le", ru, .utf16le, true), ("utf16be", lv, .utf16be, true), ("1251", ru, .windows1251, false),
                                            ("1257", lv, .windows1257, false), ("1250", cz, .windows1250, false)] as [(String, [SubtitleCue], DataEncoding, Bool)] {
                let u = try SubsFixtures.write(fx, name: "\(label).srt", cues: cues, encoding: enc, bom: bom, crlf: true)
                let (text, name) = try SubtitleKit.readText(u)
                try expectEqual(try SubtitleKit.parse(text).map(\.text), cues.map(\.text), "\(label) read as \(name)")
            }
            for enc in [DataEncoding.koi8r, .cp866] {
                let u = try SubsFixtures.write(fx, name: "\(enc.rawValue).srt", cues: ru, encoding: enc)
                try expectEqual(try SubsRun.cues(u, encoding: enc).map(\.text), ru.map(\.text), "override \(enc.displayName)")
            }
            // The legacy String.Encoding signature keeps working.
            let u = try SubsFixtures.write(fx, name: "legacy.srt", cues: ru, encoding: .windows1251)
            try expectEqual(try SubtitleKit.parse(try SubtitleKit.readText(u, encodingOverride: .windowsCP1251).text).map(\.text), ru.map(\.text))
            // The operation converts a 1251 file to readable UTF-8 on its own.
            let out = try await SubsRun.run("subs.to.vtt", u, fx: fx)[0]
            let utf8Text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
            try expect(utf8Text.contains("Привет, как дела?"), "UTF-8 result: \(utf8Text)")
        }
    }

    // MARK: Round trips and oracles

    private static func registerRoundTrips() {
        dataTest("data.subs", "every pair of SRT, VTT, SBV, ASS and SSA keeps the cue list (ms exact; ASS has centiseconds only)", proves: ["subs.format.sniff"]) {
            let ms = SubsFixtures.cues.filter { !$0.text.contains("\n♪") }
            let texts = ms.map { $0.text }
            for from in [SubtitleFormat.srt, .vtt, .sbv] {
                let a = SubtitleKit.serialize(ms, as: from)
                let parsed = try SubtitleKit.parse(a)
                try expectEqual(parsed.map(\.start), ms.map(\.start), "\(from) starts"); try expectEqual(parsed.map(\.end), ms.map(\.end), "\(from) ends"); try expectEqual(parsed.map(\.text), texts, "\(from) text")
                for to in [SubtitleFormat.srt, .vtt, .sbv] {
                    let b = try SubtitleKit.parse(SubtitleKit.serialize(parsed, as: to))
                    try expectEqual(b.map(\.start), ms.map(\.start), "\(from)->\(to) starts"); try expectEqual(b.map(\.text), texts, "\(from)->\(to) text")
                }
            }
            // ASS / SSA: times round to centiseconds, text and order survive, italics survive as tags.
            let cs = [SubtitleCue(start: 1.0, end: 2.5, text: "Привет, <i>мир</i>"), SubtitleCue(start: 3.01, end: 5.99, text: "two\nlines, with commas"), SubtitleCue(start: 61.5, end: 63.25, text: "<b>bold</b>")]
            for f in [SubtitleFormat.ass, .ssa] {
                let parsed = try SubtitleKit.parse(SubtitleKit.serialize(cs, as: f))
                try expectEqual(parsed.map(\.text), cs.map(\.text), "\(f)"); try expectEqual(parsed.map(\.start), cs.map(\.start)); try expectEqual(parsed.map(\.end), cs.map(\.end))
                try expectEqual(SubtitleKit.sniff(SubtitleKit.serialize(cs, as: f)), f)
            }
            // The plain text writer: tags removed, joined lines, no empty or doubled lines.
            let txt = SubtitleKit.serialize([SubtitleCue(start: 1, end: 2, text: "<i>Hi</i>\nthere"), SubtitleCue(start: 2, end: 3, text: "Hi there"), SubtitleCue(start: 3, end: 4, text: "<i></i>"), SubtitleCue(start: 4, end: 5, text: "bye")], as: .txt)
            try expectEqual(txt, "Hi there\nbye\n")
            let para = SubtitleKit.plainText([SubtitleCue(start: 1, end: 2, text: "a"), SubtitleCue(start: 2.5, end: 3, text: "b"), SubtitleCue(start: 9, end: 10, text: "c")], paragraphs: true)
            try expectEqual(para, "a b\n\nc\n")
        }

        dataTest("data.subs", "ffmpeg's own subtitle parsers read what we write (independent oracle for SRT, WebVTT and ASS)", requires: ["tool.ffmpeg"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let ffmpeg = try ToolLocator.shared.require(.ffmpeg)
            let cues = [SubtitleCue(start: 1.0, end: 2.5, text: "Привет, мир"), SubtitleCue(start: 3.25, end: 5.75, text: "Rīga Žluťák\nsecond line"), SubtitleCue(start: 3700.5, end: 3701.0, text: "late")]
            for f in [SubtitleFormat.srt, .vtt, .ass] {
                let u = try SubsFixtures.write(fx, name: "o.\(f.rawValue)", cues: cues, as: f)
                let back = fx.url("ffmpeg-\(f.rawValue).srt")
                let r = DataTestKit.run(ffmpeg.path, ["-v", "error", "-y", "-i", u.path, back.path])
                try expectEqual(r.status, 0, "ffmpeg reads the \(f) file: \(r.output)")
                let parsed = try SubsRun.cues(back)
                let seen = f == .ass ? parsed.map { SubtitleTools.removeTags(in: $0.text) } : parsed.map(\.text)     // ffmpeg wraps ASS lines in a <font size> tag for the style
                try expectEqual(seen, cues.map(\.text), "\(f) text as ffmpeg sees it")
                try expectEqual(parsed.map(\.start), cues.map(\.start), "\(f) starts"); try expectEqual(parsed.map(\.end), cues.map(\.end), "\(f) ends")
            }
        }
    }

    // MARK: Options

    private static func registerOptions() {
        dataTest("data.subs", "output format, encoding, BOM and line endings are visible in the bytes", proves: ["subs.format.sniff", "subs.enc.out.bytes", "subs.bom.bytes", "subs.eol.bytes"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let ru = [SubtitleCue(start: 1, end: 2, text: "Привет, мир"), SubtitleCue(start: 3, end: 4, text: "Съешь ещё")]
            let src = try SubsFixtures.write(fx, name: "s.srt", cues: ru)
            func bytes(_ op: String, _ o: OptionValues) async throws -> Data { try Data(contentsOf: try await SubsRun.run(op, src, o, fx: fx)[0]) }
            let vtt = try await bytes("subs.to.vtt", [:])
            try expect(String(decoding: vtt, as: UTF8.self).hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nПривет, мир"), "WebVTT")
            let srt = try await bytes("subs.to.srt", [:])
            try expect(String(decoding: srt, as: UTF8.self).hasPrefix("1\r\n00:00:01,000 --> 00:00:02,000\r\nПривет, мир\r\n"), "SRT uses CRLF by default: \(String(decoding: srt, as: UTF8.self).debugDescription)")
            let txt = try await bytes("subs.to.txt", [:])
            try expectEqual(String(decoding: txt, as: UTF8.self), "Привет, мир\nСъешь ещё\n")
            let crlfVTT = try await bytes("subs.to.vtt", [SubsKeys.eol: "crlf"])
            try expect(crlfVTT.contains(0x0D), "CRLF on request")
            let lfSRT = try await bytes("subs.to.srt", [SubsKeys.eol: "lf"])
            try expect(!lfSRT.contains(0x0D), "LF on request")
            let bomVTT = try await bytes("subs.to.vtt", [SubsKeys.bom: true])
            try expectEqual(Array(bomVTT.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM")
            try expect(Array(vtt.prefix(3)) != [0xEF, 0xBB, 0xBF], "no BOM by default")
            let u16 = try await bytes("subs.to.srt", [SubsKeys.encodingOut: "utf-16"])
            try expectEqual(Array(u16.prefix(2)), [0xFF, 0xFE]); try expect(String(data: u16, encoding: .utf16)?.contains("Привет") == true)
            let w1251 = try await bytes("subs.to.srt", [SubsKeys.encodingOut: "windows-1251", SubsKeys.eol: "lf"])
            try expectEqual(Array(w1251), Array(TextEncodingKit.encode("1\n00:00:01,000 --> 00:00:02,000\nПривет, мир\n\n2\n00:00:03,000 --> 00:00:04,000\nСъешь ещё\n\n", as: .windows1251).data))
            for (key, codec) in [("koi8-r", DataEncoding.koi8r), ("cp866", .cp866)] as [(String, DataEncoding)] {
                let b = try await bytes("subs.to.txt", [SubsKeys.encodingOut: .string(key)])
                try expectEqual(Array(b), Array(TextEncodingKit.encode("Привет, мир\nСъешь ещё\n", as: codec).data), key)
            }
            let lvSrc = try SubsFixtures.write(fx, name: "lv.srt", cues: [SubtitleCue(start: 1, end: 2, text: "Rīga, ūdens, Šķūņu")])
            let lv = try await SubsRun.run("subs.to.vtt", lvSrc, [SubsKeys.encodingOut: "windows-1257"], fx: fx)[0]
            try expectEqual(try SubsRun.cues(lv, encoding: .windows1257).map(\.text), ["Rīga, ūdens, Šķūņu"])
            // Studio-only targets.
            let ass = try await SubsRun.run("subs.to.srt", src, [SubsKeys.format: "ass"], fx: fx)[0]
            try expectEqual(ass.pathExtension, "ass"); try expectEqual(SubtitleKit.sniff(String(decoding: try Data(contentsOf: ass), as: UTF8.self)), .ass)
            let sbv = try await SubsRun.run("subs.to.srt", src, [SubsKeys.format: "sbv"], fx: fx)[0]
            try expectEqual(sbv.pathExtension, "sbv")
        }

        dataTest("data.subs", "timing options: shift, frame-rate change, overlap repair, short-cue merge", proves: ["subs.offset.timing", "subs.fps.timing", "subs.overlap.timing", "subs.merge.cues", "subs.merge.min"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let cues = [SubtitleCue(start: 10, end: 14, text: "one"), SubtitleCue(start: 12, end: 16, text: "two"), SubtitleCue(start: 20, end: 20.3, text: "blink"), SubtitleCue(start: 20.4, end: 22, text: "after")]
            let src = try SubsFixtures.write(fx, name: "t.srt", cues: cues)
            func result(_ o: OptionValues) async throws -> [SubtitleCue] { try SubsRun.cues(try await SubsRun.run("subs.to.srt", src, o, fx: fx)[0]) }
            let plain = try await result([:])
            try same(plain.map(\.start), cues.map(\.start)); try same(plain.map(\.end), cues.map(\.end))
            let later = try await result([SubsKeys.offset: 2.5])
            try same(later.map(\.start), [12.5, 14.5, 22.5, 22.9]); try same(later.map(\.end), [16.5, 18.5, 22.8, 24.5])
            let earlier = try await result([SubsKeys.offset: -11.0])
            try same(earlier.map(\.text), ["one", "two", "blink", "after"], "nothing is lost at -11 s (the first cue is clipped to zero)")
            try same(earlier[0].start, 0.0); try same(earlier[0].end, 3.0)
            let gone = try await result([SubsKeys.offset: -15.0])
            try same(gone.map(\.text), ["two", "blink", "after"], "the first cue ends before 0:00 and disappears")
            let fps = try await result([SubsKeys.fpsFrom: "23.976", SubsKeys.fpsTo: "25"])
            try expectClose(fps[0].start, 9.5904, tolerance: 0.0005); try expectClose(fps[3].end, 21.0989, tolerance: 0.0005)
            let same25 = try await result([SubsKeys.fpsFrom: "25", SubsKeys.fpsTo: "25"])
            try same(same25.map(\.start), cues.map(\.start), "equal frame rates change nothing")
            let fixed = try await result([SubsKeys.overlap: true])
            try same(fixed[0].end, 12.0, "the first cue now ends where the second begins")
            let merged = try await result([SubsKeys.mergeShort: true])
            try same(merged.map(\.text), ["one", "two", "blink\nafter"]); try same(merged[2].end, 22.0)
            let strict = try await result([SubsKeys.mergeShort: true, SubsKeys.mergeMin: 0.2])
            try same(strict.count, 4, "a smaller threshold keeps the 0.3 s cue apart")
            let order = try await result([SubsKeys.fpsFrom: "24", SubsKeys.fpsTo: "25", SubsKeys.offset: 1.0])
            try expectClose(order[0].start, 10 * 24 / 25.0 + 1, tolerance: 0.001, "retime first, then shift in the new time")
        }

        dataTest("data.subs", "clean-up options: tags and sound descriptions, empty results are refused, text layout of TXT", proves: ["subs.tags.text", "subs.sdh.text", "subs.txt.join.lines"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let cues = [SubtitleCue(start: 1, end: 2, text: "{\\an8}<i>Hello</i> <font color=\"#fff\">there</font>"), SubtitleCue(start: 3, end: 4, text: "[phone rings]"), SubtitleCue(start: 8, end: 9, text: "ANNA: Fine.\n♪ ♪"),
                        SubtitleCue(start: 12, end: 13, text: "(sighs) Okay")]
            let src = try SubsFixtures.write(fx, name: "c.srt", cues: cues)
            func texts(_ o: OptionValues) async throws -> [String] { try SubsRun.cues(try await SubsRun.run("subs.to.srt", src, o, fx: fx)[0]).map(\.text) }
            try same(try await texts([:]), cues.map(\.text))
            try same(try await texts([SubsKeys.removeTags: true]), ["Hello there", "[phone rings]", "ANNA: Fine.\n♪ ♪", "(sighs) Okay"])
            try same(try await texts([SubsKeys.removeSDH: true]), ["{\\an8}<i>Hello</i> <font color=\"#fff\">there</font>", "Fine.", "Okay"])
            try same(try await texts([SubsKeys.removeTags: true, SubsKeys.removeSDH: true]), ["Hello there", "Fine.", "Okay"])
            let allGone = try SubsFixtures.write(fx, name: "g.srt", cues: [SubtitleCue(start: 1, end: 2, text: "[music]")])
            let err = try await expectThrows("everything removed") { _ = try await SubsRun.run("subs.to.srt", allGone, [SubsKeys.removeSDH: true], fx: fx) }
            try expect(ConversionError.describe(err).contains("clean-up") || ConversionError.describe(err).contains("очистки"), ConversionError.describe(err))
            let txt = try await SubsRun.run("subs.to.txt", src, [SubsKeys.removeTags: true, SubsKeys.txtJoin: "paragraphs"], fx: fx)[0]
            try same(String(decoding: try Data(contentsOf: txt), as: UTF8.self), "Hello there [phone rings]\n\nANNA: Fine. ♪ ♪\n\n(sighs) Okay\n")
            let one = try await SubsRun.run("subs.to.txt", src, [:], fx: fx)[0]
            try same(String(decoding: try Data(contentsOf: one), as: UTF8.self), "Hello there\n[phone rings]\nANNA: Fine. ♪ ♪\n(sighs) Okay\n")
        }
    }
}
