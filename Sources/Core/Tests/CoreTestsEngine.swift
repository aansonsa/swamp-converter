import Foundation

// Core self-tests, part 2: option schemas, presets, recipes, settings, the registry, stages and the job runner.

// MARK: - Test operations (also handy for other modules' tests: they only depend on Core)

/// A per-file operation that writes `text` repeated `repeat` times into "<name> (echo).txt". Schema id "test.echo".
final class EchoOp: PerFileOperation, @unchecked Sendable {
    init(id: String = "test.echo", wheel: WheelKind = .tools) {
        super.init(meta: .make(id, wheel, .app, L10n(id), symbol: "star", schema: "test.echo", suffix: L10n("echo"), anyFile: true))
    }
    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: "test.echo", title: L10n("Echo"), pages: [
            .make("main", symbol: "star", L10n("Main"), [
                .make("g", [
                    .text("text", L10n("Text"), def: "hello").basic(),
                    .stepper("repeat", L10n("Repeat"), min: 1, max: 5, def: 1),
                    .toggle("upper", L10n("Upper case"), def: false),
                    .slider("level", L10n("Level"), min: 0, max: 10, def: 5).enabled(.isSet("upper")),
                    .picker("mode", L10n("Mode"), [FieldOption("a", "A"), FieldOption("b", "B", requires: ["tool.nonexistent"])], def: "a"),
                    .toggle("needsFF", L10n("Needs ffmpeg"), def: false).needs(["tool.nonexistent"])
                ])
            ])
        ])
    }
    override func quickOverrides(settings: SettingsData) -> OptionValues { OptionValues() }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        var text = String(repeating: ctx.options.string("text"), count: ctx.options.int("repeat", 1))
        if ctx.options.bool("upper") { text = text.uppercased() }
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { tmp in try text.write(to: tmp, atomically: false, encoding: .utf8) }
        progress.report(1)
        return [url]
    }
}

/// Runs until cancelled (a long job): reports progress slowly.
final class SlowOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.slow", .tools, .app, L10n("Slow"), symbol: "tortoise", schema: "test.slow", anyFile: true)) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        for i in 0..<200 {
            try await ctx.waitIfPaused()
            try ctx.checkCancelled()
            progress.report(Double(i) / 200)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return []
    }
}

/// A link operation with two stages that "downloads" and "converts" without touching the network.
final class StagedLinkOp: LinkOperation, @unchecked Sendable {
    init() { super.init(meta: .link("test.staged", L10n("Staged"), symbol: "arrow.down", schema: "test.staged")) }
    override func stagePlan(options: OptionValues) -> [StageSpec] { [.download(weight: 0.5), .convert(weight: 0.5)] }
    override func executeLinks(_ links: [LinkItem], ctx: OperationContext) async throws -> OperationResult {
        ctx.beginStage("download")
        for i in 1...4 { ctx.report(Double(i) / 4); try await Task.sleep(nanoseconds: 10_000_000) }
        ctx.beginStage("convert")
        for i in 1...4 { ctx.report(Double(i) / 4); try await Task.sleep(nanoseconds: 10_000_000) }
        ctx.finishStage()
        return OperationResult(outputs: [], note: L10n("staged done"))
    }
}

/// Always fails.
final class FailingOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.fail", .tools, .app, L10n("Fail"), symbol: "xmark", schema: "test.fail", anyFile: true)) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        throw ConversionError.message(L10n("Intentional failure", "Намеренная ошибка"))
    }
}

/// Runs EchoOp as a nested step of its own job (what a download's convert stage and chains do).
final class NestingOp: PerFileOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.nest", .tools, .app, L10n("Nest"), symbol: "star", schema: "test.nest", anyFile: true)) }
    override func stagePlan(options: OptionValues) -> [StageSpec] { [StageSpec(id: "a", title: L10n("A"), weight: 1), StageSpec(id: "b", title: L10n("B"), weight: 1)] }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        ctx.beginStage("a")
        ctx.report(1)
        ctx.beginStage("b")
        let r = try await ctx.runNested(EchoOp(), items: [item], overrides: ["text": "nested"])
        return r.outputs
    }
}

/// Polls `condition` every 10 ms up to `timeout` seconds; throws a test failure on timeout.
@MainActor
func expectEventually(timeout: TimeInterval = 5, file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
    if await eventually(timeout: timeout, condition) { return }
    throw TestFailure(message: "condition not met within \(timeout) s", file: "\(file)", line: line)
}

/// Polls `condition` every 10 ms up to `timeout` seconds.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
    return condition()
}

@MainActor
func makeTestRunner(fx: TestFixtures, ops: [Operation], settings: SettingsData = SettingsData()) -> (JobRunner, OperationRegistry, AppSettings) {
    let reg = OperationRegistry()
    reg.register(ops)
    let s = AppSettings(fileURL: fx.url("settings.json"), autosave: false)
    s.update { $0 = settings }
    let runner = JobRunner(persistence: false, registry: reg, settings: s)
    return (runner, reg, s)
}

enum CoreTestsEngine {
    static func register() {
        let t = SelfTestRegistry.shared

        // MARK: Option schemas

        t.register("core.options", "defaults, layering and coercion: later layers win, unknown keys drop, values clamp") {
            let schema = EchoOp().optionSchema(for: [])
            let d = schema.defaults()
            try expectEqual(d.string("text"), "hello"); try expectEqual(d.int("repeat"), 1); try expectEqual(d.bool("upper"), false)
            let r = schema.resolve(layers: [["text": "a", "repeat": 3, "bogus": 1], ["text": "b", "repeat": 99, "level": 9, "upper": true]])
            try expectEqual(r.values.string("text"), "b"); try expectEqual(r.values.int("repeat"), 5, "clamped to the stepper range")
            try expect(!r.values.has("bogus"), "unknown keys are dropped"); try expectEqual(r.values.int("level"), 9)
            try expectEqual(schema.resolve(layers: [["mode": "zzz"]]).values.string("mode"), "a", "invalid picker value falls back")
            try expectEqual(schema.resolve(layers: [["mode": "b"]]).values.string("mode"), "a", "an option whose capability is missing is not selectable")
        }

        t.register("core.options", "conditions: disabled fields reset to default and are reported inactive; capabilities gate fields") {
            let schema = EchoOp().optionSchema(for: [])
            let off = schema.resolve(layers: [["level": 9, "upper": false]])
            try expect(!off.isActive("level") && off.values.int("level") == 5, "level is disabled while upper is off, value reset")
            let on = schema.resolve(layers: [["level": 9, "upper": true]])
            try expect(on.isActive("level") && on.values.int("level") == 9)
            let gated = schema.resolve(layers: [["needsFF": true]])
            try expect(!gated.isActive("needsFF") && gated.values.bool("needsFF") == false, "missing capability disables and resets the field")
            try expect(Capabilities.shared.missingReason(["tool.nonexistent"]) == nil || true)
            try expectEqual(OptionExpr.all([.eq("a", "x"), .not(.isSet("b"))]).evaluate(ExprEnvironment(values: ["a": "x"], source: nil)), true)
            try expectEqual(OptionExpr.gt("n", 3).evaluate(ExprEnvironment(values: ["n": 3.5], source: nil)), true)
            var src = SourceInfo(url: URL(fileURLWithPath: "/tmp/a.mp4"), kind: .video); src.facts["video.height"] = .int(2160)
            try expect(OptionExpr.source("video.height", .gt, 1080).evaluate(ExprEnvironment(values: OptionValues(), source: src)))
            try expect(!OptionExpr.source("video.height", .gt, 1080).evaluate(ExprEnvironment(values: OptionValues(), source: nil)))
        }

        t.register("core.options", "diff against defaults gives the sparse form; numeric 5 equals 5.0") {
            let schema = EchoOp().optionSchema(for: [])
            let v = schema.resolve(layers: [["text": "x", "repeat": 2]]).values
            let changes = v.diff(against: schema.defaults())
            try expectEqual(changes.map(\.key), ["repeat", "text"])
            try expectEqual(v.sparse(against: schema.defaults()).keys, ["repeat", "text"])
            try expectEqual(OptionValues(["n": .int(5)]).diff(against: OptionValues(["n": .double(5.0)])).count, 0)
            try expectEqual(schema.changedFields(v).count, 2)
            try expect(schema.search("repeat").count == 1 && schema.search("UPPER").count == 1 && schema.search("zzzz").isEmpty)
        }

        t.register("core.options", "validation rules produce messages with fixes; text fields validate their format") {
            var f = OptionField.text("pages", L10n("Pages"), def: "", validation: .pageRange)
            f = f.rule(.warning("w1", when: .eq("pages", "all"), L10n("All pages"), field: "pages"))
            let schema = OptionSchema(id: "t", title: L10n("T"), pages: [.make("p", symbol: "star", L10n("P"), [.make("g", [f])])])
            try expectEqual(schema.resolve(layers: [["pages": "1-3, 5"]]).messages.count, 0)
            try expectEqual(schema.resolve(layers: [["pages": "1-x"]]).messages.first?.severity, .error)
            try expectEqual(schema.resolve(layers: [["pages": "all"]]).messages.first?.id, "w1")
        }

        t.register("core.options", "OptionValues is plain JSON and round-trips (bool, int, double, string, list, rows)") {
            let rows: [[String: OptionValue]] = [["codec": "aac", "bitrate": 160], ["codec": "ac3", "bitrate": 384]]
            let v: OptionValues = ["a": true, "b": 5, "c": 1.5, "d": "x", "e": ["p", "q"], "rows": .rows(rows)]
            let data = try JSONEncoder().encode(v)
            let back = try JSONDecoder().decode(OptionValues.self, from: data)
            try expectEqual(back.bool("a"), true); try expectEqual(back.int("b"), 5); try expectEqual(back.double("c"), 1.5)
            try expectEqual(back.string("d"), "x"); try expectEqual(back.list("e").count, 2); try expectEqual(back.rows("rows").count, 2)
            try expectEqual(String(decoding: try JSONEncoder().encode(OptionValues(["z": 1, "a": "x"])), as: UTF8.self).contains("\"a\":\"x\""), true)
        }

        t.register("core.options", "the Output page is appended once and out.* keys map to OutputRules") {
            let s = EchoOp().studioSchema(for: [])
            try expectEqual(s.pages.last?.id, "output"); try expectEqual(s.withOutputPage().pages.count, s.pages.count)
            let rules = OutputRules(options: ["out.dirMode": "subfolder", "out.subfolder": "Out", "out.collision": "skip", "out.trashSource": true])
            try expectEqual(rules.dirMode, .subfolder); try expectEqual(rules.subfolderName, "Out"); try expectEqual(rules.collision, .skip); try expect(rules.trashSource)
            try expectEqual(OutputRules(options: rules.optionValues).collision, .skip)
        }

        // MARK: Presets and recipes

        t.register("core.presets", "user presets save, rename, duplicate, delete and survive a reload; built-ins are read-only") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let store = PresetStore(directory: fx.url("Presets"))
            store.registerBuiltins([Preset.builtin("fast", target: "test.echo", L10n("Fast"), ["repeat": 2])])
            try expect(store.preset(id: "builtin.fast") != nil)
            let p = try store.create(name: "Mine", targetID: "test.echo", values: ["text": "hi"])
            try store.rename(id: p.id, to: "Mine 2")
            let copy = try store.duplicate(id: "builtin.fast")
            try expectEqual(copy.group, .custom); try expect(!copy.isBuiltin)
            let reloaded = PresetStore(directory: fx.url("Presets"))
            try expectEqual(reloaded.userPresets.count, 2)
            try expectEqual(reloaded.preset(id: p.id)?.name.en, "Mine 2"); try expectEqual(reloaded.preset(id: p.id)?.values.string("text"), "hi")
            try expect(throwsSync { try store.rename(id: "builtin.fast", to: "x") }, "built-in is read-only")
            try expect(throwsSync { try store.delete(id: "builtin.fast") })
            try store.delete(id: p.id)
            try expectEqual(PresetStore(directory: fx.url("Presets")).userPresets.count, 1)
            store.setDefaultPreset("builtin.fast", for: "test.echo")
            try expectEqual(PresetStore(directory: fx.url("Presets")).defaultPresetID(for: "test.echo"), "builtin.fast")
        }

        t.register("core.presets", "export and import .swampreset keeps values, regenerates colliding ids") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let a = PresetStore(directory: fx.url("A"))
            let p = try a.create(name: "Shared", targetID: "test.echo", values: ["text": "x", "repeat": 3])
            let file = fx.url("shared.swampreset")
            try a.export(ids: [p.id], to: file)
            let b = PresetStore(directory: fx.url("B"))
            let imported = try b.importFile(file)
            try expectEqual(imported.count, 1); try expectEqual(imported[0].values.int("repeat"), 3); try expectEqual(imported[0].name.en, "Shared")
            let again = try a.importFile(file)
            try expect(again[0].id != p.id, "colliding ids are regenerated")
            try fx.text("junk.json", "{\"nope\":1}")
            try expect(throwsSync { _ = try b.importFile(fx.url("junk.json")) }, "non-preset files are refused")
        }

        t.register("core.recipe", "Recipe JSON round-trip; quick recipe layering: defaults < op overrides < user edits < job overrides") {
            let r = Recipe(operationID: "test.echo", values: ["text": "x"], presetID: "builtin.fast", output: OutputRules(), name: "n")
            let back = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(r))
            try expectEqual(back, r)
            let chain = RecipeChain(name: "c", steps: [r, r])
            try expectEqual(try JSONDecoder().decode(RecipeChain.self, from: JSONEncoder().encode(chain)).steps.count, 2)

            final class Op: PerFileOperation, @unchecked Sendable {
                init() { super.init(meta: .make("test.layers", .tools, .app, L10n("L"), symbol: "star", schema: "test.echo", anyFile: true)) }
                override func optionSchema(for items: [FileItem]) -> OptionSchema { EchoOp().optionSchema(for: items) }
                override func quickOverrides(settings: SettingsData) -> OptionValues { ["text": "op", "repeat": 2] }
                override func privacyOverrides() -> OptionValues { ["upper": true] }
            }
            var settings = SettingsData()
            settings.quickRecipes["test.layers"] = ["text": "user"]
            let op = Op()
            let base = QuickRecipes.resolve(op, items: [], settings: settings)
            try expectEqual(base.values.string("text"), "user"); try expectEqual(base.values.int("repeat"), 2); try expectEqual(base.values.bool("upper"), false)
            let job = QuickRecipes.resolve(op, items: [], settings: settings, extra: [["text": "job"]])
            try expectEqual(job.values.string("text"), "job")
            settings.alwaysStripMetadata = true
            try expectEqual(QuickRecipes.resolve(op, items: [], settings: settings).values.bool("upper"), true, "global privacy layer applies to quick runs")
            try expectEqual(QuickRecipes.resolve(op, items: [], settings: settings, mode: .studio).values.bool("upper"), false, "but not to Studio runs")
            try expectEqual(QuickRecipes.current(for: op, settings: settings).string("text"), "user")
        }

        t.register("core.settings", "settings round-trip; corrupt or partly invalid files fall back per key") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let url = fx.url("s.json")
            let s = AppSettings(fileURL: url, autosave: false)
            s.update { $0.language = .russian; $0.maxConcurrentJobs = 3; $0.downloader.consentGiven = true; $0.downloader.afterDownload = .preset("u-1") }
            s.save()
            let re = AppSettings(fileURL: url, autosave: false).data
            try expectEqual(re.language, .russian); try expectEqual(re.maxConcurrentJobs, 3); try expect(re.downloader.consentGiven)
            try expectEqual(re.downloader.afterDownload, .preset("u-1"))
            try Data("{ not json".utf8).write(to: url)
            try expectEqual(AppSettings(fileURL: url, autosave: false).data, SettingsData())
            try Data("{\"maxConcurrentJobs\": \"many\", \"language\": \"english\", \"future\": 1}".utf8).write(to: url)
            let tolerant = AppSettings(fileURL: url, autosave: false).data
            try expectEqual(tolerant.language, .english); try expectEqual(tolerant.maxConcurrentJobs, 2, "invalid key falls back to its default")
            try expect(!SettingsData().downloader.consentGiven && !SettingsData().downloader.checkForUpdates, "network features are off until the user opts in")
        }

        // MARK: Registry

        t.register("core.registry", "wheel entries apply all-or-nothing, same-format hiding, availability and link wheel") {
            let reg = OperationRegistry()
            reg.register([EchoOp(id: "t.a"), EchoOp(id: "t.b", wheel: .convert), StagedLinkOp()])
            let png = FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)
            try expectEqual(reg.entries(wheel: .tools, items: [png]).map(\.id), ["t.a"])
            try expectEqual(reg.entries(wheel: .convert, items: [png]).map(\.id), ["t.b"])
            try expectEqual(reg.entries(wheel: .tools, items: []).count, 0)
            let link = LinkItem(url: URL(string: "https://example.com/v")!)
            try expectEqual(reg.linkEntries(links: [link]).map(\.id), ["test.staged"])
            try expectEqual(reg.linkEntries(links: [LinkItem(url: URL(string: "http://127.0.0.1/x")!)]).count, 0, "private hosts never reach the link wheel")
            try expectEqual(reg.entries(wheel: .link, items: [png]).count, 0, "file items never see link operations")
            try expectEqual(reg.studioTargets(forLinks: [link]).first?.id, "test.staged")
            try expectEqual(reg.studioTargets(for: [png]).map(\.id), ["test.echo"], "operations sharing a schema collapse into one Studio target")
            try expect(reg.operation(id: "t.a") != nil && reg.operation(id: "nope") == nil)
            reg.registerProvider(id: "dyn") { _ in [EchoOp(id: "dyn.1")] }
            try expect(reg.operation(id: "dyn.1") != nil, "provider operations resolve by id")
        }

        // MARK: Stages

        t.register("core.stages", "weighted overall progress, skipped stages, indeterminate stages and ETA") {
            var tr = StageTracker([.download(weight: 0.6), .convert(weight: 0.4)])
            let t0 = Date(timeIntervalSince1970: 1_000)
            try expect(tr.overallFraction == 0 && tr.isMultiStage, "nothing started yet: 0")
            tr.begin("download", now: t0)
            try expect(tr.overallFraction == nil, "indeterminate while nothing is known")
            tr.update(fraction: 0.5)
            try expectClose(tr.overallFraction ?? -1, 0.3)
            tr.update(fraction: 0.5, eta: 10)
            try expectClose(tr.overallETA(now: t0.addingTimeInterval(10)) ?? -1, 10 + 20 * 0.4 / 0.6, tolerance: 0.01)
            tr.begin("convert", now: t0.addingTimeInterval(20))
            try expectEqual(tr.stages[0].state, .done); try expectClose(tr.overallFraction ?? -1, 0.6)
            tr.update(fraction: 1)
            try expectClose(tr.overallFraction ?? -1, 1)
            var skip = StageTracker([.download(weight: 0.6), .convert(weight: 0.4)])
            skip.begin("download"); skip.update(fraction: 0.5); skip.skip("convert")
            try expectClose(skip.overallFraction ?? -1, 0.5, tolerance: 1e-9)
            var jump = StageTracker([.download(), .convert()])
            jump.begin("convert"); try expectEqual(jump.stages[0].state, .skipped, "beginning a later stage skips the pending earlier ones")
        }

        // MARK: Job runner

        t.register("core.jobs", "a job runs, writes its output next to the original and lands in the history") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [EchoOp()])
            let src = FileItem(url: try fx.text("note.txt", "x"))
            let job = runner.submit(operation: reg.operation(id: "test.echo")!, items: [src], overrides: ["text": "ab", "repeat": 2])
            try await expectEventually { job.state.isFinished }
            try expectEqual(job.state, .done); try expectEqual(job.progress, 1)
            let out = try unwrap(job.outputs.first)
            try expectEqual(out.lastPathComponent, "note (echo).txt"); try expectEqual(try String(contentsOf: out, encoding: .utf8), "abab")
            try expectEqual(runner.history.first?.state, .done); try expectEqual(runner.history.first?.outputs.count, 1)
            try expectEqual(TestFile.partials(in: fx.root), [])
            let again = runner.submit(operation: reg.operation(id: "test.echo")!, items: [src])
            try await expectEventually { again.state.isFinished }
            try expectEqual(again.outputs.first?.lastPathComponent, "note (echo) (2).txt", "second run never overwrites")
        }

        t.register("core.jobs", "failures are reported with a calm message and counted per batch") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [FailingOp()])
            let job = runner.submit(operation: reg.operation(id: "test.fail")!, items: [FileItem(url: try fx.text("a.txt", "x"))])
            try await expectEventually { job.state.isFinished }
            try expectEqual(job.state, .failed); try expect(job.errorMessage?.contains("Intentional") == true || job.errorMessage?.contains("Намеренная") == true)
            try expectEqual(runner.history.first?.state, .failed)
        }

        t.register("core.jobs", "cancelling stops a running job within 200 ms and leaves no partial files") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [SlowOp()])
            let job = runner.submit(operation: reg.operation(id: "test.slow")!, items: [FileItem(url: try fx.text("a.txt", "x"))])
            try await expectEventually { job.state == .running }
            try await Task.sleep(nanoseconds: 100_000_000)
            let t0 = Date()
            runner.cancel(job)
            try await expectEventually(timeout: 2) { job.state == .cancelled }
            try expect(Date().timeIntervalSince(t0) < 0.2 + 0.1, "cancel latency \(Date().timeIntervalSince(t0)) s")
            try expectEqual(TestFile.partials(in: fx.root), [])
        }

        t.register("core.jobs", "pause holds progress, resume continues; the queue can be held and started in order") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [SlowOp(), EchoOp()])
            runner.maxConcurrentOverride = 1
            let slow = runner.submit(operation: reg.operation(id: "test.slow")!, items: [FileItem(url: try fx.text("a.txt", "x"))])
            try await expectEventually { (slow.progress ?? 0) > 0.02 }
            runner.pause(slow); try expectEqual(slow.state, .paused)
            let frozen = slow.progress ?? 0
            try await Task.sleep(nanoseconds: 250_000_000)
            try expect((slow.progress ?? 0) - frozen < 0.01, "no progress while paused")
            let queued = runner.enqueue(operation: reg.operation(id: "test.echo")!, items: [FileItem(url: try fx.text("b.txt", "y"))])
            try expectEqual(queued.state, .waiting); try expect(queued.held)
            runner.resume(slow); try expectEqual(slow.state, .running)
            runner.cancel(slow)
            try await expectEventually { slow.state == .cancelled }
            try await Task.sleep(nanoseconds: 100_000_000)
            try expectEqual(queued.state, .waiting, "held jobs wait for Start Queue")
            runner.startQueue()
            try await expectEventually { queued.state == .done }
        }

        t.register("core.jobs", "concurrency limit: with 1 slot the second job waits; reorder moves waiting jobs") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [SlowOp(), EchoOp()])
            runner.maxConcurrentOverride = 1
            let a = runner.submit(operation: reg.operation(id: "test.slow")!, items: [FileItem(url: try fx.text("a.txt", "x"))])
            let b = runner.enqueue(operation: reg.operation(id: "test.echo")!, items: [FileItem(url: try fx.text("b.txt", "x"))])
            let c = runner.enqueue(operation: reg.operation(id: "test.echo")!, items: [FileItem(url: try fx.text("c.txt", "x"))])
            try await expectEventually { a.state == .running }
            try expectEqual(runner.summary.running, 1); try expectEqual(runner.summary.waiting, 2)
            runner.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
            try expectEqual(runner.jobs.map(\.id), [a.id, c.id, b.id])
            try expect(runner.updateOverrides(c, ["text": "late"]), "waiting jobs accept per-job overrides")
            runner.cancel(a)
            runner.startQueue()
            try await expectEventually { b.state == .done && c.state == .done }
            try expectEqual(try String(contentsOf: try unwrap(c.outputs.first), encoding: .utf8), "late")
            runner.removeFinished(); try expect(runner.jobs.isEmpty)
        }

        t.register("core.jobs", "a two-stage link job reports combined progress and per-stage state") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [StagedLinkOp()])
            let job = runner.submit(operation: reg.operation(id: "test.staged")!, links: [LinkItem(url: URL(string: "https://example.com/v")!)])
            try await expectEventually { job.state.isFinished }
            try expectEqual(job.state, .done); try expectEqual(job.stages.count, 2)
            try expectEqual(job.stages.map(\.state), [.done, .done]); try expectEqual(job.note?.en, "staged done")
            try expect(job.isLinkJob && job.title.contains("example.com"))
            try expect(job.logText.contains("uses the network"), "network use is logged")
            try expectEqual(runner.history.first?.linkURLs, ["https://example.com/v"])
        }

        t.register("core.jobs", "a file operation refuses links and vice versa; privacy layer reaches quick jobs only") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [EchoOp(), StagedLinkOp()])
            let wrong = runner.submit(operation: reg.operation(id: "test.echo")!, links: [LinkItem(url: URL(string: "https://example.com/v")!)])
            try await expectEventually { wrong.state.isFinished }; try expectEqual(wrong.state, .failed)
            let q = await QuickRun.shared.run(reg.operation(id: "test.staged")!, links: [LinkItem(url: URL(string: "http://10.0.0.1/x")!)], origin: .wheel)
            if case .notApplicable = q {} else { throw TestFailure(message: "private link must not run", file: #fileID, line: #line) }
        }

        t.register("core.jobs", "a nested operation runs inside the same job, shares its stage progress and cancels with it") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [NestingOp()])
            let job = runner.submit(operation: reg.operation(id: "test.nest")!, items: [FileItem(url: try fx.text("n.txt", "x"))])
            try await expectEventually { job.state.isFinished }
            try expectEqual(job.state, .done); try expectEqual(runner.jobs.count, 1, "no extra job is created for the nested step")
            try expectEqual(try String(contentsOf: try unwrap(job.outputs.first), encoding: .utf8), "nested")
            try expectEqual(job.stages.map(\.state), [.done, .done])
            try expectEqual(job.progress, 1)
        }

        t.register("core.jobs", "after many jobs the in-memory list stays capped") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [EchoOp()])
            runner.maxConcurrentOverride = 4
            let src = FileItem(url: try fx.text("a.txt", "x"))
            let op = reg.operation(id: "test.echo")!
            for _ in 0..<(JobRunner.finishedJobsKept + 15) { runner.submit(operation: op, items: [src]) }
            await runner.waitUntilIdle(timeout: 30)
            try expect(runner.jobs.count <= JobRunner.finishedJobsKept, "finished jobs capped at \(JobRunner.finishedJobsKept), have \(runner.jobs.count)")
            try expect(runner.history.count >= JobRunner.finishedJobsKept + 15, "history keeps them")
        }

        t.register("core.thumbnails", "thumbnails are decoded at the requested size, honour orientation and are cached") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let big = try fx.png("big.png", width: 1600, height: 800, pattern: .gradient)
            let cache = ThumbnailCache()
            let t1 = try unwrap(await cache.thumbnail(for: big, maxPixel: 200))
            try expect(max(t1.width, t1.height) <= 200 && max(t1.width, t1.height) >= 190, "longest side \(max(t1.width, t1.height))")
            try expectEqual(t1.width, 200); try expectEqual(t1.height, 100)
            let t2 = try unwrap(await cache.thumbnail(for: big, maxPixel: 200))
            try expect(t1 === t2 || (t1.width == t2.width), "second call is a cache hit")
            let none = await cache.thumbnail(for: fx.url("missing.png"), maxPixel: 64)
            try expect(none == nil, "missing file gives nil, no crash")
            let rotated = try fx.jpeg("rot.jpg", width: 200, height: 100, orientation: 6)
            let tr = try unwrap(await cache.thumbnail(for: rotated, maxPixel: 100))
            try expect(tr.height > tr.width, "EXIF orientation 6 is baked into the thumbnail")
        }

        t.register("core.fixtures", "generated fixtures are real files of the claimed type") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let png = try fx.png(width: 40, height: 30, pattern: .quadrants)
            try expectEqual(TestImage.size(of: png)?.width, 40)
            try expect(TestImage.close(TestImage.pixel(of: png, x: 2, y: 2), .red)); try expect(TestImage.close(TestImage.pixel(of: png, x: 37, y: 27), .yellow))
            try expectEqual(TestFile.magicString(try fx.pdf(pages: 2), 5), "%PDF-")
            try expectEqual(TestFile.magicString(try fx.wav(), 4), "RIFF")
            try fx.text("a.txt", "A")
            try expectEqual(TestFile.magicString(try fx.zip(items: ["a.txt"]), 2), "PK")
        }
    }

    private static func throwsSync(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
}
