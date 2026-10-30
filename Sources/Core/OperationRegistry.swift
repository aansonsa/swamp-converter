import Foundation

// The catalogue of everything the wheel and Studio can run. Engines register their operations at startup
// (EnginesBootstrap.registerAll -> <Module>.registerOperations). Registration order = catalogue order
// (images, audio, video, pdf, documents, slides, spreadsheets, subtitles, archives, OCR, then actions, then user presets).

struct OperationEntry: Identifiable {
    let operation: Operation
    let availability: OperationAvailability
    var id: String { operation.meta.id }
}

/// One entry of Studio's target picker: all operations sharing a schema id collapse into one target.
struct StudioTarget: Identifiable {
    let id: String                 // schema id, e.g. "video.convert"
    let family: OperationFamily
    let title: L10n
    let symbol: String
    /// Every operation of this target (wheel slices); `primary` executes recipes that name the target only.
    let operations: [Operation]
    var primary: Operation { operations[0] }
    let availability: OperationAvailability
}

final class OperationRegistry: @unchecked Sendable {
    static let shared = OperationRegistry()

    private let lock = NSLock()
    private var ops: [Operation] = []
    private var byID: [String: Operation] = [:]
    private var providers: [(id: String, make: @Sendable (SettingsData) -> [Operation])] = []

    // MARK: Registration

    func register(_ op: Operation) {
        lock.lock(); defer { lock.unlock() }
        // Re-registration replaces the operation IN PLACE: the catalogue order of the wheels never changes because an id was registered twice.
        if byID[op.meta.id] != nil, let i = ops.firstIndex(where: { $0.meta.id == op.meta.id }) { ops[i] = op } else { ops.append(op) }
        byID[op.meta.id] = op
    }

    func register(_ list: [Operation]) { list.forEach(register) }

    /// Dynamic operations (user presets, chains). `make` is called on every query so edits show up immediately.
    func registerProvider(id: String, _ make: @escaping @Sendable (SettingsData) -> [Operation]) {
        lock.lock(); defer { lock.unlock() }
        providers.removeAll { $0.id == id }
        providers.append((id, make))
    }

    /// Tests only.
    func removeAll() {
        lock.lock(); ops = []; byID = [:]; providers = []; lock.unlock()
    }

    func unregister(id: String) {
        lock.lock(); ops.removeAll { $0.meta.id == id }; byID[id] = nil; lock.unlock()
    }

    // MARK: Queries

    /// Number of statically registered operations (provider operations are not counted: asking them costs work).
    var staticCount: Int { lock.lock(); defer { lock.unlock() }; return ops.count }

    /// Static operations followed by dynamic ones.
    func allOperations(settings: SettingsData = AppSettings.shared.data) -> [Operation] {
        lock.lock(); let base = ops; let provs = providers; lock.unlock()
        return base + provs.flatMap { $0.make(settings) }
    }

    func operation(id: String) -> Operation? {
        lock.lock(); let hit = byID[id]; lock.unlock()
        if let hit { return hit }
        return allOperations().first { $0.meta.id == id }
    }

    /// Operations of `wheel` that apply to `items`, each with its availability (unavailable ones stay in the list so
    /// the wheel can show them dimmed with the install hint). Catalogue order; apply `WheelLayout` afterwards.
    func entries(wheel: WheelKind, items: [FileItem], tools: ToolLocator = .shared,
                 settings: SettingsData = AppSettings.shared.data) -> [OperationEntry] {
        guard !items.isEmpty else { return [] }
        return allOperations(settings: settings)
            .filter { $0.meta.wheel == wheel && !$0.meta.studioOnly && $0.appliesTo(items) }
            .map { OperationEntry(operation: $0, availability: $0.availability(for: items, tools: tools)) }
    }

    /// The LINK wheel: operations that accept `links` (download modes), each with its availability (yt-dlp missing etc.).
    func linkEntries(links: [LinkItem], tools: ToolLocator = .shared, settings: SettingsData = AppSettings.shared.data) -> [OperationEntry] {
        guard !links.isEmpty else { return [] }
        return allOperations(settings: settings)
            .filter { $0.meta.acceptsLinks && $0.meta.wheel == .link && !$0.meta.studioOnly && $0.appliesToLinks(links) }
            .map { OperationEntry(operation: $0, availability: $0.availability(for: [], tools: tools)) }
    }

    /// Studio targets (schema ids) that accept `links`: the "Download" target and its siblings.
    func studioTargets(forLinks links: [LinkItem], tools: ToolLocator = .shared, settings: SettingsData = AppSettings.shared.data) -> [StudioTarget] {
        guard !links.isEmpty else { return [] }
        var order: [String] = []
        var groups: [String: [Operation]] = [:]
        for op in allOperations(settings: settings) where op.meta.acceptsLinks && op.appliesToLinks(links) {
            if groups[op.meta.schemaID] == nil { order.append(op.meta.schemaID) }
            groups[op.meta.schemaID, default: []].append(op)
        }
        return order.compactMap { sid in
            guard let list = groups[sid], let first = list.first else { return nil }
            let schema = first.optionSchema(for: [])
            return StudioTarget(id: sid, family: first.meta.family, title: schema.title, symbol: schema.symbol, operations: list,
                                availability: first.availability(for: [], tools: tools))
        }
    }

    /// Studio targets that apply to ALL `items` (same-format hiding does not apply). Convert/Tools operations only.
    func studioTargets(for items: [FileItem], tools: ToolLocator = .shared,
                       settings: SettingsData = AppSettings.shared.data) -> [StudioTarget] {
        guard !items.isEmpty else { return [] }
        var order: [String] = []
        var groups: [String: [Operation]] = [:]
        for op in allOperations(settings: settings) where !op.meta.isAppAction && op.meta.id.hasPrefix("preset.") == false && op.appliesInStudio(items) {
            if groups[op.meta.schemaID] == nil { order.append(op.meta.schemaID) }
            groups[op.meta.schemaID, default: []].append(op)
        }
        return order.compactMap { sid in
            guard let list = groups[sid], let first = list.first else { return nil }
            let schema = first.optionSchema(for: items)
            let avail = list.map { $0.availability(for: items, tools: tools) }.first(where: { $0.isAvailable }) ?? list[0].availability(for: items, tools: tools)
            return StudioTarget(id: sid, family: first.meta.family, title: schema.title, symbol: schema.symbol, operations: list, availability: avail)
        }
    }

    /// The operation that should execute a recipe for `targetID` when the recipe names no concrete operation.
    func primaryOperation(forTarget targetID: String) -> Operation? {
        allOperations().first { $0.meta.schemaID == targetID }
    }

    /// Schema of a target without items (preset validation, quick-recipe editor).
    func schema(forTarget targetID: String) -> OptionSchema? {
        primaryOperation(forTarget: targetID)?.optionSchema(for: [])
    }
}
