import Foundation
import PDFKit

// Conformance: one oracle per operation of the catalogue. Each oracle decodes the SOURCE and the RESULT with tools that did not write them (python's csv / zipfile / tarfile
// / xml, `file`, PDFKit, libarchive, LibreOffice when installed), compares the content, and checks that the output really is the format its extension says and is not a copy of
// the input. `conformance.data/catalogue` fails when an operation has no oracle or an oracle names an operation that does not exist.

@MainActor
enum DataConformance {
    typealias Oracle = (TestFixtures) async throws -> Void

    static let table: [String: Oracle] = [
        "sheet.to.xlsx": sheetToXLSX, "sheet.to.csv": sheetToCSV, "sheet.to.tsv": sheetToTSV, "sheet.to.ods": sheetToODS, "sheet.to.pdf": sheetToPDF,
        "subs.to.srt": subsToSRT, "subs.to.vtt": subsToVTT, "subs.to.txt": subsToTXT,
        "archive.extract": archiveExtract, "archive.to.zip": { try await repack($0, to: "zip") }, "archive.to.tar": { try await repack($0, to: "tar") }, "archive.to.tar.gz": { try await repack($0, to: "tar.gz") },
        "pack.zip": { try await pack($0, "pack.zip") }, "pack.tar.gz": { try await pack($0, "pack.tar.gz") }
    ]

    /// The operation ids that have an oracle (the `table` keys; kept as a plain list so registering the tests needs no main-actor access).
    nonisolated static let ids = ["sheet.to.xlsx", "sheet.to.csv", "sheet.to.tsv", "sheet.to.ods", "sheet.to.pdf", "subs.to.srt", "subs.to.vtt", "subs.to.txt",
                                  "archive.extract", "archive.to.zip", "archive.to.tar", "archive.to.tar.gz", "pack.zip", "pack.tar.gz"]

    nonisolated static func register() {
        for id in ids {
            let suite = "conformance.data." + id.split(separator: ".").first!
            dataTest(suite, id, timeout: 240) { try await table[id]!(TestFixtures()) }
        }
        dataTest("conformance.data", "catalogue: every operation has an oracle and every oracle belongs to an operation") {
            let ids: Set<String> = Set((SheetCatalog.operations() + SubsCatalog.operations() + ArchiveCatalog.operations()).map(\.meta.id))
            let catalogue = ids
            try expectEqual(catalogue, Set(table.keys), "operations without an oracle: \(catalogue.subtracting(table.keys).sorted()); oracles without an operation: \(Set(table.keys).subtracting(catalogue).sorted())")
            try expectEqual(Set(DataConformance.ids), Set(table.keys), "the id list and the oracle table agree")
        }
    }

    // MARK: Sheets

    /// 200 rows: text with Unicode, quotes, a line break, integers, decimals, negative numbers, ISO dates; the header row.
    static func gridRows() -> [[String]] {
        var rows: [[String]] = [["Название", "Город", "Количество", "Цена", "Дата", "Комментарий"]]
        for i in 1...200 {
            rows.append(["Товар №\(i) Žluťák", i % 3 == 0 ? "Rīga" : "Москва", "\(i * 7)", String(format: "%.2f", Double(i) * 1.25).replacingOccurrences(of: ".00", with: "").replacingOccurrences(of: #"(\.\d)0$"#, with: "$1", options: .regularExpression),
                         String(format: "2024-%02d-%02d", i % 12 + 1, i % 28 + 1), i % 17 == 0 ? "строка 1\nстрока 2, \"в кавычках\"" : ""])
        }
        return rows
    }

    private static func expectedCell(_ s: String) -> String { s }

    static func sheetToXLSX(_ fx: TestFixtures) async throws {
        let rows = gridRows()
        let src = try SheetFixtures.csv(fx, rows: rows)
        let out = try unwrap(try await SheetRun.run("sheet.to.xlsx", src, fx: fx).first)
        try expectEqual(out.pathExtension, "xlsx"); try expectEqual(DataOracle.mime(out), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        try expect(try Data(contentsOf: out) != Data(contentsOf: src), "not a copy of the input")
        let dump = try DataOracle.xlsx(out)
        let got = dump.sheets[0].rows
        try expectEqual(got.count, rows.count)
        for (r, row) in rows.enumerated() {
            for (c, want) in row.enumerated() where !want.isEmpty {
                let cell = try unwrap(got[r][c], "cell \(r + 1),\(c + 1)")
                if c == 4 && r > 0 { try expect(cell.type == "n" && cell.style == 3, "dates are real dates"); continue }
                try expectEqual(cell.value, want, "cell \(r + 1),\(c + 1)")
                if c == 2 || c == 3, r > 0 { try expectEqual(cell.type, "n", "numbers are numbers") } else { try expectEqual(cell.type, "s") }
            }
        }
        if DataOracle.soffice != nil {
            let csv = try DataOracle.officeConvert(out, to: "csv", filter: "Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,0", in: fx.root)
            let seen = try DataOracle.csv(csv, encoding: "utf-8")
            try expectEqual(seen.count, rows.count, "LibreOffice sees the same rows")
            for r in 0..<rows.count { try expectEqual(Array(seen[r].prefix(4)), Array(rows[r].prefix(4)), "LibreOffice row \(r + 1)") }
        }
        let back = try SheetReader.read(out).sheets[0].rows
        for (r, row) in rows.enumerated() where r > 0 { try expectEqual(Array(back[r].prefix(4)), Array(row.prefix(4)), "round trip row \(r + 1)"); try expectEqual(back[r][4], row[4], "dates survive the round trip") }
    }

    static func sheetToCSV(_ fx: TestFixtures) async throws {
        let rows = gridRows()
        let xlsx = fx.url("src.xlsx")
        try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "Данные", rows: rows)]), to: xlsx, boldHeader: true, autoFit: true)
        let out = try unwrap(try await SheetRun.run("sheet.to.csv", xlsx, fx: fx).first)
        try expectEqual(out.pathExtension, "csv"); try expect(DataOracle.mime(out).hasPrefix("text/"), DataOracle.mime(out))
        try expectEqual(Array(try Data(contentsOf: out).prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 with BOM")
        let got = try DataOracle.csv(out, encoding: "utf-8-sig")
        // The independent XLSX reader gives the cell values; the CSV must show them (dates as ISO).
        let dump = try DataOracle.xlsx(xlsx).sheets[0].rows
        try expectEqual(got.count, dump.count)
        for r in 0..<got.count {
            for c in 0..<6 {
                let cell: DataOracle.Cell? = dump[r][safe: c] ?? nil
                let want: String
                if let cell, cell.style == 3, let serial = Double(cell.value), let comp = SheetValues.components(fromSerial: serial, date1904: false) { want = SheetValues.iso(comp, date: true, time: false) } else { want = cell?.value ?? "" }
                try expectEqual(got[r][c], want, "row \(r + 1) column \(c + 1)")
            }
        }
        try expectEqual(got, rows.map { $0 }, "and the text equals the original table")
        if DataOracle.soffice != nil {
            let lo = try DataOracle.officeConvert(out, to: "xlsx", in: fx.root)
            try expectEqual(try SheetReader.read(lo).sheets[0].rows.count, rows.count, "LibreOffice opens the CSV with the right row count")
        }
    }

    static func sheetToTSV(_ fx: TestFixtures) async throws {
        let rows = gridRows().map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") } }
        let ods = fx.url("src.ods")
        try SheetWriter.writeODS(SheetWorkbook(sheets: [SheetTable(name: "S", rows: rows)]), to: ods)
        let out = try unwrap(try await SheetRun.run("sheet.to.tsv", ods, [SheetKeys.encodingOut: "utf-8"], fx: fx).first)
        try expectEqual(out.pathExtension, "tsv")
        let got = try DataOracle.csv(out, encoding: "utf-8", delimiter: "\t")
        let sourceCells = try DataOracle.ods(ods).sheets[0].rows
        try expectEqual(got.count, sourceCells.count)
        for r in 0..<got.count { for c in 0..<6 { try expectEqual(got[r][c], (sourceCells[r][safe: c]?.value ?? "").replacingOccurrences(of: "T00:00:00", with: ""), "row \(r + 1) column \(c + 1)") } }
        try expectEqual(got.map { Array($0.prefix(4)) }, rows.map { Array($0.prefix(4)) }, "text and numbers equal the original table")
        try expect(String(decoding: try Data(contentsOf: out), as: UTF8.self).contains("\t"), "tab delimited")
    }

    static func sheetToODS(_ fx: TestFixtures) async throws {
        let rows = gridRows()
        let xlsx = fx.url("src.xlsx")
        try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "Данные", rows: rows), SheetTable(name: "Second", rows: [["x", "1"], ["y", "2"]])]), to: xlsx, boldHeader: true, autoFit: true)
        let out = try unwrap(try await SheetRun.run("sheet.to.ods", xlsx, fx: fx).first)
        try expectEqual(out.pathExtension, "ods"); try expectEqual(DataOracle.mime(out), "application/vnd.oasis.opendocument.spreadsheet")
        try expect(try Data(contentsOf: out) != Data(contentsOf: xlsx), "not a copy of the input")
        let a = try DataOracle.xlsx(xlsx), b = try DataOracle.ods(out)
        try expectEqual(b.sheets.map(\.name), a.sheets.map(\.name))
        for (sa, sb) in zip(a.sheets, b.sheets) {
            try expectEqual(sb.rows.count, sa.rows.count, sa.name)
            for (ra, rb) in zip(sa.rows, sb.rows) {
                for (c, cell) in ra.enumerated() {
                    guard let cell, !cell.value.isEmpty else { continue }
                    guard let other = rb[safe: c] else { throw TestFailure(message: "ODS row too short at \(c)", file: #fileID, line: #line) }
                    if cell.style == 3, let serial = Double(cell.value), let comp = SheetValues.components(fromSerial: serial, date1904: false) { try expectEqual(other.value, SheetValues.iso(comp, date: true, time: false)); try expectEqual(other.type, "date"); continue }
                    try expectEqual(other.value, cell.value); try expectEqual(other.type, cell.type == "n" ? "float" : "string", "cell types carry over")
                }
            }
        }
        if DataOracle.soffice != nil {
            let lo = try DataOracle.officeConvert(out, to: "csv", filter: "Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,0", in: fx.root)
            let seen = try DataOracle.csv(lo, encoding: "utf-8")
            try expectEqual(seen.map { Array($0.prefix(4)) }, rows.map { Array($0.prefix(4)) }, "LibreOffice reads the same cells")
        }
    }

    static func sheetToPDF(_ fx: TestFixtures) async throws {
        let rows = gridRows().map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") } }
        let xlsx = fx.url("src.xlsx")
        try SheetWriter.writeXLSX(SheetWorkbook(sheets: [SheetTable(name: "Данные", rows: rows)]), to: xlsx, boldHeader: true, autoFit: true)
        let out = try unwrap(try await SheetRun.run("sheet.to.pdf", xlsx, fx: fx).first)
        try expectEqual(out.pathExtension, "pdf"); try expectEqual(DataOracle.mime(out), "application/pdf"); try expect(TestFile.magicString(out, 5) == "%PDF-")
        let doc = try unwrap(PDFDocument(url: out))
        try expect(doc.pageCount >= 4, "200 rows over \(doc.pageCount) pages")
        let text = (doc.string ?? "").replacingOccurrences(of: "\n", with: " ")
        let words = Set(text.split(separator: " ").map(String.init))
        for r in stride(from: 1, to: rows.count, by: 7) { for token in rows[r][0].split(separator: " ") { try expect(words.contains(String(token)), "row \(r + 1) word \(token) is in the PDF") } }
        try expect(text.contains("Москва") && text.contains("Rīga") && text.contains("2024-"), "Cyrillic, Latvian and dates are text, not pictures")
        for p in 0..<doc.pageCount { try expect((doc.page(at: p)?.string ?? "").contains("Название"), "header on page \(p + 1)") }
        try expect(try Data(contentsOf: out) != Data(contentsOf: xlsx))
    }

    // MARK: Subtitles

    static let subsScript = """
    import sys, re, json
    text = open(sys.argv[1], encoding=sys.argv[2]).read().lstrip('\\ufeff').replace('\\r\\n', '\\n').replace('\\r', '\\n')
    def ms(t):
        t = t.replace(',', '.'); parts = t.split(':')
        h = int(parts[0]) if len(parts) == 3 else 0
        m = int(parts[-2]); s = float(parts[-1])
        return int(round(((h * 60 + m) * 60 + s) * 1000))
    cues = []
    for block in re.split(r'\\n\\s*\\n', text):
        lines = block.strip('\\n').split('\\n')
        for i, l in enumerate(lines):
            m = re.match(r'\\s*((?:\\d+:)?\\d+:\\d+[,.]\\d+)\\s*-->\\s*((?:\\d+:)?\\d+:\\d+[,.]\\d+)', l)
            if m:
                cues.append([ms(m.group(1)), ms(m.group(2)), '\\n'.join(lines[i + 1:])])
                break
    print(json.dumps(cues))
    """

    struct PyCue: Equatable { var start: Int; var end: Int; var text: String }

    static func pyCues(_ url: URL, encoding: String) throws -> [PyCue] {
        let text = try DataOracle.py(subsScript, [url.path, encoding])
        return ((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[Any]]) ?? []).map { PyCue(start: $0[0] as? Int ?? -1, end: $0[1] as? Int ?? -1, text: $0[2] as? String ?? "") }
    }

    static let subsCues: [SubtitleCue] = (0..<60).map { (i: Int) -> SubtitleCue in
        let start: Double = Double(i * 4_000 + 1_250) / 1000
        let end: Double = Double(i * 4_000 + 3_875) / 1000
        let two: String = "Привет, мир \(i)!\nВторая строка — Rīga, Žluťák"
        let one: String = "Строка \(i): съешь ещё этих мягких французских булок"
        return SubtitleCue(start: start, end: end, text: i % 5 == 0 ? two : one)
    }

    static func subsToSRT(_ fx: TestFixtures) async throws {
        // A WebVTT source in UTF-16 with a header, a NOTE and cue settings becomes SRT.
        let vtt = "WEBVTT\n\nNOTE comment\n\n" + subsCues.map { "\(SubtitleKit.stamp($0.start, ".")) --> \(SubtitleKit.stamp($0.end, ".")) align:start\n\($0.text)\n" }.joined(separator: "\n")
        let src = fx.url("in.vtt"); try TextEncodingKit.encode(vtt, as: .utf16le, bom: true).data.write(to: src)
        let out = try unwrap(try await SubsRun.run("subs.to.srt", src, fx: fx).first)
        try expectEqual(out.pathExtension, "srt"); try expect(try Data(contentsOf: out) != Data(contentsOf: src))
        let got = try pyCues(out, encoding: "utf-8")
        try expectEqual(got.count, subsCues.count)
        for (g, w) in zip(got, subsCues) { try expectEqual(g, PyCue(start: Int((w.start * 1000).rounded()), end: Int((w.end * 1000).rounded()), text: w.text)) }
        try expect(String(decoding: try Data(contentsOf: out), as: UTF8.self).hasPrefix("1\r\n00:00:01,250 --> 00:00:03,875\r\n"), "SRT layout")
        if let ffmpeg = ToolLocator.shared.url(.ffmpeg) {
            let probe = fx.url("ff.vtt")
            let r = DataTestKit.run(ffmpeg.path, ["-v", "error", "-y", "-i", out.path, probe.path])
            try expectEqual(r.status, 0, "ffmpeg parses the SRT: \(r.output.prefix(200))")
            try expectEqual(try pyCues(probe, encoding: "utf-8").count, subsCues.count)
        }
    }

    static func subsToVTT(_ fx: TestFixtures) async throws {
        let srt = subsCues.enumerated().map { "\($0.offset + 1)\r\n\(SubtitleKit.stamp($0.element.start, ",")) --> \(SubtitleKit.stamp($0.element.end, ","))\r\n\($0.element.text.replacingOccurrences(of: "\n", with: "\r\n"))\r\n" }.joined(separator: "\r\n")
        let src = fx.url("in.srt"); try TextEncodingKit.encode(srt.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "Rīga", with: "Riga").replacingOccurrences(of: "Žluťák", with: "Zlutak"), as: .windows1251).data.write(to: src)
        let out = try unwrap(try await SubsRun.run("subs.to.vtt", src, fx: fx).first)
        try expectEqual(out.pathExtension, "vtt")
        let raw = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        try expect(raw.hasPrefix("WEBVTT\n\n"), "header"); try expect(!raw.contains("\r"), "LF")
        let got = try pyCues(out, encoding: "utf-8")
        let want = subsCues.map { PyCue(start: Int(($0.start * 1000).rounded()), end: Int(($0.end * 1000).rounded()), text: $0.text.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "Rīga", with: "Riga").replacingOccurrences(of: "Žluťák", with: "Zlutak")) }
        try expectEqual(got, want, "the Windows-1251 source came out as the same cues in UTF-8")
        if let ffmpeg = ToolLocator.shared.url(.ffmpeg) {
            let probe = fx.url("ff.srt")
            try expectEqual(DataTestKit.run(ffmpeg.path, ["-v", "error", "-y", "-i", out.path, probe.path]).status, 0, "ffmpeg parses the WebVTT")
            try expectEqual(try pyCues(probe, encoding: "utf-8").count, subsCues.count)
        }
    }

    static func subsToTXT(_ fx: TestFixtures) async throws {
        let ass = SubtitleKit.serialize(subsCues.map { SubtitleCue(start: $0.start, end: $0.end, text: "<i>" + $0.text + "</i>") }, as: .ass)
        let src = fx.url("in.ass"); try Data(ass.utf8).write(to: src)
        let out = try unwrap(try await SubsRun.run("subs.to.txt", src, fx: fx).first)
        try expectEqual(out.pathExtension, "txt"); try expect(DataOracle.mime(out).hasPrefix("text/"), DataOracle.mime(out))
        let lines = String(decoding: try Data(contentsOf: out), as: UTF8.self).split(separator: "\n").map(String.init)
        try expectEqual(lines, subsCues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }, "one line per cue, tags gone, times gone")
        try expect(!String(decoding: try Data(contentsOf: out), as: UTF8.self).contains("-->"))
    }

    // MARK: Archives

    static func archiveExtract(_ fx: TestFixtures) async throws {
        let proj = try ArcFixtures.project(fx)
        let tgz = fx.url("proj.tar.gz")
        try expectEqual(DataTestKit.run("/usr/bin/bsdtar", ["-czf", tgz.path, "-C", fx.root.path, "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX", "proj"]).status, 0)
        let r = try await ArcRun.run("archive.extract", [tgz], fx: fx)
        let out = try unwrap(r.outputs.first)
        // Independent expectation: libarchive extracts the same archive.
        let reference = try ArcOracle.extract(tgz, fx: fx)
        let refTree = DataTestsExtract.tree(reference.appendingPathComponent("proj")).filter { !$0.hasPrefix("__MACOSX") && !$0.contains("._") && !$0.hasSuffix(".DS_Store") }
        try expectEqual(DataTestsExtract.tree(out).filter { !$0.hasPrefix("__MACOSX") && !$0.contains("._") && !$0.hasSuffix(".DS_Store") }, refTree, "same listing as libarchive")
        for rel in refTree where !rel.hasSuffix("/") && (try? FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent(rel).path)) == nil {
            try expectEqual(try Data(contentsOf: out.appendingPathComponent(rel)), try Data(contentsOf: reference.appendingPathComponent("proj/" + rel)), rel)
        }
        for rel in ["src/main.swift", "docs/Привет мир.txt"] { try expectEqual(try Data(contentsOf: out.appendingPathComponent(rel)), try Data(contentsOf: proj.appendingPathComponent(rel)), "equals the original \(rel)") }
        try expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent(".DS_Store").path))
    }

    static func repack(_ fx: TestFixtures, to key: String) async throws {
        let proj = try ArcFixtures.project(fx)
        let source = fx.url("proj.7z")
        let seven = DataTestKit.run("/usr/bin/bsdtar", ["--format", "7zip", "-cf", source.path, "-C", fx.root.path, "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX", "proj"]).status == 0
        let input = seven ? source : try fx.zip("proj.zip", items: ["proj"])
        let out = try unwrap(try await ArcRun.run("archive.to.\(key)", [input], fx: fx).outputs.first)
        try expectEqual(out.lastPathComponent, "proj.\(key)")
        try expect(try Data(contentsOf: out) != Data(contentsOf: input), "not a copy of the input")
        let mimes = ["zip": ["application/zip"], "tar": ["application/x-tar"], "tar.gz": ["application/gzip", "application/x-gzip"]]
        try expect(mimes[key]!.contains(DataOracle.mime(out)), "real type \(DataOracle.mime(out))")
        let x = try ArcOracle.extract(out, fx: fx)
        for rel in ["readme.txt", "src/main.swift", "src/util/helper.swift", "docs/Привет мир.txt", "bin/run.sh", "img/photo.jpg", ".hidden"] {
            try expectEqual(try Data(contentsOf: x.appendingPathComponent("proj/" + rel)), try Data(contentsOf: proj.appendingPathComponent(rel)), "\(key): \(rel)")
        }
        let listing = Set(try ArcOracle.names(out))
        try expect(!listing.contains { $0.contains("DS_Store") || $0.contains("__MACOSX") || $0.contains("/._") }, "no junk after the repack: \(listing.filter { $0.contains("._") })")
        try expect(listing.contains("proj") && listing.contains("proj/src/main.swift") && listing.contains("proj/empty"), "layout kept")
    }

    static func pack(_ fx: TestFixtures, _ id: String) async throws {
        let proj = try ArcFixtures.project(fx)
        let out = try unwrap(try await ArcRun.run(id, [proj], fx: fx).outputs.first)
        let key = id == "pack.zip" ? "zip" : "tar.gz"
        try expectEqual(out.lastPathComponent, "proj.\(key)")
        try expect(["application/zip", "application/gzip", "application/x-gzip"].contains(DataOracle.mime(out)), DataOracle.mime(out))
        let listing = Set(try ArcOracle.names(out))
        try expectEqual(listing, Set(ArcFixtures.defaultNames.map { $0.isEmpty ? "proj" : "proj/" + $0 }), "listing equals the input minus junk")
        let x = try ArcOracle.extract(out, fx: fx)
        for rel in ["readme.txt", "src/main.swift", "docs/Žluťák.txt", "bin/run.sh", "img/photo.jpg"] { try expectEqual(try Data(contentsOf: x.appendingPathComponent("proj/" + rel)), try Data(contentsOf: proj.appendingPathComponent(rel))) }
        let stored = TestFile.size(try unwrap(try await ArcRun.run(id, [proj], [ArchiveKeys.level: 0], fx: fx).outputs.first))
        let best = TestFile.size(try unwrap(try await ArcRun.run(id, [proj], [ArchiveKeys.level: 9], fx: fx).outputs.first))
        try expect(best < stored, "level 9 (\(best)) is smaller than level 0 (\(stored))")
        try expect(TestFile.size(out) < stored, "the default level compresses")
    }
}
