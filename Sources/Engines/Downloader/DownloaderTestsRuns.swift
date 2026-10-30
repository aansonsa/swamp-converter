import Foundation

// Tests: whole download jobs against the fake yt-dlp. Real code path: DownloadService -> JobRunner -> DownloadLinkOperation -> DownloadRunner ->
// ProcessRunner -> the fake tool -> work area -> placement. Only the tool is fake.

func dlArg(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
private let video = "https://www.youtube.com/watch?v=abc123XYZ_-"
private let videoFile = "Болото ⧸ Swamp [Part 1] [abc123XYZ_-].mp4"
private let playlistURL = "https://www.youtube.com/playlist?list=PLswampMix"

private func isMonotone(_ values: [Double?]) -> Bool {
    let v = values.compactMap { $0 }
    return v == v.sorted() && v.allSatisfy { $0 >= 0 && $0 <= 1 }
}

extension DownloaderTests {
    static func registerRuns() {
        test("run: a video comes down as two streams with one steady bar, its title, a clean folder and the exact file") {
            try await DownloadRig.with(env: ["FAKE_YTDLP_DELAY": "0.03"]) { rig in
                let job = try await rig.start(video)
                let bar = Recorder(job.$progress); let stages = Recorder(job.$stages)
                try await rig.finish(job)
                try expectEqual(job.state, .done, job.errorMessage ?? job.logText)
                try expectEqual(job.outputs.map { nfc($0.lastPathComponent) }, [nfc(videoFile)], "named from the title and id, in the Movies folder")
                try expectEqual(job.outputs.first?.deletingLastPathComponent().standardizedFileURL.path, rig.outDir.standardizedFileURL.path)
                try expectEqual(TestFile.size(try unwrap(job.outputs.first)), 400_000, "video and sound joined: all the bytes")
                try expectEqual(rig.names().map(nfc), [nfc(videoFile)], "nothing else in the output folder"); try expectEqual(rig.workAreas(), [], "the hidden work folder is gone")
                try expect(isMonotone(bar.values), "the bar never goes backwards: \(bar.values)")
                try expect(bar.values.compactMap { $0 }.filter { $0 > 0.05 && $0 < 0.99 }.count >= 2, "intermediate progress was reported: \(bar.values)")
                try expectEqual(job.progress, 1)
                try expectEqual(stages.values.last?.map(\.id), ["download"], "keeping the original is a one-stage job")
                try await expectEventually(timeout: 2) { job.title.hasPrefix("Download: Болото") }
                try expect(job.logText.contains("Title: Болото") && job.logText.contains("[Merger]") && !job.logLines.contains { $0.hasPrefix("SC|") }, "the log keeps the useful tool lines, not the progress spam")
                try expectEqual(rig.infoInvocations().count, 1); try expectEqual(rig.downloadInvocations().count, 1)
                let a = try unwrap(rig.downloadInvocations().first)
                try expectEqual(dlArg(a, "-f"), "313+140/bv*+ba/b", "the streams were chosen from the page, with the generic expression behind them")
                try expectEqual(Array(a.suffix(2)), ["--", video]); try expect(!a.contains("--cookies-from-browser") && !a.contains("--limit-rate") && !a.contains("--download-sections"))
                let homes = a.indices.filter { a[$0] == "-P" }.map { a[$0 + 1] }
                try expect(homes[0].hasPrefix("home:\(rig.outDir.path)/\(DownloadWorkArea.prefix)") && homes[0].hasSuffix("/out") && homes[1].hasSuffix("/tmp"), "downloads live in a hidden folder next to the result: \(homes)")
                let list = try unwrap(dlArg(a, "--print-to-file") == "after_move:filepath" ? a[a.firstIndex(of: "--print-to-file")! + 2] : nil)
                try expect(!list.hasPrefix(rig.outDir.path), "the result list is the job's private file, not in the output folder")
                let info = try unwrap(rig.infoInvocations().first); try expect(info.contains("--flat-playlist") && info.contains("--no-playlist") && info.contains("-J"))
            }
        }

        test("run: Best for Apple is a two-stage job; the convert stage gets the download, replaces it and keeps its name", oracles: ["dl.after.convert"]) {
            try await DownloadRig.with(settings: { $0.afterDownload = .bestForApple }) { rig in
                let calls = Locked<[(String, AfterDownload)]>([])
                DownloadPostProcess.override = { source, after, rules, ctx in
                    calls.withLock { $0.append((source.path, after)) }
                    ctx.report(0.5, message: "converting")
                    let url = try await OutputPaths.produceFile(dir: URL(fileURLWithPath: rules.customDir ?? ""), base: source.deletingPathExtension().lastPathComponent, ext: "mov", collision: rules.collision) { tmp in
                        try Data("converted".utf8).write(to: tmp)
                    }
                    return [url]
                }
                let job = try await rig.start(video)
                let stages = Recorder(job.$stages); let bar = Recorder(job.$progress)
                try await rig.finish(job)
                try expectEqual(job.state, .done, job.errorMessage ?? job.logText)
                let last = try unwrap(stages.values.last)
                try expectEqual(last.map(\.id), ["download", "convert"]); try expect(last.allSatisfy { $0.state == .done }, "both stages done: \(last.map(\.state))")
                try expectEqual(last.map(\.spec.weight), [0.6, 0.4])
                let order = stages.values.compactMap { s in s.first { $0.state == .running }?.id }
                try expect(order.first == "download" && order.last == "convert" && order.firstIndex(of: "convert")! > order.lastIndex(of: "download")!, "download first, then convert: \(order)")
                try expect(isMonotone(bar.values) && job.progress == 1, "one bar across both stages: \(bar.values)")
                try expectEqual(calls.value.count, 1); try expectEqual(calls.value[0].1, .bestForApple)
                try expect(calls.value[0].0.contains("/\(DownloadWorkArea.prefix)") && calls.value[0].0.hasSuffix(".mp4"), "the convert stage reads the downloaded file")
                try expectEqual(rig.names().map(nfc), [nfc(videoFile.replacingOccurrences(of: ".mp4", with: ".mov"))], "the converted file replaces the download under the same name")
                try expectEqual(rig.workAreas(), [])
                // Universal and a Studio preset reach the same stage; keep original skips it.
                calls.value = []
                _ = try await rig.download("https://www.youtube.com/watch?v=second1", mode: .universal)
                rig.configure { $0.afterDownload = .keepOriginal }
                _ = try await rig.download("https://www.youtube.com/watch?v=third1")
                _ = try await rig.download("https://www.youtube.com/watch?v=fourth1", mode: .maximum)
                try expectEqual(calls.value.map(\.1), [.universal], "Universal converts; keep-original and Maximum never do")
            }
        }

        test("run: when the conversion fails the download is kept and the person is told why") {
            try await DownloadRig.with(settings: { $0.afterDownload = .bestForApple }) { rig in
                DownloadPostProcess.override = { _, _, _, _ in throw ConversionError.message(L10n("boom", "бум")) }
                let job = try await rig.download(video)
                try expectEqual(job.outputs.map { nfc($0.lastPathComponent) }, [nfc(videoFile)], "the file as downloaded")
                try expect(job.note?.en.contains("saved as downloaded") == true && job.note?.en.contains("boom") == true, job.note?.en ?? "no note")
                try expectEqual(rig.workAreas(), [])
            }
        }

        test("run: Best for Apple with the real smart converter turns the download into a playable MP4", requires: ["tool.ffmpeg"], timeout: 180) {
            guard OperationRegistry.shared.operation(id: "smart.best") != nil else { try skipTest("the smart module is not registered in this run") }
            let fx = TestFixtures(label: "payload"); defer { fx.cleanup() }
            let payload = try await fx.video("clip.mp4", seconds: 2)
            try await DownloadRig.with(env: ["FAKE_YTDLP_PAYLOAD": payload.path], settings: { $0.afterDownload = .bestForApple }) { rig in
                let job = try await rig.download(video, timeout: 120)
                let out = try unwrap(job.outputs.first, "an output")
                if job.note?.en.contains("not implemented") == true { try skipTest("the smart converter of this build is only the skeleton stub") }
                try expect(job.note == nil, "the conversion must not have failed quietly: \(job.note?.en ?? "")")
                try expect(job.logText.contains("ffmpeg") && job.logText.contains(".swampdl-"), "the converter really ran on the downloaded file:\n\(job.logText.suffix(900))")
                try expect(["mp4", "mov"].contains(out.pathExtension.lowercased()), out.lastPathComponent)
                try expect(TestFile.size(out) > 1000, "a real file")
                try expectEqual(nfc(out.deletingPathExtension().lastPathComponent), nfc(videoFile.replacingOccurrences(of: ".mp4", with: "")), "the converted file keeps the download's name, no suffix, no stray space")
                try expectEqual(rig.names().count, 1, "only the converted file is left in the folder: \(rig.names())")
                let probe = try await ctxProbe(out)
                try expect(probe.contains("h264") || probe.contains("hevc"), "an Apple-friendly video stream: \(probe)")
                try expectEqual(rig.workAreas(), [])
                try expect(job.stages.map(\.id) == ["download", "convert"] && job.stages.allSatisfy { $0.state == .done || $0.state == .skipped }, "\(job.stages.map { "\($0.id):\($0.state)" })")
            }
        }

        test("run: sound-only modes land in the Music folder as M4A, MP3 or Opus in one stage", oracles: ["dl.audio.format", "dl.audio.quality", "dl.mode.selector"]) {
            try await DownloadRig.with { rig in
                let page = "https://soundcloud.com/swamp/audio-track"
                let m4a = try await rig.download(page, mode: .audioM4A)
                try expectEqual(m4a.outputs.map(\.lastPathComponent), ["Swamp ambience [snd_one].m4a"]); try expectEqual(m4a.outputs.first?.deletingLastPathComponent().standardizedFileURL.path, rig.audioDir.standardizedFileURL.path)
                try expectEqual(m4a.stages.map(\.id), ["download"], "sound needs no second stage")
                let a = try unwrap(rig.downloadInvocations().last)
                try expect(a.contains("-x") && dlArg(a, "--audio-format") == "m4a" && !a.contains("--merge-output-format") && dlArg(a, "-f") == "http_mp3/ba[ext=m4a]/ba/b", "\(a)")
                try expectEqual(rig.names(), [], "no sound in the Movies folder")
                let mp3 = try await rig.download(page + "2", mode: .audioMP3)
                try expectEqual(mp3.outputs.map(\.pathExtension), ["mp3"]); try expect(dlArg(try unwrap(rig.downloadInvocations().last), "--audio-format") == "mp3")
                // Studio: a format and quality of the person's choosing.
                let opus = try await rig.start(request: rig.request(page + "3") { $0.mode = .audioM4A; $0.audioFormat = .opus; $0.outputDirectory = rig.audioDir })
                try await rig.finish(opus); try expectEqual(opus.outputs.map(\.pathExtension), ["opus"], opus.errorMessage ?? "")
                let q = try await rig.start(request: rig.request(page + "4") { $0.mode = .audioMP3; $0.audioQuality = 192; $0.outputDirectory = rig.audioDir })
                try await rig.finish(q); let args = try unwrap(rig.downloadInvocations().last)
                try expectEqual(dlArg(args, "--audio-quality"), "192K"); try expectEqual(q.outputs.map(\.pathExtension), ["mp3"])
            }
        }

        test("run: cancelling stops yt-dlp at once and removes ONLY its own partial files", timeout: 60) {
            try await DownloadRig.with(env: ["FAKE_YTDLP_DELAY": "0.15"]) { rig in
                try Data("mine".utf8).write(to: rig.outDir.appendingPathComponent("mine.mp4.part")); try Data("note".utf8).write(to: rig.outDir.appendingPathComponent("notes.txt"))
                try FileManager.default.createDirectory(at: rig.outDir.appendingPathComponent("Old"), withIntermediateDirectories: true)
                try Data("old".utf8).write(to: rig.outDir.appendingPathComponent("Old/earlier.ytdl"))
                let job = try await rig.start(video)
                try await expectEventually(timeout: 10) { rig.tree().contains { $0.hasSuffix(".part") && $0.contains(DownloadWorkArea.prefix) } }
                try expect(rig.tree().contains { $0.hasSuffix(".ytdl") && $0.contains(DownloadWorkArea.prefix) }, "yt-dlp's resume marker exists while it runs")
                let t0 = Date()
                rig.runner.cancel(job)
                try await expectEventually(timeout: 5) { job.state.isFinished }
                let took = Date().timeIntervalSince(t0)
                try expectEqual(job.state, .cancelled); try expect(took < 0.5, "cancelled in \(Int(took * 1000)) ms (the kill itself takes a few)")
                try await expectEventually(timeout: 1) { ProcessRegistry.shared.count == 0 }
                try await expectEventually(timeout: 2) { rig.workAreas().isEmpty }
                try expectEqual(rig.tree(), ["Old/earlier.ytdl", "mine.mp4.part", "notes.txt"], "the person's files, even ones that look like partials, are untouched; ours are gone")
                try expect(job.outputs.isEmpty)
            }
        }

        test("run: cancelling a list keeps the videos that were finished and removes the half-done one", timeout: 60) {
            try await DownloadRig.with(env: ["FAKE_YTDLP_DELAY": "0.08", "FAKE_YTDLP_TOTAL": "80000"]) { rig in
                let job = try await rig.start(request: rig.request(playlistURL) { $0.playlistItems = "" })
                try await expectEventually(timeout: 15) { rig.tree().contains { $0.contains(DownloadWorkArea.prefix) && $0.contains("/out/") && $0.hasSuffix(".mp4") } }
                rig.runner.cancel(job)
                try await expectEventually(timeout: 5) { job.state.isFinished }
                try expectEqual(job.state, .cancelled)
                try await expectEventually(timeout: 2) { rig.workAreas().isEmpty }
                let left = rig.tree()
                try expect(left.contains { $0.hasPrefix("First swamp") && $0.hasSuffix(".mp4") }, "the finished video was rescued: \(left)")
                try expect(!left.contains { $0.contains(".part") || $0.hasSuffix(".ytdl") }, "no partial file is left: \(left)")
                try expect(left.count < 3, "the list was not finished: \(left)")
            }
        }

        test("run: cancelling while the site is still being asked leaves nothing behind", timeout: 60) {
            try await DownloadRig.with(env: ["FAKE_YTDLP_INFO_DELAY": "6"]) { rig in
                let job = try await rig.start(video)
                try await expectEventually(timeout: 5) { ProcessRegistry.shared.count == 1 }
                try await Task.sleep(nanoseconds: 300_000_000)   // let the fake reach its sleep (a child forked during the kill would outlive it by up to 2 s)
                let t0 = Date(); rig.runner.cancel(job)
                try await expectEventually(timeout: 5) { job.state.isFinished }
                try expectEqual(job.state, .cancelled); try expect(Date().timeIntervalSince(t0) < 1.5, "cancelled within a moment")
                try await expectEventually(timeout: 1) { ProcessRegistry.shared.count == 0 }
                try expect(rig.tree().isEmpty && rig.workAreas().isEmpty && rig.downloadInvocations().isEmpty, "no folder, no file, no download was started")
            }
        }

        test("run: an interrupted download keeps its partial file and the next try resumes from it") {
            try await DownloadRig.with(env: ["FAKE_YTDLP_FAIL_AT": "5"]) { rig in
                let failed = try await rig.start(video)
                try await rig.finish(failed)
                try expectEqual(failed.state, .failed)
                try expect(failed.errorMessage?.contains("Could not reach the site") == true, failed.errorMessage ?? "")
                let partials = rig.tree().filter { $0.contains(".part") && !$0.hasSuffix(".ytdl") }
                try expectEqual(partials.count, 1, "the partial file is kept for the resume: \(rig.tree())")
                try expectEqual(rig.workAreas().count, 1)
                let before = TestFile.size(rig.outDir.appendingPathComponent(partials[0]))
                try expect(before > 0 && before < 400_000, "half a file: \(before) bytes")
                try rig.setEnv([:])
                let again = try await rig.download(video)
                try expect(again.logText.contains("Resuming download at byte \(before)"), "the second run continues where the first stopped: \(again.logText.suffix(400))")
                try expect(try unwrap(rig.downloadInvocations().last).contains("--continue"))
                try expectEqual(TestFile.size(try unwrap(again.outputs.first)), 400_000, "the file is complete")
                try expectEqual(rig.names().map(nfc), [nfc(videoFile)]); try expectEqual(rig.workAreas(), [])
            }
        }

        test("run: the same video downloaded twice never overwrites; the second file gets a new name") {
            try await DownloadRig.with { rig in
                _ = try await rig.download(video)
                let second = try await rig.download(video)
                try expectEqual(rig.names().map(nfc), [nfc(videoFile.replacingOccurrences(of: ".mp4", with: " (2).mp4")), nfc(videoFile)].sorted())
                try expectEqual(second.outputs.map { nfc($0.lastPathComponent) }, [nfc(videoFile.replacingOccurrences(of: ".mp4", with: " (2).mp4"))])
            }
        }

        test("run: playlists need a choice; chosen numbers download exactly those videos with numbered names", oracles: ["dl.playlist.items", "dl.template.output"]) {
            try await DownloadRig.with { rig in
                // The quick path refuses to guess, and says what to do.
                let quick = try await rig.start(playlistURL); try await rig.finish(quick)
                try expectEqual(quick.state, .failed); try expect(quick.errorMessage?.contains("list of 3 videos") == true, quick.errorMessage ?? "")
                try expect(rig.downloadInvocations().isEmpty && rig.workAreas().isEmpty, "nothing was downloaded")
                let empty = try await rig.start("https://www.youtube.com/playlist?list=nolist"); try await rig.finish(empty)
                try expectEqual(empty.state, .failed); try expect(empty.errorMessage?.contains("list is empty") == true, empty.errorMessage ?? "")
                // Studio: videos 1 and 3 with the position in the name.
                let some = try await rig.start(request: rig.request(playlistURL) { $0.playlistItems = "1,3"; $0.filenameTemplate = "%(playlist_index)02d - %(title)s.%(ext)s" })
                let bar = Recorder(some.$progress)
                try await rig.finish(some); try expectEqual(some.state, .done, some.errorMessage ?? some.logText)
                try expectEqual(rig.names().map(nfc), ["01 - First swamp.mp4", "03 - Third swamp.mp4"], "the position in the list is in the name, only the chosen ones came down")
                let a = try unwrap(rig.downloadInvocations().last)
                try expect(a.contains("--yes-playlist") && dlArg(a, "--playlist-items") == "1,3" && !a.contains("--no-playlist"), "\(a)")
                try expectEqual(dlArg(a, "-o"), "%(playlist_index)02d - %(title)s.%(ext)s")
                let info = try unwrap(rig.infoInvocations().last); try expect(info.contains("--yes-playlist") && info.contains("--flat-playlist"))
                try expect(isMonotone(bar.values) && some.progress == 1, "a list is one bar: \(bar.values)")
                try expectEqual(some.outputs.count, 2)
                let all = try await rig.start(request: rig.request(playlistURL) { $0.playlistItems = ""; $0.outputDirectory = rig.audioDir })
                try await rig.finish(all); try expectEqual(all.outputs.count, 3, all.errorMessage ?? "")
                let b = try unwrap(rig.downloadInvocations().last); try expect(b.contains("--yes-playlist") && !b.contains("--playlist-items"))
            }
        }

        test("run: a part of the video is requested with its time range", requires: ["tool.ffmpeg"], oracles: ["dl.section.range"]) {
            try await DownloadRig.with { rig in
                let full = try await rig.download(video)
                try expectEqual(TestFile.size(try unwrap(full.outputs.first)), 400_000)
                let cut = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=cutme") { $0.sectionStart = 10; $0.sectionEnd = 20.5 })
                try await rig.finish(cut); try expectEqual(cut.state, .done, cut.errorMessage ?? cut.logText)
                try expectEqual(dlArg(try unwrap(rig.downloadInvocations().last), "--download-sections"), "*10-20.500")
                try expect(TestFile.size(try unwrap(cut.outputs.first)) == 100_000, "the part is smaller than the whole")
                let open = try await rig.start(request: rig.request("https://www.youtube.com/watch?v=cutme2") { $0.sectionStart = 90 })
                try await rig.finish(open); try expectEqual(dlArg(try unwrap(rig.downloadInvocations().last), "--download-sections"), "*90-inf")
                // The quick path never cuts.
                let quick = try await rig.download("https://www.youtube.com/watch?v=nocut")
                try expect(!(try unwrap(rig.downloadInvocations().last)).contains("--download-sections"), quick.logText)
            }
        }

        test("run: every failure of the site ends as a calm sentence, with nothing downloaded and nothing left over") {
            try await DownloadRig.with { rig in
                let cases: [(String, String)] = [("private-video", "private"), ("unsupported-page", "no video on this page"), ("signin-needed", "Cookies"), ("geo-blocked", "not available in your country"),
                                                 ("drm-stuff", "DRM"), ("offline-now", "Could not reach the site"), ("notfound-gone", "not available any more"), ("live-stream", "live stream that is still running")]
                for (word, expected) in cases {
                    let job = try await rig.start("https://example.com/watch/\(word)")
                    try await rig.finish(job)
                    try expectEqual(job.state, .failed, word)
                    try expect(job.errorMessage?.localizedCaseInsensitiveContains(expected) == true, "\(word): \(job.errorMessage ?? "nil")")
                    try expect(!(job.errorMessage ?? "").contains("ERROR:") && !(job.errorMessage ?? "").contains("Traceback"), "no raw tool output: \(job.errorMessage ?? "")")
                }
                try expect(rig.downloadInvocations().isEmpty, "the download was never started for a page that cannot be downloaded")
                try expect(rig.tree().isEmpty && rig.workAreas().isEmpty, "nothing in the output folder")
            }
        }

        test("run: several links in one job: the ones that work arrive, the others are listed as failures") {
            try await DownloadRig.with { rig in
                let op = try unwrap(rig.registry.operation(id: "link.best"))
                let good = LinkItem(url: URL(string: video)!), bad = LinkItem(url: URL(string: "https://example.com/private-one")!)
                let job = rig.runner.submit(operation: op, links: [bad, good], overrides: OptionValues(), origin: .other, mode: .quick)
                try await rig.finish(job); try expectEqual(job.state, .done, job.errorMessage ?? "")
                try expectEqual(job.outputs.count, 1); try expectEqual(job.failures.count, 1); try expect(job.failures[0].contains("private") || job.failures[0].contains("example.com"), job.failures[0])
                let none = rig.runner.submit(operation: op, links: [bad, LinkItem(url: URL(string: "https://example.com/unsupported-two")!)], overrides: OptionValues(), origin: .other, mode: .quick)
                try await rig.finish(none); try expectEqual(none.state, .failed)
            }
        }
    }

    /// `ffprobe -show_entries stream=codec_name` of a file, as one string.
    static func ctxProbe(_ url: URL) async throws -> String {
        guard let ffprobe = ToolLocator.shared.url(.ffprobe) else { return "" }
        let out = try await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path], captureStdout: true, allowNonZeroExit: true, background: false)
        return out.stdout.replacingOccurrences(of: "\n", with: " ")
    }
}
