import Foundation
import AppKit

/// The two development harnesses behind `--self-test` and `--snapshot`. Both run against an ISOLATED home (Application Support and temp are redirected before anything touches them),
/// forbid the network, and never touch the user's real settings, presets or files.
@MainActor
enum Harness {
    /// `SwampConverter --self-test [filter]`: filter = text contained in "suite/name" (case-insensitive): "core", "image/quality", "downloader".
    /// Prints one PASS / FAIL / SKIP line per test and a summary; returns 0 when nothing failed.
    static func runSelfTests(filter: String?) async -> Int32 {
        NetworkGate.forbidAll = true
        let root = AppPaths.useIsolatedHome()
        defer { AppPaths.removeIsolatedHome(root) }
        EnginesBootstrap.registerAll()
        EnginesBootstrap.registerSelfTests()
        out("Swamp Converter self-test (isolated home: \(root.path))")
        let report = await SelfTestRegistry.shared.run(filter: filter)
        ConformanceMatrix.writeIfRequested()
        ProcessRegistry.shared.killAll()
        return report.exitCode
    }

    /// `SwampConverter --snapshot <dir> [filter]`: renders every registered view in its variants to `<dir>/<name>.<variant>.png` plus `index.txt`. Needs a GUI session (WindowServer capture),
    /// never shows anything on a real display (the panel sits far outside every screen).
    static func runSnapshots(to dir: URL, filter: String?) async -> Int32 {
        NetworkGate.forbidAll = true
        let root = AppPaths.useIsolatedHome()
        defer { AppPaths.removeIsolatedHome(root) }
        EnginesBootstrap.registerAll()
        EnginesBootstrap.registerSnapshots()
        out("Swamp Converter snapshots -> \(dir.path)")
        let result = await SnapshotRenderer.renderAll(to: dir, filter: filter)
        out("\(result.written.count) written, \(result.failures.count) failed")
        for f in result.failures { out("  FAIL \(f)") }
        return result.failures.isEmpty ? 0 : 1
    }
}
