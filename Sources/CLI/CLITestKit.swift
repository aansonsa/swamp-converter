import Foundation

// Test support of the cli module: fixture operations (one with every field kind) and a rig that runs `CLI.run` IN-PROCESS against a private registry, settings,
// preset store and job queue, capturing stdout and stderr. Nothing here touches the real Application Support folder.

/// Writes a JSON report of what it received (the resolved options, the run mode, the input name) next to the input as "<name> (cli).json".
/// Its schema has one field of every kind, so the typing of `--set` is exercised against real field specs.
final class CLIFixtureOp: PerFileOperation, @unchecked Sendable {
    static let schemaID = "test.cli"

    init(id: String = "test.cli.report") {
        super.init(meta: .make(id, .tools, .app, L10n("CLI report"), symbol: "star", schema: CLIFixtureOp.schemaID, suffix: L10n("cli"), anyFile: true))
    }

    static func schema() -> OptionSchema {
        OptionSchema(id: schemaID, title: L10n("CLI fixture"), pages: [
            .make("main", symbol: "star", L10n("Main"), [
                .make("g", [
                    .text("f.text", L10n("Text"), def: "hello").basic(),
                    .stepper("f.count", L10n("Count"), min: 1, max: 5, def: 1),
                    .toggle("f.upper", L10n("Upper case")),
                    .slider("f.level", L10n("Level"), min: 0, max: 10, def: 5).enabled(.isSet("f.upper")),
                    .picker("f.mode", L10n("Mode"), [FieldOption("a", L10n("Alpha")), FieldOption("b", L10n("Bee")),
                                                      FieldOption("c", "C", requires: ["tool.nonexistent"])], def: "a"),
                    .time("f.start", L10n("Start")),
                    .number("f.gain", L10n("Gain"), min: -20, max: 20, step: 0.5, def: 0, unit: "dB", decimals: 1),
                    .color("f.color", L10n("Color"), def: "#FFFFFF"),
                    .folder("f.dir", L10n("Folder")),
                    .text("f.pages", L10n("Pages"), def: "", validation: .pageRange),
                    .text("f.secret", L10n("Secret"), secure: true),
                    .toggle("f.needs", L10n("Needs a missing tool")).needs(["tool.nonexistent"]),
                    .tracks("f.tracks", L10n("Tracks"), TrackSpec(columns: [.text("codec", L10n("Codec"), def: "aac"), .number("bitrate", L10n("Bitrate"), def: 128)]))
                ])
            ])
        ])
    }

    override func optionSchema(for items: [FileItem]) -> OptionSchema { Self.schema() }
    override func quickOverrides(settings: SettingsData) -> OptionValues { ["f.text": "quick", "f.count": 2] }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        var options: [String: Any] = [:]
        for (k, v) in ctx.options.storage { options[k] = CLIJSON.optionValue(v) }
        let report: [String: Any] = ["mode": ctx.mode.rawValue, "input": item.name, "options": options, "inactive": ctx.resolved.inactive.sorted(),
                                     "forbidAll": NetworkGate.forbidAll]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "json") { tmp in try data.write(to: tmp) }
        progress.report(1)
        return [url]
    }
}

/// Fails for names that start with "bad"; copies the text of the others into "<name> (flaky).txt".
final class CLIFlakyOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.cli.flaky", .tools, .app, L10n("Flaky"), symbol: "bolt", schema: "test.cli.flaky", suffix: L10n("flaky"), anyFile: true)) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        if item.name.hasPrefix("bad") { throw ConversionError.message(L10n("this input is bad")) }
        let text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        return [try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { tmp in try text.write(to: tmp, atomically: false, encoding: .utf8) }]
    }
}

/// Reports progress in four steps with pauses longer than the watcher's poll interval, so a run shows several progress events.
final class CLISteppedOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.cli.stepped", .tools, .app, L10n("Stepped"), symbol: "list.number", schema: "test.cli.stepped", suffix: L10n("stepped"), anyFile: true)) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        for step in 1...4 {
            try ctx.checkCancelled()
            progress.report(Double(step) / 4, message: "step \(step)")
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        return [try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { tmp in try "done".write(to: tmp, atomically: false, encoding: .utf8) }]
    }
}

/// Needs a tool that is not there.
final class CLIUnavailableOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.cli.unavailable", .tools, .app, L10n("Unavailable"), symbol: "xmark", schema: "test.cli.unavailable", anyFile: true)) }
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        .unavailable(reason: L10n("Needs Pandoc (not installed).", "Нужен Pandoc (не установлен)."), missing: [.pandoc])
    }
}

/// Looks usable, then finds out while running that its program is not installed (the program was removed, or the build lacks an encoder).
final class CLIVanishedToolOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.cli.vanished", .tools, .app, L10n("Vanished"), symbol: "questionmark", schema: "test.cli.vanished", suffix: L10n("vanished"), anyFile: true)) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] { throw ConversionError.toolMissing(.pandoc) }
}

/// Accepts only PNG files.
final class CLIPngOnlyOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.cli.png", .tools, .image, L10n("PNG only"), symbol: "photo", schema: "test.cli.png", inputs: ["png"], suffix: L10n("png"))) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        [try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { tmp in try "png".write(to: tmp, atomically: false, encoding: .utf8) }]
    }
}

/// An action that runs in the app only.
final class CLIFixtureAction: AppAction, @unchecked Sendable {
    init() { super.init(meta: .make("test.cli.action", .actions, .app, L10n("Action"), symbol: "bolt", schema: "test.cli.action", anyFile: true)) }
}

/// What one in-process CLI run produced.
struct CLIResult {
    var code: Int32
    var stdout: String
    var stderr: String
    var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    /// stdout lines parsed as JSON objects (a line that is not an object fails the test that asks for them).
    func events() throws -> [[String: Any]] {
        try lines.map { line in
            guard let o = CLIJSON.parseObject(line) else { throw TestFailure(message: "stdout line is not a JSON object: \(line)", file: #fileID, line: #line) }
            return o
        }
    }
    func event(_ name: String) throws -> [[String: Any]] { try events().filter { ($0["event"] as? String) == name } }
}

/// A private world for one test: registry with the fixture operations, settings, preset store, job queue and a temp folder.
@MainActor
final class CLIRig {
    let fx = TestFixtures(label: "cli")
    let registry = OperationRegistry()
    let settings: AppSettings
    let presets: PresetStore
    let runner: JobRunner

    init(extra: [Operation] = []) {
        registry.register([CLIFixtureOp(), CLIFlakyOp(), CLISteppedOp(), CLIUnavailableOp(), CLIVanishedToolOp(), CLIPngOnlyOp(), CLIFixtureAction(), SlowOp()] + extra)
        settings = AppSettings(fileURL: fx.url("settings.json"), autosave: false)
        presets = PresetStore(directory: fx.url("presets"))
        runner = JobRunner(persistence: false, registry: registry, settings: settings)
    }

    var environment: CLIEnvironment {
        CLIEnvironment(registry: registry, settings: settings, presets: presets, runner: runner, bootstrap: false, tools: .shared)
    }

    func cleanup() { runner.cancelAll(); fx.cleanup() }

    /// Runs the command line in this process (English messages), capturing stdout and stderr.
    @discardableResult
    func run(_ args: [String], environment env: CLIEnvironment? = nil, signals: Bool = false) async -> CLIResult {
        await CLIRig.run(args, environment: env ?? environment, signals: signals)
    }

    static func run(_ args: [String], environment: CLIEnvironment, signals: Bool = false) async -> CLIResult {
        let sink = CLISink()
        let saved = Loc.shared.setting
        Loc.shared.set(.english)
        defer { Loc.shared.set(saved) }
        let code = await CLI.run(arguments: args, environment: environment, sink: sink, handleSignals: signals)
        return CLIResult(code: code, stdout: sink.stdout, stderr: sink.stderr)
    }

    /// A text file with the given name in the rig's folder (or a subfolder).
    func file(_ name: String, _ content: String = "x", in folder: String? = nil) throws -> URL {
        var dir = fx.root
        if let folder { dir = try fx.makeDirectory(folder) }
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Output reports written by `CLIFixtureOp`, parsed.
    func report(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try unwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "the report is a JSON object")
    }
}

/// Parses with the real parser, failing the test with the parser's message.
func cliParse(_ args: [String]) throws -> CLIInvocation {
    switch CLIArguments.parse(args) {
    case .success(let i): return i
    case .failure(let e): throw TestFailure(message: "parse failed for \(args): \(e.message)", file: #fileID, line: #line)
    }
}

/// The parser's usage error message for `args` (English), failing the test when it parses.
func cliParseError(_ args: [String]) throws -> String {
    let saved = Loc.shared.setting
    Loc.shared.set(.english)
    defer { Loc.shared.set(saved) }
    switch CLIArguments.parse(args) {
    case .success(let i): throw TestFailure(message: "expected a usage error for \(args), got \(i)", file: #fileID, line: #line)
    case .failure(let e): return e.message
    }
}
