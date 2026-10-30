import Foundation

// Tests: option mapping (quick recipe, Studio request, schema conditions), progress lines, the progress mapper and sink,
// work areas and file placement, the info cache and the info fetcher.

private func withEnglish<T>(_ body: () throws -> T) rethrows -> T {
    let saved = Loc.shared.setting
    Loc.shared.set(.english)
    defer { Loc.shared.set(saved) }
    return try body()
}

extension DownloaderTests {
    // MARK: Mapping

    static func registerMapping() {
        let schema = DownloadSchemas.link(settings: DownloaderSettings())

        test("options: the quick recipe of each mode resolves to the documented request", oracles: ["dl.mode.selector", "dl.after.convert"]) {
            let settings = SettingsData()
            let expectAfter: [DownloadMode: String] = [.bestForApple: "best", .maximum: "keep", .universal: "universal", .audioM4A: "keep", .audioMP3: "keep"]
            for mode in DownloadMode.allCases {
                let op = DownloadLinkOperation(mode: mode, meta: .link("t.\(mode.rawValue)", mode.title, symbol: mode.symbol, schema: DownloadSchemas.linkID))
                let resolved = schema.resolve(layers: [op.quickOverrides(settings: settings)])
                try expectEqual(resolved.values.string(DownloadKeys.mode), mode.rawValue)
                try expectEqual(DownloadOptionsMapper.effectiveAfter(resolved.values).stringValue, expectAfter[mode]!, "after-download for \(mode)")
                let req = DownloadOptionsMapper.request(from: resolved.values, url: URL(string: "https://example.com/v")!, settings: settings, active: resolved.isActive)
                try expectEqual(req.mode, mode); try expectEqual(req.audioFormat, mode == .audioMP3 ? .mp3 : .m4a)
                try expectEqual(req.maxHeight, nil, "the quick recipe takes the best quality")
                try expectEqual(req.playlistItems, nil, "the quick recipe downloads one video")
                try expectEqual(req.cookies, .none); try expectEqual(req.rateLimitKBps, 0)
                try expectEqual(req.concurrentFragments, 4, "the default is four parts at a time")
                try expectEqual(req.outputDirectory.path, DownloadFolders.resolve(audioOnly: mode.isAudioOnly, settingsFolder: nil).path)
            }
            // The user's defaults from Settings > Downloader flow into the recipe.
            var s = SettingsData()
            s.downloader.afterDownload = .universal; s.downloader.cookies = .chrome; s.downloader.rateLimitKBps = 250
            s.downloader.subtitles = true; s.downloader.burnSubtitles = true; s.downloader.subtitleLanguages = "lv"; s.downloader.embedThumbnail = false
            s.downloader.folder = "/tmp/dl folder"; s.downloader.concurrentFragments = 6
            let best = DownloadLinkOperation(mode: .bestForApple, meta: .link("t.best", L10n("b"), symbol: "x", schema: DownloadSchemas.linkID))
            let r = schema.resolve(layers: [best.quickOverrides(settings: s)])
            let req = DownloadOptionsMapper.request(from: r.values, url: URL(string: "https://example.com/v")!, settings: s, active: r.isActive)
            try expectEqual(req.after, .universal); try expectEqual(req.cookies, .chrome); try expectEqual(req.rateLimitKBps, 250); try expectEqual(req.concurrentFragments, 6)
            try expectEqual(req.subtitles, Capabilities.shared.has("ff.filter.subtitles") ? .burn : .soft, "burning needs libass; without it the subtitles are kept inside the video"); try expectEqual(req.subtitleLanguages, ["lv"]); try expectEqual(req.embedThumbnail, false)
            try expectEqual(req.outputDirectory.path, "/tmp/dl folder")
        }

        test("options: a Studio request survives the round trip through the schema (Quick and Studio are one engine)", oracles: ["dl.folder.output", "dl.playlist.items"]) {
            var original = DownloadRequest(url: URL(string: "https://example.com/v")!, outputDirectory: URL(fileURLWithPath: "/tmp/studio out", isDirectory: true))
            original.mode = .universal; original.maxHeight = 720; original.after = .universal
            original.subtitles = .soft; original.subtitleLanguages = ["ru", "en"]; original.sectionStart = 5; original.sectionEnd = 15.5
            original.playlistItems = "2-4"; original.cookies = .chrome; original.rateLimitKBps = 200; original.concurrentFragments = 6
            original.embedMetadata = false; original.embedThumbnail = false; original.filenameTemplate = "%(uploader)s - %(title)s.%(ext)s"
            let resolved = schema.resolve(layers: [DownloadOptionsMapper.options(from: original)])
            var back = DownloadOptionsMapper.request(from: resolved.values, url: original.url, settings: SettingsData(), active: resolved.isActive)
            // Fields that need ffmpeg are inactive on a Mac without it; the rest must come back exactly.
            if !resolved.isActive(DownloadKeys.sectionStart) { back.sectionStart = original.sectionStart; back.sectionEnd = original.sectionEnd }
            if !resolved.isActive(DownloadKeys.subtitles) { back.subtitles = original.subtitles }
            try expectEqual(back, original)
            // Playlist modes.
            func items(_ v: OptionValues) -> String? { DownloadOptionsMapper.request(from: schema.resolve(layers: [v]).values, url: original.url, settings: SettingsData()).playlistItems }
            try expectEqual(items(["dl.playlist": "single", "dl.playlist.items": "9"]), nil, "numbers typed earlier do not leak when the list option is off")
            try expectEqual(items(["dl.playlist": "all"]), "")
            try expectEqual(items(["dl.playlist": "items", "dl.playlist.items": "1, 3,5-7"]), "1,3,5-7")
            try expectEqual(DownloadOptionsMapper.itemCount(of: "1,3,5-7"), 5); try expectEqual(DownloadOptionsMapper.itemCount(of: "2-"), nil); try expectEqual(DownloadOptionsMapper.itemCount(of: "x"), nil)
            // An unsafe template falls back to the default one instead of reaching yt-dlp.
            let evil = schema.resolve(layers: [["dl.template": "../../x.%(ext)s"]])
            let safe = DownloadOptionsMapper.request(from: evil.values, url: original.url, settings: SettingsData(), active: evil.isActive)
            try expect(YtDlpArguments.isSafeTemplate(safe.filenameTemplate) && !safe.filenameTemplate.contains(".."))
        }

        test("options: conditions hide what does not apply and stage plans follow the options") {
            func resolve(_ v: OptionValues) -> ResolvedOptions { schema.resolve(layers: [v]) }
            let audio = resolve(["dl.mode": "audio-m4a", "dl.maxHeight": "720", "dl.subs.mode": "soft"])
            try expect(!audio.isActive(DownloadKeys.maxHeight) && !audio.isActive(DownloadKeys.subtitles), "a picture cap and subtitles do not apply to sound")
            try expect(audio.isActive(DownloadKeys.audioFormat))
            try expect(!resolve(["dl.mode": "best"]).isActive(DownloadKeys.audioFormat))
            try expect(resolve(["dl.mode": "audio-mp3"]).isActive(DownloadKeys.audioQuality))
            try expect(resolve(["dl.mode": "audio-m4a", "dl.audio.format": "mp3"]).isActive(DownloadKeys.audioQuality))
            try expect(!resolve(["dl.mode": "audio-m4a", "dl.audio.format": "flac"]).isActive(DownloadKeys.audioQuality))
            try expect(!resolve(["dl.subs.mode": "none"]).isActive(DownloadKeys.subtitleLanguages))
            try expect(resolve(["dl.subs.mode": "external"]).isActive(DownloadKeys.subtitleLanguages))
            func plan(_ mode: DownloadMode, _ extra: OptionValues = OptionValues()) -> [String] {
                let op = DownloadLinkOperation(mode: mode, meta: .link("t", mode.title, symbol: "x", schema: DownloadSchemas.linkID))
                let r = schema.resolve(layers: [op.quickOverrides(settings: SettingsData()), extra])
                return op.stagePlan(options: r.values).map(\.id)
            }
            try expectEqual(plan(.bestForApple), ["download", "convert"]); try expectEqual(plan(.universal), ["download", "convert"])
            try expectEqual(plan(.maximum), ["download"]); try expectEqual(plan(.audioM4A), ["download"]); try expectEqual(plan(.audioMP3), ["download"])
            try expectEqual(plan(.bestForApple, ["dl.after": "keep"]), ["download"], "keep original: no second stage")
            let burning = DownloadLinkOperation(mode: .maximum, meta: .link("t", L10n("t"), symbol: "x", schema: DownloadSchemas.linkID))
            try expectEqual(burning.stagePlan(options: ["dl.mode": "max", "dl.after": "keep", "dl.subs.mode": "burn"]).map(\.id), ["download", "convert"], "burning subtitles needs the convert stage")
            let op = DownloadLinkOperation(mode: .bestForApple, meta: .link("t", L10n("t"), symbol: "x", schema: DownloadSchemas.linkID))
            try expect(op.stagePlan(options: OptionValues()).first?.weight ?? 0 > (op.stagePlan(options: OptionValues()).last?.weight ?? 1), "the download carries 0.6 of the bar, the conversion 0.4")
            let chips = DownloadLinkOperation(mode: .bestForApple, meta: .link("t", L10n("t"), symbol: "x", schema: DownloadSchemas.linkID))
            try withEnglish {
                try expectEqual(chips.summaryChips(options: ["dl.mode": "best", "dl.maxHeight": "1080"], source: nil), ["Best for Apple", "1080p"])
                try expectEqual(chips.summaryChips(options: ["dl.mode": "audio-mp3"], source: nil), ["Audio MP3", "MP3"])
                try expectEqual(chips.summaryChips(options: ["dl.mode": "audio-m4a", "dl.audio.format": "opus"], source: nil), ["Audio M4A", "OPUS"])
            }
            // Validation messages in plain words.
            try expect(op.validate(options: ["dl.section.start": 30.0, "dl.section.end": 10.0], source: nil).contains { $0.severity == .error }, "end before start")
            try expect(op.validate(options: ["dl.playlist": "items", "dl.playlist.items": " "], source: nil).contains { $0.severity == .error }, "empty numbers")
            try expect(op.validate(options: ["dl.section.start": 10.0, "dl.section.end": 30.0], source: nil).isEmpty)
        }

        test("folders: Movies for video, Music for sound, a chosen folder wins, a relative path is ignored") {
            let saved = DownloadFolders.rootsOverride
            DownloadFolders.rootsOverride = nil
            defer { DownloadFolders.rootsOverride = saved }
            try expect(DownloadFolders.resolve(audioOnly: false, settingsFolder: nil).path.hasSuffix("/Movies/Swamp Converter"))
            try expect(DownloadFolders.resolve(audioOnly: true, settingsFolder: nil).path.hasSuffix("/Music/Swamp Converter"))
            try expectEqual(DownloadFolders.resolve(audioOnly: false, settingsFolder: "~/Foo").path, NSHomeDirectory() + "/Foo")
            try expectEqual(DownloadFolders.resolve(audioOnly: false, settingsFolder: "/a", override: "/b").path, "/b", "the job's own folder beats the setting")
            try expect(DownloadFolders.resolve(audioOnly: false, settingsFolder: "relative/dir").path.hasSuffix("/Movies/Swamp Converter"))
            try expect(DownloadFolders.resolve(audioOnly: false, settingsFolder: "   ", override: "").path.hasSuffix("/Movies/Swamp Converter"))
            let svc = DownloadService.shared
            try expect(svc.outputDirectory(for: .bestForApple, settings: DownloaderSettings()).path.hasSuffix("/Movies/Swamp Converter"))
            try expect(svc.outputDirectory(for: .audioMP3, settings: DownloaderSettings()).path.hasSuffix("/Music/Swamp Converter"))
            var chosen = DownloaderSettings(); chosen.folder = "/tmp/chosen"
            try expectEqual(svc.outputDirectory(for: .audioM4A, settings: chosen).path, "/tmp/chosen")
        }
    }

    // MARK: Progress lines

    static func registerProgress() {
        test("progress: templated lines carry bytes, speed, ETA and the playlist position; NA values stay unknown") {
            let p = try unwrap(YtDlpProgressParser.parse(line: "SC|downloading|1048576|10485760|NA|1048576.0|9|NA|NA"))
            try expectEqual(p.phase, .downloading); try expectClose(try unwrap(p.fraction), 0.1)
            try expectEqual(p.downloadedBytes, 1_048_576); try expectEqual(p.totalBytes, 10_485_760); try expectEqual(p.bytesPerSecond, 1_048_576); try expectEqual(p.eta, 9)
            try expectEqual(p.itemIndex, nil)
            let prefixed = try unwrap(YtDlpProgressParser.parse(line: "download:SC|downloading|500|NA|1000|NA|NA|2|5"))
            try expectClose(try unwrap(prefixed.fraction), 0.5); try expectEqual(prefixed.totalBytes, 1000, "the estimate is used when the exact total is missing")
            try expectEqual(prefixed.bytesPerSecond, nil); try expectEqual(prefixed.eta, nil); try expectEqual(prefixed.itemIndex, 2); try expectEqual(prefixed.itemCount, 5)
            try expectEqual(try unwrap(YtDlpProgressParser.parse(line: "SC|downloading|NA|NA|NA|NA|NA|NA|NA")).fraction, nil)
            try expectEqual(try unwrap(YtDlpProgressParser.parse(line: "SC|finished|1000|1000|NA|NA|0|NA|NA")).fraction, 1)
            try expectClose(try unwrap(YtDlpProgressParser.parse(line: "SC|downloading|9000|1000|NA|NA|0|NA|NA")?.fraction), 1, "never above 100 percent")
            try expectEqual(YtDlpProgressParser.parse(line: "SC|downloading|1|2"), nil, "a truncated line is ignored")
            // A real run of the template through the app's own template text.
            try expect(YtDlpProgressParser.template.contains("progress.downloaded_bytes") && YtDlpProgressParser.template.contains("playlist_autonumber"))
        }

        test("progress: plain yt-dlp lines give phases, destinations and sizes; nonsense is ignored") {
            let plain = try unwrap(YtDlpProgressParser.parse(line: "[download]  45.3% of ~ 10.00MiB at  1.20MiB/s ETA 00:05 (frag 3/20)"))
            try expectClose(try unwrap(plain.fraction), 0.453); try expectEqual(plain.totalBytes, 10 * 1_048_576)
            try expectClose(try unwrap(plain.bytesPerSecond), 1.2 * 1_048_576, tolerance: 2); try expectEqual(plain.eta, 5)
            try expectClose(try unwrap(YtDlpProgressParser.parse(line: "[download] 100% of 10.00MiB in 00:00:03 at 3.00MiB/s")?.fraction), 1)
            let dest = try unwrap(YtDlpProgressParser.parse(line: "[download] Destination: /tmp/x/file.f137.mp4"))
            try expectEqual(dest.fileName, "file.f137.mp4"); try expectEqual(dest.fraction, nil)
            try expectEqual(YtDlpProgressParser.destinationPath(in: "[download] Destination: /tmp/x/file.f137.mp4"), "/tmp/x/file.f137.mp4")
            let item = try unwrap(YtDlpProgressParser.parse(line: "[download] Downloading item 2 of 5"))
            try expectEqual(item.itemIndex, 2); try expectEqual(item.itemCount, 5)
            try expectEqual(try unwrap(YtDlpProgressParser.parse(line: "[download] Resuming download at byte 1234")).phase, .downloading)
            try expectEqual(try unwrap(YtDlpProgressParser.parse(line: "[download] a.mp4 has already been downloaded")).phase, .finished)
            let merge = try unwrap(YtDlpProgressParser.parse(line: "[Merger] Merging formats into \"/tmp/a b/a.mp4\""))
            try expectEqual(merge.phase, .merging); try expectEqual(merge.fileName, "a.mp4")
            try expectEqual(YtDlpProgressParser.destinationPath(in: "[Merger] Merging formats into \"/tmp/a b/a.mp4\""), "/tmp/a b/a.mp4")
            let audio = try unwrap(YtDlpProgressParser.parse(line: "[ExtractAudio] Destination: /tmp/a.m4a"))
            try expectEqual(audio.phase, .extractingAudio); try expectEqual(audio.fileName, "a.m4a")
            for tag in ["[EmbedThumbnail] ffmpeg: Adding thumbnail", "[Metadata] Adding metadata to \"x\"", "[EmbedSubtitle] Embedding subtitles", "[ThumbnailsConvertor] Converting thumbnail"] {
                try expectEqual(try unwrap(YtDlpProgressParser.parse(line: tag)).phase, .embedding, tag)
            }
            let move = try unwrap(YtDlpProgressParser.parse(line: "[MoveFiles] Moving file \"/t/a.mp4\" to \"/o/a.mp4\""))
            try expectEqual(move.phase, .finished); try expectEqual(YtDlpProgressParser.destinationPath(in: "[MoveFiles] Moving file \"/t/a.mp4\" to \"/o/a.mp4\""), "/o/a.mp4")
            try expectEqual(try unwrap(YtDlpProgressParser.parse(line: "[youtube] abc: Downloading webpage")).phase, .fetchingInfo)
            for junk in ["", "hello", "WARNING: x", "[debug] foo", "[download]", "[download]  %", "SC|", "SC||||||||", "\u{0}\u{1}", String(repeating: "[", count: 500)] {
                _ = YtDlpProgressParser.parse(line: junk)   // must not crash
            }
            try expectEqual(YtDlpProgressParser.parse(line: "WARNING: nothing to see"), nil)
            try expectEqual(YtDlpProgressParser.sizeBytes("1.5GiB"), Int64(1.5 * 1_073_741_824)); try expectEqual(YtDlpProgressParser.sizeBytes("512KiB"), 524_288); try expectEqual(YtDlpProgressParser.sizeBytes("12 parsecs"), nil)
        }

        test("progress: the mapper turns two files and a playlist into ONE bar that never goes backwards") {
            // Video then audio of one video.
            var m = DownloadProgressMapper(parts: [0.9, 0.1], items: 1)
            func line(_ f: Double?, dest: Bool = false, phase: DownloadProgress.Phase = .downloading, index: Int? = nil, count: Int? = nil) -> DownloadProgress {
                var p = DownloadProgress(phase: phase, fraction: f, downloadedBytes: f.map { _ in 1 })
                if dest { p = DownloadProgress(phase: .downloading, fraction: nil, fileName: "x.mp4") }
                p.itemIndex = index; p.itemCount = count
                return p
            }
            var seen: [Double] = []
            for p in [line(nil, dest: true), line(0.25), line(0.5), line(1), line(nil, dest: true), line(0.5), line(1), line(nil, phase: .merging), line(nil, phase: .embedding), line(nil, phase: .finished)] {
                if let f = m.feed(p) { seen.append(f) }
            }
            try expect(seen == seen.sorted(), "monotone: \(seen)")
            try expect(seen.allSatisfy { $0 >= 0 && $0 <= 1 }, "within 0...1")
            try expect(seen.contains { $0 > 0.4 && $0 < 0.5 }, "the video is 90 percent of the bar")
            try expect(try unwrap(seen.last) > 0.9 && seen.last! < 1, "the merge steps keep a little in reserve until the run ends")
            // Three items selected from a longer list, reported by ordinal like yt-dlp does.
            var pl = DownloadProgressMapper(parts: [1], items: 3)
            var marks: [Double] = []
            for k in 1...3 {
                _ = pl.feed(line(nil, phase: .fetchingInfo, index: k, count: 3))
                _ = pl.feed(line(nil, dest: true))
                _ = pl.feed(line(0.5, index: k, count: 3))
                marks.append(pl.feed(line(1, index: k, count: 3)) ?? -1)
            }
            try expect(marks == marks.sorted() && marks.allSatisfy { $0 > 0 && $0 <= 1 }, "playlist marks \(marks)")
            try expectClose(marks[0], 0.32, tolerance: 0.01); try expectClose(marks[1], 0.6533, tolerance: 0.01); try expectClose(marks[2], 0.9867, tolerance: 0.01)
            // Index larger than the count (a list that grew): clamped, never beyond 1.
            var odd = DownloadProgressMapper(parts: [1], items: 2)
            try expect((odd.feed(line(1, index: 9, count: 2)) ?? 0) <= 1)
        }

        test("progress: the sink throttles to 10 updates a second and words each phase for people") {
            try withEnglish {
                let sink = DownloadProgressSink(parts: [1], items: 1, interval: 0.1)
                let t0 = Date()
                var forwarded = 0
                for i in 0..<50 {   // 50 lines in half a second
                    if sink.feed(line: "SC|downloading|\(i * 1000)|100000|NA|1048576.0|5|NA|NA", now: t0.addingTimeInterval(Double(i) * 0.01)) != nil { forwarded += 1 }
                }
                try expect(forwarded >= 4 && forwarded <= 7, "about 10 per second, got \(forwarded) in 0.5 s")
                let done = sink.feed(line: "SC|finished|100000|100000|NA|NA|0|NA|NA", now: t0.addingTimeInterval(0.505))
                try expect(done != nil, "the last update is never swallowed")
                let u = try unwrap(DownloadProgressSink(parts: [1], items: 1).feed(line: "SC|downloading|5242880|10485760|NA|1048576.0|5|NA|NA"))
                try expect(u.message?.hasPrefix("Downloading ") == true && u.message?.contains(" of ") == true && u.message?.contains("/s") == true, u.message ?? "nil")
                try expectEqual(DownloadProgressSink(parts: [1], items: 1).feed(line: "[Merger] Merging formats into \"/t/a.mp4\"")?.message, "Joining video and sound…")
                let s2 = DownloadProgressSink(parts: [1], items: 3)
                _ = s2.feed(line: "[download] Downloading item 2 of 3")
                try expect(s2.feed(line: "[ExtractAudio] Destination: /t/a.m4a", now: Date().addingTimeInterval(1))?.message?.hasPrefix("Video 2 of 3.") == true, "playlist position in the message")
                s2.addStderr("ERROR: boom"); try expect(s2.stderrText.contains("boom"))
                let s3 = DownloadProgressSink(parts: [1], items: 1)
                _ = s3.feed(line: "[download] Destination: /tmp/o/x.mp4"); _ = s3.feed(line: "[MoveFiles] Moving file \"/t/a.mp4\" to \"/o/a.mp4\"")
                try expectEqual(s3.reportedDestinations, ["/tmp/o/x.mp4", "/o/a.mp4"])
            }
        }
    }
}
