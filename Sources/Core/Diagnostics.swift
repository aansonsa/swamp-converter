import Foundation
import Darwin
import os

// Cheap, always-available measurements for the performance budgets (idle footprint, memory after 200 jobs, launch to ready).
// Nothing here runs by itself: every function reads a number when it is called.

enum MemoryProbe {
    /// The process's physical footprint in bytes (`phys_footprint`, the number Activity Monitor shows as "Memory" and `footprint` prints).
    /// 0 when the kernel call fails.
    static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Resident set size in bytes (what `ps -o rss` prints); usually larger than the footprint because it counts shared pages.
    static func residentSize() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    /// "42.3 MB" for logs and test messages.
    static func format(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
}

/// CPU time and wakeups of this process, for the "zero idle cost" budget (idle CPU, idle wakeups). Two samples a few seconds apart give the rates.
enum ResourceProbe {
    struct Sample: Sendable {
        /// User + system CPU seconds since launch.
        var cpuSeconds: Double
        /// Package idle wakeups since launch (the `idlew` column of `top`): the number that must stay at ~0 per second while nothing happens.
        var idleWakeups: UInt64
        var interruptWakeups: UInt64
    }

    static func sample() -> Sample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        var info = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        guard rc == 0 else { return nil }
        return Sample(cpuSeconds: seconds(usage.ru_utime) + seconds(usage.ru_stime), idleWakeups: info.ri_pkg_idle_wkups, interruptWakeups: info.ri_interrupt_wkups)
    }
}

/// Launch-to-ready measurement. The app calls `LaunchClock.markReady()` once, after the status item is installed (step 4 of the launch order);
/// the line it logs (`launch-ready: 312 ms since process start`) is what `scripts/measure.sh launch` reads. No timer, no allocation after the call.
enum LaunchClock {
    private static let readyAt = Locked<Date?>(nil)

    /// When the kernel started this process (nil when `sysctl` refuses).
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }()

    /// Records the moment the app is usable and logs how long it took. Idempotent: the first call wins.
    @discardableResult
    static func markReady() -> TimeInterval? {
        let now = Date()
        let first = readyAt.withLock { (v: inout Date?) -> Bool in if v != nil { return false }; v = now; return true }
        guard first, let start = processStart else { return elapsedUntilReady }
        let seconds = now.timeIntervalSince(start)
        Log.info("launch-ready: \(Int((seconds * 1000).rounded())) ms since process start")
        return seconds
    }

    /// Seconds from process start to `markReady()` (nil before it was called).
    static var elapsedUntilReady: TimeInterval? {
        guard let start = processStart, let ready = readyAt.value else { return nil }
        return ready.timeIntervalSince(start)
    }
}
