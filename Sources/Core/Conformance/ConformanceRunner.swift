import Foundation

// Runs one operation the way the job runner does and applies the generic checks every conversion owes.

@MainActor
enum ConformanceRunner {
    private static var runCounter = 0

    // MARK: Whole test

    /// Body of the generated `conformance.*` test of operation `id`: fixtures, run, generic checks, oracle.
    static func test(operationID id: String, registry: ConformanceRegistry = .shared) async throws {
        guard let op = OperationRegistry.shared.operation(id: id) else { throw TestFailure(message: "operation \(id) is not registered", file: #fileID, line: #line) }
        if let why = registry.exemption(for: op.meta) { try skipTest("exempt: \(why)") }
        guard let oracle = registry.oracle(for: op.meta) else {
            throw TestFailure(message: "no conformance oracle claims \(id): add one with ConformanceRegistry.shared.add, or exempt it with a reason", file: #fileID, line: #line)
        }
        if let reason = Capabilities.shared.missingReason(oracle.requires) { ConformanceMatrix.record(operationID: id, outcome: .skipped(reason.en)); try skipTest(reason.en) }
        let fx = ConformanceFixtures(label: "conf")
        // SC_KEEP_CONFORMANCE=1 keeps the fixtures and outputs of the run for inspection (printed on failure).
        let keepAll = ProcessInfo.processInfo.environment["SC_KEEP_CONFORMANCE"] == "1"
        var finished = false
        defer {
            if keepAll && !finished {
                // The isolated home is deleted when the run ends: copy the evidence somewhere that survives.
                let dest = AppPaths.defaultScratchBase.appendingPathComponent("conformance-kept-\(id)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
                try? FileManager.default.copyItem(at: fx.root, to: dest)
                out("      kept fixtures and outputs: \(dest.path)")
            }
            fx.cleanup()
        }
        let cases = try await oracle.cases(op.meta, fx)
        guard !cases.isEmpty else {
            let why = "the oracle made no fixtures for \(id) on this Mac"
            ConformanceMatrix.record(operationID: id, outcome: .skipped(why)); try skipTest(why)
        }
        for c in cases {
            do {
                let run = try await execute(op, c, fx: fx)
                try await genericChecks(run, oracle: oracle)
                do { try await oracle.verify(run) }
                catch let f as TestFailure where c.advisory != nil { run.note("ADVISORY, not a failure (\(c.advisory!)): \(f.message)") }
                out("      \(id) [\(c.label)] \(summary(run))" + (run.notes.isEmpty ? "" : ": " + run.notes.joined(separator: "; ")))
                ConformanceMatrix.record(.init(operationID: id, caseLabel: c.label, inputs: run.inputs.map { $0.pathExtension.lowercased() }, outputs: run.outputs.map { $0.pathExtension.lowercased() },
                                               notes: run.notes, outcome: .passed))
            } catch let f as TestFailure {
                ConformanceMatrix.record(.init(operationID: id, caseLabel: c.label, inputs: c.inputs.map { $0.pathExtension.lowercased() }, outputs: [], notes: [], outcome: .failed(f.message)))
                throw TestFailure(message: "[\(c.label)] \(f.message)", file: f.file, line: f.line)
            } catch let skip as TestSkip {
                ConformanceMatrix.record(.init(operationID: id, caseLabel: c.label, inputs: c.inputs.map { $0.pathExtension.lowercased() }, outputs: [], notes: [], outcome: .skipped(skip.reason)))
                throw skip
            }
        }
        finished = true
    }

    private static func summary(_ run: ConformanceRun) -> String {
        let outs = run.outputs.prefix(3).map { "\($0.lastPathComponent) \(Util.formatBytes(TestFile.size($0)))" }.joined(separator: ", ")
        return "-> \(outs)\(run.outputs.count > 3 ? " (+\(run.outputs.count - 3))" : "") in \(String(format: "%.1f", run.seconds)) s"
    }

    // MARK: Execution

    /// Copies the inputs into a fresh folder (outputs land next to them), resolves the options like the wheel does and executes the operation.
    static func execute(_ op: Operation, _ testCase: ConformanceCase, fx: ConformanceFixtures) async throws -> ConformanceRun {
        runCounter += 1
        let dir = try fx.folder("run-\(runCounter)")
        var copies: [URL] = []
        for src in testCase.inputs {
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            try FileManager.default.copyItem(at: src, to: dst)
            copies.append(dst)
        }
        let items = FileItem.items(copies)
        guard op.appliesInStudio(items) else {
            throw TestFailure(message: "\(op.id) does not accept its own fixture \(copies.map(\.lastPathComponent)) (the declared inputs are \(op.meta.inputs?.sorted().joined(separator: " ") ?? "any"))", file: #fileID, line: #line)
        }
        if case .unavailable(let reason, _) = op.availability(for: items, tools: .shared) { try skipTest(reason.en) }
        let settings = AppSettings.shared.data
        let source: SourceInfo? = testCase.mode == .studio ? await SourceProbeRegistry.shared.info(for: items[0]) : nil
        let resolved = QuickRecipes.resolve(op, items: items, source: source, settings: settings, extra: [testCase.extra], mode: testCase.mode)
        if resolved.hasErrors, let e = resolved.messages.first(where: { $0.severity == .error }) {
            throw TestFailure(message: "the quick recipe of \(op.id) does not validate: \(e.text.en)", file: #fileID, line: #line)
        }
        var rules = OutputRules(options: testCase.extra, base: settings.output)
        rules.after = .nothing
        let ctx = OperationContext(operationID: op.meta.id, mode: testCase.mode, resolved: resolved, outputRules: rules, settings: settings, tools: .shared,
                                   stagePlan: op.stagePlan(options: resolved.values))
        let log = Locked<[String]>([]), progress = Locked<[Double]>([])
        ctx.onLog = { line in log.withLock { $0.append(line) } }
        ctx.onProgress = { p, _, _ in if let p { progress.withLock { $0.append(p) } } }
        defer { ctx.cleanupTemp() }
        let t0 = Date()
        let result: OperationResult
        do { result = try await op.execute(items: items, ctx: ctx) }
        catch let skip as TestSkip { throw skip }
        catch is CancellationError { throw TestFailure(message: "\(op.id) was cancelled", file: #fileID, line: #line) }
        catch {
            if testCase.expectsFailure {
                return ConformanceRun(operation: op, testCase: testCase, inputs: copies, workDir: dir, result: OperationResult(), outputs: [], options: resolved.values,
                                      log: log.value, progress: progress.value, seconds: Date().timeIntervalSince(t0), fx: fx, error: ConversionError.describe(error), inactive: resolved.inactive)
            }
            let tail = log.value.suffix(6).joined(separator: " | ")
            throw TestFailure(message: "\(op.id) failed on a valid fixture: \(ConversionError.describe(error))" + (tail.isEmpty ? "" : " [log: \(tail)]"), file: #fileID, line: #line)
        }
        let seconds = Date().timeIntervalSince(t0)
        var files: [URL] = []
        for u in result.outputs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else {
                throw TestFailure(message: "\(op.id) reported the output \(u.lastPathComponent) but no such file exists", file: #fileID, line: #line)
            }
            if isDir.boolValue { files += regularFiles(under: u) } else { files.append(u) }
        }
        files = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        let sorted = files.sorted { Util.naturalCompare($0.path, $1.path) == .orderedAscending }
        return ConformanceRun(operation: op, testCase: testCase, inputs: copies, workDir: dir, result: result, outputs: sorted, options: resolved.values,
                              log: log.value, progress: progress.value, seconds: seconds, fx: fx, inactive: resolved.inactive)
    }

    /// Runs without any check (for sweeps that compare several runs, e.g. low versus high quality).
    static func execute(_ op: Operation, _ testCase: ConformanceCase, with extra: OptionValues, fx: ConformanceFixtures) async throws -> ConformanceRun {
        var c = testCase
        c.extra = testCase.extra.overlaying(extra)
        return try await execute(op, c, fx: fx)
    }

    /// The same run as Studio would make it: mode `.studio` with every resolved option of `run` passed explicitly. "Two speeds, one engine": the result must be
    /// the same as the quick run's.
    static func studioTwin(of run: ConformanceRun) async throws -> ConformanceRun {
        var c = run.testCase
        c.mode = .studio
        c.extra = run.options
        return try await execute(run.operation, c, fx: run.fx)
    }

    static func regularFiles(under dir: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return out }
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(u) }
        return out
    }

    // MARK: Generic checks

    static func genericChecks(_ run: ConformanceRun, oracle: ConformanceOracle) async throws {
        func on(_ c: GenericCheck) -> Bool { oracle.relaxed[c] == nil }
        func fail(_ m: String) -> TestFailure { TestFailure(message: m, file: #fileID, line: #line) }
        let meta = run.meta
        if run.testCase.expectsFailure {
            if run.error == nil { throw fail("\(meta.id) should have refused these inputs but produced \(run.outputs.map(\.lastPathComponent))") }
            try checkUntouched(run, enabled: on(.inputsUntouched))
            try checkNoPartials(run, enabled: on(.noPartials))
            return
        }
        if run.outputs.isEmpty {
            if run.testCase.expectsNoOutput { return }
            throw fail("\(meta.id) produced no files (returned \(run.returned.map(\.lastPathComponent)))")
        }
        if run.testCase.expectsNoOutput { throw fail("\(meta.id) should have produced nothing for these inputs but returned \(run.outputs.map(\.lastPathComponent))") }
        // Progress stays in 0...1.
        if let bad = run.progress.first(where: { !$0.isFinite || $0 < -0.0001 || $0 > 1.0001 }) { throw fail("progress left the range 0...1: \(bad)") }
        let inputHashes = Dictionary(run.inputs.compactMap { u in FileHash.sha256(u).map { ($0, u) } }, uniquingKeysWith: { first, _ in first })
        try checkUntouched(run, enabled: on(.inputsUntouched))
        try checkNoPartials(run, enabled: on(.noPartials))
        let target = meta.wheel == .convert ? meta.targetFormat : nil
        if on(.targetFormat), let target {
            let wrong = run.returned.filter { u in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                return !isDir.boolValue && Formats.key(of: u) != target
            }
            if !wrong.isEmpty { throw fail("a \(target.uppercased()) conversion returned \(wrong.map(\.lastPathComponent)) (extension is not \(target))") }
            if !run.outputs.contains(where: { Formats.key(of: $0) == target }) { throw fail("a \(target.uppercased()) conversion produced no .\(target) file: \(run.outputs.map(\.lastPathComponent))") }
        }
        for out in run.outputs {
            let name = out.lastPathComponent
            let size = TestFile.size(out)
            if on(.nonEmpty), size <= 0 { throw fail("\(name) is empty") }
            guard let sniffed = FormatSniffer.sniff(out) else { if size > 0 { throw fail("\(name) cannot be read") } else { continue } }
            let ext = Formats.key(of: out)
            if on(.sniffMatchesExtension), !ext.isEmpty, !FormatSniffer.agrees(extension: ext, with: sniffed) {
                throw fail("\(name) is called .\(ext) but its bytes are \(sniffed) (ext. renamed, not converted)")
            }
            if on(.targetFormat), let target, ext == target, !FormatSniffer.agrees(extension: target, with: sniffed) {
                throw fail("\(name): a \(target.uppercased()) conversion wrote \(sniffed)")
            }
            if on(.notIdentical), meta.passthrough == .none, let h = FileHash.sha256(out), let twin = inputHashes[h] {
                throw fail("\(name) is byte-identical to the input \(twin.lastPathComponent): a copy or a rename is not a conversion (declare passthrough if this is meant)")
            }
            if on(.decodes) {
                switch await ConformanceDecode.check(out, sniffed: sniffed) {
                case .ok: break
                case .failed(let why): throw fail("\(name) is not decodable by an independent reader: \(why)")
                case .unverified(let why): run.note("decode unverified (\(why))")
                }
            }
        }
        if on(.namedAfterInput), meta.wheel != .link {
            let bases = run.inputs.map { norm(Formats.baseName(of: $0, isDirectory: false)) }
            for out in run.returned {
                let n = norm(Formats.baseName(of: out, isDirectory: false))
                if !bases.contains(where: { n.hasPrefix($0) || $0.hasPrefix(n) }) {
                    throw fail("\(out.lastPathComponent) is not named after its input \(run.inputs.map(\.lastPathComponent)) (output naming rule)")
                }
            }
        }
    }

    /// `inputsUntouched` is judged against the hash of the ORIGINAL fixture (the copy the operation read was made before the run).
    private static func checkUntouched(_ run: ConformanceRun, enabled: Bool) throws {
        guard enabled else { return }
        for (i, copy) in run.inputs.enumerated() {
            guard FileManager.default.fileExists(atPath: copy.path) else { throw TestFailure(message: "the operation deleted or moved its input \(copy.lastPathComponent)", file: #fileID, line: #line) }
            let original = run.testCase.inputs[i]
            if (try? FileManager.default.attributesOfItem(atPath: original.path)[.type] as? FileAttributeType) == .typeDirectory { continue }
            if FileHash.sha256(copy) != FileHash.sha256(original) { throw TestFailure(message: "the operation modified its input \(copy.lastPathComponent)", file: #fileID, line: #line) }
        }
    }

    private static func checkNoPartials(_ run: ConformanceRun, enabled: Bool) throws {
        guard enabled else { return }
        var dirs = Set(run.outputs.map { $0.deletingLastPathComponent() }); dirs.insert(run.workDir)
        for d in dirs { let p = TestFile.partials(in: d); if !p.isEmpty { throw TestFailure(message: "in-flight files were left behind in \(d.lastPathComponent): \(p)", file: #fileID, line: #line) } }
    }

    private static func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
}
