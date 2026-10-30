import AppKit

/// Quit handling. If jobs are active and `settings.confirmQuitWithJobs` is on, a native alert offers Wait / Cancel jobs and quit / Quit anyway (the queue is saved and comes back held).
/// A quit caused by the system (log out, restart, shut down) or by SIGTERM never asks: it must not block the Mac.
@MainActor
enum AppTermination {
    enum Choice { case wait, cancelJobsAndQuit, quitAnyway }

    /// Set by the SIGTERM handler: the quit is not interactive.
    static var systemInitiated = false
    /// Replaceable in tests: shows the alert, returns the choice. `suppress` is called when the person ticked "Do not ask again".
    static var presenter: (_ active: Int, _ suppress: () -> Void) -> Choice = { active, suppress in runAlert(active: active, suppress: suppress) }

    /// Jobs that quitting would interrupt: running, paused, and waiting jobs that are not held back.
    static func activeJobCount(_ runner: JobRunner? = nil) -> Int {
        (runner ?? .shared).jobs.filter { $0.state.isActive || ($0.state == .waiting && !$0.held) }.count
    }

    /// Pure rule (tested).
    nonisolated static func needsConfirmation(activeJobs: Int, confirmSetting: Bool, systemInitiated: Bool) -> Bool {
        activeJobs > 0 && confirmSetting && !systemInitiated
    }

    /// Quit reasons sent by the system with the quit Apple event ('why?'): log out, shut down, restart, quit all.
    nonisolated static func isSystemQuitReason(_ code: UInt32) -> Bool {
        [fourCC("logo"), fourCC("rlgo"), fourCC("shut"), fourCC("rest"), fourCC("quia")].contains(code)
    }

    nonisolated static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private static func quitReasonIsSystem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, let reason = event.attributeDescriptor(forKeyword: fourCC("why?")) else { return false }
        return isSystemQuitReason(reason.enumCodeValue)
    }

    static func shouldTerminate(_ app: NSApplication, runner: JobRunner? = nil, settings: AppSettings = .shared) -> NSApplication.TerminateReply {
        let runner = runner ?? JobRunner.shared
        let active = activeJobCount(runner)
        let system = systemInitiated || quitReasonIsSystem()
        guard needsConfirmation(activeJobs: active, confirmSetting: settings.data.confirmQuitWithJobs, systemInitiated: system) else { return .terminateNow }
        switch presenter(active, { settings.update { $0.confirmQuitWithJobs = false } }) {
        case .wait: return .terminateCancel
        case .quitAnyway: return .terminateNow
        case .cancelJobsAndQuit:
            runner.cancelAll()
            Task { @MainActor in
                // Cancelling is quick (processes are signalled at once); wait briefly so partial outputs are cleaned up, then go.
                let deadline = ContinuousClock.now + .seconds(3)
                while activeJobCount(runner) > 0 && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                app.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /// The last things before the process ends.
    static func willTerminate(runner: JobRunner? = nil) {
        (runner ?? JobRunner.shared).flushPersistence()
        AppSettings.shared.save()
        ProcessRegistry.shared.killAll()
    }

    private static func runAlert(active: Int, suppress: () -> Void) -> Choice {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Loc.plural(active, enOne: "A job is still running", enOther: "\(active) jobs are still running",
                                       ruOne: "Ещё выполняется задача", ruFew: "Ещё выполняются задачи: \(active)", ruMany: "Ещё выполняются задачи: \(active)")
        alert.informativeText = L("You can wait for it to finish, cancel the jobs and quit, or quit now. Quitting now stops running jobs; the queue is kept and waits for you next time.",
                                  "Можно дождаться завершения, отменить задачи и выйти или выйти сейчас. При выходе сейчас текущие задачи останавливаются, а очередь сохраняется и ждёт вас при следующем запуске.")
        alert.addButton(withTitle: L("Wait", "Подождать"))
        alert.addButton(withTitle: L("Cancel Jobs and Quit", "Отменить задачи и выйти"))
        alert.addButton(withTitle: L("Quit Anyway", "Всё равно выйти"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[2].keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Do not ask again", "Больше не спрашивать")
        let response = alert.runModal()
        let choice: Choice
        switch response {
        case .alertSecondButtonReturn: choice = .cancelJobsAndQuit
        case .alertThirdButtonReturn: choice = .quitAnyway
        default: choice = .wait
        }
        if alert.suppressionButton?.state == .on && choice != .wait { suppress() }
        return choice
    }
}
