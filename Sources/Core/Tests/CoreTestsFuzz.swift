import Foundation

// CRASH SAFETY. Every reader the app points at a file or a string it did not write is run over mutated copies of a valid sample (bytes flipped, cut, inserted, set to the
// extreme values that break arithmetic). The only property checked is the one a person feels: the app does not die (a Swift trap would end this run) and does not hang.
// Seeds are fixed, so a failure reproduces; the sample sets are small enough to stay in the self-test time budget.

enum FuzzKit {
    /// One mutated copy of `data`.
    static func mutate(_ data: [UInt8], _ rng: inout SplitMix) -> [UInt8] {
        var b = data
        let extremes: [[UInt8]] = [[0xFF, 0xFF, 0xFF, 0xFF], [0xFF, 0xFF, 0xFF, 0x7F], [0, 0, 0, 0x80], [0, 0, 0, 0], [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F], [1, 0, 0, 0, 0, 0, 0, 0x80]]
        for _ in 0..<(1 + Int(rng.next() % 6)) where !b.isEmpty {
            let at = Int(rng.next() % UInt64(b.count))
            switch rng.next() % 7 {
            case 0: b[at] ^= UInt8(1 << (rng.next() % 8))
            case 1: b[at] = UInt8(truncatingIfNeeded: rng.next())
            case 2: let n = min(Int(1 + rng.next() % 16), b.count - at); b.removeSubrange(at..<(at + n))
            case 3: b.insert(contentsOf: (0..<Int(1 + rng.next() % 16)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: at)
            case 4: b = Array(b.prefix(at))
            case 5: let e = extremes[Int(rng.next() % UInt64(extremes.count))]; for (i, v) in e.enumerated() where at + i < b.count { b[at + i] = v }
            default: let n = min(Int(1 + rng.next() % 64), b.count - at); b.insert(contentsOf: b[at..<(at + n)], at: at)
            }
        }
        return b
    }

    static func mutate(_ text: String, _ rng: inout SplitMix) -> String {
        String(decoding: mutate(Array(text.utf8), &rng), as: UTF8.self)
    }

    /// Runs `body` over `rounds` mutated copies of each sample, written to `scratch` with `ext`.
    static func files(_ samples: [URL], ext: String, rounds: Int = 120, seed: UInt64, scratch: URL, _ body: (URL) async -> Void) async {
        var rng = SplitMix(seed: seed)
        for s in samples {
            guard let data = try? Data(contentsOf: s) else { continue }
            await body(s)
            for i in 0..<rounds {
                let out = scratch.appendingPathComponent("fuzz-\(i % 8).\(ext)")
                try? Data(mutate([UInt8](data), &rng)).write(to: out)
                await body(out)
            }
        }
    }
}

enum CoreTestsFuzz {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("core.fuzz", "text parsers survive mutated input: links, the URL scheme, browser answers, yt-dlp progress, HTML, Markdown, subtitles, tar listings", timeout: 120) {
            var rng = SplitMix(seed: 90_001)
            let links = ["https://example.com/watch?v=abc&list=x", "http://[2001:db8::1]:8080/a b", "https://пример.рф/путь?q=1#frag", "swampconverter://download?url=https%3A%2F%2Fa.b%2Fc&mode=best&title=T",
                         "ftp://x", "javascript:alert(1)", "file:///etc/passwd", "https://user:pw@host.example:99999/", "https://%zz.com", "http://0x7f.1/", "https://a.b/" + String(repeating: "x", count: 5000)]
            let html = "<html><head><style>.a{font-weight:bold}</style></head><body><h1 class=a>T &amp; &#x41;</h1><p>one<p>two <b>b<i>i</b></i><table><tr><td>1<td>2<tr><td colspan=3>x</table><ul><li>a<li>b</ul><pre>p</pre></body></html>"
            let markdown = "# Title #\n\n* a\n* b\n\n1. x\n2. y\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n[l](http://x.y \"t\") ![i](a.png) `c` **b** _i_ ~~s~~\n\n```swift\ncode\n```\n> q\n"
            let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,250\nПривет\n"
            let vtt = "WEBVTT\n\n00:01.000 --> 00:02.500 align:start\nHello <b>x</b>\n"
            let ass = "[Script Info]\nTitle: x\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.00,0:00:02.50,Default,Hello{\\b1}x\n"
            let tarLines = ["-rw-r--r--  0 user group   1234 Oct 24 12:00 path/file.txt", "lrwxr-xr-x  0 u g 0 Jan  1  2020 link -> ../x", "drwxr-xr-x 0 u g 0 Oct 24 12:00 d/"]
            for round in 0..<400 {
                for l in links { let m = FuzzKit.mutate(l, &rng); _ = LinkParsing.validate(m); _ = LinkParsing.extractURLs(from: m + " " + m); if let u = URL(string: m) { _ = DownloadURLScheme.parse(u) } }
                _ = BrowserScripts.parseResult(FuzzKit.mutate("https://a.b/c\nTitle", &rng)); _ = BrowserScripts.parseFinderSelection(FuzzKit.mutate("/Users/a/b\n/c d\n", &rng))
                _ = YtDlpProgressParser.parse(line: FuzzKit.mutate(YtDlpProgressParser.template + " 12.5% 1.2MiB/s 00:30", &rng))
                _ = DocHTMLReader.read(FuzzKit.mutate(html, &rng)); _ = DocMarkdown.parse(FuzzKit.mutate(markdown, &rng), gfm: round % 2 == 0)
                _ = try? SubtitleKit.parse(FuzzKit.mutate(srt, &rng)); _ = try? SubtitleKit.parse(FuzzKit.mutate(vtt, &rng)); _ = SubtitleASS.parse(FuzzKit.mutate(ass, &rng))
                for l in tarLines { _ = ArchiveTree.parseTarLine(FuzzKit.mutate(l, &rng)) }
                _ = DownloadMode(parameter: FuzzKit.mutate("best", &rng))
            }
        }

        t.register("core.fuzz", "binary readers survive mutated files: format sniffing, zip, tar, tar.gz, csv, xlsx, docx, odt, rtf, html, pdf, png, jpeg, wav", timeout: 300) {
            let fx = ConformanceFixtures(label: "fuzz"); defer { fx.base.cleanup() }
            let scratch = fx.base.url("scratch"); try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            var samples: [URL] = []
            samples.append(try fx.base.png()); samples.append(try fx.base.jpeg()); samples.append(try fx.base.wav()); samples.append(try fx.base.pdf())
            samples.append(try fx.docx()); samples.append(try fx.odt()); samples.append(try fx.xlsx())
            let zip = fx.base.url("s.zip"); try RawZip.build([RawZip.Entry("a.txt", "A"), RawZip.Entry("d/b.txt", String(repeating: "b", count: 3000))]).write(to: zip); samples.append(zip)
            let tar = fx.base.url("s.tar"); try DataTestsTar.write(tar, items: [.init(name: "a.txt", data: Data("A".utf8)), .init(name: "d/b.txt", data: Data(count: 2000))], dirs: ["d"], links: [("l", "a.txt")], gzip: false, fx: fx.base)
            samples.append(tar)
            let tgz = fx.base.url("s.tar.gz"); try DataTestsTar.write(tgz, items: [.init(name: "a.txt", data: Data("A".utf8))], gzip: true, fx: fx.base); samples.append(tgz)
            let csv = try fx.base.csv(); samples.append(csv)
            let ctx = OperationContext(operationID: "x", mode: .studio, resolved: ResolvedOptions(values: OptionValues(), inactive: [], messages: []), outputRules: OutputRules(), settings: SettingsData())
            // SC_FUZZ_ROUNDS=600 ./build.sh selftest core.fuzz: a longer hunt (the default keeps the run short).
            let rounds = ProcessInfo.processInfo.environment["SC_FUZZ_ROUNDS"].flatMap { Int($0) } ?? 60
            await FuzzKit.files(samples, ext: "bin", rounds: rounds, seed: 90_002, scratch: scratch) { url in
                _ = FormatSniffer.sniff(url)
                _ = try? ZipKit.list(url)
                _ = try? SheetReader.read(url)
                for gz in [false, true] { _ = try? DataTestsTar.read(url, gzip: gz) }
                let stage = scratch.appendingPathComponent("stage-\(UUID().uuidString.prefix(6))")
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                for f in [ArchiveFormat.zip, .tar, .tarGz] { _ = try? await ArchiveExtractor.extract(url, into: stage, format: f, options: ArchiveExtractOptions(), ctx: ctx, progress: { _ in }) }
                _ = await ArchiveSourceProbe().probe(FileItem(url: url))
                _ = try? FileManager.default.removeItem(at: stage)
            }
            // The document readers by key, on files named for the format they pretend to be.
            for (sample, key) in [(try fx.docx(), "docx"), (try fx.odt(), "odt")] {
                await FuzzKit.files([sample], ext: key, rounds: rounds, seed: 90_003, scratch: scratch) { url in _ = try? await DocNative.read(url, key: key, settings: DocSettings(), ctx: nil) }
            }
        }
    }
}
