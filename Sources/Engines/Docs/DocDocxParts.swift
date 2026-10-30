import Foundation

// The fixed parts of a DOCX package: content types, relationships, styles, numbering, settings and document properties.

extension DocDocxWriter.Builder {
    private static let wNS = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    func packageParts(body: String) -> [DocPackage.Part] {
        var parts: [DocPackage.Part] = []
        let decl = DocXML.declaration
        // [Content_Types].xml
        var ct = decl + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for ext in usedExtensions.sorted() { ct += "<Default Extension=\"\(ext)\" ContentType=\"\(DocMediaKind.mime(forExtension: ext))\"/>" }
        let wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        ct += "<Override PartName=\"/word/document.xml\" ContentType=\"\(wml).document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"\(wml).styles+xml\"/>"
        ct += "<Override PartName=\"/word/numbering.xml\" ContentType=\"\(wml).numbering+xml\"/><Override PartName=\"/word/settings.xml\" ContentType=\"\(wml).settings+xml\"/>"
        ct += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>"
        parts.append(.init(name: "[Content_Types].xml", data: Data(ct.utf8)))
        parts.append(.init(name: "_rels/.rels", data: Data((decl + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>").utf8)))
        // document.xml
        let docNS = "\(Self.wNS) xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
        parts.append(.init(name: "word/document.xml", data: Data((decl + "<w:document \(docNS)><w:body>\(body)</w:body></w:document>").utf8)))
        // relationships of the document
        var rr = decl + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        rr += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        rr += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
        rr += "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>"
        for r in rels { rr += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(DocXML.attr(r.target))\"" + (r.external ? " TargetMode=\"External\"" : "") + "/>" }
        parts.append(.init(name: "word/_rels/document.xml.rels", data: Data((rr + "</Relationships>").utf8)))
        parts.append(.init(name: "word/styles.xml", data: Data(styles().utf8)))
        parts.append(.init(name: "word/numbering.xml", data: Data(numbering().utf8)))
        parts.append(.init(name: "word/settings.xml", data: Data((decl + "<w:settings \(Self.wNS)><w:defaultTabStop w:val=\"720\"/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>").utf8)))
        parts.append(.init(name: "docProps/core.xml", data: Data(core().utf8)))
        let words = DocModel.wordCount(model.plainText)
        parts.append(.init(name: "docProps/app.xml", data: Data((decl + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Swamp Converter</Application><Words>\(words)</Words></Properties>").utf8)))
        parts += mediaParts
        return parts
    }

    private func core() -> String {
        var s = DocXML.declaration + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        if o.includeAuthorAndTitle {
            if let t = model.meta.title, !t.isEmpty { s += "<dc:title>\(DocXML.escape(t))</dc:title>" }
            if let a = model.meta.author, !a.isEmpty { s += "<dc:creator>\(DocXML.escape(a))</dc:creator>" }
        }
        if o.includeDates {
            let now = DocXML.isoDate(Date())
            s += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(DocXML.isoDate(model.meta.created ?? Date()))</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified>"
        }
        return s + "</cp:coreProperties>"
    }

    // MARK: styles.xml

    private func styles() -> String {
        let sz = Int(o.fontSize * 2)
        let line = Int((o.lineSpacing * 240).rounded())
        let font = DocXML.attr(o.font)
        let lang = DocXML.attr(model.meta.language ?? "en-US")
        func heading(_ n: Int, size: Int, color: String) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(n == 1 ? 360 : 240)\" w:after=\"80\"/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:cs=\"\(font)\"/><w:b/><w:bCs/><w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        var s = DocXML.declaration + "<w:styles \(Self.wNS)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:eastAsia=\"\(font)\" w:cs=\"\(font)\"/><w:sz w:val=\"\(sz)\"/><w:szCs w:val=\"\(sz)\"/><w:lang w:val=\"\(lang)\" w:eastAsia=\"\(lang)\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault>"
        s += "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"\(line)\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
        s += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        s += "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/></w:style>"
        s += "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
        let sizes = [(40, "1F1F1F"), (32, "1F1F1F"), (28, "1F1F1F"), (26, "1F1F1F"), (24, "404040"), (22, "404040")]
        for (i, h) in sizes.enumerated() { s += heading(i + 1, size: h.0 * sz / 22, color: h.1) }
        s += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"CodeBlock\"><w:name w:val=\"Code Block\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:contextualSpacing/></w:pPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"BFBFBF\"/></w:pBdr><w:ind w:left=\"720\"/></w:pPr><w:rPr><w:i/><w:iCs/><w:color w:val=\"404040\"/></w:rPr></w:style>"
        s += "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"34\"/><w:qFormat/><w:pPr><w:spacing w:after=\"60\"/><w:ind w:left=\"720\"/></w:pPr></w:style>"
        s += "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/><w:uiPriority w:val=\"39\"/><w:tblPr><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/></w:tblBorders></w:tblPr></w:style>"
        return s + "</w:styles>"
    }

    // MARK: numbering.xml

    private func numbering() -> String {
        func levels(bullet: Bool) -> String {
            var s = ""
            let bulletMarks = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
            let numFormats = ["decimal", "lowerLetter", "lowerRoman"]
            for l in 0..<9 {
                let left = 720 * (l + 1)
                s += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/>"
                if bullet {
                    s += "<w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bulletMarks[l % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\" w:hint=\"default\"/></w:rPr>"
                } else {
                    s += "<w:numFmt w:val=\"\(numFormats[l % 3])\"/><w:lvlText w:val=\"%\(l + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr>"
                }
                s += "</w:lvl>"
            }
            return s
        }
        var s = DocXML.declaration + "<w:numbering \(Self.wNS)>"
        s += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(bullet: true))</w:abstractNum>"
        s += "<w:abstractNum w:abstractNumId=\"2\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(bullet: false))</w:abstractNum>"
        s += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num>"
        for l in orderedLists {
            s += "<w:num w:numId=\"\(l.numId)\"><w:abstractNumId w:val=\"2\"/>"
            if l.start != 1 { s += "<w:lvlOverride w:ilvl=\"\(l.level)\"><w:startOverride w:val=\"\(l.start)\"/></w:lvlOverride>" }
            s += "</w:num>"
        }
        return s + "</w:numbering>"
    }
}
