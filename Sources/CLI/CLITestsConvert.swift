import Foundation

/// `swamp convert` end to end, in-process, on fixture operations: quick semantics, --set / --preset layering, JSON Lines, human output, awkward file names, warnings.
enum CLITestsConvert {
    @MainActor private static func rig(_ body: (CLIRig) async throws -> Void) async throws {
        let rig = CLIRig()
        defer { rig.cleanup() }
        try await body(rig)
    }

    private static func outputs(of result: CLIResult) throws -> [URL] {
        let done = try result.event("done")
        try expectEqual(done.count, 1, "one done event")
        return ((done[0]["outputs"] as? [String]) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.convert", "quick semantics: with no --set / --preset the result equals the wheel's, byte for byte") {
            try await rig { rig in
                let src = try rig.file("note.txt", "hello", in: "a")
                let r = await rig.run(["convert", src.path, "--op", "test.cli.report", "--json"])
                try expectEqual(r.code, 0, r.stdout + r.stderr)
                let out = try outputs(of: r)
                try expectEqual(out.count, 1); try expectEqual(out[0].lastPathComponent, "note (cli).json")
                let cli = try rig.report(out[0])
                try expectEqual(cli["mode"] as? String, "quick")
                let options = try unwrap(cli["options"] as? [String: Any])
                try expectEqual(options["f.text"] as? String, "quick", "the operation's quick recipe is applied, not the schema default")
                try expectEqual(options["f.count"] as? Int, 2)

                // The wheel: the same operation submitted through the runner in quick mode on an identical copy.
                let copy = try rig.file("note.txt", "hello", in: "b")
                let job = rig.runner.submit(operation: try unwrap(rig.registry.operation(id: "test.cli.report")), items: [FileItem(url: copy)], origin: .wheel, mode: .quick)
                await rig.runner.waitUntilIdle()
                try expectEqual(job.state, .done)
                let wheelBytes = try Data(contentsOf: try unwrap(job.outputs.first))
                try expectEqual(try Data(contentsOf: out[0]), wheelBytes, "CLI output == wheel output")
            }
        }

        t.register("cli.convert", "--set values are typed and reach ctx.options; the run becomes a studio run and the network is off") {
            try await rig { rig in
                let src = try rig.file("a.txt")
                let saved = NetworkGate.forbidAll
                NetworkGate.forbidAll = false
                defer { NetworkGate.forbidAll = saved }
                let r = await rig.run(["convert", src.path, "--op", "test.cli.report", "--json", "--set", "f.text=xyz", "--set", "f.count=3", "--set", "f.upper=true",
                                       "--set", "f.level=9", "--set", "f.mode=b", "--set", "f.start=1:30", "--set", "f.gain=2.5", "--set", "f.color=#ff72d9"])
                try expectEqual(r.code, 0, r.stdout + r.stderr)
                try expectEqual(NetworkGate.forbidAll, false, "the previous network gate state is restored after a run")
                let report = try rig.report(try unwrap(try outputs(of: r).first))
                try expectEqual(report["mode"] as? String, "studio", "--set makes it a studio run")
                try expectEqual(report["forbidAll"] as? Bool, true, "a conversion runs with the network gate closed")
                let o = try unwrap(report["options"] as? [String: Any])
                try expectEqual(o["f.text"] as? String, "xyz"); try expectEqual(o["f.count"] as? Int, 3); try expectEqual(o["f.upper"] as? Bool, true)
                try expectEqual(o["f.level"] as? Int, 9); try expectEqual(o["f.mode"] as? String, "b"); try expectEqual(o["f.start"] as? Double, 90)
                try expectEqual(o["f.gain"] as? Double, 2.5); try expectEqual(o["f.color"] as? String, "#FF72D9")
            }
        }

        t.register("cli.convert", "--op accepts an id, a target (schema) id, a case-insensitive id; --preset supplies values and operation; --set beats the preset") {
            try await rig { rig in
                let src = try rig.file("p.txt")
                _ = try rig.presets.create(name: "My Preset", targetID: CLIFixtureOp.schemaID, values: ["f.text": "fromPreset", "f.count": 4])
                let byPreset = await rig.run(["convert", src.path, "--preset", "my preset", "--json"])
                try expectEqual(byPreset.code, 0, byPreset.stdout + byPreset.stderr)
                var report = try rig.report(try unwrap(try outputs(of: byPreset).first))
                var o = try unwrap(report["options"] as? [String: Any])
                try expectEqual(o["f.text"] as? String, "fromPreset"); try expectEqual(o["f.count"] as? Int, 4); try expectEqual(report["mode"] as? String, "studio")

                let layered = await rig.run(["convert", src.path, "--preset", "My Preset", "--set", "f.count=1", "--json"])
                report = try rig.report(try unwrap(try outputs(of: layered).first))
                o = try unwrap(report["options"] as? [String: Any])
                try expectEqual(o["f.count"] as? Int, 1, "--set wins over the preset"); try expectEqual(o["f.text"] as? String, "fromPreset")

                let bySchema = await rig.run(["convert", src.path, "--op", "TEST.CLI", "--json"])
                try expectEqual(bySchema.code, 0, "a target id picks the target's first operation: \(bySchema.stdout)")
                let byCase = await rig.run(["convert", src.path, "--op", "Test.Cli.Report", "--json"])
                try expectEqual(byCase.code, 0)

                let other = await rig.run(["convert", src.path, "--op", "test.cli.flaky", "--preset", "My Preset"])
                try expectEqual(other.code, 2); try expect(other.stderr.contains("is for 'test.cli'"), other.stderr)
                let id = try unwrap(rig.presets.userPresets.first?.id)
                let byID = await rig.run(["convert", src.path, "--preset", id, "--op", "test.cli.report", "--json"])
                try expectEqual(byID.code, 0, "a preset id works together with --op of the same target")
            }
        }

        t.register("cli.convert", "JSON Lines: only events on stdout, progress fractions are monotonic, the last line is done with the outputs and code 0") {
            try await rig { rig in
                let src = try rig.file("s.txt")
                let r = await rig.run(["convert", src.path, "--op", "test.cli.stepped", "--json"])
                try expectEqual(r.code, 0, r.stdout + r.stderr)
                try expect(r.stderr.isEmpty, "in --json mode stderr stays empty, got: \(r.stderr)")
                let events = try r.events()
                try expect(events.count >= 3, "several progress events and a done: \(events.count)")
                let names = Set(events.compactMap { $0["event"] as? String })
                try expect(names.isSubset(of: ["progress", "done", "warning"]), "unexpected events \(names)")
                try expectEqual(events.last?["event"] as? String, "done")
                var last = -1.0
                for e in events where (e["event"] as? String) == "progress" {
                    try expect(!(e["job"] as? String ?? "").isEmpty && UUID(uuidString: e["job"] as? String ?? "") != nil, "a job id on every progress line")
                    try expect(e.keys.contains("fraction") && e.keys.contains("stage") && e.keys.contains("eta"), "progress has fraction, stage, eta")
                    if let f = e["fraction"] as? Double { try expect(f >= 0 && f <= 1 && f >= last, "fraction \(f) after \(last)"); last = f }
                }
                try expect(last > 0.5, "progress reached the end region: \(last)")
                let done = try unwrap(events.last)
                let outs = try unwrap(done["outputs"] as? [String])
                try expectEqual(outs.count, 1); try expect(FileManager.default.fileExists(atPath: outs[0]))
                try expectEqual(done["code"] as? Int, 0); try expectEqual((done["failures"] as? [String])?.count, 0)
                try expectEqual(done["job"] as? String, (events.first { ($0["event"] as? String) == "progress" }?["job"] as? String), "one job id throughout")
            }
        }

        t.register("cli.convert", "human mode: stdout is exactly the result paths, progress and messages go to stderr") {
            try await rig { rig in
                let a = try rig.file("one.txt"), b = try rig.file("two.txt")
                let r = await rig.run(["convert", a.path, b.path, "--op", "test.cli.stepped"])
                try expectEqual(r.code, 0, r.stderr)
                let paths = r.lines
                try expectEqual(paths.count, 2, "one line per result: \(r.stdout)")
                for p in paths { try expect(p.hasPrefix("/") && FileManager.default.fileExists(atPath: p), "stdout line \(p) is an existing file") }
                try expect(!r.stderr.isEmpty, "progress went to stderr")
                let quiet = await rig.run(["convert", a.path, "--op", "test.cli.report", "--quiet"])
                try expectEqual(quiet.code, 0); try expect(quiet.stderr.isEmpty, "--quiet silences progress: \(quiet.stderr)"); try expectEqual(quiet.lines.count, 1)
                let verbose = await rig.run(["convert", a.path, "--op", "test.cli.report", "--verbose"])
                try expect(verbose.stderr.contains("test.cli.report"), "--verbose shows the job log: \(verbose.stderr)")
                try expectEqual(verbose.lines.count, 1, "stdout still has only the result")
            }
        }

        t.register("cli.convert", "file names with spaces, dots, unicode and a leading dash work; --out creates the folder; names never collide") {
            try await rig { rig in
                let cwd = FileManager.default.currentDirectoryPath
                defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
                let dir = try rig.fx.makeDirectory("in dir")
                let names = ["My file.v2.final.txt", "Привет мир.txt", "-dash.txt", "ünï.cöde.txt"]
                for n in names { try "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
                FileManager.default.changeCurrentDirectoryPath(dir.path)
                let out = rig.fx.url("out dir/sub")
                let r = await rig.run(["convert", "--op", "test.cli.report", "--out", out.path, "--json", "--"] + names)
                try expectEqual(r.code, 0, r.stdout + r.stderr)
                let results = try outputs(of: r)
                try expectEqual(results.count, names.count)
                for (n, u) in zip(names, results) {
                    try expectEqual(u.deletingLastPathComponent().path, out.path, "results go to --out")
                    try expectEqual(u.lastPathComponent, URL(fileURLWithPath: n).deletingPathExtension().lastPathComponent + " (cli).json")
                }
                let again = await rig.run(["convert", "--op", "test.cli.report", "--out", out.path, "--json", "--"] + names)
                try expectEqual(again.code, 0)
                let second = try outputs(of: again)
                try expect(Set(second.map(\.path)).isDisjoint(with: Set(results.map(\.path))), "a second run never overwrites the first results")
                try expect(second.allSatisfy { $0.lastPathComponent.contains(" (2)") }, "collisions get a number")
                try expect(results.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the first results are untouched")
                try expect(TestFile.partials(in: out).isEmpty, "no partial files left")
                let relOut = await rig.run(["convert", "--op", "test.cli.report", "--out", "rel-out", "--json", "--", "Привет мир.txt"])
                try expectEqual(relOut.code, 0, relOut.stdout)
                try expect(try outputs(of: relOut)[0].path.hasSuffix("/in dir/rel-out/Привет мир (cli).json"), "a relative --out is relative to the working directory")
            }
        }

        t.register("cli.convert", "warnings: a --set that has no effect, or was adjusted, is reported; the run still succeeds") {
            try await rig { rig in
                let src = try rig.file("w.txt")
                let off = await rig.run(["convert", src.path, "--op", "test.cli.report", "--json", "--set", "f.level=9"])
                try expectEqual(off.code, 0)
                let w = try off.event("warning")
                try expectEqual(w.count, 1)
                try expect((w[0]["message"] as? String ?? "").contains("'f.level' has no effect"), "\(w)")
                let done = try unwrap(try off.event("done").first)
                try expectEqual((done["warnings"] as? [String])?.count, 1, "the warning is repeated in the done event")

                let unusable = await rig.run(["convert", src.path, "--op", "test.cli.report", "--set", "f.mode=c"])
                try expectEqual(unusable.code, 0)
                try expect(unusable.stderr.contains("'f.mode' was set to c but a is used"), unusable.stderr)
                let gated = await rig.run(["convert", src.path, "--op", "test.cli.report", "--set", "f.needs=true"])
                try expect(gated.stderr.contains("'f.needs' has no effect") && gated.stderr.contains("Not available"), gated.stderr)
            }
        }

        t.register("cli.convert", "options that fail validation are a usage error before any job starts") {
            try await rig { rig in
                let src = try rig.file("v.txt")
                let r = await rig.run(["convert", src.path, "--op", "test.cli.report", "--set", "f.pages=1-x", "--json"])
                try expectEqual(r.code, 2, r.stdout)
                let err = try unwrap(try r.event("error").first)
                try expectEqual(err["code"] as? Int, 2); try expect((err["message"] as? String ?? "").contains("f.pages"))
                try expect(rig.runner.jobs.isEmpty, "no job was created")
                let siblings = (try? FileManager.default.contentsOfDirectory(atPath: rig.fx.root.path)) ?? []
                try expect(!siblings.contains { $0.hasSuffix(".json") && $0.contains("(cli)") }, "nothing was written")
            }
        }

        t.register("cli.convert", "the run uses a private queue: the app's queue and history files are not touched") {
            try await rig { rig in
                let src = try rig.file("q.txt")
                let before = (try? Data(contentsOf: AppPaths.queueFile), try? Data(contentsOf: AppPaths.historyFile))
                var env = rig.environment
                env.runner = nil     // the default: a private runner without persistence
                let r = await rig.run(["convert", src.path, "--op", "test.cli.report"], environment: env)
                try expectEqual(r.code, 0, r.stderr)
                try await Task.sleep(nanoseconds: 800_000_000)
                let after = (try? Data(contentsOf: AppPaths.queueFile), try? Data(contentsOf: AppPaths.historyFile))
                try expectEqual(before.0, after.0, "queue.json unchanged"); try expectEqual(before.1, after.1, "history.json unchanged")
                try expect(JobRunner.shared.jobs.allSatisfy { $0.operationID != "test.cli.report" }, "the shared runner never saw the job")
            }
        }
    }
}
