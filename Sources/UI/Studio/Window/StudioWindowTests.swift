import Foundation

enum StudioWindowTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("studio-window", "the controller starts with no windows") {
            try expectEqual(StudioWindowController.shared.openSessionCount, 0)
        }
        t.register("studio-window", "Start runs the work in front: new files beat a held queue, the queue starts only when there is nothing else to start") {
            Loc.shared.set(.english); defer { Loc.shared.set(.system) }
            // The owner's "Studio works every other time": Start used to run the old held queue and leave the newly added files alone.
            let newWorkAndOldQueue = StudioCommandContext(hasSources: true, sessionCanStart: true, heldQueueCount: 3)
            try expect(!StudioCommands.startRunsQueue(newWorkAndOldQueue), "new files start, the held queue waits for its own button")
            try expectEqual(StudioCommands.startTitle(newWorkAndOldQueue).en, "Start")
            let onlyQueue = StudioCommandContext(hasSources: false, sessionCanStart: false, heldQueueCount: 2)
            try expect(StudioCommands.startRunsQueue(onlyQueue)); try expectEqual(StudioCommands.startTitle(onlyQueue).en, "Start Queue")
            try expect(!StudioCommands.startRunsQueue(StudioCommandContext()), "nothing held, nothing to start: no queue run")
        }
        // STUDIO-WINDOW OWNER: window lifecycle (reuse, drop adds sources), toolbar command availability, queue panel against a fake JobRunner, preview divider maths, frame / state restoration,
        // snapshots of the full window (empty, video with preview, image before / after, queue with 3 states, audio, PDF, subtitles, spreadsheet, archive, download target) in en / ru,
        // light / dark, Reduce Transparency, Increase Contrast; Russian long labels never truncate badly.
    }
}
