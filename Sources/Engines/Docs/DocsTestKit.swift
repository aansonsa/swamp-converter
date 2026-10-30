import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Fixtures, independent oracles and the runner of the documents self-tests (suite "docs"). Everything is generated in a temp folder. The oracles read results back with tools
// that are NOT the code under test: PDFKit, /usr/bin/textutil, /usr/bin/unzip, /usr/bin/xmllint and /usr/bin/file.

/// oracle id -> name of the test that proves it. `DocsTests` checks that every field of every schema is covered.
enum DocOracles {
    private static let ledger = Locked<[String: String]>([:])
    static var map: [String: String] { ledger.value }
    static func record(_ ids: [String], test: String) { ledger.withLock { for id in ids { $0[id] = test } } }
}

func docTest(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
    DocOracles.record(proves, test: name)
    SelfTestRegistry.shared.register("docs", name, requires: requires, timeout: timeout, body)
}

// MARK: - Fixtures

enum DocFixtures {
    static let title = "Болотный отчёт — Purvs 2026"

    /// Plain-text snippets in reading order (outside the table), used to prove that a conversion kept the text and its order.
    static let orderedTokens = ["Болотный отчёт", "Привет, мир! Ķirsis un ābols", "Introduction", "Some bold, italic and code_span() with a link to the swamp.",
                                "first item", "second item", "nested three", "nested four", "third item", "step one", "step two", "A quoted thought about frogs.",
                                "let x = 1", "Conclusion", "The end of the swamp report."]
    static let cellTokens = ["Žluťák", "42", "Привет", "Pipe | char"]

    static func picture(_ fx: TestFixtures, width: Int = 240, height: Int = 120) -> Data {
        let image = fx.cgImage(width: width, height: height, pattern: .noise(seed: 7))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A document with every construct: headings 1-3, styled inlines, a link, bullet / nested ordered lists, an aligned table, a quote, code, a rule and a picture.
    static func sample(_ fx: TestFixtures, long: Bool = false) -> DocModel {
        var m = DocModel()
        m.meta.title = "Swamp report"
        m.meta.author = "Андрис Лейте"
        m.meta.language = "en"
        m.meta.created = Date(timeIntervalSince1970: 1_700_000_000)
        var store = DocMediaStore()
        let key = store.add(picture(fx), suggestedName: "swamp.png")
        m.media = store.items
        let nested = DocList(ordered: true, start: 3, items: [DocListItem(blocks: [.paragraph([.text("nested three")])]), DocListItem(blocks: [.paragraph([.text("nested four")])])])
        m.blocks = [
            .heading(level: 1, content: [.text("Болотный отчёт — Purvs 2026")]),
            .paragraph([.text("Привет, мир! Ķirsis un ābols — žogs, čūska. Plain words for the swamp.")]),
            .heading(level: 2, content: [.text("Introduction")]),
            .paragraph([.text("Some "), .strong([.text("bold")]), .text(", "), .emphasis([.text("italic")]), .text(" and "), .code("code_span()"), .text(" with a "),
                        .link(url: "https://example.com/swamp?a=1&b=2", title: nil, content: [.text("link to the swamp")]), .text(".")]),
            .list(DocList(ordered: false, items: [
                DocListItem(blocks: [.paragraph([.text("first item")])]),
                DocListItem(blocks: [.paragraph([.text("second item")]), .list(nested)]),
                DocListItem(blocks: [.paragraph([.text("third item")])])])),
            .list(DocList(ordered: true, start: 1, items: [DocListItem(blocks: [.paragraph([.text("step one")])]), DocListItem(blocks: [.paragraph([.text("step two")])])])),
            .heading(level: 3, content: [.text("Numbers")]),
            .table(DocTable(align: [.left, .right, .center], header: [[.text("Name")], [.text("Count")], [.text("Note")]],
                            rows: [[[.text("Žluťák")], [.text("42")], [.text("ok")]], [[.text("Привет")], [.text("7")], [.text("да")]], [[.text("Pipe | char")], [.text("1")], [.text("x")]]])),
            .quote([.paragraph([.text("A quoted thought about frogs.")])]),
            .code(language: nil, text: "let x = 1\nprint(x) // <tag> & \"quotes\""),
            .rule,
            .paragraph([.image(src: key, alt: "Swamp picture", title: nil)]),
            .heading(level: 2, content: [.text("Conclusion")]),
            .paragraph([.text("The end of the swamp report.")])
        ]
        if long {
            var body: [DocBlock] = []
            for i in 1...140 {
                body.append(.paragraph([.text("Paragraph \(i): the quick brown frog jumps over the lazy toad near the reed beds of the swamp, and the evening mist settles over the water while "
                                              + "краснобрюхие жабы поют свою вечернюю песню, а ķirsis zied pie ezera. Number \(i * 7).")]))
            }
            m.blocks.insert(contentsOf: body, at: 3)
        }
        return m
    }

    /// An input file of format `key` holding `model`. Our own writers make most of them; the legacy ones go through textutil (HTML in, doc out).
    @discardableResult
    static func makeInput(_ key: String, in fx: TestFixtures, model: DocModel, name: String? = nil) async throws -> URL {
        let url = fx.url(name ?? "sample.\(key)")
        var s = DocSettings()
        s.target = key
        switch key {
        case "doc":
            let html = fx.url((name ?? "sample") + ".source.html")
            s.target = "html"; s.htmlEmbed = false
            try await DocNative.write(model, to: html, settings: s, baseName: "sample", mediaFolder: "")
            for m in model.media.values { try m.data.write(to: fx.url(m.name)) }       // textutil embeds pictures it can find next to the page, not data: URIs
            let r = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/textutil"), ["-convert", "doc", "-output", url.path, html.path], timeout: 30)
            try expect(FileManager.default.fileExists(atPath: url.path), "textutil could not make the .doc fixture: \(r ?? "")")
        case "rtf", "docx", "odt", "epub", "html", "md", "txt", "pdf":
            s.target = key
            try await DocNative.write(model, to: url, settings: s, baseName: "sample")
        default: throw TestFailure(message: "no fixture writer for \(key)", file: #fileID, line: #line)
        }
        return url
    }

    /// The same content made by the SYSTEM (textutil from HTML), so readers are also proven on files our writers did not produce.
    static func systemMade(_ key: String, in fx: TestFixtures, model: DocModel) async throws -> URL {
        let html = fx.url("system-source.html")
        var s = DocSettings(); s.target = "html"; s.htmlEmbed = false
        try await DocNative.write(model, to: html, settings: s, baseName: "system", mediaFolder: "")
        for m in model.media.values { try m.data.write(to: fx.url(m.name)) }
        let url = fx.url("system.\(key)")
        let r = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/textutil"), ["-convert", key, "-output", url.path, html.path], timeout: 30)
        try expect(FileManager.default.fileExists(atPath: url.path), "textutil could not make a .\(key) file: \(r ?? "")")
        return url
    }
}

// MARK: - Oracles

enum DocOracle {
    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "[\\s\\x{00A0}\\x{2028}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The first token that is missing (or out of order) in `text`, or nil when all are present in order.
    static func firstMissing(_ tokens: [String], in text: String) -> String? {
        let hay = normalized(text)
        var from = hay.startIndex
        for t in tokens {
            guard let r = hay.range(of: normalized(t), range: from..<hay.endIndex) else { return t }
            from = r.upperBound
        }
        return nil
    }

    static func missingAnywhere(_ tokens: [String], in text: String) -> [String] {
        let hay = normalized(text)
        return tokens.filter { !hay.contains(normalized($0)) }
    }

    /// Text of a result read by something other than our readers: PDFKit for PDF, textutil for the word-processor formats, unzip + a tag stripper for EPUB, the bytes for text.
    static func text(of url: URL) -> String {
        switch Formats.key(of: url) {
        case "pdf": return PDFDocument(url: url)?.string ?? ""
        case "docx", "odt", "rtf", "doc", "html": return SyncProcess.run(URL(fileURLWithPath: "/usr/bin/textutil"), ["-convert", "txt", "-encoding", "UTF-8", "-stdout", url.path], timeout: 30) ?? ""
        case "epub":
            let names = (SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", url.path], timeout: 20) ?? "").split(separator: "\n").map(String.init).filter { $0.hasSuffix(".xhtml") && $0.contains("/text/") }.sorted()
            return names.map { n in
                let x = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, unzipPattern(n)], timeout: 20) ?? ""
                return stripMarkup(x)
            }.joined(separator: "\n")
        case "md": return stripMarkdown((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        default: return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    /// Tags removed without touching the words around them: block ends become line breaks, inline tags vanish.
    static func stripMarkup(_ x: String) -> String {
        var t = x.replacingOccurrences(of: "</(p|h[1-6]|li|div|tr|td|th|pre|blockquote|ul|ol|table)>|<br\\s*/?>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    /// Markdown reduced to its words: emphasis marks, code ticks, link targets, heading hashes, table bars and escapes removed.
    static func stripMarkdown(_ md: String) -> String {
        var t = md
        t = t.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "<(https?://[^>]+)>", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(\\*\\*|__|~~)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*([-*+]|\\d+[.)])\\s+(\\[[ xX]\\]\\s+)?", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "</?(u|del|b|i|em|strong|code)>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
        t = t.replacingOccurrences(of: "\\\\([\\\\`*_{}\\[\\]()#+\\-.!|<>~&])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\|?[\\s:|-]+\\|?$", with: "", options: .regularExpression)
        return t
    }

    /// `/usr/bin/file --mime-type`.
    static func mime(_ url: URL) -> String {
        (SyncProcess.run(URL(fileURLWithPath: "/usr/bin/file"), ["--mime-type", "-b", url.path], timeout: 10) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let expectedMime: [String: [String]] = [
        "docx": ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"], "odt": ["application/vnd.oasis.opendocument.text"],
        "pdf": ["application/pdf"], "epub": ["application/epub+zip"], "rtf": ["text/rtf"], "html": ["text/html"], "txt": ["text/plain"],
        "md": ["text/plain", "text/markdown", "text/x-markdown"], "doc": ["application/msword"]
    ]

    /// Entry names of a zip read with unzip (central directory), in order.
    static func zipNames(_ url: URL) -> [String] { (SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", url.path], timeout: 20) ?? "").split(separator: "\n").map(String.init) }

    /// unzip matches names as wildcards: "[Content_Types].xml" must be escaped to be found.
    static func unzipPattern(_ name: String) -> String { name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]") }

    static func zipPart(_ url: URL, _ name: String) -> String { SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, unzipPattern(name)], timeout: 20) ?? "" }

    /// "line 7: got X, expected Y" for the first difference between two outlines, nil when equal.
    static func firstDifference(_ got: [String], _ expected: [String]) -> String? {
        for i in 0..<max(got.count, expected.count) {
            let g = i < got.count ? got[i] : "(nothing)", e = i < expected.count ? expected[i] : "(nothing)"
            if g != e { return "line \(i + 1): got \"\(g.prefix(90))\", expected \"\(e.prefix(90))\"" }
        }
        return nil
    }

    /// Names of XML parts of a zip that xmllint rejects.
    static func xmlProblems(in zip: URL, fx: TestFixtures) -> [String] {
        var bad: [String] = []
        for n in zipNames(zip) where n.hasSuffix(".xml") || n.hasSuffix(".xhtml") || n.hasSuffix(".rels") || n.hasSuffix(".opf") || n.hasSuffix(".ncx") {
            let part = fx.url("xml-check-\(Util.hex8()).xml")
            guard let data = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", zip.path, unzipPattern(n)], timeout: 20)?.data(using: .utf8) else { continue }
            try? data.write(to: part)
            let r = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/xmllint"), ["--noout", part.path], timeout: 20) ?? ""
            if !r.isEmpty { bad.append("\(n): \(r.prefix(160))") }
        }
        return bad
    }

    /// Structure of a model as comparable lines: the oracle for "headings, lists and tables survive".
    static func outline(_ blocks: [DocBlock], depth: Int = 0) -> [String] {
        var out: [String] = []
        for b in blocks {
            switch b {
            case .heading(let l, let c): out.append("h\(l) \(normalized(c.plainText))")
            case .paragraph(let c): if !c.isBlank { out.append("p \(normalized(c.plainText))") }
            case .list(let l):
                for (i, item) in l.items.enumerated() {
                    let first = item.blocks.first.map { b -> String in if case .paragraph(let c) = b { return normalized(c.plainText) } else { return "" } } ?? ""
                    out.append("\(l.ordered ? "ol" : "ul")\(depth) \(l.ordered ? "\(l.start + i) " : "")\(first)")
                    for rest in item.blocks.dropFirst() { out += outline([rest], depth: depth + 1) }
                }
            case .table(let t):
                if let h = t.header { out.append("th " + h.map { normalized($0.plainText) }.joined(separator: "|")) }
                for r in t.rows { out.append("tr " + r.map { normalized($0.plainText) }.joined(separator: "|")) }
            case .quote(let inner): out += outline(inner, depth: depth).map { "q " + $0 }
            case .code(_, let t): out.append("code " + t)
            case .rule: out.append("hr")
            case .pageBreak: break
            }
        }
        return out
    }
}

// MARK: - Runner

/// Runs operations of the catalogue the way the job runner does. Unless a test sets `doc.engine` itself, the built-in engine is pinned, so results never depend on whether
/// LibreOffice or Pandoc happen to be installed on the Mac that runs the tests.
@MainActor
enum DocRun {
    static func op(_ id: String) throws -> Operation {
        try unwrap(DocsCatalog.operations().first { $0.meta.id == id }, "operation \(id) is not in the documents catalogue")
    }

    static func context(_ operation: Operation, _ items: [FileItem], extra: OptionValues = OptionValues(), mode: RunMode = .quick, rules: OutputRules = OutputRules(),
                        tools: ToolLocator = .shared, settings: SettingsData = SettingsData(), pinNative: Bool = true) -> OperationContext {
        var layer = extra
        if pinNative, !layer.has(DocKeys.engine), operation.meta.schemaID == DocSchemas.convertID { layer[DocKeys.engine] = "native" }
        let resolved = operation.optionSchema(for: items).resolve(layers: [operation.quickOverrides(settings: settings), layer])
        return OperationContext(operationID: operation.meta.id, mode: mode, resolved: resolved, outputRules: rules, settings: settings, tools: tools)
    }

    @discardableResult
    static func run(_ id: String, _ files: [URL], _ extra: OptionValues = OptionValues(), mode: RunMode = .quick, rules: OutputRules = OutputRules(),
                    tools: ToolLocator = .shared, pinNative: Bool = true, log: ((String) -> Void)? = nil) async throws -> OperationResult {
        let operation = try op(id)
        let items = FileItem.items(files)
        let ctx = context(operation, items, extra: extra, mode: mode, rules: rules, tools: tools, pinNative: pinNative)
        if let log { ctx.onLog = { log($0) } }
        defer { ctx.cleanupTemp() }
        return try await operation.execute(items: items, ctx: ctx)
    }

    /// Output rules that put results into `dir`.
    static func into(_ dir: URL) -> OutputRules { var r = OutputRules(); r.dirMode = .custom; r.customDir = dir.path; return r }

    /// Studio-style run of the operation that makes `target` with the given options.
    @discardableResult
    static func convert(_ file: URL, to target: String, _ extra: OptionValues = OptionValues(), into dir: URL, tools: ToolLocator = .shared, pinNative: Bool = true) async throws -> URL {
        var values = extra
        values[DocKeys.format] = .string(target)
        let r = try await run("doc.to.\(target)", [file], values, mode: .studio, rules: into(dir), tools: tools, pinNative: pinNative)
        return try unwrap(r.outputs.first, "no output for \(target)")
    }
}
