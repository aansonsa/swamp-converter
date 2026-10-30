import Foundation
import AppKit

// Fakes for the jobs self-tests: a scheduler whose time the test moves, a toast surface and a notification sink that record their calls.

/// Time under the test's control. `advance(by:)` runs every block that falls due, in order (blocks may schedule more).
@MainActor
final class FakeScheduler: ToastScheduler {
    private(set) var now: TimeInterval = 0
    private var items: [(due: TimeInterval, id: Int, block: @MainActor () -> Void)] = []
    private var nextID = 0
    private(set) var scheduledCount = 0

    var pendingCount: Int { items.count }

    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> () -> Void {
        let id = nextID
        nextID += 1
        scheduledCount += 1
        items.append((now + seconds, id, block))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            items.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.block()
        }
        now = target
    }
}

@MainActor
final class FakeToastSurface: ToastSurface {
    var onHover: ((Bool) -> Void)?
    private(set) var presented: [String] = []
    private(set) var announced: [String] = []
    private(set) var dismissCount = 0
    private(set) var refitCount = 0

    func present(model: ToastModel) { presented.append(model.item?.text ?? "") }
    func refit() { refitCount += 1 }
    func dismiss() { dismissCount += 1 }
    func announce(_ text: String) { announced.append(text) }
}

@MainActor
final class FakeNotificationSink: NotificationSink {
    var isAvailable = true
    var status: NotificationAuthorization = .notDetermined
    var requestResult: NotificationAuthorization = .provisional
    var addSucceeds = true
    private(set) var requestCount = 0
    private(set) var added: [NotificationRequest] = []
    private(set) var categoriesSet: [[NotificationCategorySpec]] = []

    func setCategories(_ specs: [NotificationCategorySpec]) { categoriesSet.append(specs) }
    func authorizationStatus() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> NotificationAuthorization {
        requestCount += 1
        status = requestResult
        return requestResult
    }
    func add(_ request: NotificationRequest) async -> Bool {
        added.append(request)
        return addSucceeds
    }
}

@MainActor
enum JobsTestKit {
    /// Runs `body` with the UI language forced, and puts the setting back.
    static func withLanguage<T>(_ setting: LanguageSetting, _ body: () throws -> T) rethrows -> T {
        let old = Loc.shared.setting
        Loc.shared.set(setting)
        defer { Loc.shared.set(old) }
        return try body()
    }

    static func batch(succeeded: Int = 1, failed: Int = 0, cancelled: Int = 0, outputs: [String] = ["/tmp/out/a.jpg"], automatic: Bool = false, id: UUID = UUID()) -> BatchSummary {
        BatchSummary(batchID: id, total: succeeded + failed + cancelled, succeeded: succeeded, failed: failed, cancelled: cancelled, outputs: outputs.map { URL(fileURLWithPath: $0) },
                     firstTitle: "Secret holiday photos", firstError: failed > 0 ? "boom" : nil, finishAction: .nothing, automatic: automatic)
    }

    /// A toast center that records instead of drawing.
    static func toastCenter() -> (center: ToastCenter, scheduler: FakeScheduler, surface: FakeToastSurface) {
        let scheduler = FakeScheduler()
        let surface = FakeToastSurface()
        let center = ToastCenter(scheduler: scheduler, surface: { surface })
        center.reduceMotion = { false }
        return (center, scheduler, surface)
    }
}
