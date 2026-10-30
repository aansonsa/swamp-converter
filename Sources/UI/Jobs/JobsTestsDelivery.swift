import Foundation
import SwiftUI
import AppKit
import UserNotifications

// Self-tests of toasts, notifications and the HUD cards.

enum JobsTestsDelivery {
    static func register() {
        registerToasts()
        registerNotifications()
        registerHUD()
    }

    // MARK: Toasts

    private static func registerToasts() {
        let t = SelfTestRegistry.shared

        t.register("jobs.toast", "the queue keeps order, folds repeats, and drops the oldest confirmation first when full") {
            var q = ToastQueue()
            let a = ToastItem(text: "A"), b = ToastItem(text: "B"), c = ToastItem(text: "C")
            try expectEqual(q.enqueue(a), .startNow)
            try expectEqual(q.enqueue(b), .queued)
            try expectEqual(q.enqueue(c), .queued)
            try expectEqual(q.enqueue(ToastItem(text: "A")), .merged, "the same sentence while it is up")
            try expectEqual(q.enqueue(ToastItem(text: "C")), .merged, "the same sentence as the last waiting one")
            try expectEqual(q.pending.map(\.text), ["B", "C"])
            try expectEqual(q.advance()?.text, "B")
            try expectEqual(q.advance()?.text, "C")
            try expect(q.advance() == nil && q.isEmpty)
            try expectEqual(q.enqueue(ToastItem(text: "D")), .startNow, "an empty queue starts again")

            var full = ToastQueue()
            _ = full.enqueue(ToastItem(text: "now"))
            _ = full.enqueue(ToastItem(text: "error", severity: .error))
            for i in 0..<ToastQueue.maxPending { _ = full.enqueue(ToastItem(text: "info \(i)")) }
            try expectEqual(full.pending.count, ToastQueue.maxPending)
            try expect(full.pending.contains { $0.text == "error" }, "an error is never dropped for a confirmation")
            try expect(!full.pending.contains { $0.text == "info 0" }, "the oldest confirmation went")
        }

        t.register("jobs.toast", "the clock counts three seconds, pauses under the pointer and resumes with what is left") {
            var clock = ToastClock(duration: ToastTiming.confirmation)
            try expectClose(clock.start(now: 0), 3)
            clock.pause(now: 1)
            try expectClose(clock.remaining, 2); try expect(!clock.isRunning)
            clock.pause(now: 5)
            try expectClose(clock.remaining, 2, "pausing twice changes nothing")
            try expectClose(clock.start(now: 10), 2)
            clock.pause(now: 10.5)
            try expectClose(clock.remaining, 1.5)
            clock.restart(duration: 3)
            try expectClose(clock.remaining, 3)
            try expectEqual(ToastTiming.duration(ToastItem(text: "x")), 3)
            try expectEqual(ToastTiming.duration(ToastItem(text: "x", severity: .warning)), 5)
            try expectEqual(ToastTiming.duration(ToastItem(text: "x", action: ("Go", {}))), 5)
        }

        t.register("jobs.toast", "toasts show one after another, three seconds each, announced to VoiceOver, with the panel created only on the first one") {
            let kit = JobsTestKit.toastCenter()
            let c = kit.center
            try expect(!c.isShowing && kit.surface.presented.isEmpty, "nothing exists before the first toast")
            c.show("First", symbol: "doc.on.doc")
            c.show("Second")
            c.show("Third", severity: .warning)
            try expectEqual(kit.surface.presented, ["First"])
            try expectEqual(kit.surface.announced, ["First"])
            kit.scheduler.advance(by: 0.05)
            try expect(c.model.shown, "fades in right after the panel appears")
            kit.scheduler.advance(by: 2.9)
            try expectEqual(kit.surface.presented, ["First"], "still the first at 2.95 s")
            kit.scheduler.advance(by: 0.1)
            try expect(!c.model.shown, "fading out at 3 s")
            kit.scheduler.advance(by: ToastTiming.fadeOut)
            try expectEqual(kit.surface.presented, ["First", "Second"])
            kit.scheduler.advance(by: 3 + ToastTiming.fadeOut + 0.05)
            try expectEqual(kit.surface.presented, ["First", "Second", "Third"])
            try expect(kit.surface.announced.last?.hasSuffix("Third") == true && kit.surface.announced.last != "Third", "a warning is announced with its kind: \(kit.surface.announced)")
            kit.scheduler.advance(by: 5 + ToastTiming.fadeOut + 0.05)
            try expect(!c.isShowing && kit.surface.dismissCount == 1, "the panel leaves with the last toast")
            c.show("Again")
            try expectEqual(kit.surface.presented.last, "Again")
        }

        t.register("jobs.toast", "hovering pauses the countdown; leaving resumes with the time that was left; a repeat keeps it up a little longer") {
            let kit = JobsTestKit.toastCenter()
            kit.center.show("Hold")
            kit.scheduler.advance(by: 1)
            kit.center.hover(true)
            kit.scheduler.advance(by: 30)
            try expect(kit.center.model.shown && kit.center.isShowing, "nothing disappears under the pointer")
            kit.center.hover(false)
            kit.scheduler.advance(by: 1.9)
            try expect(kit.center.model.shown, "2 s were left: 1.9 s later it is still there")
            kit.scheduler.advance(by: 0.2)
            try expect(!kit.center.model.shown)
            kit.scheduler.advance(by: 1)
            try expect(!kit.center.isShowing)

            kit.center.show("Twice")
            kit.scheduler.advance(by: 2.5)
            kit.center.show("Twice")
            kit.scheduler.advance(by: 2.5)
            try expect(kit.center.model.shown, "the repeat restarted the 3 s")
            try expectEqual(kit.surface.presented.filter { $0 == "Twice" }.count, 1)
        }

        t.register("jobs.toast", "a click or the button closes a toast, the button runs its action once; Reduce Motion shortens the fade") {
            let kit = JobsTestKit.toastCenter()
            var ran = 0
            kit.center.show("Saved", action: ("Show", { ran += 1 }))
            kit.scheduler.advance(by: 0.05)
            kit.center.model.onAction?()
            try expectEqual(ran, 1)
            kit.center.model.onAction?()
            try expectEqual(ran, 1, "a second press while fading does nothing")
            kit.scheduler.advance(by: ToastTiming.fadeOut + 0.01)
            try expect(!kit.center.isShowing)

            kit.center.show("Tap")
            kit.center.model.onTap?()
            try expect(!kit.center.model.shown)
            kit.scheduler.advance(by: ToastTiming.fadeOut + 0.01)
            try expect(!kit.center.isShowing)

            let reduced = JobsTestKit.toastCenter()
            reduced.center.reduceMotion = { true }
            reduced.center.show("Quiet")
            reduced.center.model.onTap?()
            reduced.scheduler.advance(by: ToastTiming.fadeOutReduced + 0.01)
            try expect(!reduced.center.isShowing, "the 0.12 s fade is enough with Reduce Motion")
        }

        t.register("jobs.toast", "a toast's glyph and spoken text follow its severity") {
            try JobsTestKit.withLanguage(.english) {
                let info = ToastItem(text: "Path copied", symbol: "doc.on.doc")
                try expectEqual(info.effectiveSymbol, "doc.on.doc"); try expectEqual(info.spoken, "Path copied")
                let warn = ToastItem(UserMessage(severity: .warning, text: "Careful"))
                try expectEqual(warn.effectiveSymbol, StatusTone.warning.symbol); try expectEqual(warn.spoken, "Warning, Careful")
                let err = ToastItem(text: "Broken", severity: .error)
                try expectEqual(err.spoken, "Error, Broken")
            }
            try expectEqual(JobsTestKit.withLanguage(.russian) { ToastItem(text: "Сбой", severity: .error).spoken }, "Ошибка, Сбой")
        }

        t.register("jobs.toast", "floating cards are placed at the bottom centre (toast) and the top right (HUD) of the visible frame, also on a screen with a negative origin") {
            let visible = NSRect(x: -1440, y: 25, width: 1440, height: 875)
            let toast = FloatingPlacement.bottomCenter(in: visible, size: NSSize(width: 400, height: 80), inset: 48)
            try expectEqual(toast, NSPoint(x: -920, y: 73))
            let hud = FloatingPlacement.topRight(in: visible, size: NSSize(width: 376, height: 200), inset: 8)
            try expectEqual(hud, NSPoint(x: -1440 + 1440 - 376 - 8, y: 25 + 875 - 200 - 8))
        }
    }

    // MARK: Notifications

    private static func registerNotifications() {
        let t = SelfTestRegistry.shared

        t.register("jobs.notify", "categories carry 'Show in Finder' and 'Open' (Open only for a single result), both languages") {
            let cats = NotificationPolicy.categories
            let done = try unwrap(cats.first { $0.id == NotificationIDs.doneCategory })
            try expectEqual(done.actions.map(\.id), [NotificationIDs.showAction, NotificationIDs.openAction])
            try expectEqual(done.actions.map { $0.title.en }, ["Show in Finder", "Open"])
            try expect(done.actions.allSatisfy { $0.title.ru.unicodeScalars.contains { $0.value >= 0x400 } }, "Russian titles")
            let many = try unwrap(cats.first { $0.id == NotificationIDs.doneManyCategory })
            try expectEqual(many.actions.map(\.id), [NotificationIDs.showAction])
            try expect(try unwrap(cats.first { $0.id == NotificationIDs.failedCategory }).actions.isEmpty)
            try expectEqual(NotificationPolicy.categoryID(for: JobsTestKit.batch()), NotificationIDs.doneCategory)
            try expectEqual(NotificationPolicy.categoryID(for: JobsTestKit.batch(succeeded: 2, outputs: ["/a", "/b"])), NotificationIDs.doneManyCategory)
            try expectEqual(NotificationPolicy.categoryID(for: JobsTestKit.batch(succeeded: 0, failed: 2, outputs: [])), NotificationIDs.failedCategory)
        }

        t.register("jobs.notify", "the policy table: one notification per finished batch, never for unattended success, never when off, a toast when denied") {
            typealias P = NotificationPolicy
            func decide(_ b: BatchSummary, _ mode: NotificationMode = .background, active: Bool = false, hud: Bool = false, auth: NotificationAuthorization = .provisional,
                        sink: Bool = true) -> P.Delivery {
                P.decide(b, mode: mode, appIsActive: active, handledByHUD: hud, authorization: auth, sinkAvailable: sink)
            }
            let ok = JobsTestKit.batch(), bad = JobsTestKit.batch(succeeded: 0, failed: 1, outputs: [])
            try expectEqual(decide(ok), .notification)
            try expectEqual(decide(ok, active: true), .toast, "in front: the person sees the window, a toast is enough")
            try expectEqual(decide(ok, .always, active: true), .notification)
            try expectEqual(decide(ok, .off), .none)
            try expectEqual(decide(bad, .off), .none)
            try expectEqual(decide(JobsTestKit.batch(succeeded: 0, cancelled: 2, outputs: [])), .none, "cancelled work needs no news")
            try expectEqual(decide(JobsTestKit.batch(automatic: true)), .none, "unattended success is silent")
            try expectEqual(decide(JobsTestKit.batch(succeeded: 0, failed: 1, outputs: [], automatic: true)), .notification, "unattended failure is not")
            try expectEqual(decide(ok, hud: true), .none, "the quick-run card already told the story")
            try expectEqual(decide(bad, hud: true), .none)
            try expectEqual(decide(ok, .always, hud: true), .notification, "“Always” means always, even after the quick-run card")
            try expectEqual(decide(ok, auth: .denied), .toast)
            try expectEqual(decide(ok, .always, auth: .denied), .toast)
            try expectEqual(decide(ok, sink: false), .none, "no bundle, no notification")
            try expectEqual(decide(ok, auth: .notDetermined), .notification, "the permission is asked when the first one is needed")
        }

        t.register("jobs.notify", "the words: counts with Russian plurals, no file names, a failure points to the window") {
            let secret = JobsTestKit.batch(succeeded: 5, outputs: (0..<5).map { "/Users/me/Secret holiday photos/pic\($0).jpg" })
            let en = JobsTestKit.withLanguage(.english) { NotificationPolicy.copy(for: secret) }
            try expectEqual(en.title, "Done"); try expectEqual(en.body, "5 files ready")
            for n in [1: "1 файл", 2: "2 файла", 5: "5 файлов", 21: "21 файл", 11: "11 файлов"] {
                let b = JobsTestKit.batch(succeeded: n.key, outputs: (0..<n.key).map { "/o/\($0).jpg" })
                let ru = JobsTestKit.withLanguage(.russian) { NotificationPolicy.copy(for: b) }
                try expectEqual(ru.body, "Готово: \(n.value)")
            }
            let mixed = JobsTestKit.withLanguage(.english) { NotificationPolicy.copy(for: JobsTestKit.batch(succeeded: 3, failed: 2)) }
            try expectEqual(mixed.title, "Finished with errors"); try expectEqual(mixed.body, "3 done, 2 failed")
            let failed = JobsTestKit.withLanguage(.russian) { NotificationPolicy.copy(for: JobsTestKit.batch(succeeded: 0, failed: 2, outputs: [])) }
            try expectEqual(failed.title, "Не удалось завершить"); try expect(failed.body.contains("2"))
            for b in [secret, JobsTestKit.batch(succeeded: 0, failed: 1, outputs: []), JobsTestKit.batch(succeeded: 1, failed: 1)] {
                for lang in [LanguageSetting.english, .russian] {
                    let c = JobsTestKit.withLanguage(lang) { NotificationPolicy.copy(for: b) }
                    for text in [c.title, c.body] {
                        try expect(!text.contains("Secret") && !text.contains(".jpg") && !text.contains("boom"), "no file names or raw errors: \(text)")
                        try expect(!text.contains("!") && !text.contains("..."), text)
                    }
                }
            }
            let request = NotificationPolicy.request(for: secret)
            try expectEqual(request.id, secret.batchID.uuidString, "one request id per batch: a repeat replaces the banner")
            try expectEqual(request.paths.count, 5); try expect(request.passive)
            try expect(!NotificationPolicy.request(for: JobsTestKit.batch(succeeded: 0, failed: 1, outputs: [])).passive, "a failure is a normal banner")
            let many = JobsTestKit.batch(succeeded: 60, outputs: (0..<60).map { "/o/\($0).jpg" })
            try expectEqual(NotificationPolicy.request(for: many).paths.count, NotificationIDs.maxPaths)
        }

        t.register("jobs.notify", "a tap or a button maps to reveal, open, the Jobs window, or nothing") {
            let d = "default", x = "dismiss"
            func route(_ a: String, paths: Bool) -> NotificationPolicy.Route { NotificationPolicy.route(actionID: a, hasPaths: paths, defaultActionID: d, dismissActionID: x) }
            try expectEqual(route(NotificationIDs.showAction, paths: true), .reveal)
            try expectEqual(route(NotificationIDs.openAction, paths: true), .open)
            try expectEqual(route(d, paths: true), .reveal)
            try expectEqual(route(d, paths: false), .showJobs)
            try expectEqual(route(NotificationIDs.showAction, paths: false), .showJobs)
            try expectEqual(route(x, paths: true), .nothing)
            try expectEqual(route("unknown", paths: true), .nothing)
            try expectEqual(NotificationPolicy.route(actionID: UNNotificationDefaultActionIdentifier, hasPaths: true, defaultActionID: UNNotificationDefaultActionIdentifier,
                                                     dismissActionID: UNNotificationDismissActionIdentifier), .reveal)
        }

        t.register("jobs.notify", "the permission is asked once, at the first batch that needs it, never at attach; denied falls back to a toast") {
            let sink = FakeNotificationSink()
            let kit = JobsTestKit.toastCenter()
            let service = NotificationService(sink: sink, mode: { .always }, isAppActive: { false }, toasts: { kit.center })
            service.attach()   // the fake claims to be available but is not a system sink: the status is read, nothing is asked
            try await Task.sleep(nanoseconds: 50_000_000)
            try expectEqual(sink.requestCount, 0, "never at launch")
            let first = JobsTestKit.batch()
            await service.deliver(first)
            try expectEqual(sink.requestCount, 1); try expectEqual(sink.added.count, 1)
            try expectEqual(sink.added.first?.id, first.batchID.uuidString)
            try expect(!sink.categoriesSet.isEmpty && sink.categoriesSet.last == NotificationPolicy.categories, "categories are registered before posting")
            try expectEqual(service.authorization, .provisional); try expect(!service.isDenied)
            await service.deliver(JobsTestKit.batch())
            try expectEqual(sink.requestCount, 1, "asked only once"); try expectEqual(sink.added.count, 2)
            try expect(kit.surface.presented.isEmpty, "no toast while notifications work")

            let denied = FakeNotificationSink()
            denied.requestResult = .denied
            let kit2 = JobsTestKit.toastCenter()
            let s2 = NotificationService(sink: denied, mode: { .always }, isAppActive: { false }, toasts: { kit2.center })
            await s2.deliver(JobsTestKit.batch(succeeded: 3, outputs: ["/o/a.jpg", "/o/b.jpg", "/o/c.jpg"]))
            try expect(s2.isDenied, "isDenied is real")
            try expect(denied.added.isEmpty, "nothing is posted to a center that said no")
            try expectEqual(JobsTestKit.withLanguage(.english) { kit2.surface.presented.count }, 1, "the result still reaches the person")
            try expect(kit2.center.queue.current?.actionTitle != nil, "with a button")

            let fail = FakeNotificationSink()
            fail.addSucceeds = false
            fail.status = .authorized
            let kit3 = JobsTestKit.toastCenter()
            await NotificationService(sink: fail, mode: { .always }, isAppActive: { false }, toasts: { kit3.center }).deliver(JobsTestKit.batch())
            try expectEqual(kit3.surface.presented.count, 1, "a refused post becomes a toast")
        }

        t.register("jobs.notify", "post(batch:) follows the policy; without a bundle the service is inert and never throws") {
            let sink = FakeNotificationSink()
            sink.status = .authorized
            let kit = JobsTestKit.toastCenter()
            let service = NotificationService(sink: sink, mode: { .background }, isAppActive: { true }, toasts: { kit.center })
            service.post(batch: JobsTestKit.batch())
            try expectEqual(service.lastDelivery, .toast)
            try expectEqual(kit.surface.presented.count, 1)
            service.post(batch: JobsTestKit.batch(), handledByHUD: true)
            try expectEqual(service.lastDelivery, NotificationPolicy.Delivery.none)

            try expectEqual(SystemNotificationSink.map(.denied), .denied); try expectEqual(SystemNotificationSink.map(.provisional), .provisional)
            try expectEqual(SystemNotificationSink.map(.notDetermined), .notDetermined); try expectEqual(SystemNotificationSink.map(.authorized), .authorized)
        }
    }

    // MARK: HUD (and the bare-binary check)

    private static func registerHUD() {
        let t = SelfTestRegistry.shared

        t.register("jobs.notify", "without an application bundle the service is inert: no center is touched, nothing throws") {
            guard !SystemNotificationSink.isBundled else { try skipTest("running from an application bundle") }
            let bare = NotificationService()
            try expect(!bare.sink.isAvailable, "a bare binary has no notification center")
            bare.post(batch: JobsTestKit.batch())
            try expectEqual(bare.lastDelivery, NotificationPolicy.Delivery.none)
            bare.refreshStatus()
            bare.attach()
            try await Task.sleep(nanoseconds: 30_000_000)
            try expect(!bare.isDenied && bare.authorization == .unknown)
            NotificationService.shared.post(batch: JobsTestKit.batch())
            try expect(NotificationService.shared.sink is NullNotificationSink)
        }

        t.register("jobs.hud", "a successful card leaves 4 s after the job ended; failures stay; a cancelled job's card goes at once") {
            let clock = FakeScheduler()
            let hud = JobHUDController(scheduler: clock)
            hud.showsPanel = false
            let ok = JobsSamples.running(mode: .quick), bad = JobsSamples.failed(), gone = JobsSamples.running(mode: .quick)
            [ok, bad, gone].forEach { hud.add($0) }
            try expectEqual(hud.jobs.map(\.id), [gone.id, bad.id, ok.id], "newest on top")
            try expect(hud.handled(batch: ok.batchID))
            ok.finish(.done, result: OperationResult(outputs: [URL(fileURLWithPath: "/tmp/a.jpg")]))
            hud.jobEnded(ok)
            hud.jobEnded(bad)
            gone.finish(.cancelled)
            hud.jobEnded(gone)
            try expect(!hud.jobs.contains { $0.id == gone.id }, "cancelled: removed at once")
            clock.advance(by: 3.9)
            try expect(hud.jobs.contains { $0.id == ok.id })
            clock.advance(by: 0.2)
            try expect(!hud.jobs.contains { $0.id == ok.id }, "success: gone after 4 s")
            clock.advance(by: 60)
            try expect(hud.jobs.contains { $0.id == bad.id }, "a failure waits to be closed")
            hud.remove(bad)
            try expect(hud.jobs.isEmpty)
            hud.forget(batch: ok.batchID)
            try expect(!hud.handled(batch: ok.batchID))
        }

        t.register("jobs.hud", "the pointer holds a card; a retried job is not removed by the old timer; a partial success stays; at most four cards") {
            let clock = FakeScheduler()
            let hud = JobHUDController(scheduler: clock)
            hud.showsPanel = false
            let job = JobsSamples.done()
            hud.add(job)
            hud.jobEnded(job)
            hud.hover(true)
            clock.advance(by: 4.5)
            try expectEqual(hud.jobs.count, 1, "held back under the pointer")
            hud.hover(false)
            clock.advance(by: JobHUDController.afterHoverDelay + 0.1)
            try expect(hud.jobs.isEmpty, "gone shortly after the pointer left")

            let retried = JobsSamples.done()
            hud.add(retried)
            hud.jobEnded(retried)
            retried.reset(for: true)
            clock.advance(by: 5)
            try expectEqual(hud.jobs.count, 1, "the card of a job that runs again stays")
            hud.remove(retried)

            let partial = JobsSamples.withWarnings()
            hud.add(partial)
            hud.jobEnded(partial)
            clock.advance(by: 60)
            try expectEqual(hud.jobs.count, 1, "errors in a finished batch keep the card")
            hud.remove(partial)

            for i in 0..<6 { hud.add(JobsSamples.running("Job \(i)", mode: .quick)) }
            try expectEqual(hud.jobs.count, JobHUDController.maxCards)
            hud.add(hud.jobs[0])
            try expectEqual(hud.jobs.count, JobHUDController.maxCards, "the same job is never added twice")
        }
    }
}
