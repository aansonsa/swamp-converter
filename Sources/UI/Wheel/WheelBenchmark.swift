import Foundation
import AppKit
import SwiftUI
import Darwin

#if !SC_SHIPPING   // a developer measurement that builds its wheel from the test registry: it lives in the full build only

// The wheel's performance harness: `SwampConverter --bench wheel` (wired in main.swift) calls `WheelBenchmark.run()`.
//
// What it measures, all offscreen (the panel sits 6000 pt off every display, takes no focus, plays no haptic) with the real controller, panel, drop view and SwiftUI ring:
//   * prewarm   the hidden window built when a drag begins (panel + hosting view + first layout);
//   * open      `present` to the first committed layout once the window is prewarmed: the number the 80 ms budget is about;
//   * frames    N hover changes (the busiest per-frame update: one sector loses the highlight, one gains it, the hub text changes), each followed by a layout pass and a Core
//               Animation commit, timed one by one;
//   * allocations  malloc calls on the MAIN thread per frame (the `malloc_logger` hook, installed only while measuring) and the growth of live heap blocks over the run.
// Glass itself is rendered by the window server, outside this process, so the frame times are the cost on OUR side (SwiftUI diffing, layout, commit).

struct WheelBenchmarkResult: Sendable {
    var sectors = 0
    var frames = 0
    var prewarmMS = 0.0
    var openMS = 0.0
    var frameMeanMS = 0.0
    var frameP95MS = 0.0
    var frameMaxMS = 0.0
    /// Main-thread malloc calls per frame (nil when the hook is unavailable).
    var allocationsPerFrame: Double?
    /// Live heap blocks at the end of the run minus the middle of it, i.e. over the second half (steady state): a leak indicator; a handful is noise.
    var heapBlockGrowth = 0

    struct Budget: Sendable {
        var openMS = 80.0
        var frameMeanMS = 8.0
        var heapBlockGrowth = 400
    }

    static let release = Budget()
    /// A debug build runs our own code unoptimised: the same shape of check with room for it.
    static let debug = Budget(openMS: 250, frameMeanMS: 20, heapBlockGrowth: 2000)

    func failures(budget: Budget) -> [String] {
        var out: [String] = []
        if openMS > budget.openMS { out.append("open \(fmt(openMS)) ms > \(fmt(budget.openMS)) ms") }
        if frameMeanMS > budget.frameMeanMS { out.append("mean frame \(fmt(frameMeanMS)) ms > \(fmt(budget.frameMeanMS)) ms") }
        if heapBlockGrowth > budget.heapBlockGrowth { out.append("heap grew by \(heapBlockGrowth) blocks > \(budget.heapBlockGrowth)") }
        return out
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

// MARK: - malloc counting

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private nonisolated(unsafe) let mainThreadAllocations = UnsafeMutablePointer<Int>.allocate(capacity: 1)

private let wheelMallocHook: MallocLogger = { type, _, _, _, _, _ in
    // MALLOC_LOG_TYPE_ALLOCATE = 2. Only the main thread is counted: that is where the wheel's frame work happens.
    if type & 2 != 0 && pthread_main_np() != 0 { mainThreadAllocations.pointee &+= 1 }
}

@MainActor
private enum MallocCounter {
    private static var slot: UnsafeMutablePointer<MallocLogger?>? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: MallocLogger?.self)
    }

    static var isAvailable: Bool { slot != nil }

    static func start() {
        mainThreadAllocations.pointee = 0
        slot?.pointee = wheelMallocHook
    }

    /// Stops counting and returns the count since `start`.
    static func stop() -> Int {
        slot?.pointee = nil
        return mainThreadAllocations.pointee
    }

    static func liveBlocks() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }
}

// MARK: - The benchmark

@MainActor
enum WheelBenchmark {
    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    /// One pass: prewarm, open, `frames` hover changes. Needs a window server (no screens = a skipped measurement, the caller decides).
    static func measure(frames: Int = 120) async -> WheelBenchmarkResult {
        var r = WheelBenchmarkResult()
        r.frames = frames
        let (registry, _) = WheelTests.fakeRegistry()
        for i in 0..<5 {                                                // eight sectors in total: four conversions + four more
            registry.register(PerFileOperation(meta: .make("bench.op\(i)", .convert, .image, L10n("Operation \(i)", "Операция \(i)"), sub: L10n("sub", "под"),
                                                           symbol: "photo", schema: "image.convert", inputs: ["png"])))
        }
        let controller = WheelController()
        controller.offscreenForTesting = true
        var builder = WheelContentBuilder()
        builder.registry = registry
        controller.contentBuilder = { builder }
        let input = IncomingInput(files: [FileItem(url: URL(fileURLWithPath: "/tmp/swamp-bench/photo.png"), isDirectory: false)])

        // Prewarm: what a drag beginning does.
        var t0 = now()
        let (panel, view) = controller.ensurePanel()
        view.layoutSubtreeIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
        r.prewarmMS = now() - t0

        // Open: the number the 80 ms budget is about. Median of five.
        var opens: [Double] = []
        for _ in 0..<5 {
            controller.close()
            await settle()
            t0 = now()
            controller.present(input, anchor: NSPoint(x: 400, y: 400), wheel: .convert)
            view.layoutSubtreeIfNeeded()
            CATransaction.flush()
            opens.append(now() - t0)
        }
        opens.sort()
        r.openMS = opens[opens.count / 2]

        // Frames: alternate the highlight over every sector (and the hub in between).
        guard let model = controller.model else { return r }
        r.sectors = model.sectors.count
        await settle()
        let n = max(model.sectors.count, 1)
        // One frame = one hover change. Each frame gets its own autorelease pool: in the app every frame is a separate run-loop turn, whereas this loop runs inside one,
        // so AppKit's autoreleased temporaries would pile up and look like a leak.
        func frame(_ i: Int) {
            autoreleasepool {
                if i % 2 == 0 { model.setHighlight((i / 2) % n) } else { model.setHighlight(-1) }
                view.layoutSubtreeIfNeeded()
                CATransaction.flush()
            }
        }
        // Warm-up (not measured): SwiftUI and Core Animation fill their caches (text layout, glyphs, layers) on the first hovers; that is a one-time cost, not growth.
        for i in 0..<(4 * n) { frame(i) }
        await settle()
        MallocCounter.start()
        var samples: [Double] = []
        samples.reserveCapacity(frames)
        // Heap growth is judged on the SECOND half of the run (steady state): the first half still fills one-time caches (about a thousand blocks), which is not a leak.
        var blocksMid = 0
        for i in 0..<frames {
            if i == frames / 2 { blocksMid = MallocCounter.liveBlocks() }
            let t = now()
            frame(i)
            samples.append(now() - t)
            // Give the run loop a turn between frames, as the real app does: finished Core Animation animations and SwiftUI transactions are released there.
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let allocations = MallocCounter.stop()
        r.heapBlockGrowth = MallocCounter.liveBlocks() - blocksMid
        if MallocCounter.isAvailable { r.allocationsPerFrame = Double(allocations) / Double(max(frames, 1)) }
        samples.sort()
        r.frameMeanMS = samples.reduce(0, +) / Double(max(samples.count, 1))
        r.frameP95MS = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
        r.frameMaxMS = samples.last ?? 0
        controller.close()
        return r
    }

    /// Lets pending SwiftUI work and animations finish so one measurement does not bleed into the next.
    private static func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    /// `--bench wheel`: prints the numbers and returns whether the release budgets hold (exit code 0 / 1 for main.swift). Run it from a release build to compare with the
    /// budgets of the brief; a debug build is judged against the looser debug budget and says so.
    @discardableResult
    static func run(frames: Int = 120) async -> Bool {
        guard !NSScreen.screens.isEmpty else {
            print("wheel benchmark: no display / window server, nothing measured")
            return false
        }
        // SC_BENCH_FRAMES=480 lengthens the run: heap growth that scales with the frame count is a leak, growth that stays put is cache warm-up.
        let count = ProcessInfo.processInfo.environment["SC_BENCH_FRAMES"].flatMap { Int($0) }.map { min(max($0, 20), 5000) } ?? frames
        let r = await measure(frames: count)
        // An unoptimised build is judged against the loose budget; SC_BENCH_RELEASE_BUDGET=1 holds it to the release numbers anyway.
        let isDebug = _isDebugAssertConfiguration() && ProcessInfo.processInfo.environment["SC_BENCH_RELEASE_BUDGET"] == nil
        let budget = isDebug ? WheelBenchmarkResult.debug : WheelBenchmarkResult.release
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        print("wheel benchmark (\(isDebug ? "debug build, loose budget" : "release budget")): \(r.sectors) sectors, \(r.frames) frames, offscreen")
        print("  prewarm (panel + first layout)      \(f(r.prewarmMS)) ms")
        print("  open after prewarm (median of 5)    \(f(r.openMS)) ms     budget \(f(budget.openMS)) ms")
        print("  frame: mean \(f(r.frameMeanMS)) ms, p95 \(f(r.frameP95MS)) ms, max \(f(r.frameMaxMS)) ms     budget mean \(f(budget.frameMeanMS)) ms")
        if let a = r.allocationsPerFrame { print("  main-thread allocations per frame   \(String(format: "%.1f", a))") } else { print("  main-thread allocations per frame   n/a (malloc_logger hook unavailable)") }
        print("  live heap block growth, second half \(r.heapBlockGrowth)     budget \(budget.heapBlockGrowth)")
        let failures = r.failures(budget: budget)
        print(failures.isEmpty ? "  PASS" : "  FAIL: " + failures.joined(separator: "; "))
        return failures.isEmpty
    }
}
#endif
