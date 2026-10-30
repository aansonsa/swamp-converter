import Foundation

// Facts about a document or a deck for the Studio inspector and the schema conditions. Cheap by design (a few milliseconds): text files are sampled (the first MiB),
// OOXML / ODF files give their own statistics from a tiny part of the package (docProps/app.xml, meta.xml), nothing is converted and no page is laid out.
//   container (the format key), text.encoding, text.lines, doc.words, doc.pages, slides.count

struct DocSourceProbe: SourceProbe {
    func probe(_ item: FileItem) async -> SourceInfo {
        var info = SourceInfo(url: item.url, kind: item.kind)
        let key = item.key
        info.facts["container"] = .string(key)
        info.chips.append(SourceChip(symbol: "doc.text", text: Formats.displayName(key)))
        if let size = item.size { info.chips.append(SourceChip(symbol: "internaldrive", text: Util.formatBytes(size))) }
        switch key {
        case "txt", "md", "html": textFacts(item, key: key, into: &info)
        case "docx": packageFacts(item.url, part: "docProps/app.xml", pages: "Pages", words: "Words", slides: nil, into: &info)
        case "pptx": packageFacts(item.url, part: "docProps/app.xml", pages: nil, words: nil, slides: "Slides", into: &info)
        case "odt", "odp": odfFacts(item.url, slides: key == "odp", into: &info)
        case "doc", "rtf": info.facts["doc.legacy"] = .bool(true)
        default: break
        }
        if key == "doc" || key == "ppt" {
            info.warnings.append(L10n("An old binary format. It is read through the system (doc) or LibreOffice (ppt); layout details may differ.",
                                      "Старый двоичный формат. Он читается средствами системы (doc) или LibreOffice (ppt); детали вёрстки могут отличаться."))
        }
        return info
    }

    private func textFacts(_ item: FileItem, key: String, into info: inout SourceInfo) {
        guard let h = try? FileHandle(forReadingFrom: item.url) else { return }
        defer { try? h.close() }
        let sample = (try? h.read(upToCount: 1 << 20)) ?? Data()
        guard !sample.isEmpty else { return }
        var det = DocTextCodec.detect(sample)
        if key == "html", !det.hasBOM, let declared = DocNative.declaredCharset(sample), det.id == "utf-8" || DocTextCodec.stringEncoding(declared) != nil { det.id = declared }
        info.facts["text.encoding"] = .string(det.id)
        info.chips.append(SourceChip(symbol: "textformat", text: DocTextCodec.displayName(det.id).text))
        if det.id != "utf-8" && !det.id.hasPrefix("utf-16") {
            info.warnings.append(L10n("The text is not UTF-8 (looks like \(DocTextCodec.displayName(det.id).en)). Converting to UTF-8 makes it open correctly everywhere.",
                                      "Текст не в UTF-8 (похоже на \(DocTextCodec.displayName(det.id).ru)). После конвертации в UTF-8 он везде откроется правильно."))
        }
        if key != "html", let lines = DocTextCodec.countLines(item.url) {
            info.facts["text.lines"] = .int(lines.lines)
            info.chips.append(SourceChip(symbol: "text.alignleft", text: L("\(lines.lines) lines", "строк: \(lines.lines)")))
        }
        let text = DocTextCodec.decode(sample, as: det.id).text
        let visible = key == "html" ? text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression) : text
        var words = DocModel.wordCount(visible)
        if let size = item.size, Int(size) > sample.count, sample.count > 0 { words = Int(Double(words) * Double(size) / Double(sample.count)) }
        info.facts["doc.words"] = .int(words)
        info.chips.append(SourceChip(symbol: "character.cursor.ibeam", text: L("\(words) words", "слов: \(words)")))
    }

    private func packageFacts(_ url: URL, part: String, pages: String?, words: String?, slides: String?, into info: inout SourceInfo) {
        guard let data = try? ZipKit.read(url, entry: part, limit: 1 << 20), let root = try? DocXML.parse(data) else { return }
        func number(_ tag: String?) -> Int? {
            guard let tag, let node = root.child(tag) else { return nil }
            return Int(node.textContent.trimmingCharacters(in: .whitespaces))
        }
        if let p = number(pages), p > 0 {
            info.facts["doc.pages"] = .int(p)
            info.chips.append(SourceChip(symbol: "doc.on.doc", text: Loc.pages(p)))
        }
        if let w = number(words), w > 0 {
            info.facts["doc.words"] = .int(w)
            info.chips.append(SourceChip(symbol: "character.cursor.ibeam", text: L("\(w) words", "слов: \(w)")))
        }
        if let s = number(slides), s > 0 { addSlides(s, into: &info) }
    }

    private func odfFacts(_ url: URL, slides: Bool, into info: inout SourceInfo) {
        guard let data = try? ZipKit.read(url, entry: "meta.xml", limit: 1 << 20), let root = try? DocXML.parse(data),
              let stat = root.child("office:meta")?.child("meta:document-statistic") else { return }
        if slides {
            if let s = stat["meta:page-count"].flatMap(Int.init), s > 0 { addSlides(s, into: &info) }
            return
        }
        if let p = stat["meta:page-count"].flatMap(Int.init), p > 0 { info.facts["doc.pages"] = .int(p); info.chips.append(SourceChip(symbol: "doc.on.doc", text: Loc.pages(p))) }
        if let w = stat["meta:word-count"].flatMap(Int.init), w > 0 { info.facts["doc.words"] = .int(w); info.chips.append(SourceChip(symbol: "character.cursor.ibeam", text: L("\(w) words", "слов: \(w)"))) }
    }

    private func addSlides(_ n: Int, into info: inout SourceInfo) {
        info.facts["slides.count"] = .int(n)
        info.chips.append(SourceChip(symbol: "rectangle.on.rectangle.angled", text: Loc.plural(n, enOne: "\(n) slide", enOther: "\(n) slides", ruOne: "\(n) слайд", ruFew: "\(n) слайда", ruMany: "\(n) слайдов")))
    }
}
