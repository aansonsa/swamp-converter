import Foundation

/// Typing of `--set key=value` strings against an option schema. Pure: no registry, no settings, no files read.
enum CLIOptionTyping {
    /// Splits "key=value" at the first "=" (the value may contain more).
    static func split(_ set: String) -> (key: String, value: String)? {
        guard let eq = set.firstIndex(of: "=") else { return nil }
        let key = set[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(set[set.index(after: eq)...]))
    }

    static func values(from sets: [String], schema: OptionSchema) -> Result<OptionValues, CLIUsageError> {
        var out = OptionValues()
        let fields = schema.allFields
        let keys = fields.map(\.key)
        for raw in sets {
            guard let (key, text) = split(raw) else {
                return .failure(CLIUsageError(message: L("--set needs key=value, got '\(raw)'.", "--set требует вид ключ=значение, получено '\(raw)'.")))
            }
            guard let field = fields.first(where: { $0.key == key }) else {
                var message = L("Unknown option '\(key)'.", "Неизвестный параметр '\(key)'.")
                if keys.isEmpty {
                    message += " " + L("This operation has no options.", "У этой операции нет параметров.")
                } else if let near = CLISuggest.nearest(key, among: keys) {
                    message += " " + L("Did you mean '\(near)'?", "Возможно, '\(near)'?")
                } else {
                    message += " " + L("See: swamp options <operation>", "Список параметров: swamp options <операция>")
                }
                return .failure(CLIUsageError(message: message))
            }
            switch typed(text, field: field) {
            case .success(let v): out[key] = v
            case .failure(let e): return .failure(e)
            }
        }
        return .success(out)
    }

    /// One value, typed from the field kind. The message names the key and what was expected.
    static func typed(_ text: String, field f: OptionField) -> Result<OptionValue, CLIUsageError> {
        func fail(_ en: String, _ ru: String) -> Result<OptionValue, CLIUsageError> {
            .failure(CLIUsageError(message: "'\(f.key)': " + L(en, ru)))
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch f.kind {
        case .toggle:
            switch trimmed.lowercased() {
            case "true", "yes", "on", "1", "да", "вкл": return .success(.bool(true))
            case "false", "no", "off", "0", "нет", "выкл": return .success(.bool(false))
            default: return fail("expected true or false, got '\(text)'.", "ожидается true или false, получено '\(text)'.")
            }

        case .picker(let options), .segmented(let options):
            if let o = options.first(where: { $0.value == trimmed })
                ?? options.first(where: { $0.value.caseInsensitiveCompare(trimmed) == .orderedSame })
                ?? options.first(where: { $0.label.en.caseInsensitiveCompare(trimmed) == .orderedSame || $0.label.ru.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return .success(.string(o.value))
            }
            let valid = options.map(\.value)
            return fail("'\(text)' is not one of: \(valid.joined(separator: ", ")).", "'\(text)' не входит в список: \(valid.joined(separator: ", ")).")

        case .slider(let spec):
            guard let n = number(trimmed) else { return fail("expected a number, got '\(text)'.", "ожидается число, получено '\(text)'.") }
            guard n >= spec.min, n <= spec.max else {
                return fail("\(trimmed) is out of range \(fmt(spec.min))...\(fmt(spec.max)).", "\(trimmed) вне диапазона \(fmt(spec.min))...\(fmt(spec.max)).")
            }
            if spec.decimals == 0 && spec.step == spec.step.rounded() {
                guard n == n.rounded() else { return fail("expects a whole number, got '\(text)'.", "ожидается целое число, получено '\(text)'.") }
                return .success(.int(Int(n)))
            }
            return .success(.double(n))

        case .stepper(let spec):
            guard let n = number(trimmed), n == n.rounded() else { return fail("expected a whole number, got '\(text)'.", "ожидается целое число, получено '\(text)'.") }
            guard Int(n) >= spec.min, Int(n) <= spec.max else {
                return fail("\(trimmed) is out of range \(spec.min)...\(spec.max).", "\(trimmed) вне диапазона \(spec.min)...\(spec.max).")
            }
            return .success(.int(Int(n)))

        case .number(let spec):
            guard let n = number(trimmed) else { return fail("expected a number, got '\(text)'.", "ожидается число, получено '\(text)'.") }
            if let lo = spec.min, n < lo { return fail("\(trimmed) is below the minimum \(fmt(lo)).", "\(trimmed) меньше минимума \(fmt(lo)).") }
            if let hi = spec.max, n > hi { return fail("\(trimmed) is above the maximum \(fmt(hi)).", "\(trimmed) больше максимума \(fmt(hi)).") }
            if spec.decimals == 0 && spec.step == spec.step.rounded() {
                guard n == n.rounded() else { return fail("expects a whole number, got '\(text)'.", "ожидается целое число, получено '\(text)'.") }
                return .success(.int(Int(n)))
            }
            return .success(.double(n))

        case .time(let spec):
            if trimmed.isEmpty {
                return spec.allowEmpty ? .success(.string("")) : fail("a time is required.", "нужно указать время.")
            }
            guard let t = Util.parseTime(trimmed) else {
                return fail("expected a time like 90, 1:30 or 01:02:03.5, got '\(text)'.", "ожидается время вида 90, 1:30 или 01:02:03.5, получено '\(text)'.")
            }
            return .success(.double(t))

        case .color:
            var hex = trimmed
            if !hex.hasPrefix("#") { hex = "#" + hex }
            guard hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                return fail("expected a colour like #FF72D9, got '\(text)'.", "ожидается цвет вида #FF72D9, получено '\(text)'.")
            }
            return .success(.string(hex.uppercased()))

        case .folder, .file:
            return .success(.string(trimmed.isEmpty ? "" : absolutePath(trimmed)))

        case .text:
            return .success(.string(text))

        case .tracks:
            if trimmed.isEmpty || trimmed == "[]" { return .success(.rows([])) }
            guard let data = trimmed.data(using: .utf8), let rows = try? JSONDecoder().decode([[String: OptionValue]].self, from: data) else {
                return fail("expected a JSON list of objects, for example [{\"codec\":\"aac\"}].", "ожидается JSON-список объектов, например [{\"codec\":\"aac\"}].")
            }
            return .success(.rows(rows))
        }
    }

    // MARK: Helpers

    /// Decimal point or comma; finite numbers only.
    static func number(_ s: String) -> Double? {
        guard let d = Double(s.replacingOccurrences(of: ",", with: ".")), d.isFinite else { return nil }
        return d
    }

    /// 5 -> "5", 0.5 -> "0.5".
    static func fmt(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d) }

    /// "~/x" and relative paths become absolute (relative to the current directory), `..` and `.` are resolved.
    static func absolutePath(_ p: String) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL.path
    }
}
