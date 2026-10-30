import Foundation
import Combine

// Presets: named sets of option values for one Studio target (schema id). Built-in presets are registered by the
// engines (see spec/handbrake.md section 4 for the exact values); user presets live as one JSON file each in
// ~/Library/Application Support/Swamp Converter/Presets/<id>.json. Import/export uses `.swampreset` files.
//
// A preset with `onWheel` set is a "slice of your own": it appears on that wheel as operation `preset.<id>`
// (see PresetOperation) and can be targeted by watched folders.

enum PresetGroup: String, Codable, CaseIterable, Sendable {
    case web, devices, social, archive, smallSize, lossless, custom
    var title: L10n {
        switch self {
        case .web: return L10n("Web", "Веб")
        case .devices: return L10n("Devices", "Устройства")
        case .social: return L10n("Social", "Соцсети")
        case .archive: return L10n("Archive", "Архив")
        case .smallSize: return L10n("Small size", "Малый размер")
        case .lossless: return L10n("Lossless", "Без потерь")
        case .custom: return L10n("Custom", "Мои")
        }
    }
    var symbol: String {
        switch self {
        case .web: return "globe"
        case .devices: return "iphone"
        case .social: return "person.2"
        case .archive: return "archivebox"
        case .smallSize: return "arrow.down.right.and.arrow.up.left"
        case .lossless: return "checkmark.seal"
        case .custom: return "person.crop.circle"
        }
    }
}

struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// Schema id of the Studio target ("video.convert").
    var targetID: String
    var name: L10n
    var notes: L10n? = nil
    var symbol: String = "slider.horizontal.3"
    var group: PresetGroup = .custom
    /// Sparse values over the schema defaults. Concrete track choices are never part of a preset.
    var values: OptionValues = OptionValues()
    /// Keys the user locked (a locked field is not changed when the preset is applied over other settings).
    var locks: [String] = []
    /// Operation used to run it; nil = the target's primary operation.
    var operationID: String? = nil
    /// Wheel placement of the user's own slice (nil = Studio only).
    var onWheel: WheelKind? = nil
    var schemaVersion: Int = 1
    /// True for presets registered by engines (their ids start with "builtin.").
    var isBuiltin: Bool { id.hasPrefix("builtin.") }

    enum CodingKeys: String, CodingKey { case id, targetID, name, notes, symbol, group, values, locks, operationID, onWheel, schemaVersion }

    init(id: String, targetID: String, name: L10n, notes: L10n? = nil, symbol: String = "slider.horizontal.3", group: PresetGroup = .custom,
         values: OptionValues = OptionValues(), locks: [String] = [], operationID: String? = nil, onWheel: WheelKind? = nil) {
        self.id = id; self.targetID = targetID; self.name = name; self.notes = notes; self.symbol = symbol; self.group = group
        self.values = values; self.locks = locks; self.operationID = operationID; self.onWheel = onWheel
    }

    /// Built-in presets are created by engines with this helper: ids are prefixed "builtin." automatically.
    static func builtin(_ shortID: String, target: String, _ name: L10n, notes: L10n? = nil, symbol: String = "slider.horizontal.3",
                        group: PresetGroup = .web, operation: String? = nil, _ values: OptionValues) -> Preset {
        return Preset(id: "builtin." + shortID, targetID: target, name: name, notes: notes, symbol: symbol, group: group, values: values, operationID: operation)
    }
}

/// `.swampreset` file: a versioned list.
private struct PresetFile: Codable {
    var format = "swampreset"
    var version = 1
    var presets: [Preset]
}

enum PresetError: LocalizedError {
    case notAPresetFile
    case builtinReadOnly
    case notFound
    var errorDescription: String? {
        switch self {
        case .notAPresetFile: return L("This is not a preset file.", "Это не файл шаблона.")
        case .builtinReadOnly: return L("Built-in presets can’t be changed. Duplicate it first.", "Встроенные шаблоны нельзя изменить. Сначала создайте копию.")
        case .notFound: return L("The preset doesn’t exist.", "Шаблон не найден.")
        }
    }
}

final class PresetStore: ObservableObject, @unchecked Sendable {
    static let shared = PresetStore()

    @Published private(set) var revision = 0
    private let lock = NSLock()
    private var _builtins: [Preset] = []
    private var _user: [Preset] = []
    private var _chains: [RecipeChain] = []
    private var _defaults: [String: String] = [:]
    private let directory: URL

    /// `directory` nil = Application Support/Presets (resolved now).
    init(directory: URL? = nil) {
        self.directory = directory ?? AppPaths.presetsDir
        reload()
    }

    // MARK: Built-ins

    /// Engines call this from `registerOperations()`. Re-registering the same ids replaces them.
    func registerBuiltins(_ presets: [Preset]) {
        lock.lock()
        for var p in presets {
            if !p.id.hasPrefix("builtin.") { p.id = "builtin." + p.id }
            _builtins.removeAll { $0.id == p.id }
            _builtins.append(Preset.builtin(String(p.id.dropFirst(8)), target: p.targetID, p.name, notes: p.notes, symbol: p.symbol, group: p.group, operation: p.operationID, p.values))
        }
        lock.unlock()
        publish()
    }

    var builtins: [Preset] { lock.lock(); defer { lock.unlock() }; return _builtins }
    var userPresets: [Preset] { lock.lock(); defer { lock.unlock() }; return _user }
    var all: [Preset] { builtins + userPresets }

    func presets(for targetID: String) -> [Preset] {
        all.filter { $0.targetID == targetID }
    }

    func preset(id: String) -> Preset? { all.first { $0.id == id } }

    /// User presets that appear on a wheel.
    func wheelPresets() -> [Preset] { userPresets.filter { $0.onWheel != nil } }

    // MARK: User presets

    /// Creates or updates a user preset (writes its file). Built-ins can't be saved over.
    @discardableResult
    func save(_ preset: Preset) throws -> Preset {
        if preset.isBuiltin { throw PresetError.builtinReadOnly }
        var p = preset
        if p.id.isEmpty { p.id = Self.newUserID() }
        try write(p)
        lock.lock()
        if let i = _user.firstIndex(where: { $0.id == p.id }) { _user[i] = p } else { _user.append(p) }
        lock.unlock()
        publish()
        return p
    }

    /// New user preset from the current Studio values.
    @discardableResult
    func create(name: String, targetID: String, values: OptionValues, symbol: String = "slider.horizontal.3", group: PresetGroup = .custom,
                operationID: String? = nil, onWheel: WheelKind? = nil, locks: [String] = []) throws -> Preset {
        try save(Preset(id: Self.newUserID(), targetID: targetID, name: L10n(name), symbol: symbol, group: group, values: values, locks: locks,
                        operationID: operationID, onWheel: onWheel))
    }

    func rename(id: String, to name: String) throws {
        guard var p = preset(id: id) else { throw PresetError.notFound }
        if p.isBuiltin { throw PresetError.builtinReadOnly }
        p.name = L10n(name)
        try save(p)
    }

    /// Copy of any preset (built-in or user) as a new user preset named "<name> copy".
    @discardableResult
    func duplicate(id: String) throws -> Preset {
        guard var p = preset(id: id) else { throw PresetError.notFound }
        p.id = Self.newUserID()
        p.name = L10n(p.name.en + " copy", p.name.ru + " (копия)")
        p.group = .custom
        return try save(Preset(id: p.id, targetID: p.targetID, name: p.name, notes: p.notes, symbol: p.symbol, group: .custom,
                               values: p.values, locks: p.locks, operationID: p.operationID, onWheel: p.onWheel))
    }

    func delete(id: String) throws {
        guard let p = preset(id: id) else { throw PresetError.notFound }
        if p.isBuiltin { throw PresetError.builtinReadOnly }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        lock.lock(); _user.removeAll { $0.id == id }; lock.unlock()
        publish()
    }

    // MARK: Import / export

    func export(ids: [String], to url: URL) throws {
        let list = ids.compactMap { preset(id: $0) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(PresetFile(presets: list)).write(to: url, options: .atomic)
    }

    /// Imports a `.swampreset` (or a single bare preset JSON). Unknown option keys are dropped when the target's schema is known;
    /// ids that collide are regenerated. Returns the imported presets.
    @discardableResult
    func importFile(_ url: URL) throws -> [Preset] {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        var list: [Preset]
        if let f = try? dec.decode(PresetFile.self, from: data), f.format == "swampreset" { list = f.presets }
        else if let p = try? dec.decode(Preset.self, from: data) { list = [p] }
        else { throw PresetError.notAPresetFile }
        var imported: [Preset] = []
        for var p in list {
            if p.id.hasPrefix("builtin.") || preset(id: p.id) != nil { p.id = Self.newUserID() }
            if let schema = OperationRegistry.shared.schema(forTarget: p.targetID) {
                let known = Set(schema.allFields.map(\.key))
                p.values = OptionValues(p.values.storage.filter { known.contains($0.key) })
            }
            p.group = p.group == .custom ? .custom : p.group
            imported.append(try save(Preset(id: p.id, targetID: p.targetID, name: p.name, notes: p.notes, symbol: p.symbol, group: p.group,
                                            values: p.values, locks: p.locks, operationID: p.operationID, onWheel: p.onWheel)))
        }
        return imported
    }

    // MARK: Per-target default preset (Make Default)

    func defaultPresetID(for targetID: String) -> String? { lock.lock(); defer { lock.unlock() }; return _defaults[targetID] }
    func setDefaultPreset(_ id: String?, for targetID: String) {
        lock.lock(); _defaults[targetID] = id; let d = _defaults; lock.unlock()
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: directory.appendingPathComponent("defaults.json"), options: .atomic) }
        publish()
    }

    // MARK: Chains

    var chains: [RecipeChain] { lock.lock(); defer { lock.unlock() }; return _chains }

    func saveChain(_ chain: RecipeChain) {
        lock.lock()
        if let i = _chains.firstIndex(where: { $0.id == chain.id }) { _chains[i] = chain } else { _chains.append(chain) }
        let c = _chains
        lock.unlock()
        writeChains(c)
        publish()
    }

    func deleteChain(id: String) {
        lock.lock(); _chains.removeAll { $0.id == id }; let c = _chains; lock.unlock()
        writeChains(c)
        publish()
    }

    private func writeChains(_ c: [RecipeChain]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(c) { try? data.write(to: directory.appendingPathComponent("chains.json"), options: .atomic) }
    }

    // MARK: Persistence

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var user: [Preset] = []
        for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") && !name.hasPrefix("._") {
            if name == "chains.json" || name == "defaults.json" { continue }
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)), let p = try? JSONDecoder().decode(Preset.self, from: data) { user.append(p) }
        }
        var chains: [RecipeChain] = []
        if let d = try? Data(contentsOf: directory.appendingPathComponent("chains.json")), let c = try? JSONDecoder().decode([RecipeChain].self, from: d) { chains = c }
        var defaults: [String: String] = [:]
        if let d = try? Data(contentsOf: directory.appendingPathComponent("defaults.json")), let c = try? JSONDecoder().decode([String: String].self, from: d) { defaults = c }
        lock.lock(); _user = user; _chains = chains; _defaults = defaults; lock.unlock()
        publish()
    }

    private func fileURL(for id: String) -> URL { directory.appendingPathComponent(Util.safeFileName(id) + ".json") }

    private func write(_ p: Preset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: fileURL(for: p.id), options: .atomic)
    }

    static func newUserID() -> String { "u-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased() }

    private func publish() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }
}

/// A user preset on a wheel: runs the preset's target operation with the preset's values. Placement follows the preset
/// (`onWheel`). Applies to the same files as the target and, like all presets, also when the format already matches.
final class PresetOperation: OperationBase, @unchecked Sendable {
    let preset: Preset
    private let base: Operation

    init?(preset: Preset, registry: OperationRegistry = .shared) {
        guard let wheel = preset.onWheel,
              let base = (preset.operationID.flatMap { registry.operation(id: $0) }) ?? registry.primaryOperation(forTarget: preset.targetID) else { return nil }
        self.preset = preset
        self.base = base
        var m = base.meta
        m.id = "preset.\(preset.id)"
        m.wheel = wheel
        m.label = preset.name
        m.subtitle = nil
        m.symbol = preset.symbol
        m.targetFormat = nil   // presets show on every applicable file
        m.suffix = L10n(Util.safeSuffix(preset.name.en), Util.safeSuffix(preset.name.ru))
        super.init(meta: m)
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { base.quickOverrides(settings: settings).overlaying(preset.values) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { base.optionSchema(for: items) }
    override func appliesTo(_ items: [FileItem]) -> Bool { base.appliesInStudio(items) }
    override func appliesInStudio(_ items: [FileItem]) -> Bool { base.appliesInStudio(items) }
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability { base.availability(for: items, tools: tools) }
    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] { base.validate(options: options, source: source) }
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? { base.estimate(options: options, items: items, source: source) }
    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        try await base.preview(items: items, options: options, source: source, time: time, maxPixel: maxPixel)
    }
    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] { base.summaryChips(options: options, source: source) }
    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        try await base.execute(items: items, ctx: ctx)
    }
}

enum PresetOperations {
    /// Registers the provider that exposes `PresetStore.wheelPresets()` as wheel operations. Called by EnginesBootstrap.
    static func install() {
        OperationRegistry.shared.registerProvider(id: "user-presets") { _ in
            PresetStore.shared.wheelPresets().compactMap { PresetOperation(preset: $0) }
        }
    }
}
