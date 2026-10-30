import Foundation

// What the app knows about one source file, filled by the engines' probes (ffprobe/AVFoundation, ImageIO, PDFKit, ...).
// Used by: option conditions (`OptionExpr.source`), `fromSource` defaults, the Studio inspector and summary.
//
// facts use DOTTED KEYS. The conventional ones (probes should fill what applies):
//   container, duration (s), size (bytes), bitrate (bit/s)
//   video.count video.codec video.profile video.width video.height video.fps video.pixfmt video.bitdepth
//   video.interlaced video.hdr video.rotation video.vfr
//   audio.count  audio.<N>.codec audio.<N>.channels audio.<N>.rate audio.<N>.lang audio.<N>.bitrate
//   sub.count    sub.<N>.codec sub.<N>.lang
//   chapters.count
//   image.width image.height image.dpi image.alpha image.profile image.frames image.hasGPS
//   pdf.pages pdf.encrypted pdf.hasText pdf.width pdf.height
//   text.encoding text.lines table.columns table.rows archive.entries

struct SourceChip: Hashable, Sendable {
    var symbol: String?
    var text: String
}

enum SourceStreamKind: String, Codable, Sendable { case video, audio, subtitle, chapter, data, image, page }

struct SourceStream: Identifiable, Hashable, Sendable {
    var kind: SourceStreamKind
    var index: Int
    var title: String
    var detail: String
    var language: String?
    var isDefault: Bool = false
    var facts: [String: OptionValue] = [:]
    var id: String { "\(kind.rawValue)-\(index)" }
}

struct SourceInfo: Sendable {
    var url: URL
    var kind: FileKind
    var facts: [String: OptionValue] = [:]
    var chips: [SourceChip] = []
    var streams: [SourceStream] = []
    /// Plain-words oddities: "Variable frame rate", "10-bit HDR", "Interlaced".
    var warnings: [L10n] = []
    var duration: Double? { number("duration") }
    var sizeBytes: Int64? { number("size").map { Int64($0) } }

    init(url: URL, kind: FileKind) { self.url = url; self.kind = kind }

    subscript(key: String) -> OptionValue? { facts[key] }
    func number(_ key: String) -> Double? { facts[key]?.asDouble }
    func int(_ key: String) -> Int? { facts[key]?.asInt }
    func string(_ key: String) -> String? { facts[key]?.asString }
    func bool(_ key: String) -> Bool? { facts[key]?.asBool }
    func streams(of kind: SourceStreamKind) -> [SourceStream] { streams.filter { $0.kind == kind } }
}

/// A probe turns a file into SourceInfo. Engines register one per file kind at startup.
protocol SourceProbe: Sendable {
    /// Should return quickly (< 1 s typical) and never throw: return what is known.
    func probe(_ item: FileItem) async -> SourceInfo
}

/// Registry + cache of probes. Cache key = path + mtime + size.
final class SourceProbeRegistry: @unchecked Sendable {
    static let shared = SourceProbeRegistry()
    private let lock = NSLock()
    private var probes: [FileKind: [SourceProbe]] = [:]
    private var cache: [String: SourceInfo] = [:]

    /// Registers `probe` for the given kinds. The FIRST registered probe that returns facts wins; later ones may enrich.
    func register(kinds: [FileKind], probe: SourceProbe) {
        lock.lock(); for k in kinds { probes[k, default: []].append(probe) }; lock.unlock()
    }

    /// Probes (or returns the cached result for) one item. Unknown kinds return a bare SourceInfo with size only.
    func info(for item: FileItem) async -> SourceInfo {
        let key = cacheKey(item)
        let (hit, list) = lookup(key, kind: item.kind)
        if let hit { return hit }
        var info = SourceInfo(url: item.url, kind: item.kind)
        if let s = item.size { info.facts["size"] = .double(Double(s)) }
        for p in list {
            let r = await p.probe(item)
            info.facts.merge(r.facts) { cur, _ in cur }
            info.chips += r.chips
            info.streams += r.streams
            info.warnings += r.warnings
        }
        store(info, for: key)
        return info
    }

    private func lookup(_ key: String, kind: FileKind) -> (SourceInfo?, [SourceProbe]) {
        lock.lock(); defer { lock.unlock() }
        return (cache[key], probes[kind] ?? [])
    }

    private func store(_ info: SourceInfo, for key: String) {
        lock.lock(); cache[key] = info; lock.unlock()
    }

    func invalidate(_ item: FileItem? = nil) {
        lock.lock(); if let item { cache[cacheKey(item)] = nil } else { cache.removeAll() }; lock.unlock()
    }

    private func cacheKey(_ item: FileItem) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path)
        let m = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(item.url.path)|\(m)|\(s)"
    }
}
