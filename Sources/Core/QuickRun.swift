import Foundation
import Combine

// The QUICK path in one place. The wheel, Services, the Dock / menu-bar drop, the hotkey, "Repeat last" and chains
// all start work through `QuickRun.shared.run(...)`: it checks applicability and availability, resolves the quick recipe,
// asks the few fields named in `OperationMeta.quickPromptKeys` (trim start/end) through a UI hook, runs app actions in-process, and otherwise
// submits a job. The Studio path ends in the same JobRunner.submit; nothing else may start conversions.

/// A one-line message for the user that is not tied to a job card ("Path copied", "Nothing selected").
struct UserMessage: Identifiable, Sendable {
    enum Severity: String, Sendable { case info, warning, error }
    var id = UUID()
    var severity: Severity = .info
    var text: String
    var symbol: String? = nil
    var date = Date()
}

/// Fan-out of `UserMessage`s. The Jobs module shows them as toasts / notifications; tests read `recent`.
@MainActor
final class MessageCenter {
    static let shared = MessageCenter()
    private(set) var recent: [UserMessage] = []
    private var subscribers: [UUID: AsyncStream<UserMessage>.Continuation] = [:]

    func post(_ text: String, severity: UserMessage.Severity = .info, symbol: String? = nil) {
        let m = UserMessage(severity: severity, text: text, symbol: symbol)
        recent.append(m)
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
        subscribers.values.forEach { $0.yield(m) }
    }

    func events() -> AsyncStream<UserMessage> {
        let token = UUID()
        return AsyncStream(UserMessage.self, bufferingPolicy: .bufferingNewest(50)) { cont in
            subscribers[token] = cont
            cont.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[token] = nil } }
        }
    }
}

struct ActionResult: Sendable {
    /// Shown as a quiet toast ("Path copied").
    var note: L10n? = nil
    var outputs: [URL] = []
}

/// Operations of the Actions wheel (copy, move, reveal, share, shelf...). They run inside the app on the main actor,
/// show no progress card and are never offered to watched folders. Subclass and override `perform`.
class AppAction: OperationBase, @unchecked Sendable {
    override init(meta: OperationMeta) {
        var m = meta
        m.isAppAction = true
        m.wheel = .actions
        m.acceptsAnyFile = true
        m.acceptsDirectories = true
        super.init(meta: m)
    }

    /// Implement: do the action. Throw `ConversionError.message` with a calm sentence on failure.
    @MainActor
    func perform(items: [FileItem], origin: JobOrigin) async throws -> ActionResult {
        throw ConversionError.unsupported(L10n("This action is not implemented yet.", "Это действие ещё не реализовано."))
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        let r = try await perform(items: items, origin: .other)
        return OperationResult(outputs: r.outputs, note: r.note)
    }
}

@MainActor
final class QuickRun {
    static let shared = QuickRun()

    /// Asks the user for the `quickPromptKeys` fields before a quick run. Installed by the Settings module
    /// (`SettingsModule.installParameterSheet()`); returns nil when the user cancels. Without a hook defaults are used.
    typealias ParameterPrompt = @MainActor (_ operation: Operation, _ items: [FileItem], _ fields: [OptionField], _ current: OptionValues) async -> OptionValues?
    var parameterPrompt: ParameterPrompt?

    // Injectable for tests.
    var registry: OperationRegistry = .shared
    var runnerProvider: @MainActor () -> JobRunner = { JobRunner.shared }
    var settings: AppSettings = .shared
    var tools: ToolLocator = .shared

    enum Outcome {
        case started(Job)
        case performedAction(ActionResult)
        case cancelled
        /// Shown to the user already (toast); carries the reason.
        case unavailable(L10n)
        case notApplicable
        case failed(String)
    }

    /// Runs `op` on `items` with its quick recipe plus `overrides`. `mode` stays `.quick` for gestures and `.automatic`
    /// for watched folders and chains (no dialogs, nothing remembered).
    @discardableResult
    func run(_ op: Operation, items: [FileItem], origin: JobOrigin, mode: RunMode = .quick, overrides: OptionValues = OptionValues(),
             outputRules: OutputRules? = nil, batchID: UUID = UUID()) async -> Outcome {
        guard op.appliesTo(items) || op.appliesInStudio(items) else { return .notApplicable }
        let availability = op.availability(for: items, tools: tools)
        if case .unavailable(let reason, _) = availability {
            if mode != .automatic { MessageCenter.shared.post(reason.text, severity: .warning, symbol: "exclamationmark.triangle") }
            return .unavailable(reason)
        }

        if let action = op as? AppAction {
            do {
                let r = try await action.perform(items: items, origin: origin)
                if let n = r.note { MessageCenter.shared.post(n.text, symbol: op.meta.symbol) }
                return .performedAction(r)
            } catch is CancellationError {
                return .cancelled
            } catch {
                let msg = ConversionError.describe(error)
                MessageCenter.shared.post(msg, severity: .error, symbol: "exclamationmark.octagon")
                return .failed(msg)
            }
        }

        var ov = overrides
        if mode == .quick {
            let keys = op.meta.quickPromptKeys
            let fields = keys.isEmpty ? [] : op.optionSchema(for: items).allFields.filter { keys.contains($0.key) && !ov.has($0.key) }
            if !fields.isEmpty, let prompt = parameterPrompt {
                let current = QuickRecipes.resolve(op, items: items, settings: settings.data, extra: [ov]).values
                guard let answers = await prompt(op, items, fields, current) else { return .cancelled }
                ov = answers.merged(over: ov)
            }
        }
        let job = runnerProvider().submit(operation: op, items: items, overrides: ov, origin: origin, mode: mode, outputRules: outputRules, batchID: batchID)
        return .started(job)
    }

    @discardableResult
    func run(operationID: String, items: [FileItem], origin: JobOrigin, mode: RunMode = .quick, overrides: OptionValues = OptionValues()) async -> Outcome {
        guard let op = registry.operation(id: operationID) else { return .failed(L("The action no longer exists.", "Действие больше не существует.")) }
        return await run(op, items: items, origin: origin, mode: mode, overrides: overrides)
    }

    /// Runs a LINK operation (a download mode) on `links`. The downloader's `DownloadService.start(url:mode:)` is the usual entry point;
    /// this one exists for the wheel, which only knows operations. Availability (consent, yt-dlp present) is checked like for files.
    @discardableResult
    func run(_ op: Operation, links: [LinkItem], origin: JobOrigin, mode: RunMode = .quick, overrides: OptionValues = OptionValues(),
             batchID: UUID = UUID()) async -> Outcome {
        guard op.meta.acceptsLinks, op.appliesToLinks(links) else { return .notApplicable }
        if case .unavailable(let reason, _) = op.availability(for: [], tools: tools) {
            if mode != .automatic { MessageCenter.shared.post(reason.text, severity: .warning, symbol: "exclamationmark.triangle") }
            return .unavailable(reason)
        }
        let job = runnerProvider().submit(operation: op, links: links, overrides: overrides, origin: origin, mode: mode, batchID: batchID)
        return .started(job)
    }

    /// Re-runs the last recipe (with its stored parameters, no dialog) when it still applies.
    @discardableResult
    func repeatLast(items: [FileItem], origin: JobOrigin) async -> Outcome {
        guard let r = settings.data.lastRecipe, let op = registry.operation(id: r.operationID), op.appliesTo(items) else { return .notApplicable }
        return await run(op, items: items, origin: origin, overrides: r.values)
    }

    /// The operation "Repeat last" would run for `items`, for the wheel's repeat view (nil = nothing to repeat).
    func lastOperation(for items: [FileItem]) -> Operation? {
        guard let r = settings.data.lastRecipe, let op = registry.operation(id: r.operationID), op.appliesTo(items) else { return nil }
        return op
    }
}
