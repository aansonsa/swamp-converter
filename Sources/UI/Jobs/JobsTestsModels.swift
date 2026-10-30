import Foundation
import SwiftUI
import AppKit

// Self-tests of the row model, the text formatting, the list sections and the row views.

enum JobsTestsModels {
    @MainActor
    static func snapshot(_ state: JobState, held: Bool = false, progress: Double? = nil, outputs: [String] = [], failures: [String] = [], error: String? = nil,
                         cancelRequested: Bool = false, elapsed: TimeInterval = 0, stages: [StageProgress] = [], names: [String] = ["photo.png"]) -> JobSnapshot {
        JobSnapshot(title: "Convert to JPG", state: state, held: held, cancelRequested: cancelRequested, progress: progress, errorMessage: error, failures: failures,
                    outputs: outputs.map { URL(fileURLWithPath: $0) }, stages: stages, inputNames: names, elapsed: elapsed)
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("jobs.rows", "every job state maps to one phase with the right buttons and status glyph") {
            try JobsTestKit.withLanguage(.english) {
                let queued = JobRowModel.make(snapshot(.waiting))
                try expectEqual(queued.phase, .queued); try expectEqual(queued.statusLine, "Waiting"); try expectEqual(queued.statusKind, .waiting)
                try expect(queued.canCancel && !queued.canPause && !queued.canRemove && !queued.showsBar)

                let held = JobRowModel.make(snapshot(.waiting, held: true))
                try expectEqual(held.phase, .held); try expectEqual(held.statusLine, "Added to the queue")

                let running = JobRowModel.make(snapshot(.running, progress: 0.42))
                try expectEqual(running.phase, .running); try expectEqual(running.percentText, "42%"); try expectEqual(running.statusKind, .running)
                try expect(running.showsBar && running.canPause && running.canCancel && !running.canResume && !running.canRetry)

                let cancelling = JobRowModel.make(snapshot(.running, progress: 0.5, cancelRequested: true))
                try expectEqual(cancelling.phase, .cancelling); try expect(!cancelling.canCancel, "a second Cancel does nothing")

                let paused = JobRowModel.make(snapshot(.paused, progress: 0.6))
                try expectEqual(paused.phase, .paused); try expect(paused.canResume && !paused.canPause && paused.canCancel); try expectEqual(paused.statusKind, .paused)

                let done = JobRowModel.make(snapshot(.done, outputs: ["/tmp/a.jpg"], elapsed: 12))
                try expectEqual(done.phase, .done); try expectEqual(done.statusLine, "Done in 12 s"); try expect(done.hasResult && done.canRemove && !done.canRetry)
                try expectEqual(done.statusKind, .done)

                let quick = JobRowModel.make(snapshot(.done, outputs: ["/tmp/a.jpg"], elapsed: 0.3))
                try expectEqual(quick.statusLine, "Done", "no duration under a second")

                let noOutput = JobRowModel.make(snapshot(.done))
                try expect(!noOutput.hasResult, "nothing to reveal without a result")

                let warn = JobRowModel.make(snapshot(.done, outputs: ["/tmp/a.png"], failures: ["b.tiff: Cannot read b.tiff."]))
                try expectEqual(warn.phase, .doneWithWarnings); try expectEqual(warn.statusKind, .warning); try expectEqual(warn.statusLine, "Done, 1 failed")
                try expect(warn.errorText?.contains("b.tiff") == true && warn.hasResult)

                let failed = JobRowModel.make(snapshot(.failed, error: "ffmpeg is not installed."))
                try expectEqual(failed.phase, .failed); try expectEqual(failed.errorText, "ffmpeg is not installed."); try expect(failed.canRetry && failed.canRemove && !failed.hasResult)
                try expectEqual(failed.statusKind, .failed)
                let blank = JobRowModel.make(snapshot(.failed, error: "  "))
                try expect(blank.errorText?.isEmpty == false, "a failed row always says something")

                for s in [JobState.cancelled, .skipped] {
                    let m = JobRowModel.make(snapshot(s))
                    try expect(m.canRetry && m.canRemove && !m.canCancel, "\(s)")
                    try expectEqual(m.statusKind, .idle)
                }
                try expectEqual(JobRowModel.make(snapshot(.cancelled)).statusLine, "Canceled")
            }
        }

        t.register("jobs.rows", "row texts: the same job reads in Russian, and VoiceOver gets title, state, percent and ETA") {
            let s = JobSnapshot(title: "Convert to MP4", state: .running, progress: 0.42, eta: 130, inputNames: ["holiday.mov"])
            let en = JobsTestKit.withLanguage(.english) { JobRowModel.make(s) }
            let ru = JobsTestKit.withLanguage(.russian) { JobRowModel.make(s) }
            try expect(en.accessibilityLabel.contains("Running") && en.accessibilityLabel.contains("42%") && en.accessibilityLabel.contains("About 2 minutes left"), en.accessibilityLabel)
            try expect(ru.accessibilityLabel.contains("Выполняется") && ru.accessibilityLabel.contains("Осталось около 2 минут"), ru.accessibilityLabel)
            try expect(en.accessibilityLabel.contains("holiday.mov"))
            let failed = JobsTestKit.withLanguage(.russian) { JobRowModel.make(JobSnapshot(title: "x", state: .failed, errorMessage: "Файл не читается.", inputNames: ["a.png"])) }
            try expect(failed.accessibilityLabel.contains("Не удалось") && failed.accessibilityLabel.contains("Файл не читается."), failed.accessibilityLabel)
        }

        t.register("jobs.rows", "ETA text rounds calmly and takes the Russian plural forms after 'около'") {
            try JobsTestKit.withLanguage(.english) {
                try expectEqual(JobsFormat.etaText(nil), nil)
                try expectEqual(JobsFormat.etaText(-4), nil)
                try expectEqual(JobsFormat.etaText(2), "Almost done")
                try expectEqual(JobsFormat.etaText(12), "About 10 seconds left")
                try expectEqual(JobsFormat.etaText(44), "About 45 seconds left")
                try expectEqual(JobsFormat.etaText(60), "About 1 minute left")
                try expectEqual(JobsFormat.etaText(130), "About 2 minutes left")
                try expectEqual(JobsFormat.etaText(600), "About 10 minutes left")
                try expectEqual(JobsFormat.etaText(3600), "About 1 hour left")
                try expectEqual(JobsFormat.etaText(5400), "About 1 h 30 min left")
                try expectEqual(JobsFormat.etaText(7200), "About 2 hours left")
                try expectEqual(JobsFormat.etaText(90_000), "More than a day left")
            }
            try JobsTestKit.withLanguage(.russian) {
                try expectEqual(JobsFormat.etaText(2), "Почти готово")
                try expectEqual(JobsFormat.etaText(12), "Осталось около 10 секунд")
                try expectEqual(JobsFormat.etaText(60), "Осталось около 1 минуты")
                try expectEqual(JobsFormat.etaText(120), "Осталось около 2 минут")
                try expectEqual(JobsFormat.etaText(300), "Осталось около 5 минут")
                try expectEqual(JobsFormat.etaText(660), "Осталось около 11 минут")
                try expectEqual(JobsFormat.etaText(1260), "Осталось около 21 минуты")
                try expectEqual(JobsFormat.etaText(1320), "Осталось около 22 минут")
                try expectEqual(JobsFormat.etaText(3600), "Осталось около 1 часа")
                try expectEqual(JobsFormat.etaText(7200), "Осталось около 2 часов")
                try expectEqual(JobsFormat.etaText(75_600), "Осталось около 21 часа")
                try expectEqual(JobsFormat.etaText(5400), "Осталось около 1 ч 30 мин")
                try expectEqual(JobsFormat.etaText(90_000), "Осталось больше суток")
            }
            // Step stability: a number that creeps by a second does not change the sentence every tick.
            try JobsTestKit.withLanguage(.english) {
                try expectEqual(JobsFormat.etaText(131), JobsFormat.etaText(129))
                try expectEqual(JobsFormat.etaText(312), JobsFormat.etaText(298))
            }
        }

        t.register("jobs.rows", "percent never reads 100 before the end; speed needs a real file and a few seconds; durations") {
            try expectEqual(JobsFormat.percentText(nil), nil)
            try expectEqual(JobsFormat.percentText(0), "0%")
            try expectEqual(JobsFormat.percentText(0.999), "99%")
            try expectEqual(JobsFormat.percentText(1.7), "100%")
            try expectEqual(JobsFormat.percentText(-1), "0%")
            try expectEqual(JobsFormat.percentText(.nan), nil)
            try expectEqual(JobsFormat.speedText(progress: 0.5, inputBytes: 1_000_000, elapsed: 10), nil, "small files give no speed")
            try expectEqual(JobsFormat.speedText(progress: 0.5, inputBytes: 100_000_000, elapsed: 1), nil, "too early")
            try expectEqual(JobsFormat.speedText(progress: 0.01, inputBytes: 100_000_000, elapsed: 10), nil, "noise")
            try expectEqual(JobsFormat.speedText(progress: nil, inputBytes: 100_000_000, elapsed: 10), nil)
            let speed = try unwrap(JobsTestKit.withLanguage(.english) { JobsFormat.speedText(progress: 0.5, inputBytes: 100_000_000, elapsed: 10) })
            try expect(speed.hasSuffix("/s") && speed.contains("5"), speed)
            let ru = try unwrap(JobsTestKit.withLanguage(.russian) { JobsFormat.speedText(progress: 0.5, inputBytes: 100_000_000, elapsed: 10) })
            try expect(ru.hasSuffix("/с"), ru)
            try expectEqual(JobsFormat.tookText(0.4), nil)
            try expectEqual(JobsTestKit.withLanguage(.english) { JobsFormat.tookText(42) }, "42 s")
        }

        t.register("jobs.rows", "the stage chain lists the steps, shows the running step's percent, hides skipped steps and tints the second stage") {
            var download = StageProgress(spec: .download(), state: .running, fraction: 0.62)
            download.startedAt = Date()
            let convert = StageProgress(spec: .convert())
            let m = JobsTestKit.withLanguage(.english) { JobRowModel.make(snapshot(.running, progress: 0.3, stages: [download, convert])) }
            try expectEqual(m.stageLine, "Downloading 62% \u{2192} Converting")
            try expect(!m.barIsSecondary, "the first stage uses the pink bar")
            // The line is read in the language it was made in (the percent sign follows the language too).
            let ruLine = JobsTestKit.withLanguage(.russian) { JobRowModel.make(snapshot(.running, progress: 0.3, stages: [download, convert])).stageLine }
            try expectEqual(ruLine, "Загрузка 62 % \u{2192} Конвертация")

            var done = download; done.state = .done; done.fraction = 1
            var running = convert; running.state = .running; running.fraction = 0.5
            let second = JobRowModel.make(snapshot(.running, progress: 0.8, stages: [done, running]))
            try expect(second.barIsSecondary, "later stages use the Swamp Blue bar")
            try expect(second.stages.first { $0.id == "convert" }?.percent == 50 && second.stages.first { $0.id == "download" }?.percent == nil)

            var skipped = convert; skipped.state = .skipped
            try expect(JobRowModel.make(snapshot(.running, stages: [download, skipped])).stages.isEmpty, "one live stage is not a chain")
            try expect(JobRowModel.make(snapshot(.running, stages: [])).stages.isEmpty)
            // The runner's message repeats the stage name: not shown twice.
            var named = JobSnapshot(title: "x", state: .running, statusText: "Downloading", stages: [download, convert], inputNames: ["a"])
            named.progress = 0.2
            try expectEqual(JobsTestKit.withLanguage(.english) { JobRowModel.make(named).statusLine }, "")
        }

        t.register("jobs.rows", "the symbol comes from the operation, else the link glyph, else the first input's kind") {
            try expectEqual(JobRowModel.symbol(JobSnapshot(operationSymbol: "film.stack", inputNames: ["a.png"])), "film.stack")
            try expectEqual(JobRowModel.symbol(JobSnapshot(inputNames: ["youtube.com"], isLinkJob: true)), "arrow.down.circle")
            try expectEqual(JobRowModel.symbol(JobSnapshot(inputNames: ["clip.mp4"])), FileKind.video.symbol)
            try expectEqual(JobRowModel.symbol(JobSnapshot(inputNames: ["song.mp3"])), FileKind.audio.symbol)
            try expectEqual(JobRowModel.symbol(JobSnapshot()), "doc")
            try JobsTestKit.withLanguage(.english) {
                try expectEqual(JobRowModel.inputLine(JobSnapshot(inputNames: ["a.png"])), "a.png")
                try expectEqual(JobRowModel.inputLine(JobSnapshot(inputNames: ["a.png", "b.png", "c.png"])), "3 files")
                try expectEqual(JobRowModel.inputLine(JobSnapshot(inputNames: ["a", "b"], isLinkJob: true)), "2 links")
            }
            try expectEqual(JobsTestKit.withLanguage(.russian) { JobRowModel.inputLine(JobSnapshot(inputNames: ["a", "b", "c", "d", "e"])) }, "5 файлов")
        }

        t.register("jobs.rows", "a snapshot taken from a live job follows its state, and a finished job's results") {
            let running = JobsSamples.running(progress: 0.42)
            let s = JobSnapshot(job: running, queuePaused: false, operationSymbol: nil)
            try expectEqual(s.state, .running); try expectClose(s.progress ?? -1, 0.42); try expectEqual(s.eta, 130)
            let done = JobSnapshot(job: JobsSamples.done(), queuePaused: false, operationSymbol: "photo")
            try expectEqual(done.state, .done); try expectEqual(done.outputs.count, 1); try expectEqual(done.operationSymbol, "photo")
            let queued = JobSnapshot(job: JobsSamples.queued(), queuePaused: true, operationSymbol: nil)
            try expect(queued.queuePaused && queued.state == .waiting)
            try expectEqual(JobsTestKit.withLanguage(.english) { JobRowModel.make(queued).statusLine }, "Queue paused")
        }

        t.register("jobs.rows", "the row observer shows the first state at once and later changes within a tenth of a second, without the log") {
            let job = JobsSamples.running(progress: 0.1)
            let runner = JobRunner(persistence: false)
            let observer = JobRowObserver(job: job, runner: runner)
            try expectClose(observer.snapshot.progress ?? -1, 0.1)
            try await Task.sleep(nanoseconds: 120_000_000)   // Job.update itself drops updates closer than 80 ms
            job.update(progress: 0.5, message: "Halfway", etaHint: 60)
            try await expectEventually(timeout: 2) { observer.snapshot.progress == 0.5 }
            try expectEqual(observer.snapshot.statusText, "Halfway")
            job.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/tmp/x.jpg")]))
            try await expectEventually(timeout: 2) { observer.snapshot.state == .done }
            try expectEqual(observer.snapshot.outputs.count, 1)
            // 200 log lines change nothing the row shows: the snapshot stays the same object value.
            let before = observer.snapshot
            for i in 0..<200 { job.appendLog("line \(i)") }
            try await Task.sleep(nanoseconds: 300_000_000)
            try expectEqual(observer.snapshot.id, before.id); try expectEqual(observer.snapshot.state, before.state)
        }

        t.register("jobs.list", "the window's sections: running (with paused), queued, finished newest first; clear and pause state") {
            let a = JobsSamples.running(), p = JobsSamples.paused(), q1 = JobsSamples.queued("Q1"), q2 = JobsSamples.queued("Q2")
            let f1 = JobsSamples.done("F1")
            try await Task.sleep(nanoseconds: 20_000_000)
            let f2 = JobsSamples.failed()
            let all = [f1, q1, a, f2, q2, p]
            try expectEqual(JobsListModel.running(all).map(\.id), [a.id, p.id])
            try expectEqual(JobsListModel.queued(all).map(\.id), [q1.id, q2.id])
            try expectEqual(JobsListModel.finished(all).map(\.id), [f2.id, f1.id], "newest first")
            let model = JobsListModel(runner: JobRunner(persistence: false), jobs: all)
            try expect(model.canClearFinished && model.hasWork && !model.isEmpty)
            let empty = JobsListModel(runner: JobRunner(persistence: false), jobs: [])
            try expect(empty.isEmpty && !empty.canClearFinished && !empty.hasWork)
            let onlyFinished = JobsListModel(runner: JobRunner(persistence: false), jobs: [f1])
            try expect(!onlyFinished.hasWork, "nothing to pause when only finished jobs remain")
            let heldOnly = JobsSamples.queued("H")
            heldOnly.held = true
            try expect(!JobsListModel(runner: JobRunner(persistence: false), jobs: [heldOnly]).hasWork, "a held job is not work in progress")
        }

        t.register("jobs.list", "dragging inside the Queued section is translated into the runner's indices") {
            let ids = (0..<5).map { _ in UUID() }
            // all: [run, Q1, run, Q2, Q3]
            let all = ids
            let queued = [ids[1], ids[3], ids[4]]
            let up = try unwrap(JobsListModel.moveArguments(all: all, queued: queued, from: IndexSet(integer: 2), to: 0))
            try expectEqual(up.source, IndexSet(integer: 4)); try expectEqual(up.destination, 1)
            let toEnd = try unwrap(JobsListModel.moveArguments(all: all, queued: queued, from: IndexSet(integer: 0), to: 3))
            try expectEqual(toEnd.source, IndexSet(integer: 1)); try expectEqual(toEnd.destination, 5)
            let middle = try unwrap(JobsListModel.moveArguments(all: all, queued: queued, from: IndexSet(integer: 0), to: 2))
            try expectEqual(middle.destination, 4)
            try expect(JobsListModel.moveArguments(all: all, queued: queued, from: IndexSet(integer: 7), to: 0) == nil)
            try expect(JobsListModel.moveArguments(all: all, queued: [], from: IndexSet(integer: 0), to: 0) == nil)
            // The real runner accepts the arguments and keeps the running job where it was.
            let runner = JobRunner(persistence: false)
            guard let op = OperationRegistry.shared.allOperations().first else { try skipTest("no operations registered") }
            let jobs = (0..<3).map { _ in runner.enqueue(operation: op, items: [], mode: .automatic) }
            let args = try unwrap(JobsListModel.moveArguments(all: runner.jobs.map(\.id), queued: jobs.map(\.id), from: IndexSet(integer: 2), to: 0))
            runner.move(fromOffsets: args.source, toOffset: args.destination)
            try expectEqual(runner.jobs.map(\.id), [jobs[2].id, jobs[0].id, jobs[1].id])
        }

        t.register("jobs.list", "the list model hears the runner while the window is open and stops when it closes") {
            guard let op = OperationRegistry.shared.allOperations().first else { try skipTest("no operations registered") }
            let runner = JobRunner(persistence: false)
            let model = JobsListModel(runner: runner)
            model.start(); model.start()
            let before = model.revision
            _ = runner.enqueue(operation: op, items: [], mode: .automatic)
            try await expectEventually(timeout: 2) { model.revision > before }
            model.stop()
            let after = model.revision
            _ = runner.enqueue(operation: op, items: [], mode: .automatic)
            try await Task.sleep(nanoseconds: 150_000_000)
            try expectEqual(model.revision, after, "no events after stop")
        }

        t.register("jobs.rows", "row actions drive the runner: cancel a waiting job, remove a finished one") {
            guard let op = OperationRegistry.shared.allOperations().first else { try skipTest("no operations registered") }
            let runner = JobRunner(persistence: false)
            let job = runner.enqueue(operation: op, items: [], mode: .automatic)
            runner.pauseQueue()   // a retried job must not start a real operation inside the test
            JobRowActions.perform(.cancel, job: job, runner: runner)
            try expectEqual(job.state, .cancelled)
            JobRowActions.perform(.retry, job: job, runner: runner)
            try expectEqual(job.state, .waiting, "retry puts the job back in line")
            JobRowActions.perform(.cancel, job: job, runner: runner)
            JobRowActions.perform(.remove, job: job, runner: runner)
            try expect(runner.jobs.isEmpty)
            try expect(JobRowActions.Action.allCases.allSatisfy { !JobRowActions.title($0).isEmpty })
        }

        t.register("jobs.rows", "rows fit: every state at the window's minimum width, English and Russian, with sane heights") {
            let runner = JobRunner(persistence: false)
            let samples: [(String, Job)] = [("running", JobsSamples.running()), ("two-stage", JobsSamples.twoStage()), ("done", JobsSamples.done()), ("many", JobsSamples.doneMany()),
                                            ("failed", JobsSamples.failed()), ("warnings", JobsSamples.withWarnings()), ("queued", JobsSamples.queued()), ("paused", JobsSamples.paused())]
            for lang in [LanguageSetting.english, .russian] {
                try JobsTestKit.withLanguage(lang) {
                    for (name, job) in samples {
                        let size = SharedTestKit.fitting(JobRowView(job: job, runner: runner), width: 440)
                        try expect(size.height > 40 && size.height < 260, "\(name) \(lang): height \(size.height)")
                    }
                    let card = SharedTestKit.fitting(JobHUDCard(job: JobsSamples.failed(), runner: runner), width: JobHUDCard.width)
                    try expect(card.height > 60 && card.height < 300, "hud card \(card.height)")
                }
            }
        }
    }
}
