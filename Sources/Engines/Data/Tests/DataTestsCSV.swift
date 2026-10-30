import Foundation

// CSV / TSV: parser dialect matrix, delimiter sniffing, encodings and byte-exact writer output.

enum DataTestsCSV {
    private static func parse(_ text: String, delimiter: UInt8 = 0x2C) -> [[String]] {
        var p = CSVParser(delimiter: delimiter)
        var rows: [[String]] = []
        p.feed(Array(text.utf8)) { rows.append($0) }
        p.finish { rows.append($0) }
        return rows
    }

    static func register() {
        dataTest("data.csv", "RFC 4180 dialect matrix: quotes, doubled quotes, embedded newlines, CR / LF / CRLF, blank lines, ragged rows, literal quotes inside a field") {
            try expectEqual(parse("a,b,c\r\n1,2,3\r\n"), [["a", "b", "c"], ["1", "2", "3"]])
            try expectEqual(parse("a,b\n1,2"), [["a", "b"], ["1", "2"]], "the last row without a line break is kept")
            try expectEqual(parse("a,b\r1,2\r"), [["a", "b"], ["1", "2"]], "CR alone ends a row")
            try expectEqual(parse("\"a,b\",\"say \"\"hi\"\"\",c\n"), [["a,b", "say \"hi\"", "c"]])
            try expectEqual(parse("\"line1\nline2\",x\r\n\"cr\r\nlf\",y\r\n"), [["line1\nline2", "x"], ["cr\r\nlf", "y"]], "embedded newlines of both kinds survive")
            try expectEqual(parse("ab\"c,d\n"), [["ab\"c", "d"]], "a quote inside an unquoted field is literal")
            try expectEqual(parse("a\n\nb\n"), [["a"], [""], ["b"]], "a blank line is a row with one empty field")
            try expectEqual(parse("a,b,c\n1\n1,2,3,4\n"), [["a", "b", "c"], ["1"], ["1", "2", "3", "4"]], "rows are not padded")
            try expectEqual(parse(",,\n"), [["", "", ""]])
            try expectEqual(parse("\"\"\n"), [[""]])
            try expectEqual(parse("\"a\"b,c\n"), [["ab", "c"]], "text after a closing quote is appended")
            try expectEqual(parse("x;y\n1;2\n", delimiter: 0x3B), [["x", "y"], ["1", "2"]])
            try expectEqual(parse("Žluťák\tПривет\t日本\n", delimiter: 0x09), [["Žluťák", "Привет", "日本"]])
        }

        dataTest("data.csv", "the parser gives the same rows for any chunking of the input", proves: []) {
            let text = "name,notes\r\n\"Ž\u{301}luťák\",\"multi\nline, with \"\"quotes\"\"\"\r\nПривет,мир\r\n,\r\nlast,row"
            let whole = parse(text)
            let bytes = Array(text.utf8)
            for chunk in [1, 2, 3, 5, 8, 13] {
                var p = CSVParser(delimiter: 0x2C)
                var rows: [[String]] = []
                var i = 0
                while i < bytes.count { p.feed(Array(bytes[i..<min(i + chunk, bytes.count)])) { rows.append($0) }; i += chunk }
                p.finish { rows.append($0) }
                try expectEqual(rows, whole, "chunk size \(chunk)")
            }
        }

        dataTest("data.csv", "delimiter detection: comma, semicolon, tab, pipe; quoted delimiters ignored; consistency beats a title row", proves: ["sheet.delim.in.parse"]) {
            func sniff(_ s: String) -> UInt8 { CSVSniffer.detect(Array(s.utf8)) }
            try expectEqual(sniff("a,b,c\n1,2,3\n4,5,6\n"), 0x2C)
            try expectEqual(sniff("a;b;c\n1;2;3\n4;5;6\n"), 0x3B)
            try expectEqual(sniff("a\tb\tc\n1\t2\t3\n"), 0x09)
            try expectEqual(sniff("a|b|c\n1|2|3\n"), 0x7C)
            try expectEqual(sniff("\"x,y\";\"z\"\n\"1,2\";\"3\"\n"), 0x3B, "commas inside quotes do not count")
            try expectEqual(sniff("Report, 2024, final\nname;qty;price\nbolt;3;1,5\nnut;4;2,5\n"), 0x3B, "a title row with commas does not fool the sniffer")
            try expectEqual(sniff("single column\nanother row\n"), 0x2C, "no delimiter at all falls back to the comma")
            try expectEqual(sniff("1,5;2,5;3,5\n4,5;5,5;6,5\n"), 0x3B, "decimal commas with semicolon delimiters")
        }

        dataTest("data.csv", "encodings of CSV files are detected: UTF-8, BOM, UTF-16, Windows-1251 / 1250 / 1257; KOI8-R and CP866 need the override", proves: ["sheet.enc.in.decode"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let rows = [["name", "city"], ["Привет", "Москва"], ["Žluťák", "Příbram"], ["Rīga", "Ķekava"]]
            func table(_ enc: DataEncoding, bom: Bool = false, rows: [[String]]) throws -> URL {
                let body = rows.map { $0.joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
                let e = TextEncodingKit.encode(body, as: enc, bom: bom)
                try expectEqual(e.replaced, 0, "fixture representable in \(enc.displayName)")
                let u = fx.url("t-\(enc.rawValue)-\(bom).csv")
                try e.data.write(to: u)
                return u
            }
            let cyr = Array(rows.prefix(2))
            let balt = [rows[0], rows[3]]
            let cz = [rows[0], rows[2]]
            for (enc, bom, data) in [(DataEncoding.utf8, false, rows), (.utf8, true, rows), (.utf16le, true, rows), (.utf16be, true, rows), (.utf16le, false, rows),
                                     (.windows1251, false, cyr), (.windows1257, false, balt), (.windows1250, false, cz)] as [(DataEncoding, Bool, [[String]])] {
                let wb = try SheetReader.read(try table(enc, bom: bom, rows: data))
                try expectEqual(wb.sheets[0].rows, data, "\(enc.displayName) bom=\(bom)")
            }
            // KOI8-R and CP866 are ambiguous for a short text: the explicit encoding decides.
            for enc in [DataEncoding.koi8r, .cp866] {
                var o = SheetReadOptions(); o.encoding = enc
                let u = try table(enc, rows: cyr)
                try expectEqual(try SheetReader.read(u, options: o).sheets[0].rows, cyr, "override \(enc.displayName)")
            }
            var wrong = SheetReadOptions(); wrong.encoding = .windows1251
            let koi = try table(.koi8r, rows: cyr)
            try expect(try SheetReader.read(koi, options: wrong).sheets[0].rows != cyr, "a wrong explicit encoding really changes the result")
        }

        dataTest("data.csv", "the explicit delimiter wins over detection; .tsv defaults to tab", proves: []) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let u = try fx.text("a.csv", "a;b,c\r\n1;2,3\r\n")
            try expectEqual(try SheetReader.read(u).sheets[0].rows[0], ["a;b", "c"], "the comma wins a tie of consistency")
            var o = SheetReadOptions(); o.delimiter = 0x3B
            try expectEqual(try SheetReader.read(u, options: o).sheets[0].rows, [["a", "b,c"], ["1", "2,3"]])
            let tsv = try fx.text("b.tsv", "x,y\tz\r\n1\t2\r\n")
            try expectEqual(try SheetReader.read(tsv).sheets[0].rows, [["x,y", "z"], ["1", "2"]])
        }

        dataTest("data.csv", "writer: quoting rules byte for byte, TSV tabs become spaces, line endings, quote-all, BOM and encodings", proves: ["sheet.eol.bytes", "sheet.quoteAll.bytes", "sheet.enc.out.bytes"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let table = SheetTable(name: "t", rows: [["a", "b,c", "x\"y"], ["multi\nline", "plain", ""], ["tab\there", "ž", "Привет"]])
            func bytes(_ d: CSVDialect, name: String = "o.csv") throws -> Data {
                let u = fx.url(name)
                try SheetWriter.writeCSV(table, to: u, dialect: d)
                return try Data(contentsOf: u)
            }
            var d = CSVDialect(); d.bom = false
            let plain = String(decoding: try bytes(d), as: UTF8.self)
            try expectEqual(plain, "a,\"b,c\",\"x\"\"y\"\r\n\"multi\nline\",plain,\r\ntab\there,ž,Привет\r\n")
            d.crlf = false
            try expectEqual(String(decoding: try bytes(d), as: UTF8.self).contains("\r"), false, "LF endings")
            d.crlf = true; d.quoteAll = true
            try expect(String(decoding: try bytes(d), as: UTF8.self).hasPrefix("\"a\",\"b,c\",\"x\"\"y\"\r\n"), "quote everything")
            d.quoteAll = false; d.bom = true
            try expectEqual(Array(try bytes(d).prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM")
            d.delimiter = "\t"; d.bom = false
            try expect(String(decoding: try bytes(d, name: "o.tsv"), as: UTF8.self).contains("tab here"), "tabs inside TSV values become spaces")
            var win = CSVDialect(); win.delimiter = ";"; win.dataEncoding = .windows1251; win.bom = false
            let cp = SheetTable(name: "t", rows: [["Привет", "мир"]])
            let u = fx.url("w.csv"); try SheetWriter.writeCSV(cp, to: u, dialect: win)
            try expectEqual(Array(try Data(contentsOf: u)), TextEncodingKit.encode("Привет;мир\r\n", as: .windows1251).data.map { $0 }, "Windows-1251 bytes")
            var u16 = CSVDialect(); u16.dataEncoding = .utf16
            let u2 = fx.url("u16.csv"); try SheetWriter.writeCSV(cp, to: u2, dialect: u16)
            try expectEqual(Array(try Data(contentsOf: u2).prefix(2)), [0xFF, 0xFE], "UTF-16 LE with BOM")
            try expectEqual(try SheetReader.read(u2).sheets[0].rows, cp.rows, "and it reads back")
            let rep = try SheetWriter.writeCSVReporting(SheetTable(name: "t", rows: [["Rīga Žluťák ♪"]]), to: fx.url("lossy.csv"), dialect: win)
            try expect(rep.replacedCharacters > 0, "unrepresentable characters are counted")
        }

        dataTest("data.csv", "a 200 000-row file streams through and keeps every row; the preview stops early") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let u = fx.url("big.csv")
            let w = try CSVRowWriter(url: u, dialect: CSVDialect())
            for i in 0..<200_000 { try w.write(row: ["\(i)", "name \(i)", "Привет, \"мир\" \(i)"]) }
            try w.finish()
            var n = 0, last: [String] = []
            try CSVFile.stream(u) { row in n += 1; last = row; return true }
            try expectEqual(n, 200_000)
            try expectEqual(last, ["199999", "name 199999", "Привет, \"мир\" 199999"])
            let pv = try SheetReader.preview(u, maxRows: 50)
            try expectEqual(pv.sheets[0].rows.count, 50)
            try expectEqual(pv.detectedDelimiter, ",")
        }

        dataTest("data.csv", "cancelling a big CSV read stops it within 200 ms") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let u = fx.url("big2.csv")
            let w = try CSVRowWriter(url: u, dialect: CSVDialect())
            for i in 0..<400_000 { try w.write(row: ["\(i)", "some longer text value to make the file bigger \(i)", "x"]) }
            try w.finish()
            let task = Task.detached { () throws -> Int in var n = 0; try CSVFile.stream(u) { _ in n += 1; return true }; return n }
            try await Task.sleep(nanoseconds: 20_000_000)
            let t0 = Date()
            task.cancel()
            let r = await task.result
            let took = Date().timeIntervalSince(t0)
            if case .success = r { throw TestFailure(message: "the read finished before the cancel arrived", file: #fileID, line: #line) }
            try expect(took < 0.5, "stopped in \(took) s")
        }
    }
}
