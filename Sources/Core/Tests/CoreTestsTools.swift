import Foundation

// Core self-tests, part 4: where tools are found (with fake tools in a temp folder, never depending on what is installed), what child processes
// see, how a paused job treats its processes, and how the runner follows the environment (Low Power Mode, battery, free disk space).

/// Records what a job's task looked like while it ran (QoS, background flag, hardware preference).
final class ProbeOp: PerFileOperation, @unchecked Sendable {
    struct Probe: Sendable { var job: UUID; var priority: TaskPriority; var background: Bool; var hardware: Bool; var mode: RunMode }
    let probes = Locked<[Probe]>([])
    init() { super.init(meta: .make("test.probe", .tools, .app, L10n("Probe"), symbol: "scope", schema: "test.probe", suffix: L10n("probe"), anyFile: true)) }
    func probe(for job: Job) -> Probe? { probes.value.first { $0.job == job.id } }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        probes.withLock { $0.append(Probe(job: ctx.jobID, priority: Task.currentPriority, background: ctx.isBackground, hardware: ctx.preferHardware, mode: ctx.mode)) }
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { try "p".write(to: $0, atomically: false, encoding: .utf8) }
        progress.report(1)
        return [url]
    }
}

/// Claims to need `bytes` of output (what the free-space preflight reads) and writes a tiny file.
final class SizedOp: PerFileOperation, @unchecked Sendable {
    let bytes: Int64
    init(bytes: Int64) {
        self.bytes = bytes
        super.init(meta: .make("test.sized", .tools, .app, L10n("Sized"), symbol: "externaldrive", schema: "test.sized", suffix: L10n("sized"), anyFile: true))
    }
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? { OperationEstimate(bytes: bytes) }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { try "s".write(to: $0, atomically: false, encoding: .utf8) }
        progress.report(1)
        return [url]
    }
}

enum CoreTestsTools {
    /// An executable shell script that prints "fake <version>" and a second line, or a plain file without the execute bit.
    @discardableResult
    private static func fakeTool(_ dir: URL, _ name: String, version: String, executable: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho 'fake \(version)'\necho second line\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private static func state(of pid: Int32) -> String {
        (SyncProcess.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "state=", "-p", "\(pid)"], timeout: 2, sandboxed: false) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func register() {
        let t = SelfTestRegistry.shared

        // MARK: ToolLocator

        t.register("core.tools", "search order: user override, bundled, user folder, well-known folders, PATH; non-executables, folders and empty overrides are ignored") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let bundled = fx.url("bundled"), user = fx.url("user"), known = fx.url("homebrew-bin"), onPath = fx.url("pathdir")
            let loc = ToolLocator(roots: ToolSearchRoots(bundled: .folder(bundled.path), userFolder: .folder(user.path), wellKnown: [known.path],
                                                         extraDirectories: false, path: .folder(onPath.path + ":" + fx.url("elsewhere").path)))
            try expect(loc.find(.ffmpeg) == nil && !loc.has(.ffmpeg), "nothing installed in the fake roots")
            try expectEqual(loc.missing([.ffmpeg, .sips]), [.ffmpeg], "built-in macOS tools are always present")

            try fakeTool(onPath, "ffmpeg", version: "path"); loc.refresh()
            try expectEqual(loc.find(.ffmpeg)?.source, .path)
            try fakeTool(known, "ffmpeg", version: "known"); loc.refresh()
            try expectEqual(loc.find(.ffmpeg)?.source, .homebrew, "a well-known folder beats PATH (a GUI app has a minimal PATH)")
            try fakeTool(user, "ffmpeg", version: "user"); loc.refresh()
            try expectEqual(loc.find(.ffmpeg)?.source, .userFolder, "the tools folder next to the app beats Homebrew")
            let b = try fakeTool(bundled, "ffmpeg", version: "bundled"); loc.refresh()
            try expectEqual(loc.find(.ffmpeg)?.source, .bundled); try expectEqual(loc.find(.ffmpeg)?.path, b.path)

            let mine = try fakeTool(fx.url("custom"), "my-ffmpeg", version: "override")
            loc.setUserOverrides(["ffmpeg": mine.path])
            try expectEqual(loc.find(.ffmpeg)?.source, .userOverride); try expectEqual(loc.find(.ffmpeg)?.path, mine.path)
            let plain = try fakeTool(fx.url("custom"), "not-executable", version: "x", executable: false)
            loc.setUserOverrides(["ffmpeg": plain.path])
            try expectEqual(loc.find(.ffmpeg)?.source, .bundled, "an override without the execute bit falls through")
            loc.setUserOverrides(["ffmpeg": fx.url("custom").path])
            try expectEqual(loc.find(.ffmpeg)?.source, .bundled, "an override that is a folder falls through")
            loc.setUserOverrides(["ffmpeg": ""])
            try expectEqual(loc.find(.ffmpeg)?.source, .bundled, "an empty override means none")
            loc.setUserOverrides(["sips": mine.path])
            try expectEqual(loc.find(.sips)?.path, "/usr/bin/sips", "built-in tools cannot be redirected")
            loc.setUserOverrides([:])

            try FileManager.default.removeItem(at: b); loc.refresh()
            try expectEqual(loc.find(.ffmpeg)?.source, .userFolder, "removing a tool moves the lookup to the next folder after refresh")
            try FileManager.default.createDirectory(at: onPath.appendingPathComponent("qjs"), withIntermediateDirectories: true); loc.refresh()
            try expect(loc.find(.quickjs) == nil, "a directory named like the tool is not a tool")
        }

        t.register("core.tools", "yt-dlp is found under both release names (yt-dlp first); version is the first output line and is cached; require throws for a missing tool") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let user = fx.url("user")
            let loc = ToolLocator(roots: ToolSearchRoots(bundled: .none, userFolder: .folder(user.path), wellKnown: [], extraDirectories: false, path: .none))
            try fakeTool(user, "yt-dlp_macos", version: "2026.01.01"); loc.refresh()
            try expectEqual(loc.find(.ytdlp)?.url.lastPathComponent, "yt-dlp_macos", "the name of the official release asset is found")
            try fakeTool(user, "yt-dlp", version: "2026.02.02"); loc.refresh()
            try expectEqual(loc.find(.ytdlp)?.url.lastPathComponent, "yt-dlp", "the plain name wins when both exist")
            try expectEqual(loc.version(of: .ytdlp), "fake 2026.02.02", "first line of --version")
            try fakeTool(user, "yt-dlp", version: "changed")
            try expectEqual(loc.version(of: .ytdlp), "fake 2026.02.02", "the version is cached per path until refresh")
            loc.refresh()
            try expectEqual(loc.version(of: .ytdlp), "fake changed")
            try expect(loc.version(of: .sips) == nil, "built-in tools have no version probe")
            let err = try await expectThrows { _ = try loc.require(.pandoc) }
            guard case ConversionError.toolMissing(let tool) = err else { throw TestFailure(message: "expected toolMissing, got \(err)", file: #fileID, line: #line) }
            try expectEqual(tool, .pandoc)
            try expectEqual(try loc.require(.ytdlp).lastPathComponent, "yt-dlp")
        }

        t.register("core.tools", "a version probe that overlaps a refresh (the tool was just replaced) neither returns nor caches the old file's answer") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let user = fx.url("user"), marker = fx.url("probe-started")
            let loc = ToolLocator(roots: ToolSearchRoots(bundled: .none, userFolder: .folder(user.path), wellKnown: [], extraDirectories: false, path: .none))
            func write(_ body: String) throws {
                try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
                let url = user.appendingPathComponent("yt-dlp")
                try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            // One line, so the running shell has read all of it before the file is replaced; it says when it is running.
            try write("touch '\(marker.path)'; sleep 0.5; echo 'fake old'"); loc.refresh()
            let probe = Task.detached { loc.version(of: .ytdlp) }
            for _ in 0..<80 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 50_000_000) }
            try expect(FileManager.default.fileExists(atPath: marker.path), "the old tool is running its --version")
            try write("echo 'fake new'"); loc.refresh()          // the update lands and the lookups are cleared
            let answer = await probe.value
            try expectEqual(answer, "fake new", "the probe that started before the refresh answers for the file that is there now")
            try expectEqual(loc.version(of: .ytdlp), "fake new", "and the cache holds the new answer")
        }

        t.register("core.tools", "child processes get a controlled PATH (tool folders + system folders), a UTF-8 locale and caller extras that win") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let user = fx.url("user"), known = fx.url("known")
            try fakeTool(user, "flac", version: "x"); try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
            let loc = ToolLocator(roots: ToolSearchRoots(bundled: .none, userFolder: .folder(user.path), wellKnown: [known.path], extraDirectories: false, path: .none))
            let dirs = loc.childPath.split(separator: ":").map(String.init)
            try expect(dirs.contains(known.path), "existing well-known folders are on the path")
            try expect(dirs.contains(user.path), "the folder of every located tool is on the path")
            try expectEqual(Array(dirs.suffix(4)), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"], "system folders come last")
            try expectEqual(dirs.count, Set(dirs).count, "no duplicates")
            let env = loc.childEnvironment(extra: ["LANG": "ru_RU.UTF-8", "SWAMP_X": "1"])
            try expectEqual(env["LC_ALL"], "en_US.UTF-8"); try expectEqual(env["LANG"], "ru_RU.UTF-8", "extras win"); try expectEqual(env["SWAMP_X"], "1")
            try expectEqual(env["PATH"], loc.childPath)
        }

        // MARK: ProcessRunner environment and pause

        t.register("core.process", "a real child sees the controlled environment and finds a tool placed in the user's tools folder by name") {
            guard AppPaths.supportDir.path.contains("selftest-") else { try skipTest("only runs in the isolated self-test home") }
            let tool = AppPaths.userToolsDir.appendingPathComponent("qjs")
            try "#!/bin/sh\necho fake-qjs-ran\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            ToolLocator.shared.refresh()
            defer { try? FileManager.default.removeItem(at: tool); ToolLocator.shared.refresh() }
            let env = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), [], environment: ["SWAMP_TEST_VALUE": "yes"], captureStdout: true)
            var vars: [String: String] = [:]
            for line in env.stdout.split(separator: "\n") { if let eq = line.firstIndex(of: "=") { vars[String(line[..<eq])] = String(line[line.index(after: eq)...]) } }
            try expectEqual(vars["SWAMP_TEST_VALUE"], "yes"); try expectEqual(vars["LC_ALL"], "en_US.UTF-8")
            try expect(vars["PATH"]?.split(separator: ":").map(String.init).contains(AppPaths.userToolsDir.path) == true, "the user tools folder is on the child's PATH")
            let found = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), ["qjs"], captureStdout: true)
            try expectEqual(found.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "fake-qjs-ran", "the child resolves the tool through its PATH")
            let missing = try await expectThrows { _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), []) }
            guard case ConversionError.cannotStart = missing else { throw TestFailure(message: "a missing executable must be cannotStart, got \(missing)", file: #fileID, line: #line) }
        }

        t.register("core.process", "a paused job's processes start suspended; resuming lets them finish; cancelling a suspended process still ends it") {
            let paused = ProcessSet()
            paused.suspendAll()
            let ctl = ProcessControl(); paused.add(ctl)
            let run = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["1"], control: ctl) }
            try await expectEventually { ctl.pid != nil }
            let pid = try unwrap(ctl.pid)
            try await Task.sleep(nanoseconds: 200_000_000)
            try expect(state(of: pid).hasPrefix("T"), "started while the job was paused: the process is stopped, not running (state \(state(of: pid)))")
            paused.resumeAll()
            _ = try await run.value
            try expect(!ctl.isSuspended)

            let set = ProcessSet()
            let c2 = ProcessControl(); set.add(c2)
            let long = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["60"], control: c2) }
            try await expectEventually { c2.pid != nil }
            let pid2 = try unwrap(c2.pid)
            set.suspendAll()
            try expect(state(of: pid2).hasPrefix("T"), "pause stops a running process")
            let t0 = Date()
            set.cancelAll()
            let result = await long.result
            if case .failure(let e) = result { try expect(e is CancellationError, "cancel must surface as CancellationError, got \(e)") } else { throw TestFailure(message: "a cancelled run must not succeed", file: #fileID, line: #line) }
            try expect(Date().timeIntervalSince(t0) < 3, "cancel ends a suspended process promptly")
            try await expectEventually(timeout: 3) { kill(pid2, 0) != 0 }
        }

        // MARK: Scheduler end to end

        t.register("core.scheduler", "the runner follows the environment: Low Power Mode lowers parallel jobs, lifting it starts the waiting ones at once, and the Mac stays awake only while jobs run") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let saved = SystemEnvironment.override; defer { SystemEnvironment.override = saved }
            SystemEnvironment.override = SystemEnvironment(cores: 14, performanceCores: 10, thermal: .nominal, lowPowerMode: true, onBattery: false)
            var settings = SettingsData(); settings.maxConcurrentJobs = 4
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [SlowOp()], settings: settings)
            let src = FileItem(url: try fx.text("a.txt", "x"))
            let slow = try unwrap(reg.operation(id: "test.slow"))
            _ = (0..<4).map { _ in runner.submit(operation: slow, items: [src], mode: .studio) }
            try await expectEventually { runner.summary.running == 2 }
            try expectEqual(runner.summary.waiting, 2, "Low Power Mode halves four parallel jobs to two")
            try expect(SleepGuard.shared.isHolding, "the Mac may not idle-sleep while a job runs")

            SystemEnvironment.override?.lowPowerMode = false
            SystemEnvironmentMonitor.shared.notifyChange()
            try await expectEventually { runner.summary.running == 4 }
            SystemEnvironment.override?.thermal = .serious
            runner.cancelAll()
            try await expectEventually { runner.jobs.allSatisfy { $0.state.isFinished } }
            try expect(!SleepGuard.shared.isHolding, "released the moment nothing runs")
            try expectEqual(runner.maxConcurrent, 1, "a seriously hot Mac runs one job at a time")
        }

        t.register("core.scheduler", "unattended jobs wait on battery while the setting is on and start when the power source or the setting changes; priority and hardware preference follow the origin") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let saved = SystemEnvironment.override; defer { SystemEnvironment.override = saved }
            SystemEnvironment.override = SystemEnvironment(cores: 14, performanceCores: 10, thermal: .nominal, lowPowerMode: false, onBattery: true)
            var settings = SettingsData(); settings.pauseBackgroundOnBattery = true
            let probe = ProbeOp()
            let (runner, _, s) = makeTestRunner(fx: fx, ops: [probe], settings: settings)
            let src = FileItem(url: try fx.text("a.txt", "x"))
            let watch = runner.submit(operation: probe, items: [src], origin: .watch, mode: .automatic)
            let hand = runner.submit(operation: probe, items: [src], origin: .wheel, mode: .quick)
            try await expectEventually { hand.state == .done }
            try expectEqual(watch.state, .waiting, "the watched-folder job waits while on battery")
            try expectEqual(probe.probe(for: hand)?.priority, .userInitiated, "the job the person waits for runs at user-initiated QoS")
            try expectEqual(probe.probe(for: hand)?.hardware, true, "on battery hardware encoders are preferred")
            try expectEqual(probe.probe(for: hand)?.background, false)

            SystemEnvironment.override?.onBattery = false
            SystemEnvironmentMonitor.shared.notifyChange()
            try await expectEventually { watch.state == .done }
            try expectEqual(probe.probe(for: watch)?.priority, .utility); try expectEqual(probe.probe(for: watch)?.background, true)
            try expectEqual(probe.probe(for: watch)?.hardware, false, "plugged in and cool: no forced hardware preference")

            SystemEnvironment.override?.onBattery = true
            let again = runner.submit(operation: probe, items: [src], origin: .chain, mode: .automatic)
            try await Task.sleep(nanoseconds: 100_000_000)
            try expectEqual(again.state, .waiting)
            s.update { $0.pauseBackgroundOnBattery = false }
            try await expectEventually { again.state == .done }
        }

        t.register("core.jobs", "the free-space preflight refuses a job that cannot fit, warns when it is tight, and can be switched off") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let op = SizedOp(bytes: 5_000_000_000)
            let (runner, _, s) = makeTestRunner(fx: fx, ops: [op])
            let src = FileItem(url: try fx.text("big.txt", "x"))
            defer { DiskSpaceGuard.availableOverride = nil }

            DiskSpaceGuard.availableOverride = { _ in 1_000_000_000 }
            let refused = runner.submit(operation: op, items: [src])
            try await expectEventually { refused.state.isFinished }
            try expectEqual(refused.state, .failed)
            try expect(refused.errorMessage?.contains("Not enough free space") == true || refused.errorMessage?.contains("Не хватает места") == true, "calm message: \(refused.errorMessage ?? "-")")
            try expect(refused.outputs.isEmpty && TestFile.partials(in: fx.root).isEmpty, "nothing was started")

            DiskSpaceGuard.availableOverride = { _ in 5_500_000_000 }
            let tight = runner.submit(operation: op, items: [src])
            try await expectEventually { tight.state.isFinished }
            try expectEqual(tight.state, .done); try expect(tight.logText.contains("WARNING"), "a tight disk is mentioned in the job log")

            DiskSpaceGuard.availableOverride = { _ in 1_000_000_000 }
            s.update { $0.freeSpaceGuard = false }
            let off = runner.submit(operation: op, items: [src])
            try await expectEventually { off.state.isFinished }
            try expectEqual(off.state, .done, "with the guard off the job simply runs")
        }
    }
}
