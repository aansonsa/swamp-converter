import Foundation

// Conditions for enabling / showing fields, evaluated against current values, the source probe and capabilities.
// Written in Swift with literals, e.g.
//     visibleWhen: .all([.eq("container", "mp4"), .not(.isSet("copyVideo"))])
//     enabledWhen: .source("video.height", .gt, 1080)
//     requires:    ["ff.enc.libx265"]            (capabilities are separate from Expr; `.cap` exists for composite rules)

enum SourceComparison: Sendable { case eq, ne, gt, gte, lt, lte, exists, absent }

struct ExprEnvironment {
    var values: OptionValues
    var source: SourceInfo?
    var capabilities: Capabilities = .shared
}

indirect enum OptionExpr: Sendable {
    case always
    case never
    case eq(String, OptionValue)
    case ne(String, OptionValue)
    case `in`(String, [OptionValue])
    case gt(String, Double)
    case gte(String, Double)
    case lt(String, Double)
    case lte(String, Double)
    /// True / non-zero / non-empty.
    case isSet(String)
    case all([OptionExpr])
    case any([OptionExpr])
    case not(OptionExpr)
    /// Compares a source fact (`SourceInfo.facts`, dotted key) with a literal. Unknown facts: only `.absent` is true.
    case source(String, SourceComparison, OptionValue)
    /// A capability id (see Capabilities.swift).
    case cap(String)

    func evaluate(_ env: ExprEnvironment) -> Bool {
        switch self {
        case .always: return true
        case .never: return false
        case .eq(let k, let v): return Self.equal(env.values[k], v)
        case .ne(let k, let v): return !Self.equal(env.values[k], v)
        case .in(let k, let vs): return vs.contains { Self.equal(env.values[k], $0) }
        case .gt(let k, let n): return (env.values[k]?.asDouble).map { $0 > n } ?? false
        case .gte(let k, let n): return (env.values[k]?.asDouble).map { $0 >= n } ?? false
        case .lt(let k, let n): return (env.values[k]?.asDouble).map { $0 < n } ?? false
        case .lte(let k, let n): return (env.values[k]?.asDouble).map { $0 <= n } ?? false
        case .isSet(let k): return Self.truthy(env.values[k])
        case .all(let xs): return xs.allSatisfy { $0.evaluate(env) }
        case .any(let xs): return xs.contains { $0.evaluate(env) }
        case .not(let x): return !x.evaluate(env)
        case .cap(let id): return env.capabilities.has(id)
        case .source(let k, let op, let lit):
            let fact = env.source?[k]
            switch op {
            case .exists: return fact != nil
            case .absent: return fact == nil
            case .eq: return Self.equal(fact, lit)
            case .ne: return fact != nil && !Self.equal(fact, lit)
            case .gt, .gte, .lt, .lte:
                guard let a = fact?.asDouble, let b = lit.asDouble else { return false }
                switch op { case .gt: return a > b; case .gte: return a >= b; case .lt: return a < b; default: return a <= b }
            }
        }
    }

    static func equal(_ a: OptionValue?, _ b: OptionValue) -> Bool {
        guard let a else { return false }
        if a == b { return true }
        // Numbers compare numerically (int 5 equals double 5.0); strings and bools compare by text/bool.
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.bool(let x), _): return b.asBool.map { $0 == x } ?? false
        default:
            if case .string = a { return false }
            if case .string = b { return false }
            if let x = a.asDouble, let y = b.asDouble { return abs(x - y) < 1e-9 }
            return false
        }
    }

    static func truthy(_ v: OptionValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty && s != "off" && s != "none"
        case .list(let l): return !l.isEmpty
        case .rows(let r): return !r.isEmpty
        }
    }

    /// Keys of option values this expression reads (used to build dependency order / change tracking).
    var referencedKeys: Set<String> {
        switch self {
        case .always, .never, .cap, .source: return []
        case .eq(let k, _), .ne(let k, _), .in(let k, _), .gt(let k, _), .gte(let k, _), .lt(let k, _), .lte(let k, _), .isSet(let k): return [k]
        case .all(let xs), .any(let xs): return xs.reduce(into: Set<String>()) { $0.formUnion($1.referencedKeys) }
        case .not(let x): return x.referencedKeys
        }
    }
}
