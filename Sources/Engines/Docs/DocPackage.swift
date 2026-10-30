import Foundation

// Office / ebook packages are zip files. This is the thin layer between the document readers / writers and the shared ZipKit of the data module:
// write a list of parts in order (EPUB and ODF need `mimetype` first and stored), and read parts of a package by name.

enum DocPackage {
    struct Part {
        var name: String
        var data: Data
        /// Stored without compression (mimetype, pictures that are compressed already).
        var stored = false
    }

    /// Writes the parts in the given order. On any error the half-written file is removed.
    static func write(_ parts: [Part], to url: URL, level: Int = 6) throws {
        do {
            let zip = try ZipWriter(url: url, level: level)
            for p in parts {
                try Task.checkCancellation()
                try zip.add(data: p.data, as: p.name, method: p.stored ? .stored : .deflate, modified: nil)
            }
            try zip.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Read access to the parts of one package. The central directory is read once.
    final class Reader {
        let url: URL
        private let entries: [ZipEntry]
        private let byName: [String: ZipEntry]

        init(url: URL) throws {
            self.url = url
            entries = try ZipKit.list(url)
            var map: [String: ZipEntry] = [:]
            for e in entries { map[e.name.replacingOccurrences(of: "\\", with: "/")] = e }
            byName = map
        }

        var names: [String] { entries.filter { !$0.isDirectory }.map(\.name) }
        func has(_ name: String) -> Bool { byName[name] != nil }

        /// The bytes of a part, or nil when it does not exist. Throws for damaged data.
        func data(_ name: String, limit: Int = 256_000_000) throws -> Data? {
            guard has(name) else { return nil }
            return try ZipKit.read(url, entry: name, limit: limit)
        }

        func xml(_ name: String) throws -> DocXMLNode? {
            guard let d = try data(name, limit: 128_000_000) else { return nil }
            return try DocXML.parse(d)
        }

        /// Resolves a relationship target (`media/image1.png`, `../media/a.png`, `/word/media/a.png`) against the folder of the part that owns it.
        func resolve(_ target: String, relativeTo part: String) -> String {
            if target.hasPrefix("/") { return String(target.dropFirst()) }
            var comps = part.split(separator: "/").dropLast().map(String.init)
            for c in target.split(separator: "/") {
                if c == ".." { if !comps.isEmpty { comps.removeLast() } } else if c != "." { comps.append(String(c)) }
            }
            return comps.joined(separator: "/")
        }
    }
}

/// Relationships of a part (`word/_rels/document.xml.rels`): id -> (target, external?).
struct DocRelationships {
    struct Rel { var target: String; var type: String; var external: Bool }
    var byID: [String: Rel] = [:]

    init(_ root: DocXMLNode?) {
        for r in root?.children("Relationship") ?? [] {
            guard let id = r["Id"], let t = r["Target"] else { continue }
            byID[id] = Rel(target: t, type: r["Type"] ?? "", external: (r["TargetMode"] ?? "").lowercased() == "external")
        }
    }

    subscript(id: String) -> Rel? { byID[id] }
}
