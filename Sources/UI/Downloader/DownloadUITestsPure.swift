import Foundation
import SwiftUI

// Self-tests, part 3: pure helpers and presentation logic (failure recognition, text helpers, stages, toasts, the pickers' data, views that must build).

extension DownloadUITests {
    static func registerPure() {
        test("failures: every engine sentence is recognised in English and Russian and gets the fix that fits") {
            let samples: [(stderr: String, kind: DownloadFailure.Kind, fix: DownloadFailure.Fix?)] = [
                ("ERROR: [youtube] x: Sign in to confirm you're not a bot", .signIn, .chooseBrowser),
                ("ERROR: [youtube] x: Private video. Sign in if you've been granted access", .privateVideo, .chooseBrowser),
                ("ERROR: [youtube] x: Sign in to confirm your age. This video may be inappropriate for some users", .ageRestricted, .chooseBrowser),
                ("ERROR: [youtube] x: The uploader has not made this video available in your country", .geoBlocked, nil),
                ("ERROR: [generic] This video is DRM protected", .drm, nil),
                ("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>", .networkDown, nil),
                ("ERROR: No space left on device", .diskFull, .openSettings),
                ("ERROR: Requested format is not available\nWARNING: No supported JavaScript runtime could be found. n challenge solving failed", .noJSRuntime, .showJSRuntimeHelp),
                ("ERROR: no such option: --js-runtimes", .toolTooOld, .openSettings)
            ]
            for s in samples {
                let l = YtDlpInfoParser.friendlyMessage(forStderr: s.stderr)
                for text in [l.en, l.ru] {
                    let f = DownloadFailure(message: text)
                    try expectEqual(f.kind, s.kind, "\(s.stderr) -> \(text)")
                    try expectEqual(f.fix, s.fix, "\(s.kind)")
                    if s.fix != nil { try expect(f.fixTitle != nil) }
                }
            }
            try expectEqual(DownloadFailure(message: "The site reported: something odd").kind, .other)
            try expect(DownloadToast.warrantsToast(DownloadFailure(kind: .signIn, message: "x")) && !DownloadToast.warrantsToast(DownloadFailure(kind: .networkDown, message: "x")))
            try expect(!DownloadFailure(kind: .drm, message: "x").canRetry)
        }

        test("playlist spec: ranges are compact, everything selected means the whole list") {
            let all = [1, 2, 3, 4, 5, 6, 7, 8]
            try expectEqual(PlaylistSpec.make(selection: [1, 3, 5, 6, 7], indices: all), "1,3,5-7")
            try expectEqual(PlaylistSpec.make(selection: Set(all), indices: all), "")
            try expectEqual(PlaylistSpec.make(selection: [], indices: all), nil)
            try expectEqual(PlaylistSpec.make(selection: [2], indices: all), "2")
            try expectEqual(PlaylistSpec.make(selection: [9, 10], indices: all), nil, "indices outside the list are ignored")
            try expectEqual(PlaylistSpec.make(selection: [1, 2, 3], indices: [1, 2, 3, 4]), "1-3")
        }

        test("text helpers: chips of the best quality, sizes, durations, counts") {
            try await downloadUIEnglish {
                let k8 = DownloadFormatText.bestChips(for: DownloadSnapshotSamples.info("video-8k-hdr.json"))
                try expect(k8.first == "8K" && k8.contains("HDR"), "\(k8)")
                let v = DownloadFormatText.bestChips(for: DownloadSnapshotSamples.info("video.json"))
                try expect(v.first == "4K", "\(v)")
                try expect(DownloadFormatText.bestChips(for: DownloadSnapshotSamples.info("audio-only.json")).contains("Audio only"))
                try expectEqual(DownloadFormatText.resolutionName(2160), "4K"); try expectEqual(DownloadFormatText.resolutionName(1080), "1080p")
                try expectEqual(DownloadFormatText.resolutionName(4320), "8K")
                try expectEqual(DownloadFormatText.duration(612), "10:12"); try expectEqual(DownloadFormatText.duration(nil), nil); try expectEqual(DownloadFormatText.duration(3723), "1:02:03")
                try expectEqual(DownloadFormatText.sizeColumn(nil), "\u{2014}"); try expect(DownloadFormatText.size(5_000_000).hasPrefix("about"))
                try expectEqual(DownloadFormatText.size(nil), "Size unknown")
                try expectEqual(DownloadFormatText.videoCount(1), "1 video"); try expectEqual(DownloadFormatText.videoCount(12), "12 videos")
                try expectEqual(DownloadFormatText.selected(3, of: 12), "3 of 12 selected")
                let small = DownloadFormatText.roughBytes(seconds: 600, height: 720, audioOnly: false), big = DownloadFormatText.roughBytes(seconds: 600, height: 2160, audioOnly: false)
                let audio = DownloadFormatText.roughBytes(seconds: 600, height: 0, audioOnly: true)
                try expect(audio < small && small < big, "\(audio) < \(small) < \(big)")
            }
        }

        test("quality picker: rows come from the engine's ladder, highest first, with titles that never repeat the HDR flag") {
            let info = DownloadSnapshotSamples.info("video-8k-hdr.json")
            let options = FormatSelector.qualityOptions(for: info)
            try expect(options.count >= 3 && options.map(\.height) == options.map(\.height).sorted(by: >), "highest first")
            let top = try unwrap(options.first)
            try expectEqual(top.height, 4320); try expect(top.isHDR)
            try expect(!QualityPickerView.title(top).contains("HDR") && QualityPickerView.details(top).contains("HDR"))
            try expect(options.allSatisfy { QualityPickerView.details($0).count <= 3 })
            try expectEqual(DownloadAudioFormat.choices.map(\.title), ["M4A (AAC)", "MP3", "Opus", "FLAC"])
        }

        test("stages: a download followed by a conversion reads as two lines, then one sentence") {
            try await downloadUIEnglish {
                let stages = [StageProgress(spec: .download(), state: .done, fraction: 1), StageProgress(spec: .convert(), state: .running, fraction: 0.4)]
                let lines = DownloadStageLine.lines(from: stages)
                try expectEqual(lines.map(\.detail), ["done", "40%"]); try expectEqual(lines.map(\.isSecondary), [false, true])
                try expectEqual(lines.map(\.fraction), [1, 0.4])
                try expectEqual(DownloadStageLine.summary(lines), "Converting 40%")
                let early = DownloadStageLine.lines(from: [StageProgress(spec: .download(), state: .running, fraction: 0.5), StageProgress(spec: .convert())])
                try expectEqual(DownloadStageLine.summary(early), "Downloading 50%, then Converting")
                try expectEqual(early[1].detail, "waiting"); try expectEqual(early[1].fraction, 0)
                // The live job feeds the same lines.
                let job = DownloadSnapshotSamples.twoStageJob(title: "x", convertFraction: 0.25)
                try expectEqual(DownloadStageLine.lines(from: job.stages).map(\.detail), ["done", "25%"])
                job.finish(.done)
                try expect(DownloadStageLine.lines(from: job.stages).allSatisfy { $0.state == .done })
            }
        }

        test("toasts: started, rejected and fixable failures use the Jobs toast with the right words and buttons") {
            try await downloadUIEnglish {
                let log = Locked<[(String, UserMessage.Severity, String?)]>([])
                DownloadToast.sink = { text, _, severity, action in log.withLock { $0.append((text, severity, action)) } }
                defer { DownloadToast.sink = nil }
                let link = LinkItem(url: URL(string: videoLink)!, title: "Swamp Films")
                try expectEqual(DownloadToast.startedText(link: link, mode: .bestForApple), "Download started: Swamp Films")
                try expect(DownloadToast.startedText(link: link, mode: .audioMP3).hasPrefix("Audio download started"))
                try expectEqual(DownloadToast.startedText(link: LinkItem(url: URL(string: videoLink)!), mode: .maximum), "Download started: youtube.com")
                DownloadToast.rejected(.unsupportedScheme("ftp"))
                let rejected = try unwrap(log.value.last)
                try expect(rejected.0.contains("ftp") && rejected.1 == .warning && rejected.2 == nil)
                let job = DownloadSnapshotSamples.twoStageJob(title: "Swamp", convertFraction: 0.2)
                DownloadToast.started(link: link, mode: .bestForApple, job: job)
                try expectEqual(try unwrap(log.value.last).2, "Show")
                job.finish(.failed, error: YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: Sign in to confirm you're not a bot").text)
                try await expectEventually(timeout: 5) { log.value.count == 3 }
                let failed = try unwrap(log.value.last)
                try expect(failed.1 == .error && failed.2 == "Choose a browser", "\(failed)")
                // An unremarkable failure leaves the job card alone (no second toast).
                let other = DownloadSnapshotSamples.twoStageJob(title: "Swamp 2", convertFraction: 0.2)
                DownloadToast.started(link: link, mode: .bestForApple, job: other)
                other.finish(.failed, error: "Could not reach the site. Check the internet connection and try again.")
                try await Task.sleep(for: .milliseconds(200))
                try expectEqual(log.value.count, 4, "only the 'started' toast was added")
                // With the download window open, its own "started" state is enough: no toast, but a fixable failure still gets one.
                let inSheet = DownloadSnapshotSamples.twoStageJob(title: "Swamp 3", convertFraction: 0.2)
                DownloadToast.started(link: link, mode: .bestForApple, job: inSheet, sheetVisible: true)
                try expectEqual(log.value.count, 4, "no second 'started' message while the sheet is open")
                inSheet.finish(.failed, error: YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: Sign in to confirm you're not a bot").text)
                try await expectEventually(timeout: 5) { log.value.count == 5 }
            }
        }

        test("install model: words for progress, checksum and errors; the speed choices keep an unusual stored value") {
            try await downloadUIEnglish {
                try expect(YtDlpInstallModel.progressText(kind: .install, progress: 0.3).contains("30%"))
                try expect(YtDlpInstallModel.progressText(kind: .install, progress: 0.92).contains("SHA-256"))
                let ok = YtDlpInstallModel.Outcome(kind: .install, version: "2026.11.01", checksumVerified: true, alreadyLatest: false)
                try expect(YtDlpInstallModel.successText(ok).contains("2026.11.01") && YtDlpInstallModel.successText(ok).contains("SHA-256"))
                let latest = YtDlpInstallModel.Outcome(kind: .update, version: "2026.11.01", checksumVerified: false, alreadyLatest: true)
                try expect(YtDlpInstallModel.successText(latest).contains("up to date"))
                try expect(YtDlpInstallModel.plain(URLError(.notConnectedToInternet)).contains("github.com"))
                try expectEqual(DownloaderSettingsNetworkSections.rateTitle(0), "No limit"); try expectEqual(DownloaderSettingsNetworkSections.rateTitle(2_048), "2 MB/s")
                try expectEqual(DownloaderSettingsNetworkSections.rateTitle(512), "512 KB/s")
                try expect(DownloaderSettingsView.isManagedByApp(YtDlpStatus(url: URL(fileURLWithPath: "/x"), version: nil, source: .userFolder, jsRuntime: nil)))
                try expect(!DownloaderSettingsView.isManagedByApp(YtDlpStatus(url: URL(fileURLWithPath: "/x"), version: nil, source: .homebrew, jsRuntime: nil)))
            }
        }

        test("views: the sheet, the notice, the install offer and the settings page build in both languages") {
            for lang in [LanguageSetting.english, .russian] {
                let saved = Loc.shared.setting
                Loc.shared.set(lang)
                defer { Loc.shared.set(saved) }
                let stub = StubSheet()
                let model = DownloadSheetModel.preview(deps: stub.deps(), phase: .info, text: videoLink, info: DownloadSnapshotSamples.info("video.json"))
                let views: [AnyView] = [
                    AnyView(DownloadSheetContent(model: model, onClose: {})),
                    AnyView(DownloadConsentView(onFinish: { _ in }, settings: stub.settings)),
                    AnyView(DownloadInstallOfferBody(phase: .idle, probe: JSRuntimeProbe(state: .missing), onInstall: {}, onCancel: {}, onContinue: {})),
                    AnyView(DownloaderSettingsView(settings: stub.settings, manager: YtDlpToolManager(), probe: JSRuntimeProbe(state: .missing), refreshesOnAppear: false))
                ]
                for v in views {
                    let host = NSHostingView(rootView: v.appRoot())
                    host.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
                    host.layoutSubtreeIfNeeded()
                    try expect(host.fittingSize.width > 100, "the view lays out")
                }
            }
        }

        test("the Russian strings of the notice and the failures differ from the English ones and are not empty") {
            let l10n: [L10n] = DownloadNotice.points.map(\.text) + [DownloadNotice.heading, DownloadNotice.legalTitle, DownloadNotice.legalText, DownloadNotice.usageLine]
                + DownloadModeChoice.allCases.flatMap { [$0.title, $0.explanation] } + DownloadAudioFormat.choices.map(\.detail)
            for s in l10n { try expect(!s.en.isEmpty && !s.ru.isEmpty && s.en != s.ru, "missing translation: \(s.en)") }
            try expect(DownloadFailure.Kind.allCases.count >= 14)
        }
    }
}
