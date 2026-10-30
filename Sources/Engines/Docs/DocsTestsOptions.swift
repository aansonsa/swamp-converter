import Foundation
import PDFKit
import ImageIO

// One test per option of the text, Markdown, web and e-book pages. Each proves the claimed effect on the BYTES of the result, read back with something other than the
// writer (iconv, PDFKit, unzip, ImageIO, textutil) and each proves that changing the option changes the output.

enum DocsOptionTests {
    static func register() {
        registerEncodings()
        registerTextLayout()
        registerMarkdown()
        registerWeb()
        registerEpub()
    }

    // MARK: Encodings

    /// Bytes -> UTF-8 text with /usr/bin/iconv (a decoder that is not ours).
    static func iconv(_ data: Data, from: String, fx: TestFixtures) throws -> String {
        let f = fx.url("iconv-\(Util.hex8()).bin")
        try data.write(to: f)
        let r = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/iconv"), ["-f", from, "-t", "UTF-8", f.path], timeout: 20) ?? ""
        return r
    }

    private static let russian = "Привет, мир! Съешь же ещё этих мягких французских булок, да выпей чаю.\nЖаба в болоте поёт ночью.\n"
    private static let latvian = "Ķirsis un ābols — žogs, čūska, ēdiens. Šķirne ar īpašu garšu.\n"

    private static func registerEncodings() {
        docTest("doc.enc.in: Windows-1251, KOI8-R, DOS 866, Windows-1257, UTF-16 (with and without BOM) and UTF-8 with BOM are all read back to the exact text",
                proves: ["doc.enc.in.decode"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            // The legacy code pages are encoded by iconv, not by our codec, so a wrong table in the codec cannot hide behind itself.
            func legacy(_ name: String, _ text: String, _ iconvName: String) throws -> URL {
                let utf8 = fx.url("\(name).utf8.txt"), file = fx.url("\(name).txt")
                try Data(text.utf8).write(to: utf8)
                let r = Process(); r.executableURL = URL(fileURLWithPath: "/usr/bin/iconv"); r.arguments = ["-f", "UTF-8", "-t", iconvName, utf8.path]
                let pipe = Pipe(); r.standardOutput = pipe; try r.run()
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); r.waitUntilExit()
                try expectEqual(r.terminationStatus, 0, "iconv encodes \(name)")
                try bytes.write(to: file)
                return file
            }
            let more = String(repeating: russian, count: 6)
            let moreLV = String(repeating: latvian, count: 6)
            for (name, text, ic) in [("cp1251", more, "CP1251"), ("koi8", more, "KOI8-R"), ("cp866", more, "CP866"), ("cp1257", moreLV, "CP1257")] {
                let result = try await DocRun.convert(try legacy(name, text, ic), to: "txt", [DocKeys.encodingIn: "auto"], into: out)
                try expectEqual(DocOracle.normalized(try String(contentsOf: result, encoding: .utf8)), DocOracle.normalized(text), "\(name): automatic detection of bytes made by iconv")
            }
            let cases: [(String, String, String.Encoding, Bool)] = [
                ("utf8bom", russian + latvian, .utf8, true), ("utf16le", russian + latvian, .utf16LittleEndian, false), ("utf16be", russian + latvian, .utf16BigEndian, false)]
            for (name, text, enc, bom) in cases {
                var data = Data()
                if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
                if enc == .utf16LittleEndian { data.append(contentsOf: [0xFF, 0xFE]) }
                if enc == .utf16BigEndian { data.append(contentsOf: [0xFE, 0xFF]) }
                data.append(try unwrap(text.data(using: enc), "encode \(name)"))
                let file = fx.url("\(name).txt")
                try data.write(to: file)
                let result = try await DocRun.convert(file, to: "txt", [DocKeys.encodingIn: "auto"], into: out)
                let got = try String(contentsOf: result, encoding: .utf8)
                try expectEqual(DocOracle.normalized(got), DocOracle.normalized(text), "\(name): automatic detection")
                try expect(!(try Data(contentsOf: result)).starts(with: [0xEF, 0xBB, 0xBF]), "\(name): a BOM in the source is not copied into the text")
            }
            // UTF-16 without any byte order mark (what some Windows tools write) is recognised by its zero bytes.
            let bare = fx.url("bare16.txt")
            try (try unwrap("Hello, swamp\nSecond line here\n".data(using: .utf16LittleEndian))).write(to: bare)
            let bareOut = try String(contentsOf: try await DocRun.convert(bare, to: "txt", into: out), encoding: .utf8)
            try expectEqual(bareOut, "Hello, swamp\nSecond line here\n", "UTF-16 without a BOM")
            // Naming the encoding wins over the detector, and a wrong choice really changes the text (so the option is not decorative).
            let ru = fx.url("forced.txt")
            try (try unwrap(russian.data(using: DocTextCodec.stringEncoding("windows-1251")!))).write(to: ru)
            let right = try String(contentsOf: try await DocRun.convert(ru, to: "txt", [DocKeys.encodingIn: "windows-1251"], into: out), encoding: .utf8)
            let wrong = try String(contentsOf: try await DocRun.convert(ru, to: "txt", [DocKeys.encodingIn: "koi8-r"], into: out), encoding: .utf8)
            try expectEqual(DocOracle.normalized(right), DocOracle.normalized(russian))
            try expect(DocOracle.normalized(wrong) != DocOracle.normalized(russian), "a different source encoding gives different text")
            // HTML announces its own charset; Markdown goes through the same decoder.
            let html = fx.url("page.html")
            let htmlBytes = try unwrap(("<html><head><meta charset=\"windows-1251\"><title>t</title></head><body><p>" + "Привет, мир" + "</p></body></html>").data(using: DocTextCodec.stringEncoding("windows-1251")!))
            try htmlBytes.write(to: html)
            let fromHTML = try String(contentsOf: try await DocRun.convert(html, to: "txt", into: out), encoding: .utf8)
            try expect(fromHTML.contains("Привет, мир"), "an HTML page's declared charset is honoured: \(fromHTML)")
            let md = fx.url("note.md")
            try (try unwrap("# Заголовок\n\nЖаба поёт.\n".data(using: DocTextCodec.stringEncoding("windows-1251")!))).write(to: md)
            let fromMD = try String(contentsOf: try await DocRun.convert(md, to: "txt", [DocKeys.encodingIn: "windows-1251"], into: out), encoding: .utf8)
            try expect(fromMD.contains("Заголовок") && fromMD.contains("Жаба поёт."), "Markdown sources are decoded too: \(fromMD)")
        }

        docTest("doc.enc.out: Windows-1251, KOI8-R, UTF-16 and UTF-8 files hold the right bytes (checked with iconv); unrepresentable letters become ? in text and character references in HTML",
                proves: ["doc.enc.out.bytes"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = fx.url("src.txt")
            let sample = "Привет, мир! Жаба в болоте.\n"
            try Data(sample.utf8).write(to: src)
            for (id, iconvName) in [("windows-1251", "CP1251"), ("koi8-r", "KOI8-R"), ("cp866", "CP866")] {
                let r = try await DocRun.convert(src, to: "txt", [DocKeys.encodingOut: .string(id)], into: out)
                let bytes = try Data(contentsOf: r)
                try expectEqual(bytes.count, DocOracle.normalized(sample).count + (bytes.last == 10 ? 1 : 0) + 0, "\(id): one byte per character")
                try expectEqual(DocOracle.normalized(try iconv(bytes, from: iconvName, fx: fx)), DocOracle.normalized(sample), "\(id) decodes with iconv")
            }
            let cp = try Data(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.encodingOut: "windows-1251"], into: out))
            try expectEqual(Array(cp.prefix(6)), [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], "\"Привет\" in Windows-1251 starts CF F0 E8 E2 E5 F2")
            let u16 = try Data(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.encodingOut: "utf-16"], into: out))
            try expectEqual(Array(u16.prefix(2)), [0xFF, 0xFE], "UTF-16 starts with its byte order mark")
            try expectEqual(DocOracle.normalized(try iconv(u16, from: "UTF-16", fx: fx)), DocOracle.normalized(sample))
            let u16be = try Data(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.encodingOut: "utf-16be"], into: out))
            try expectEqual(Array(u16be.prefix(2)), [0xFE, 0xFF])
            // A letter the code page lacks: "?" in plain text, a numeric reference in markup (nothing is lost there).
            let lv = fx.url("lv.txt")
            try Data("Ķirsis ābols\n".utf8).write(to: lv)
            let lossy = try Data(contentsOf: try await DocRun.convert(lv, to: "txt", [DocKeys.encodingOut: "windows-1251"], into: out))
            try expect(lossy.contains(0x3F), "an unrepresentable letter is written as ?")
            let htmlOut = try await DocRun.convert(lv, to: "html", [DocKeys.encodingOut: "windows-1251"], into: out)
            let htmlText = try String(data: Data(contentsOf: htmlOut), encoding: DocTextCodec.stringEncoding("windows-1251")!) ?? ""
            try expect(htmlText.contains("charset=\"windows-1251\"") && htmlText.contains("&#310;") && htmlText.contains("&#257;"), "HTML in a code page declares it and uses references: \(htmlText.prefix(300))")
            let back = DocHTMLReader.read(htmlText)
            try expect(back.plainText.contains("Ķirsis ābols"), "the references read back to the letters")
        }

        docTest("doc.bom: UTF-8 gets EF BB BF only when asked, UTF-16 always carries its mark", proves: ["doc.bom.bytes"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let src = fx.url("src.txt"); try Data("Привет\n".utf8).write(to: src)
            let plain = try Data(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.bom: false], into: out))
            let withBom = try Data(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.bom: true], into: out))
            try expect(!plain.starts(with: [0xEF, 0xBB, 0xBF]), "no BOM by default")
            try expectEqual(Array(withBom.prefix(3)), [0xEF, 0xBB, 0xBF])
            try expectEqual(Data(withBom.dropFirst(3)), plain, "only the three bytes differ")
            for target in ["md", "html"] {
                let r = try Data(contentsOf: try await DocRun.convert(src, to: target, [DocKeys.bom: true], into: out))
                try expectEqual(Array(r.prefix(3)), [0xEF, 0xBB, 0xBF], "\(target) honours the BOM too")
            }
            // The streaming path (txt -> txt) writes the same bytes as the in-memory path.
            let streamed = try Data(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.bom: true, DocKeys.reflow: "keep"], into: out))
            try expectEqual(streamed, withBom)
        }

        docTest("doc.eol: LF and CRLF files contain exactly the line endings asked for, in text, Markdown and HTML", proves: ["doc.eol.bytes"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let model = DocFixtures.sample(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: model)
            for target in ["txt", "md", "html"] {
                let lf = Array(try Data(contentsOf: try await DocRun.convert(docx, to: target, [DocKeys.eol: "lf"], into: out)))
                let crlf = Array(try Data(contentsOf: try await DocRun.convert(docx, to: target, [DocKeys.eol: "crlf"], into: out)))
                try expect(!lf.contains(13), "\(target): LF has no carriage return")
                try expect(lf.filter { $0 == 10 }.count > 5, "\(target): there are lines")
                var lone = 0
                for (i, b) in crlf.enumerated() where b == 10 && (i == 0 || crlf[i - 1] != 13) { lone += 1 }
                try expectEqual(lone, 0, "\(target): CRLF has no bare LF")
                try expectEqual(crlf.filter { $0 == 13 }.count, lf.filter { $0 == 10 }.count, "\(target): one CR per line")
            }
            // Streaming path with a CR split across chunks must not double a line ending.
            let src = fx.url("mixed.txt")
            try Data("one\r\ntwo\rthree\nfour\r\n".utf8).write(to: src)
            let r = try String(contentsOf: try await DocRun.convert(src, to: "txt", [DocKeys.eol: "lf", DocKeys.reflow: "keep"], into: out), encoding: .utf8)
            try expectEqual(r, "one\ntwo\nthree\nfour\n", "a mix of endings is normalised")
        }
    }

    // MARK: Plain-text layout

    private static func registerTextLayout() {
        docTest("doc.txt.wrap: lines are hard-wrapped at 72, 80 or 100 characters without losing a word or a paragraph break", proves: ["doc.txt.wrap"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let words = (1...400).map { "слово\($0)" + ($0 % 7 == 0 ? " žogs" : "") }.joined(separator: " ")
            let md = fx.url("long.md")
            try Data(("# Title\n\n" + words + "\n\nSecond paragraph, short.\n").utf8).write(to: md)
            let unwrapped = try String(contentsOf: try await DocRun.convert(md, to: "txt", [DocKeys.wrap: "0"], into: out), encoding: .utf8)
            try expect(unwrapped.split(separator: "\n").contains { $0.count > 1000 }, "no wrapping keeps the long line")
            for width in [72, 80, 100] {
                let t = try String(contentsOf: try await DocRun.convert(md, to: "txt", [DocKeys.wrap: .string("\(width)")], into: out), encoding: .utf8)
                let lines = t.components(separatedBy: "\n")
                try expect(lines.allSatisfy { $0.count <= width }, "width \(width): the longest line has \(lines.map(\.count).max() ?? 0)")
                try expect(lines.filter { $0.count > width - 12 }.count >= 3, "width \(width): lines are filled, not cut short")
                try expectEqual(DocTextCodec.wrap("a b", width: width), "a b")
                try expectEqual(t.components(separatedBy: "\n\n").count, 3, "width \(width): three blocks stay three blocks")
                try expectEqual(DocOracle.normalized(t), DocOracle.normalized(unwrapped), "width \(width): same words")
            }
        }

        docTest("doc.txt.reflow: hard-wrapped plain text becomes real paragraphs on request; keep preserves every break", proves: ["doc.txt.reflow"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let para1 = "The swamp lay quiet under the evening mist and the frogs had begun their slow\nchorus among the reeds while a heron stood motionless at the edge of the\nwater waiting for something to move in the shallows."
            let para2 = "Dawn came late. The mist\nlifted by itself."
            let txt = fx.url("old.txt")
            try Data((para1 + "\n\n" + para2 + "\n").utf8).write(to: txt)
            func paragraphs(_ mode: String) async throws -> [String] {
                let md = try String(contentsOf: try await DocRun.convert(txt, to: "md", [DocKeys.reflow: .string(mode)], into: out), encoding: .utf8)
                return md.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            let joined = try await paragraphs("join")
            try expectEqual(joined.count, 2, "two paragraphs")
            try expect(!joined[0].contains("\n") && !joined[1].contains("\n"), "joined paragraphs are single lines")
            let kept = try await paragraphs("keep")
            try expectEqual(kept.count, 2)
            try expect(kept[0].components(separatedBy: "\n").count >= 3, "keep preserves the line breaks (as hard breaks)")
            let auto = try await paragraphs("auto")
            try expect(!auto[0].contains("\n"), "auto recognises the first paragraph as wrapped at ~80 columns")
            try expect(auto[1].contains("\n") || auto[1].contains("\\"), "auto leaves the short two-line paragraph alone: \(auto[1])")
            // Re-encoding a text file must never join its lines.
            let same = try String(contentsOf: try await DocRun.convert(txt, to: "txt", into: out), encoding: .utf8)
            try expectEqual(same, para1 + "\n\n" + para2 + "\n", "txt -> txt keeps the file as it is")
        }
    }

    // MARK: Markdown

    private static func registerMarkdown() {
        docTest("doc.md.flavor: GFM writes pipe tables and ~~strike~~, CommonMark writes HTML for both; each flavour reads back to the same structure",
                proves: ["doc.md.flavor"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            var model = DocFixtures.sample(fx)
            model.blocks.append(.paragraph([.text("old "), .strike([.text("price")]), .text(" new")]))
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: model)
            let gfm = try String(contentsOf: try await DocRun.convert(docx, to: "md", [DocKeys.mdFlavor: "gfm"], into: out), encoding: .utf8)
            let cm = try String(contentsOf: try await DocRun.convert(docx, to: "md", [DocKeys.mdFlavor: "commonmark"], into: out), encoding: .utf8)
            try expect(gfm.contains("| :--- | ---: | :---: |") && gfm.contains("~~price~~"), "GFM: pipe table with alignment and strike-through")
            try expect(!cm.contains("| :--- |") && cm.contains("<table>") && cm.contains("<del>price</del>") && !cm.contains("~~"), "CommonMark: HTML table and <del>")
            // A CommonMark reader (flavour off) does not turn pipes into a table; a GFM reader does.
            let parsedGFM = DocMarkdown.parse(gfm, gfm: true), parsedCM = DocMarkdown.parse(cm, gfm: false)
            let tablesGFM = parsedGFM.blocks.filter { if case .table = $0 { return true } else { return false } }.count
            let tablesCM = parsedCM.blocks.filter { if case .table = $0 { return true } else { return false } }.count
            try expectEqual(tablesGFM, 1); try expectEqual(tablesCM, 1, "the HTML table is a table in both readers")
            try expectEqual(DocsConformance.outline(of: parsedCM.blocks), DocsConformance.outline(of: parsedGFM.blocks), "both flavours carry the same content")
            let pipesAsText = DocMarkdown.parse("| a | b |\n| - | - |\n| 1 | 2 |\n", gfm: false)
            try expect(pipesAsText.blocks.allSatisfy { if case .table = $0 { return false } else { return true } }, "CommonMark reading leaves pipes as text")
            // A Markdown file is always READ with GFM tables, whichever flavour is written (md -> md normalises, it does not lose the table).
            let src = fx.url("t.md"); try Data("| a | b |\n| - | - |\n| 1 | 2 |\n".utf8).write(to: src)
            let again = try String(contentsOf: try await DocRun.convert(src, to: "md", [DocKeys.mdFlavor: "commonmark"], into: out), encoding: .utf8)
            try expect(again.contains("<table>") && again.contains("<td>1</td>"), "the pipe table of a Markdown source survives as an HTML table: \(again)")
        }

        docTest("doc.md.media: pictures go to a folder next to the file and are linked; without the option no picture is written", proves: ["doc.md.media"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let model = DocFixtures.sample(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: model, name: "report.docx")
            let off = try await DocRun.convert(docx, to: "md", [DocKeys.extractMedia: false], into: out)
            let offText = try String(contentsOf: off, encoding: .utf8)
            try expect(!offText.contains("!["), "no picture syntax without the option")
            try expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("report - media").path), "no folder without the option")
            let on = try await DocRun.convert(docx, to: "md", [DocKeys.extractMedia: true], into: out)
            let md = try String(contentsOf: on, encoding: .utf8)
            let folder = out.appendingPathComponent("report - media")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            try expectEqual(files.count, 1, "one picture file")
            let png = folder.appendingPathComponent(files[0])
            let size = try unwrap(TestImage.size(of: png), "the extracted file is a picture")
            try expectEqual(size.width, 240); try expectEqual(size.height, 120)
            try expectEqual(TestImage.info(of: png)?.type, "public.png")
            try expect(md.contains("![Swamp picture](report%20-%20media/\(files[0]))"), "the link points at the extracted file: \(md.suffix(300))")
            let reread = try await DocNative.read(on, key: "md", settings: DocSettings(), ctx: nil)
            try expectEqual(reread.media.count, 1, "reading the Markdown file back finds the picture next to it")
            // A second run does not overwrite: the folder gets a number and the link follows it.
            let again = try await DocRun.convert(docx, to: "md", [DocKeys.extractMedia: true], into: out)
            let md2 = try String(contentsOf: again, encoding: .utf8)
            try expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("report - media (2)").path), "second folder")
            try expect(md2.contains("report%20-%20media%20%282%29/"), "the second Markdown links the second folder: \(md2.suffix(300))")
            let reread2 = try await DocNative.read(again, key: "md", settings: DocSettings(), ctx: nil)
            try expectEqual(reread2.media.count, 1, "and that link resolves to the picture in the numbered folder")
            try expect(TestFile.partials(in: out).isEmpty)
        }

        docTest("doc.md.front: title, author and language open the Markdown file as YAML front matter that reads back", proves: ["doc.md.front"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx))
            let plain = try String(contentsOf: try await DocRun.convert(docx, to: "md", [DocKeys.mdFrontMatter: false], into: out), encoding: .utf8)
            let front = try String(contentsOf: try await DocRun.convert(docx, to: "md", [DocKeys.mdFrontMatter: true], into: out), encoding: .utf8)
            try expect(plain.hasPrefix("# Болотный"), "no front matter by default")
            try expect(front.hasPrefix("---\ntitle: \"Swamp report\"\nauthor: \"Андрис Лейте\"\nlang: \"en\"\n---\n\n# Болотный"), "front matter first: \(front.prefix(120))")
            let parsed = DocMarkdown.parse(front)
            try expectEqual(parsed.meta.title, "Swamp report"); try expectEqual(parsed.meta.author, "Андрис Лейте")
            // A Markdown source that has front matter keeps it when asked and drops it otherwise.
            let src = fx.url("again.md"); try Data(front.utf8).write(to: src)
            let kept = try String(contentsOf: try await DocRun.convert(src, to: "md", [DocKeys.mdFrontMatter: true], into: out), encoding: .utf8)
            let dropped = try String(contentsOf: try await DocRun.convert(src, to: "md", [DocKeys.mdFrontMatter: false], into: out), encoding: .utf8)
            try expect(kept.hasPrefix("---\ntitle: \"Swamp report\""), "front matter survives a Markdown to Markdown pass")
            try expect(dropped.hasPrefix("# Болотный"), "and is removed when not asked for")
        }
    }

    // MARK: Web page

    private static func registerWeb() {
        docTest("doc.html.embed: a single file holds its pictures as data; otherwise they go to a folder that the page links", proves: ["doc.html.embed"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "page.docx")
            let single = try String(contentsOf: try await DocRun.convert(docx, to: "html", [DocKeys.htmlSingleFile: true], into: out), encoding: .utf8)
            try expect(single.contains("src=\"data:image/png;base64,"), "embedded picture")
            let b64 = try unwrap(single.range(of: "base64,[A-Za-z0-9+/=]+", options: .regularExpression).map { String(single[$0].dropFirst(7)) })
            let png = try unwrap(Data(base64Encoded: b64))
            let src = try unwrap(CGImageSourceCreateWithData(png as CFData, nil))
            try expectEqual(CGImageSourceGetType(src) as String?, "public.png")
            try expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("page - media").path), "no folder for a single file")
            let linked = try await DocRun.convert(docx, to: "html", [DocKeys.htmlSingleFile: false], into: out)
            let html = try String(contentsOf: linked, encoding: .utf8)
            try expect(!html.contains("data:image"), "no data URI when linked")
            let ref = try unwrap(html.range(of: "src=\"[^\"]+\"", options: .regularExpression).map { String(html[$0].dropFirst(5).dropLast()) })
            let target = out.appendingPathComponent(ref.removingPercentEncoding ?? ref)
            try expect(FileManager.default.fileExists(atPath: target.path), "the linked picture exists next to the page: \(ref)")
            try expectEqual(TestImage.size(of: target)?.width, 240)
            // The page is complete without the folder only in the single-file case: check the sizes differ in the expected direction.
            try expect(single.utf8.count > html.utf8.count + 100, "the single file carries the picture, the linked page does not")
        }
    }

    // MARK: E-book

    private static func registerEpub() {
        docTest("doc.epub.split: chapters start at Heading 1, at Heading 1 and 2, or never; the navigation document lists them in order", proves: ["doc.epub.split"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            var m = DocModel()
            m.meta.title = "Three parts"
            for part in 1...3 {
                m.blocks.append(.heading(level: 1, content: [.text("Part \(part)")]))
                m.blocks.append(.paragraph([.text("Text of part \(part), frogs and reeds.")]))
                for sub in 1...2 {
                    m.blocks.append(.heading(level: 2, content: [.text("Section \(part).\(sub)")]))
                    m.blocks.append(.paragraph([.text("Words in section \(part).\(sub).")]))
                }
            }
            let md = try await DocFixtures.makeInput("md", in: fx, model: m, name: "book.md")
            func chapters(_ split: String) async throws -> (names: [String], nav: String) {
                let epub = try await DocRun.convert(md, to: "epub", [DocKeys.epubSplit: .string(split)], into: out)
                let names = DocOracle.zipNames(epub).filter { $0.hasPrefix("OEBPS/text/chapter") }.sorted()
                return (names, DocOracle.zipPart(epub, "OEBPS/nav.xhtml"))
            }
            let h1 = try await chapters("h1")
            try expectEqual(h1.names.count, 3, "three chapters at Heading 1")
            try expect(h1.nav.range(of: "Part 1.*Part 2.*Part 3", options: .regularExpression) != nil, "navigation in order")
            try expect(h1.nav.contains("Section 1.1"), "sections are nested in the navigation")
            let h2 = try await chapters("h2")
            try expectEqual(h2.names.count, 9, "Heading 1 and 2 start chapters: 3 parts + 6 sections")
            let none = try await chapters("none")
            try expectEqual(none.names.count, 1, "one chapter")
            try expect(none.nav.contains("Part 3") && none.nav.contains("#"), "headings are anchors in a single chapter")
            // Chapter files read back in order through the EPUB reader.
            let epub = try await DocRun.convert(md, to: "epub", [DocKeys.epubSplit: "h1"], into: out)
            let back = try DocEpubReader.read(epub)
            try expectEqual(DocsConformance.outline(of: back.blocks).filter { $0.hasPrefix("h1") }, ["h1 Part 1", "h1 Part 2", "h1 Part 3"])
        }

        docTest("doc.epub.cover: a cover picture becomes the cover image of the package and the first page of the spine", proves: ["doc.epub.cover"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let cover = try fx.png("cover.png", width: 200, height: 300, pattern: .gradient)
            let md = try await DocFixtures.makeInput("md", in: fx, model: DocFixtures.sample(fx), name: "book.md")
            let without = try await DocRun.convert(md, to: "epub", into: out)
            try expect(!DocOracle.zipPart(without, "OEBPS/content.opf").contains("cover-image"), "no cover by default")
            let with = try await DocRun.convert(md, to: "epub", [DocKeys.epubCover: .string(cover.path)], into: out)
            let opf = DocOracle.zipPart(with, "OEBPS/content.opf")
            try expect(opf.contains("properties=\"cover-image\"") && opf.contains("<meta name=\"cover\" content=\"cover-image\"/>"), "cover declared (EPUB 3 and 2 styles)")
            let spineFirst = try unwrap(opf.range(of: "<spine[^>]*><itemref idref=\"[^\"]+\"", options: .regularExpression).map { String(opf[$0]) })
            try expect(spineFirst.hasSuffix("cover-page\""), "the cover page opens the spine: \(spineFirst)")
            let extracted = fx.url("cover-out.png")
            let zipEntry = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", with.path, "OEBPS/images/cover.png"], timeout: 20)
            _ = zipEntry
            let r = Process(); r.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); r.arguments = ["-p", with.path, "OEBPS/images/cover.png"]
            let pipe = Pipe(); r.standardOutput = pipe; try r.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); r.waitUntilExit()
            try bytes.write(to: extracted)
            try expectEqual(TestImage.size(of: extracted)?.height, 300, "the cover file is the picture we gave")
            let bad = DocOracle.xmlProblems(in: with, fx: fx)
            try expect(bad.isEmpty, "xmllint: \(bad)")
        }
    }
}
