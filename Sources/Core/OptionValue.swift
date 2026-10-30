import Foundation

// Typed option values. One OptionValue is what a single field holds; OptionValues is a whole set
// (a preset, a quick recipe, a job's options). Both are Codable as PLAIN JSON (true, 5, 1.5, "x", [...], [{...}])
// so preset files are readable and hand-editable.

enum OptionValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    /// Also used for time fields (seconds).
    case double(Double)
    case string(String)
    case list([OptionValue])
    /// Rows of a `tracks` field (audio tracks, subtitle tracks, chapters).
    case rows([[String: OptionValue]])

    var asBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return ["true", "yes", "1", "on"].contains(s.lowercased()) ? true : (["false", "no", "0", "off", ""].contains(s.lowercased()) ? false : nil)
        default: return nil
        }
    }
    var asInt: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d.rounded()) : nil
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces)) ?? Double(s.replacingOccurrences(of: ",", with: ".")).map { Int($0.rounded()) }
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }
    var asString: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var asList: [OptionValue]? {
        switch self {
        case .list(let l): return l
        case .rows(let r): return r.isEmpty ? [] : nil
        default: return nil
        }
    }
    var asRows: [[String: OptionValue]]? {
        switch self {
        case .rows(let r): return r
        case .list(let l): return l.isEmpty ? [] : nil
        default: return nil
        }
    }

    /// Short human text for the "Show changes" list ("on", "22", "mp4", "3 rows").
    var displayText: String {
        switch self {
        case .bool(let b): return b ? L("on", "вкл.") : L("off", "выкл.")
        case .int, .double, .string: return asString ?? ""
        case .list(let l): return l.compactMap(\.asString).joined(separator: ", ")
        case .rows(let r): return L("\(r.count) rows", "строк: \(r.count)")
        }
    }
}

extension OptionValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let rows = try? c.decode([[String: OptionValue]].self), !rows.isEmpty { self = .rows(rows); return }
        if let l = try? c.decode([OptionValue].self) { self = .list(l); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported option value")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .list(let l): try c.encode(l)
        case .rows(let r): try c.encode(r)
        }
    }
}

extension OptionValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: OptionValue...) { self = .list(elements) }
}

/// One change between two option sets ("Quality 22 -> 20").
struct OptionChange: Hashable, Sendable {
    var key: String
    var old: OptionValue?
    var new: OptionValue?
}

/// A whole set of option values keyed by the schema's field keys.
struct OptionValues: Codable, Equatable, Sendable, ExpressibleByDictionaryLiteral {
    var storage: [String: OptionValue]

    init() { storage = [:] }
    init(_ dict: [String: OptionValue]) { storage = dict }
    init(dictionaryLiteral elements: (String, OptionValue)...) { storage = Dictionary(elements, uniquingKeysWith: { $1 }) }

    init(from decoder: Decoder) throws {
        storage = try [String: OptionValue](from: decoder)
    }
    func encode(to encoder: Encoder) throws { try storage.encode(to: encoder) }

    var isEmpty: Bool { storage.isEmpty }
    var keys: [String] { Array(storage.keys).sorted() }
    func has(_ key: String) -> Bool { storage[key] != nil }

    subscript(key: String) -> OptionValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    // Typed readers. They coerce (an int reads as a double, "true" as a bool) and fall back to the default.
    func bool(_ key: String, _ def: Bool = false) -> Bool { storage[key]?.asBool ?? def }
    func int(_ key: String, _ def: Int = 0) -> Int { storage[key]?.asInt ?? def }
    func double(_ key: String, _ def: Double = 0) -> Double { storage[key]?.asDouble ?? def }
    /// Time fields are stored in seconds.
    func time(_ key: String, _ def: Double = 0) -> Double { double(key, def) }
    func string(_ key: String, _ def: String = "") -> String { storage[key]?.asString ?? def }
    func list(_ key: String) -> [OptionValue] { storage[key]?.asList ?? [] }
    func rows(_ key: String) -> [[String: OptionValue]] { storage[key]?.asRows ?? [] }

    mutating func set(_ key: String, _ value: OptionValue?) { storage[key] = value }

    /// `self` wins over `base` for keys present in both.
    func merged(over base: OptionValues) -> OptionValues {
        var out = base
        for (k, v) in storage { out.storage[k] = v }
        return out
    }

    /// `other` wins over `self`.
    func overlaying(_ other: OptionValues) -> OptionValues { other.merged(over: self) }

    /// Keys whose value differs from `defaults` (missing in `self` counts as "unchanged"). Sorted by key.
    func diff(against defaults: OptionValues) -> [OptionChange] {
        var out: [OptionChange] = []
        for k in storage.keys.sorted() {
            let new = storage[k]
            let old = defaults.storage[k]
            if new != old && !(Self.numericallyEqual(new, old)) { out.append(OptionChange(key: k, old: old, new: new)) }
        }
        return out
    }

    private static func numericallyEqual(_ a: OptionValue?, _ b: OptionValue?) -> Bool {
        guard let a, let b else { return false }
        switch (a, b) {
        case (.int, .double), (.double, .int), (.double, .double), (.int, .int):
            return abs((a.asDouble ?? 0) - (b.asDouble ?? 1)) < 1e-9
        default: return false
        }
    }

    /// Only the keys that differ from `defaults` (the sparse form stored in presets and recipes).
    func sparse(against defaults: OptionValues) -> OptionValues {
        var out = OptionValues()
        for c in diff(against: defaults) { out.storage[c.key] = c.new }
        return out
    }
}
