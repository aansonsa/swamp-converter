import Foundation

// Tests: hidden work areas and file placement (clean-up touches only what the downloader created), the info cache and the info fetcher.

extension DownloaderTests {
    static func registerWorkAreas() {
        func touch(_ url: URL, _ text: String = "x") throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        test("work area: a retry finds the same hidden folder; finished files are told from partials, hidden files and strangers") {
            let fx = TestFixtures(label: "wa"); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let a = DownloadWorkArea.make(in: out, key: "youtube:abc|137+140|best")
            try expectEqual(a.root, DownloadWorkArea.make(in: out, key: "youtube:abc|137+140|best").root, "the same download maps to the same folder, so a retry resumes")
            try expect(a.root != DownloadWorkArea.make(in: out, key: "youtube:abc|18|best").root)
            try expect(a.root.lastPathComponent.hasPrefix(".swampdl-") && a.root.deletingLastPathComponent().standardizedFileURL.path == out.standardizedFileURL.path)
            try a.create()
            try touch(a.out.appendingPathComponent("a.mp4")); try touch(a.out.appendingPathComponent("Mix/b.mp4"))
            try touch(a.tmp.appendingPathComponent("a.f137.mp4.part")); try touch(a.out.appendingPathComponent("c.mp4.ytdl")); try touch(a.out.appendingPathComponent(".hidden.mp4"))
            try touch(a.out.appendingPathComponent("d.mp4.part-Frag3")); try touch(a.out.appendingPathComponent("e.temp"))
            try expectEqual(DownloadWorkArea.finishedFiles(in: a.out).map { a.relativePath(of: $0) }, ["Mix/b.mp4", "a.mp4"])
            try expectEqual(a.relativePath(of: URL(fileURLWithPath: "/elsewhere/z.mp4")), "z.mp4")
            for n in ["x.part", "x.ytdl", "x.mp4.part-Frag12", "x.temp", "x.tmp", "x.mp4.ytdl"] { try expect(DownloadFileKinds.isPartial(URL(fileURLWithPath: "/t/\(n)")), n) }
            for n in ["x.mp4", "x.m4a", "x.webm", "x.srt", "part.mp4"] { try expect(!DownloadFileKinds.isPartial(URL(fileURLWithPath: "/t/\(n)")), n) }
            try expect(DownloadFileKinds.isVideo(URL(fileURLWithPath: "/t/X.MKV")) && DownloadFileKinds.isAudio(URL(fileURLWithPath: "/t/a.opus")) && !DownloadFileKinds.isMedia(URL(fileURLWithPath: "/t/a.srt")))
        }

        test("work area: yt-dlp's list of results is data, not an instruction: only files inside the area count") {
            let fx = TestFixtures(label: "wa"); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out"); let secret = try fx.text("secret.txt", "private")
            let a = DownloadWorkArea.make(in: out, key: "k"); try a.create()
            try touch(a.out.appendingPathComponent("ok.mp4"))
            try FileManager.default.createSymbolicLink(at: a.out.appendingPathComponent("link.mp4"), withDestinationURL: secret)
            let listed = [a.out.appendingPathComponent("ok.mp4").path, secret.path, "/etc/hosts", a.out.path + "/../../secret.txt", a.out.appendingPathComponent("missing.mp4").path,
                          a.out.appendingPathComponent("link.mp4").path, a.out.appendingPathComponent("ok.mp4").path, a.out.appendingPathComponent("x.part").path]
            try expectEqual(a.confined(listed).map(\.lastPathComponent), ["ok.mp4"], "outside paths, symlink escapes, missing files, duplicates and partials are dropped")
        }

        test("work area: removal is limited to areas the downloader made; empty and stale ones are cleaned, strangers never") {
            let fx = TestFixtures(label: "wa"); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let stranger = out.appendingPathComponent("Videos"); try touch(stranger.appendingPathComponent("mine.mp4"))
            let foreign = DownloadWorkArea(root: stranger); foreign.remove()
            try expect(TestFile.exists(stranger.appendingPathComponent("mine.mp4")), "remove() refuses a folder without the .swampdl- prefix")
            // removeIfEmpty keeps partials (the next try resumes) and drops an area with nothing in it.
            let empty = DownloadWorkArea.make(in: out, key: "e"); try empty.create(); empty.removeIfEmpty()
            try expect(!TestFile.exists(empty.root), "an area with nothing in it goes away")
            let partial = DownloadWorkArea.make(in: out, key: "p"); try partial.create(); try touch(partial.tmp.appendingPathComponent("v.mp4.part"))
            partial.removeIfEmpty(); try expect(TestFile.exists(partial.root), "partials stay for the resume")
            partial.removeIfNothingFinished(); try expect(!TestFile.exists(partial.root), "nothing finished: the area can go")
            // Stale areas.
            let old = DownloadWorkArea.make(in: out, key: "old"); try old.create(); try touch(old.tmp.appendingPathComponent("v.part"))
            let oldDone = DownloadWorkArea.make(in: out, key: "oldDone"); try oldDone.create(); try touch(oldDone.out.appendingPathComponent("done.mp4"))
            let fresh = DownloadWorkArea.make(in: out, key: "fresh"); try fresh.create(); try touch(fresh.tmp.appendingPathComponent("v.part"))
            let past = Date().addingTimeInterval(-30 * 86_400)
            for a in [old, oldDone] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: a.root.path) }
            DownloadWorkArea.cleanStale(in: out)
            try expect(!TestFile.exists(old.root), "old and unfinished: removed")
            try expect(TestFile.exists(oldDone.root), "old but holding a finished file: kept, the person may still want it")
            try expect(TestFile.exists(fresh.root), "recent: kept (it may be running or about to resume)")
            try expect(TestFile.exists(stranger.appendingPathComponent("mine.mp4")), "the person's own folders are never touched")
        }

        test("placement: finished files move out with collision-safe names, sidecars follow, a cancelled run keeps only finished files") {
            let fx = TestFixtures(label: "wa"); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            try touch(out.appendingPathComponent("a.mp4"), "the person's older file")
            let a = DownloadWorkArea.make(in: out, key: "k"); try a.create()
            try touch(a.out.appendingPathComponent("a.mp4"), "new"); try touch(a.out.appendingPathComponent("Mix/b.mp4"), "b"); try touch(a.tmp.appendingPathComponent("c.mp4.part"), "half")
            try touch(a.out.appendingPathComponent("d.mp4.part"), "half too")
            let placed = DownloadPlacer.salvage(a, into: out)
            try expectEqual(placed.count, 2, "two finished videos were rescued")
            try expectEqual(try String(contentsOf: out.appendingPathComponent("a.mp4"), encoding: .utf8), "the person's older file", "an existing file is never overwritten")
            try expectEqual(try String(contentsOf: out.appendingPathComponent("a (2).mp4"), encoding: .utf8), "new")
            try expectEqual(try String(contentsOf: out.appendingPathComponent("Mix/b.mp4"), encoding: .utf8), "b")
            try expect(!TestFile.exists(a.root), "the work area, partials included, is gone")
            let leftovers = (FileManager.default.enumerator(atPath: out.path)?.allObjects as? [String] ?? []).filter { $0.contains(".part") || $0.hasSuffix(".ytdl") }
            try expectEqual(leftovers, [], "no partial file is left in the output folder")
            // Sidecars.
            let files = ["T [id].mp4", "T [id].en.srt", "T [id].ru.srt", "T [id].jpg", "Other [x].srt"].map { URL(fileURLWithPath: "/w/\($0)") }
            let sidecars = DownloadPlacer.sidecars(of: files[0], in: files)
            try expectEqual(sidecars.map(\.lastPathComponent), ["T [id].en.srt", "T [id].ru.srt", "T [id].jpg"])
            let dest = try fx.makeDirectory("dest")
            let src = try fx.makeDirectory("src")
            var moved: [URL] = []
            for s in ["T [id].en.srt", "T [id].ru.srt"] { let u = src.appendingPathComponent(s); try touch(u); moved.append(u) }
            DownloadPlacer.placeSidecars(moved, rawStem: "T [id]", finalStem: "T [id] (Best for Apple)", into: dest)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted(), ["T [id] (Best for Apple).en.srt", "T [id] (Best for Apple).ru.srt"])
        }

        test("info cache: entries live a minute, the freshest wins, the cache is small") {
            let cache = DownloadInfoCache(); cache.lifetime = 60
            let info = try DownloaderFixtures.info("video.json")
            let t0 = Date()
            cache.put("youtube:abc|flat|one|none", info, now: t0)
            try expect(cache.get("youtube:abc|flat|one|none", now: t0.addingTimeInterval(30)) != nil)
            try expect(cache.latest(forKey: "youtube:abc", now: t0.addingTimeInterval(30)) != nil, "the estimate does not care how the info was fetched")
            try expect(cache.latest(forKey: "youtube:abcd", now: t0.addingTimeInterval(30)) == nil, "a longer id is another video")
            try expect(cache.get("youtube:abc|flat|one|none", now: t0.addingTimeInterval(61)) == nil, "expired after a minute")
            for i in 0..<20 { cache.put("k\(i)|x", info, now: t0.addingTimeInterval(Double(i))) }
            var kept = 0
            for i in 0..<20 where cache.get("k\(i)|x", now: t0.addingTimeInterval(21)) != nil { kept += 1 }
            try expect(kept <= 8 && kept >= 1, "at most 8 entries, got \(kept)")
            try expect(cache.get("k19|x", now: t0.addingTimeInterval(21)) != nil, "the newest survive")
        }

        test("info fetch: parses a good answer once, explains a bad one, gives up politely, and cancels") {
            let json = String(data: try DownloaderFixtures.data("video.json"), encoding: .utf8)!
            let calls = Locked(0)
            let ok: DownloadProcessRunner = { _, _ in calls.value += 1; return ProcessOutput(exitCode: 0, stdout: json, stderrTail: []) }
            DownloadInfoCache.shared.clear()
            let q = DownloadInfoFetcher.Query(url: URL(string: "https://www.youtube.com/watch?v=abc123XYZ_-")!, jsRuntime: nil)
            let first = try await DownloadInfoFetcher.fetch(q, executable: URL(fileURLWithPath: "/bin/echo"), run: ok)
            _ = try await DownloadInfoFetcher.fetch(q, executable: URL(fileURLWithPath: "/bin/echo"), run: ok)
            try expectEqual(first.title, "Болото / Swamp: Part 1"); try expectEqual(calls.value, 1, "the second ask is served from the cache")
            try expectEqual(DownloadInfoCache.shared.latest(forKey: LinkParsing.canonicalKey(of: q.url))?.id, "abc123XYZ_-")
            // The Studio's size estimate reads the information fetched a moment ago (no second request).
            let op = DownloadLinkOperation(mode: .bestForApple, meta: .link("t", L10n("t"), symbol: "x", schema: DownloadSchemas.linkID))
            let link = LinkItem(url: q.url)
            try expectEqual(op.estimateLinks(options: ["dl.mode": "best", "dl.maxHeight": "1080"], links: [link])?.bytes, 199_900_000, "1080p video plus the AAC sound")
            try expectEqual(op.estimateLinks(options: ["dl.mode": "best", "dl.maxHeight": "0"], links: [link])?.bytes, 1_009_900_000)
            try expectEqual(op.estimateLinks(options: ["dl.mode": "audio-m4a"], links: [link])?.bytes, 9_900_000)
            try expect(op.estimateLinks(options: ["dl.mode": "best"], links: [LinkItem(url: URL(string: "https://example.com/never-fetched")!)]) == nil, "no information, no guess")
            DownloadInfoCache.shared.clear()
            try expect(op.estimateLinks(options: ["dl.mode": "best"], links: [link]) == nil)
            var other = q; other.url = URL(string: "https://example.com/private")!
            let bad: DownloadProcessRunner = { _, _ in ProcessOutput(exitCode: 1, stdout: "", stderrTail: ["ERROR: [generic] abc: Private video. Sign in if you've been granted access"]) }
            let err = try await expectThrows { _ = try await DownloadInfoFetcher.fetch(other, executable: URL(fileURLWithPath: "/bin/echo"), run: bad) }
            try expect(ConversionError.describe(err).localizedCaseInsensitiveContains("private") || ConversionError.describe(err).contains("закрыт"), ConversionError.describe(err))
            let slow = try await expectThrows { _ = try await DownloadInfoFetcher.withTimeout(0.1) { try await Task.sleep(nanoseconds: 5_000_000_000) } }
            try expect(ConversionError.describe(slow).contains("too long") || ConversionError.describe(slow).contains("долго"), "a calm timeout message")
            let t0 = Date()
            let task = Task { try await DownloadInfoFetcher.withTimeout(30) { try await Task.sleep(nanoseconds: 20_000_000_000) } }
            try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
            do { _ = try await task.value; throw TestFailure(message: "cancelled fetch returned", file: #fileID, line: #line) } catch is CancellationError {}
            try expect(Date().timeIntervalSince(t0) < 0.5, "cancel is immediate")
        }
    }
}
