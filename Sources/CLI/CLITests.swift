import Foundation

/// Self-tests of the cli module (suites "cli", "cli.parser", "cli.options", "cli.convert", "cli.exit", "cli.info", "cli.download", "cli.real").
/// The commands run IN-PROCESS (`CLI.run` with a captured `CLISink`) against a private registry of fixture operations; the `cli.real` suite runs
/// real engines on generated files and the built binary as a child process (the stdout contract).
enum CLITests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("cli", "verbs and the swamp executable name are recognised; ordinary app launches are not") {
            try expect(CLI.isCLIInvocation(arguments: ["convert", "a.png"], executableName: "SwampConverter"))
            try expect(CLI.isCLIInvocation(arguments: [], executableName: "swamp"))
            try expect(!CLI.isCLIInvocation(arguments: ["--self-test"], executableName: "SwampConverter"))
            try expect(!CLI.isCLIInvocation(arguments: [], executableName: "SwampConverter"))
            try expectEqual(CLIExitCode.cancelled.rawValue, 130)
            for verb in ["convert", "download", "probe", "list-ops", "presets", "options", "version", "help", "--help", "-h", "--version", "--cli"] {
                try expect(CLI.isCLIInvocation(arguments: [verb], executableName: "SwampConverter"), "\(verb) starts the CLI")
            }
            try expect(!CLI.isCLIInvocation(arguments: ["--snapshot", "/tmp/x"], executableName: "SwampConverter"))
            try expectEqual(CLIExitCode.ok.rawValue, 0); try expectEqual(CLIExitCode.failed.rawValue, 1); try expectEqual(CLIExitCode.usage.rawValue, 2)
            try expectEqual(CLIExitCode.unavailable.rawValue, 3); try expectEqual(CLIExitCode.partial.rawValue, 4)
        }
        CLITestsParser.register()
        CLITestsOptions.register()
        CLITestsConvert.register()
        CLITestsExit.register()
        CLITestsInfo.register()
        CLITestsDownload.register()
        CLITestsReal.register()
    }
}
