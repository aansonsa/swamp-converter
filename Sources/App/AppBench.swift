import AppKit
import Darwin

/// Developer measurements (`SwampConverter --bench <name>`, used by `scripts/measure.sh`). Nothing here runs in a normal launch except the ready marker, and that only when
/// `SC_READY_FILE` is set.
///   --bench launch   starts the app like a normal launch, prints `launch_ms=<n>` (process start to status item ready) and quits
///   --bench wheel    runs the wheel benchmark of the wheel module when it is connected (`AppBench.wheelRunner`)
@MainActor
enum AppBench {
    static var exitAfterReady = false
    /// The wheel module's benchmark entry (`WheelBenchmark.run()`); the integrator connects it here: `AppBench.wheelRunner = { await WheelBenchmark.run() }`.
    static var wheelRunner: (@MainActor () async -> Int32)?

    static func run(_ name: String) async -> Int32 {
        switch name {
        case "wheel":
            guard let runner = wheelRunner else {
                FileHandle.standardError.write(Data("bench: the wheel benchmark is not connected in this build (set AppBench.wheelRunner to WheelBenchmark.run).\n".utf8))
                return 2
            }
            return await runner()
        default:
            FileHandle.standardError.write(Data("usage: SwampConverter --bench launch|wheel\n".utf8))
            return 2
        }
    }

    /// Milliseconds from the start of this process (kernel start time) to now; nil when the kernel does not tell.
    nonisolated static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }

    /// Called when the status item is on screen. With `SC_READY_FILE=<path>` the file gets `launch_ms=<n>`; `--bench launch` prints it and quits.
    static func writeReadyMarkerIfRequested() {
        let ms = millisecondsSinceProcessStart().map { String(format: "%.0f", $0) } ?? "unknown"
        if let path = ProcessInfo.processInfo.environment["SC_READY_FILE"], !path.isEmpty {
            try? "launch_ms=\(ms)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        if exitAfterReady {
            print("launch_ms=\(ms)")
            fflush(stdout)
            AppTermination.systemInitiated = true
            NSApp.terminate(nil)
        }
    }
}
