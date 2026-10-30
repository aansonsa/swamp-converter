import Foundation

/// The read-only commands: probe, list-ops, options, presets, version, help. They never run a job and never write outside what `presets export / import` is asked to.
extension CLICommands {
    private static var env: CLIEnvironment { CLIRuntime.environment }

    private static func usage(_ message: String, _ out: CLIOutput) -> Int32 {
        out.error(code: .usage, message: message)
        return CLIExitCode.usage.rawValue
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    // MARK: list-ops

    static func listOps(_ inv: CLIInvocation, out: CLIOutput) async -> Int32 {
        var ops = env.registry.allOperations(settings: env.settings.data)
        if let kind = inv.options["kind"] { ops = ops.filter { $0.meta.family.rawValue == kind || $0.meta.wheel.rawValue == kind } }
        let rows = ops.map { (op: $0, availability: $0.availability(for: [], tools: env.tools)) }
        let shown = inv.flags.contains("available") ? rows.filter { $0.availability.isAvailable } : rows
        if out.json {
            out.print(json: ["count": shown.count, "operations": shown.map { CLIDescribe.operation($0.op, tools: env.tools) }])
            return CLIExitCode.ok.rawValue
        }
        let idWidth = min(40, shown.map { $0.op.meta.id.count }.max() ?? 10)
        let wheelWidth = shown.map { $0.op.meta.wheel.rawValue.count }.max() ?? 7
        for r in shown {
            var line = pad(r.op.meta.id, idWidth) + "  " + pad(r.op.meta.wheel.rawValue, wheelWidth) + "  " + r.op.meta.label.text
            if let sub = r.op.meta.subtitle?.text, !sub.isEmpty { line += " (" + sub + ")" }
            if let reason = r.availability.reason { line += "   [" + reason.text + "]" }
            out.line(line)
        }
        return CLIExitCode.ok.rawValue
    }

    // MARK: options

    static func options(_ inv: CLIInvocation, out: CLIOutput) async -> Int32 {
        let op: Operation
        switch CLIResolve.operation(inv.positional[0], items: nil, env: env) {
        case .failure(let e): return usage(e.message, out)
        case .success(let o): op = o
        }
        if out.json {
            out.print(json: CLIDescribe.schema(of: op, settings: env.settings.data))
            return CLIExitCode.ok.rawValue
        }
        let schema = op.studioSchema(for: [])
        let quick = QuickRecipes.current(for: op, settings: env.settings.data)
        out.line("\(op.meta.id)  -  \(schema.title.text)  (\(schema.id))")
        if schema.allFields.isEmpty { out.line(L("(no options)", "(параметров нет)")) }
        for page in schema.pages {
            out.line("")
            out.line("[\(page.title.text)]")
            for group in page.groups {
                if let t = group.title?.text { out.line("  \(t)") }
                for f in group.fields {
                    var line = "    " + f.key + "  " + CLIDescribe.kindName(f.kind)
                    let def = f.defaultValue.resolve(nil)
                    if case .text(let t) = f.kind, t.secure {
                        line += "  " + L("(secret)", "(секрет)")
                    } else {
                        line += "  = " + def.displayText
                        if let q = quick[f.key], q != def { line += " " + L("(quick: \(q.displayText))", "(быстро: \(q.displayText))") }
                    }
                    switch f.kind {
                    case .slider(let s): line += "  [\(CLIOptionTyping.fmt(s.min))...\(CLIOptionTyping.fmt(s.max))]"
                    case .stepper(let s): line += "  [\(s.min)...\(s.max)]"
                    case .number(let n):
                        if n.min != nil || n.max != nil { line += "  [\(n.min.map(CLIOptionTyping.fmt) ?? "")...\(n.max.map(CLIOptionTyping.fmt) ?? "")]" }
                    case .picker(let o), .segmented(let o): line += "  {" + o.map(\.value).joined(separator: "|") + "}"
                    default: break
                    }
                    line += "  - " + f.label.text
                    if !Capabilities.shared.hasAll(f.requires), let why = Capabilities.shared.missingReason(f.requires) { line += "  [" + why.text + "]" }
                    out.line(line)
                }
            }
        }
        return CLIExitCode.ok.rawValue
    }

    // MARK: probe

    static func probe(_ inv: CLIInvocation, out: CLIOutput) async -> Int32 {
        let path = CLIOptionTyping.absolutePath(inv.positional[0])
        guard FileManager.default.fileExists(atPath: path) else {
            return usage(L("No such file or folder: \(inv.positional[0])", "Нет такого файла или папки: \(inv.positional[0])"), out)
        }
        let item = FileItem(url: URL(fileURLWithPath: path))
        let info = await SourceProbeRegistry.shared.info(for: item)
        var doc = CLIDescribe.source(info)
        var plans: [(SmartMode, TranscodePlan)] = []
        if inv.flags.contains("plan") {
            guard item.kind == .video else {
                out.error(code: .unavailable, message: L("A smart-transcode plan exists only for video files.", "План умной перекодировки есть только для видеофайлов."))
                return CLIExitCode.unavailable.rawValue
            }
            do {
                let media = try await MediaProbe.probe(item.url)
                for mode in SmartMode.allCases {
                    var options = SmartOptions()
                    options.mode = mode
                    plans.append((mode, TranscodePlanner.plan(probe: media, mode: mode, capabilities: SmartCapabilities.current, options: options)))
                }
            } catch is CancellationError {
                out.error(code: .cancelled, message: L("Canceled.", "Отменено."))
                return CLIExitCode.cancelled.rawValue
            } catch {
                out.error(code: .unavailable, message: ConversionError.describe(error))
                return CLIExitCode.unavailable.rawValue
            }
            doc["plans"] = Dictionary(uniqueKeysWithValues: plans.map { ($0.0.rawValue, CLIDescribe.plan($0.1)) })
        }
        if out.json {
            out.print(json: doc)
            return CLIExitCode.ok.rawValue
        }
        let size = info.sizeBytes.map { Util.formatBytes($0) } ?? ""
        out.line("\(item.name)  (\(info.kind.title.text)\(size.isEmpty ? "" : ", " + size))")
        for key in info.facts.keys.sorted() { out.line("  \(key) = \(info.facts[key]?.displayText ?? "")") }
        if !info.chips.isEmpty { out.line(L("Summary: ", "Кратко: ") + info.chips.map(\.text).joined(separator: " | ")) }
        for s in info.streams { out.line("  \(s.kind.rawValue) #\(s.index): \(s.title)" + (s.detail.isEmpty ? "" : " (\(s.detail))")) }
        for w in info.warnings { out.line(L("Note: ", "Замечание: ") + w.text) }
        for (mode, plan) in plans {
            var video = "copy"
            switch plan.video {
            case .copy: video = "copy"
            case .hevc(let encoder, let ten): video = "HEVC (\(encoder)\(ten ? ", 10-bit" : ""))"
            case .h264(let encoder): video = "H.264 (\(encoder))"
            }
            out.line(L("Plan \(mode.rawValue): ", "План \(mode.rawValue): ") + "\(plan.container), \(video)" + (plan.isPureRemux ? ", " + L("lossless remux", "без потерь") : ""))
            for w in plan.warnings { out.line("  " + w.text) }
        }
        return CLIExitCode.ok.rawValue
    }

    // MARK: presets

    static func presets(_ inv: CLIInvocation, out: CLIOutput) async -> Int32 {
        let sub = inv.positional.first ?? "list"
        switch sub {
        case "list":
            var list = env.presets.all
            if let t = inv.options["target"] { list = list.filter { $0.targetID == t } }
            if out.json {
                out.print(json: ["count": list.count, "presets": list.map(CLIDescribe.preset)])
            } else {
                let idWidth = min(36, list.map { $0.id.count }.max() ?? 10)
                let tw = list.map { $0.targetID.count }.max() ?? 10
                for p in list { out.line(pad(p.id, idWidth) + "  " + pad(p.targetID, tw) + "  " + p.name.text) }
            }
            return CLIExitCode.ok.rawValue

        case "show":
            switch CLIResolve.preset(inv.positional[1], env: env) {
            case .failure(let e): return usage(e.message, out)
            case .success(let p):
                if out.json { out.print(json: CLIDescribe.preset(p)); return CLIExitCode.ok.rawValue }
                out.line("\(p.id)  -  \(p.name.text)  (\(p.targetID))")
                if let n = p.notes?.text { out.line(n) }
                for key in p.values.keys { out.line("  \(key) = \(p.values[key]?.displayText ?? "")") }
                return CLIExitCode.ok.rawValue
            }

        case "export":
            let preset: Preset
            switch CLIResolve.preset(inv.positional[1], env: env) {
            case .failure(let e): return usage(e.message, out)
            case .success(let p): preset = p
            }
            let path = CLIOptionTyping.absolutePath(inv.positional[2])
            if FileManager.default.fileExists(atPath: path) && !inv.flags.contains("force") {
                return usage(L("\(inv.positional[2]) already exists. Choose another name or add --force.", "\(inv.positional[2]) уже существует. Выберите другое имя или добавьте --force."), out)
            }
            do {
                try env.presets.export(ids: [preset.id], to: URL(fileURLWithPath: path))
            } catch {
                out.error(code: .failed, message: ConversionError.describe(error))
                return CLIExitCode.failed.rawValue
            }
            if out.json { out.print(json: ["exported": [preset.id], "file": path]) } else { out.line(path) }
            return CLIExitCode.ok.rawValue

        default:   // import
            let path = CLIOptionTyping.absolutePath(inv.positional[1])
            guard FileManager.default.fileExists(atPath: path) else {
                return usage(L("No such file: \(inv.positional[1])", "Нет такого файла: \(inv.positional[1])"), out)
            }
            do {
                let imported = try env.presets.importFile(URL(fileURLWithPath: path))
                if out.json { out.print(json: ["imported": imported.map(\.id), "presets": imported.map(CLIDescribe.preset)]) }
                else { for p in imported { out.line("\(p.id)  \(p.name.text)") } }
                return CLIExitCode.ok.rawValue
            } catch {
                out.error(code: .failed, message: ConversionError.describe(error))
                return CLIExitCode.failed.rawValue
            }
        }
    }

    // MARK: version

    static func version(out: CLIOutput) -> Int32 {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        if out.json {
            var tools: [String: Any] = [:]
            for t in Tool.allCases where !t.isBuiltIn { tools[t.rawValue] = env.tools.find(t)?.path as Any }
            out.print(json: ["name": "swamp", "version": version, "build": build, "os": ProcessInfo.processInfo.operatingSystemVersionString, "tools": tools])
        } else {
            out.line("swamp \(version) (\(build))")
            if out.verbose {
                for t in Tool.allCases where !t.isBuiltIn { out.line("  \(t.rawValue): " + (env.tools.find(t)?.path ?? L("not found", "не найден"))) }
            }
        }
        return CLIExitCode.ok.rawValue
    }

    // MARK: help

    static func help(out: CLIOutput) -> Int32 { help(topic: nil, out: out) }

    static func help(topic: String?, out: CLIOutput) -> Int32 {
        if let topic, CLICommand(rawValue: topic) == nil {
            return usage(L("No help for '\(topic)'. Commands: \(CLICommand.allCases.map(\.rawValue).joined(separator: ", "))",
                           "Нет справки по '\(topic)'. Команды: \(CLICommand.allCases.map(\.rawValue).joined(separator: ", "))"), out)
        }
        let text = CLIHelp.text(topic: topic.flatMap(CLICommand.init(rawValue:)))
        if out.json { out.print(json: ["usage": text]) } else { out.line(text) }
        return CLIExitCode.ok.rawValue
    }
}
