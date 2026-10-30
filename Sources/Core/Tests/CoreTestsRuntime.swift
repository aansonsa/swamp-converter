import Foundation

// Core self-tests, part 3: the queue across a relaunch, history, "Repeat last" and quick prompts, dynamic operation providers.
// Everything runs against private JobRunners, OperationRegistries and state folders in a temp folder; the shared singletons are only touched
// where a test says so and are restored afterwards.

// MARK: - Extra test operations

/// EchoOp with one secret field: the queue file must never contain it.
final class SecretEchoOp: PerFileOperation, @unchecked Sendable {
    init(id: String = "test.secret") {
        super.init(meta: .make(id, .tools, .app, L10n(id), symbol: "lock", schema: "test.secret", suffix: L10n("secret"), anyFile: true))
    }
    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: "test.secret", title: L10n("Secret"), pages: [
            .make("main", symbol: "lock", L10n("Main"), [.make("g", [
                .text("text", L10n("Text"), def: "hello"),
                .text("token", L10n("Token"), def: "", secure: true)
            ])])
        ])
    }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let text = ctx.options.string("text")
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { try text.write(to: $0, atomically: false, encoding: .utf8) }
        progress.report(1)
        return [url]
    }
}

/// Like EchoOp, but the QUICK path asks for `quickPromptKeys` first, and only PDFs are accepted when `pdfOnly`.
final class PromptEchoOp: PerFileOperation, @unchecked Sendable {
    init(id: String = "test.prompt", prompts: [String] = ["text"], pdfOnly: Bool = false, requires: [Tool] = []) {
        super.init(meta: .make(id, .tools, .app, L10n(id), symbol: "questionmark", schema: "test.echo", inputs: pdfOnly ? ["pdf"] : nil, requires: requires,
                               suffix: L10n("asked"), anyFile: !pdfOnly, prompts: prompts))
    }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { EchoOp().optionSchema(for: items) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let text = ctx.options.string("text")
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { try text.write(to: $0, atomically: false, encoding: .utf8) }
        progress.report(1)
        return [url]
    }
}

enum CoreTestsRuntime {
    private static let page = URL(string: "https://example.com/watch?v=abc123")!

    static func register() {
        let t = SelfTestRegistry.shared

        // MARK: Queue persistence

        t.register("core.jobs", "the unfinished queue survives a relaunch: every job comes back held, overrides and link titles intact, secrets never reach the file") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let state = try fx.makeDirectory("state")
            let reg = OperationRegistry()
            reg.register([SecretEchoOp(), StagedLinkOp(), SlowOp()])
            let s = AppSettings(fileURL: fx.url("settings.json"), autosave: false)
            let first = JobRunner(persistence: true, registry: reg, settings: s, stateDirectory: state)
            first.maxConcurrentOverride = 1
            let f1 = FileItem(url: try fx.text("one.txt", "1")), f2 = FileItem(url: try fx.text("two.txt", "2"))
            let batch = UUID()
            let secret = try unwrap(reg.operation(id: "test.secret"))
            let held1 = first.enqueue(operation: secret, items: [f1], overrides: ["text": "ab", "token": "s3cret-value"], batchID: batch)
            let held2 = first.enqueue(operation: secret, items: [f2], batchID: batch)
            let link = first.enqueue(operation: try unwrap(reg.operation(id: "test.staged")), links: [LinkItem(url: page, title: "A title")], overrides: ["x": 1])
            let slow = first.submit(operation: try unwrap(reg.operation(id: "test.slow")), items: [f1], origin: .studio, mode: .studio)
            try await expectEventually { slow.state == .running }
            first.flushPersistence()
            let raw = try String(contentsOf: state.appendingPathComponent("queue.json"), encoding: .utf8)
            try expect(!raw.contains("s3cret-value"), "secure fields are never written to queue.json")
            try expect(raw.contains("A title"), "link titles are kept")

            // "Relaunch": a second runner over the same state folder. The first one is left alone, as after a crash.
            let second = JobRunner(persistence: true, registry: reg, settings: s, stateDirectory: state)
            try expectEqual(second.jobs.map(\.id), [held1.id, held2.id, link.id, slow.id], "order and ids are preserved (a running job is restored too)")
            try expect(second.jobs.allSatisfy { $0.state == .waiting && $0.held }, "restored jobs wait for Start Queue; nothing runs by itself")
            let r1 = try unwrap(second.job(id: held1.id))
            try expectEqual(r1.overrides.string("text"), "ab"); try expect(!r1.overrides.has("token"), "the secret is gone")
            try expectEqual(r1.batchID, batch); try expectEqual(r1.items.map(\.name), ["one.txt"])
            let rl = try unwrap(second.job(id: link.id))
            try expect(rl.isLinkJob && rl.items.isEmpty, "a link job stays a link job")
            try expectEqual(rl.links.map(\.url), [page]); try expectEqual(rl.links.first?.title, "A title")
            try expectEqual(rl.overrides.int("x"), 1); try expectEqual(rl.origin, .studio); try expectEqual(rl.mode, .studio)

            // A third relaunch after one input vanished (an unplugged drive): that job is dropped with one calm notice, the others stay.
            try FileManager.default.removeItem(at: f2.url)
            let before = MessageCenter.shared.recent.count
            let third = JobRunner(persistence: true, registry: reg, settings: s, stateDirectory: state)
            try expectEqual(third.jobs.map(\.id), [held1.id, link.id, slow.id])
            try expect(MessageCenter.shared.recent.count == before + 1 && MessageCenter.shared.recent.last?.text.contains("1") == true, "one notice about the dropped job")

            // Start Queue on the relaunched runner runs what came back (the restored slow job is cancelled first so the test stays short).
            second.cancel(try unwrap(second.job(id: slow.id)))
            second.startQueue()
            try await expectEventually(timeout: 15) { second.jobs.allSatisfy { $0.state.isFinished } }
            try expectEqual(second.job(id: held1.id)?.state, .done); try expectEqual(second.job(id: link.id)?.state, .done)
            try expectEqual(try String(contentsOf: try unwrap(second.job(id: held1.id)?.outputs.first), encoding: .utf8), "ab")
            second.flushPersistence()
            try expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("queue.json").path), "nothing unfinished: the queue file is gone")
            first.cancelAll()
            try await expectEventually { first.jobs.allSatisfy { $0.state.isFinished } }
        }

        t.register("core.jobs", "history is capped at 200 records, newest first, and reloads from history.json") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let state = try fx.makeDirectory("state")
            let reg = OperationRegistry(); reg.register([EchoOp()])
            let s = AppSettings(fileURL: fx.url("settings.json"), autosave: false)
            let runner = JobRunner(persistence: true, registry: reg, settings: s, stateDirectory: state)
            runner.maxConcurrentOverride = 6
            let src = FileItem(url: try fx.text("a.txt", "x"))
            let op = try unwrap(reg.operation(id: "test.echo"))
            for _ in 0..<(JobRunner.historyKept + 8) { runner.submit(operation: op, items: [src], mode: .automatic) }
            await runner.waitUntilIdle(timeout: 90)
            try expectEqual(runner.history.count, JobRunner.historyKept, "history never grows past the cap")
            try expect(runner.jobs.count <= JobRunner.finishedJobsKept, "finished jobs in memory are capped too")
            let stamps = runner.history.compactMap(\.finishedAt)
            try expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 >= $1 }, "newest first")
            runner.flushPersistence()
            let again = JobRunner(persistence: true, registry: reg, settings: s, stateDirectory: state)
            try expectEqual(again.history.map(\.id), runner.history.map(\.id), "history.json round-trips")
            try expect(again.jobs.isEmpty, "nothing unfinished to restore")
            again.clearHistory()
            try expect(again.history.isEmpty && !FileManager.default.fileExists(atPath: state.appendingPathComponent("history.json").path))
        }

        // MARK: QuickRun

        t.register("core.quickrun", "Repeat last re-runs the remembered recipe without a dialog; automatic runs never overwrite it; a gone or unfit operation is not offered") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, s) = makeTestRunner(fx: fx, ops: [EchoOp(), PromptEchoOp(id: "test.pdfonly", prompts: [], pdfOnly: true)])
            let q = QuickRun.shared
            let saved = (q.registry, q.runnerProvider, q.settings, q.parameterPrompt)
            defer { q.registry = saved.0; q.runnerProvider = saved.1; q.settings = saved.2; q.parameterPrompt = saved.3 }
            q.registry = reg; q.runnerProvider = { runner }; q.settings = s; q.parameterPrompt = nil
            let src = FileItem(url: try fx.text("a.txt", "x"))
            let pdf = FileItem(url: URL(fileURLWithPath: "/tmp/not-there.pdf"), isDirectory: false)

            try expect(q.lastOperation(for: [src]) == nil, "nothing to repeat on a fresh install")
            guard case .notApplicable = await q.repeatLast(items: [src], origin: .hotkey) else { throw TestFailure(message: "repeat without history must be notApplicable", file: #fileID, line: #line) }

            let echo = try unwrap(reg.operation(id: "test.echo"))
            guard case .started(let job) = await q.run(echo, items: [src], origin: .wheel, overrides: ["text": "again", "repeat": 2]) else { throw TestFailure(message: "first run must start", file: #fileID, line: #line) }
            try await expectEventually { job.state.isFinished }
            try expectEqual(s.data.lastRecipe?.operationID, "test.echo"); try expectEqual(s.data.lastRecipe?.values.string("text"), "again")
            try expectEqual(q.lastOperation(for: [src])?.meta.id, "test.echo")

            guard case .started(let again) = await q.repeatLast(items: [src], origin: .hotkey) else { throw TestFailure(message: "repeat must start a job", file: #fileID, line: #line) }
            try await expectEventually { again.state.isFinished }
            try expectEqual(again.origin, .hotkey); try expectEqual(try String(contentsOf: try unwrap(again.outputs.first), encoding: .utf8), "againagain")

            guard case .started(let auto) = await q.run(echo, items: [src], origin: .watch, mode: .automatic, overrides: ["text": "auto"]) else { throw TestFailure(message: "automatic run must start", file: #fileID, line: #line) }
            try await expectEventually { auto.state.isFinished }
            try expectEqual(s.data.lastRecipe?.values.string("text"), "again", "watched-folder jobs never replace the remembered recipe")

            s.update { $0.lastRecipe = Recipe(operationID: "test.pdfonly", values: [:]) }
            try expect(q.lastOperation(for: [src]) == nil, "a PDF-only recipe is not offered for a text file")
            try expectEqual(q.lastOperation(for: [pdf])?.meta.id, "test.pdfonly")
            s.update { $0.lastRecipe = Recipe(operationID: "test.deleted", values: [:]) }
            try expect(q.lastOperation(for: [src]) == nil, "a recipe whose operation no longer exists is not offered")
            guard case .notApplicable = await q.repeatLast(items: [src], origin: .hotkey) else { throw TestFailure(message: "deleted operation must be notApplicable", file: #fileID, line: #line) }
        }

        t.register("core.quickrun", "quick prompts ask only for the keys the recipe does not fix; cancelling starts nothing; unattended runs never ask") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, s) = makeTestRunner(fx: fx, ops: [PromptEchoOp()])
            let q = QuickRun.shared
            let saved = (q.registry, q.runnerProvider, q.settings, q.parameterPrompt)
            defer { q.registry = saved.0; q.runnerProvider = saved.1; q.settings = saved.2; q.parameterPrompt = saved.3 }
            q.registry = reg; q.runnerProvider = { runner }; q.settings = s
            let src = FileItem(url: try fx.text("p.txt", "x"))
            let op = try unwrap(reg.operation(id: "test.prompt"))
            let asked = Locked<[[String]]>([])
            q.parameterPrompt = { _, _, fields, current in
                asked.withLock { $0.append(fields.map(\.key)) }
                precondition(current.string("text") == "hello", "the sheet starts from the quick recipe")
                return ["text": "typed"]
            }
            guard case .started(let a) = await q.run(op, items: [src], origin: .wheel) else { throw TestFailure(message: "must start after the prompt", file: #fileID, line: #line) }
            try await expectEventually { a.state.isFinished }
            try expectEqual(asked.value, [["text"]]); try expectEqual(try String(contentsOf: try unwrap(a.outputs.first), encoding: .utf8), "typed")

            guard case .started(let b) = await q.run(op, items: [src], origin: .wheel, overrides: ["text": "given"]) else { throw TestFailure(message: "must start without asking", file: #fileID, line: #line) }
            try await expectEventually { b.state.isFinished }
            try expectEqual(asked.value.count, 1, "a key that arrives with the request is not asked again")
            try expectEqual(try String(contentsOf: try unwrap(b.outputs.first), encoding: .utf8), "given")

            guard case .started(let c) = await q.run(op, items: [src], origin: .watch, mode: .automatic) else { throw TestFailure(message: "automatic must start", file: #fileID, line: #line) }
            try await expectEventually { c.state.isFinished }
            try expectEqual(asked.value.count, 1, "unattended runs never open a dialog"); try expectEqual(try String(contentsOf: try unwrap(c.outputs.first), encoding: .utf8), "hello")

            q.parameterPrompt = { _, _, _, _ in nil }
            let jobsBefore = runner.jobs.count
            guard case .cancelled = await q.run(op, items: [src], origin: .wheel) else { throw TestFailure(message: "cancelling the sheet must cancel the run", file: #fileID, line: #line) }
            try expectEqual(runner.jobs.count, jobsBefore, "no job is created when the person cancels")
        }

        t.register("core.quickrun", "an operation whose tool is missing is refused with a calm message and no job; a missing tool never crashes") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, s) = makeTestRunner(fx: fx, ops: [PromptEchoOp(id: "test.needs", prompts: [], requires: [.sox, .lame])])
            let q = QuickRun.shared
            let saved = (q.registry, q.runnerProvider, q.settings, q.tools)
            defer { q.registry = saved.0; q.runnerProvider = saved.1; q.settings = saved.2; q.tools = saved.3 }
            q.registry = reg; q.runnerProvider = { runner }; q.settings = s
            q.tools = ToolLocator(roots: .empty)
            let src = FileItem(url: try fx.text("n.txt", "x"))
            let op = try unwrap(reg.operation(id: "test.needs"))
            try expect(!op.availability(for: [src], tools: q.tools).isAvailable)
            let before = MessageCenter.shared.recent.count
            guard case .unavailable(let reason) = await q.run(op, items: [src], origin: .wheel) else { throw TestFailure(message: "must be unavailable", file: #fileID, line: #line) }
            try expect(reason.en.contains("Needs") && reason.ru.contains("Нужен"), "the reason is localised and names the tool")
            try expect(runner.jobs.isEmpty, "no job for an unavailable operation")
            try expectEqual(MessageCenter.shared.recent.count, before + 1); try expectEqual(MessageCenter.shared.recent.last?.severity, .warning)
            let quiet = MessageCenter.shared.recent.count
            _ = await q.run(op, items: [src], origin: .watch, mode: .automatic)
            try expectEqual(MessageCenter.shared.recent.count, quiet, "unattended runs stay silent")
        }

        // MARK: Concurrent output names

        t.register("core.paths", "jobs running in parallel that want the same output name never collide: every one succeeds with its own numbered file") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [EchoOp()])
            runner.maxConcurrentOverride = 8
            let src = FileItem(url: try fx.text("same.txt", "x"))
            let op = try unwrap(reg.operation(id: "test.echo"))
            var jobs: [Job] = []
            for round in 0..<6 {
                jobs += (0..<16).map { _ in runner.submit(operation: op, items: [src], overrides: ["text": .string("r\(round)")], mode: .studio) }
                await runner.waitUntilIdle(timeout: 60)
            }
            let failed = jobs.filter { $0.state != .done }
            try expect(failed.isEmpty, "\(failed.count) of \(jobs.count) jobs failed: \(failed.first?.errorMessage ?? "")")
            let names = jobs.compactMap { $0.outputs.first?.lastPathComponent }
            try expectEqual(Set(names).count, jobs.count, "every job got a distinct file name")
            try expectEqual(TestFile.partials(in: fx.root), [])
        }

        // MARK: Registry providers and preset operations

        t.register("core.registry", "providers are asked on every query, receive the settings, sort after static operations; preset operations never become Studio targets") {
            let reg = OperationRegistry()
            reg.register([EchoOp(id: "t.static")])
            let presets = Locked<[String]>(["p1"])
            reg.registerProvider(id: "presets") { settings in
                (presets.value + (0..<settings.quickRecipes.count).map { "q\($0)" }).map { EchoOp(id: "preset.\($0)") }
            }
            let txt = FileItem(url: URL(fileURLWithPath: "/tmp/a.txt"), isDirectory: false)
            try expectEqual(reg.entries(wheel: .tools, items: [txt]).map(\.id), ["t.static", "preset.p1"])
            let targets = reg.studioTargets(for: [txt])
            try expectEqual(targets.map(\.id), ["test.echo"])
            try expectEqual(targets.first?.operations.map(\.meta.id), ["t.static"], "preset.* operations run presets; they are not Studio targets of their own")
            try expectEqual(reg.primaryOperation(forTarget: "test.echo")?.meta.id, "t.static", "a static operation is the primary one")

            presets.value = ["p1", "p2"]   // the person saved another preset: no re-registration needed
            try expectEqual(reg.entries(wheel: .tools, items: [txt]).map(\.id), ["t.static", "preset.p1", "preset.p2"])
            try expect(reg.operation(id: "preset.p2") != nil)
            var custom = SettingsData(); custom.quickRecipes = ["a": ["x": 1], "b": ["x": 2]]
            try expectEqual(reg.entries(wheel: .tools, items: [txt], settings: custom).map(\.id), ["t.static", "preset.p1", "preset.p2", "preset.q0", "preset.q1"])
            presets.value = []
            try expect(reg.operation(id: "preset.p1") == nil, "a deleted preset disappears at once")

            reg.registerProvider(id: "presets") { _ in [EchoOp(id: "preset.only")] }
            try expectEqual(reg.allOperations().map(\.meta.id), ["t.static", "preset.only"], "registering a provider id again replaces it")
            reg.unregister(id: "t.static")
            try expectEqual(reg.allOperations().map(\.meta.id), ["preset.only"])
            reg.removeAll()
            try expect(reg.allOperations().isEmpty && reg.operation(id: "preset.only") == nil, "removeAll drops providers too")
        }

        t.register("core.registry", "registering an id twice replaces the operation in place and keeps the catalogue order") {
            let reg = OperationRegistry()
            let a = EchoOp(id: "t.a"), b = EchoOp(id: "t.b"), c = EchoOp(id: "t.c"), a2 = EchoOp(id: "t.a")
            reg.register([a, b, c])
            reg.register(a2)
            try expectEqual(reg.allOperations().map(\.meta.id), ["t.a", "t.b", "t.c"])
            try expect(reg.operation(id: "t.a") === a2, "the new instance wins")
            let png = FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)
            try expectEqual(reg.entries(wheel: .tools, items: [png]).map(\.id), ["t.a", "t.b", "t.c"])
        }
    }
}
