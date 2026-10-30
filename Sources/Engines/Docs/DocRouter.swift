import Foundation

// Which engine converts a given (input format, output format) pair. Pure functions of the pair, the engine choice, the options and the tools found on this Mac, so every rule
// is unit-tested with a fake `ToolLocator`.
//
// The built-in engine reads and writes all eight document formats, so a pair never lacks a route unless the person forces an engine that cannot do it. Pandoc and
// LibreOffice are optional upgrades (spec/catalog.md 3.5, adapted):
//   1. LibreOffice for word-processor files (doc docx odt rtf) going to pdf / docx / odt / rtf: it keeps the layout of the original, which our own layout cannot.
//   2. Pandoc for the structural formats it handles well (docx odt rtf md html epub in; docx odt rtf md html epub txt out).
//   3. LibreOffice opens a binary .doc, the built-in engine (or Pandoc) continues from the Word file it produced (headings and lists survive).
// The upgrades are used only when no option that ONLY the built-in writers honour (page size, margins, font, encodings ...) has been changed: an engine must never silently
// ignore what the person set. Forcing an engine in the Studio overrides this and the info line lists what that engine ignores.

enum DocRoute: String, Equatable, Sendable {
    case native, pandoc, soffice, pandocThenSoffice, sofficeThenPandoc, sofficeThenNative

    var tools: [Tool] {
        switch self {
        case .native: return []
        case .pandoc: return [.pandoc]
        case .soffice, .sofficeThenNative: return [.soffice]
        case .pandocThenSoffice, .sofficeThenPandoc: return [.pandoc, .soffice]
        }
    }

    /// Short engine name for chips and the log.
    var label: L10n {
        switch self {
        case .native: return L10n("Built-in", "Встроенный")
        case .pandoc: return L10n("Pandoc")
        case .soffice: return L10n("LibreOffice")
        case .pandocThenSoffice: return L10n("Pandoc + LibreOffice")
        case .sofficeThenPandoc: return L10n("LibreOffice + Pandoc")
        case .sofficeThenNative: return L10n("LibreOffice + built-in", "LibreOffice + встроенный")
        }
    }

    /// The calm sentence of the Studio info line: who converts and what that engine keeps.
    var explanation: L10n {
        switch self {
        case .native:
            return L10n("Built-in engine: keeps text, headings, lists, tables, links and pictures. Page layout, columns and the fonts of the original are not kept.",
                        "Встроенный движок: сохраняет текст, заголовки, списки, таблицы, ссылки и картинки. Разметка страниц, колонки и шрифты оригинала не сохраняются.")
        case .soffice:
            return L10n("LibreOffice: keeps the layout of the original as far as LibreOffice can. Page, font and encoding options below do not apply.",
                        "LibreOffice: сохраняет вёрстку оригинала в пределах возможностей LibreOffice. Параметры страницы, шрифта и кодировки ниже не применяются.")
        case .pandoc:
            return L10n("Pandoc: converts the structure (headings, lists, tables, notes); page layout is not kept. Page, font and encoding options below do not apply.",
                        "Pandoc: переносит структуру (заголовки, списки, таблицы, сноски); разметка страниц не сохраняется. Параметры страницы, шрифта и кодировки ниже не применяются.")
        case .pandocThenSoffice:
            return L10n("Pandoc and LibreOffice: the structure goes through a Word file and LibreOffice makes the final file.",
                        "Pandoc и LibreOffice: структура проходит через файл Word, итоговый файл создаёт LibreOffice.")
        case .sofficeThenPandoc:
            return L10n("LibreOffice opens the old file, Pandoc writes the result; page layout is not kept.",
                        "LibreOffice открывает старый файл, Pandoc записывает результат; разметка страниц не сохраняется.")
        case .sofficeThenNative:
            return L10n("LibreOffice opens the old .doc file, then the built-in engine writes the result (headings, lists and tables survive).",
                        "LibreOffice открывает старый файл .doc, затем результат записывает встроенный движок (заголовки, списки и таблицы сохраняются).")
        }
    }
}

/// What the router needs to know about the Mac: is a tool there? `ToolLocator` answers for real; tests answer with a fixed set.
protocol DocToolProbe {
    func has(_ tool: Tool) -> Bool
}

extension ToolLocator: DocToolProbe {}

struct DocFakeTools: DocToolProbe {
    var present: Set<Tool>
    init(_ present: Tool...) { self.present = Set(present) }
    func has(_ tool: Tool) -> Bool { tool.isBuiltIn || present.contains(tool) }
}

enum DocRouteDecision: Equatable, Sendable {
    case route(DocRoute)
    case none(reason: L10n, missing: [Tool])

    var route: DocRoute? { if case .route(let r) = self { return r } else { return nil } }
}

enum DocRouter {
    static let nativeReads: Set<String> = ["docx", "doc", "odt", "rtf", "md", "txt", "html", "epub"]
    static let nativeWrites: Set<String> = ["docx", "pdf", "odt", "md", "html", "txt", "epub", "rtf"]
    static let sofficeReads: Set<String> = ["doc", "docx", "odt", "rtf", "txt", "html"]
    /// Pandoc is deliberately not used for plain text input: it would parse a .txt as Markdown (`*` and `#` turn into formatting).
    static let pandocReads: Set<String> = ["docx", "odt", "rtf", "md", "html", "epub"]
    static let pandocWrites: Set<String> = ["docx", "odt", "rtf", "md", "html", "txt", "epub"]
    static let wordProcessor: Set<String> = ["doc", "docx", "odt", "rtf"]
    static let pageTargets: Set<String> = ["pdf", "docx", "odt", "rtf"]

    static func sofficeWrites(_ target: String, input: String) -> Bool {
        switch target {
        case "pdf", "docx", "odt", "txt", "html": return true
        case "rtf": return input != "html"
        default: return false
        }
    }

    static func nativeReadable(_ input: String, tools: DocToolProbe) -> Bool {
        guard nativeReads.contains(input) else { return false }
        return (input == "doc" || input == "rtf") ? tools.has(.textutil) : true
    }

    static func displayName(_ key: String) -> String { Formats.displayName(key) }

    static func noRoute(_ input: String, _ target: String, missing: [Tool], engineName: String? = nil) -> DocRouteDecision {
        let a = displayName(input), b = displayName(target)
        if let engineName {
            return .none(reason: L10n("Converting \(a) to \(b) with \(engineName) is not possible on this Mac.", "Конвертация \(a) в \(b) через \(engineName) на этом Mac невозможна."), missing: missing)
        }
        return .none(reason: L10n("Converting \(a) to \(b) needs Pandoc or LibreOffice.", "Для конвертации \(a) в \(b) требуется Pandoc или LibreOffice."), missing: [.pandoc, .soffice])
    }

    /// `engine` is the value of `doc.engine`. `nativeOptionsChanged` = options only the built-in writers honour have been changed (see `DocSettings.nativeOnlyChanges`).
    static func route(input: String, target: String, engine: String = "auto", nativeOptionsChanged: Bool = false, tools: DocToolProbe) -> DocRouteDecision {
        let hasLO = tools.has(.soffice), hasPandoc = tools.has(.pandoc)
        let nativeOK = nativeReadable(input, tools: tools) && nativeWrites.contains(target)
        switch engine {
        case "native":
            return nativeOK ? .route(.native) : noRoute(input, target, missing: [], engineName: L("the built-in engine", "встроенный движок"))
        case "soffice":
            guard hasLO else { return noRoute(input, target, missing: [.soffice], engineName: "LibreOffice") }
            if sofficeReads.contains(input) && sofficeWrites(target, input: input) { return .route(.soffice) }
            if pandocReads.contains(input) && hasPandoc && sofficeWrites(target, input: "docx") { return .route(.pandocThenSoffice) }
            return noRoute(input, target, missing: pandocReads.contains(input) ? [.pandoc] : [], engineName: "LibreOffice")
        case "pandoc":
            guard hasPandoc else { return noRoute(input, target, missing: [.pandoc], engineName: "Pandoc") }
            if pandocReads.contains(input) && pandocWrites.contains(target) { return .route(.pandoc) }
            if pandocReads.contains(input) && target == "pdf" { return hasLO ? .route(.pandocThenSoffice) : noRoute(input, target, missing: [.soffice], engineName: "Pandoc") }
            if input == "doc" && hasLO && pandocWrites.contains(target) { return .route(.sofficeThenPandoc) }
            return noRoute(input, target, missing: input == "doc" ? [.soffice] : [], engineName: "Pandoc")
        default:
            break
        }
        // Automatic.
        if !nativeOptionsChanged && input != target {
            if hasLO, wordProcessor.contains(input), pageTargets.contains(target), sofficeReads.contains(input), sofficeWrites(target, input: input) { return .route(.soffice) }
            if hasPandoc, pandocReads.contains(input), pandocWrites.contains(target) { return .route(.pandoc) }
        }
        if input == "doc" && hasLO && nativeWrites.contains(target) {
            if !nativeOptionsChanged && hasPandoc && pandocWrites.contains(target) && input != target { return .route(.sofficeThenPandoc) }
            return .route(.sofficeThenNative)
        }
        if nativeOK { return .route(.native) }
        // Not reachable for the eight formats; kept so the router never invents a route.
        if hasLO, sofficeReads.contains(input), sofficeWrites(target, input: input) { return .route(.soffice) }
        if hasPandoc, pandocReads.contains(input), pandocWrites.contains(target) { return .route(.pandoc) }
        return noRoute(input, target, missing: [])
    }
}

extension DocSettings {
    /// Keys of options that only the built-in writers honour and that differ from the quick recipe, for `target`.
    func nativeOnlyChanges(for target: String) -> [String] {
        let d = DocSettings()
        var keys: [String] = []
        if DocRouter.pageTargets.contains(target) {
            if pageSize != d.pageSize { keys.append(DocKeys.pageSize) }
            if marginMM != d.marginMM { keys.append(DocKeys.margins) }
            if font != d.font { keys.append(DocKeys.font) }
            if fontSize != d.fontSize { keys.append(DocKeys.fontSize) }
            if lineSpacing != d.lineSpacing { keys.append(DocKeys.lineSpacing) }
        }
        if target == "pdf" && pageNumbers { keys.append(DocKeys.pageNumbers) }
        if ["txt", "md", "html"].contains(target) {
            if encodingOut != d.encodingOut { keys.append(DocKeys.encodingOut) }
            if bom { keys.append(DocKeys.bom) }
            if eol != d.eol { keys.append(DocKeys.eol) }
        }
        if target == "txt" && wrap != d.wrap { keys.append(DocKeys.wrap) }
        if target == "md" && (markdownGFM != d.markdownGFM || extractMedia || frontMatter) { keys.append(DocKeys.mdFlavor) }
        if target == "html" && !htmlEmbed { keys.append(DocKeys.htmlSingleFile) }
        if target == "epub" && (epubSplit != d.epubSplit || !epubCover.isEmpty) { keys.append(DocKeys.epubSplit) }
        if stripImages { keys.append(DocKeys.images) }
        if stripMetadata { keys.append(DocKeys.metaMode) }
        if title != nil || author != nil || language != nil { keys.append(DocKeys.title) }
        if encodingIn != d.encodingIn || reflow != d.reflow { keys.append(DocKeys.encodingIn) }
        return keys
    }
}
