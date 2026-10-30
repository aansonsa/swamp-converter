import AppKit

/// The optional "sound when done" (setting `completionSound`, off by default): one short system sound per finished batch. It is silent for background (watched-folder) batches
/// and for batches the person cancelled, and a failure gets its own, lower cue. No timers: the sound is played from the batch-finished event, once.
enum CompletionSound {
    enum Cue: String, CaseIterable {
        case success = "Glass"
        case failure = "Basso"
    }

    /// Which cue a finished batch deserves (nil = none). Pure, so it is testable without a speaker.
    static func cue(for summary: BatchSummary) -> Cue? {
        if summary.automatic { return nil }
        if summary.failed > 0 { return .failure }
        if summary.succeeded > 0 { return .success }
        return nil
    }

    /// Plays a cue; replaced by the tests.
    @MainActor static var player: (Cue) -> Void = { cue in NSSound(named: NSSound.Name(cue.rawValue))?.play() }

    /// Called when a batch has finished.
    @MainActor
    static func batchFinished(_ summary: BatchSummary, enabled: Bool = AppSettings.shared.data.completionSound) {
        guard enabled, let cue = cue(for: summary) else { return }
        player(cue)
    }
}
