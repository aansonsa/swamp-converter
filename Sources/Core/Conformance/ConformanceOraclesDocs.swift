import Foundation
import PDFKit

// Default oracles for documents, spreadsheets and subtitles. The fixtures have KNOWN content (ConformanceFixtures+Docs): a report with three heading levels, a
// bulleted and a numbered list, a table, bold text and Latin / Cyrillic / Czech letters; a table with quotes, delimiters, line breaks and leading zeros inside
// fields; subtitles with markup, line breaks and times beyond one hour. The expected facts are compared with what the output file says when read back by
// readers written for the conformance checks (and Apple's textutil / PDFKit), not by the engine's own parsers.

extension ConformanceOracles {
    static let documentTargets: Set<String> = ["docx", "pdf", "odt", "md", "html", "txt", "epub", "rtf"]
    private static let structuredTargets: Set<String> = ["docx", "odt", "md", "html", "epub"]

    static let documentConvert = ConformanceOracle(
        id: "document.convert", priority: 0,
        match: { m in
            m.wheel == .convert && documentTargets.contains(m.targetFormat ?? "") && (m.inputs?.isDisjoint(with: ["md", "html", "docx", "odt", "txt", "rtf"]) == false) && !(m.inputs?.contains("pdf") ?? false)
        },
        timeout: 300,
        cases: { meta, fx in
            let target = meta.targetFormat ?? "docx"
            var cases: [ConformanceCase] = []
            for key in ["html", "docx", "md", "odt"] where (meta.inputs?.contains(key) ?? false) && key != target && cases.count < 2 {
                if let f = try await ConformanceInputs.file(key: key, fx: fx, name: "report") { cases.append(ConformanceCase(label: key, inputs: [f])) }
            }
            return cases
        },
        verify: { run in try verifyDocumentConvert(run) },
        proves: "the text of the report in order; headings, lists, tables and bold kept where the format can hold them (read back by independent readers, textutil and PDFKit)")

    @MainActor
    static func verifyDocumentConvert(_ run: ConformanceRun) throws {
        let target = run.meta.targetFormat ?? ""
        let out = try run.sole()
        let spec = ConformanceFixtures.docSpec
        switch target {
        case "pdf":
            guard let facts = PDFReader.facts(out) else { throw run.fail("PDFKit cannot read the PDF") }
            let r = TextCompare.wordRecall(expected: spec.words, actual: facts.allText)
            try expect(r >= 0.95, String(format: "only %.1f%% of the document's words are in the PDF", r * 100))
            run.note(String(format: "%d page(s), %.1f%% of words", facts.pageCount, r * 100))
        case "txt":
            let data = try Data(contentsOf: out)
            try expect(!data.starts(with: [0xEF, 0xBB, 0xBF]), "text exports are UTF-8 without a BOM")
            guard let text = String(data: data, encoding: .utf8) else { throw run.fail("the text is not valid UTF-8") }
            let r = TextCompare.wordRecall(expected: spec.words, actual: text)
            try expect(r >= 0.97, String(format: "only %.1f%% of the words are in the text", r * 100))
            run.note(String(format: "%.1f%% of words", r * 100))
        case "rtf":
            guard let text = TextCompare.textutilText(out) else { throw run.fail("textutil cannot read the RTF") }
            let r = TextCompare.wordRecall(expected: spec.words, actual: text)
            try expect(r >= 0.97, String(format: "only %.1f%% of the words are in the RTF", r * 100))
            run.note(String(format: "%.1f%% of words (read by textutil)", r * 100))
        default:
            guard let doc = DocStructure.read(out) else { throw run.fail("cannot read the produced \(target.uppercased())") }
            let r = TextCompare.wordRecall(expected: spec.words, actual: doc.text)
            try expect(r >= 0.97, String(format: "only %.1f%% of the words are in the %@ (read back: %@)", r * 100, target, doc.summary))
            try expectEqual(doc.headings.map(\.level), spec.headings.map(\.level), "heading levels")
            try expectEqual(doc.headings.map(\.text), spec.headings.map(\.text), "heading texts")
            try expectEqual(doc.listItems, spec.listItems, "list items")
            try expectEqual(doc.tables.first ?? [], spec.tableRows, "the table")
            if target != "odt" { try expect(doc.boldRuns >= 1, "the bold word lost its emphasis") }
            run.note(String(format: "%.1f%% of words; %@", r * 100, doc.summary))
            if let tu = TextCompare.textutilText(out), target != "epub", target != "md" {
                let r2 = TextCompare.wordRecall(expected: spec.words, actual: tu)
                try expect(r2 >= 0.90, String(format: "Apple's own reader finds only %.1f%% of the words", r2 * 100))
            }
        }
    }

    // MARK: Spreadsheets

    static let sheetConvert = ConformanceOracle(
        id: "sheet.convert", priority: 0,
        match: { m in m.wheel == .convert && ["csv", "tsv", "xlsx", "ods", "pdf"].contains(m.targetFormat ?? "") && (m.inputs?.isDisjoint(with: ["csv", "tsv", "xlsx", "xlsm"]) == false) },
        cases: { meta, fx in
            let target = meta.targetFormat ?? "csv"
            var cases: [ConformanceCase] = []
            if (meta.inputs?.contains("csv") ?? false), target != "csv" { cases.append(ConformanceCase(label: "csv with BOM", inputs: [try fx.unicodeCSV("table.csv", bom: true)])) }
            if (meta.inputs?.contains("xlsx") ?? false), target != "xlsx" { cases.append(ConformanceCase(label: "xlsx", inputs: [try fx.xlsx("book.xlsx")])) }
            if (meta.inputs?.contains("csv") ?? false), target == "csv" { cases.append(ConformanceCase(label: "semicolon csv", inputs: [try fx.unicodeCSV("table.tsv", delimiter: "\t")])) }
            return cases
        },
        verify: { run in
            let target = run.meta.targetFormat ?? ""
            let expected = ConformanceFixtures.unicodeTable
            let out = try run.sole()
            switch target {
            case "csv", "tsv":
                guard let f = TableFidelity.readDelimited(out) else { throw run.fail("cannot read the output table") }
                try expect(f.delimiter == (target == "csv" ? "," : "\t"), "wrong delimiter \(f.delimiter.debugDescription)")
                try expect(f.hasBOM, "a CSV / TSV export starts with a UTF-8 BOM so Excel shows accents")
                try expectEqual(f.lineEnding, "\r\n", "line endings")
                let want = target == "tsv" ? expected.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") } } : expected
                let diff = TableFidelity.difference(f.rows, want)
                try expect(diff == nil, "the table changed: \(diff ?? "")")
                run.note("\(f.rows.count) rows equal, UTF-8 BOM, CRLF")
            case "xlsx", "ods":
                guard let sheets = target == "xlsx" ? TableFidelity.readXLSX(out) : TableFidelity.readODS(out), let first = sheets.first else { throw run.fail("cannot read the workbook") }
                let diff = TableFidelity.difference(first.rows, expected)
                try expect(diff == nil, "the table changed: \(diff ?? "")")
                run.note("sheet \"\(first.name)\" equals the source table")
            default:
                guard let facts = PDFReader.facts(out) else { throw run.fail("PDFKit cannot read the PDF") }
                let r = TextCompare.wordRecall(expected: "id name note amount Žluťák Привет 日本語", actual: facts.allText)
                try expect(r >= 0.7, String(format: "the PDF shows only %.0f%% of the cell texts", r * 100))
                run.note("\(facts.pageCount) page(s)")
            }
        },
        proves: "the same table cell for cell (quotes, delimiters, line breaks, leading zeros, Cyrillic and CJK); CSV with BOM and CRLF; sheet written readable by an independent reader")

    // MARK: Subtitles

    static let subsConvert = ConformanceOracle(
        id: "subs.convert", priority: 0,
        match: { m in m.wheel == .convert && ["srt", "vtt", "txt"].contains(m.targetFormat ?? "") && (m.inputs?.isDisjoint(with: ["srt", "vtt"]) == false) },
        cases: { meta, fx in
            let target = meta.targetFormat ?? "srt"
            var cases: [ConformanceCase] = []
            if target != "srt" { cases.append(ConformanceCase(label: "srt", inputs: [try fx.srtFile("subs.srt")])) }
            if target != "vtt" { cases.append(ConformanceCase(label: "vtt", inputs: [try fx.vttFile("subs.vtt")])) }
            return cases
        },
        verify: { run in
            let target = run.meta.targetFormat ?? ""
            let out = try run.sole()
            let data = try Data(contentsOf: out)
            try expect(!data.starts(with: [0xEF, 0xBB, 0xBF]), "subtitle exports are UTF-8 without a BOM")
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            if target == "txt" {
                let want = SubtitleFidelity.plainLines(ConformanceFixtures.cues)
                let got = text.split(whereSeparator: \.isNewline).map(String.init)
                try expectEqual(got, want, "one cleaned line per cue")
                run.note("\(got.count) lines")
                return
            }
            let cues = try unwrap(SubtitleFidelity.read(out), "cannot parse the subtitles")
            if let d = SubtitleFidelity.difference(cues, ConformanceFixtures.cues) {
                // VTT / SRT keep markup as is; a converter may not drop tags unless it is the text export.
                throw run.fail("the cues changed: \(d)")
            }
            if target == "vtt" {
                try expect(text.hasPrefix("WEBVTT"), "a WebVTT file starts with WEBVTT")
                try expect(text.contains("00:00:00.500 --> 00:00:02.000"), "WebVTT writes milliseconds after a dot")
            } else {
                try expect(text.contains("00:00:00,500 --> 00:00:02,000") && text.hasPrefix("1\n"), "SubRip numbers its cues and writes milliseconds after a comma")
            }
            run.note("\(cues.count) cues equal in time and text")
        },
        proves: "every cue with the same times (to the millisecond) and text, in the target's own syntax; the text export has one cleaned line per cue")
}
