import Foundation

// F. MULTI-OUTPUT PRESETS: one input -> several outputs in one go, each shown as a SINGLE wheel sector.
// Built-ins: "Social sizes" (1080x1350, 1080x1920, 1200x630, 1080x1080), "Web images" (WebP + JPG at 3 widths), "Icon pack" (ICO, ICNS, PNG 16...1024).
// User-definable: Settings > Recipes lists them next to presets. Each output is a Recipe of an existing operation, so there is NO new engine: the fan-out runs the recipes
// through the nested-run helper on the same input, collects all outputs into one result and one job card, and names files `{name} - {label}.{ext}`.

struct MultiOutputItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: L10n
    var recipe: Recipe
    /// Name part used in the file name ("1080x1350", "web-800", "ios-512").
    var nameSuffix: String
}

struct MultiOutputPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: L10n
    var symbol: String = "rectangle.stack"
    /// The kind of input it accepts ("image" for all three built-ins).
    var inputProfile: WheelProfile = .image
    var items: [MultiOutputItem]
    var wheel: WheelKind = .tools
    var isBuiltin: Bool { id.hasPrefix("builtin.") }
}

/// What a pack file looks like on disk: a version and the packs (also used by import / export, so a single exported pack and a whole list both read back).
struct MultiOutputFile: Codable, Sendable {
    var version = 1
    var packs: [MultiOutputPreset]
}

enum MultiOutputError: LocalizedError {
    case builtinReadOnly, notFound, notAPackFile, noOutputs
    var errorDescription: String? {
        switch self {
        case .builtinReadOnly: return L("Built-in packs can’t be changed. Duplicate it first.", "Встроенные наборы нельзя изменить. Сначала создайте копию.")
        case .notFound: return L("The pack doesn’t exist.", "Набор не найден.")
        case .notAPackFile: return L("This is not a pack file.", "Это не файл набора.")
        case .noOutputs: return L("A pack needs at least one output.", "В наборе должен быть хотя бы один результат.")
        }
    }
}

/// Store: built-ins + user JSON files in Application Support/MultiOutput/*.json (atomic writes, tolerant reading, import / export like presets).
/// The folder is read on first use (nothing at launch) and again on `reload()`.
final class MultiOutputStore: ObservableObject, @unchecked Sendable {
    static let shared = MultiOutputStore()
    @Published private(set) var revision = 0

    private let lock = NSLock()
    private let directoryOverride: URL?
    private var _user: [MultiOutputPreset] = []
    private var loaded = false

    /// `directory` nil = Application Support/MultiOutput (resolved when first needed, so the self-test home redirect is honoured).
    init(directory: URL? = nil) { directoryOverride = directory }

    var directory: URL {
        let url = directoryOverride ?? AppPaths.supportDir.appendingPathComponent("MultiOutput", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var builtins: [MultiOutputPreset] { MultiOutputBuiltins.all }
    var user: [MultiOutputPreset] { ensureLoaded(); lock.lock(); defer { lock.unlock() }; return _user }
    var all: [MultiOutputPreset] { builtins + user }

    func preset(id: String) -> MultiOutputPreset? { all.first { $0.id == id } }

    // MARK: Editing

    /// Adds or replaces a user pack (built-ins are read-only). The file name is derived from the id; the write is atomic.
    func save(_ preset: MultiOutputPreset) throws {
        if preset.isBuiltin { throw MultiOutputError.builtinReadOnly }
        guard !preset.items.isEmpty else { throw MultiOutputError.noOutputs }
        ensureLoaded()
        var p = preset
        p.items = Self.withUniqueItemIDs(p.items)
        try write(p)
        lock.lock()
        if let i = _user.firstIndex(where: { $0.id == p.id }) { _user[i] = p } else { _user.append(p) }
        lock.unlock()
        publish()
    }

    func delete(id: String) throws {
        if id.hasPrefix("builtin.") { throw MultiOutputError.builtinReadOnly }
        ensureLoaded()
        lock.lock(); let existed = _user.contains { $0.id == id }; lock.unlock()
        guard existed else { throw MultiOutputError.notFound }
        let file = fileURL(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        lock.lock(); _user.removeAll { $0.id == id }; lock.unlock()
        publish()
    }

    /// A user copy of any pack (built-in or not) under a fresh id.
    @discardableResult
    func duplicate(id: String) throws -> MultiOutputPreset {
        guard var p = preset(id: id) else { throw MultiOutputError.notFound }
        p.id = Self.newUserID()
        p.name = L10n(p.name.en + " copy", p.name.ru + " (копия)")
        try save(p)
        return p
    }

    func rename(id: String, to name: L10n) throws {
        guard var p = preset(id: id) else { throw MultiOutputError.notFound }
        if p.isBuiltin { throw MultiOutputError.builtinReadOnly }
        p.name = name
        try save(p)
    }

    // MARK: Import / export

    func export(ids: [String], to url: URL) throws {
        let packs = ids.compactMap { preset(id: $0) }
        guard !packs.isEmpty else { throw MultiOutputError.notFound }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(MultiOutputFile(packs: packs)).write(to: url, options: .atomic)
    }

    /// Reads a pack file (one pack or a list). Imported packs always become user packs with fresh ids, so importing twice never overwrites anything.
    @discardableResult
    func importFile(_ url: URL) throws -> [MultiOutputPreset] {
        guard let data = try? Data(contentsOf: url) else { throw MultiOutputError.notAPackFile }
        let packs = try Self.decodePacks(data)
        guard !packs.isEmpty else { throw MultiOutputError.notAPackFile }
        var imported: [MultiOutputPreset] = []
        for var p in packs {
            p.id = Self.newUserID()
            guard !p.items.isEmpty else { continue }
            try save(p)
            imported.append(p)
        }
        guard !imported.isEmpty else { throw MultiOutputError.notAPackFile }
        return imported
    }

    /// Reads the folder again (after an import by hand, or in tests).
    func reload() {
        lock.lock(); loaded = false; lock.unlock()
        ensureLoaded()
        publish()
    }

    // MARK: Disk

    private func ensureLoaded() {
        lock.lock()
        if loaded { lock.unlock(); return }
        loaded = true
        lock.unlock()
        var found: [MultiOutputPreset] = []
        let dir = directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            // Tolerant: a file that does not parse, or a pack without outputs, is skipped (never deleted, never an error for the others).
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), let packs = try? Self.decodePacks(data) else { continue }
            for var p in packs where !p.items.isEmpty && !p.id.hasPrefix("builtin.") {
                p.items = Self.withUniqueItemIDs(p.items)
                if !found.contains(where: { $0.id == p.id }) { found.append(p) }
            }
        }
        lock.lock(); _user = found; lock.unlock()
    }

    private func write(_ p: MultiOutputPreset) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(MultiOutputFile(packs: [p])).write(to: fileURL(for: p.id), options: .atomic)
    }

    private func fileURL(for id: String) -> URL { directory.appendingPathComponent(Util.safeFileName(id, fallback: "pack") + ".json") }

    static func decodePacks(_ data: Data) throws -> [MultiOutputPreset] {
        let dec = JSONDecoder()
        if let file = try? dec.decode(MultiOutputFile.self, from: data) { return file.packs }
        if let one = try? dec.decode(MultiOutputPreset.self, from: data) { return [one] }
        if let list = try? dec.decode([MultiOutputPreset].self, from: data) { return list }
        throw MultiOutputError.notAPackFile
    }

    static func newUserID() -> String { "u-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased() }

    private static func withUniqueItemIDs(_ items: [MultiOutputItem]) -> [MultiOutputItem] {
        var seen = Set<String>()
        return items.enumerated().map { i, item in
            var it = item
            if it.id.isEmpty || !seen.insert(it.id).inserted { it.id = "o\(i)-" + UUID().uuidString.prefix(4).lowercased(); seen.insert(it.id) }
            return it
        }
    }

    private func publish() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }
}

extension MultiOutputPreset {
    /// Tolerant decoding for packs written by hand or by an older version: only the id, the name and the outputs are required.
    init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case id, name, symbol, inputProfile, items, wheel }
        let c = try decoder.container(keyedBy: K.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(L10n.self, forKey: .name),
                  symbol: (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "rectangle.stack",
                  inputProfile: (try? c.decodeIfPresent(WheelProfile.self, forKey: .inputProfile)) ?? .image,
                  items: try c.decode([MultiOutputItem].self, forKey: .items),
                  wheel: (try? c.decodeIfPresent(WheelKind.self, forKey: .wheel)) ?? .tools)
    }
}
