import Foundation

// Core self-tests, part 5: the performance and size budgets that Core can prove on its own.
//   core.memory   after 200 jobs the footprint returns to within 10 MB of the start; nothing is retained per job
//   core.idle     no timer, display link or polling loop is armed at idle (source audit), and a quiet process really is quiet (CPU, wakeups)
//   core.perf     registration builds descriptors only (no process, no schema), building every wheel is cheap and starts nothing

/// The source audit of the "zero idle cost" rule. Pure functions over text so the rules themselves are tested with fixtures.
enum IdleAudit {
    struct Hit: Equatable { var file: String; var line: Int; var token: String; var text: String }

    /// Token name -> regular expression over comment- and string-free code.
    static let rules: [(token: String, pattern: String)] = [
        ("Timer", #"\bTimer\s*(\.|\()"#),
        ("NSTimer", #"\bNSTimer\b"#),
        ("DispatchSourceTimer", #"makeTimerSource|DispatchSourceTimer"#),
        ("CADisplayLink", #"\bCADisplayLink\b|\bCVDisplayLink\w*"#),
        ("repeatForever", #"\.repeatForever\b"#),
        ("TimelineView", #"\bTimelineView\b"#),
        ("repeats", #"repeats:\s*true"#),
        ("autoconnect", #"\.autoconnect\(\)"#)
    ]

    /// Files that may use a token, and why. A path matches when it ends with (or, for folders ending in "/", contains) the entry.
    /// `*` allows every token. Everything outside this list must stay event-driven.
    static let allowed: [(path: String, tokens: Set<String>, reason: String)] = [
        ("UI/Wheel/", ["Timer", "DispatchSourceTimer", "polling"], "the drag watcher polls the mouse button only while a drag is in progress"),
        ("Automation/", ["DispatchSourceTimer"], "the settle detector arms one-shot timers only while a file is still changing"),
        ("Core/JobRunner.swift", ["polling"], "waitUntilIdle is an on-demand helper for tests and scripts"),
        ("Core/ProcessRunner.swift", ["polling"], "SyncProcess.run waits for a short probe, never longer than its timeout"),
        ("CLI/", ["polling"], "a headless command waits for its own job (at most 10 Hz) and exits; the menu-bar app never runs this path"),
        ("Core/Tests/", ["*"], "tests"),
        ("Core/Conformance/", ["*"], "conformance harness (runs only under --self-test)"),
        ("Core/SelfTest.swift", ["*"], "test harness"),
        ("Core/Snapshots.swift", ["*"], "snapshot harness (runs only under --snapshot)"),
        ("Core/TestFixtures.swift", ["*"], "test fixtures")
    ]

    /// Self-test code (`ImageTestsFormat.swift`, `StudioCoreTests.swift`, `DownloaderTestKit.swift`, ...) is compiled into the binary but only runs under `--self-test`:
    /// its helpers may wait, poll and animate. Recognised by the file name, so a module cannot hide production code in a file that merely lives in a folder called Tests.
    static func isTestCode(path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return ["Tests", "TestKit", "TestSupport", "TestFixtures", "Conformance"].contains { name.contains($0) } || path.contains("Core/Tests/") || path.contains("Core/Conformance/")
            || name == "SelfTest.swift" || name == "Snapshots.swift"
    }

    static func isAllowed(path: String, token: String) -> Bool {
        if isTestCode(path: path) { return true }
        return allowed.contains { entry in
            let matches = entry.path.hasSuffix("/") ? path.contains(entry.path) : path.hasSuffix(entry.path)
            return matches && (entry.tokens.contains("*") || entry.tokens.contains(token))
        }
    }

    /// Replaces comments and the insides of string literals by spaces (newlines stay, so line numbers survive). Works on UTF-8 bytes: every delimiter is ASCII.
    static func stripCommentsAndStrings(_ source: String) -> String {
        let b = Array(source.utf8)
        var out = [UInt8](); out.reserveCapacity(b.count)
        let nl = UInt8(ascii: "\n"), sp = UInt8(ascii: " "), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), quote = UInt8(ascii: "\""), back = UInt8(ascii: "\\")
        enum Mode { case code, line, block, string, multiline }
        var mode = Mode.code
        var depth = 0
        var i = 0
        func blank(_ c: UInt8) -> UInt8 { c == nl ? nl : sp }
        func isTripleQuote(_ at: Int) -> Bool { at + 2 < b.count && b[at] == quote && b[at + 1] == quote && b[at + 2] == quote }
        while i < b.count {
            let c = b[i]
            let n: UInt8? = i + 1 < b.count ? b[i + 1] : nil
            switch mode {
            case .code:
                if c == slash && n == slash { mode = .line; out += [sp, sp]; i += 2; continue }
                if c == slash && n == star { mode = .block; depth = 1; out += [sp, sp]; i += 2; continue }
                if isTripleQuote(i) { mode = .multiline; out += [sp, sp, sp]; i += 3; continue }
                if c == quote { mode = .string; out.append(sp); i += 1; continue }
                out.append(c); i += 1
            case .line:
                if c == nl { mode = .code }
                out.append(blank(c)); i += 1
            case .block:
                if c == slash && n == star { depth += 1; out += [sp, sp]; i += 2; continue }
                if c == star && n == slash { depth -= 1; out += [sp, sp]; i += 2; if depth == 0 { mode = .code }; continue }
                out.append(blank(c)); i += 1
            case .string:
                if c == back, let n { out += [sp, blank(n)]; i += 2; continue }
                if c == quote || c == nl { mode = .code }
                out.append(blank(c)); i += 1
            case .multiline:
                if isTripleQuote(i) { mode = .code; out += [sp, sp, sp]; i += 3; continue }
                out.append(blank(c)); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static let compiledRules: [(token: String, regex: NSRegularExpression)] = rules.map { ($0.token, try! NSRegularExpression(pattern: $0.pattern)) }
    private static let loopRegex = try! NSRegularExpression(pattern: #"^\s*(while|repeat)\b|\bfor\s+await\b"#)
    private static let sleepRegex = try! NSRegularExpression(pattern: #"\bsleep\(|\busleep\(|Thread\.sleep|Task\.sleep"#)
    /// A file that contains none of these cannot violate a rule (cheap pre-filter; the regular expressions only run on the few files that do).
    private static let hints = ["Timer", "DisplayLink", "repeatForever", "Timeline", "autoconnect", "repeats:", "sleep("]

    private static func matches(_ re: NSRegularExpression, _ line: String) -> Bool {
        re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Every rule hit in `source`, plus "polling": a loop whose body (next 8 lines) sleeps.
    static func hits(in source: String, file: String) -> [Hit] {
        guard hints.contains(where: { source.contains($0) }) else { return [] }
        let original = source.components(separatedBy: "\n")
        let code = stripCommentsAndStrings(source).components(separatedBy: "\n")
        let mayPoll = source.contains("sleep(")
        var found: [Hit] = []
        for (n, line) in code.enumerated() where !line.isEmpty {
            func record(_ token: String) { found.append(Hit(file: file, line: n + 1, token: token, text: original[safe: n]?.trimmingCharacters(in: .whitespaces) ?? "")) }
            for rule in compiledRules where matches(rule.regex, line) { record(rule.token) }
            if mayPoll, line.contains("while") || line.contains("repeat") || line.contains("for await"), matches(loopRegex, line) {
                let window = code[(n + 1)..<min(code.count, n + 9)]
                if window.contains(where: { matches(sleepRegex, $0) }) { record("polling") }
            }
        }
        return found
    }

    /// The `Sources` folder of the project: `SC_PROJECT` (set by build.sh), the compile-time path of this file, or the working directory.
    static func sourcesFolder() -> URL? {
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["SC_PROJECT"] { candidates.append(URL(fileURLWithPath: p).appendingPathComponent("Sources")) }
        let me = "\(#filePath)"
        if me.hasPrefix("/") { candidates.append(URL(fileURLWithPath: me).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Core/Model.swift").path) }
    }

    static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return (walker.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" && !$0.lastPathComponent.hasPrefix("._") }.sorted { $0.path < $1.path }
    }
}

enum CoreTestsBudgets {
    static func register() {
        let t = SelfTestRegistry.shared

        // MARK: Memory

        t.register("core.memory", "after 200 jobs the footprint is back within 10 MB of the start; finished jobs, contexts and event buffers are not retained", timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let (runner, reg, _) = makeTestRunner(fx: fx, ops: [EchoOp()])
            runner.maxConcurrentOverride = 4
            let src = FileItem(url: try fx.text("a.txt", "x"))
            let op = try unwrap(reg.operation(id: "test.echo"))
            let payload = String(repeating: "payload ", count: 400)
            let deadSubscriber = runner.events()   // a UI that subscribed and never reads: its buffer must stay bounded
            @MainActor func run(_ count: Int) async {
                for _ in 0..<count { runner.submit(operation: op, items: [src], overrides: ["text": .string(payload)], mode: .automatic) }
                await runner.waitUntilIdle(timeout: 120)
            }

            await run(40)   // warm-up: lazily created singletons, malloc high-water mark
            runner.removeFinished(); runner.clearHistory()
            try await Task.sleep(nanoseconds: 300_000_000)
            let start = MemoryProbe.physFootprint()

            weak var watched: Job?
            for round in 0..<4 {
                await run(50)
                if round == 0 { watched = runner.jobs.last }
                try expect(runner.jobs.count <= JobRunner.finishedJobsKept, "in-memory jobs are capped at \(JobRunner.finishedJobsKept), have \(runner.jobs.count)")
            }
            let sample = try unwrap(runner.jobs.last)
            try expect(sample.context == nil && sample.task == nil, "a finished job holds no context and no task")
            try expect(sample.logLines.count < 50, "job logs stay small")
            runner.removeFinished()
            try expectEqual(runner.history.count, JobRunner.historyKept, "history capped at \(JobRunner.historyKept)")
            try await Task.sleep(nanoseconds: 300_000_000)
            let end = MemoryProbe.physFootprint()
            try expect(end - start < 10 * 1_048_576, "footprint grew from \(MemoryProbe.format(start)) to \(MemoryProbe.format(end)) after 200 jobs (budget: +10 MB)")
            out("      footprint after 200 jobs: \(MemoryProbe.format(start)) -> \(MemoryProbe.format(end)); OwnOutputs entries: \(OwnOutputs.shared.count)")
            try expect(watched == nil, "a finished, trimmed job is released: nothing (events, closures, history) keeps it alive")
            try expect(MessageCenter.shared.recent.count <= 50, "toast history capped")
            try expect(OwnOutputs.shared.count <= OwnOutputs.capacity, "loop-guard registry capped")
            _ = deadSubscriber
        }

        t.register("core.memory", "OwnOutputs stays bounded under a flood of outputs and still recognises recent ones") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let own = OwnOutputs.shared
            let first = fx.url("first.txt")
            own.register(first)
            for i in 0..<(OwnOutputs.capacity + 500) { own.register(URL(fileURLWithPath: "/tmp/flood/\(i).txt")) }
            try expect(own.count <= OwnOutputs.capacity, "bounded at \(OwnOutputs.capacity), have \(own.count)")
            try expect(own.contains(URL(fileURLWithPath: "/tmp/flood/\(OwnOutputs.capacity + 499).txt")), "the newest entries survive a prune")
        }

        // MARK: Idle audit

        t.register("core.idle", "the audit rules find timers, display links, forever animations and polling loops, and ignore comments and strings") {
            let sample = """
            // Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            let a = "Timer.scheduledTimer(" /* CADisplayLink */
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            let s = DispatchSource.makeTimerSource(queue: .main)
            let link = CADisplayLink(target: self, selector: #selector(x))
            view.animation(.easeInOut.repeatForever(autoreverses: true))
            TimelineView(.animation) { _ in }
            while !done {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let multi = \"\"\"
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            \"\"\"
            """
            let tokens = IdleAudit.hits(in: sample, file: "x.swift").map(\.token)
            try expectEqual(tokens.sorted(), ["DispatchSourceTimer", "CADisplayLink", "Timer", "TimelineView", "polling", "repeatForever", "repeats"].sorted())
            try expectEqual(IdleAudit.hits(in: sample, file: "x.swift").first { $0.token == "polling" }?.line, 8)
            try expect(IdleAudit.hits(in: "let x = 1 // while true { sleep(1) }\nlet y = \"Timer.scheduledTimer(\"\n", file: "y.swift").isEmpty)
            try expect(!IdleAudit.isAllowed(path: "Sources/UI/Shared/Components/SlantedProgressBar.swift", token: "repeatForever"), "the progress bar needs no forever animation, so it has no allowance")
            try expect(!IdleAudit.isAllowed(path: "Sources/UI/Wheel/DragWatcher.swift", token: "repeatForever"), "an allowance covers its own tokens only")
            try expect(!IdleAudit.isAllowed(path: "Sources/UI/Jobs/JobsModule.swift", token: "Timer"))
            try expect(IdleAudit.isAllowed(path: "Sources/UI/Wheel/DragWatcher.swift", token: "Timer"))
            try expect(IdleAudit.isAllowed(path: "Sources/CLI/CLIRuntime.swift", token: "polling"), "headless commands may wait for their own job")
            try expect(!IdleAudit.isAllowed(path: "Sources/CLI/CLIRuntime.swift", token: "Timer"), "but not arm a timer")
            try expect(IdleAudit.isAllowed(path: "Sources/UI/Studio/Core/StudioCoreTests.swift", token: "polling"), "self-test helpers may poll")
            try expect(IdleAudit.isAllowed(path: "Sources/Engines/Downloader/DownloaderTestKit.swift", token: "Timer"))
            try expect(!IdleAudit.isAllowed(path: "Sources/UI/Jobs/JobsTable.swift", token: "polling"), "production UI files get no allowance")
            try expect(!IdleAudit.isAllowed(path: "Sources/Engines/Image/ImageEncoder.swift", token: "repeatForever"))
        }

        t.register("core.idle", "no source file arms a timer, display link, forever animation or polling loop outside the documented allow-list") {
            guard let sources = IdleAudit.sourcesFolder() else { try skipTest("the source tree is not next to this binary") }
            var violations: [String] = []
            var allowedUses: [String] = []
            for file in IdleAudit.swiftFiles(under: sources) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let rel = String(file.path.dropFirst(sources.deletingLastPathComponent().path.count + 1))
                for hit in IdleAudit.hits(in: text, file: rel) {
                    if IdleAudit.isAllowed(path: rel, token: hit.token) {
                        if !IdleAudit.isTestCode(path: rel) { allowedUses.append("\(rel):\(hit.line) \(hit.token)") }
                    } else {
                        violations.append("\(rel):\(hit.line)  \(hit.token)  \(hit.text.prefix(90))")
                    }
                }
            }
            for u in allowedUses { out("      allowed: \(u)") }
            try expect(violations.isEmpty, "idle-cost violations (use events, or add a reasoned entry to IdleAudit.allowed):\n    " + violations.joined(separator: "\n    "))
        }

        t.register("core.idle", "a quiet process is quiet: negligible CPU and almost no wakeups over three seconds of doing nothing", timeout: 60) {
            // Everything the app arms at startup (the shared runner's environment monitor, settings, registration) is armed by now.
            _ = JobRunner.shared
            try await Task.sleep(nanoseconds: 500_000_000)
            let a = try unwrap(ResourceProbe.sample())
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let b = try unwrap(ResourceProbe.sample())
            let cpu = b.cpuSeconds - a.cpuSeconds
            let idle = Int(b.idleWakeups - a.idleWakeups), interrupts = Int(b.interruptWakeups - a.interruptWakeups)
            out("      3 s idle: cpu \(String(format: "%.1f", cpu * 1000)) ms, idle wakeups \(idle), interrupt wakeups \(interrupts)")
            try expect(cpu < 0.05, "idle CPU \(String(format: "%.1f", cpu * 1000)) ms in 3 s (budget: 0.1 percent = 3 ms; the test allows 50 ms for the harness itself)")
            try expect(idle <= 60, "\(idle) idle wakeups in 3 s: something is polling")
        }

        // MARK: Registration and launch

        t.register("core.perf", "registering every engine starts no process and builds no option schema; it stays far below the launch budget") {
            let s = EnginesBootstrap.registrationStats
            out("      registration: \(s.operations) operations in \(String(format: "%.1f", s.seconds * 1000)) ms, \(s.processesStarted) processes, footprint +\(MemoryProbe.format(s.footprintGrowth))")
            try expect(s.operations > 0, "the engines registered nothing")
            try expectEqual(s.processesStarted, 0, "registration must not start child processes (ffmpeg probing is lazy)")
            try expect(s.seconds < 0.15, "registration took \(String(format: "%.0f", s.seconds * 1000)) ms (debug build; the whole launch budget is 800 ms)")
            try expect(s.footprintGrowth < 40 * 1_048_576, "registration grew the footprint by \(MemoryProbe.format(s.footprintGrowth))")
        }

        t.register("core.perf", "building every wheel for typical inputs starts no process and costs a few milliseconds") {
            let reg = OperationRegistry.shared
            let settings = SettingsData()
            func file(_ name: String, folder: Bool = false) -> FileItem { FileItem(url: URL(fileURLWithPath: "/tmp/swamp-perf/\(name)"), isDirectory: folder) }
            let inputs: [[FileItem]] = [[file("a.png")], [file("a.jpg"), file("b.heic")], [file("a.pdf")], [file("clip.mp4")], [file("clip.mov"), file("b.mkv")],
                                        [file("song.mp3")], [file("a.docx")], [file("a.csv")], [file("a.zip")], [file("folder", folder: true)]]
            let link = [LinkItem(url: URL(string: "https://example.com/watch?v=abc")!)]
            func buildAll() {
                for items in inputs { for wheel in [WheelKind.convert, .tools, .actions] { _ = reg.entries(wheel: wheel, items: items, settings: settings) } }
                _ = reg.linkEntries(links: link, settings: settings)
            }
            buildAll()   // first call fills the tool-location caches
            let processes = ProcessStats.started
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rounds = 5
            for _ in 0..<rounds { buildAll() }
            let perWheel = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 / Double(rounds * (inputs.count * 3 + 1))
            out("      wheel entries: \(String(format: "%.3f", perWheel)) ms per wheel (debug build)")
            try expectEqual(ProcessStats.started, processes, "asking what a wheel offers must not start a process")
            try expect(perWheel < 5, "\(String(format: "%.2f", perWheel)) ms per wheel build (budget: the wheel appears within 80 ms of the drag)")
        }

        t.register("core.perf", "MemoryProbe, ResourceProbe and LaunchClock read plausible numbers") {
            let fp = MemoryProbe.physFootprint(), rss = MemoryProbe.residentSize()
            try expect(fp > 1_048_576 && fp < 4_000 * 1_048_576, "footprint \(MemoryProbe.format(fp))")
            try expect(rss > 1_048_576 && rss < 8_000 * 1_048_576, "rss \(MemoryProbe.format(rss))")
            out("      this test process: footprint \(MemoryProbe.format(fp)), resident \(MemoryProbe.format(rss)) (debug build with every test framework loaded)")
            let r = try unwrap(ResourceProbe.sample()); try expect(r.cpuSeconds > 0)
            let start = try unwrap(LaunchClock.processStart); try expect(start < Date() && Date().timeIntervalSince(start) < 3600, "process start time")
            let first = try unwrap(LaunchClock.markReady()); try expect(first > 0 && first < 3600)
            try expectEqual(LaunchClock.markReady(), LaunchClock.elapsedUntilReady, "the first call wins")
        }
    }
}
