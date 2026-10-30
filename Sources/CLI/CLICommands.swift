import Foundation

/// One function per command; each returns an exit code. All are `@MainActor async` and cancellable. They only use Core + the registries + `DownloadService`.
/// `convert` and `download` live here; the read-only commands (probe, list-ops, presets, options, version, help) are in `CLICommands+Info.swift`.
@MainActor
enum CLICommands {
    private static var env: CLIEnvironment { CLIRuntime.environment }

    // MARK: convert

    /// Resolve the operation (`--op <id>`; or by target schema id; `--preset <name|id>` picks a preset's values and operation), build `OptionValues` from `--set` against
    /// `op.optionSchema(for: items)`, run `JobRunner.submit(operation:items:overrides:origin:.cli,mode:.quick|.studio)`, stream progress, wait, report outputs.
    /// Quick semantics: with no `--set` / `--preset` the result equals the wheel's. Exit 4 when `OperationResult.failures` is non-empty but outputs exist.
    static func convert(_ inv: CLIInvocation, out: CLIOutput) async -> Int32 {
        func usage(_ e: CLIUsageError) -> Int32 { out.error(code: .usage, message: e.message); return CLIExitCode.usage.rawValue }
        func unavailable(_ message: String) -> Int32 { out.error(code: .unavailable, message: message); return CLIExitCode.unavailable.rawValue }

        let items: [FileItem]
        switch CLIResolve.fileItems(inv.positional) {
        case .failure(let e): return usage(e)
        case .success(let i): items = i
        }

        var preset: Preset?
        if let key = inv.options["preset"] {
            switch CLIResolve.preset(key, env: env) {
            case .failure(let e): return usage(e)
            case .success(let p): preset = p
            }
        }

        let op: Operation
        if let key = inv.options["op"] {
            switch CLIResolve.operation(key, items: items, env: env) {
            case .failure(let e): return usage(e)
            case .success(let o): op = o
            }
            if let p = preset, op.meta.schemaID != p.targetID {
                return usage(CLIUsageError(message: L("The preset '\(p.name.text)' is for '\(p.targetID)', not for '\(op.meta.id)' ('\(op.meta.schemaID)').",
                                                      "Шаблон '\(p.name.text)' относится к '\(p.targetID)', а не к '\(op.meta.id)' ('\(op.meta.schemaID)').")))
            }
        } else if let p = preset {
            guard let o = p.operationID.flatMap({ env.registry.operation(id: $0) }) ?? env.registry.primaryOperation(forTarget: p.targetID) else {
                return usage(CLIUsageError(message: L("The preset '\(p.name.text)' needs '\(p.targetID)', which this build does not have.", "Шаблону '\(p.name.text)' нужна цель '\(p.targetID)', которой нет в этой сборке.")))
            }
            op = o
        } else {
            return usage(CLIUsageError(message: L("convert needs --op or --preset.", "convert требует --op или --preset.")))
        }

        if op.meta.acceptsLinks {
            return usage(CLIUsageError(message: L("'\(op.meta.id)' downloads links. Use: swamp download <link>", "'\(op.meta.id)' скачивает ссылки. Используйте: swamp download <ссылка>")))
        }
        if op.meta.isAppAction {
            return unavailable(L("'\(op.meta.id)' is an action that runs inside the app, not in the command line.", "'\(op.meta.id)' — действие, которое выполняется в приложении, а не в командной строке."))
        }
        guard op.appliesTo(items) || op.appliesInStudio(items) else {
            let kinds = items.kinds.map { $0.title.text }.sorted().joined(separator: ", ")
            return unavailable(L("'\(op.meta.id)' can’t process these files (\(kinds)).", "'\(op.meta.id)' не обрабатывает такие файлы (\(kinds))."))
        }
        if case .unavailable(let reason, _) = op.availability(for: items, tools: env.tools) { return unavailable(reason.text) }

        let schema = op.studioSchema(for: items)
        let typed: OptionValues
        switch CLIArguments.optionValues(from: inv.sets, schema: schema) {
        case .failure(let e): return usage(e)
        case .success(let v): typed = v
        }
        let overrides = (preset?.values ?? OptionValues()).overlaying(typed)
        let mode: RunMode = (preset != nil || !inv.sets.isEmpty) ? .studio : .quick

        var rules: OutputRules?
        if let raw = inv.options["out"] {
            switch CLIResolve.outputFolder(raw) {
            case .failure(let e): return usage(e)
            case .success(let path):
                var r = env.settings.data.output
                r.dirMode = .custom
                r.customDir = path
                rules = r
            }
        }

        // Check the options the way the job will, so a bad value is a usage error (2) now and not a failed job (1) later.
        let resolved = QuickRecipes.resolve(op, items: items, settings: env.settings.data, extra: [overrides], mode: mode)
        if resolved.hasErrors {
            let text = resolved.messages.filter { $0.severity == .error }.map { ($0.fieldKey.map { "'\($0)': " } ?? "") + $0.text.text }.joined(separator: "\n")
            return usage(CLIUsageError(message: text))
        }
        var warnings = resolved.messages.filter { $0.severity == .warning }.map { $0.text.text }
        warnings += setWarnings(typed: typed, resolved: resolved, schema: schema)
        for w in warnings { out.warning(w) }

        let runner = CLIRuntime.runner()
        let job = runner.submit(operation: op, items: items, overrides: overrides, origin: .cli, mode: mode, outputRules: rules)
        let outcome = await CLIJobWatcher.wait(for: job, runner: runner, out: out)
        return report(outcome, job: job, warnings: warnings, out: out)
    }

    /// Options given with --set that the job will not use: the field is switched off by another option or a missing tool, or the value was adjusted.
    private static func setWarnings(typed: OptionValues, resolved: ResolvedOptions, schema: OptionSchema) -> [String] {
        var out: [String] = []
        for key in typed.keys {
            guard let field = schema.field(key), let final = resolved.values[key], let wanted = typed[key] else { continue }   // out.* keys are not options of the job
            if resolved.inactive.contains(key) {
                let why = Capabilities.shared.missingReason(field.requires)?.text
                    ?? field.disabledReason?.text
                    ?? L("another option switches it off", "его отключает другая настройка")
                out.append(L("'\(key)' has no effect here: \(why).", "'\(key)' здесь не действует: \(why)."))
                continue
            }
            if case .tracks = field.kind { continue }
            if !OptionValues([key: final]).diff(against: OptionValues([key: wanted])).isEmpty {
                out.append(L("'\(key)' was set to \(wanted.displayText) but \(final.displayText) is used.", "'\(key)': задано \(wanted.displayText), но используется \(final.displayText)."))
            }
        }
        return out
    }

    /// The shared ending of convert and download: the event or text for the outcome and the exit code.
    private static func report(_ outcome: CLIJobOutcome, job: Job, warnings: [String], out: CLIOutput) -> Int32 {
        let code = outcome.exitCode
        let id = job.id.uuidString.lowercased()
        switch code {
        case .ok, .partial:
            var note = outcome.note
            if outcome.outputs.isEmpty && note == nil {
                note = L("Nothing to do: every file is already in the target format.", "Делать нечего: все файлы уже в нужном формате.")
            }
            out.done(job: id, outputs: outcome.outputs, failures: outcome.failures, warnings: warnings, note: note, code: code, elapsed: outcome.elapsed)
        case .cancelled:
            out.error(code: .cancelled, message: L("Canceled.", "Отменено."))
        default:
            let message = outcome.error ?? outcome.failures.joined(separator: "\n")
            out.error(code: code, message: message.isEmpty ? L("The job failed.", "Задача не выполнена.") : message)
        }
        return code.rawValue
    }

    // MARK: download

    /// `DownloadService.shared.start(...)` + the same progress stream. Needs consent in settings (or `--consent`); exit 3 when yt-dlp is missing.
    static func download(_ inv: CLIInvocation, out: CLIOutput) async -> Int32 {
        func usage(_ message: String) -> Int32 { out.error(code: .usage, message: message); return CLIExitCode.usage.rawValue }

        let link: URL
        switch LinkParsing.validate(inv.positional[0]) {
        case .failure(let reason): return usage(reason.message.text)
        case .success(let u): link = u
        }
        let mode = DownloadMode(parameter: inv.options["mode"]) ?? env.settings.data.downloader.defaultMode

        // `--consent` is the consent of this one run; it is never written to the settings.
        let savedProvider = NetworkGate.settingsProvider
        if inv.flags.contains("consent") {
            NetworkGate.settingsProvider = { var d = savedProvider(); d.downloader.consentGiven = true; return d }
        }
        defer { NetworkGate.settingsProvider = savedProvider }

        let service = DownloadService.shared
        let savedRunner = service.runnerOverride
        if savedRunner == nil { service.runnerOverride = CLIRuntime.runner() }
        defer { service.runnerOverride = savedRunner }

        let outcome: DownloadService.StartOutcome
        if inv.options["out"] != nil || !inv.sets.isEmpty {
            var request: DownloadRequest
            switch CLIDownloadRequest.build(url: link, mode: mode, sets: inv.sets, settings: env.settings.data) {
            case .failure(let e): return usage(e.message)
            case .success(let r): request = r
            }
            if let raw = inv.options["out"] {
                switch CLIResolve.outputFolder(raw) {
                case .failure(let e): return usage(e.message)
                case .success(let path): request.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            outcome = await service.start(request: request, origin: .cli)
        } else {
            outcome = await service.start(url: link, mode: mode, origin: .cli)
        }

        switch outcome {
        case .started(let job):
            let outcome = await CLIJobWatcher.wait(for: job, runner: service.jobRunner, out: out)
            return report(outcome, job: job, warnings: [], out: out)
        case .needsConsent:
            out.error(code: .unavailable, message: L("Downloading uses the network and a third-party tool (yt-dlp). Agree once in the app (Settings > Downloader), or pass --consent to agree for this run.",
                                                      "Загрузка использует сеть и стороннюю программу (yt-dlp). Согласитесь один раз в приложении (Настройки > Загрузка) или добавьте --consent, чтобы согласиться на этот запуск."))
            return CLIExitCode.unavailable.rawValue
        case .needsInstall:
            out.error(code: .unavailable, message: L("yt-dlp is not installed. ", "yt-dlp не установлен. ") + Tool.ytdlp.installHint.text)
            return CLIExitCode.unavailable.rawValue
        case .rejected(let reason):
            return usage(reason.message.text)
        case .failed(let message):
            out.error(code: .failed, message: message)
            return CLIExitCode.failed.rawValue
        }
    }
}
