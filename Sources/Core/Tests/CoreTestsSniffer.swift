import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// The conformance toolbox must itself be right before it judges anyone else: the sniffer is checked against files written by system encoders (ImageIO,
// afconvert, textutil, zip, tar, ffmpeg), the metrics against known relationships (identical = infinite, lower quality = lower score).

enum CoreTestsSniffer {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("conformance.toolbox", "the sniffer names the real format of files written by system encoders, whatever their extension says") {
            let fx = ConformanceFixtures(label: "sniff")
            defer { fx.cleanup() }
            let photo = try fx.photo("p.png")
            let jpg = try fx.photoJPEG("p.jpg")
            let tiff = try fx.base.writeImage(fx.photoImage(width: 64, height: 48), name: "p.tiff", type: .tiff)
            let bmp = try fx.base.writeImage(fx.photoImage(width: 64, height: 48), name: "p.bmp", type: .bmp)
            let gif = try fx.base.writeImage(fx.photoImage(width: 64, height: 48), name: "p.gif", type: .gif)
            let ico = try fx.base.writeImage(fx.photoImage(width: 64, height: 64), name: "p.ico", type: .ico)
            var expected: [(URL, String)] = [(photo, "png"), (jpg, "jpg"), (tiff, "tiff"), (bmp, "bmp"), (gif, "gif"), (ico, "ico")]
            if let heic = try? fx.base.writeImage(fx.photoImage(width: 64, height: 48), name: "p.heic", type: .heic) { expected.append((heic, "heic")) }
            let wav = try fx.chirp("c.wav", seconds: 1)
            expected.append((wav, "wav"))
            for ext in ["m4a", "flac", "aiff", "caf"] { if let u = fx.audioVariant(of: wav, ext: ext) { expected.append((u, ext)) } }
            if ToolLocator.shared.has(.ffmpeg) { for ext in ["mp3", "ogg", "opus"] { if let u = fx.audioVariant(of: wav, ext: ext) { expected.append((u, ext)) } } }
            let pdf = try fx.richPDF("d.pdf", pages: 1)
            expected.append((pdf.url, "pdf"))
            expected.append((try fx.docx("r.docx"), "docx"))
            expected.append((try fx.odt("r.odt"), "odt"))
            expected.append((try fx.xlsx("t.xlsx"), "xlsx"))
            expected.append((try fx.srtFile("s.srt"), "srt"))
            expected.append((try fx.vttFile("s.vtt"), "vtt"))
            expected.append((try fx.htmlDoc("r.html"), "html"))
            expected.append((try fx.markdownDoc("r.md"), "md"))
            expected.append((try fx.unicodeCSV("t.csv"), "csv"))
            expected.append((try fx.unicodeCSV("t.tsv", delimiter: "\t"), "tsv"))
            expected.append((try fx.base.text("plain.txt", "Just some words.\nAnd a second line, with a comma.\nThird.\n"), "txt"))
            let tree = try fx.archiveSource("proj")
            _ = tree
            expected.append((try fx.base.zip("a.zip", items: ["proj"]), "zip"))
            expected.append((try fx.base.tarGz("a.tar.gz", items: ["proj"]), "tar.gz"))
            let video = try await fx.movingVideo("v.mp4", ConformanceFixtures.VideoSpec(seconds: 1))
            expected.append((video, "mp4"))
            let mov = try await fx.movingVideo("v.mov", ConformanceFixtures.VideoSpec(seconds: 1, audio: false))
            expected.append((mov, "mov"))
            if let mkv = fx.videoVariant(of: video, ext: "mkv") { expected.append((mkv, "mkv")) }
            if let webm = fx.videoVariant(of: video, ext: "webm") { expected.append((webm, "webm")) }
            if let avi = fx.videoVariant(of: video, ext: "avi") { expected.append((avi, "avi")) }
            var wrong: [String] = []
            for (url, key) in expected {
                let s = FormatSniffer.sniff(url)
                if s?.key != key { wrong.append("\(url.lastPathComponent): sniffed \(s?.description ?? "nil"), expected \(key)") }
            }
            try expect(wrong.isEmpty, "sniffer disagreements: \(wrong.joined(separator: "; "))")
            out("      sniffed \(expected.count) files correctly")
            // A rename must be caught: PNG bytes called .jpg, MP3 bytes called .m4a.
            let fake = fx.url("fake.jpg")
            try FileManager.default.copyItem(at: photo, to: fake)
            let s = try unwrap(FormatSniffer.sniff(fake))
            try expect(!FormatSniffer.agrees(extension: "jpg", with: s), "PNG bytes named .jpg must not agree with the jpg extension")
            try expectEqual(s.key, "png")
        }

        t.register("conformance.toolbox", "the sniffer reads codecs from MPEG-4 boxes and Ogg headers, and tells an audio-only MP4 from a video") {
            let fx = ConformanceFixtures(label: "sniff2")
            defer { fx.cleanup() }
            let clip = try await fx.movingVideo("v.mp4", ConformanceFixtures.VideoSpec(seconds: 1))
            let s = try unwrap(FormatSniffer.sniff(clip))
            try expectEqual(s.key, "mp4")
            try expect(s.hasVideo && s.hasAudio, "video clip should have both tracks: \(s)")
            try expect(s.codecs.contains("h264") && s.codecs.contains("aac"), "codecs should be h264 + aac, got \(s.codecs)")
            let wav = try fx.chirp("c.wav", seconds: 1)
            let m4a = try unwrap(fx.audioVariant(of: wav, ext: "m4a"), "afconvert should write m4a")
            let a = try unwrap(FormatSniffer.sniff(m4a))
            try expectEqual(a.key, "m4a")
            try expect(a.codecs.contains("aac") && !a.hasVideo, "m4a should hold AAC and no video: \(a)")
            if ToolLocator.shared.has(.ffmpeg) {
                if let opus = fx.audioVariant(of: wav, ext: "opus") { try expectEqual(try unwrap(FormatSniffer.sniff(opus)).codecs, ["opus"]) }
                if let mp3 = fx.audioVariant(of: wav, ext: "mp3") { try expectEqual(try unwrap(FormatSniffer.sniff(mp3)).key, "mp3") }
            }
        }

        t.register("conformance.toolbox", "image metrics: identical pictures score infinity, lower JPEG quality scores lower, resizing is detected, alpha survives only in formats that keep it") {
            let fx = ConformanceFixtures(label: "imgmetric")
            defer { fx.cleanup() }
            let png = try fx.photo("p.png")
            let a = try unwrap(ImageFidelity.decode(png))
            try expectEqual(ImageFidelity.psnr(a, a) ?? 0, Double.infinity)
            var scores: [Double] = []
            var sizes: [Int64] = []
            for q in [0.3, 0.6, 0.9] {
                let j = try fx.base.writeImage(fx.photoImage(), name: "q\(Int(q * 100)).jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: q])
                let c = try unwrap(ImageFidelity.compare(source: png, output: j))
                scores.append(c.psnr); sizes.append(TestFile.size(j))
                try expect(c.ssim > 0.5, "SSIM \(c.ssim) at q\(q)")
            }
            try expect(scores[0] < scores[1] && scores[1] < scores[2], "PSNR must rise with quality: \(scores)")
            try expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "size must rise with quality: \(sizes)")
            try expect(scores[2] > 24, "q90 of a photographic scene should exceed 24 dB, got \(scores[2])")
            let small = try fx.photo("small.png", width: 320, height: 240)
            try expect(ImageFidelity.compare(source: png, output: small) == nil, "different sizes need allowResize")
            let resized = try unwrap(ImageFidelity.compare(source: png, output: small, allowResize: true))
            try expect(!resized.sameSize && resized.psnr > 20 && resized.psnr < 60, "resized PSNR \(resized.psnr)")
            // Alpha: PNG keeps it, JPEG flattens it.
            let alphaPNG = try fx.photo("alpha.png", alpha: true)
            let keep = try unwrap(ImageFidelity.decode(alphaPNG))
            try expect(keep.hasTransparency && keep.transparentFraction > 0.05, "alpha fixture should have transparent pixels")
            let flat = try fx.base.writeImage(fx.photoImage(alpha: true), name: "alpha.jpg", type: .jpeg)
            try expect(!(try unwrap(ImageFidelity.decode(flat))).hasTransparency, "JPEG cannot carry alpha")
        }

        t.register("conformance.toolbox", "audio metrics: lossless round trips are bit-exact, AAC is close after alignment, a shifted or damaged copy is caught") {
            let fx = ConformanceFixtures(label: "audmetric")
            defer { fx.cleanup() }
            let wav = try fx.chirp("c.wav", seconds: 2)
            let ref = try unwrap(AudioFidelity.decode(wav))
            try expectEqual(ref.channelCount, 2)
            try expectEqual(ref.frames, 88_200)
            for ext in ["flac", "aiff", "caf"] {
                let u = try unwrap(fx.audioVariant(of: wav, ext: ext), "afconvert \(ext)")
                let d = try unwrap(AudioFidelity.decode(u))
                let r = AudioFidelity.bitExact(ref, d)
                try expect(r.equal, "\(ext) round trip is not bit-exact: \(r.detail)")
            }
            let m4a = try unwrap(fx.audioVariant(of: wav, ext: "m4a"))
            let aac = try unwrap(AudioFidelity.decode(m4a))
            let m = try unwrap(AudioFidelity.match(ref: ref, test: aac))
            out("      AAC 192k: \(m.summary)")
            try expect(m.snr > 8 && m.correlation > 0.95, "AAC should stay close to the source: \(m.summary)")
            try expect(!AudioFidelity.bitExact(ref, aac).equal, "lossy AAC cannot be bit-exact")
            // A damaged copy: every 50th sample zeroed.
            var damaged = ref
            for c in 0..<damaged.channelCount { for i in stride(from: 0, to: damaged.frames, by: 50) { damaged.channels[c][i] = 0 } }
            let dm = try unwrap(AudioFidelity.match(ref: ref, test: damaged))
            try expect(dm.snr < 40, "damage must be visible: \(dm.summary)")
            // A delayed copy is aligned before measuring.
            var delayed = ref
            for c in 0..<delayed.channelCount { delayed.channels[c] = [Float](repeating: 0, count: 1500) + ref.channels[c] }
            let dl = try unwrap(AudioFidelity.match(ref: ref, test: delayed))
            try expectEqual(dl.lag, 1500)
            try expect(dl.snr > 60, "an aligned delayed copy is identical: \(dl.summary)")
        }

        t.register("conformance.toolbox", "table, subtitle, archive and document readers recover the known content of generated files") {
            let fx = ConformanceFixtures(label: "docmetric")
            defer { fx.cleanup() }
            // CSV (quotes, commas, newlines in fields) and XLSX agree with the ground truth grid.
            let csv = try fx.unicodeCSV("t.csv", bom: true)
            let parsed = try unwrap(TableFidelity.readDelimited(csv))
            try expect(parsed.hasBOM && parsed.lineEnding == "\r\n" && parsed.delimiter == ",", "csv facts \(parsed.hasBOM) \(parsed.delimiter)")
            try expect(TableFidelity.difference(parsed.rows, ConformanceFixtures.unicodeTable) == nil, "csv grid: \(TableFidelity.difference(parsed.rows, ConformanceFixtures.unicodeTable) ?? "")")
            let xlsx = try fx.xlsx("t.xlsx")
            let sheets = try unwrap(TableFidelity.readXLSX(xlsx))
            try expectEqual(sheets.first?.name, "Data")
            let diff = TableFidelity.difference(sheets[0].rows, ConformanceFixtures.unicodeTable)
            try expect(diff == nil, "xlsx grid: \(diff ?? "")")
            try expect(TableFidelity.difference([["007"]], [["7"]]) != nil, "a leading zero is text, not the number 7")
            try expect(TableFidelity.difference([["42"]], [["42.0"]]) == nil, "42 equals 42.0")
            // Subtitles.
            let srt = try unwrap(SubtitleFidelity.read(try fx.srtFile("s.srt")))
            let vtt = try unwrap(SubtitleFidelity.read(try fx.vttFile("s.vtt")))
            try expect(SubtitleFidelity.difference(srt, ConformanceFixtures.cues) == nil, "srt: \(SubtitleFidelity.difference(srt, ConformanceFixtures.cues) ?? "")")
            try expect(SubtitleFidelity.difference(vtt, ConformanceFixtures.cues) == nil, "vtt: \(SubtitleFidelity.difference(vtt, ConformanceFixtures.cues) ?? "")")
            try expectEqual(SubtitleFidelity.plainLines(srt).count, 6)
            // Documents.
            let spec = ConformanceFixtures.docSpec
            for (name, doc) in [("docx", DocStructure.read(try fx.docx("r.docx"))), ("odt", DocStructure.read(try fx.odt("r.odt"))),
                                ("html", DocStructure.read(try fx.htmlDoc("r.html"))), ("md", DocStructure.read(try fx.markdownDoc("r.md")))] {
                let d = try unwrap(doc, "\(name) should be readable")
                try expectEqual(d.headings.map(\.level), spec.headings.map(\.level), "\(name) heading levels")
                try expectEqual(d.headings.map(\.text), spec.headings.map(\.text), "\(name) heading text")
                try expectEqual(d.listItems, spec.listItems, "\(name) list items")
                try expectEqual(d.tables.first ?? [], spec.tableRows, "\(name) table")
                try expect(TextCompare.wordRecall(expected: spec.words, actual: d.text) > 0.97, "\(name) text recall \(TextCompare.wordRecall(expected: spec.words, actual: d.text))")
            }
            // PDF: known text per page comes back from PDFKit.
            let pdf = try fx.richPDF("d.pdf", pages: 3)
            let facts = try unwrap(PDFReader.facts(pdf.url))
            try expectEqual(facts.pageCount, 3)
            for (i, expectedText) in pdf.pages.enumerated() {
                let r = TextCompare.wordRecall(expected: expectedText, actual: facts.pageText[i])
                try expect(r > 0.97, "page \(i + 1) recall \(r)")
            }
        }


        t.register("conformance.toolbox", "readers and sniffer on awkward input: empty and random files, truncated PNG, huge ID3 tag, RFC 4180 corner cases, subtitle time forms, zip CRC, word order") {
            let fx = ConformanceFixtures(label: "edge")
            defer { fx.cleanup() }
            // Sniffer.
            try expect(FormatSniffer.sniff(try fx.base.text("empty.bin", "")) == nil, "an empty file has no format")
            var rng = SplitMix(seed: 5)
            let random = Data((0..<256).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            let rf = fx.url("random.dat"); try random.write(to: rf)
            try expectEqual(try unwrap(FormatSniffer.sniff(rf)).key, "bin")
            let png = try fx.photo("p.png")
            let cut = fx.url("cut.png"); try Data(contentsOf: png).prefix(80).write(to: cut)
            let cutSniff = try unwrap(FormatSniffer.sniff(cut))
            try expect(cutSniff.key == "png" && cutSniff.detail.contains("truncated"), "a cut PNG is a truncated PNG, got \(cutSniff)")
            let utf16 = fx.url("u16.txt"); try ("\u{FEFF}Привет, мир\nвторая строка\n".data(using: .utf16LittleEndian)!).write(to: utf16)
            try expectEqual(try unwrap(FormatSniffer.sniff(utf16)).key, "txt")
            if let mp3 = fx.audioVariant(of: try fx.chirp("c.wav", seconds: 1), ext: "mp3") {
                // An ID3v2 tag of 20 KB pushes the first audio frame far beyond the sniffed head.
                var tag = Data("ID3".utf8); tag.append(contentsOf: [3, 0, 0]); let size = 20_000
                tag.append(contentsOf: [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
                tag.append(Data(count: size))
                let big = fx.url("bigid3.mp3"); try (tag + (try Data(contentsOf: mp3))).write(to: big)
                try expectEqual(try unwrap(FormatSniffer.sniff(big)).key, "mp3", "frames after a 20 KB tag")
            }
            // RFC 4180.
            let rows = TableFidelity.parseDelimited("a;\"b;c\";\"d\"\"e\"\r\n\"multi\nline\";2;3", delimiter: ";")
            try expectEqual(rows.count, 2)
            try expectEqual(rows[0], ["a", "b;c", "d\"e"])
            try expectEqual(rows[1][0], "multi\nline")
            try expectEqual(TableFidelity.parseDelimited("x,,z\r", delimiter: ",").first ?? [], ["x", "", "z"])
            try expectEqual(TableFidelity.parseDelimited("a,b\n1,2\n", delimiter: ",").count, 2)
            try expectEqual(TableFidelity.parseDelimited("1\r2\r3", delimiter: ",").count, 3, "CR-only line ends")
            // Subtitle time forms.
            try expectEqual(SubtitleFidelity.seconds("01:15.500"), 75.5)
            try expectEqual(SubtitleFidelity.seconds("1:02:03,5"), 3723.5)
            let ass = "[Script Info]\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,Hello, {\\i1}world{\\i0}\\Nsecond line\n"
            let cue = try unwrap(SubtitleFidelity.parse(ass).first)
            try expect(cue.start == 1 && cue.end == 2.5 && cue.text == "Hello, world\nsecond line", "ASS dialogue with commas and override tags: \(cue)")
            // ZIP: stored and deflated members read back with their CRC checked; a damaged byte is refused.
            let zip = try fx.base.zip("z.zip", items: ["c.wav"])
            let entry = try unwrap(ZipProbe.entries(zip)?.first)
            try expect(ZipProbe.read(entry, from: zip)?.count == Int(entry.size), "deflated member reads back")
            var bytes = try Data(contentsOf: zip)
            bytes[Int(entry.localHeaderOffset) + 30 + entry.name.utf8.count + 40] ^= 0xFF
            let damaged = fx.url("damaged.zip"); try bytes.write(to: damaged)
            try expect(ZipProbe.read(entry, from: damaged) == nil, "a member with a wrong CRC is refused")
            // Word order matters; extra words do not.
            try expectEqual(TextCompare.wordRecall(expected: "one two three", actual: "zero one two and three four"), 1.0)
            try expect(TextCompare.wordRecall(expected: "one two three", actual: "three two one") < 0.5, "reordered words lose recall")
            try expectEqual(TextCompare.wordRecall(expected: "", actual: "anything"), 1.0)
            // Fixtures are deterministic.
            try expect(ConformanceFixtures(label: "d1").photoImage(width: 64, height: 48, seed: 3).dataProvider?.data as Data? == ConformanceFixtures(label: "d2").photoImage(width: 64, height: 48, seed: 3).dataProvider?.data as Data?, "the same seed gives the same picture")
        }

        t.register("conformance.toolbox", "archive tools: the tree diff sees changed bytes and permissions, the zip-slip check flags hostile member names") {
            let fx = ConformanceFixtures(label: "arcmetric")
            defer { fx.cleanup() }
            let src = try fx.archiveSource("proj")
            let zip = try fx.base.zip("a.zip", items: ["proj"])
            let tgz = try fx.base.tarGz("a.tar.gz", items: ["proj"])
            let original = ArchiveFidelity.tree(src)
            try expect(original.contains { $0.path == "proj/readme.txt" || $0.path == "readme.txt" }, "tree lists files")
            for (name, archive) in [("zip", zip), ("tar.gz", tgz)] {
                let ex = try unwrap(ArchiveFidelity.extractedTree(archive), "\(name) extracts")
                defer { AppPaths.removeTemp(ex.root) }
                let inner = ex.root.appendingPathComponent("proj")
                let d = ArchiveFidelity.differences(expected: original, actual: ArchiveFidelity.tree(inner))
                try expect(d.isEmpty, "\(name) round trip differs: \(d)")
            }
            // Changing one byte and one permission bit shows up.
            let altered = original.map { e -> TreeEntry in
                var x = e
                if x.path == "readme.txt" { x.sha256 = "0" }
                if x.path == "bin/run.sh" { x.mode = 0o644 }
                return x
            }
            let diffs = ArchiveFidelity.differences(expected: original, actual: altered)
            try expect(diffs.contains { $0.contains("bytes differ: readme.txt") } && diffs.contains { $0.contains("permissions differ: bin/run.sh") }, "diffs: \(diffs)")
            let hostile = try fx.hostileZip()
            let unsafe = ArchiveFidelity.unsafeMemberNames(hostile)
            try expect(unsafe.contains("../evil.txt") && unsafe.contains("/tmp/swamp-evil-abs.txt") && unsafe.contains("a/../../evil2.txt") && !unsafe.contains("safe/ok.txt"), "unsafe names: \(unsafe)")
            try expect(ZipProbe.entries(hostile)?.count == 4, "the hand-built zip has a readable central directory")
            try expect(ExternalProbe.zipIsIntact(hostile).ok, "unzip -t accepts the hand-built zip: \(ExternalProbe.zipIsIntact(hostile).message)")
        }
    }
}
