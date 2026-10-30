import Foundation

// Small XML helpers shared by the OOXML / ODF / EPUB readers and writers: a DOM built with XMLParser (names exactly as written, "w:p", "text:span")
// and the escaping used by every writer. Package parts are small compared with the pictures, so a DOM is fine; the node count is capped.

enum DocXMLChild {
    case element(DocXMLNode)
    case text(String)
}

final class DocXMLNode {
    let name: String
    var attributes: [String: String]
    var content: [DocXMLChild] = []

    init(name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }

    subscript(attr: String) -> String? { attributes[attr] }
    var elements: [DocXMLNode] { content.compactMap { if case .element(let e) = $0 { return e } else { return nil } } }
    func children(_ name: String) -> [DocXMLNode] { elements.filter { $0.name == name } }
    func child(_ name: String) -> DocXMLNode? { elements.first { $0.name == name } }

    /// All descendants (depth-first, document order) with `name`.
    func descendants(_ name: String) -> [DocXMLNode] {
        var out: [DocXMLNode] = []
        for e in elements { if e.name == name { out.append(e) }; out += e.descendants(name) }
        return out
    }

    /// Concatenated text of the whole subtree.
    var textContent: String {
        var s = ""
        for c in content {
            switch c { case .text(let t): s += t; case .element(let e): s += e.textContent }
        }
        return s
    }
}

enum DocXML {
    /// Parses a document. Throws `ConversionError.message` for malformed XML. DOCTYPE / external entities are never loaded.
    static func parse(_ data: Data, maxNodes: Int = 6_000_000) throws -> DocXMLNode {
        let builder = TreeBuilder(maxNodes: maxNodes)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        if !parser.parse() || builder.tooBig {
            let why = builder.tooBig ? L("the document is too large", "документ слишком большой") : (parser.parserError?.localizedDescription ?? "?")
            throw ConversionError.message(L10n("The file contains damaged XML (\(why)).", "Файл содержит повреждённый XML (\(why))."))
        }
        guard let root = builder.root else { throw ConversionError.message(L10n("The file contains no XML content.", "В файле нет XML-содержимого.")) }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: DocXMLNode?
        var stack: [DocXMLNode] = []
        var count = 0
        let maxNodes: Int
        var tooBig = false
        init(maxNodes: Int) { self.maxNodes = maxNodes }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            count += 1
            if count > maxNodes { tooBig = true; parser.abortParsing(); return }
            let node = DocXMLNode(name: elementName, attributes: attributeDict)
            if let top = stack.last { top.content.append(.element(node)) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = stack.last else { return }
            if case .text(let prev)? = top.content.last { top.content[top.content.count - 1] = .text(prev + string) } else { top.content.append(.text(string)) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: s) }
        }
    }

    // MARK: Writing

    /// Escapes text for element content (`attribute: false`) or double-quoted attribute values. Characters that are illegal in XML 1.0 are dropped.
    static func escape(_ s: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += attribute ? "&quot;" : "\""
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF || (u.value >= 0xD800 && u.value <= 0xDFFF) { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static func attr(_ s: String) -> String { escape(s, attribute: true) }

    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// ISO 8601 in UTC with a trailing Z ("2026-10-24T17:20:00Z"), the form OOXML core properties and ODF meta expect.
    static func isoDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func parseISODate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
