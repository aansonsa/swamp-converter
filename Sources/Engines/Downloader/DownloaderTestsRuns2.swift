import Foundation

// Tests: more whole jobs against the fake yt-dlp: options that change the request (cookies, speed, subtitles, metadata, folders, templates),
// the disk-space check, the network gate, Quick = Studio, subtitle burn-in.

private let video = "https://www.youtube.com/watch?v=abc123XYZ_-"
private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

/// The download argv with the one job-private path masked, so two jobs can be compared.
private func masked(_ a: [String]) -> [String] {
    var out = a
    if let i = out.firstIndex(of: "--print-to-file"), i + 2 < out.count { out[i + 2] = "<list>" }
    return out
}

extension DownloaderTests {
    static func registerRuns2() {
        test("run: cookies and a speed limit reach yt-dlp only when chosen, for the information request and the download alike", oracles: ["dl.cookies.only-when-chosen", "dl.rate.limit"]) {
            try await DownloadRig.with { rig in
                _ = try await rig.download(video)
                for a in rig.invocations() { try expect(!a.contains("--cookies-from-browser") && !a.contains("--limit-rate"), "default run must not ask for cookies or a limit: \(a)") }
                let chosen = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=cookie1") { $0.cookies = .chrome; $0.rateLimitKBps = 750 })
                try await rig.finish(chosen); try expectEqual(chosen.state, .done, chosen.errorMessage ?? "")
                let info = try unwrap(rig.infoInvocations().last), down = try unwrap(rig.downloadInvocations().last)
                try expectEqual(dlArg(info, "--cookies-from-browser"), "chrome"); try expectEqual(dlArg(down, "--cookies-from-browser"), "chrome")
                try expectEqual(dlArg(down, "--limit-rate"), "750K"); try expect(!info.contains("--limit-rate"), "a speed limit has no meaning for the information request")
                // The default from Settings is used by the quick path.
                rig.configure { $0.cookies = .safari; $0.rateLimitKBps = 300 }
                _ = try await rig.download("https://www.youtube.com/watch?v=cookie2")
                let quick = try unwrap(rig.downloadInvocations().last)
                try expectEqual(dlArg(quick, "--cookies-from-browser"), "safari"); try expectEqual(dlArg(quick, "--limit-rate"), "300K")
            }
        }

        test("run: yt-dlp gets the JavaScript runtime that was found, once, and nothing else about it") {
            try await DownloadRig.with { rig in
                guard let rt = JSRuntimeDetector.detect() else { try skipTest("no JavaScript runtime on this Mac") }
                _ = try await rig.download(video)
                for a in [try unwrap(rig.infoInvocations().last), try unwrap(rig.downloadInvocations().last)] {
                    try expectEqual(a.filter { $0 == "--js-runtimes" }.count, 1); try expectEqual(dlArg(a, "--js-runtimes"), rt.argument)
                }
            }
        }

        test("run: subtitles are fetched in the chosen languages and kept inside the video or as a file beside it", requires: ["tool.ffmpeg"], oracles: ["dl.subs.mode", "dl.subs.langs"]) {
            try await DownloadRig.with(env: ["FAKE_YTDLP_SUBS": "1"]) { rig in
                let soft = try await rig.start(request: rig.request(video) { $0.subtitles = .soft; $0.subtitleLanguages = ["ru", "en"] })
                try await rig.finish(soft); try expectEqual(soft.state, .done, soft.errorMessage ?? "")
                let a = try unwrap(rig.downloadInvocations().last)
                try expect(a.contains("--write-subs") && a.contains("--embed-subs") && dlArg(a, "--sub-langs") == "ru,en", "\(a)")
                let ext = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=subs2") { $0.subtitles = .external; $0.subtitleLanguages = ["en"] })
                try await rig.finish(ext); try expectEqual(ext.state, .done, ext.errorMessage ?? "")
                let b = try unwrap(rig.downloadInvocations().last)
                try expect(!b.contains("--embed-subs") && dlArg(b, "--convert-subs") == "srt" && dlArg(b, "--sub-langs") == "en")
                let video2 = try unwrap(ext.outputs.first)
                try expect(FileManager.default.fileExists(atPath: video2.deletingPathExtension().appendingPathExtension("en.srt").path), "a subtitle file beside the video: \(rig.names())")
                let none = try await rig.download("https://www.youtube.com/watch?v=subs3")
                try expect(!(try unwrap(rig.downloadInvocations().last)).contains("--write-subs"), none.logText)
            }
        }

        test("run: title, chapters and cover are embedded unless switched off", requires: ["tool.ffmpeg"], oracles: ["dl.embed.flags"]) {
            try await DownloadRig.with { rig in
                _ = try await rig.download(video)
                let on = try unwrap(rig.downloadInvocations().last)
                try expect(on.contains("--embed-metadata") && on.contains("--embed-chapters") && on.contains("--embed-thumbnail"), "\(on)")
                let off = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=bare1") { $0.embedMetadata = false; $0.embedThumbnail = false })
                try await rig.finish(off)
                let b = try unwrap(rig.downloadInvocations().last)
                try expect(!b.contains("--embed-metadata") && !b.contains("--embed-chapters") && !b.contains("--embed-thumbnail") && !b.contains("--convert-thumbnails"), "\(b)")
            }
        }

        test("run: files go where the person said, and a template can never lead outside that folder", oracles: ["dl.folder.output", "dl.template.output"]) {
            try await DownloadRig.with { rig in
                let custom = try rig.fx.makeDirectory("Custom Place"), other = try rig.fx.makeDirectory("Другая папка")
                rig.configure { $0.folder = custom.path }
                let quick = try await rig.download(video)
                try expectEqual(quick.outputs.first?.deletingLastPathComponent().standardizedFileURL.path, custom.standardizedFileURL.path, "the folder from Settings")
                try expectEqual(rig.names(), [], "nothing in the default folder")
                let studio = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=folder2") { $0.outputDirectory = other })
                try await rig.finish(studio); try expectEqual(studio.outputs.first?.deletingLastPathComponent().standardizedFileURL.path, other.standardizedFileURL.path, "the Studio choice wins")
                // A template that tries to leave the folder is refused with a calm message before anything starts.
                let before = Set(try FileManager.default.contentsOfDirectory(atPath: rig.fx.root.path))
                let evil = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=evil1") { $0.filenameTemplate = "../escape/%(title)s.%(ext)s" })
                try await rig.finish(evil); try expectEqual(evil.state, .failed); try expect(!(evil.errorMessage ?? "").isEmpty, "a message, not a crash")
                try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: rig.fx.root.path)), before, "no new folder next to the output folder")
                try expect(rig.downloadInvocations().allSatisfy { dlArg($0, "-o")?.contains("..") != true }, "the unsafe template never reached yt-dlp")
                try expect(rig.downloadInvocations().count == 2 && rig.names().isEmpty, "only the two earlier downloads ran")
                // A folder that cannot be written to is explained, not crashed on.
                let locked = try rig.fx.makeDirectory("locked"); try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
                if !FileManager.default.isWritableFile(atPath: locked.path) {
                    let ro = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=ro1") { $0.outputDirectory = locked })
                    try await rig.finish(ro); try expectEqual(ro.state, .failed); try expect(!(ro.errorMessage ?? "").isEmpty && !(ro.errorMessage ?? "").contains("Optional"), ro.errorMessage ?? "")
                }
            }
        }

        test("run: Quick and Studio start yt-dlp with exactly the same arguments for the same choices") {
            try await DownloadRig.with { rig in
                let quick = try await rig.download(video)
                let a = masked(try unwrap(rig.downloadInvocations().last))
                let studio = try await rig.start(request: rig.request(video))
                try await rig.finish(studio); try expectEqual(studio.state, .done, studio.errorMessage ?? "")
                try expectEqual(masked(try unwrap(rig.downloadInvocations().last)), a, "one engine, two speeds")
                try expectEqual(quick.operationID, studio.operationID)
                // And the information request is the same.
                try expectEqual(rig.infoInvocations().count, 1, "the second job reused the fetched information")
            }
        }

        test("run: the free-space check stops an 8K download before it starts, warns when it is tight, and can be switched off") {
            try await DownloadRig.with { rig in
                let out = rig.outDir.path
                let big = "https://www.youtube.com/watch?v=big8k"
                DiskSpaceGuard.availableOverride = { $0.path.hasPrefix(out) ? 1_000_000_000 : nil }
                let low = try await rig.start(big); try await rig.finish(low)
                try expectEqual(low.state, .failed); try expect(low.errorMessage?.contains("Not enough free space") == true, low.errorMessage ?? "")
                try expect(rig.downloadInvocations().isEmpty && rig.workAreas().isEmpty, "nothing was started, no folder was made")
                try expectEqual(rig.infoInvocations().count, 1, "the real size comes from the information fetch")
                DiskSpaceGuard.availableOverride = { $0.path.hasPrefix(out) ? 4_100_000_000 : nil }
                let tight = try await rig.start("https://www.youtube.com/watch?v=big8k2"); try await rig.finish(tight)
                try expectEqual(tight.state, .done, tight.errorMessage ?? ""); try expect(tight.logText.contains("WARNING: Little free space"), "a warning in the log: \(tight.logText.suffix(300))")
                DiskSpaceGuard.availableOverride = { $0.path.hasPrefix(out) ? 500_000_000_000 : nil }
                let plenty = try await rig.start("https://www.youtube.com/watch?v=big8k3"); try await rig.finish(plenty)
                try expectEqual(plenty.state, .done); try expect(!plenty.logText.contains("free space"), "no warning when there is room")
                DiskSpaceGuard.availableOverride = { $0.path.hasPrefix(out) ? 1_000_000_000 : nil }
                AppSettings.shared.update { $0.freeSpaceGuard = false }
                let off = try await rig.start("https://www.youtube.com/watch?v=big8k4"); try await rig.finish(off)
                try expectEqual(off.state, .done, "the person switched the guard off")
            }
        }

        test("run: with the network switched off the tool is never started and the message says so") {
            try await DownloadRig.with { rig in
                NetworkGate.forbidAll = true
                let job = try await rig.start(video); try await rig.finish(job)
                try expectEqual(job.state, .failed); try expect(job.errorMessage?.contains("switched off") == true, job.errorMessage ?? "")
                try expect(rig.infoInvocations().isEmpty && rig.downloadInvocations().isEmpty, "yt-dlp was not asked anything")
                try expect(rig.tree().isEmpty)
            }
        }

        test("burn-in: the subtitle step builds a safe ffmpeg command with hardware or software encoding") {
            let hw = DownloadBurnIn.arguments(inputName: "/t/in.mp4", subtitleName: "subs.srt", outputName: "out.mp4", hardware: true)
            try expect(hw.contains("subtitles=subs.srt") && dlArg(hw, "-c:v") == "hevc_videotoolbox" && dlArg(hw, "-tag:v") == "hvc1" && dlArg(hw, "-c:a") == "copy", "\(hw)")
            try expect(hw.contains("-sn") && dlArg(hw, "-movflags") == "+faststart" && hw.last == "out.mp4" && hw.contains("-nostdin"))
            let sw = DownloadBurnIn.arguments(inputName: "/t/in.mp4", subtitleName: "subs.srt", outputName: "out.mp4", hardware: false)
            try expect(dlArg(sw, "-c:v") == "libx264" && dlArg(sw, "-crf") == "16" && dlArg(sw, "-pix_fmt") == "yuv420p" && !sw.contains("hevc_videotoolbox"), "\(sw)")
            try expectEqual(sw.filter { $0 == "-map" }.count, 2)
        }

        test("burn-in: a downloaded video gets its subtitles drawn into the picture; without subtitles the person is told", requires: ["tool.ffmpeg", "ff.filter.subtitles"], timeout: 180) {
            let fx = TestFixtures(label: "burn"); defer { fx.cleanup() }
            let payload = try await fx.video("clip.mp4", seconds: 2)
            try await DownloadRig.with(env: ["FAKE_YTDLP_PAYLOAD": payload.path, "FAKE_YTDLP_SUBS": "1"]) { rig in
                let job = try await rig.start(request: rig.request(video) { $0.subtitles = .burn; $0.subtitleLanguages = ["en"] })
                try await rig.finish(job, timeout: 120); try expectEqual(job.state, .done, job.errorMessage ?? job.logText.suffix(500).description)
                let out = try unwrap(job.outputs.first)
                func frameHash(_ url: URL) async throws -> String {
                    let ff = try ToolLocator.shared.require(.ffmpeg)
                    let r = try await ProcessRunner.run(ff, ["-v", "error", "-ss", "1", "-i", url.path, "-frames:v", "1", "-f", "md5", "-"], captureStdout: true, allowNonZeroExit: true, background: false)
                    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let burned = try await frameHash(out), plain = try await frameHash(payload)
                try expect(burned.hasPrefix("MD5=") && plain.hasPrefix("MD5=") && burned != plain, "the picture changed: the words are drawn in (\(burned) vs \(plain))")
                let codecs = try await ctxProbe(out)
                try expect(codecs.contains("h264") || codecs.contains("hevc"), codecs)
                try expectEqual(rig.workAreas(), [])
            }
            try await DownloadRig.with { rig in
                let job = try await rig.start(request: rig.request(video) { $0.subtitles = .burn })
                try await rig.finish(job); try expectEqual(job.state, .done, job.errorMessage ?? "")
                try expect(job.note?.en.contains("no subtitles") == true, job.note?.en ?? "no note")
                try expectEqual(job.outputs.count, 1)
            }
        }
    }
}
