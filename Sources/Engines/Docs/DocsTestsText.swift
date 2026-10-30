import Foundation
import CryptoKit

// The text layer under the converters: encoding detection and streaming transcoding (fixtures made by iconv, an encoder that is not ours), CommonMark examples,
// a Markdown escaping property test (write, then parse: the words must come back whatever punctuation they contain), the tolerant HTML parser and plain-text rules.

enum DocsTextTests {
    static func register() {
        registerCodec()
        registerStreaming()
        registerMarkdown()
        registerHTML()
        registerPlainText()
    }

    // MARK: Helpers

    /// UTF-8 text -> bytes in `iconvName`, produced by /usr/bin/iconv.
    static func iconvEncode(_ text: String, to iconvName: String, fx: TestFixtures) throws -> Data {
        let src = fx.url("iconv-src-\(Util.hex8()).txt")
        try Data(text.utf8).write(to: src)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconv"); p.arguments = ["-f", "UTF-8", "-t", iconvName, src.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        try expectEqual(p.terminationStatus, 0, "iconv -t \(iconvName)")
        return data
    }

    static func html(_ blocks: [DocBlock]) -> String {
        var m = DocModel(); m.blocks = blocks
        var o = DocHTMLWriter.Options(); o.fragment = true; o.headingIDs = false
        return squash(DocHTMLWriter.write(m, options: o).html)
    }

    /// Whitespace between tags and line breaks before a tag do not matter in HTML.
    static func squash(_ html: String) -> String {
        html.replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression).replacingOccurrences(of: "\n<", with: "<").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: Detection

    private static func registerCodec() {
        docTest("encoding detection: natural text in Windows-1251, KOI8-R, DOS 866, Windows-1257, Windows-1250, Windows-1252, UTF-8 and UTF-16 is recognised from its bytes") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let ru = "Съешь ещё этих мягких французских булок, да выпей чаю. Жабы живут в болоте и поют по ночам. Привет, мир! Вечерний туман поднимается над водой. "
            let lv = "Ķirsis un ābols aug dārzā pie ezera. Šķirne ar īpašu garšu, ēdiens ar žāvētu zivi, čūska ložņā pa zāli. Lūdzu, nāc ātri uz māju. "
            let cz = "Příliš žluťoučký kůň úpěl ďábelské ódy. Řeka teče údolím a ptáci zpívají ráno. Město Plzeň leží na řece Mži. Děkuji vám za pomoc. "
            let fr = "Où est l'été français? Garçon, un café crème, s'il vous plaît; à bientôt, très bien, déjà vu, l'élève naïf. Voilà le résultat final. "
            let cases: [(String, String, [String])] = [
                (String(repeating: ru, count: 4), "CP1251", ["windows-1251"]), (String(repeating: ru, count: 4), "KOI8-R", ["koi8-r"]), (String(repeating: ru, count: 4), "CP866", ["cp866"]),
                (String(repeating: lv, count: 4), "CP1257", ["windows-1257"]), (String(repeating: cz, count: 4), "CP1250", ["windows-1250"]), (String(repeating: fr, count: 4), "CP1252", ["windows-1252"])]
            for (text, name, accepted) in cases {
                let bytes = try iconvEncode(text, to: name, fx: fx)
                let d = DocTextCodec.detect(bytes)
                try expect(accepted.contains(d.id), "\(name): detected \(d.id)")
                try expectEqual(DocTextCodec.decode(bytes).text, text, "\(name): decoded text")
            }
            try expectEqual(DocTextCodec.detect(Data(String(repeating: ru + lv, count: 3).utf8)).id, "utf-8")
            try expectEqual(DocTextCodec.detect(Data("plain ascii only".utf8)).id, "utf-8", "ASCII counts as UTF-8")
            try expectEqual(DocTextCodec.detect(Data([0xEF, 0xBB, 0xBF, 0x41])), DocTextCodec.Detection(id: "utf-8", bomLength: 3))
            try expectEqual(DocTextCodec.detect(Data([0xFF, 0xFE, 0x41, 0x00])), DocTextCodec.Detection(id: "utf-16", bomLength: 2))
            // A multi-byte character cut at the end of the sample must not turn a UTF-8 file into a code page.
            var cut = Data(String(repeating: "я", count: 100).utf8); cut.removeLast()
            try expectEqual(DocTextCodec.detect(cut).id, "utf-8", "a character cut by the sample end is still UTF-8")
            // Invalid bytes become U+FFFD, never a crash, and say so.
            let bad = DocTextCodec.decode(Data([0x41, 0xFF, 0xFE, 0x42, 0x80]), as: "utf-8")
            try expect(bad.lossy && bad.text.contains("\u{FFFD}"), "undecodable bytes are replaced and reported")
            // Encoding: an unrepresentable character is counted.
            let e = DocTextCodec.encode("Привет ķ", as: "windows-1251")
            try expectEqual(e.replaced, 1); try expectEqual(e.data.last, 0x3F)
        }
    }

    // MARK: Streaming

    private static func registerStreaming() {
        docTest("streaming re-encode: text crosses chunk boundaries without cutting a character, a surrogate pair or a CR LF in half, and memory does not grow with the file", timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            // Cyrillic is two bytes per character in UTF-8, the frog emoji four: the 4 MiB chunk edge falls inside characters. The CR LF pairs fall on edges too.
            let unit = "жаба\u{1F438}поёт\r\nночью\n"
            func make(_ url: URL, mebibytes: Int) throws -> Int {
                let chunk = Data(String(repeating: unit, count: 4_000).utf8)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
                var written = 0
                while written < mebibytes << 20 { try h.write(contentsOf: chunk); written += chunk.count }
                return written
            }
            /// SHA-256 of the file with every CR removed (what LF normalisation must produce), streamed.
            func hashLF(_ url: URL) throws -> String {
                let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
                var hasher = SHA256()
                while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: Data(d.filter { $0 != 13 })) }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            func utf16Units(_ url: URL) throws -> Int { Int(TestFile.size(url) - 2) / 2 }
            var peaks: [Int64] = []
            for mib in [9, 36] {
                let src = fx.url("big\(mib).txt"), mid = fx.url("big\(mib).utf16.txt"), back = fx.url("big\(mib).back.txt")
                let bytes = try make(src, mebibytes: mib)
                let base = footprint()
                let peak = Locked(base)
                let sampling = Locked(true)
                let sampler = Thread { while sampling.value { let f = footprint(); peak.withLock { $0 = max($0, f) }; Thread.sleep(forTimeInterval: 0.005) } }
                sampler.start()
                let r1 = try DocTextCodec.transcodeFile(input: src, encodingIn: "auto", to: mid, encodingOut: "utf-16", bom: true, eol: nil)
                let r2 = try DocTextCodec.transcodeFile(input: mid, encodingIn: "auto", to: back, encodingOut: "utf-8", bom: false, eol: "lf")
                sampling.value = false
                try expectEqual(r1.detected, "utf-8"); try expectEqual(r2.detected, "utf-16"); try expectEqual(r1.replaced + r2.replaced, 0)
                // 1 UTF-16 unit per BMP character, 2 for the emoji: characters = UTF-8 characters.
                let chars = try String(contentsOf: src, encoding: .utf8).unicodeScalars.count
                let emoji = chars / (unit.unicodeScalars.count) * 1
                try expectEqual(try utf16Units(mid), chars + emoji, "UTF-16 length of \(mib) MiB")
                try expectEqual(try hashLF(back), try hashLF(src), "\(mib) MiB: the round trip through UTF-16 equals the source with LF endings (byte for byte)")
                let text = try String(contentsOf: back, encoding: .utf8)
                try expect(!text.contains("\u{FFFD}") && !text.contains("\r"), "no cut character, no CR left")
                _ = bytes
                peaks.append(peak.value - base)
            }
            try expect(peaks[1] < max(peaks[0] * 3 / 2, 0) + (24 << 20), "memory does not grow with the file: +\(peaks[0] >> 20) MiB for 9 MiB, +\(peaks[1] >> 20) MiB for 36 MiB")
            // A CR at the very end of one chunk followed by LF at the start of the next must stay ONE line ending.
            let crlf = fx.url("crlf.txt")
            var bytes = Data(repeating: 0x61, count: (4 << 20) - 1); bytes.append(contentsOf: [0x0D, 0x0A, 0x62, 0x0D, 0x0A])
            try bytes.write(to: crlf)
            let lf = fx.url("crlf.lf.txt")
            _ = try DocTextCodec.transcodeFile(input: crlf, encodingIn: "utf-8", to: lf, encodingOut: "utf-8", bom: false, eol: "lf")
            let out = try Data(contentsOf: lf)
            let expectedCount: Int = 4_194_306        // 4 MiB - 1 letters, LF, "b", LF
            try expectEqual(out.count, expectedCount, "CR LF across the chunk edge became one LF")
            try expectEqual(out.filter { $0 == 10 }.count, 2)
            // Cancellation reaches a streaming run.
            let task = Task { try DocTextCodec.transcodeFile(input: fx.url("big36.txt"), encodingIn: "auto", to: fx.url("cancelled.txt"), encodingOut: "utf-16", bom: true, eol: nil) }
            task.cancel()
            let cancelled = await task.result
            if case .failure(let e) = cancelled { try expect(e is CancellationError, "cancellation is CancellationError") } else { throw TestFailure(message: "a cancelled streaming run must not succeed", file: #fileID, line: #line) }
        }
    }

    // MARK: CommonMark and Markdown escaping

    private static func registerMarkdown() {
        docTest("CommonMark: a corpus of specification examples parses to the HTML the specification gives") {
            var examples: [(String, String)] = []
            let part0: [(String, String)] = [
                ("# foo\n## foo\n###### foo", "<h1>foo</h1><h2>foo</h2><h6>foo</h6>"),
                ("####### foo", "<p>####### foo</p>"),
                ("Foo *bar*\n=========\n\nFoo *bar*\n---------", "<h1>Foo <em>bar</em></h1><h2>Foo <em>bar</em></h2>"),
                ("***\n---\n___", "<hr/><hr/><hr/>"),
                ("*foo bar*", "<p><em>foo bar</em></p>"), ("_foo bar_", "<p><em>foo bar</em></p>"), ("**foo bar**", "<p><strong>foo bar</strong></p>"),
                ("foo***bar***baz", "<p>foo<em><strong>bar</strong></em>baz</p>"), ("snake_case_word", "<p>snake_case_word</p>"), ("a * foo bar*", "<p>a * foo bar*</p>"),
                ("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>"),
                ("\\*not emphasized*\n\\<br/> not a tag\n\\[not a link](/foo)", "<p>*not emphasized*\n&lt;br/&gt; not a tag\n[not a link](/foo)</p>")
            ]
            examples += part0
            let part1: [(String, String)] = [
                ("`foo`", "<p><code>foo</code></p>"), ("`` foo ` bar ``", "<p><code>foo ` bar</code></p>"), ("`foo", "<p>`foo</p>"),
                ("[link](/uri \"title\")", "<p><a href=\"/uri\" title=\"title\">link</a></p>"), ("[link](</my uri>)", "<p><a href=\"/my uri\">link</a></p>"),
                ("[a *b* c](/u)", "<p><a href=\"/u\">a <em>b</em> c</a></p>"),
                ("![foo](/url \"title\")", "<p><img src=\"/url\" alt=\"foo\" title=\"title\"/></p>"),
                ("[foo]\n\n[foo]: /url \"title\"", "<p><a href=\"/url\" title=\"title\">foo</a></p>"),
                ("<http://foo.bar.baz>", "<p><a href=\"http://foo.bar.baz\">http://foo.bar.baz</a></p>"),
                ("foo\nbaz", "<p>foo\nbaz</p>"), ("foo  \nbaz", "<p>foo<br/>baz</p>"), ("foo\\\nbaz", "<p>foo<br/>baz</p>"),
                ("> # Foo\n> bar\n> baz", "<blockquote><h1>Foo</h1><p>bar\nbaz</p></blockquote>"), ("> foo\nbar", "<blockquote><p>foo\nbar</p></blockquote>")
            ]
            examples += part1
            let part2: [(String, String)] = [
                ("- foo\n- bar\n- baz", "<ul><li>foo</li><li>bar</li><li>baz</li></ul>"), ("1. foo\n2. bar", "<ol><li>foo</li><li>bar</li></ol>"),
                ("3. foo\n4. bar", "<ol start=\"3\"><li>foo</li><li>bar</li></ol>"),
                ("- foo\n\n- bar", "<ul><li><p>foo</p></li><li><p>bar</p></li></ul>"),
                ("- a\n  - b\n    - c", "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li></ul>"),
                ("- foo\n- bar\n\n\n- baz", "<ul><li><p>foo</p></li><li><p>bar</p></li><li><p>baz</p></li></ul>"),
                ("The number 2.\n3. not a list start", "<p>The number 2.\n3. not a list start</p>"),
                ("```\n<\n >\n```", "<pre><code>&lt;\n &gt;\n</code></pre>"), ("```ruby\ndef foo(x)\n  return 3\nend\n```", "<pre><code class=\"language-ruby\">def foo(x)\n  return 3\nend\n</code></pre>"),
                ("    a simple\n      indented code block", "<pre><code>a simple\n  indented code block\n</code></pre>")
            ]
            examples += part2
            let part3: [(String, String)] = [
                ("aaa\n\nbbb", "<p>aaa</p><p>bbb</p>"), ("  aaa\n bbb", "<p>aaa\nbbb</p>"), ("&amp; &copy; &#35; &#x1F600;", "<p>&amp; © # \u{1F600}</p>"),
                ("| a | b |\n| - | -: |\n| 1 | 2 |", "<table><thead><tr><th>a</th><th align=\"right\">b</th></tr></thead><tbody><tr><td>1</td><td align=\"right\">2</td></tr></tbody></table>"),
                ("~~gone~~ and - [x] done", "<p><del>gone</del> and - [x] done</p>")
            ]
            examples += part3
            var failures: [String] = []
            for (md, expected) in examples {
                let got = html(DocMarkdown.parse(md, gfm: true).blocks)
                let want = squash(expected)
                if got != want { failures.append("\n\(md.debugDescription)\n  got      \(got.debugDescription)\n  expected \(want.debugDescription)") }
            }
            try expect(failures.isEmpty, "\(failures.count) of \(examples.count) examples differ:" + failures.prefix(6).joined())
            // GFM task list items.
            let task = DocMarkdown.parse("- [x] done\n- [ ] todo\n", gfm: true).blocks
            guard case .list(let l)? = task.first else { throw TestFailure(message: "task list", file: #fileID, line: #line) }
            try expectEqual(l.items.map(\.checked), [true, false])
        }

        docTest("Markdown headings: a text that ends in # keeps it (the closing sequence of an ATX heading would swallow it)") {
            for t in ["C #", "#", "foo ##", "a # b", "end#", "x \\#", "# x #", "F# and C#", "tail #  "] {
                var m = DocModel(); m.blocks = [.heading(level: 2, content: [.text(t)])]
                let md = DocMarkdownWriter.write(m, gfm: true).markdown
                guard case .heading(_, let c)? = DocMarkdown.parse(md, gfm: true).blocks.first else { throw TestFailure(message: "no heading back from \(md.debugDescription)", file: #fileID, line: #line) }
                try expectEqual(DocOracle.normalized(c.plainText), DocOracle.normalized(t), "markdown was \(md.debugDescription)")
            }
        }

        docTest("Markdown escaping: text full of punctuation survives write then parse, in paragraphs, headings, list items, table cells and links") {
            var rng = SplitMix(seed: 20_261_024)
            let alphabet = Array("ab cde_*`[]()<>&\\#!~|-+.:12 \"'=/")
            let words = ["foo", "bar_baz", "*", "_", "`", "[x]", "(y)", "1.", "-", "#", ">", "|", "<b>", "&amp;", "a_b_c", "**", "~~", "\\", "http://x.y/z_(1)", "!"]
            func randomText() -> String {
                var s = ""
                for _ in 0..<(1 + Int(rng.next() % 6)) {
                    if rng.next() % 3 == 0 { s += words[Int(rng.next() % UInt64(words.count))] } else { for _ in 0..<(1 + Int(rng.next() % 7)) { s.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) } }
                    s += rng.next() % 2 == 0 ? " " : ""
                }
                return s.trimmingCharacters(in: .whitespaces)
            }
            var bad: [String] = []
            for i in 0..<400 {
                let t = randomText()
                if t.isEmpty { continue }
                let kind = i % 5
                let model = escapingModel(kind: kind, text: t, index: i)
                let md = DocMarkdownWriter.write(model, gfm: true).markdown
                let back = DocMarkdown.parse(md, gfm: true)
                let want = DocOracle.normalized(t)
                var got = ""
                switch back.blocks.first {
                case .paragraph(let c)?: got = DocOracle.normalized(c.plainText)
                case .heading(_, let c)?: got = DocOracle.normalized(c.plainText)
                case .list(let l)?: got = DocOracle.normalized(l.items.first?.blocks.first.map { $0.plainText } ?? "")
                case .table(let tb)?: got = DocOracle.normalized(tb.rows.first?.first?.plainText ?? "")
                default: got = "(no block: \(back.blocks))"
                }
                if got != want { bad.append("kind \(kind): \(t.debugDescription)\n  markdown \(md.debugDescription)\n  parsed   \(got.debugDescription)") }
                if kind == 4, case .paragraph(let c)? = back.blocks.first, case .link(let u, _, _)? = c.first { if !u.contains("example.com") { bad.append("link lost: \(md)") } }
            }
            try expect(bad.isEmpty, "\(bad.count) of 400 texts did not survive:\n" + bad.prefix(5).joined(separator: "\n"))
        }
    }

    private static func escapingModel(kind: Int, text t: String, index i: Int) -> DocModel {
        var m = DocModel()
        switch kind {
        case 0: m.blocks = [.paragraph([.text(t)])]
        case 1: m.blocks = [.heading(level: 2, content: [.text(t)])]
        case 2: m.blocks = [.list(DocList(ordered: false, items: [DocListItem(blocks: [.paragraph([.text(t)])])]))]
        case 3: m.blocks = [.table(DocTable(align: [.none, .none], header: [[.text("h")], [.text("g")]], rows: [[[.text(t)], [.text("c")]]]))]
        default: m.blocks = [.paragraph([.link(url: "https://example.com/a b(c)?q=\(i)", title: nil, content: [.text(t)])])]
        }
        return m
    }

    // MARK: HTML

    private static func registerHTML() {
        docTest("HTML reader: untidy real-world markup (unclosed tags, bare attributes, mis-nested styles, entities, scripts, comments, Word classes) still reads as the document it means") {
            let page = """
            <!DOCTYPE html><HTML LANG=lv><HEAD><meta charset=utf-8><TITLE>Testa lapa</TITLE><style>.warn{font-weight:bold} p.note{font-style:italic}</style>
            <script>var x = "<p>not text</p>";</script></HEAD><body>
            <!-- a comment <p>hidden</p> -->
            <H1 class=top>Virsraksts &amp; &Zcaron;ogs &#352; &#x161; &nbsp;|&mdash;|&nonsense;</H1>
            <p>First <b>bold <i>both</b> italic</i> text<br>after break<p class=note>Second, unclosed paragraph
            <p class=warn>Warned
            <ul><li>one<li>two <a href=http://example.com/a?b=1&c=2>link</a><li>three<ul><li>deep</ul></ul>
            <table border=1><tr><th>H1<th>H2<tr><td>a<td>b<tr><td colspan=2>wide</table>
            <pre>  keep   spaces
            second</pre><img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" alt="dot">
            <p class=MsoNormal><span style='font-weight:bold;mso-bidi-font-weight:normal'>Word bold</span> and <span style="text-decoration:line-through">struck</span></p>
            <![CDATA[ raw text ]]></body></HTML>
            """
            let m = DocHTMLReader.read(page)
            let lines = DocOracle.outline(m.blocks)
            try expectEqual(m.meta.title, "Testa lapa"); try expectEqual(m.meta.language, "lv")
            try expect(lines.contains("h1 Virsraksts & Žogs Š š | |—|&nonsense;".replacingOccurrences(of: "| |", with: "\u{00A0}|")) || lines.first?.hasPrefix("h1 Virsraksts & Žogs Š š") == true, "heading with entities: \(lines.first ?? "")")
            try expect(!lines.joined().contains("not text") && !lines.joined().contains("hidden"), "scripts and comments are not text")
            guard case .paragraph(let p1)? = m.blocks.dropFirst().first else { throw TestFailure(message: "first paragraph: \(lines)", file: #fileID, line: #line) }
            try expectEqual(DocOracle.normalized(p1.plainText), "First bold both italic text after break", "mis-nested bold and italic keep their words")
            try expect(lines.contains("p Second, unclosed paragraph") && lines.contains("p Warned"), "unclosed paragraphs close at the next one: \(lines)")
            try expect(lines.contains("ul0 one") && lines.contains("ul0 two link") && lines.contains("ul0 three") && lines.contains("ul1 deep"), "unclosed list items and nesting: \(lines)")
            try expect(lines.contains("th H1|H2") && lines.contains("tr a|b") && lines.contains { $0.hasPrefix("tr wide") }, "table without tbody or closing tags: \(lines)")
            try expect(lines.contains("code   keep   spaces\nsecond"), "pre keeps its spaces: \(lines)")
            let link = try unwrap(m.blocks.compactMap { b -> String? in if case .list(let l) = b { return l.items.compactMap { $0.blocks.first }.compactMap { x -> String? in if case .paragraph(let c) = x, case .link(let u, _, _)? = c.last { return u } else { return nil } }.first } else { return nil } }.first)
            try expectEqual(link, "http://example.com/a?b=1&c=2", "an unquoted href with &c= stays whole")
            try expectEqual(m.media.count, 1, "the data: picture is decoded into the media table")
            // Styles: classes from <style>, inline styles, Word's mso-prefixed declarations.
            let strong = m.blocks.compactMap { b -> [DocInline]? in if case .paragraph(let c) = b, c.plainText.hasPrefix("Warned") { return c } else { return nil } }.first
            try expect(strong.map { if case .strong? = $0.first { return true } else { return false } } == true, "p.warn {font-weight:bold} makes the paragraph strong")
            let word = m.blocks.compactMap { b -> [DocInline]? in if case .paragraph(let c) = b, c.plainText.hasPrefix("Word bold") { return c } else { return nil } }.first ?? []
            try expect(word.contains { if case .strong = $0 { return true } else { return false } } && word.contains { if case .strike = $0 { return true } else { return false } }, "inline style declarations: \(word)")
            // Entities in isolation.
            try expectEqual(DocEntities.decode("&lt;&gt;&amp;&quot;&apos;&#65;&#x42;&euro;&copy;&bogus;&#0;"), "<>&\"'AB€©&bogus;\u{FFFD}")
            try expectEqual(DocEntities.decode("fish &amp chips &"), "fish &amp chips &", "a missing semicolon is left alone")
            // A document with pictures that live next to it: only real pictures are embedded, and only relative paths.
            let fx = TestFixtures(); defer { fx.cleanup() }
            let pic = DocFixtures.picture(fx); try pic.write(to: fx.url("pic.png"))
            try Data("secret".utf8).write(to: fx.url("secret.txt"))
            let src = fx.url("page.html")
            try Data("<p><img src=\"pic.png\" alt=a><img src=\"secret.txt\" alt=b><img src=\"/etc/hosts\" alt=c><img src=\"http://example.com/x.png\" alt=d><img src=\"file:///etc/hosts\" alt=e><img src=\"../page.html\" alt=f></p>".utf8).write(to: src)
            let read = try await DocNative.read(src, key: "html", settings: DocSettings(), ctx: nil)
            try expectEqual(read.media.count, 1, "only pic.png is embedded")
            guard case .paragraph(let inl)? = read.blocks.first else { throw TestFailure(message: "paragraph", file: #fileID, line: #line) }
            let srcs = inl.compactMap { i -> String? in if case .image(let s, _, _) = i { return s } else { return nil } }
            try expectEqual(srcs.filter { read.media[$0] != nil }, ["pic.png"]); try expectEqual(srcs.count, 6)
        }
    }

    // MARK: Plain text

    private static func registerPlainText() {
        docTest("plain text: paragraphs, lists, indented code and hard-wrapped lines are recognised; Markdown syntax in a .txt is NOT interpreted") {
            let txt = "Heading-looking line\n\nA paragraph with # hash, *stars*, _underscores_ and `ticks`.\nSecond line of it.\n\n- one\n- two\n\n1. first\n2. second\n\n    indented code\n    more code\n\n* not\n"
            let blocks = DocPlainText.read(txt, reflow: .keep)
            let lines = DocOracle.outline(blocks)
            try expect(lines.contains("p Heading-looking line"), "no heading from plain text: \(lines)")
            try expect(lines.contains { $0.hasPrefix("p A paragraph with # hash, *stars*, _underscores_ and `ticks`.") }, "Markdown characters stay characters: \(lines)")
            try expect(lines.contains("ul0 one") && lines.contains("ul0 two") && lines.contains("ol0 1 first") && lines.contains("ol0 2 second"), "lists: \(lines)")
            try expect(lines.contains("code indented code\nmore code"), "indented block is code: \(lines)")
            // Through the whole converter: the asterisks and hashes are still there in the DOCX text.
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = fx.url("literal.txt"); try Data("# not a heading\n\nplain *stars* and _under_\n".utf8).write(to: src)
            let out = try fx.makeDirectory("out")
            let docx = try await DocRun.convert(src, to: "docx", into: out)
            let text = DocOracle.text(of: docx)
            try expect(text.contains("# not a heading") && text.contains("*stars*") && text.contains("_under_"), "textutil reads the DOCX literally: \(text)")
            try expect(!DocOracle.zipPart(docx, "word/document.xml").contains("Heading1"), "no heading style invented")
            // Rendering: wrap respects words longer than the width and keeps indentation of list continuation lines.
            let long = DocPlainText.render([.paragraph([.text("a " + String(repeating: "x", count: 30) + " b")])], wrap: 10)
            try expect(long.contains(String(repeating: "x", count: 30)), "an unbreakable word stays whole: \(long)")
            let item = DocPlainText.render([.list(DocList(ordered: false, items: [DocListItem(blocks: [.paragraph([.text("alpha beta gamma delta epsilon zeta")])])]))], wrap: 16)
            try expect(item.split(separator: "\n").dropFirst().allSatisfy { $0.hasPrefix("  ") }, "continuation lines are indented under the text: \(item)")
        }
    }
}
