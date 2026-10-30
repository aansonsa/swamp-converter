import Foundation

/// `swamp download` against the FAKE yt-dlp of the downloader module (`DownloadRig`): the real service, queue and runner, no network, no real tool.
enum CLITestsDownload {
    private static let video = "https://www.youtube.com/watch?v=abc123XYZ_-"

    @MainActor private static func environment() -> CLIEnvironment { CLIEnvironment() }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.download", "a link downloads into --out through DownloadService with JSON Lines progress; the file is the one yt-dlp wrote") {
            try await DownloadRig.with(env: ["FAKE_YTDLP_DELAY": "0.05"]) { rig in
                let out = rig.fx.url("cli out")
                let r = await CLIRig.run(["download", video, "--mode", "maximum", "--out", out.path, "--json"], environment: environment())
                try expectEqual(r.code, 0, r.stdout + r.stderr)
                try expect(r.stderr.isEmpty, "stderr stays empty in --json mode: \(r.stderr)")
                let events = try r.events()
                try expectEqual(events.last?["event"] as? String, "done")
                let outputs = try unwrap(events.last?["outputs"] as? [String])
                try expectEqual(outputs.count, 1)
                try expectEqual(URL(fileURLWithPath: outputs[0]).deletingLastPathComponent().path, out.path, "the file is in --out")
                try expect(FileManager.default.fileExists(atPath: outputs[0]) && TestFile.size(URL(fileURLWithPath: outputs[0])) == 400_000, "all bytes arrived")
                try expect(outputs[0].hasSuffix("[abc123XYZ_-].mp4"), outputs[0])
                try expect(events.contains { ($0["event"] as? String) == "progress" && ($0["fraction"] as? Double ?? 0) > 0.05 }, "progress was reported")
                let a = try unwrap(rig.downloadInvocations().first)
                try expectEqual(rig.downloadInvocations().count, 1)
                let homes = a.indices.filter { a[$0] == "-P" }.map { a[$0 + 1] }
                try expect(homes.first?.contains(out.path) == true, "yt-dlp was confined to --out: \(homes)")
                try expectEqual(rig.workAreas(in: out), [], "no work folder is left")
                try expectEqual(AppSettings.shared.data.downloader.consentGiven, true, "settings untouched by the run")
            }
        }

        t.register("cli.download", "human mode prints the path on stdout; audio modes give the audio file; the default folder comes from the settings") {
            try await DownloadRig.with { rig in
                let audio = await CLIRig.run(["download", "https://www.youtube.com/watch?v=abc123XYZ_-", "--mode", "audio-m4a"], environment: environment())
                try expectEqual(audio.code, 0, audio.stderr)
                try expectEqual(audio.lines.count, 1, audio.stdout)
                try expect(audio.lines[0].hasSuffix(".m4a") && FileManager.default.fileExists(atPath: audio.lines[0]), audio.stdout)
                try expectEqual(URL(fileURLWithPath: audio.lines[0]).deletingLastPathComponent().path, rig.audioDir.path, "audio goes to the music folder of the settings")
                let movie = await CLIRig.run(["download", video, "--quiet"], environment: environment())
                try expectEqual(movie.code, 0, movie.stderr)
                try expectEqual(URL(fileURLWithPath: try unwrap(movie.lines.first)).deletingLastPathComponent().path, rig.outDir.path, "video goes to the movies folder of the settings")
            }
        }

        t.register("cli.download", "consent: without it exit 3 and nothing starts; --consent agrees for this run only") {
            try await DownloadRig.with(settings: { $0.consentGiven = false }) { rig in
                let no = await CLIRig.run(["download", video, "--json"], environment: environment())
                try expectEqual(no.code, 3, no.stdout)
                let e = try unwrap(try no.event("error").first)
                try expectEqual(e["code"] as? Int, 3); try expect((e["message"] as? String ?? "").contains("--consent"), "the message says how to agree: \(e)")
                try expect(rig.invocations().isEmpty, "yt-dlp was not even asked for its version")
                let yes = await CLIRig.run(["download", video, "--consent", "--mode", "max"], environment: environment())
                try expectEqual(yes.code, 0, yes.stderr)
                try expectEqual(AppSettings.shared.data.downloader.consentGiven, false, "--consent is not written to the settings")
                try expectEqual(NetworkGate.settingsProvider().downloader.consentGiven, false, "and the gate's view is restored")
                try expectEqual(yes.lines.count, 1)
            }
        }

        t.register("cli.download", "links that are not public http(s) pages are usage errors (2) and never reach yt-dlp") {
            try await DownloadRig.with { rig in
                for bad in ["javascript:alert(1)", "file:///etc/passwd", "http://localhost/video", "http://192.168.1.5/v.mp4", "https://user:pass@example.com/v", "ftp://example.com/x", "not a link"] {
                    let r = await CLIRig.run(["download", bad, "--json"], environment: environment())
                    try expectEqual(r.code, 2, "\(bad): \(r.stdout)")
                    try expectEqual(try r.events().first?["event"] as? String, "error")
                }
                try expect(rig.invocations().isEmpty, "yt-dlp was never started: \(rig.invocations())")
            }
        }

        t.register("cli.download", "--set maps the download options: the height cap reaches yt-dlp, bad values and unknown keys are usage errors") {
            try await DownloadRig.with { rig in
                let out = rig.fx.url("set out")
                let ok = await CLIRig.run(["download", video, "--out", out.path, "--set", "dl.maxHeight=720", "--set", "dl.embed.thumb=false", "--quiet"], environment: environment())
                try expectEqual(ok.code, 0, ok.stderr)
                let a = try unwrap(rig.downloadInvocations().first)
                try expect((dlArg(a, "-f") ?? "").contains("height<=720"), "the format selector is capped at 720: \(dlArg(a, "-f") ?? "-")")
                try expect(!a.contains("--embed-thumbnail"), "embed thumbnail was switched off")
                let big = await CLIRig.run(["download", video, "--set", "dl.maxHeight=999"], environment: environment())
                try expectEqual(big.code, 2); try expect(big.stderr.contains("not one of"), big.stderr)
                let unknown = await CLIRig.run(["download", video, "--set", "dl.maxHight=720"], environment: environment())
                try expectEqual(unknown.code, 2); try expect(unknown.stderr.contains("dl.maxHeight"), "the nearest key is suggested: \(unknown.stderr)")
                try expectEqual(rig.downloadInvocations().count, 1, "the refused runs started nothing")
            }
        }

        t.register("cli.download", "yt-dlp missing: exit 3 with the install hint (no process, no network)") {
            if ToolLocator.shared.has(.ytdlp) { try skipTest("yt-dlp is installed on this Mac; the missing-tool path cannot be exercised") }
            let saved = AppSettings.shared.data
            defer { AppSettings.shared.update { $0 = saved } }
            let r = await CLIRig.run(["download", video, "--consent", "--json"], environment: environment())
            try expectEqual(r.code, 3, r.stdout)
            let e = try unwrap(try r.event("error").first)
            let message = e["message"] as? String ?? ""
            try expect(message.contains("yt-dlp is not installed") && message.contains("brew install yt-dlp"), message)
            try expectEqual(r.lines.count, 1)
        }

        t.register("cli.download", "cancelling a download ends the run with 130 and leaves no files or work folders") {
            try await DownloadRig.with(env: ["FAKE_YTDLP_STEPS": "40", "FAKE_YTDLP_DELAY": "0.1"]) { rig in
                let out = rig.fx.url("cancel out")
                let running = Task { @MainActor in await CLIRig.run(["download", video, "--mode", "max", "--out", out.path, "--json"], environment: CLIEnvironment()) }
                try await expectEventually(timeout: 8) { rig.runner.jobs.contains { $0.state == .running && ($0.progress ?? 0) > 0.05 } }
                CLI.requestCancel()
                let r = await running.value
                try expectEqual(r.code, 130, r.stdout + r.stderr)
                try expectEqual(try r.event("error").last?["code"] as? Int, 130)
                try await expectEventually(timeout: 3) { rig.runner.jobs.allSatisfy { $0.state.isFinished } }
                try expectEqual(rig.tree(out), [], "no partial files remain: \(rig.tree(out))")
                try expectEqual(rig.workAreas(in: out), [], "the work folder is gone")
            }
        }
    }
}
