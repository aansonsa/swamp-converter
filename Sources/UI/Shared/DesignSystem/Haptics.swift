import AppKit

/// The app's haptic vocabulary (spec/ux.md 7): an ALIGNMENT tick when the pointer moves onto another sector (or a sub-ring opens), a GENERIC tick when a
/// choice is committed, nothing on failure. Force Touch trackpads only (other hardware ignores the call), switched off by the "Haptics" setting, and never
/// faster than one tick every 60 ms so a quick sweep across several sectors feels like a ratchet, not a buzz.
@MainActor
enum Haptics {
    enum Kind: Sendable {
        /// The pointer snapped onto something (sector change, sub-ring opened).
        case alignment
        /// A choice was committed (drop, button press that starts work).
        case generic
        /// A value stepped across a notch (slider ticks).
        case levelChange

        var pattern: NSHapticFeedbackManager.FeedbackPattern {
            switch self {
            case .alignment: return .alignment
            case .generic: return .generic
            case .levelChange: return .levelChange
            }
        }
    }

    /// The shortest gap between two ticks.
    static let minimumInterval: TimeInterval = 0.06

    /// The pure decision (unit-tested): fire when haptics are on and the last tick is at least `minimumInterval` ago.
    static func shouldFire(now: TimeInterval, last: TimeInterval?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        return now - last >= minimumInterval
    }

    private static var lastTick: TimeInterval?

    /// Plays one tick. Returns whether it was played (false: switched off or throttled). `now` is injectable for tests.
    @discardableResult
    static func tick(_ kind: Kind = .alignment, enabled: Bool = AppSettings.shared.data.hapticsEnabled,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime, perform: Bool = true) -> Bool {
        guard shouldFire(now: now, last: lastTick, enabled: enabled) else { return false }
        lastTick = now
        if perform { NSHapticFeedbackManager.defaultPerformer.perform(kind.pattern, performanceTime: .now) }
        return true
    }

    /// Forgets the last tick (tests).
    static func reset() { lastTick = nil }
}
