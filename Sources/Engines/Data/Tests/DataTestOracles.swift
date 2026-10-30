import Foundation

// Independent oracles of the data tests: the code that WROTE a file is never the code that checks it. Python 3's standard library (zipfile, xml, csv) reads XLSX, ODS and
// CSV; /usr/bin/file sniffs the real type; PDFKit reads PDFs; LibreOffice (when installed) opens the results as a second opinion. Every oracle degrades to a SKIP when its
// tool is missing.

/// `expectEqual` for values that are already computed (its arguments are not autoclosures, so `await` may appear inside them).
func same<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    if actual != expected { throw TestFailure(message: "\(message.isEmpty ? "values differ" : message): got \(actual), expected \(expected)", file: "\(file)", line: line) }
}

enum DataOracle {
    static let python = "/usr/bin/python3"
    static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: python) }

    /// `file --mime-type -b`: the real type of a file by content, independent of its name.
    static func mime(_ url: URL) -> String {
        DataTestKit.run("/usr/bin/file", ["--mime-type", "-b", url.path]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a python script (isolated mode, no site packages) and returns stdout; throws a test failure with stderr on a non-zero exit.
    static func py(_ script: String, _ args: [String]) throws -> String {
        guard hasPython else { try skipTest("python3 is not installed") }
        let r = DataTestKit.run(python, ["-I", "-c", script] + args)
        if r.status != 0 { throw TestFailure(message: "python oracle failed: \(r.output)", file: #fileID, line: #line) }
        return r.output
    }

    // MARK: XLSX

    struct Cell: Equatable {
        var value: String
        /// OOXML cell type: "s" shared string, "n" / nil number, "b", "str", "inlineStr", "e".
        var type: String
        /// Style index (cellXfs).
        var style: Int
    }
    struct Sheet { var name: String; var rows: [[Cell?]]; var raw: String }

    static let xlsxScript = """
    import sys, zipfile, re, json
    import xml.etree.ElementTree as ET
    M = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
    R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
    z = zipfile.ZipFile(sys.argv[1])
    wb = ET.fromstring(z.read('xl/workbook.xml'))
    rels = {r.get('Id'): r.get('Target') for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
    sst = []
    if 'xl/sharedStrings.xml' in z.namelist():
        for si in ET.fromstring(z.read('xl/sharedStrings.xml')).iter(M + 'si'):
            sst.append(''.join(t.text or '' for t in si.iter(M + 't')))
    out = []
    for s in wb.find(M + 'sheets'):
        target = rels[s.get(R + 'id')]
        path = 'xl/' + target if not target.startswith('/') else target[1:]
        xml = z.read(path).decode('utf-8')
        root = ET.fromstring(xml)
        rows = []
        for r in root.iter(M + 'row'):
            rn = int(r.get('r'))
            while len(rows) < rn - 1: rows.append([])
            cells = []
            for c in r.findall(M + 'c'):
                col = 0
                for ch in re.match('[A-Z]+', c.get('r')).group(0): col = col * 26 + ord(ch) - 64
                while len(cells) < col - 1: cells.append(None)
                t = c.get('t'); v = c.find(M + 'v')
                if t == 's': val = sst[int(v.text)]
                elif t == 'inlineStr': val = ''.join(x.text or '' for x in c.iter(M + 't'))
                elif v is not None: val = v.text or ''
                else: val = ''
                cells.append({'v': val, 't': t or 'n', 's': int(c.get('s') or 0)})
            rows.append(cells)
        out.append({'name': s.get('name'), 'rows': rows, 'raw': xml[:4000]})
    styles = z.read('xl/styles.xml').decode('utf-8') if 'xl/styles.xml' in z.namelist() else ''
    print(json.dumps({'sheets': out, 'styles': styles, 'files': z.namelist()}))
    """

    struct XLSXDump { var sheets: [Sheet]; var styles: String; var files: [String] }

    static func xlsx(_ url: URL) throws -> XLSXDump {
        let text = try py(xlsxScript, [url.path])
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let sheets = obj["sheets"] as? [[String: Any]] else {
            throw TestFailure(message: "bad oracle output", file: #fileID, line: #line)
        }
        let list = sheets.map { s -> Sheet in
            let rows = (s["rows"] as? [[Any]] ?? []).map { row in row.map { c -> Cell? in
                guard let d = c as? [String: Any] else { return nil }
                return Cell(value: d["v"] as? String ?? "", type: d["t"] as? String ?? "n", style: d["s"] as? Int ?? 0)
            } }
            return Sheet(name: s["name"] as? String ?? "", rows: rows, raw: s["raw"] as? String ?? "")
        }
        return XLSXDump(sheets: list, styles: obj["styles"] as? String ?? "", files: obj["files"] as? [String] ?? [])
    }

    // MARK: ODS

    static let odsScript = """
    import sys, zipfile, json
    import xml.etree.ElementTree as ET
    T = '{urn:oasis:names:tc:opendocument:xmlns:table:1.0}'
    O = '{urn:oasis:names:tc:opendocument:xmlns:office:1.0}'
    X = '{urn:oasis:names:tc:opendocument:xmlns:text:1.0}'
    z = zipfile.ZipFile(sys.argv[1])
    names = z.namelist()
    info = z.infolist()[0]
    root = ET.fromstring(z.read('content.xml'))
    def text_of(cell):
        paras = []
        for p in cell.findall(X + 'p'):
            buf = []
            def walk(e):
                if e.text: buf.append(e.text)
                for ch in e:
                    if ch.tag == X + 's': buf.append(' ' * int(ch.get(X + 'c') or 1))
                    elif ch.tag == X + 'tab': buf.append('\\t')
                    elif ch.tag == X + 'line-break': buf.append('\\n')
                    else: walk(ch)
                    if ch.tail: buf.append(ch.tail)
            walk(p)
            paras.append(''.join(buf))
        return '\\n'.join(paras)
    sheets = []
    for tb in root.iter(T + 'table'):
        rows = []
        for r in tb.findall(T + 'table-row'):
            cells = []
            for c in r:
                if c.tag not in (T + 'table-cell', T + 'covered-table-cell'): continue
                rep = int(c.get(T + 'number-columns-repeated') or 1)
                vt = c.get(O + 'value-type')
                val = c.get(O + 'value') or c.get(O + 'date-value') or c.get(O + 'boolean-value') or text_of(c)
                cell = {'v': val, 't': vt or '', 'display': text_of(c), 's': c.get(T + 'style-name') or ''}
                for _ in range(min(rep, 50)): cells.append(cell)
            rr = int(r.get(T + 'number-rows-repeated') or 1)
            for _ in range(min(rr, 50)): rows.append(cells)
        sheets.append({'name': tb.get(T + 'name'), 'rows': rows})
    print(json.dumps({'sheets': sheets, 'files': names, 'first': info.filename, 'firstMethod': info.compress_type, 'content': z.read('content.xml').decode('utf-8')[:20000]}))
    """

    struct ODSDump { var sheets: [(name: String, rows: [[(value: String, type: String, style: String)]])]; var files: [String]; var first: String; var firstMethod: Int; var content: String }

    static func ods(_ url: URL) throws -> ODSDump {
        let text = try py(odsScript, [url.path])
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let sheets = obj["sheets"] as? [[String: Any]] else {
            throw TestFailure(message: "bad oracle output", file: #fileID, line: #line)
        }
        let list = sheets.map { s in
            (name: s["name"] as? String ?? "", rows: (s["rows"] as? [[[String: Any]]] ?? []).map { row in row.map { (value: $0["v"] as? String ?? "", type: $0["t"] as? String ?? "", style: $0["s"] as? String ?? "") } })
        }
        return ODSDump(sheets: list, files: obj["files"] as? [String] ?? [], first: obj["first"] as? String ?? "", firstMethod: obj["firstMethod"] as? Int ?? -1, content: obj["content"] as? String ?? "")
    }

    // MARK: CSV

    /// Rows of a delimited text file as Python's `csv` module reads them (encoding given explicitly; "utf-8-sig" removes a BOM).
    static func csv(_ url: URL, encoding: String, delimiter: String = ",") throws -> [[String]] {
        let script = """
        import sys, csv, json
        with open(sys.argv[1], encoding=sys.argv[2], newline='') as f:
            print(json.dumps(list(csv.reader(f, delimiter=sys.argv[3], quotechar='"'))))
        """
        let text = try py(script, [url.path, encoding, delimiter])
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String]]) ?? []
    }

    // MARK: LibreOffice as a second opinion

    static var soffice: URL? { ToolLocator.shared.url(.soffice) }

    /// Opens `url` in LibreOffice (headless, throw-away profile) and saves `format` ("csv", "xlsx", "xls", "ods", "pdf") into a fresh folder; returns the produced file.
    static func officeConvert(_ url: URL, to format: String, filter: String? = nil, in dir: URL) throws -> URL {
        guard let exe = soffice else { try skipTest("LibreOffice is not installed") }
        let profile = dir.appendingPathComponent("lo-profile-\(UUID().uuidString.prefix(6))")
        let out = dir.appendingPathComponent("lo-out-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = DataTestKit.run(exe.path, ["--headless", "--norestore", "--nolockcheck", "--nodefault", "--nofirststartwizard", "-env:UserInstallation=" + profile.absoluteString,
                                           "--convert-to", filter.map { "\(format):\($0)" } ?? format, "--outdir", out.path, url.path])
        let listing = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix("." + format) }.sorted()
        let produced = out.appendingPathComponent(listing.first ?? "missing")
        guard !listing.isEmpty else { throw TestFailure(message: "LibreOffice produced no .\(format): \(r.output)", file: #fileID, line: #line) }
        return produced
    }
}
