import Foundation

/// The frozen exit codes: 0 ok, 1 failed, 2 usage, 3 unavailable, 4 partial, 130 cancelled; and the shape of the error on both output modes.
enum CLITestsExit {
    @MainActor private static func rig(_ body: (CLIRig) async throws -> Void) async throws {
        let rig = CLIRig()
        defer { rig.cleanup() }
        try await body(rig)
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.exit", "outcome table: ok / failed / partial / cancelled map to 0 / 1 / 4 / 130") {
            func outcome(_ s: JobState, outputs: Int = 0, failures: Int = 0, toolMissing: Bool = false) -> CLIExitCode {
                CLIJobOutcome(state: s, outputs: (0..<outputs).map { URL(fileURLWithPath: "/tmp/o\($0)") }, failures: (0..<failures).map { "f\($0)" },
                              note: nil, error: nil, elapsed: 0, toolMissing: toolMissing).exitCode
            }
            try expectEqual(outcome(.failed, toolMissing: true), .unavailable, "a program that is not installed is 3, not 1")
            try expectEqual(outcome(.cancelled, toolMissing: true), .cancelled)
            try expectEqual(outcome(.done, outputs: 2), .ok)
            try expectEqual(outcome(.done), .ok, "nothing to do is not an error")
            try expectEqual(outcome(.done, outputs: 1, failures: 1), .partial)
            try expectEqual(outcome(.done, outputs: 0, failures: 2), .failed)
            try expectEqual(outcome(.failed), .failed); try expectEqual(outcome(.cancelled), .cancelled); try expectEqual(outcome(.skipped), .ok)
        }

        t.register("cli.exit", "usage errors (2): unknown operation with suggestions, missing file, a link given to convert, bad preset; JSON mode answers with an error event") {
            try await rig { rig in
                let src = try rig.file("u.txt")
                let unknown = await rig.run(["convert", src.path, "--op", "test.cli.reprot"])
                try expectEqual(unknown.code, 2); try expect(unknown.stdout.isEmpty, "stdout stays empty on errors in human mode")
                try expect(unknown.stderr.contains("Unknown operation 'test.cli.reprot'") && unknown.stderr.contains("test.cli.report"), unknown.stderr)
                try expect(unknown.stderr.hasPrefix("swamp: "), unknown.stderr)
                let missing = await rig.run(["convert", rig.fx.url("nope.txt").path, "--op", "test.cli.report"])
                try expectEqual(missing.code, 2); try expect(missing.stderr.contains("No such file"), missing.stderr)
                let link = await rig.run(["convert", "https://example.com/v.mp4", "--op", "test.cli.report"])
                try expectEqual(link.code, 2); try expect(link.stderr.contains("swamp download"), link.stderr)
                let preset = await rig.run(["convert", src.path, "--preset", "no such preset"])
                try expectEqual(preset.code, 2); try expect(preset.stderr.contains("Unknown preset"), preset.stderr)
                let file = try rig.file("afile")
                let outIsFile = await rig.run(["convert", src.path, "--op", "test.cli.report", "--out", file.path])
                try expectEqual(outIsFile.code, 2); try expect(outIsFile.stderr.contains("must be a folder"), outIsFile.stderr)
                let badOption = await rig.run(["convert", src.path, "--op", "test.cli.report", "--set", "f.count=99", "--json"])
                try expectEqual(badOption.code, 2)
                let events = try badOption.events()
                try expectEqual(events.count, 1, "exactly one line: the error"); try expectEqual(events[0]["event"] as? String, "error")
                try expectEqual(events[0]["code"] as? Int, 2); try expect((events[0]["message"] as? String ?? "").contains("f.count"))
                let parse = await rig.run(["convert", "--json"])
                try expectEqual(parse.code, 2); try expectEqual(try parse.events().first?["event"] as? String, "error", "a parse error answers in JSON when --json was given")
                let none = await rig.run([])
                try expectEqual(none.code, 2)
            }
        }

        t.register("cli.exit", "unavailable (3): a missing tool, input the operation does not take, an in-app action, a link operation") {
            try await rig { rig in
                let txt = try rig.file("t.txt")
                let tool = await rig.run(["convert", txt.path, "--op", "test.cli.unavailable", "--json"])
                try expectEqual(tool.code, 3)
                let err = try unwrap(try tool.event("error").first)
                try expectEqual(err["code"] as? Int, 3); try expect((err["message"] as? String ?? "").contains("Pandoc"), "the reason names the tool: \(err)")
                // The program disappears while the job runs: the job fails with exit 3 and the message names it; a batch where every file hits it says it once.
                let vanished = await rig.run(["convert", txt.path, "--op", "test.cli.vanished", "--json"])
                try expectEqual(vanished.code, 3, vanished.stderr)
                let verr = try unwrap(try vanished.event("error").first)
                try expectEqual(verr["code"] as? Int, 3); try expect((verr["message"] as? String ?? "").localizedCaseInsensitiveContains("pandoc"), "the message names the program: \(verr)")
                let second = try rig.file("t2.txt")
                let batch = await rig.run(["convert", txt.path, second.path, "--op", "test.cli.vanished"])
                try expectEqual(batch.code, 3, "every file hit the same missing program: \(batch.stderr)")
                try expectEqual(batch.stderr.lowercased().components(separatedBy: "pandoc").count - 1 <= 2, true, "the program is named once, not once per file: \(batch.stderr)")
                let wrong = await rig.run(["convert", txt.path, "--op", "test.cli.png"])
                try expectEqual(wrong.code, 3); try expect(wrong.stderr.contains("can’t process these files"), wrong.stderr)
                let action = await rig.run(["convert", txt.path, "--op", "test.cli.action"])
                try expectEqual(action.code, 3); try expect(action.stderr.contains("runs inside the app"), action.stderr)
                let png = try rig.fx.png("ok.png")
                let ok = await rig.run(["convert", png.path, "--op", "test.cli.png", "--quiet"])
                try expectEqual(ok.code, 0, "the same operation accepts a PNG: \(ok.stderr)")
            }
        }

        t.register("cli.exit", "partial (4): some files fail, the others are made; all fail (1); a single failing file (1)") {
            try await rig { rig in
                let good = try rig.file("good.txt", "fine"), bad = try rig.file("bad.txt")
                let partial = await rig.run(["convert", good.path, bad.path, "--op", "test.cli.flaky", "--json"])
                try expectEqual(partial.code, 4, partial.stdout)
                let done = try unwrap(try partial.event("done").first)
                try expectEqual(done["code"] as? Int, 4); try expectEqual((done["outputs"] as? [String])?.count, 1)
                let failures = try unwrap(done["failures"] as? [String])
                try expectEqual(failures.count, 1); try expect(failures[0].contains("bad.txt") && failures[0].contains("this input is bad"), failures[0])
                let human = await rig.run(["convert", good.path, bad.path, "--op", "test.cli.flaky"])
                try expectEqual(human.code, 4); try expectEqual(human.lines.count, 1, "stdout: only the file that was made")
                try expect(human.stderr.contains("Failed: bad.txt"), human.stderr)

                let bad2 = try rig.file("bad2.txt")
                let all = await rig.run(["convert", bad.path, bad2.path, "--op", "test.cli.flaky", "--json"])
                try expectEqual(all.code, 1, all.stdout)
                let e = try unwrap(try all.event("error").first)
                try expectEqual(e["code"] as? Int, 1); try expect((e["message"] as? String ?? "").contains("bad2.txt"), "\(e)")
                let single = await rig.run(["convert", bad.path, "--op", "test.cli.flaky"])
                try expectEqual(single.code, 1); try expect(single.stderr.contains("this input is bad"), single.stderr); try expect(single.stdout.isEmpty)
                try expect(TestFile.partials(in: rig.fx.root).isEmpty, "no partial files after failures")
            }
        }

        t.register("cli.exit", "cancelled (130): cancelling a running job ends the run with 130, an error event and no partial files") {
            try await rig { rig in
                let src = try rig.file("slow.txt")
                let started = Date()
                let running = Task { @MainActor in await rig.run(["convert", src.path, "--op", "test.slow", "--json"]) }
                try await expectEventually(timeout: 5) { rig.runner.jobs.contains { $0.state == .running } }
                CLI.requestCancel()
                let r = await running.value
                try expectEqual(r.code, 130, r.stdout + r.stderr)
                try expect(Date().timeIntervalSince(started) < 4, "cancellation is quick")
                let err = try unwrap(try r.event("error").last)
                try expectEqual(err["code"] as? Int, 130); try expect(try r.event("done").isEmpty, "a cancelled run has no done event")
                try expect(TestFile.partials(in: rig.fx.root).isEmpty, "no partial files")
                let stray = ((try? FileManager.default.contentsOfDirectory(atPath: rig.fx.root.path)) ?? []).filter { $0 != "slow.txt" && $0 != "presets" }
                try expect(stray.isEmpty, "nothing was written: \(stray)")
                try expect(rig.runner.jobs.allSatisfy { $0.state == .cancelled }, "the job ended as cancelled")
                // A later run is not affected by the earlier cancellation.
                let again = await rig.run(["convert", src.path, "--op", "test.cli.report", "--quiet"])
                try expectEqual(again.code, 0, again.stderr)
            }
        }

        t.register("cli.exit", "SIGINT cancels the running jobs and the run ends with 130 (the real signal handler, sent to this process)") {
            try await rig { rig in
                let src = try rig.file("sig.txt")
                let running = Task { @MainActor in await rig.run(["convert", src.path, "--op", "test.slow"], signals: true) }
                try await expectEventually(timeout: 5) { rig.runner.jobs.contains { $0.state == .running } }
                kill(getpid(), SIGINT)
                let r = await running.value
                try expectEqual(r.code, 130, r.stdout + r.stderr)
                try expect(r.stderr.contains("Canceled"), r.stderr)
                try expect(TestFile.partials(in: rig.fx.root).isEmpty, "no partial files")
            }
        }

        t.register("cli.exit", "a read-only output folder is a failure (1) with a calm message and no partial file") {
            try await rig { rig in
                let src = try rig.file("ro.txt")
                let ro = try rig.fx.makeDirectory("readonly")
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
                if FileManager.default.isWritableFile(atPath: ro.path) { try skipTest("this account can write into read-only folders") }
                let r = await rig.run(["convert", src.path, "--op", "test.cli.report", "--out", ro.path, "--json"])
                try expectEqual(r.code, 1, r.stdout)
                let e = try unwrap(try r.event("error").first)
                try expect((e["message"] as? String ?? "").contains("Cannot write"), "\(e)")
                try expect(((try? FileManager.default.contentsOfDirectory(atPath: ro.path)) ?? []).isEmpty, "nothing was left in the folder")
            }
        }

        t.register("cli.exit", "--lang ru answers in Russian and the language setting is restored afterwards") {
            try await rig { rig in
                let before = Loc.shared.setting
                let sink = CLISink()
                let code = await CLI.run(arguments: ["convert", "--lang", "ru", rig.fx.url("missing.txt").path, "--op", "test.cli.report"], environment: rig.environment, sink: sink)
                try expectEqual(code, 2)
                try expect(sink.stderr.contains("Нет такого файла"), sink.stderr)
                try expectEqual(Loc.shared.setting, before, "the language setting is restored")
                let help = await CLI.run(arguments: ["help", "--lang=ru"], environment: rig.environment, sink: sink)
                try expectEqual(help, 0); try expect(sink.stdout.contains("командная строка"), "the help is Russian")
                let en = await rig.run(["help", "--lang", "en"])
                try expect(en.stdout.contains("the command line of Swamp Converter"))
            }
        }

        t.register("cli.exit", "the run never opens a window or a network connection: the gate is closed for every command except download") {
            try await rig { rig in
                let saved = NetworkGate.forbidAll
                defer { NetworkGate.forbidAll = saved }
                NetworkGate.forbidAll = false
                _ = await rig.run(["list-ops", "--json"])
                try expectEqual(NetworkGate.forbidAll, false, "restored")
                // download without consent or tool never starts anything, whatever the gate says
                let r = await rig.run(["download", "https://example.com/video"])
                try expectEqual(r.code, 3, r.stderr)
                try expect(r.stdout.isEmpty)
            }
        }
    }
}
