import Foundation

// Copy and Move share this flow: ask where, plan (conflicts), measure, check free space, then either finish at once (toast) or hand the finished plan to the
// Jobs window as a card with progress and Cancel (big copies). Every sentence the person can read is built in `TransferMessages`.

@MainActor
enum TransferService {
    /// The whole action: folder picker, remembered folder, then `run`.
    static func pickAndRun(mode: TransferMode, items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        let system = ActionsSystem.current
        let settings = AppSettings.shared
        let remembered = mode == .copy ? settings.data.lastCopyFolder : settings.data.lastMoveFolder
        let start = remembered.map { URL(fileURLWithPath: $0, isDirectory: true) }.flatMap { system.fs.isDirectory($0) ? $0 : nil } ?? items.first?.parent
        guard let folder = await system.chooseFolder(FolderPrompt(mode: mode, startAt: start, itemCount: items.count)) else { throw CancellationError() }
        settings.update { if mode == .copy { $0.lastCopyFolder = folder.path } else { $0.lastMoveFolder = folder.path } }
        return try await run(mode: mode, items: items, folder: folder, origin: origin)
    }

    static func run(mode: TransferMode, items: [FileItem], folder: URL, origin: JobOrigin) async throws -> ActionResult {
        let system = ActionsSystem.current
        let plan = try await TransferPlanner.plan(mode: mode, items: items, folder: folder, resolver: system.resolveConflict, fs: system.fs)
        if plan.stopped { return ActionResult(note: TransferMessages.stopped(mode)) }
        if plan.isEmpty { return ActionResult(note: TransferMessages.nothingToDo(plan)) }

        let measured = await Task.detached(priority: .userInitiated) { plan.measured() }.value
        let required = TransferSpace.requiredBytes(measured, fs: system.fs, cloneable: system.supportsCloning)
        try TransferSpace.check(required: required, available: system.availableSpace(folder), folderName: folder.lastPathComponent)

        if let threshold = system.jobThresholdBytes, measured.totalBytes >= threshold, submitJob(measured, origin: origin) {
            return ActionResult(note: TransferMessages.startedInBackground(measured))
        }
        let outcome = try await TransferRunner.runAsync(plan: measured, fs: system.fs)
        return ActionResult(note: TransferMessages.summary(measured, outcome), outputs: outcome.outputs)
    }

    /// Submits the plan as a job. False when the job operation is not registered (the caller then just runs inline).
    private static func submitJob(_ plan: TransferPlan, origin: JobOrigin) -> Bool {
        guard let op = OperationRegistry.shared.operation(id: TransferJobOperation.operationID) else { return false }
        let runner = JobRunner.shared
        let files = plan.steps.map { FileItem(url: $0.sourceURL, isDirectory: $0.isDirectory, size: $0.bytes) }
        let settings = AppSettings.shared
        let previousRecipe = settings.data.lastRecipe
        let job = runner.submit(operation: op, items: files, overrides: TransferJobOperation.overrides(for: plan), origin: origin, mode: .quick)
        job.title = TransferMessages.jobTitle(plan)
        // A copy plan is single-use: it must never become what "Repeat last" does next.
        settings.update { $0.lastRecipe = previousRecipe }
        return true
    }
}

/// The hidden operation behind the Jobs card of a big copy or move. It is registered (the runner looks operations up by id) but never offered on a wheel or in
/// the Studio: its only input is the finished plan, carried as JSON in one option so the queue can persist it.
final class TransferJobOperation: AppAction, @unchecked Sendable {
    static let operationID = "action.transfer"
    static let planKey = "transfer.plan"

    init() {
        super.init(meta: .make(Self.operationID, .actions, .app, L10n("Copy or move", "Копирование или перемещение"), symbol: "doc.on.doc",
                               schema: Self.operationID, anyFile: true, studio: true))
    }

    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: Self.operationID, title: meta.label, symbol: "doc.on.doc", pages: [
            .make("main", symbol: "doc.on.doc", meta.label, [
                .make("plan", [.text(Self.planKey, L10n("Plan", "План"), multiline: true).expert().oracle("action.transfer.plan")])
            ])
        ])
    }

    static func overrides(for plan: TransferPlan) -> OptionValues {
        var values = OptionValues()
        if let data = try? JSONEncoder().encode(plan), let text = String(data: data, encoding: .utf8) { values.set(planKey, .string(text)) }
        return values
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        guard let data = ctx.options.string(Self.planKey).data(using: .utf8), let plan = try? JSONDecoder().decode(TransferPlan.self, from: data) else {
            throw ConversionError.message(L10n("This copy can no longer be continued. Start it again.", "Это копирование нельзя продолжить. Запустите его заново."))
        }
        ctx.log("\(plan.mode.rawValue) \(plan.steps.count) item(s) to \(plan.folder)")
        let outcome = try await TransferRunner.runAsync(plan: plan) { fraction in ctx.report(fraction) }
        ctx.report(1)
        return OperationResult(outputs: outcome.outputs, note: TransferMessages.summaryNote(plan, outcome), failures: outcome.failures)
    }
}

enum TransferMessages {
    static func stopped(_ mode: TransferMode) -> L10n {
        mode == .copy ? L10n("Stopped. Nothing was copied.", "Остановлено. Ничего не скопировано.")
                      : L10n("Stopped. Nothing was moved.", "Остановлено. Ничего не перемещено.")
    }

    static func nothingToDo(_ plan: TransferPlan) -> L10n {
        let name = plan.folderURL.lastPathComponent
        if plan.skippedByChoice.isEmpty, !plan.skippedSamePath.isEmpty {
            return plan.skippedSamePath.count == 1 ? L10n("Already in “\(name)”.", "Уже в «\(name)».") : L10n("These items are already in “\(name)”.", "Эти элементы уже в «\(name)».")
        }
        return L10n("Nothing was \(plan.mode == .copy ? "copied" : "moved").", "Ничего не \(plan.mode == .copy ? "скопировано" : "перемещено").")
    }

    static func startedInBackground(_ plan: TransferPlan) -> L10n {
        let n = plan.steps.count
        let name = plan.folderURL.lastPathComponent
        return plan.mode == .copy
            ? L10n("Copying \(ActionText.items(n).en) to “\(name)”. Progress is in the Jobs window.", "Копирование в «\(name)»: \(ActionText.items(n).ru). Ход работы - в окне задач.")
            : L10n("Moving \(ActionText.items(n).en) to “\(name)”. Progress is in the Jobs window.", "Перемещение в «\(name)»: \(ActionText.items(n).ru). Ход работы - в окне задач.")
    }

    static func jobTitle(_ plan: TransferPlan) -> String {
        let name = plan.folderURL.lastPathComponent
        return plan.mode == .copy ? L("Copy to “\(name)”", "Копирование в «\(name)»") : L("Move to “\(name)”", "Перемещение в «\(name)»")
    }

    /// The toast after an inline copy or move.
    static func summary(_ plan: TransferPlan, _ outcome: TransferOutcome) -> L10n {
        var note = summaryNote(plan, outcome)
        if let first = outcome.failures.first {
            note = L10n(note.en + " " + first, note.ru + " " + first)
        }
        return note
    }

    /// "Copied to “Documents”: 3 items (1 skipped)".
    static func summaryNote(_ plan: TransferPlan, _ outcome: TransferOutcome) -> L10n {
        let n = outcome.outputs.count
        let name = plan.folderURL.lastPathComponent
        let skipped = plan.skippedSamePath.count + plan.skippedByChoice.count
        var en: String, ru: String
        switch (plan.mode, n) {
        case (.copy, 1): en = "Copied to “\(name)”"; ru = "Скопировано в «\(name)»"
        case (.copy, _): en = "Copied to “\(name)”: \(ActionText.items(n).en)"; ru = "Скопировано в «\(name)»: \(ActionText.items(n).ru)"
        case (.move, 1): en = "Moved to “\(name)”"; ru = "Перемещено в «\(name)»"
        case (.move, _): en = "Moved to “\(name)”: \(ActionText.items(n).en)"; ru = "Перемещено в «\(name)»: \(ActionText.items(n).ru)"
        }
        if skipped > 0 { en += " (\(skipped) skipped)"; ru += " (пропущено: \(skipped))" }
        return L10n(en + ".", ru + ".")
    }
}
