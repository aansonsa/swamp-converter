import SwiftUI
import AppKit

// MODULE jobs (owner: jobs engineer). Prefix for new top-level types: Jobs* / Job* (views) / Notification* / Toast* / MenuBar*.
// Files: Sources/UI/Jobs/*.
// Spec: spec/appfeatures.md 4 (jobs window, progress cards), 7.5 (notifications), 7.1 (tray / menu); spec/ux.md 2 (menu-bar item), 3 (jobs list), 5 (notifications permission), 7 (haptics, sound, motion);
//       spec/handbrake.md 6.7 (queue); spec/platform.md 8 (notifications, sharing, preview, reveal); LIFE-IMPROVER block J (result handling) of the project brief.
//
// Map of the files:
//   JobsCoordinator            the one subscriber of JobRunner / MessageCenter events; routes to the pieces below
//   MenuBarProgressModel       what the status item shows (fraction, counts, unseen-error dot, five recent results), updated at most 10 Hz (UpdateThrottle)
//   ToastCenter / ToastModel / ToastView            glass toasts: queue, 3 s, hover pauses, VoiceOver announcement, Reduce Motion = fade
//   NotificationService / NotificationPolicy / SystemNotificationSink     one notification per finished batch, permission asked lazily, toast fallback
//   JobHUDController / JobHUDCard                    the card after a quick drop
//   JobsWindowController / JobsListView / JobsListModel / JobLogView     the Jobs window
//   JobRowView / JobRowModel / JobRowObserver / JobRowParts              the shared queue row (also used by the Studio queue panel)
//
// Idle rule: this module observes `JobRunner.shared.events()` and `MessageCenter.shared.events()` (AsyncStreams) and does NOTHING while they are quiet. Progress UI updates are
// throttled to <= 10 Hz (the Job already throttles; the throttle here is a leading + trailing gate with a one-shot block, never a repeating timer). No window exists until the first
// toast, the first quick job or the first `show()`.
enum JobsModule {
    /// Subscribes to the job and message streams: batch-finished notifications (one per batch, only when not frontmost, no file names, action "Show in Finder"), toasts for `MessageCenter`,
    /// the menu-bar progress model, the HUD card for quick jobs, the Dock badge. Called by the app once launch finished. Idempotent.
    @MainActor
    static func start() { JobsCoordinator.shared.start() }

    #if !SC_SHIPPING
    @MainActor
    static func registerSnapshots() { JobsSnapshots.register() }
    #endif

    #if !SC_SHIPPING
    static func registerSelfTests() {
        JobsTests.register()
        JobsTestsModels.register()
        JobsTestsDelivery.register()
        JobsTestsSound.register()
    }
    #endif
}
