import Foundation

// Tests of DownloadService, the single entry of the download feature: consent and install gating through the hooks, rejected links,
// duplicates, the mode-to-operation mapping, the URL scheme and the information fetch. All against the fake yt-dlp.

private func kind(_ o: DownloadService.StartOutcome) -> String {
    switch o {
    case .started: return "started"
    case .needsConsent: return "needsConsent"
    case .needsInstall: return "needsInstall"
    case .rejected(let r): return "rejected(\(r))"
    case .failed(let s): return "failed(\(s))"
    }
}

private let video = "https://www.youtube.com/watch?v=abc123XYZ_-"

extension DownloaderTests {
    static func registerService() {
        test("service: nothing starts without consent; only a sheet that really records the consent opens the door") {
            try await DownloadRig.with(settings: { $0.consentGiven = false }) { rig in
                let asked = Locked(0)
                let url = URL(string: video)!
                func expectStart(_ expected: String, _ why: String = "") async throws {
                    let k = kind(await rig.service.start(url: url, mode: .bestForApple)); try expectEqual(k, expected, why)
                }
                try await expectStart("needsConsent", "no UI to ask: nothing happens")
                rig.service.hooks.requestConsent = { asked.value += 1; return false }
                try await expectStart("needsConsent", "the person declined")
                rig.service.hooks.requestConsent = { asked.value += 1; return true }
                try await expectStart("needsConsent", "a hook that says yes without recording it is not consent")
                try expectEqual(asked.value, 2)
                try expect(rig.runner.jobs.isEmpty && rig.invocations().filter { $0.contains("-J") || $0.contains("--newline") }.isEmpty, "no job, and the tool was never asked anything")
                rig.service.hooks.requestConsent = { AppSettings.shared.update { $0.downloader.consentGiven = true }; return true }
                let started = await rig.service.start(url: url, mode: .bestForApple)
                guard case .started(let job) = started else { throw TestFailure(message: "should start after consent: \(kind(started))", file: #fileID, line: #line) }
                try await rig.finish(job); try expectEqual(job.state, .done, job.errorMessage ?? "")
            }
        }

        test("service: a missing yt-dlp is offered as an install, never fetched silently") {
            try await DownloadRig.with { rig in
                AppSettings.shared.update { $0.toolPaths = [:] }; ToolLocator.shared.refresh()
                if ToolLocator.shared.has(.ytdlp) { try skipTest("a real yt-dlp is installed on this Mac") }
                let url = URL(string: video)!
                let offers = Locked(0)
                func expectStart(_ expected: String, _ why: String = "") async throws {
                    let k = kind(await rig.service.start(url: url, mode: .bestForApple)); try expectEqual(k, expected, why)
                }
                try await expectStart("needsInstall")
                rig.service.hooks.offerInstall = { offers.value += 1; return false }
                try await expectStart("needsInstall", "the person declined")
                rig.service.hooks.offerInstall = { offers.value += 1; return true }
                try await expectStart("needsInstall", "the install did not produce a tool")
                try expectEqual(offers.value, 2); try expect(rig.runner.jobs.isEmpty)
                let tool = rig.tool.path
                rig.service.hooks.offerInstall = { AppSettings.shared.update { $0.toolPaths = ["ytdlp": tool] }; ToolLocator.shared.refresh(); return true }
                guard case .started(let job) = await rig.service.start(url: url, mode: .bestForApple) else { throw TestFailure(message: "should start after the install", file: #fileID, line: #line) }
                try await rig.finish(job); try expectEqual(job.state, .done, job.errorMessage ?? "")
            }
        }

        test("service: links that cannot be downloaded are rejected before consent, install or any process") {
            try await DownloadRig.with(settings: { $0.consentGiven = false }) { rig in
                let rejected = Locked<[LinkRejection]>([]); let asked = Locked(0)
                rig.service.hooks.rejected = { reason in rejected.withLock { $0.append(reason) } }
                rig.service.hooks.requestConsent = { asked.value += 1; return true }
                rig.service.hooks.offerInstall = { asked.value += 1; return true }
                for bad in ["javascript:alert(1)", "file:///etc/passwd", "http://localhost:8080/v", "https://user:pw@example.com/v", "not a link", ""] {
                    let outcome = await rig.service.start(url: URL(string: bad) ?? URL(string: "x:")!, mode: .bestForApple)
                    guard case .rejected = outcome else { throw TestFailure(message: "\"\(bad)\" gave \(kind(outcome))", file: #fileID, line: #line) }
                }
                try expectEqual(rejected.value.count, 6, "the person is told each time"); try expectEqual(asked.value, 0, "no consent sheet for a link that is not downloadable")
                try expect(rig.runner.jobs.isEmpty && rig.invocations().isEmpty, "nothing was started")
                let req = rig.request("file:///etc/passwd")
                guard case .rejected = await rig.service.start(request: req) else { throw TestFailure(message: "Studio request with a file: link", file: #fileID, line: #line) }
            }
        }

        test("service: the same video asked twice runs once, however the link is spelled") {
            try await DownloadRig.with(env: ["FAKE_YTDLP_DELAY": "0.1"]) { rig in
                let started = Locked(0)
                rig.service.hooks.started = { _, _, _ in started.value += 1 }
                guard case .started(let a) = await rig.service.start(url: URL(string: "https://youtu.be/abc123XYZ_-?si=track")!, mode: .bestForApple),
                      case .started(let b) = await rig.service.start(url: URL(string: "https://www.youtube.com/watch?v=abc123XYZ_-&utm_source=x")!, mode: .maximum) else {
                    throw TestFailure(message: "both asks should answer with a job", file: #fileID, line: #line)
                }
                try expectEqual(a.id, b.id, "the second ask joins the running job"); try expectEqual(rig.runner.jobs.count, 1); try expectEqual(started.value, 1, "one toast, not two")
                try await rig.finish(a)
                let c = try await rig.start(video)
                try expect(c.id != a.id, "once finished, the same link can be downloaded again")
                try await rig.finish(c)
            }
        }

        test("service: every mode maps to its operation; the default mode and the URL scheme choose when nothing is said", oracles: ["dl.mode.selector"]) {
            try await DownloadRig.with { rig in
                for mode in DownloadMode.allCases {
                    guard case .started(let job) = await rig.service.start(request: { var r = rig.request(video); r.mode = mode; return r }(), held: true) else { throw TestFailure(message: "no job for \(mode)", file: #fileID, line: #line) }
                    try expectEqual(job.operationID, DownloadCatalog.operationID(for: mode)); try expect(job.held && job.state == .waiting, "Add to Queue holds the job")
                    try expectEqual(job.overrides.string(DownloadKeys.mode), mode.rawValue)
                    rig.runner.remove(job)
                }
                try expectEqual(DownloadCatalog.operationID(for: .audioMP3), "link.audio.mp3")
                rig.configure { $0.defaultMode = .maximum }
                let job = try await rig.start(video, mode: .maximum)
                try expectEqual(job.operationID, "link.max"); try await rig.finish(job)
                guard case .started(let viaDefault) = await rig.service.start(url: URL(string: "https://www.youtube.com/watch?v=other1")!, mode: nil) else { throw TestFailure(message: "default mode", file: #fileID, line: #line) }
                try expectEqual(viaDefault.operationID, "link.max", "no mode given: the one from Settings"); try await rig.finish(viaDefault)
                let scheme = try unwrap(DownloadURLScheme.make(link: URL(string: "https://www.youtube.com/watch?v=viaScheme")!, mode: .audioMP3))
                guard case .success(let parsed) = DownloadURLScheme.parse(scheme), case .started(let viaURL) = await rig.service.handle(scheme: parsed) else { throw TestFailure(message: "scheme", file: #fileID, line: #line) }
                try expectEqual(viaURL.operationID, "link.audio.mp3"); try await rig.finish(viaURL)
                try expectEqual(viaURL.state, .done, viaURL.errorMessage ?? "")
            }
        }

        test("service: a newer yt-dlp is announced quietly after a start, and only when the check is switched on") {
            try await DownloadRig.with { rig in
                rig.stub.tag = "2026.12.01"
                _ = try await rig.download(video)
                try await Task.sleep(nanoseconds: 300_000_000)
                try expectEqual(rig.stub.requests.count, 0, "off by default: no request, no message")
                rig.configure { $0.checkForUpdates = true }
                let before = MessageCenter.shared.recent.count
                _ = try await rig.download("https://www.youtube.com/watch?v=second1")
                try await expectEventually(timeout: 5) { MessageCenter.shared.recent.count > before }
                try expect(MessageCenter.shared.recent.last?.text.contains("2026.12.01") == true && MessageCenter.shared.recent.last?.text.contains("Settings > Downloader") == true, MessageCenter.shared.recent.last?.text ?? "")
                try expectEqual(rig.stub.requests.map(\.lastPathComponent), ["latest"], "one small request to the release page, nothing downloaded")
                _ = try await rig.download("https://www.youtube.com/watch?v=third1")
                try await Task.sleep(nanoseconds: 300_000_000)
                try expectEqual(rig.stub.requests.count, 1, "once a day at most")
            }
        }

        test("service: information is fetched through the tool, cached, cancellable, and honours the network gate", oracles: ["dl.cookies.only-when-chosen"]) {
            try await DownloadRig.with { rig in
                let url = URL(string: video)!
                let info = try await rig.service.fetchInfo(url)
                try expectEqual(info.title, "Болото / Swamp: Part 1"); try expectEqual(info.formats.count, 15)
                _ = try await rig.service.fetchInfo(URL(string: "https://youtu.be/abc123XYZ_-?si=x")!)
                try expectEqual(rig.infoInvocations().count, 1, "the second ask (same video, other spelling) is served from the cache")
                let args = try unwrap(rig.infoInvocations().first)
                try expect(args.contains("--no-playlist") && !args.contains("--cookies-from-browser") && args.suffix(2).elementsEqual(["--", url.absoluteString]))
                let list = try await rig.service.fetchInfo(URL(string: "https://www.youtube.com/playlist?list=PLswampMix")!, flatPlaylist: true)
                try expect(list.isPlaylist); try expectEqual(list.entries.count, 3)
                let listArgs = try unwrap(rig.infoInvocations().last); try expect(listArgs.contains("--yes-playlist") && listArgs.contains("--flat-playlist"))
                rig.configure { $0.cookies = .safari }
                _ = try await rig.service.fetchInfo(URL(string: "https://www.youtube.com/watch?v=withCookies")!)
                try expectEqual(argAfter(try unwrap(rig.infoInvocations().last), "--cookies-from-browser"), "safari")
                for bad in ["javascript:alert(1)", "file:///etc/hosts", "https://example.com/private"] {
                    _ = try await expectThrows("\(bad) must fail calmly") { _ = try await rig.service.fetchInfo(URL(string: bad)!) }
                }
                let before = rig.invocations().count
                NetworkGate.forbidAll = true
                let err = try await expectThrows { _ = try await rig.service.fetchInfo(URL(string: "https://www.youtube.com/watch?v=gated")!) }
                try expect(ConversionError.describe(err).contains("switched off"), ConversionError.describe(err)); try expectEqual(rig.invocations().count, before, "the tool was not started")
            }
            try await DownloadRig.with(env: ["FAKE_YTDLP_INFO_DELAY": "6"]) { rig in
                let t0 = Date()
                let task = Task { try await rig.service.fetchInfo(URL(string: "https://www.youtube.com/watch?v=slowInfo")!) }
                try await Task.sleep(nanoseconds: 400_000_000); task.cancel()
                do { _ = try await task.value; throw TestFailure(message: "a cancelled fetch returned", file: #fileID, line: #line) } catch is CancellationError {}
                try expect(Date().timeIntervalSince(t0) < 4, "cancelled within a moment, not after the 6 s delay")
                try await expectEventually(timeout: 2) { ProcessRegistry.shared.count == 0 }
            }
        }
    }
}

private func argAfter(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
