import Foundation

// Turning layered option sets into the complete, valid OptionValues an engine reads:
//   defaults(source) <- base layers (op quick overrides, preset, user quick edits) <- job overrides
// then coercion/clamping per field kind, resetting inactive fields, and validation messages.

struct ResolvedOptions: Sendable {
    /// Complete: every schema key has a value. Inactive fields hold their default.
    var values: OptionValues
    /// Keys whose field was disabled / hidden / lacking a capability (value reset to default; engines must ignore them).
    var inactive: Set<String>
    var messages: [OptionMessage]

    func isActive(_ key: String) -> Bool { !inactive.contains(key) }
    var hasErrors: Bool { messages.contains { $0.severity == .error } }
}

/// A search hit for the Studio option search (Cmd-F).
struct OptionSearchHit: Identifiable, Sendable {
    var page: OptionPage
    var group: OptionGroup
    var field: OptionField
    var id: String { field.key }
}

extension OptionSchema {
    /// Defaults of every field, with `fromSource` rules evaluated against `source`.
    func defaults(source: SourceInfo? = nil) -> OptionValues {
        var out = OptionValues()
        for f in allFields {
            out[f.key] = f.defaultValue.resolve(source)
        }
        return out
    }

    /// Layers are applied in order (later wins). Unknown keys are dropped.
    func resolve(layers: [OptionValues], source: SourceInfo? = nil, capabilities: Capabilities = .shared) -> ResolvedOptions {
        let fields = allFields
        let defs = defaults(source: source)
        var values = defs
        let known = Set(fields.map(\.key))
        for layer in layers { for (k, v) in layer.storage where known.contains(k) { values[k] = v } }
        // Coerce kinds.
        for f in fields {
            let raw = values[f.key] ?? defs[f.key] ?? f.defaultValue.resolve(source)
            values[f.key] = Self.coerce(raw, field: f, defaultValue: defs[f.key] ?? raw, capabilities: capabilities, values: values, source: source)
        }
        // Inactive fields: up to three passes because conditions can depend on fields that just became inactive.
        var inactive = Set<String>()
        for _ in 0..<3 {
            let env = ExprEnvironment(values: values, source: source, capabilities: capabilities)
            var next = Set<String>()
            for page in pages {
                let pageOff = (page.visibleWhen.map { !$0.evaluate(env) } ?? false) || !capabilities.hasAll(page.requires)
                for group in page.groups {
                    let groupOff = pageOff || (group.visibleWhen.map { !$0.evaluate(env) } ?? false)
                    for f in group.fields {
                        let off = groupOff
                            || (f.visibleWhen.map { !$0.evaluate(env) } ?? false)
                            || (f.enabledWhen.map { !$0.evaluate(env) } ?? false)
                            || !capabilities.hasAll(f.requires)
                        if off { next.insert(f.key) }
                    }
                }
            }
            if next == inactive { break }
            inactive = next
            for k in inactive { values[k] = defs[k] }
        }
        let messages = validate(values, source: source, capabilities: capabilities, inactive: inactive)
        return ResolvedOptions(values: values, inactive: inactive, messages: messages)
    }

    func resolve(_ layers: OptionValues..., source: SourceInfo? = nil) -> ResolvedOptions {
        resolve(layers: layers, source: source)
    }

    // MARK: Coercion

    private static func coerce(_ raw: OptionValue, field f: OptionField, defaultValue: OptionValue, capabilities: Capabilities,
                               values: OptionValues, source: SourceInfo?) -> OptionValue {
        switch f.kind {
        case .toggle:
            return .bool(raw.asBool ?? defaultValue.asBool ?? false)
        case .picker(let opts), .segmented(let opts):
            let s = raw.asString ?? ""
            let env = ExprEnvironment(values: values, source: source, capabilities: capabilities)
            func usable(_ o: FieldOption) -> Bool { capabilities.hasAll(o.requires) && (o.enabledWhen?.evaluate(env) ?? true) }
            if let o = opts.first(where: { $0.value == s }), usable(o) { return .string(s) }
            let d = defaultValue.asString ?? ""
            if let o = opts.first(where: { $0.value == d }), usable(o) { return .string(d) }
            return .string(opts.first(where: usable)?.value ?? d)
        case .slider(let spec):
            let v = raw.asDouble ?? defaultValue.asDouble ?? spec.min
            let c = Util.clamp(v, spec.min, spec.max)
            if spec.decimals == 0 && spec.step == spec.step.rounded() { return .int(Int(c.rounded())) }
            return .double(c)
        case .stepper(let spec):
            let v = raw.asInt ?? defaultValue.asInt ?? spec.min
            return .int(Util.clamp(v, spec.min, spec.max))
        case .number(let spec):
            guard let v = raw.asDouble ?? defaultValue.asDouble else { return defaultValue }
            var c = v
            if let lo = spec.min { c = max(c, lo) }
            if let hi = spec.max { c = min(c, hi) }
            return spec.decimals == 0 && spec.step == spec.step.rounded() ? .int(Int(c.rounded())) : .double(c)
        case .time(let spec):
            if let s = raw.asString, s.trimmingCharacters(in: .whitespaces).isEmpty { return spec.allowEmpty ? .string("") : defaultValue }
            if case .string(let s) = raw, let t = Util.parseTime(s) { return .double(t) }
            if let d = raw.asDouble { return .double(max(0, d)) }
            return defaultValue
        case .text, .folder, .file, .color:
            return .string(raw.asString ?? defaultValue.asString ?? "")
        case .tracks(let spec):
            guard var rows = raw.asRows else { return defaultValue.asRows != nil ? .rows(defaultValue.asRows!) : .list([]) }
            if let m = spec.maxRows, rows.count > m { rows = Array(rows.prefix(m)) }
            var normalised: [[String: OptionValue]] = []
            for r in rows {
                var row = r
                for c in spec.columns where row[c.key] == nil { row[c.key] = c.defaultValue.resolve(source) }
                normalised.append(row)
            }
            return .rows(normalised)
        }
    }

    // MARK: Validation

    /// Evaluates every field rule (for active fields) and schema rule. Sorted: errors first.
    func validate(_ values: OptionValues, source: SourceInfo? = nil, capabilities: Capabilities = .shared, inactive: Set<String> = []) -> [OptionMessage] {
        let env = ExprEnvironment(values: values, source: source, capabilities: capabilities)
        var out: [OptionMessage] = []
        func add(_ r: ValidationRule, key: String?) {
            if r.when.evaluate(env) {
                out.append(OptionMessage(id: r.id, severity: r.severity, text: r.message, fieldKey: r.fieldKey ?? key, fix: r.fix))
            }
        }
        for f in allFields where !inactive.contains(f.key) {
            for r in f.rules { add(r, key: f.key) }
            // Text validation of obviously malformed input.
            if case .text(let spec) = f.kind, let msg = Self.textProblem(values.string(f.key), spec.validation) {
                out.append(OptionMessage(id: "\(f.key).format", severity: .error, text: msg, fieldKey: f.key))
            }
        }
        for r in rules { add(r, key: nil) }
        return out.sorted { $0.severity > $1.severity }
    }

    private static func textProblem(_ s: String, _ v: TextValidation) -> L10n? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        switch v {
        case .none: return nil
        case .pageRange:
            return PageRange.parse(t, pageCount: nil) == nil ? L10n("Use a range like 1-3, 5, 8-.", "Введите диапазон, например 1-3, 5, 8-.") : nil
        case .hexColor:
            let ok = t.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
            return ok ? nil : L10n("Use a color like #RRGGBB.", "Введите цвет в виде #RRGGBB.")
        case .integerList:
            let ok = t.split(separator: ",").allSatisfy { Int($0.trimmingCharacters(in: .whitespaces)) != nil }
            return ok ? nil : L10n("Use whole numbers separated by commas.", "Введите целые числа через запятую.")
        case .timeList:
            let ok = t.split(separator: ",").allSatisfy { Util.parseTime(String($0)) != nil }
            return ok ? nil : L10n("Use times like 0:30, 1:15.", "Введите время в виде 0:30, 1:15.")
        case .regex(let pattern):
            return t.range(of: pattern, options: .regularExpression) != nil ? nil : L10n("The text has the wrong format.", "Текст имеет неверный формат.")
        }
    }

    // MARK: Studio helpers

    /// Fields whose resolved value differs from the schema defaults, with their labels (the "Show changes" list).
    func changedFields(_ values: OptionValues, source: SourceInfo? = nil) -> [(field: OptionField, change: OptionChange)] {
        let defs = defaults(source: source)
        return values.diff(against: defs).compactMap { c in field(c.key).map { ($0, c) } }
    }

    /// Option search across label, help, key and aliases in both languages. Expert fields are included.
    func search(_ query: String) -> [OptionSearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return [] }
        var hits: [OptionSearchHit] = []
        for p in pages {
            for g in p.groups {
                for f in g.fields {
                    let hay = [f.label.en, f.label.ru, f.help?.en ?? "", f.help?.ru ?? "", f.key, g.title?.en ?? "", g.title?.ru ?? ""] + f.aliases
                    if hay.contains(where: { $0.looseContains(q) }) { hits.append(OptionSearchHit(page: p, group: g, field: f)) }
                }
            }
        }
        return hits
    }
}

/// "all", "1-3, 5, 8-" page ranges shared by PDF operations and the validation of `.pageRange` text fields.
enum PageRange {
    /// Parses a user range into sorted unique 0-based indices. `pageCount` nil only validates syntax (returns []).
    /// Open ends ("8-", "-3") need `pageCount`. Returns nil on bad syntax or out-of-range values (when pageCount is known).
    static func parse(_ text: String, pageCount: Int?) -> [Int]? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "all" || t == L("all", "все") || t == "все" {
            guard let n = pageCount else { return [] }
            return Array(0..<n)
        }
        var out = Set<Int>()
        for part in t.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { return nil }
            if let dash = p.firstIndex(of: "-") {
                let a = String(p[p.startIndex..<dash]).trimmingCharacters(in: .whitespaces)
                let b = String(p[p.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
                if a.isEmpty && b.isEmpty { return nil }
                guard let lo = a.isEmpty ? 1 : Int(a), lo >= 1 else { return nil }
                if b.isEmpty && pageCount == nil { continue }
                guard let hi = b.isEmpty ? pageCount : Int(b), hi >= lo else { return nil }
                if let n = pageCount { if hi > n { return nil }; for i in lo...hi { out.insert(i - 1) } }
            } else {
                guard let n = Int(p), n >= 1 else { return nil }
                if let c = pageCount { if n > c { return nil }; out.insert(n - 1) }
            }
        }
        return out.sorted()
    }
}
