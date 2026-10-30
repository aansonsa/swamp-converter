import Foundation

// MODULE cli (owner: CLI engineer). Prefix for new top-level types: CLI*.
// Files: Sources/CLI/*.
// Spec: the LIFE-IMPROVER block H of the project brief; spec/appfeatures.md 7.2 (startup arguments), 8 (the original self-test: exit codes, log files).
//
// The SAME binary runs headless: `SwampConverter convert ...` (and, once install.sh has linked it, `swamp convert ...`). Useful for Shortcuts "Run Shell Script", Automator, scripts,
// and it powers the self-tests. No UI is started: `main.swift` calls `CLI.run` BEFORE NSApplication exists. It uses the very same `OperationRegistry`, `QuickRecipes`, `JobRunner` and
// `DownloadService` as the app, so a CLI result equals a wheel result for equal options.
//
//   swamp convert <files...> --op <id> [--preset <name>] [--set key=value ...] [--out <dir>] [--json]
//   swamp download <url> [--mode best|max|universal|audio-m4a|audio-mp3] [--out <dir>] [--set key=value ...] [--consent] [--json]
//   swamp probe <file> [--json] [--plan]      (SourceInfo: facts, chips, streams, warnings; `--plan` adds the smart-transcode plans for videos)
//   swamp list-ops [--json] [--kind image|video|...] [--available]   (id, wheel, label, schema id, availability + reason, usesNetwork)
//   swamp presets list|show <id|name>|export <id|name> <file>|import <file> [--json]
//   swamp options <op> [--json]               (the option schema: keys, types, defaults, ranges: scripts can discover every knob)
//   swamp version | help [command]
// Everywhere: --json (machine output), --pretty (indent JSON documents), --quiet, --verbose (job log on stderr), --lang en|ru|system.
// Exit codes (stable): 0 ok, 1 failed, 2 usage error, 3 unavailable (tool missing / consent needed / unsupported input), 4 partial (some files failed), 130 cancelled (SIGINT).
// `--json` prints ONE JSON object per line (JSON Lines) on stdout: {"event":"progress","job":"...","fraction":0.42,"stage":"download","eta":12.5}, {"event":"done","outputs":[...]},
// {"event":"error","code":3,"message":"..."}; human mode prints a progress line on stderr and the result paths on stdout. Never prompts, never opens a window, never touches the network
// unless the command is `download` (and consent is on in settings, or `--consent` is passed for this one run).
//
// stdout is a contract: in the real process file descriptor 1 is pointed at stderr for the whole run and the results are written to a private copy of the original stdout,
// so a library that prints by accident can never corrupt the output.

enum CLIExitCode: Int32 {
    case ok = 0, failed = 1, usage = 2, unavailable = 3, partial = 4, cancelled = 130
}

enum CLI {
    /// True when `arguments` (without the executable) start with a CLI verb, `--cli`, or the executable is named `swamp`.
    static func isCLIInvocation(arguments: [String], executableName: String = CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") -> Bool {
        let verbs: Set<String> = ["convert", "download", "probe", "list-ops", "presets", "options", "version", "help", "--help", "-h", "--version", "--cli"]
        if executableName == "swamp" { return true }
        return arguments.first.map { verbs.contains($0) } ?? false
    }

    /// Runs the command and returns the exit code. Installs SIGINT handling (cancel running jobs, exit 130). Registers the engines itself (`EnginesBootstrap.registerAll`).
    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        await run(arguments: arguments, environment: CLIEnvironment(), sink: nil)
    }

    /// The same with an injected environment. With a `sink` nothing touches the real stdout / stderr or file descriptors (the self-tests run it in-process);
    /// signal handling follows `handleSignals` (default: only without a sink).
    @MainActor
    static func run(arguments: [String], environment: CLIEnvironment, sink: CLISink?, handleSignals: Bool? = nil) async -> Int32 {
        var args = arguments
        if args.first == "--cli" { args.removeFirst() }
        let wantsJSON = jsonRequested(args)
        var out = CLIOutput(json: wantsJSON, sink: sink)

        var realOut: Int32?
        var signals: CLISignals?
        if sink == nil {
            // stdout is the contract: keep a private copy of it and point fd 1 at stderr for the rest of the run.
            let copy = dup(1)
            if copy >= 0 { realOut = copy; out.outFD = copy; dup2(2, 1) }
            signal(SIGPIPE, SIG_IGN)
            out.interactive = isatty(2) != 0
        }
        if handleSignals ?? (sink == nil) { signals = CLISignals.install() }
        defer {
            signals?.remove()
            if let realOut { close(realOut) }
        }

        let parsed = CLIArguments.parse(args)
        let inv: CLIInvocation
        switch parsed {
        case .failure(let e):
            out.error(code: .usage, message: e.message)
            if !wantsJSON { out.note(L("Try: swamp help", "Справка: swamp help")) }
            return CLIExitCode.usage.rawValue
        case .success(let i): inv = i
        }
        out.json = inv.json
        out.pretty = inv.flags.contains("pretty")
        out.quiet = inv.flags.contains("quiet")
        out.verbose = inv.flags.contains("verbose")

        // Settings first (they set the language and the tool paths), then the explicit --lang.
        _ = environment.settings.data
        let savedLanguage = Loc.shared.setting
        defer { Loc.shared.set(savedLanguage) }
        if let l = inv.options["lang"] { Loc.shared.set(l == "ru" ? .russian : (l == "en" ? .english : .system)) }

        let savedForbid = NetworkGate.forbidAll
        defer { NetworkGate.forbidAll = savedForbid }
        if inv.command != .download { NetworkGate.forbidAll = true }

        if environment.bootstrap { EnginesBootstrap.registerAll() }
        CLIRuntime.reset()
        CLIRuntime.environment = environment
        defer { CLIRuntime.reset() }

        switch inv.command {
        case .convert: return await CLICommands.convert(inv, out: out)
        case .download: return await CLICommands.download(inv, out: out)
        case .probe: return await CLICommands.probe(inv, out: out)
        case .listOps: return await CLICommands.listOps(inv, out: out)
        case .presets: return await CLICommands.presets(inv, out: out)
        case .options: return await CLICommands.options(inv, out: out)
        case .version: return CLICommands.version(out: out)
        case .help: return CLICommands.help(topic: inv.positional.first, out: out)
        }
    }

    /// Cancels the jobs of the running command (what SIGINT does). The command then ends with exit code 130.
    @MainActor
    static func requestCancel() { CLIRuntime.requestCancel() }

    #if !SC_SHIPPING
    static func registerSelfTests() { CLITests.register() }
    #endif

    // MARK: Internals

    /// `--json` anywhere before a bare `--` (so even a usage error can answer in JSON).
    static func jsonRequested(_ args: [String]) -> Bool {
        for a in args {
            if a == "--" { return false }
            if a == "--json" || a == "--json=true" { return true }
        }
        return false
    }
}

/// SIGINT and SIGTERM cancel the running jobs (a second SIGINT ends the process at once). `remove()` puts the previous handlers back.
@MainActor
final class CLISignals {
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(Int32, (@convention(c) (Int32) -> Void)?)] = []

    static func install() -> CLISignals {
        let s = CLISignals()
        for sig in [SIGINT, SIGTERM] {
            s.previous.append((sig, signal(sig, SIG_IGN)))
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { CLIRuntime.requestCancel(forceExitOnRepeat: true) } }
            src.resume()
            s.sources.append(src)
        }
        return s
    }

    func remove() {
        for src in sources { src.cancel() }
        sources = []
        for (sig, old) in previous { signal(sig, old) }
        previous = []
    }
}
