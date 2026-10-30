import Foundation

// The logic of the quick-run parameter sheet (no drawing): which values the sheet shows first, what it refuses to run with, what it hands back, and what it remembers.
// `QuickRun` asks for the fields named in `OperationMeta.quickPromptKeys` (trim start / end, fit-to-size target, a password ...); this file turns that into answers.

/// The values a sheet remembers between runs, per operation, in `param-sheet.json` next to the settings. Passwords and any field that is not persisted are never written.
final class ParameterMemory: @unchecked Sendable {
    static let shared = ParameterMemory(fileURL: nil)

    private let lock = NSLock()
    private let fixedURL: URL?

    /// `fileURL` nil = the standard file, resolved at each use (so an isolated test home is honoured).
    init(fileURL: URL?) { fixedURL = fileURL }

    private var url: URL { fixedURL ?? AppPaths.supportDir.appendingPathComponent("param-sheet.json") }

    private func load() -> [String: OptionValues] {
        guard let data = try? Data(contentsOf: url), let map = try? JSONDecoder().decode([String: OptionValues].self, from: data) else { return [:] }
        return map
    }

    func values(for operationID: String) -> OptionValues {
        lock.lock(); defer { lock.unlock() }
        return load()[operationID] ?? OptionValues()
    }

    func remember(_ values: OptionValues, for operationID: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        if values.isEmpty { map[operationID] = nil } else { map[operationID] = values }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(map) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The sheet's state: the asked fields, their values, and the checks that decide whether "Run" is allowed.
struct ParamSheetModel {
    let operation: Operation
    let items: [FileItem]
    /// The asked fields, in the order the operation named them.
    let fields: [OptionField]
    /// The complete quick-recipe values (what the run would use if nothing were asked).
    let base: OptionValues
    /// The values of the asked fields as the person has them now.
    private(set) var values: OptionValues

    /// `current` = the complete quick-recipe values; `remembered` = what the sheet saved last time (applied only to fields that can be remembered).
    init(operation: Operation, items: [FileItem], fields: [OptionField], current: OptionValues, remembered: OptionValues = OptionValues()) {
        self.operation = operation; self.items = items; self.fields = fields; self.base = current
        var start = OptionValues()
        for f in fields {
            if Self.isMemorable(f), let r = remembered[f.key] { start[f.key] = r } else if let c = current[f.key] { start[f.key] = c } else { start[f.key] = f.defaultOptionValue }
        }
        self.values = start
        // Remembered values go through the same coercion and clamping as any other (a stale value out of range is pulled back in).
        self.values = resolvedAnswers(for: start)
    }

    // MARK: Fields

    /// A field the sheet may write to disk: not a secret, and persistable.
    static func isMemorable(_ f: OptionField) -> Bool {
        if !f.persist { return false }
        if case .text(let spec) = f.kind, spec.secure { return false }
        return true
    }

    private static func isSecret(_ f: OptionField) -> Bool {
        if case .text(let spec) = f.kind, spec.secure { return true }
        return !f.persist
    }

    var schema: OptionSchema { operation.optionSchema(for: items) }

    mutating func set(_ key: String, _ value: OptionValue) { values[key] = value }

    /// The complete option set the checks run on.
    var merged: OptionValues { values.merged(over: base) }

    // MARK: Checks

    /// What stops or colours the run. Errors about fields the sheet doesn't show are not counted unless the answers caused them (a problem that was already there before the
    /// person typed anything can't be fixed here, and must not lock the Run button forever).
    func messages() -> [OptionMessage] {
        let keys = Set(fields.map(\.key))
        let schema = self.schema
        let before = Set((schema.validate(base) + operation.validate(options: base, source: nil)).map(\.id))
        var all = schema.validate(merged) + operation.validate(options: merged, source: nil)
        all = all.filter { m in
            if let k = m.fieldKey, keys.contains(k) { return true }
            return !before.contains(m.id)
        }
        for f in fields where Self.isSecret(f) && values.string(f.key).isEmpty {
            all.append(OptionMessage(id: "\(f.key).required", severity: .error, text: L10n("Enter the \(f.label.en.lowercased()) to continue.", "Введите: \(f.label.ru.lowercased())."), fieldKey: f.key))
        }
        for f in fields {
            if case .time(let spec) = f.kind, !spec.allowEmpty, (values[f.key]?.asString ?? "").isEmpty {
                all.append(OptionMessage(id: "\(f.key).required", severity: .error, text: L10n("Enter a time.", "Введите время."), fieldKey: f.key))
            }
        }
        // Trim-style pairs: a start that is not before the end can't cut anything.
        if let start = fields.first(where: { Self.isBoundary($0.key, "start") }), let end = fields.first(where: { Self.isBoundary($0.key, "end") }),
           let s = values[start.key]?.asDouble, let e = values[end.key]?.asDouble, e > 0, s >= e, !all.contains(where: { $0.id == "trim.order" }) {
            all.append(OptionMessage(id: "trim.order", severity: .error, text: L10n("The start must be before the end.", "Начало должно быть раньше конца."), fieldKey: end.key))
        }
        return all.sorted { $0.severity > $1.severity }
    }

    private static func isBoundary(_ key: String, _ word: String) -> Bool {
        let last = key.split(separator: ".").last.map { String($0).lowercased() } ?? key.lowercased()
        return last == word || last.hasSuffix(word) || last.hasPrefix(word)
    }

    var canRun: Bool { !messages().contains { $0.severity == .error } }

    // MARK: Answers

    private func resolvedAnswers(for asked: OptionValues) -> OptionValues {
        let resolved = schema.resolve(layers: [base, asked]).values
        var out = OptionValues()
        for f in fields { out[f.key] = resolved[f.key] ?? asked[f.key] ?? f.defaultOptionValue }
        return out
    }

    /// What goes back to `QuickRun`: the asked fields only, coerced and clamped like every other value.
    func answers() -> OptionValues { resolvedAnswers(for: values) }

    /// What is written to `param-sheet.json`: the asked fields that may be remembered.
    func memorable() -> OptionValues {
        var out = OptionValues()
        let a = answers()
        for f in fields where Self.isMemorable(f) { out[f.key] = a[f.key] }
        return out
    }
}
