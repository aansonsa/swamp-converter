import Foundation

enum CLICommand: String, CaseIterable, Sendable {
    case convert, download, probe, listOps = "list-ops", presets, options, version, help
}

struct CLIInvocation: Equatable, Sendable {
    var command: CLICommand
    /// Arguments without a leading dash (files, a URL, a subcommand).
    var positional: [String] = []
    /// `--out dir`, `--op id`, `--preset name`, `--mode m`, `--kind k`, `--lang l`, `--target t`: last one wins.
    var options: [String: String] = [:]
    /// Repeated `--set key=value`.
    var sets: [String] = []
    var json = false
    /// Switches without a value, by name without the dashes: consent, plan, quiet, verbose, pretty, available, force.
    var flags: Set<String> = []
}

struct CLIUsageError: Error, Equatable, Sendable { var message: String }

/// One accepted option of a command line.
struct CLIOptionSpec: Equatable, Sendable {
    var name: String
    var takesValue: Bool
    var short: Character? = nil
    var repeatable = false
}

enum CLIArguments {
    // MARK: Option tables

    /// Accepted by every command.
    static let globalOptions: [CLIOptionSpec] = [
        CLIOptionSpec(name: "json", takesValue: false),
        CLIOptionSpec(name: "pretty", takesValue: false),
        CLIOptionSpec(name: "quiet", takesValue: false, short: "q"),
        CLIOptionSpec(name: "verbose", takesValue: false, short: "v"),
        CLIOptionSpec(name: "lang", takesValue: true),
        CLIOptionSpec(name: "help", takesValue: false, short: "h")
    ]

    static func options(of command: CLICommand) -> [CLIOptionSpec] {
        switch command {
        case .convert:
            return [CLIOptionSpec(name: "op", takesValue: true), CLIOptionSpec(name: "preset", takesValue: true),
                    CLIOptionSpec(name: "set", takesValue: true, repeatable: true), CLIOptionSpec(name: "out", takesValue: true, short: "o")]
        case .download:
            return [CLIOptionSpec(name: "mode", takesValue: true), CLIOptionSpec(name: "out", takesValue: true, short: "o"),
                    CLIOptionSpec(name: "set", takesValue: true, repeatable: true), CLIOptionSpec(name: "consent", takesValue: false)]
        case .probe: return [CLIOptionSpec(name: "plan", takesValue: false)]
        case .listOps: return [CLIOptionSpec(name: "kind", takesValue: true), CLIOptionSpec(name: "available", takesValue: false)]
        case .presets: return [CLIOptionSpec(name: "target", takesValue: true), CLIOptionSpec(name: "force", takesValue: false)]
        case .options, .version, .help: return []
        }
    }

    /// `--kind` accepts an operation family or a wheel.
    static var kindNames: [String] { OperationFamily.allCases.map(\.rawValue) + WheelKind.allCases.map(\.rawValue) }
    static let presetSubcommands = ["list", "show", "export", "import"]

    // MARK: Parsing

    /// Pure parser. Rules: `--` ends options; `--key=value` and `--key value` both work; unknown options are a usage error (never silently ignored); `--set` needs `key=value`;
    /// values of `--set` are typed from the operation's schema later (true / 5 / 1.5 / text / a,b lists). A switch takes no value (`--json=false` switches it off).
    /// `<command> --help` and `--help` / `--version` as the first argument are forms of `help` / `version`.
    static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        var args = arguments
        if args.first == "--cli" { args.removeFirst() }
        guard let first = args.first else { return .failure(CLIUsageError(message: L("No command given. Try: swamp help", "Команда не указана. Попробуйте: swamp help"))) }
        let command: CLICommand
        switch first {
        case "--help", "-h": return .success(CLIInvocation(command: .help, positional: Array(args.dropFirst().filter { !$0.hasPrefix("-") }.prefix(1))))
        case "--version": return .success(CLIInvocation(command: .version, json: args.contains("--json")))
        default:
            guard let c = CLICommand(rawValue: first) else {
                let hint = CLISuggest.nearest(first, among: CLICommand.allCases.map(\.rawValue)).map { L(" Did you mean '\($0)'?", " Возможно, '\($0)'?") } ?? ""
                return .failure(CLIUsageError(message: L("Unknown command '\(first)'.", "Неизвестная команда '\(first)'.") + hint))
            }
            command = c
        }

        let specs = globalOptions + options(of: command)
        var inv = CLIInvocation(command: command)
        var helpRequested = false
        var onlyPositional = false
        var i = 1
        while i < args.count {
            let a = args[i]
            i += 1
            if onlyPositional || !a.hasPrefix("-") || a == "-" { inv.positional.append(a); continue }
            if a == "--" { onlyPositional = true; continue }

            var spec: CLIOptionSpec?
            var inline: String?
            var shownName = a
            if a.hasPrefix("--") {
                var name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") { inline = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
                spec = specs.first { $0.name == name }
                shownName = "--" + name
                if spec == nil {
                    let hint = CLISuggest.nearest(name, among: specs.map(\.name)).map { L(" Did you mean --\($0)?", " Возможно, --\($0)?") } ?? ""
                    return .failure(CLIUsageError(message: L("Unknown option --\(name) for '\(command.rawValue)'.", "Неизвестный параметр --\(name) для '\(command.rawValue)'.") + hint))
                }
            } else if a.count == 2, let ch = a.dropFirst().first, let s = specs.first(where: { $0.short == ch }) {
                spec = s
            } else {
                return .failure(CLIUsageError(message: L("Unknown option \(a) for '\(command.rawValue)'. Use -- before file names that start with a dash.",
                                                         "Неизвестный параметр \(a) для '\(command.rawValue)'. Перед именами файлов с дефисом в начале поставьте --.")))
            }
            guard let spec else { continue }

            if !spec.takesValue {
                if let inline {
                    switch inline.lowercased() {
                    case "true", "1", "yes", "on": break
                    case "false", "0", "no", "off": apply(spec.name, value: nil, to: &inv, switchOff: true); continue
                    default: return .failure(CLIUsageError(message: L("\(shownName) is a switch and takes no value.", "\(shownName) — это переключатель, значение не нужно.")))
                    }
                }
                if spec.name == "help" { helpRequested = true } else { apply(spec.name, value: nil, to: &inv, switchOff: false) }
                continue
            }

            var value = inline
            if value == nil {
                if i < args.count, !(args[i].hasPrefix("--") && args[i] != "--") { value = args[i]; i += 1 }
            }
            guard let value, !value.isEmpty || spec.name == "set" else {
                return .failure(CLIUsageError(message: L("\(shownName) needs a value.", "Для \(shownName) нужно указать значение.")))
            }
            switch spec.name {
            case "set":
                guard let eq = value.firstIndex(of: "="), !value[..<eq].trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure(CLIUsageError(message: L("--set needs key=value, got '\(value)'.", "--set требует вид ключ=значение, получено '\(value)'.")))
                }
                inv.sets.append(value)
            case "mode":
                guard let m = DownloadMode(parameter: value) else {
                    return .failure(CLIUsageError(message: L("Unknown download mode '\(value)'. Use one of: \(DownloadMode.allCases.map(\.rawValue).joined(separator: ", ")).",
                                                             "Неизвестный режим загрузки '\(value)'. Допустимо: \(DownloadMode.allCases.map(\.rawValue).joined(separator: ", ")).")))
                }
                inv.options["mode"] = m.rawValue
            case "kind":
                let k = value.lowercased()
                guard kindNames.contains(k) else {
                    return .failure(CLIUsageError(message: L("Unknown kind '\(value)'. Use one of: \(kindNames.joined(separator: ", ")).",
                                                             "Неизвестный вид '\(value)'. Допустимо: \(kindNames.joined(separator: ", ")).")))
                }
                inv.options["kind"] = k
            case "lang":
                guard let l = language(value) else {
                    return .failure(CLIUsageError(message: L("Unknown language '\(value)'. Use en, ru or system.", "Неизвестный язык '\(value)'. Допустимо: en, ru, system.")))
                }
                inv.options["lang"] = l
            default:
                inv.options[spec.name] = value
            }
        }

        if helpRequested { return .success(CLIInvocation(command: .help, positional: command == .help ? inv.positional : [command.rawValue])) }
        if let problem = shapeProblem(inv) { return .failure(CLIUsageError(message: problem)) }
        return .success(inv)
    }

    private static func apply(_ name: String, value: String?, to inv: inout CLIInvocation, switchOff: Bool) {
        if name == "json" { inv.json = !switchOff; return }
        if switchOff { inv.flags.remove(name) } else { inv.flags.insert(name) }
    }

    /// "en" / "ru" / "system" (also english, russian, auto).
    static func language(_ value: String) -> String? {
        switch value.lowercased() {
        case "en", "eng", "english": return "en"
        case "ru", "rus", "russian": return "ru"
        case "system", "auto": return "system"
        default: return nil
        }
    }

    /// The per-command positional rules, so every command shape is validated in one pure place.
    private static func shapeProblem(_ inv: CLIInvocation) -> String? {
        let p = inv.positional
        switch inv.command {
        case .convert:
            if p.isEmpty { return L("convert needs at least one file. Example: swamp convert photo.heic --op image.to.jpg", "convert требует хотя бы один файл. Пример: swamp convert photo.heic --op image.to.jpg") }
            if inv.options["op"] == nil && inv.options["preset"] == nil {
                return L("convert needs --op <id> or --preset <name>. List the choices with: swamp list-ops", "convert требует --op <id> или --preset <имя>. Список вариантов: swamp list-ops")
            }
        case .download:
            if p.count != 1 { return L("download needs exactly one link. Example: swamp download https://example.com/video --mode best", "download требует ровно одну ссылку. Пример: swamp download https://example.com/video --mode best") }
        case .probe:
            if p.count != 1 { return L("probe needs exactly one file.", "probe требует ровно один файл.") }
        case .listOps:
            if !p.isEmpty { return L("list-ops takes no arguments (use --kind to filter).", "list-ops не принимает аргументов (для фильтра используйте --kind).") }
        case .presets:
            let sub = p.first ?? "list"
            guard presetSubcommands.contains(sub) else {
                return L("Unknown presets command '\(sub)'. Use: \(presetSubcommands.joined(separator: ", ")).", "Неизвестная команда presets '\(sub)'. Допустимо: \(presetSubcommands.joined(separator: ", ")).")
            }
            let need = ["list": 1, "show": 2, "export": 3, "import": 2][sub] ?? 1
            let have = max(p.count, 1)
            if have != need {
                let usage = ["list": "presets list", "show": "presets show <id|name>", "export": "presets export <id|name> <file>", "import": "presets import <file>"][sub] ?? sub
                return L("Usage: swamp \(usage)", "Использование: swamp \(usage)")
            }
        case .options:
            if p.count != 1 { return L("options needs exactly one operation id. Example: swamp options image.to.jpg", "options требует ровно один id операции. Пример: swamp options image.to.jpg") }
        case .version:
            if !p.isEmpty { return L("version takes no arguments.", "version не принимает аргументов.") }
        case .help:
            if p.count > 1 { return L("help takes at most one topic.", "help принимает не более одной темы.") }
        }
        return nil
    }

    // MARK: Typed option values

    /// Converts `key=value` strings to `OptionValues` using the field kinds of `schema` (toggle -> bool, slider / stepper / number -> numbers, time -> seconds from "1:30", list -> comma split).
    /// Unknown keys and out-of-range values are usage errors with the nearest valid key suggested.
    static func optionValues(from sets: [String], schema: OptionSchema) -> Result<OptionValues, CLIUsageError> {
        CLIOptionTyping.values(from: sets, schema: schema)
    }
}

/// "Did you mean ...": suffix matches first (`crf` -> `video.crf`), then the smallest edit distance.
enum CLISuggest {
    static func nearest(_ word: String, among candidates: [String]) -> String? {
        let w = word.lowercased()
        guard !w.isEmpty else { return nil }
        if let hit = candidates.first(where: { $0.lowercased() == w }) { return hit }
        if let hit = candidates.first(where: { $0.lowercased().hasSuffix("." + w) }) { return hit }
        var best: (String, Int)?
        for c in candidates {
            let d = distance(w, c.lowercased())
            if best == nil || d < best!.1 { best = (c, d) }
        }
        guard let (c, d) = best, d <= max(2, w.count / 3) else { return nil }
        return c
    }

    /// Up to `limit` candidates sorted by closeness (for error messages that list choices).
    static func closest(_ word: String, among candidates: [String], limit: Int = 3) -> [String] {
        let w = word.lowercased()
        var scored: [(name: String, score: Int)] = []
        for c in candidates {
            let lower = c.lowercased()
            scored.append((c, lower.contains(w) ? 0 : distance(w, lower)))
        }
        scored.sort { $0.score == $1.score ? $0.name < $1.name : $0.score < $1.score }
        return scored.prefix(limit).map { $0.name }
    }

    /// Levenshtein distance on Characters.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}
