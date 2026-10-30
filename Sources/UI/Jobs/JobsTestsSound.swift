import Foundation
import AppKit

// Self-tests of the optional completion sound.

enum JobsTestsSound {
    private static func summary(succeeded: Int = 0, failed: Int = 0, cancelled: Int = 0, automatic: Bool = false) -> BatchSummary {
        BatchSummary(batchID: UUID(), total: succeeded + failed + cancelled, succeeded: succeeded, failed: failed, cancelled: cancelled, outputs: [],
                     firstTitle: "Convert", firstError: nil, finishAction: .nothing, automatic: automatic)
    }

    static func register() {
        let t = SelfTestRegistry.shared
        t.register("jobs.sound", "the cue: success for a clean batch, the lower one when something failed, none for cancelled or background batches") {
            try expectEqual(CompletionSound.cue(for: summary(succeeded: 3)), .success)
            try expectEqual(CompletionSound.cue(for: summary(succeeded: 2, failed: 1)), .failure)
            try expectEqual(CompletionSound.cue(for: summary(failed: 1)), .failure)
            try expect(CompletionSound.cue(for: summary(cancelled: 2)) == nil, "a cancelled batch is silent")
            try expect(CompletionSound.cue(for: summary(succeeded: 5, automatic: true)) == nil, "a watched-folder batch is silent")
            for cue in CompletionSound.Cue.allCases { try expect(NSSound(named: NSSound.Name(cue.rawValue)) != nil, "the system sound \(cue.rawValue) exists") }
        }
        t.register("jobs.sound", "the sound plays once per batch, and only when the setting is on") {
            var played: [CompletionSound.Cue] = []
            let saved = CompletionSound.player
            CompletionSound.player = { played.append($0) }
            defer { CompletionSound.player = saved }
            CompletionSound.batchFinished(summary(succeeded: 1), enabled: false)
            try expect(played.isEmpty, "off by default")
            CompletionSound.batchFinished(summary(succeeded: 1), enabled: true)
            CompletionSound.batchFinished(summary(failed: 1), enabled: true)
            CompletionSound.batchFinished(summary(cancelled: 1), enabled: true)
            try expectEqual(played, [.success, .failure])
            try expect(!AppSettings.shared.data.completionSound, "the setting is off unless the person turned it on")
        }
    }
}
