import Foundation

/// Leading + trailing throttle as a pure state machine: the first request fires at once, requests that follow inside `minInterval` collapse into ONE trailing fire at the
/// end of the interval. At most `1 / minInterval` fires per second (10 Hz for the progress UI) and nothing is armed while nobody asks (no timer, no polling).
/// The clock is injected, so the rule is tested without waiting.
struct UpdateThrottle: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Run the update now.
        case now
        /// Run it once, `after` seconds from now (the caller schedules ONE one-shot block).
        case later(after: TimeInterval)
        /// A trailing fire is already scheduled; the request is folded into it.
        case alreadyScheduled
    }

    var minInterval: TimeInterval
    private(set) var lastFire: TimeInterval?
    private(set) var trailingScheduled = false

    init(minInterval: TimeInterval = 0.1) { self.minInterval = minInterval }

    mutating func request(now: TimeInterval) -> Decision {
        if trailingScheduled { return .alreadyScheduled }
        guard let last = lastFire, now - last < minInterval else {
            lastFire = now
            return .now
        }
        trailingScheduled = true
        return .later(after: max(0, last + minInterval - now))
    }

    /// The scheduled trailing block ran.
    mutating func trailingFired(now: TimeInterval) {
        trailingScheduled = false
        lastFire = now
    }
}

/// `UpdateThrottle` wired to an action and a one-shot scheduler (`DispatchQueue.main.asyncAfter` unless a test injects its own).
@MainActor
final class ThrottledAction {
    typealias Scheduler = (_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Void

    private var throttle: UpdateThrottle
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private let action: @MainActor () -> Void

    var isPending: Bool { throttle.trailingScheduled }

    init(interval: TimeInterval = 0.1, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: Scheduler? = nil, action: @escaping @MainActor () -> Void) {
        throttle = UpdateThrottle(minInterval: interval)
        self.now = now
        self.schedule = schedule ?? ThrottledAction.mainQueue
        self.action = action
    }

    static let mainQueue: Scheduler = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { block() } }
    }

    func request() {
        switch throttle.request(now: now()) {
        case .now: action()
        case .later(let delay): schedule(delay) { [weak self] in self?.fireTrailing() }
        case .alreadyScheduled: break
        }
    }

    private func fireTrailing() {
        throttle.trailingFired(now: now())
        action()
    }
}
