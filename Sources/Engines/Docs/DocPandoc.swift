import Foundation

// Pandoc as an optional upgrade (spec/backends.md 3.4). The argument list is a pure function of the pair and the options, so the golden tests run without Pandoc.
// Pandoc always writes UTF-8; encodings other than UTF-8 are therefore handled by the built-in engine (the router sees to it). A plain .txt is never read by Pandoc.

struct DocPandocVersion: Comparable, Sendable {
    var major: Int, minor: Int
    static func < (a: Self, b: Self) -> Bool { (a.major, a.minor) < (b.major, b.minor) }

    /// "pandoc 3.1.11.1" / "pandoc.exe 2.19.2".
    init?(_ line: String?) {
        guard let line, let r = line.range(of: "[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
        let parts = line[r].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        major = parts[0]; minor = parts[1]
    }
    init(major: Int, minor: Int) { self.major = major; self.minor = minor }
    /// `--embed-resources` replaced `--self-contained` in 2.19.
    var hasEmbedResources: Bool { self >= DocPandocVersion(major: 2, minor: 19) }
    /// `--split-level` for EPUB chapters arrived in 3.0.
    var hasSplitLevel: Bool { major >= 3 }
    /// `--epub-title-page=false` (no generated title page, which read as an extra chapter heading); certainly there from 3.2.
    var hasEpubTitlePage: Bool { self >= DocPandocVersion(major: 3, minor: 2) }
}

enum DocPandoc {
    static func readerName(_ key: String, gfm: Bool) -> String {
        switch key {
        case "md": return gfm ? "gfm" : "commonmark"
        default: return key
        }
    }

    static func writerName(_ key: String, gfm: Bool) -> String {
        switch key {
        case "md": return gfm ? "gfm" : "commonmark"
        case "txt": return "plain"
        case "html": return "html5"
        case "epub": return "epub3"
        default: return key
        }
    }

    /// A Lua filter that keeps the source's own structure (pandoc's readers add things the built-in engine never does):
    /// - the HTML `<title>` or the DOCX title property becomes document metadata, and the writers print it as an extra first heading ("Title" in DOCX, a title
    ///   block in HTML). It is kept as the page title only, unless the person typed a title (`keepTitle`) or the target is EPUB (which needs one);
    /// - Markdown tables must have a header row: a table without one got an empty header. Its first row becomes the header (`promoteHeader`).
    static func filterSource(keepTitle: Bool, promoteHeader: Bool) -> String {
        """
        -- Swamp Converter: keep the structure of the source document.
        local keep_title = \(keepTitle)
        local promote_header = \(promoteHeader)
        function Meta(m)
          if not keep_title and m.title ~= nil then
            if m.pagetitle == nil then m.pagetitle = m.title end
            m.title = nil
          end
          return m
        end
        function Table(t)
          if promote_header and #t.head.rows == 0 and #t.bodies > 0 and #t.bodies[1].body > 0 then
            t.head.rows = { table.remove(t.bodies[1].body, 1) }
            return t
          end
        end
        """
    }

    /// The filter settings for one conversion.
    static func filterNeeds(target: String, settings s: DocSettings) -> (keepTitle: Bool, promoteHeader: Bool) {
        (keepTitle: s.title != nil || target == "epub", promoteHeader: target == "md")
    }

    /// Everything after the executable. `mediaFolder` is the name of the folder pandoc should extract pictures to (relative to the working directory);
    /// `filter` is the path of the file written from `filterSource`.
    static func arguments(input: URL, inputKey: String, target: String, output: URL, settings s: DocSettings, baseName: String,
                          version: DocPandocVersion?, mediaFolder: String? = nil, filter: String? = nil) -> [String] {
        var a = [input.path, "-f", readerName(inputKey, gfm: s.markdownGFM), "-t", writerName(target, gfm: s.markdownGFM), "-o", output.path, "--quiet"]
        if ["html", "rtf", "epub"].contains(target) || inputKey == "html" { a.append("--standalone") }
        if target == "html" && s.htmlEmbed {
            a.append((version?.hasEmbedResources ?? true) ? "--embed-resources" : "--self-contained")
            if !a.contains("--standalone") { a.append("--standalone") }
        }
        // HTML gets a page title for the browser tab, not a title heading (the file's own first heading stays the first one); EPUB requires a real title.
        if target == "html" { a += ["--metadata", "pagetitle=" + (s.title ?? baseName)] }
        if target == "epub" { a += ["--metadata", "title=" + (s.title ?? baseName)] }
        if let t = s.title, target != "epub" { a += ["--metadata", "title=" + t] }
        if let author = s.author { a += ["--metadata", "author=" + author] }
        if let lang = s.language { a += ["--metadata", "lang=" + lang] }
        if target == "txt" || target == "md" { a.append(s.wrap > 0 && target == "txt" ? "--wrap=auto" : "--wrap=none") }
        if target == "txt" && s.wrap > 0 { a.append("--columns=\(s.wrap)") }
        if ["txt", "md", "html"].contains(target) { a.append("--eol=" + (s.eol == "crlf" ? "crlf" : "lf")) }
        if target == "md", s.extractMedia, ["docx", "odt", "epub"].contains(inputKey), let f = mediaFolder { a.append("--extract-media=" + f) }
        if target == "epub" {
            if !s.epubCover.isEmpty { a.append("--epub-cover-image=" + s.epubCover) }
            if version?.hasSplitLevel ?? true { a.append("--split-level=\(max(1, s.epubSplit == 0 ? 6 : s.epubSplit))") }
            if version?.hasEpubTitlePage ?? true { a.append("--epub-title-page=false") }
        }
        if target == "md" && s.frontMatter { a.append("--standalone") }
        if let filter { a.append("--lua-filter=" + filter) }
        a.append("--resource-path=" + input.deletingLastPathComponent().path)
        return a
    }
}
