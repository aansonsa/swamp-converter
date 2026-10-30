import Foundation

// The decisions and the words of batch notifications, without any UserNotifications types: pure, so the tests cover every row of the policy table.

enum NotificationAuthorization: Equatable, Sendable {
    /// Not asked yet (or not readable, e.g. a bare binary).
    case unknown
    case notDetermined
    case denied
    case authorized
    /// Delivered quietly to Notification Center, no prompt shown.
    case provisional

    var allowsDelivery: Bool { self == .authorized || self == .provisional || self == .notDetermined || self == .unknown }
}

struct NotificationActionSpec: Equatable {
    var id: String
    var title: L10n
}

struct NotificationCategorySpec: Equatable {
    var id: String
    var actions: [NotificationActionSpec]
}

/// What the system is asked to show.
struct NotificationRequest: Equatable {
    var id: String
    var title: String
    var body: String
    var categoryID: String
    var threadID: String
    /// Result paths for the buttons (never displayed; capped).
    var paths: [String]
    /// Success is passive (Notification Center, no banner interruption); a failure is a normal banner.
    var passive: Bool
}

enum NotificationIDs {
    static let showAction = "swp.action.show"
    static let openAction = "swp.action.open"
    static let doneCategory = "swp.category.done"
    static let doneManyCategory = "swp.category.doneMany"
    static let failedCategory = "swp.category.failed"
    static let thread = "swp.batch"
    static let maxPaths = 20
}

enum NotificationPolicy {
    /// Everything a batch notification can turn into.
    enum Delivery: Equatable {
        /// Say nothing.
        case none
        /// A system notification.
        case notification
        /// The app's own toast (notifications are denied, or the app is in front and the person sees the window).
        case toast
    }

    /// The categories registered with the system. "Open" only for a single result: opening fifty files at once is never what a click means.
    static var categories: [NotificationCategorySpec] {
        let show = NotificationActionSpec(id: NotificationIDs.showAction, title: L10n("Show in Finder", "Показать в Finder"))
        let open = NotificationActionSpec(id: NotificationIDs.openAction, title: L10n("Open", "Открыть"))
        return [NotificationCategorySpec(id: NotificationIDs.doneCategory, actions: [show, open]),
                NotificationCategorySpec(id: NotificationIDs.doneManyCategory, actions: [show]),
                NotificationCategorySpec(id: NotificationIDs.failedCategory, actions: [])]
    }

    static func categoryID(for b: BatchSummary) -> String {
        if b.succeeded == 0 { return NotificationIDs.failedCategory }
        return b.outputs.count == 1 ? NotificationIDs.doneCategory : NotificationIDs.doneManyCategory
    }

    /// The policy table.
    ///   * nothing finished (all cancelled) -> none
    ///   * mode off -> none
    ///   * unattended (watched folder, chain) -> only when something failed
    ///   * the quick-run card already told the story (`handledByHUD`) -> none, unless the person chose "Always" (the card goes away after a few seconds)
    ///   * the system cannot deliver (bare binary, no bundle) -> none
    ///   * denied -> toast (so the result is never silent)
    ///   * `.background`: system notification only while the app is not in front; in front, a toast
    ///   * `.always`: system notification
    static func decide(_ b: BatchSummary, mode: NotificationMode, appIsActive: Bool, handledByHUD: Bool, authorization: NotificationAuthorization,
                       sinkAvailable: Bool) -> Delivery {
        if b.succeeded == 0 && b.failed == 0 { return .none }
        if mode == .off { return .none }
        if b.automatic && b.failed == 0 { return .none }
        if handledByHUD && mode != .always { return .none }
        guard sinkAvailable else { return .none }
        if authorization == .denied { return .toast }
        switch mode {
        case .background: return appIsActive ? .toast : .notification
        case .always: return .notification
        case .off: return .none
        }
    }

    /// Title and body. No file names anywhere (a banner can be read over a shoulder or on a lock screen).
    static func copy(for b: BatchSummary) -> (title: String, body: String) {
        let done = max(b.outputs.count, b.succeeded)
        if b.failed == 0 {
            return (L("Done", "Готово"), L("\(Loc.files(done)) ready", "Готово: \(Loc.files(done))"))
        }
        if b.succeeded == 0 {
            return (L("Could not finish", "Не удалось завершить"),
                    L("\(b.failed) failed. Open Swamp Converter for details.", "Не удалось: \(b.failed). Подробности в окне задач."))
        }
        return (L("Finished with errors", "Завершено с ошибками"),
                L("\(b.succeeded) done, \(b.failed) failed", "Готово: \(b.succeeded), с ошибкой: \(b.failed)"))
    }

    static func request(for b: BatchSummary) -> NotificationRequest {
        let c = copy(for: b)
        return NotificationRequest(id: b.batchID.uuidString, title: c.title, body: c.body, categoryID: categoryID(for: b), threadID: NotificationIDs.thread,
                                   paths: b.outputs.prefix(NotificationIDs.maxPaths).map(\.path), passive: b.failed == 0)
    }

    // MARK: Button handling

    enum Route: Equatable { case reveal, open, showJobs, nothing }

    /// What a click on the banner or one of its buttons does. `defaultActionID` / `dismissActionID` are the system's identifiers for a tap and a swipe-away.
    static func route(actionID: String, hasPaths: Bool, defaultActionID: String, dismissActionID: String) -> Route {
        switch actionID {
        case NotificationIDs.showAction: return hasPaths ? .reveal : .showJobs
        case NotificationIDs.openAction: return hasPaths ? .open : .showJobs
        case defaultActionID: return hasPaths ? .reveal : .showJobs
        case dismissActionID: return .nothing
        default: return .nothing
        }
    }
}
