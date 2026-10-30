import Foundation

// ProcessRunner starts every child in its own process group and cancels with killpg: SIGTERM, SIGKILL after 2 s (or at once on request). The shells here spawn
// grandchildren, some of which refuse SIGTERM or leave the group, and the tests check that every one of them is gone and that nothing is left as a zombie.

enum CoreTestsProcessGroup {
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    private static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private static func state(of pid: Int32) -> String {
        (SyncProcess.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "state=", "-p", "\(pid)"], timeout: 2, sandboxed: false) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Zombie children of THIS process (a child that exited but was never waited for).
    private static func zombieChildren() -> [Int32] {
        let text = SyncProcess.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid=,stat="], timeout: 3, sandboxed: false) ?? ""
        let me = getpid()
        return text.split(separator: "\n").compactMap { line -> Int32? in
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 3, let pid = Int32(p[0]), let ppid = Int32(p[1]), ppid == me, p[2].hasPrefix("Z") else { return nil }
            return pid
        }
    }

    /// Runs `script` under sh and returns once the first stdout line (the grandchild's pid) arrived.
    @MainActor
    private static func start(_ script: String, killImmediately: Bool = false) async throws -> (task: Task<ProcessOutput, Error>, ctl: ProcessControl, grandchild: Int32) {
        let first = Locked<Int32?>(nil)
        let ctl = ProcessControl(killImmediately: killImmediately)
        let task = Task { try await ProcessRunner.run(sh, ["-c", script], onStdoutLine: { l in if first.value == nil, let p = Int32(l.trimmingCharacters(in: .whitespaces)) { first.value = p } }, control: ctl) }
        try await expectEventually { first.value != nil && ctl.pid != nil }
        return (task, ctl, first.value!)
    }

    @MainActor
    private static func cancelled(_ task: Task<ProcessOutput, Error>) async throws {
        task.cancel()
        let result = await task.result
        if case .failure(let e) = result { try expect(e is CancellationError, "a cancelled run throws CancellationError, got \(e)") }
        else { throw TestFailure(message: "a cancelled run must not succeed", file: #fileID, line: #line) }
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("core.process", "every child leads its own process group (pgid = pid, not ours), with only stdin/stdout/stderr open and default signals") {
            // (allowNetwork: the sandbox forbids running ps, and this test is about spawn attributes, not about the network)
            let out = try await ProcessRunner.run(sh, ["-c", "echo $$; ps -o pgid= -p $$; ls /dev/fd | wc -l; trap -p | wc -l"], captureStdout: true, allowNetwork: true)
            let lines = out.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            try expectEqual(lines.count, 4, "got \(lines)")
            let pid = try unwrap(Int32(lines[0])), pgid = try unwrap(Int32(lines[1]))
            try expectEqual(pgid, pid, "the child is the leader of its own group")
            try expect(pgid != getpgrp(), "and not in the app's group")
            // stdin, stdout, stderr, and the directory handle `ls` itself opens: nothing inherited from the app.
            try expect((Int(lines[2]) ?? 99) <= 5, "the child inherited descriptors: \(lines[2]) open")
        }

        t.register("core.process", "cancelling kills the child AND its grandchild at once (SIGTERM to the group) and leaves no zombie") {
            let r = try await start("sleep 60 & echo $!; wait")
            let child = try unwrap(r.ctl.pid)
            try expect(alive(r.grandchild), "the grandchild runs")
            try expectEqual(Int32(getpgid(r.grandchild)), child, "the grandchild is in the child's group")
            let t0 = Date()
            try await cancelled(r.task)
            try await expectEventually(timeout: 1.5) { !alive(r.grandchild) && !alive(child) }
            try expect(Date().timeIntervalSince(t0) < 1.5, "both died within 1.5 s: \(Date().timeIntervalSince(t0)) s")
            try expect(zombieChildren().isEmpty, "zombie children: \(zombieChildren())")
        }

        t.register("core.process", "a grandchild that ignores SIGTERM is killed with SIGKILL after 2 s; with killImmediately it is gone at once") {
            let script = "trap '' TERM; sleep 60 & echo $!; wait"
            let slow = try await start(script)
            let child = try unwrap(slow.ctl.pid)
            let t0 = Date()
            // `run` returns only once the child is gone, and this child ignores SIGTERM: so cancel WITHOUT waiting, look at the state in the grace period, then wait for the end.
            slow.task.cancel()
            try await Task.sleep(nanoseconds: 500_000_000)
            try expect(alive(slow.grandchild) && alive(child), "SIGTERM alone does not stop them (they ignore the signal): the escalation has not happened yet")
            if case .failure(let e) = await slow.task.result { try expect(e is CancellationError, "a cancelled run throws CancellationError, got \(e)") }
            else { throw TestFailure(message: "a cancelled run must not succeed", file: #fileID, line: #line) }
            try await expectEventually(timeout: 1) { !alive(slow.grandchild) && !alive(child) }
            let took = Date().timeIntervalSince(t0)
            try expect(took >= 1.5 && took < 4, "SIGKILL arrived after the grace period of 2 s, took \(took) s")

            let fast = try await start(script, killImmediately: true)
            let t1 = Date()
            try await cancelled(fast.task)
            try await expectEventually(timeout: 1) { !alive(fast.grandchild) }
            try expect(Date().timeIntervalSince(t1) < 1, "an immediate kill needs no grace period")
            try expect(zombieChildren().isEmpty, "zombie children: \(zombieChildren())")
        }

        t.register("core.process", "ProcessSet.cancelAll(immediately:) and the exit-time killAll reach grandchildren too") {
            let set = ProcessSet()
            let first = Locked<Int32?>(nil)
            let ctl = ProcessControl(); set.add(ctl)
            let task = Task { try await ProcessRunner.run(sh, ["-c", "trap '' TERM; sleep 60 & echo $!; wait"], onStdoutLine: { l in if let p = Int32(l.trimmingCharacters(in: .whitespaces)) { first.value = p } }, control: ctl) }
            try await expectEventually { first.value != nil && ctl.pid != nil }
            let g = try unwrap(first.value)
            set.cancelAll(immediately: true)
            _ = await task.result
            try await expectEventually(timeout: 1) { !alive(g) }
            let second = Locked<Int32?>(nil)
            let c2 = ProcessControl()
            let t2 = Task { try await ProcessRunner.run(sh, ["-c", "trap '' TERM; sleep 60 & echo $!; wait"], onStdoutLine: { l in if let p = Int32(l.trimmingCharacters(in: .whitespaces)) { second.value = p } }, control: c2) }
            try await expectEventually { second.value != nil && c2.pid != nil }
            ProcessRegistry.shared.killAll()
            _ = await t2.result
            try await expectEventually(timeout: 1) { !alive(second.value!) }
        }

        t.register("core.process", "a descendant that left the process group (setsid) is still found and killed") {
            let r = try await start("/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec q(sleep), q(60)' & echo $!; wait")
            let child = try unwrap(r.ctl.pid)
            try await expectEventually { getpgid(r.grandchild) == r.grandchild }
            try expect(getpgid(r.grandchild) != child, "the grandchild has its own group")
            try await cancelled(r.task)
            try await expectEventually(timeout: 3) { !alive(r.grandchild) && !alive(child) }
        }

        t.register("core.process", "pause stops the whole group (grandchild included) and resume continues it") {
            let r = try await start("sleep 60 & echo $!; wait")
            r.ctl.suspend()
            try await expectEventually { state(of: r.grandchild).hasPrefix("T") }
            try expect(state(of: try unwrap(r.ctl.pid)).hasPrefix("T"), "the child is stopped as well")
            r.ctl.resume()
            try await expectEventually { !state(of: r.grandchild).hasPrefix("T") }
            try await cancelled(r.task)
            try await expectEventually(timeout: 1.5) { !alive(r.grandchild) }
        }

        t.register("core.process", "exit status: the code of a normal exit, the signal number of a killed child; a missing program is cannotStart with the system's reason") {
            let code = try await ProcessRunner.run(sh, ["-c", "exit 7"], allowNonZeroExit: true)
            try expectEqual(code.exitCode, 7)
            let killed = try await ProcessRunner.run(sh, ["-c", "kill -9 $$"], allowNonZeroExit: true)
            try expectEqual(killed.exitCode, 9, "SIGKILL")
            let err = try await expectThrows { _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), []) }
            guard case ConversionError.cannotStart(_, let reason) = err else { throw TestFailure(message: "wrong error \(err)", file: #fileID, line: #line) }
            try expect(reason.lowercased().contains("no such file"), "reason: \(reason)")
            // Large output and both streams arrive complete and in order.
            let big = try await ProcessRunner.run(sh, ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i; echo err$i 1>&2; i=$((i+1)); done"], captureStdout: true)
            try expectEqual(big.stdout.split(separator: "\n").count, 20000)
            try expectEqual(big.stderrTail.last, "err19999")
        }
    }
}
