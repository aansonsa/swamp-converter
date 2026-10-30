import Foundation

// Self-tests, part 2: the state machine of the sheet with stub dependencies (no yt-dlp, no window, no network).

extension DownloadUITests {
    static func registerState() {
        test("sheet: empty -> fetching -> info; the link is validated live and never fetched while typing") {
            try await downloadUIEnglish {
                let stub = StubSheet()
                let m = stub.model()
                try expectEqual(m.phase, .empty); try expect(m.validation == nil, "an empty field says nothing")
                m.text = "not a link"
                try expect(m.rejection != nil && m.validURL == nil); try expect(!m.canFetch)
                m.text = videoLink
                try expect(m.validURL != nil && m.rejection == nil && m.canFetch)
                try expectEqual(stub.fetches.count, 0, "typing a link starts nothing")
                m.primaryAction()
                try expectEqual(m.phase, .fetching)
                await m.settled()
                try expectEqual(m.phase, .info); try expectEqual(stub.fetches.count, 1); try expectEqual(stub.readinessChecks, 1)
                try expect(!m.qualityOptions.isEmpty && m.qualityID == nil, "best available is the default")
                try expectEqual(m.primaryTitle, "Download and Convert", "Best for Apple is followed by the conversion stage")
                m.modeChoice = .maximum
                try expectEqual(m.primaryTitle, "Download", "Maximum quality keeps the file as it is")
                try expect(m.canDownload)
            }
        }

        test("sheet: a pasted sentence with a link inside is accepted; rejected schemes explain themselves") {
            let m = StubSheet().model()
            m.text = "look at this https://youtu.be/abc123XYZ_- it is great"
            try expect(m.validURL?.host == "youtu.be", "the first downloadable link of the text")
            for (text, kind) in [("javascript:alert(1)", "unsupportedScheme"), ("ftp://example.com/a.mp4", "unsupportedScheme"), ("http://localhost:8080/x", "privateHost"),
                                 ("http://192.168.0.7/video", "privateHost"), ("https://user:pass@example.com/x", "credentialsInURL"), ("hello", "malformed")] {
                m.text = text
                let r = try unwrap(m.rejection, "\(text) must be refused")
                try expect("\(r)".hasPrefix(kind), "\(text): \(r)")
                try expect(!r.message.en.isEmpty && !r.message.ru.isEmpty && r.message.en != r.message.ru, "both languages for \(text)")
            }
        }

        test("sheet: editing the link after a result starts over; cancel returns to empty") {
            try await downloadUIEnglish {
                let stub = StubSheet()
                let m = stub.model()
                m.text = videoLink; m.fetch(); await m.settled()
                try expectEqual(m.phase, .info)
                m.text = "https://example.com/other"
                try expectEqual(m.phase, .empty); try expect(m.info == nil && m.qualityOptions.isEmpty)
                stub.fetchDelay = .seconds(30)
                m.fetch(); try expectEqual(m.phase, .fetching)
                m.cancelFetch()
                try expectEqual(m.phase, .empty, "cancel while fetching")
                await m.settled()
                try expectEqual(m.phase, .empty, "a cancelled fetch never lands later")
            }
        }

        test("sheet: consent or install declined stops before any fetch and says so") {
            try await downloadUIEnglish {
                for (readiness, kind) in [(DownloadReadiness.consentDeclined, DownloadFailure.Kind.consentDeclined), (.installDeclined, .notInstalled)] {
                    let stub = StubSheet(); stub.readiness = readiness
                    let m = stub.model(); m.text = videoLink; m.fetch(); await m.settled()
                    try expectEqual(m.phase, .failed); try expectEqual(m.failure?.kind, kind)
                    try expectEqual(stub.fetches.count, 0, "nothing was fetched")
                    try expect(m.failure?.fixTitle != nil && m.failure?.canRetry == true)
                }
            }
        }

        test("sheet: a failed fetch is classified and offers its fix; retry works") {
            try await downloadUIEnglish {
                let stub = StubSheet()
                let signIn = YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: [youtube] x: Sign in to confirm you're not a bot. Use --cookies-from-browser")
                stub.fetchResult = .failure(ConversionError.message(signIn))
                let m = stub.model(); m.text = videoLink; m.fetch(); await m.settled()
                try expectEqual(m.phase, .failed); try expectEqual(m.failure?.kind, .signIn); try expectEqual(m.failure?.fix, .chooseBrowser)
                m.chooseBrowser(.safari)
                try expectEqual(stub.settings.data.downloader.cookies, .safari, "the inline fix writes the setting")
                stub.fetchResult = .success(DownloadSnapshotSamples.info("video.json"))
                m.primaryAction(); await m.settled()
                try expectEqual(m.phase, .info)
            }
        }

        test("sheet: a list gets the picker, all videos are selected, the spec follows the selection") {
            try await downloadUIEnglish {
                let stub = StubSheet(); stub.fetchResult = .success(DownloadSnapshotSamples.info("playlist.json"))
                let m = stub.model(); m.text = "https://www.youtube.com/playlist?list=PLswampMix"; m.fetch(); await m.settled()
                try expectEqual(m.phase, .playlist)
                let all = try unwrap(m.info).entries.map(\.index)
                try expectEqual(m.selection, Set(all)); try expectEqual(m.playlistItems, "", "everything selected means the whole list")
                m.selection = [all[0], all[2]]
                try expect(m.playlistItems?.contains(",") == true || m.playlistItems?.contains("-") == true, "a subset is spelled out: \(m.playlistItems ?? "nil")")
                m.selection = []
                try expectEqual(m.playlistItems, nil); try expect(!m.canDownload, "nothing selected: nothing to download")
                m.selection = Set(all)
                try expectEqual(m.primaryTitle, "Download and Convert")
                try expect(m.estimatedBytes != nil, "a rough total from the durations")
            }
        }

        test("sheet: the request follows the choices (mode, quality, audio, subtitles, range, folder, after-download)") {
            try await downloadUIEnglish {
                let stub = StubSheet()
                let m = stub.model(); m.text = videoLink; m.fetch(); await m.settled()
                var r = try unwrap(m.makeRequest())
                try expectEqual(r.mode, .bestForApple); try expectEqual(r.maxHeight, nil); try expectEqual(r.outputDirectory, stub.folder); try expectEqual(r.playlistItems, nil)
                let q1080 = try unwrap(m.qualityOptions.first { $0.height == 1080 }); m.qualityID = q1080.id
                r = try unwrap(m.makeRequest()); try expectEqual(r.maxHeight, 1080)
                m.modeChoice = .maximum
                r = try unwrap(m.makeRequest()); try expectEqual(r.mode, .maximum); try expectEqual(r.after, .keepOriginal); try expect(!m.convertsAfterDownload)
                m.modeChoice = .universal
                r = try unwrap(m.makeRequest()); try expectEqual(r.mode, .universal); try expectEqual(r.after, .universal); try expectEqual(m.primaryTitle, "Download and Convert")
                m.modeChoice = .audio; m.audioFormat = .opus
                r = try unwrap(m.makeRequest()); try expectEqual(r.mode, .audioM4A); try expectEqual(r.audioFormat, .opus); try expectEqual(r.maxHeight, nil); try expectEqual(r.after, .keepOriginal)
                m.audioFormat = .mp3
                try expectEqual(try unwrap(m.makeRequest()).mode, .audioMP3)
                m.modeChoice = .best
                m.subtitleMode = .soft; m.subtitleLanguages = "ru, en"
                r = try unwrap(m.makeRequest()); try expectEqual(r.subtitles, .soft); try expectEqual(r.subtitleLanguages, ["ru", "en"])
                m.rangeStart = "0:10"; m.rangeEnd = "1:30"
                r = try unwrap(m.makeRequest()); try expectEqual(r.sectionStart, 10); try expectEqual(r.sectionEnd, 90)
                m.folder = URL(fileURLWithPath: "/tmp/elsewhere")
                try expectEqual(try unwrap(m.makeRequest()).outputDirectory.path, "/tmp/elsewhere")
            }
        }

        test("sheet: a time range that makes no sense blocks Download with a reason") {
            try await downloadUIEnglish {
                let stub = StubSheet()
                let m = stub.model(); m.text = videoLink; m.fetch(); await m.settled()
                m.rangeStart = "abc"
                try expect(m.rangeProblem != nil && !m.canDownload, "unreadable time")
                m.rangeStart = "2:00"; m.rangeEnd = "1:00"
                try expect(m.rangeProblem != nil && !m.canDownload, "end before start")
                m.rangeStart = ""; m.rangeEnd = ""
                try expectEqual(m.rangeProblem, nil); try expect(m.canDownload)
            }
        }

        test("sheet: a live stream cannot be downloaded yet") {
            try await downloadUIEnglish {
                let stub = StubSheet(); stub.fetchResult = .success(DownloadSnapshotSamples.info("live.json"))
                let m = stub.model(); m.text = "https://www.youtube.com/watch?v=liveStream01"; m.fetch(); await m.settled()
                try expectEqual(m.phase, .info); try expect(m.isLive && !m.canDownload)
                try expect(DownloadFormatText.bestChips(for: try unwrap(m.info)).contains("Live"))
            }
        }

        test("sheet: Download starts through the service and lands in 'started'; a refusal becomes a calm error") {
            try await downloadUIEnglish {
                let stub = StubSheet()
                let m = stub.model(); m.text = videoLink; m.fetch(); await m.settled()
                stub.startOutcome = .needsConsent
                m.download(); await m.settledDownload()
                try expectEqual(m.phase, .failed); try expectEqual(m.failure?.kind, .consentDeclined); try expectEqual(stub.requests.count, 1)
                m.primaryAction(); await m.settled()
                try expectEqual(m.phase, .info)
                let job = DownloadSnapshotSamples.twoStageJob(title: "Swamp", convertFraction: 0.1)
                stub.startOutcome = .started(job)
                m.download(); await m.settledDownload()
                try expectEqual(m.phase, .started); try expect(m.startedJob === job); try expect(!m.startedTitle.isEmpty)
                m.reset()
                try expectEqual(m.phase, .empty); try expect(m.text.isEmpty && m.startedJob == nil)
            }
        }

        test("sheet: a video inside a list offers the whole list; Open in Studio hands over the link and the mode") {
            try await downloadUIEnglish {
                try expect(DownloadSheetModel.isVideoInsideList(URL(string: "https://www.youtube.com/watch?v=a&list=PLb")!))
                try expect(!DownloadSheetModel.isVideoInsideList(URL(string: "https://www.youtube.com/watch?v=a")!))
                try expect(!DownloadSheetModel.isVideoInsideList(URL(string: "https://www.youtube.com/playlist?list=PLb")!))
                let stub = StubSheet()
                let m = stub.model(); m.text = "https://www.youtube.com/watch?v=abc123XYZ_-&list=PLswampMix"; m.fetch(); await m.settled()
                try expect(m.offersWholeList, "the single video is shown, the list is offered")
                m.fetch(wholeList: true); await m.settled()
                try expectEqual(stub.fetches.map(\.whole), [false, true])
                m.modeChoice = .universal
                m.openInStudio()
                let opened = try unwrap(stub.studioOpened.first)
                try expectEqual(opened.1, .universal); try expect(opened.0.url.host == "www.youtube.com")
            }
        }

        test("clipboard: read once when the sheet opens, offered as a banner, used only on a click") {
            try await downloadUIEnglish {
                let reads = Locked(0)
                ClipboardLinkReader.override = { reads.value += 1; return "see https://youtu.be/abc123XYZ_- now" }
                defer { ClipboardLinkReader.override = nil }
                let stub = StubSheet()
                let m = stub.model()
                try expectEqual(reads.value, 0, "creating the model reads nothing")
                m.loadClipboardBanner()
                try expectEqual(reads.value, 1); let banner = try unwrap(m.clipboardLink); try expectEqual(banner.host, "youtu.be")
                try await Task.sleep(for: .milliseconds(300))
                try expectEqual(reads.value, 1, "no polling"); try expectEqual(stub.fetches.count, 0, "the banner never fetches by itself")
                m.useClipboardLink(); await m.settled()
                try expect(m.text.contains("youtu.be")); try expectEqual(stub.fetches.count, 1); try expect(m.clipboardLink == nil)
                ClipboardLinkReader.override = { "no link here" }
                m.loadClipboardBanner(); try expect(m.clipboardLink == nil)
                try expect(ClipboardLinkBanner.shortAddress(URL(string: "https://example.com/" + String(repeating: "a", count: 200))!).count <= 64)
            }
        }

        test("controller: opens a parked window, reads the clipboard once, fetches only for an explicit link, releases everything on close") {
            try await downloadUIEnglish {
                let reads = Locked(0)
                ClipboardLinkReader.override = { reads.value += 1; return "https://youtu.be/abc123XYZ_-" }
                defer { ClipboardLinkReader.override = nil }
                let stub = StubSheet()
                let c = DownloadSheetController(options: .init(activates: false, reportsPresence: false, parkOffscreen: true, dependencies: stub.deps()))
                c.show(link: nil, prefillFromClipboard: true)
                try expect(c.isVisible && c.model != nil); try expectEqual(reads.value, 1); try expect(c.model?.clipboardLink != nil)
                try expectEqual(stub.fetches.count, 0, "opening the sheet never starts a fetch")
                c.show(link: nil, prefillFromClipboard: false)
                try expectEqual(reads.value, 1, "reopening without the flag reads nothing")
                c.show(link: LinkItem(url: URL(string: videoLink)!), prefillFromClipboard: true)
                await c.model?.settled()
                try expectEqual(stub.fetches.count, 1); try expectEqual(c.model?.phase, .info)
                c.close()
                try expect(!c.isVisible && c.model == nil && c.currentWindow == nil, "closing releases the window and the model")
            }
        }
    }
}
