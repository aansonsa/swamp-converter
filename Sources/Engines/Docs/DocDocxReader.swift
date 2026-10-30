import Foundation

// DOCX -> DocModel. Reads word/document.xml directly (headings from style names and outline levels, lists from numbering.xml, tables, hyperlinks including field codes,
// pictures, bold / italic / underline / strike, monospace runs and styles). Headers, footers, footnotes, text boxes and tracked deletions are left out.

enum DocDocxReader {
    static func read(_ url: URL) throws -> DocModel {
        let pkg = try DocPackage.Reader(url: url)
        var mainPart = "word/document.xml"
        if let rels = try pkg.xml("_rels/.rels") {
            for r in rels.children("Relationship") where (r["Type"] ?? "").hasSuffix("/officeDocument") { if let t = r["Target"] { mainPart = pkg.resolve(t, relativeTo: "_rels/.rels").replacingOccurrences(of: "_rels/", with: "") ; if !pkg.has(mainPart) { mainPart = t.hasPrefix("/") ? String(t.dropFirst()) : t } } }
        }
        guard let doc = try pkg.xml(mainPart) else {
            throw ConversionError.message(L10n("This is not a Word document (no document part).", "Это не документ Word (нет основной части)."))
        }
        let folder = (mainPart as NSString).deletingLastPathComponent
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (mainPart as NSString).lastPathComponent + ".rels"
        let r = Reader(pkg: pkg, mainPart: mainPart, rels: DocRelationships(try pkg.xml(relsPath)))
        r.loadStyles(try pkg.xml((folder.isEmpty ? "" : folder + "/") + "styles.xml"))
        r.loadNumbering(try pkg.xml((folder.isEmpty ? "" : folder + "/") + "numbering.xml"))
        var model = DocModel()
        if let body = doc.child("w:body") {
            r.measureBodySize(body)
            let c = BlockCollector(reader: r)
            try r.collect(body, into: c)
            model.blocks = c.finish()
        }
        model.media = r.media.items
        if let core = try pkg.xml("docProps/core.xml") {
            model.meta.title = core.child("dc:title")?.textContent.nonEmpty
            model.meta.author = core.child("dc:creator")?.textContent.nonEmpty
            model.meta.created = DocXML.parseISODate(core.child("dcterms:created")?.textContent)
            model.meta.modified = DocXML.parseISODate(core.child("dcterms:modified")?.textContent)
        }
        model.meta.language = r.defaultLanguage
        return model
    }

    // MARK: Reader state

    struct StyleInfo {
        var name = ""
        var basedOn: String?
        var outline: Int?
        var bold = false, italic = false, mono = false
        var numId: Int?, ilvl: Int?
        /// Font size in half-points from the style's run properties.
        var halfPoints: Int?
    }

    /// What the runs of the paragraph being read looked like (used to recognise a heading that has no heading style).
    struct ParaStats {
        var anyText = false
        var allBold = true
        var maxHalfPoints = 0
    }

    struct LevelInfo { var format: String; var start: Int }

    final class Reader {
        let pkg: DocPackage.Reader
        let mainPart: String
        let rels: DocRelationships
        var media = DocMediaStore()
        var styles: [String: StyleInfo] = [:]
        var abstractLevels: [Int: [Int: LevelInfo]] = [:]
        var numToAbstract: [Int: Int] = [:]
        var numStartOverride: [Int: [Int: Int]] = [:]
        var defaultLanguage: String?
        /// Size of the body text in half-points: the Normal style, else the document default, else 11 pt.
        var bodyHalfPoints = 22
        var para = ParaStats()
        var paragraphHalfPoints: Int?
        private var imageCache: [String: String] = [:]

        init(pkg: DocPackage.Reader, mainPart: String, rels: DocRelationships) { self.pkg = pkg; self.mainPart = mainPart; self.rels = rels }

        // MARK: Styles and numbering

        func loadStyles(_ root: DocXMLNode?) {
            guard let root else { return }
            defaultLanguage = root.child("w:docDefaults")?.child("w:rPrDefault")?.child("w:rPr")?.child("w:lang")?["w:val"]
            if let hp = root.child("w:docDefaults")?.child("w:rPrDefault")?.child("w:rPr")?.child("w:sz")?["w:val"].flatMap(Int.init) { bodyHalfPoints = hp }
            for s in root.children("w:style") where s["w:type"] == "paragraph" || s["w:type"] == "character" {
                guard let id = s["w:styleId"] else { continue }
                var info = StyleInfo(name: s.child("w:name")?["w:val"] ?? id)
                info.basedOn = s.child("w:basedOn")?["w:val"]
                if let ppr = s.child("w:pPr") {
                    info.outline = ppr.child("w:outlineLvl")?["w:val"].flatMap(Int.init)
                    info.numId = ppr.child("w:numPr")?.child("w:numId")?["w:val"].flatMap(Int.init)
                    info.ilvl = ppr.child("w:numPr")?.child("w:ilvl")?["w:val"].flatMap(Int.init)
                }
                if let rpr = s.child("w:rPr") {
                    let p = runProps(rpr)
                    info.bold = p.bold; info.italic = p.italic; info.mono = p.mono
                    info.halfPoints = rpr.child("w:sz")?["w:val"].flatMap(Int.init)
                }
                if s["w:default"] == "1", s["w:type"] == "paragraph", let hp = info.halfPoints { bodyHalfPoints = hp }
                styles[id] = info
            }
        }

        func loadNumbering(_ root: DocXMLNode?) {
            guard let root else { return }
            for a in root.children("w:abstractNum") {
                guard let id = a["w:abstractNumId"].flatMap(Int.init) else { continue }
                var levels: [Int: LevelInfo] = [:]
                for l in a.children("w:lvl") {
                    guard let il = l["w:ilvl"].flatMap(Int.init) else { continue }
                    levels[il] = LevelInfo(format: l.child("w:numFmt")?["w:val"] ?? "decimal", start: l.child("w:start")?["w:val"].flatMap(Int.init) ?? 1)
                }
                abstractLevels[id] = levels
            }
            for n in root.children("w:num") {
                guard let id = n["w:numId"].flatMap(Int.init), let a = n.child("w:abstractNumId")?["w:val"].flatMap(Int.init) else { continue }
                numToAbstract[id] = a
                for o in n.children("w:lvlOverride") {
                    if let il = o["w:ilvl"].flatMap(Int.init), let st = o.child("w:startOverride")?["w:val"].flatMap(Int.init) { numStartOverride[id, default: [:]][il] = st }
                }
            }
        }

        func listInfo(numId: Int, level: Int) -> (ordered: Bool, start: Int) {
            let lvl = numToAbstract[numId].flatMap { abstractLevels[$0]?[level] }
            let ordered = (lvl?.format ?? "bullet") != "bullet" && lvl?.format != "none"
            return (ordered, numStartOverride[numId]?[level] ?? lvl?.start ?? 1)
        }

        /// The size most of the text is set in (by amount of text). Headings without a heading style are recognised against this, not against the document default.
        func measureBodySize(_ body: DocXMLNode) {
            var weights: [Int: Int] = [:]
            for p in body.descendants("w:p") {
                let styleID = p.child("w:pPr")?.child("w:pStyle")?["w:val"]
                let paragraphSize = styleChain(styleID).compactMap(\.halfPoints).first
                for r in p.children("w:r") {
                    let length = r.children("w:t").reduce(0) { $0 + $1.textContent.count }
                    guard length > 0 else { continue }
                    weights[r.child("w:rPr")?.child("w:sz")?["w:val"].flatMap(Int.init) ?? paragraphSize ?? bodyHalfPoints, default: 0] += length
                }
            }
            if let best = weights.max(by: { $0.value < $1.value })?.key { bodyHalfPoints = best }
        }

        // MARK: Style queries

        func styleChain(_ id: String?) -> [StyleInfo] {
            var out: [StyleInfo] = []
            var cur = id
            var guardCount = 0
            while let c = cur, let s = styles[c], guardCount < 12 { out.append(s); cur = s.basedOn; guardCount += 1 }
            return out
        }

        func headingLevel(styleID: String?, outline: Int?) -> Int? {
            // Files without styles.xml (generated by other tools) still name their styles Heading1 ...
            if styleChain(styleID).isEmpty, let sid = styleID?.lowercased() {
                if sid == "title" { return 1 }
                if sid.hasPrefix("heading"), let l = Int(sid.dropFirst(7).trimmingCharacters(in: .whitespaces)) { return min(max(l, 1), 6) }
            }
            for s in styleChain(styleID) {
                let n = s.name.lowercased()
                if n == "title" { return 1 }
                if n.hasPrefix("heading "), let l = Int(n.dropFirst(8)) { return min(max(l, 1), 6) }
                if let o = s.outline, o < 9 { return min(o + 1, 6) }
            }
            if let o = outline, o < 9 { return min(o + 1, 6) }
            return nil
        }

        func styleKind(_ id: String?) -> (code: Bool, quote: Bool, listBullet: Int?, listNumber: Int?) {
            var code = false, quote = false
            var lb: Int?, ln: Int?
            for s in styleChain(id) {
                let n = s.name.lowercased()
                if ["code", "source code", "preformatted text", "html preformatted", "code block", "macro text", "plain text", "html code"].contains(n) { code = true }
                if ["quote", "intense quote", "block text", "block quotation"].contains(n) { quote = true }
                if n.hasPrefix("list bullet") { lb = Int(n.dropFirst(11).trimmingCharacters(in: .whitespaces)).map { $0 - 1 } ?? 0 }
                if n.hasPrefix("list number") { ln = Int(n.dropFirst(11).trimmingCharacters(in: .whitespaces)).map { $0 - 1 } ?? 0 }
            }
            return (code, quote, lb, ln)
        }

        func inheritedNumbering(_ id: String?) -> (Int, Int)? {
            for s in styleChain(id) { if let n = s.numId { return (n, s.ilvl ?? 0) } }
            return nil
        }

        // MARK: Run properties

        struct RunProps { var bold = false, italic = false, underline = false, strike = false, mono = false, hidden = false, halfPoints: Int? = nil }

        static let monoFonts = ["courier", "consolas", "menlo", "monaco", "lucida console", "source code", "fira code", "sf mono", "andale mono", "liberation mono", "dejavu sans mono", "cascadia"]

        func runProps(_ rpr: DocXMLNode?) -> RunProps {
            var p = RunProps()
            guard let rpr else { return p }
            func on(_ n: String) -> Bool { rpr.child(n).map { !["0", "false", "off", "none"].contains(($0["w:val"] ?? "true").lowercased()) } ?? false }
            if let sid = rpr.child("w:rStyle")?["w:val"] {
                for s in styleChain(sid) {
                    if s.bold || s.name.lowercased() == "strong" { p.bold = true }
                    if s.italic || s.name.lowercased() == "emphasis" { p.italic = true }
                    if s.mono || s.name.lowercased().contains("code") { p.mono = true }
                }
            }
            if on("w:b") { p.bold = true }
            if on("w:i") { p.italic = true }
            if on("w:strike") || on("w:dstrike") { p.strike = true }
            if on("w:u") { p.underline = true }
            if on("w:vanish") { p.hidden = true }
            p.halfPoints = rpr.child("w:sz")?["w:val"].flatMap(Int.init)
            if let f = rpr.child("w:rFonts") {
                let name = (f["w:ascii"] ?? f["w:hAnsi"] ?? "").lowercased()
                if Self.monoFonts.contains(where: { name.contains($0) }) { p.mono = true }
            }
            return p
        }

        // MARK: Pictures

        /// Resolves a relationship id of the main part to a media key.
        func picture(rid: String) -> String? {
            if let k = imageCache[rid] { return k }
            guard let rel = rels[rid], !rel.external else { return nil }
            let path = pkg.resolve(rel.target, relativeTo: mainPart)
            guard let data = try? pkg.data(path, limit: 200_000_000), !data.isEmpty else { return nil }
            let key = media.add(data, suggestedName: (path as NSString).lastPathComponent)
            imageCache[rid] = key
            return key
        }
    }
}

extension String {
    var nonEmpty: String? { let t = trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
}
