import Foundation

// NO NETWORK FOR THE TOOLS THAT READ YOUR FILES. The app promises to be 100% local except the downloader, but a file can carry a link: LibreOffice fetches the image a
// document links to (checked: a converted .fodt with an http image made a request to a local server), so a hostile document could phone home or probe the local network
// from the person's Mac. Every child process therefore starts under `sandbox-exec` with a profile that denies outgoing and incoming IP traffic and allows everything else
// (files, pipes, local unix sockets, so the tools still work). The one exception is yt-dlp itself: it is the downloader, and the person agreed to that in the consent sheet.
//
// `sandbox-exec` is deprecated by Apple but ships with every macOS and works on 26; when it is missing the tools run as before and the About window / log say nothing
// scary (the code path is the same, only unprotected). The wrapper `exec`s the tool, so the pid, the process group and every signal behave exactly as without it.

enum ProcessSandbox {
    /// Constant text: nothing from a file, a link or a setting is ever put into the profile.
    static let profile = "(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))(deny network-bind (local ip))"
    static let launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// Switched off only by tests that need to see an unprotected child.
    nonisolated(unsafe) static var enabled = true

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: launcher.path) }

    struct Plan: Equatable, Sendable {
        var executable: URL
        var arguments: [String]
        var sandboxed: Bool
    }

    /// What really gets started. `allowNetwork` nil = decide by the program: only the configured yt-dlp may use the network.
    static func plan(executable: URL, arguments: [String], allowNetwork: Bool? = nil, tools: ToolLocator = .shared) -> Plan {
        let open = allowNetwork ?? isDownloader(executable, tools: tools)
        guard enabled, !open, isAvailable else { return Plan(executable: executable, arguments: arguments, sandboxed: false) }
        return Plan(executable: launcher, arguments: ["-p", profile, executable.path] + arguments, sandboxed: true)
    }

    /// True for the yt-dlp binary the app located (user override, the app's own folder, Homebrew ...): compared by resolved path, never by name.
    static func isDownloader(_ executable: URL, tools: ToolLocator = .shared) -> Bool {
        guard let located = tools.find(.ytdlp)?.url else { return false }
        return located.resolvingSymlinksInPath().standardizedFileURL.path == executable.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// For code that still configures a Foundation `Process` itself (previews): points it at the sandbox launcher when the tool must not use the network.
    static func apply(to process: Process, allowNetwork: Bool? = nil) {
        guard let exe = process.executableURL else { return }
        let p = plan(executable: exe, arguments: process.arguments ?? [], allowNetwork: allowNetwork)
        if p.sandboxed { process.executableURL = p.executable; process.arguments = p.arguments }
    }
}
