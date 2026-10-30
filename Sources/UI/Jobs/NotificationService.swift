import SwiftUI
import AppKit
import UserNotifications

/// Local notifications: ONE per batch, never at launch. The permission is asked lazily, at the first batch that needs a notification, as `.provisional` (quiet delivery to Notification
/// Center, no prompt in the person's way). If it is denied, `isDenied` drives an inline row "Open Notification Settings" in Settings > General and the result is shown as a toast instead.
/// Works only from a bundle with an identifier (bare binary: no-op, never throws). What is posted, when, and the words are in `NotificationPolicy`.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var authorization: NotificationAuthorization = .unknown
    var isDenied: Bool { authorization == .denied }

    let sink: NotificationSink
    /// What the last `post(batch:)` decided (tests and diagnostics).
    private(set) var lastDelivery: NotificationPolicy.Delivery?

    private let mode: () -> NotificationMode
    private let isAppActive: () -> Bool
    private let toasts: @MainActor () -> ToastCenter
    private var pendingAuthorization: Task<NotificationAuthorization, Never>?
    /// The latest delivery in flight (tests wait for it).
    private var lastDeliveryTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    init(sink: NotificationSink? = nil,
         mode: @escaping () -> NotificationMode = { AppSettings.shared.data.notificationMode },
         isAppActive: @escaping () -> Bool = { NSRunningApplication.current.isActive },
         toasts: @escaping @MainActor () -> ToastCenter = { ToastCenter.shared }) {
        self.sink = sink ?? (SystemNotificationSink.isBundled ? SystemNotificationSink() : NullNotificationSink())
        self.mode = mode
        self.isAppActive = isAppActive
        self.toasts = toasts
        super.init()
    }

    // MARK: Lifecycle

    /// Wires the button handler, installs the system delegate and reads the current permission (read-only, no prompt). Called once by `JobsModule.start()`; a no-op without a bundle.
    func attach() {
        guard sink.isAvailable, activeObserver == nil else { return }
        if let system = sink as? SystemNotificationSink {
            system.onResponse = { [weak self] action, paths in self?.handleResponse(actionID: action, paths: paths) }
            system.attach()
        }
        refreshStatus()
        // The person may change the permission in System Settings and come back: read it again when the app becomes active (an event, not a poll).
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        guard sink.isAvailable else { return }
        Task { @MainActor in
            let status = await sink.authorizationStatus()
            if status != authorization { authorization = status }
        }
    }

    // MARK: Posting

    /// Posts the batch summary ("5 files ready" / "Готово: 5 файлов"); category with "Show in Finder" and "Open" actions; respects `settings.notificationMode`.
    /// `handledByHUD`: the quick-run card already showed this batch, so a notification would only repeat it.
    func post(batch: BatchSummary, handledByHUD: Bool = false) {
        let delivery = NotificationPolicy.decide(batch, mode: mode(), appIsActive: isAppActive(), handledByHUD: handledByHUD,
                                                 authorization: authorization, sinkAvailable: sink.isAvailable)
        lastDelivery = delivery
        switch delivery {
        case .none: return
        case .toast: showToast(for: batch)
        case .notification: lastDeliveryTask = Task { @MainActor in await deliver(batch) }
        }
    }

    /// Waits for the delivery started by the latest `post(batch:)` (tests).
    func deliverPending() async { await lastDeliveryTask?.value }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Awaits delivery (tests).
    func deliver(_ batch: BatchSummary) async {
        let status = await ensureAuthorization()
        if status == .denied { showToast(for: batch); return }
        sink.setCategories(NotificationPolicy.categories)   // registered at each post, so the button titles follow the language
        if await sink.add(NotificationPolicy.request(for: batch)) == false { showToast(for: batch) }
    }

    /// The permission, asked at most once at a time and only when it is still open (`notDetermined`).
    private func ensureAuthorization() async -> NotificationAuthorization {
        if let task = pendingAuthorization { return await task.value }
        let task = Task { @MainActor () -> NotificationAuthorization in
            var status = self.authorization
            if status == .unknown { status = await self.sink.authorizationStatus() }
            if status == .notDetermined { status = await self.sink.requestAuthorization() }
            return status
        }
        pendingAuthorization = task
        let status = await task.value
        pendingAuthorization = nil
        authorization = status
        return status
    }

    private func showToast(for b: BatchSummary) {
        let c = NotificationPolicy.copy(for: b)
        let severity: UserMessage.Severity = b.failed == 0 ? .info : (b.succeeded == 0 ? .error : .warning)
        let urls = b.outputs
        let action: (title: String, handler: @MainActor () -> Void)? = urls.isEmpty
            ? (L("Show Jobs", "Показать задачи"), { JobsWindowController.shared.show() })
            : (L("Show in Finder", "Показать в Finder"), { ResultActions.reveal(urls) })
        toasts().show(c.title + ": " + c.body, symbol: b.failed == 0 ? "checkmark.circle" : nil, severity: severity, action: action)
    }

    // MARK: Buttons

    func handleResponse(actionID: String, paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        switch NotificationPolicy.route(actionID: actionID, hasPaths: !urls.isEmpty, defaultActionID: UNNotificationDefaultActionIdentifier,
                                        dismissActionID: UNNotificationDismissActionIdentifier) {
        case .reveal: ResultActions.reveal(urls)
        case .open: ResultActions.open(Array(urls.prefix(5)))
        case .showJobs: JobsWindowController.shared.show()
        case .nothing: break
        }
    }
}
