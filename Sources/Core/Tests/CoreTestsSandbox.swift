import Foundation
import Darwin

// The no-network sandbox of child processes (ProcessSandbox): the plan it makes, the identity rule for yt-dlp, and the real effect on a real child (a connection to a
// listener this test opens is refused for an ordinary tool and allowed for the downloader).

enum CoreTestsSandbox {
    /// A TCP listener on 127.0.0.1 with an ephemeral port; `accepted(within:)` says whether anybody connected.
    private final class Listener {
        let fd: Int32
        let port: UInt16
        init() throws {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw TestFailure(message: "no socket", file: #fileID, line: #line) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(sock, 4) == 0 else { close(sock); throw TestFailure(message: "cannot listen: \(String(cString: strerror(errno)))", file: #fileID, line: #line) }
            var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
            fd = sock
            port = UInt16(bigEndian: out.sin_port)
        }
        func accepted(within seconds: Double) -> Bool {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return poll(&p, 1, Int32(seconds * 1000)) > 0
        }
        deinit { close(fd) }
    }

    private static let nc = URL(fileURLWithPath: "/usr/bin/nc")

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("core.sandbox", "the launch plan: tools start under sandbox-exec with a constant no-network profile; yt-dlp (by resolved path, not by name), an explicit allow and a disabled sandbox start as they are") {
            guard ProcessSandbox.isAvailable else { try skipTest("sandbox-exec is not on this Mac") }
            let fx = TestFixtures(); defer { fx.cleanup() }
            let user = fx.url("user"); try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let ytdlp = user.appendingPathComponent("yt-dlp")
            try "#!/bin/sh\necho x\n".write(to: ytdlp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytdlp.path)
            let loc = ToolLocator(roots: ToolSearchRoots(bundled: .none, userFolder: .folder(user.path), wellKnown: [], extraDirectories: false, path: .none))
            try expectEqual(loc.find(.ytdlp)?.url.lastPathComponent, "yt-dlp")

            let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            let plan = ProcessSandbox.plan(executable: ffmpeg, arguments: ["-i", "/a b/-i.mov"], tools: loc)
            try expect(plan.sandboxed)
            try expectEqual(plan.executable.path, "/usr/bin/sandbox-exec")
            try expectEqual(plan.arguments, ["-p", ProcessSandbox.profile, "/opt/homebrew/bin/ffmpeg", "-i", "/a b/-i.mov"], "the program and its arguments follow the profile untouched")
            try expect(ProcessSandbox.profile.contains("(deny network-outbound (remote ip))") && !ProcessSandbox.profile.contains("\\("), "the profile is constant text")

            let downloader = ProcessSandbox.plan(executable: ytdlp, arguments: ["--version"], tools: loc)
            try expect(!downloader.sandboxed && downloader.executable == ytdlp, "the located yt-dlp is the one program that may use the network")
            let link = fx.url("alias"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ytdlp)
            try expect(!ProcessSandbox.plan(executable: link, arguments: [], tools: loc).sandboxed, "a link to it is it")
            let impostor = fx.url("elsewhere"); try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)
            let other = impostor.appendingPathComponent("yt-dlp"); try "#!/bin/sh\n".write(to: other, atomically: true, encoding: .utf8)
            try expect(ProcessSandbox.plan(executable: other, arguments: [], tools: loc).sandboxed, "a file that is merely NAMED yt-dlp gets no network")

            try expect(!ProcessSandbox.plan(executable: ffmpeg, arguments: [], allowNetwork: true, tools: loc).sandboxed, "an explicit allow wins")
            ProcessSandbox.enabled = false; defer { ProcessSandbox.enabled = true }
            try expect(!ProcessSandbox.plan(executable: ffmpeg, arguments: [], tools: loc).sandboxed, "switched off (tests only)")
        }

        t.register("core.sandbox", "a real child cannot connect to a listener on this Mac, the downloader can, and a tool's exit code and output pass through the wrapper unchanged") {
            guard ProcessSandbox.isAvailable, FileManager.default.isExecutableFile(atPath: nc.path) else { try skipTest("needs sandbox-exec and nc") }
            let listener = try Listener()
            let args = ["-z", "-w", "2", "127.0.0.1", String(listener.port)]
            let blocked = try await ProcessRunner.run(nc, args, captureStdout: true, allowNonZeroExit: true)
            try expect(blocked.exitCode != 0, "nc connected from inside the sandbox")
            try expect(!listener.accepted(within: 0.3), "the listener saw a connection from a sandboxed tool")
            let allowed = try await ProcessRunner.run(nc, args, captureStdout: true, allowNonZeroExit: true, allowNetwork: true)
            try expectEqual(allowed.exitCode, 0, "the downloader's way to start a process reaches the listener")
            try expect(listener.accepted(within: 1), "the listener saw the downloader-style connection")

            // The wrapper is invisible otherwise: exit code, stdout and a quoted path with spaces.
            let echo = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["a b", "-n", "ü"], captureStdout: true)
            try expectEqual(echo.stdout.trimmingCharacters(in: .newlines), "a b -n ü")
            let code = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 7"], allowNonZeroExit: true)
            try expectEqual(code.exitCode, 7)
        }
    }
}
