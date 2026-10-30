import Foundation

// Self-tests, part 4: the real engine against the FAKE yt-dlp (`DownloadRig` refuses to run unless the located tool is the fake, and a self-test run forbids the network
// everywhere else). These prove the contract of the owner: nothing is spawned without consent, the sheet drives real info fetches and real downloads, errors become
// the right kind of message, and the install button goes through the verified install with a stub network layer.

extension DownloadUITests {
    static func registerFlow() {
        test("consent gating: without consent no process is started by the sheet or by the service; Agree opens the door") {
            try await downloadUIEnglish {
                try await DownloadRig.with(settings: { $0.consentGiven = false }) { rig in
                    let asked = Locked(0)
                    rig.service.hooks.requestConsent = { asked.value += 1; return false }
                    let m = DownloadSheetModel(deps: .live(service: rig.service, settings: .shared))
                    m.text = videoLink; m.fetch(); await m.settled()
                    try expectEqual(m.phase, .failed); try expectEqual(m.failure?.kind, .consentDeclined); try expectEqual(asked.value, 1)
                    try expect(rig.infoInvocations().isEmpty && rig.downloadInvocations().isEmpty, "the tool was never asked anything")
                    let outcome = await rig.service.start(url: URL(string: videoLink)!, mode: .bestForApple)
                    guard case .needsConsent = outcome else { throw TestFailure(message: "expected needsConsent, got \(outcome)", file: #fileID, line: #line) }
                    try expect(rig.runner.jobs.isEmpty && rig.infoInvocations().isEmpty && rig.downloadInvocations().isEmpty, "no job, no process")
                    // The real hooks with the dialog answered "Not Now" behave the same.
                    DownloadDialogHost.autoAnswer = { _ in false }
                    defer { DownloadDialogHost.autoAnswer = nil }
                    rig.service.hooks.requestConsent = DownloadUIModule.makeHooks().requestConsent
                    m.primaryAction(); await m.settled()
                    try expectEqual(m.phase, .failed); try expect(rig.infoInvocations().isEmpty, "declined through the real hook: still nothing spawned")
                    try expectEqual(AppSettings.shared.data.downloader.consentGiven, false)
                    // Agree: the consent is written and the very next fetch works.
                    rig.service.hooks.requestConsent = { DownloadConsent.record(true) }
                    m.primaryAction(); await m.settled()
                    try expectEqual(m.phase, .info); try expectEqual(AppSettings.shared.data.downloader.consentGiven, true); try expectEqual(rig.infoInvocations().count, 1)
                }
            }
        }

        test("readiness: consent first, then the tool; the hooks are only asked when something is missing") {
            try await downloadUIEnglish {
                try await DownloadRig.with(settings: { $0.consentGiven = false }) { rig in
                    let consentAsks = Locked(0), installAsks = Locked(0)
                    rig.service.hooks.offerInstall = { installAsks.value += 1; return true }
                    let none = await DownloadFlow.ensureReady(service: rig.service)
                    try expectEqual(none, .consentDeclined, "no consent hook: no consent"); try expectEqual(installAsks.value, 0, "the install is not even offered before consent")
                    rig.service.hooks.requestConsent = { consentAsks.value += 1; return true }     // says yes but records nothing
                    let fake = await DownloadFlow.ensureReady(service: rig.service)
                    try expectEqual(fake, .consentDeclined, "a hook that records nothing is not consent")
                    rig.service.hooks.requestConsent = { consentAsks.value += 1; return DownloadConsent.record(true) }
                    let ready = await DownloadFlow.ensureReady(service: rig.service)
                    try expectEqual(ready, .ready); try expectEqual(installAsks.value, 0, "the tool is there: no install offer")
                    let again = await DownloadFlow.ensureReady(service: rig.service)
                    try expectEqual(again, .ready); try expectEqual(consentAsks.value, 2, "consent given: not asked a third time")
                }
            }
        }

        test("sheet with the real service: info card from the fake tool, a chosen quality, a real download into the folder") {
            try await downloadUIEnglish {
                try await DownloadRig.with { rig in
                    let m = DownloadSheetModel(deps: .live(service: rig.service, settings: .shared))
                    m.text = videoLink; m.fetch(); await m.settled()
                    try expectEqual(m.phase, .info); try expectEqual(try unwrap(m.info).title, "Болото / Swamp: Part 1")
                    try expect(m.qualityOptions.count >= 4, "the ladder of the page: \(m.qualityOptions.map(\.label))")
                    try expectEqual(rig.infoInvocations().count, 1)
                    m.qualityID = try unwrap(m.qualityOptions.first { $0.height == 720 }).id
                    m.modeChoice = .maximum
                    m.download(); await m.settledDownload()
                    try expectEqual(m.phase, .started)
                    let job = try unwrap(m.startedJob)
                    try await rig.finish(job)
                    try expectEqual(job.state, .done, job.errorMessage ?? "")
                    let argv = try unwrap(rig.downloadInvocations().last, "yt-dlp was run for the download")
                    try expect(argv.contains { $0.contains("720") }, "the chosen height reached yt-dlp: \(argv)")
                    try expect(!rig.names().isEmpty, "a file landed in the chosen folder: \(rig.tree())")
                    try expect(rig.workAreas().isEmpty, "no hidden work area is left behind")
                }
            }
        }

        test("sheet with the real service: a list of videos, a chosen subset, only those are asked for") {
            try await downloadUIEnglish {
                try await DownloadRig.with { rig in
                    let m = DownloadSheetModel(deps: .live(service: rig.service, settings: .shared))
                    m.text = "https://www.youtube.com/playlist?list=PLswampMix"; m.fetch(); await m.settled()
                    try expectEqual(m.phase, .playlist)
                    let indices = try unwrap(m.info).entries.map(\.index)
                    try expect(indices.count >= 3, "\(indices)")
                    m.selection = [indices[0], indices[2]]
                    let expected = try unwrap(PlaylistSpec.make(selection: m.selection, indices: indices))
                    m.modeChoice = .audio
                    m.download(); await m.settledDownload()
                    let job = try unwrap(m.startedJob, "started: \(m.phase) \(m.failure?.message ?? "")")
                    try await rig.finish(job)
                    try expectEqual(job.state, .done, job.errorMessage ?? "")
                    let argv = try unwrap(rig.downloadInvocations().last)
                    let at = try unwrap(argv.firstIndex(of: "--playlist-items"), "the subset is passed: \(argv)")
                    try expectEqual(argv[at + 1], expected)
                }
            }
        }

        test("sheet with the real service: each way a link can fail becomes the right message") {
            try await downloadUIEnglish {
                try await DownloadRig.with { rig in
                    let cases: [(String, DownloadFailure.Kind)] = [("signin", .signIn), ("private", .privateVideo), ("geo", .geoBlocked), ("drm", .drm), ("offline", .networkDown), ("unsupported", .other)]
                    for (word, kind) in cases {
                        let m = DownloadSheetModel(deps: .live(service: rig.service, settings: .shared))
                        m.text = "https://example.com/watch/\(word)"; m.fetch(); await m.settled()
                        try expectEqual(m.phase, .failed, word); try expectEqual(m.failure?.kind, kind, "\(word): \(m.failure?.message ?? "")")
                        try expect(!(m.failure?.message.isEmpty ?? true))
                    }
                }
            }
        }

        test("the started hook shows the toast and a rejected link says why") {
            try await downloadUIEnglish {
                try await DownloadRig.with { rig in
                    let log = Locked<[String]>([])
                    DownloadToast.sink = { text, _, _, _ in log.withLock { $0.append(text) } }
                    defer { DownloadToast.sink = nil }
                    let hooks = DownloadUIModule.makeHooks()
                    rig.service.hooks.started = hooks.started; rig.service.hooks.rejected = hooks.rejected
                    let job = try await rig.start(videoLink)
                    try expectEqual(log.value, ["Download started: youtube.com"])
                    try await rig.finish(job)
                    _ = await rig.service.start(url: URL(string: "http://localhost:9/x")!, mode: .bestForApple)
                    try expectEqual(log.value.count, 2); try expect(log.value[1].contains("localhost"), log.value[1])
                }
            }
        }

        test("install button: verified install with a stub network layer, a bad checksum installs nothing, update of a foreign copy is explained") {
            guard AppPaths.supportDir.path.contains("selftest-") else { try skipTest("not running in an isolated home: refusing to touch the tools folder") }
            try await downloadUIEnglish {
                try await DownloadRig.with { rig in
                    let target = YtDlpToolManager.installURL
                    try? FileManager.default.removeItem(at: target)
                    defer { try? FileManager.default.removeItem(at: target) }
                    let payload = StubHTTP.fakeBinary(version: "2026.11.01")
                    rig.stub.payload = payload; rig.stub.checksums = StubHTTP.sums(for: payload, hash: String(repeating: "c", count: 64))
                    let bad = YtDlpInstallModel()
                    bad.install(); await bad.finished()
                    guard case .failed(let why) = bad.phase else { throw TestFailure(message: "a wrong checksum must fail: \(bad.phase)", file: #fileID, line: #line) }
                    try expect(why.contains("checksum"), why); try expect(!FileManager.default.fileExists(atPath: target.path), "nothing installed")
                    rig.stub.checksums = StubHTTP.sums(for: payload)
                    let model = YtDlpInstallModel()
                    model.install()
                    try expect(model.isWorking); model.install()    // a second press while working does nothing
                    await model.finished()
                    guard case .succeeded(let outcome) = model.phase else { throw TestFailure(message: "install should succeed: \(model.phase)", file: #fileID, line: #line) }
                    try expect(outcome.checksumVerified && !outcome.alreadyLatest, "the checksum result is reported")
                    try expectEqual(try Data(contentsOf: target), payload)
                    try expect(rig.stub.requests.allSatisfy { $0.host == "github.com" }, "only github.com: \(rig.stub.requests)")
                    // The located tool is the fake (an override), i.e. not the app's own copy: the update is refused with an explanation.
                    let update = YtDlpInstallModel()
                    update.update(); await update.finished()
                    guard case .failed(let reason) = update.phase else { throw TestFailure(message: "update of a foreign copy: \(update.phase)", file: #fileID, line: #line) }
                    try expect(reason.contains("managed outside"), reason)
                    update.reset(); try expectEqual(update.phase, .idle)
                }
            }
        }

        test("install button without consent: refused with the notice, nothing requested") {
            try await downloadUIEnglish {
                try await DownloadRig.with(settings: { $0.consentGiven = false }) { rig in
                    let model = YtDlpInstallModel()
                    model.install(); await model.finished()
                    guard case .failed(let why) = model.phase else { throw TestFailure(message: "should be refused: \(model.phase)", file: #fileID, line: #line) }
                    try expect(why.contains("agree"), why); try expectEqual(rig.stub.requests.count, 0)
                }
            }
        }

        test("a link dropped on the sheet fills the field and fetches; text without a link only fills the field") {
            try await downloadUIEnglish {
                let stub = StubSheet(); let m = stub.model()
                DownloadLinkDrop.apply("watch https://youtu.be/abc123XYZ_- later", to: m); await m.settled()
                try expectEqual(stub.fetches.count, 1); try expectEqual(m.phase, .info)
                let other = stub.model()
                DownloadLinkDrop.apply("just some words", to: other)
                try expectEqual(other.phase, .empty); try expectEqual(stub.fetches.count, 1); try expect(other.rejection != nil)
            }
        }
    }
}
