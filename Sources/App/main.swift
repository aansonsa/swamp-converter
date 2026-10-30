import AppKit
import Foundation

// Process entry. Command-line modes are handled BEFORE any UI starts and never create an NSApplication window server session unless they need one:
//   --self-test [filter]   run the self-tests against an ISOLATED home folder, exit 0 / 1        (Core Harness)
//   --snapshot <dir> [filter]   render the registered views offscreen to PNG files, exit 0 / 1   (Core Harness; needs a GUI session, never touches the desktop)
//   --bench launch|wheel   developer measurements (scripts/measure.sh): time to ready, wheel benchmark
//   convert | download | probe | list-ops | presets | options | version | help | --cli          headless CLI (module cli); also when the executable is named `swamp`
//   (anything else)        the menu-bar app
// Top-level code runs on the main thread; `RunLoop.main.run()` keeps the process alive until a Task calls `exit`.

let launchArguments = Array(CommandLine.arguments.dropFirst())

func finish(_ code: Int32) -> Never { exit(code) }

if launchArguments.first == "--self-test" {
    let filter = launchArguments.dropFirst().first
    Task { @MainActor in finish(await Harness.runSelfTests(filter: filter)) }
    RunLoop.main.run()
} else if launchArguments.first == "--snapshot" {
    guard launchArguments.count >= 2 else {
        FileHandle.standardError.write(Data("usage: SwampConverter --snapshot <dir> [filter]\n".utf8))
        finish(2)
    }
    let dir = URL(fileURLWithPath: launchArguments[1], isDirectory: true)
    let filter = launchArguments.dropFirst(2).first
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in finish(await Harness.runSnapshots(to: dir, filter: filter)) }
    RunLoop.main.run()
} else if launchArguments.first == "--bench" {
    let name = launchArguments.dropFirst().first ?? ""
    if name == "launch" {
        MainActor.assumeIsolated { AppBench.exitAfterReady = true; AppMain.run() }
    } else {
        if name == "wheel" {
            // The benchmark drives the real panel offscreen, so it needs a window-server session (accessory policy, no Dock icon), like --snapshot.
            NSApplication.shared.setActivationPolicy(.accessory)
            #if !SC_SHIPPING
            MainActor.assumeIsolated { AppBench.wheelRunner = { await WheelBenchmark.run() ? 0 : 1 } }
            #endif
        }
        Task { @MainActor in finish(await AppBench.run(name)) }
        RunLoop.main.run()
    }
} else if CLI.isCLIInvocation(arguments: launchArguments) {
    Task { @MainActor in finish(await CLI.run(arguments: launchArguments.first == "--cli" ? Array(launchArguments.dropFirst()) : launchArguments)) }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        // A second launch forwards its files / URLs to the running app and exits (before any UI exists).
        SingleInstance.forwardAndExitIfAnotherInstanceRuns(arguments: launchArguments)
        AppMain.run()
    }
}
