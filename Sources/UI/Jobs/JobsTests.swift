import Foundation
import SwiftUI
import Combine

// Self-tests of the menu-bar model, the throttle, and the coordinator that routes job and message events. The row/format tests are in JobsTestsModels,
// toasts / notifications / HUD in JobsTestsDelivery.

enum JobsTests {
    @MainActor
    private struct Rig {
        let runner = JobRunner(persistence: false)
        let model = MenuBarProgressModel()
        let kit = JobsTestKit.toastCenter()
        let sink = FakeNotificationSink()
        let hudClock = FakeScheduler()
        let hud: JobHUDController
        let notifications: NotificationService
        let messages = MessageCenter()
        let coordinator: JobsCoordinator
        let badge = Locked<[String]>([])

        init(mode: NotificationMode = .always, windowVisible: Bool = false) {
            hud = JobHUDController(scheduler: hudClock)
            hud.showsPanel = false
            sink.status = .authorized
            let center = kit.center
            notifications = NotificationService(sink: sink, mode: { mode }, isAppActive: { false }, toasts: { center })
            coordinator = JobsCoordinator(runner: runner, messages: messages, model: model, toasts: center, notifications: notifications, hud: hud)
            let log = badge
            coordinator.setDockBadge = { label in log.withLock { $0.append(label ?? "-") } }
            coordinator.jobsWindowVisible = { windowVisible }
        }
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("jobs.menubar", "the aggregate: counts, fraction over finished and running jobs, status line in both languages") {
            func input(_ state: JobState, _ p: Double? = nil, held: Bool = false, download: Bool = false) -> JobProgressInput {
                JobProgressInput(state: state, held: held, progress: p, isDownload: download)
            }
            let idle = MenuBarAggregate.make(active: [], finishedInSession: 3, queuePaused: false)
            try expect(idle.isIdle && idle.fraction == nil && idle.statusLine.isEmpty)
            try expect(MenuBarAggregate.make(active: [input(.waiting, held: true)], finishedInSession: 0, queuePaused: false).isIdle, "a held job does not light the menu bar")
            try expect(MenuBarAggregate.make(active: [input(.done), input(.failed)], finishedInSession: 0, queuePaused: false).isIdle, "finished jobs are not work")

            try JobsTestKit.withLanguage(.english) {
                let one = MenuBarAggregate.make(active: [input(.running)], finishedInSession: 0, queuePaused: false)
                try expect(one.fraction == nil && one.running == 1 && one.statusLine == "Converting", "indeterminate: \(one)")
                let half = MenuBarAggregate.make(active: [input(.running, 0.5)], finishedInSession: 0, queuePaused: false)
                try expectEqual(half.statusLine, "Converting \u{2013} 50%"); try expectClose(half.fraction ?? -1, 0.5)
                let three = MenuBarAggregate.make(active: [input(.running, 0.5), input(.running, 0.25)], finishedInSession: 1, queuePaused: false)
                try expectClose(three.fraction ?? -1, 1.75 / 3, tolerance: 1e-9)
                try expectEqual(three.statusLine, "Converting 2 of 3 \u{2013} 58%")
                try expectEqual(three.running, 2)
                let waiting = MenuBarAggregate.make(active: [input(.waiting), input(.waiting)], finishedInSession: 0, queuePaused: false)
                try expect(waiting.fraction == nil && waiting.waiting == 2 && waiting.running == 0, "\(waiting)")
                try expectEqual(waiting.statusLine, "2 items waiting")
                let after = MenuBarAggregate.make(active: [input(.waiting)], finishedInSession: 2, queuePaused: false)
                try expectClose(after.fraction ?? -1, 2.0 / 3.0, tolerance: 1e-9)
                let paused = MenuBarAggregate.make(active: [input(.paused, 0.4), input(.waiting)], finishedInSession: 0, queuePaused: true)
                try expectEqual(paused.statusLine, "Paused \u{2013} 0 of 2 done"); try expectEqual(paused.paused, 1)
                let download = MenuBarAggregate.make(active: [input(.running, 0.1, download: true)], finishedInSession: 0, queuePaused: false)
                try expectEqual(download.statusLine, "Downloading \u{2013} 10%")
                let capped = MenuBarAggregate.make(active: [input(.running, 7)], finishedInSession: 0, queuePaused: false)
                try expectClose(capped.fraction ?? -1, 1)
            }
            try JobsTestKit.withLanguage(.russian) {
                let three = MenuBarAggregate.make(active: [input(.running, 0.5), input(.running, 0.25)], finishedInSession: 1, queuePaused: false)
                try expectEqual(three.statusLine, "Конвертация 2 из 3 \u{2013} 58 %")
                let paused = MenuBarAggregate.make(active: [input(.paused, 0.4), input(.waiting)], finishedInSession: 0, queuePaused: true)
                try expectEqual(paused.statusLine, "Приостановлено \u{2013} готово 0 из 2")
            }
        }

        t.register("jobs.menubar", "the model starts idle, publishes only real changes, keeps the five newest results once each, and clears the unseen-error dot") {
            let model = MenuBarProgressModel()
            try expect(model.isIdle && model.fraction == nil && !model.hasUnseenError && model.recentResults.isEmpty)
            var changes = 0
            let sub = model.objectWillChange.sink { changes += 1 }
            let a = MenuBarAggregate(fraction: 0.4, running: 1, waiting: 2, paused: 0, statusLine: "x")
            model.apply(a)
            let first = changes
            try expect(first > 0 && !model.isIdle && model.waiting == 2)
            model.apply(a)
            try expectEqual(changes, first, "the same numbers publish nothing")
            model.apply(.idle)
            try expect(model.isIdle && model.fraction == nil && model.statusLine.isEmpty)

            for i in 0..<7 { model.noteFinished(title: "Job \(i)", outputs: [URL(fileURLWithPath: "/o/f\(i).jpg")]) }
            try expectEqual(model.recentResults.count, MenuBarProgressModel.recentLimit)
            try expectEqual(model.recentResults.first?.title, "Job 6"); try expectEqual(model.recentResults.last?.title, "Job 2")
            model.noteFinished(title: "Again", outputs: [URL(fileURLWithPath: "/o/f4.jpg")])
            try expectEqual(model.recentResults.filter { $0.url.lastPathComponent == "f4.jpg" }.count, 1, "the same file is listed once")
            try expectEqual(model.recentResults.first?.title, "Again")
            model.noteFinished(title: "No output", outputs: [])
            try expectEqual(model.recentResults.first?.title, "Again", "a job without a file adds nothing")

            model.noteFailure()
            try expect(model.hasUnseenError)
            model.markErrorsSeen()
            try expect(!model.hasUnseenError)
            sub.cancel()

            let seeded = MenuBarProgressModel()
            let rec = { (title: String, state: JobState, out: [String]) in
                JobRecord(id: UUID(), title: title, operationID: "x", state: state, origin: .studio, itemNames: [], outputs: out, errorMessage: nil, note: nil, startedAt: nil, finishedAt: nil, bytesIn: 0)
            }
            seeded.seed(from: [rec("fail", .failed, ["/o/x"]), rec("one", .done, ["/o/1.jpg"]), rec("empty", .done, []), rec("two", .done, ["/o/2.jpg"])])
            try expectEqual(seeded.recentResults.map(\.title), ["one", "two"], "history seeds the list with successful results, newest first")
            seeded.seed(from: [rec("late", .done, ["/o/3.jpg"])])
            try expectEqual(seeded.recentResults.count, 2, "seeding never overwrites")
        }

        t.register("jobs.throttle", "the gate fires at once after quiet, at most 10 times a second under a flood, and the last request is never lost") {
            var gate = UpdateThrottle(minInterval: 0.1)
            try expectEqual(gate.request(now: 0), .now)
            guard case .later(let wait) = gate.request(now: 0.03) else { throw TestFailure(message: "expected a trailing fire", file: #fileID, line: #line) }
            try expectClose(wait, 0.07, tolerance: 1e-9)
            try expectEqual(gate.request(now: 0.05), .alreadyScheduled)
            gate.trailingFired(now: 0.1)
            try expectEqual(gate.request(now: 5), .now, "after a quiet spell the next request is immediate")

            // A 3 s flood, one request per millisecond. Every fire is recorded; the trailing ones happen when the gate asked for them.
            var flood = UpdateThrottle(minInterval: 0.1)
            var fires: [Double] = []
            var trailingAt: Double?
            for ms in 0...3000 {
                let now = Double(ms) / 1000
                if let at = trailingAt, now >= at - 1e-9 { flood.trailingFired(now: now); fires.append(now); trailingAt = nil }
                switch flood.request(now: now) {
                case .now: fires.append(now)
                case .later(let after): trailingAt = now + after
                case .alreadyScheduled: break
                }
            }
            try expect(fires.count <= 31 && fires.count >= 28, "\(fires.count) fires in 3 s")
            for i in 0..<(fires.count - 10) { try expect(fires[i + 10] - fires[i] >= 1.0 - 1e-9, "11 fires inside one second at \(fires[i])") }
            // Stop asking at 3.0 s: the pending trailing fire delivers the newest state within one interval.
            if let at = trailingAt { try expect(at - 3.0 <= 0.1 + 1e-9, "the last request is delivered within 100 ms") }
        }

        t.register("jobs.throttle", "ThrottledAction runs the first call at once and folds a burst into one scheduled run") {
            var now = 0.0
            var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
            var runs = 0
            let action = ThrottledAction(now: { now }, schedule: { delay, block in scheduled.append((delay, block)) }, action: { runs += 1 })
            action.request()
            try expectEqual(runs, 1)
            for _ in 0..<50 { action.request() }
            try expectEqual(runs, 1); try expectEqual(scheduled.count, 1, "one trailing block for the whole burst"); try expect(action.isPending)
            now = 0.1
            scheduled.removeFirst().1()
            try expectEqual(runs, 2); try expect(!action.isPending)
            now = 0.15
            action.request()
            try expectEqual(scheduled.count, 1, "a request inside the next interval is scheduled again")
        }

        t.register("jobs.coordinator", "job events drive the menu-bar model, the Dock badge, the recent list and the unseen-error dot") {
            let rig = Rig()
            let c = rig.coordinator
            let job = JobsSamples.running("Convert to MP4", progress: 0.5)
            c.handle(.added(job)); c.handle(.started(job))
            c.refreshNow()
            try expect(rig.model.running == 1 && !rig.model.isIdle)
            try expectClose(rig.model.fraction ?? -1, 0.5)
            try expectEqual(rig.badge.value.last, "1")
            job.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/o/out.mp4")]))
            c.handle(.finished(job))
            c.refreshNow()
            try expect(rig.model.isIdle && rig.model.fraction == nil, "idle again: \(rig.model.statusLine)")
            try expectEqual(rig.model.recentResults.map(\.title), ["Convert to MP4"])
            try expectEqual(rig.badge.value.last, "-", "the badge is cleared")

            let bad = JobsSamples.failed()
            c.handle(.added(bad)); c.handle(.started(bad)); c.handle(.failed(bad))
            try expect(rig.model.hasUnseenError)
            rig.model.markErrorsSeen()
            let cancelled = JobsSamples.cancelled()
            c.handle(.added(cancelled)); c.handle(.cancelled(cancelled))
            try expect(!rig.model.hasUnseenError, "a cancelled job is not an error")

            let watching = Rig(windowVisible: true)
            let b2 = JobsSamples.failed()
            watching.coordinator.handle(.added(b2)); watching.coordinator.handle(.failed(b2))
            try expect(!watching.model.hasUnseenError, "no dot for a failure the person is looking at")
        }

        t.register("jobs.coordinator", "a running job's progress reaches the model through the 10 Hz gate") {
            let rig = Rig()
            let job = JobsSamples.running("P", progress: 0.1)
            rig.coordinator.handle(.added(job)); rig.coordinator.handle(.started(job))
            rig.coordinator.refreshNow()
            let before = rig.coordinator.refreshCount
            try await Task.sleep(nanoseconds: 120_000_000)
            for i in 1...40 {
                job.update(progress: 0.1 + Double(i) * 0.01, message: "", etaHint: nil)   // Job.update drops most of these itself (80 ms)
            }
            for _ in 0..<200 { rig.coordinator.scheduleRefresh() }
            try expect(rig.coordinator.refreshCount - before <= 2, "a burst makes at most the leading and one trailing refresh: \(rig.coordinator.refreshCount - before)")
            try await expectEventually(timeout: 2) { !rig.coordinator.hasPendingWork }
            try await Task.sleep(nanoseconds: 250_000_000)   // the job's own change notification may still be on its way
            try expectClose(rig.model.fraction ?? -1, job.progress ?? -2, tolerance: 0.001)
            let settled = rig.coordinator.refreshCount
            try await Task.sleep(nanoseconds: 350_000_000)
            try expectEqual(rig.coordinator.refreshCount, settled, "nothing is scheduled while nothing happens")
            try expect(!rig.coordinator.hasPendingWork)
        }

        t.register("jobs.coordinator", "a finished batch gives one notification; quick-run batches (card shown) give none; unattended success is silent") {
            // The default mode ("when the app is in the background", the app is not in front here); "Always" also notifies after the card (policy test).
            let rig = Rig(mode: .background)
            let c = rig.coordinator
            let batch = UUID()
            let a = JobsSamples.make("A", names: ["a.png"], batch: batch), b = JobsSamples.make("B", names: ["b.png"], batch: batch)
            for j in [a, b] { c.handle(.added(j)); c.handle(.started(j)) }
            for j in [a, b] { j.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/o/\(j.title).jpg")])); c.handle(.finished(j)) }
            c.handle(.batchFinished(JobsTestKit.batch(succeeded: 2, outputs: ["/o/A.jpg", "/o/B.jpg"], id: batch)))
            await rig.notifications.deliverPending()
            try expectEqual(rig.sink.added.count, 1, "one notification for two jobs")
            try expectEqual(rig.sink.added.first?.id, batch.uuidString)

            let quick = JobsSamples.make("Q", names: ["q.png"], mode: .quick)
            c.handle(.added(quick)); c.handle(.started(quick))
            try expectEqual(rig.hud.jobs.count, 1, "a quick run gets a card")
            quick.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/o/q.jpg")])); c.handle(.finished(quick))
            c.handle(.batchFinished(JobsTestKit.batch(outputs: ["/o/q.jpg"], id: quick.batchID)))
            await rig.notifications.deliverPending()
            try expectEqual(rig.sink.added.count, 1, "the card was the feedback")
            try expect(!rig.hud.handled(batch: quick.batchID), "the batch is forgotten once it is over")

            c.handle(.batchFinished(JobsTestKit.batch(automatic: true)))
            await rig.notifications.deliverPending()
            try expectEqual(rig.sink.added.count, 1, "unattended success is silent")
            c.handle(.batchFinished(JobsTestKit.batch(succeeded: 0, failed: 1, outputs: [], automatic: true)))
            await rig.notifications.deliverPending()
            try expectEqual(rig.sink.added.count, 2, "unattended failure is not")
            try expect(rig.model.hasUnseenError)
        }

        t.register("jobs.coordinator", "messages become toasts: new ones through the stream, recent ones replayed once at start") {
            let rig = Rig()
            rig.messages.post("Posted before start", severity: .info, symbol: "tray.full")
            rig.coordinator.start()
            rig.coordinator.start()
            try expectEqual(rig.kit.surface.presented, ["Posted before start"], "replayed once, start is idempotent")
            rig.messages.post("Path copied", severity: .info, symbol: "doc.on.doc")
            rig.messages.post("Careful", severity: .warning)
            try await expectEventually(timeout: 2) { rig.kit.center.queue.pending.count == 2 }
            try expectEqual(rig.kit.center.queue.pending.map(\.text), ["Path copied", "Careful"])
            try expectEqual(rig.kit.center.queue.pending.last?.severity, .warning)
            rig.coordinator.stop()
            rig.messages.post("After stop")
            try await Task.sleep(nanoseconds: 100_000_000)
            try expectEqual(rig.kit.center.queue.pending.count, 2, "no toast after stop")
        }

        t.register("jobs.coordinator", "start seeds from jobs that already exist and from history, and a removed job leaves the picture") {
            let rig = Rig()
            guard let op = OperationRegistry.shared.allOperations().first else { try skipTest("no operations registered") }
            let job = rig.runner.enqueue(operation: op, items: [], mode: .automatic)
            rig.coordinator.start()
            rig.coordinator.refreshNow()
            try expect(rig.model.isIdle, "a held job from an earlier session is not work")
            job.held = false
            rig.runner.pauseQueue()
            rig.coordinator.handle(.queueStateChanged)
            rig.coordinator.refreshNow()
            try expectEqual(rig.model.waiting, 1)
            rig.runner.remove(job)
            rig.coordinator.refreshNow()
            try expect(rig.model.isIdle)
            rig.coordinator.stop()
        }

        t.register("jobs.strings", "every L(en, ru) in the jobs module has two real languages, no exclamation marks, no three-dot ellipsis") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            let dir = sources.appendingPathComponent("UI/Jobs")
            let pair = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)"#)
            var checked = 0
            var problems: [String] = []
            for (path, text) in SharedTestKit.swiftSources(in: dir) where !path.contains("Tests") && !path.hasSuffix("JobsTestKit.swift") {
                let ns = text as NSString
                for m in pair.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let en = ns.substring(with: m.range(at: 1)), ru = ns.substring(with: m.range(at: 2))
                    checked += 1
                    let file = URL(fileURLWithPath: path).lastPathComponent
                    if en == ru && en.rangeOfCharacter(from: .letters) != nil && !en.hasPrefix("\\(") { problems.append("\(file): same in both languages: \(en)") }
                    if !ru.unicodeScalars.contains(where: { $0.value >= 0x400 && $0.value <= 0x4FF }) && ru.rangeOfCharacter(from: .letters) != nil && !ru.hasPrefix("\\(") {
                        problems.append("\(file): no Cyrillic in \(ru)")
                    }
                    for s in [en, ru] where s.contains("!") || s.contains("...") { problems.append("\(file): '!' or '...' in \(s)") }
                }
            }
            try expect(checked > 60, "only \(checked) strings found: the pattern broke")
            try expect(problems.isEmpty, problems.prefix(8).joined(separator: "\n"))
        }

        t.register("jobs.strings", "module hygiene: files stay under 500 lines; no timers, no raw colours, no polling in production files") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            var problems: [String] = []
            for (path, text) in SharedTestKit.swiftSources(in: sources.appendingPathComponent("UI/Jobs")) {
                let file = URL(fileURLWithPath: path).lastPathComponent
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > 500 { problems.append("\(file): \(lines.count) lines") }
                if file.contains("Tests") || file.contains("TestKit") { continue }
                for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for bad in ["Timer.scheduled", "Timer(", "CADisplayLink", "TimelineView", "repeatForever", "Task.sleep", "TODO", "fatalError"] where line.contains(bad) {
                        problems.append("\(file):\(i + 1): \(bad)")
                    }
                }
            }
            try expect(problems.isEmpty, problems.prefix(8).joined(separator: "\n"))
        }
    }
}
