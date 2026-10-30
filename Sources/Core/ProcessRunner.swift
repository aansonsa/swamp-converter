import Foundation

// Async wrapper around Foundation.Process.
//  * arguments are ALWAYS an array (never a shell string -> no injection)
//  * stdin is /dev/null, stdout/stderr are streamed line by line (split on \n AND \r: ffmpeg stats use \r)
//  * every child leads its own process group (posix_spawn, see ProcessSpawn): Task cancellation sends SIGTERM to the whole group at once, then SIGKILL
//    after 2 s (or SIGKILL straight away when asked: x265 / ffmpeg encoders that hold on to the CPU), and the child is always reaped
//  * non-zero exit throws ConversionError.toolFailed with the last meaningful stderr lines
//  * suspend/resume (SIGSTOP/SIGCONT) through ProcessControl for the queue's Pause

struct ProcessOutput: Sendable {
    var exitCode: Int32
    var stdout: String
    /// Last 15 stderr lines (noise filtered).
    var stderrTail: [String]
}

/// Handle to one running child process: pause, resume, cancel. Created by the caller (usually via
/// `OperationContext.runProcess`) and passed to `ProcessRunner.run(control:)`.
final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    /// Pid of the running child, which is also its process group id; 0 when none runs.
    private var child: pid_t = 0
    private var cancelRequested = false
    private var suspended = false
    private var killImmediately = false

    var pid: Int32? { lock.lock(); defer { lock.unlock() }; return child > 0 ? child : nil }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }
    var isSuspended: Bool { lock.lock(); defer { lock.unlock() }; return suspended }

    /// Cancelling kills with SIGKILL at once instead of asking with SIGTERM first (for encoders that finish their current frame group before obeying SIGTERM).
    init(killImmediately: Bool = false) { self.killImmediately = killImmediately }

    func attach(pid: pid_t) {
        lock.lock(); child = pid; let c = cancelRequested; let wasSuspended = suspended; lock.unlock()
        ProcessRegistry.shared.add(self)
        if c { cancel(); return }
        // The job was paused before this process started (pause pressed between registering the control and launching it): it must not run.
        if wasSuspended { killpg(pid, SIGSTOP) }
    }

    func detach() {
        lock.lock(); child = 0; lock.unlock()
        ProcessRegistry.shared.remove(self)
    }

    /// Signals the whole group of the child, plus any descendant that left the group on its own (found with `ps` BEFORE the signal, while it is still a descendant).
    private func send(_ sig: Int32, to pid: pid_t, outside: [pid_t]) {
        killpg(pid, sig)
        for d in outside { kill(d, sig) }
    }

    /// Terminates the process and all its descendants: SIGTERM to the process group, SIGKILL two seconds later for whatever is still there
    /// (or SIGKILL at once with `immediately`, or when the control was created with `killImmediately`).
    func cancel(immediately: Bool = false) {
        lock.lock(); cancelRequested = true; let pid = child; let wasSuspended = suspended; let now = immediately || killImmediately; lock.unlock()
        guard pid > 0 else { return }
        let outside = ProcessTree.descendants(of: pid).filter { getpgid($0) != pid }
        if wasSuspended { send(SIGCONT, to: pid, outside: outside) }
        if now { send(SIGKILL, to: pid, outside: outside); return }
        send(SIGTERM, to: pid, outside: outside)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // killpg(pid, 0) succeeds only while some member of the group is alive: a finished group is not signalled (no pid reuse accident).
            if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
            for d in outside where kill(d, 0) == 0 { kill(d, SIGKILL) }
        }
    }

    private func members() -> (pid: pid_t, outside: [pid_t])? {
        lock.lock(); let pid = child; lock.unlock()
        guard pid > 0 else { return nil }
        return (pid, ProcessTree.descendants(of: pid).filter { getpgid($0) != pid })
    }

    func suspend() {
        lock.lock(); suspended = true; lock.unlock()
        guard let m = members() else { return }
        send(SIGSTOP, to: m.pid, outside: m.outside)
    }

    func resume() {
        lock.lock(); suspended = false; lock.unlock()
        guard let m = members() else { return }
        send(SIGCONT, to: m.pid, outside: m.outside)
    }
}

/// Every live child process of the app. `killAll()` runs at exit so no tool is ever left running.
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var controls: [ObjectIdentifier: ProcessControl] = [:]

    func add(_ c: ProcessControl) { lock.lock(); controls[ObjectIdentifier(c)] = c; lock.unlock() }
    func remove(_ c: ProcessControl) { lock.lock(); controls[ObjectIdentifier(c)] = nil; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return controls.count }

    /// At exit: every tool dies NOW (SIGKILL to its group), because there is no later in which a delayed SIGKILL could still run.
    func killAll() {
        lock.lock(); let all = Array(controls.values); lock.unlock()
        all.forEach { $0.cancel(immediately: true) }
    }
}

/// A group of ProcessControls that belong to one job: the queue pauses/resumes/cancels them together.
final class ProcessSet: @unchecked Sendable {
    private let lock = NSLock()
    private var controls: [ObjectIdentifier: ProcessControl] = [:]
    private var paused = false

    func add(_ c: ProcessControl) {
        lock.lock(); controls[ObjectIdentifier(c)] = c; let p = paused; lock.unlock()
        if p { c.suspend() }
    }
    func remove(_ c: ProcessControl) { lock.lock(); controls[ObjectIdentifier(c)] = nil; lock.unlock() }
    func suspendAll() { lock.lock(); paused = true; let all = Array(controls.values); lock.unlock(); all.forEach { $0.suspend() } }
    func resumeAll() { lock.lock(); paused = false; let all = Array(controls.values); lock.unlock(); all.forEach { $0.resume() } }
    func cancelAll(immediately: Bool = false) { lock.lock(); let all = Array(controls.values); lock.unlock(); all.forEach { $0.cancel(immediately: immediately) } }
}

enum ProcessTree {
    /// Descendant pids of `pid` (children, grandchildren, ...), found with `ps`. Empty when `ps` fails.
    static func descendants(of pid: Int32) -> [Int32] {
        guard let out = SyncProcess.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid="], timeout: 2, sandboxed: false) else { return [] }
        var children: [Int32: [Int32]] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, let c = Int32(parts[0]), let p = Int32(parts[1]) { children[p, default: []].append(c) }
        }
        var result: [Int32] = [], queue: [Int32] = [pid]
        while let cur = queue.popLast() {
            for c in children[cur] ?? [] { result.append(c); queue.append(c) }
        }
        return result
    }
}

/// Counts the child processes the app starts. Tests assert that registration, wheel building and idle time start none (everything heavy is lazy).
enum ProcessStats {
    private static let counter = Locked(0)
    /// Processes started (or attempted) since launch, through `ProcessRunner` and `SyncProcess`.
    static var started: Int { counter.value }
    static func noteStart() { counter.withLock { $0 += 1 } }
}

/// Blocking helper for short probes (`--version`, `ps`, `ffmpeg -encoders`). Never use for conversions.
enum SyncProcess {
    /// `sandboxed` (default) starts the tool without network access, like every tool that reads the person's files (ProcessSandbox); the version / process-list probes
    /// of the app itself pass false.
    static func run(_ exe: URL, _ args: [String], timeout: TimeInterval = 5, environment: [String: String]? = nil, sandboxed: Bool = true) -> String? {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if sandboxed { ProcessSandbox.apply(to: p) }
        p.environment = environment ?? ToolLocator.shared.childEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        ProcessStats.noteStart()
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.05); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        _ = done.wait(timeout: .now() + 1)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits a byte stream into lines on \n, \r and \r\n.
struct LineSplitter {
    private var buffer = Data()
    mutating func feed(_ data: Data, emit: (String) -> Void) {
        buffer.append(data)
        var start = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let b = buffer[i]
            if b == 10 || b == 13 {
                if i > start { emit(String(decoding: buffer[start..<i], as: UTF8.self)) }
                start = buffer.index(after: i)
            }
            i = buffer.index(after: i)
        }
        buffer = start < buffer.endIndex ? Data(buffer[start...]) : Data()
    }
    mutating func flush(emit: (String) -> Void) {
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)) }
        buffer = Data()
    }
}

/// Mutable state of one run; only ever touched on the run's private serial queue.
final class IOState: @unchecked Sendable {
    var outSplit = LineSplitter()
    var errSplit = LineSplitter()
    var captured = Data()
    var tail: [String] = []
}

enum ProcessRunner {
    /// Runs `executable` with `arguments` and waits. Throws `CancellationError` when the task is cancelled
    /// (the process tree is killed first) and `ConversionError.toolFailed` on a non-zero exit unless
    /// `allowNonZeroExit` is true.
    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        captureStdout: Bool = false,
        maxCapturedBytes: Int = 16_000_000,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil,
        control: ProcessControl? = nil,
        toolName: String? = nil,
        allowNonZeroExit: Bool = false,
        background: Bool = false,
        killImmediately: Bool = false,
        allowNetwork: Bool? = nil
    ) async throws -> ProcessOutput {
        let ctl = control ?? ProcessControl(killImmediately: killImmediately)
        let name = toolName ?? executable.lastPathComponent
        if Task.isCancelled { throw CancellationError() }

        let output: ProcessOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                let outPipe = Pipe(), errPipe = Pipe()

                let io = DispatchQueue(label: "app.swampconverter.process-io")
                let group = DispatchGroup()
                let st = IOState()   // touched only on `io`
                let resumed = Locked(false)

                @Sendable func noteStderr(_ line: String) {
                    if line.hasPrefix("HasCallStack backtrace") || line.contains(", called at libraries") { return }
                    st.tail.append(line)
                    if st.tail.count > 15 { st.tail.removeFirst() }
                    onStderrLine?(line)
                }

                group.enter()
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        io.async { st.outSplit.flush { onStdoutLine?($0) }; group.leave() }
                    } else {
                        io.async {
                            if captureStdout && st.captured.count < maxCapturedBytes { st.captured.append(d) }
                            if onStdoutLine != nil { st.outSplit.feed(d) { onStdoutLine?($0) } }
                        }
                    }
                }
                group.enter()
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        io.async { st.errSplit.flush { noteStderr($0) }; group.leave() }
                    } else {
                        io.async { st.errSplit.feed(d) { noteStderr($0) } }
                    }
                }

                @Sendable func finish(status: Int32) {
                    guard resumed.withLock({ (v: inout Bool) -> Bool in if v { return false }; v = true; return true }) else { return }
                    ctl.detach()
                    if ctl.wasCancelled { cont.resume(throwing: CancellationError()); return }
                    let text = captureStdout ? String(decoding: st.captured, as: UTF8.self) : ""
                    let out = ProcessOutput(exitCode: status, stdout: text, stderrTail: st.tail)
                    if status != 0 && !allowNonZeroExit {
                        let detail = st.tail.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(5).joined(separator: "\n")
                        cont.resume(throwing: ConversionError.toolFailed(tool: name, code: status, detail: detail))
                    } else {
                        cont.resume(returning: out)
                    }
                }

                @Sendable func exited(status: Int32) {
                    // Wait for EOF on both pipes, but never hang on a daemonised grandchild that keeps them open.
                    let flag = Locked(false)
                    group.notify(queue: io) {
                        if flag.withLock({ (v: inout Bool) -> Bool in if v { return false }; v = true; return true }) { finish(status: status) }
                    }
                    io.asyncAfter(deadline: .now() + 2) {
                        if flag.withLock({ (v: inout Bool) -> Bool in if v { return false }; v = true; return true }) {
                            outPipe.fileHandleForReading.readabilityHandler = nil
                            errPipe.fileHandleForReading.readabilityHandler = nil
                            finish(status: status)
                        }
                    }
                }

                do {
                    ProcessStats.noteStart()
                    // A program that is not there fails like a failed spawn would ("No such file or directory"), not as the sandbox launcher's own exit code 71.
                    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                        throw ProcessSpawn.SpawnError.errno(FileManager.default.fileExists(atPath: executable.path) ? EACCES : ENOENT)
                    }
                    // Tools that read the person's files start without network access (ProcessSandbox); only yt-dlp may use it.
                    let launch = ProcessSandbox.plan(executable: executable, arguments: arguments, allowNetwork: allowNetwork)
                    let spawned = try ProcessSpawn.spawn(launch.executable, launch.arguments, environment: ToolLocator.shared.childEnvironment(extra: environment ?? [:]),
                                                         workingDirectory: workingDirectory, stdout: outPipe.fileHandleForWriting.fileDescriptor,
                                                         stderr: errPipe.fileHandleForWriting.fileDescriptor, background: background)
                    // The child owns its copies of the write ends now: close ours, or EOF would never arrive.
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    if background { setpriority(PRIO_PROCESS, id_t(spawned.pid), ResourcePolicy.childNice(background: true)) }
                    ctl.attach(pid: spawned.pid)
                    ProcessSpawn.reap(spawned.pid) { status in exited(status: status) }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    if resumed.withLock({ (v: inout Bool) -> Bool in if v { return false }; v = true; return true }) {
                        let reason = (error as? ProcessSpawn.SpawnError)?.reason ?? error.localizedDescription
                        cont.resume(throwing: ConversionError.cannotStart(tool: name, reason: reason))
                    }
                }
            }
        } onCancel: {
            ctl.cancel()
        }
        return output
    }
}
