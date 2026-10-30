import Foundation
import AppKit
import UserNotifications

/// The system side of notifications, behind a protocol so the policy and the service are tested with a fake.
@MainActor
protocol NotificationSink: AnyObject {
    /// False when the process cannot talk to the notification center (a bare binary without a bundle: the self-test runner, the CLI).
    var isAvailable: Bool { get }
    func setCategories(_ specs: [NotificationCategorySpec])
    func authorizationStatus() async -> NotificationAuthorization
    /// Asks for permission. Provisional: delivered quietly to Notification Center, the person is not interrupted by a prompt.
    func requestAuthorization() async -> NotificationAuthorization
    func add(_ request: NotificationRequest) async -> Bool
}

/// Used when there is no bundle: every call is a harmless no-op.
@MainActor
final class NullNotificationSink: NotificationSink {
    var isAvailable: Bool { false }
    func setCategories(_ specs: [NotificationCategorySpec]) {}
    func authorizationStatus() async -> NotificationAuthorization { .unknown }
    func requestAuthorization() async -> NotificationAuthorization { .unknown }
    func add(_ request: NotificationRequest) async -> Bool { false }
}

/// `UNUserNotificationCenter`, only ever touched from a real application bundle. `UNUserNotificationCenter.current()` raises an Objective-C exception (which Swift cannot catch)
/// in a process without a bundle identifier, so the bundle is checked first; errors the center does report (an ad-hoc signed app can be refused) are caught and mean "not delivered".
@MainActor
final class SystemNotificationSink: NSObject, NotificationSink, UNUserNotificationCenterDelegate {
    /// What a tap on a banner or a button asks the app to do (set by `NotificationService`).
    var onResponse: (@MainActor (_ actionID: String, _ paths: [String]) -> Void)?

    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    var isAvailable: Bool { Self.isBundled }

    private var attached = false
    private var center: UNUserNotificationCenter? {
        guard Self.isBundled else { return nil }
        let c = UNUserNotificationCenter.current()
        if !attached { c.delegate = self; attached = true }
        return c
    }

    /// Installs the delegate (so a tap on a banner from an earlier run reaches the app). Reading the settings does not prompt.
    func attach() { _ = center }

    func setCategories(_ specs: [NotificationCategorySpec]) {
        guard let center else { return }
        let categories = specs.map { spec in
            UNNotificationCategory(identifier: spec.id,
                                   actions: spec.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title.text, options: []) },
                                   intentIdentifiers: [], options: [])
        }
        center.setNotificationCategories(Set(categories))
    }

    func authorizationStatus() async -> NotificationAuthorization {
        guard let center else { return .unknown }
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        guard let center else { return .unknown }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .provisional])
        } catch {
            return .denied   // the center refused (ad-hoc signature, no permission): the person gets toasts instead
        }
        return await authorizationStatus()
    }

    func add(_ r: NotificationRequest) async -> Bool {
        guard let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = r.body
        content.categoryIdentifier = r.categoryID
        content.threadIdentifier = r.threadID
        content.userInfo = ["paths": r.paths]
        content.sound = nil
        content.interruptionLevel = r.passive ? .passive : .active
        do {
            try await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    static func map(_ s: UNAuthorizationStatus) -> NotificationAuthorization {
        switch s {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        default: return .authorized
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A banner is shown even while the app is in front (the policy only posts then when the person asked for "always").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        await MainActor.run { self.onResponse?(action, paths) }
    }
}
