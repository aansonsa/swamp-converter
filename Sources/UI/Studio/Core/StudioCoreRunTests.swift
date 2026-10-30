import Foundation
import AppKit
import SwiftUI

// From session to engine: the recipe equals what the wheel resolves, real runs through a JobRunner are byte-identical to the quick path, queueing, per-item edits, and the views lay out.

enum StudioCoreRunTests {
    typealias T = StudioCoreTests

    @MainActor
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    static func nonOutput(_ v: OptionValues) -> OptionValues { OptionValues(v.storage.filter { !$0.key.hasPrefix("out.") }) }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("studio-core", "recipe() carries the person's edits and the probed file's defaults, and the wheel's resolution of it equals what the Studio showed") {
            let h = StudioHarness(); defer { h.cleanup() }
            let f = try h.file()
            let s = h.probedSession(files: [f], operationID: "test.studio.b")
            try expect(s.recipe().values.isEmpty == false, "the 4K file's defaults must be explicit: the runner does not probe")
            try expectEqual(s.recipe().values.string(FixtureKeys.limit), "2160")
            s.set(FixtureKeys.quality, 30); s.set(FixtureKeys.title, "Привет"); s.set(FixtureKeys.trimStart, 2.5)
            let r = s.recipe()
            try expectEqual(r.operationID, "test.studio.b"); try expect(r.presetID == nil && r.output == nil)
            try expectEqual(r.values.int(FixtureKeys.quality), 30); try expectEqual(r.values.string(FixtureKeys.title), "Привет")
            try expect(!r.values.has(FixtureKeys.container), "what the operation's quick recipe already says is not repeated")
            try expectEqual(r.values.rows(FixtureKeys.tracks).count, 2, "the file's audio rows")
            let op = try unwrap(h.registry.operation(id: "test.studio.b"))
            let wheel = QuickRecipes.resolve(op, items: [f], settings: h.settings.data, extra: [r.values], mode: .studio)
            try expectEqual(wheel.values, nonOutput(try unwrap(s.resolved).values), "wheel resolution == Studio resolution")
            // A preset's values are flattened into the recipe (the runner knows no presets), its id is kept for the Modified badge.
            h.presets.registerBuiltins([Preset.builtin("p", target: StudioFixture.schemaID, L10n("P"), [FixtureKeys.mode: "max"])])
            s.apply(preset: try unwrap(h.presets.preset(id: "builtin.p")))
            let withPreset = s.recipe()
            try expectEqual(withPreset.values.string(FixtureKeys.mode), "max"); try expectEqual(withPreset.presetID, "builtin.p")
            // No edits on an unprobed session: an empty recipe, the pure quick path.
            let plain = h.session(files: [f], target: "test.studio.b")
            try expect(plain.recipe().values.isEmpty)
            // A session opened from a recipe restores values, preset and output rules.
            var rules = OutputRules(); rules.dirMode = .subfolder
            let back = h.session(files: [f], recipe: Recipe(operationID: "test.studio.b", values: [FixtureKeys.quality: 33], presetID: "builtin.p", output: rules))
            try expectEqual(back.operationID, "test.studio.b"); try expectEqual(back.resolved?.values.int(FixtureKeys.quality), 33)
            try expectEqual(back.presetID, "builtin.p"); try expectEqual(back.resolved?.values.string(FixtureKeys.mode), "max"); try expectEqual(back.outputRules.dirMode, .subfolder)
            try expect(!back.canUndo, "opening a recipe is not an edit")
        }

        t.register("studio-core", "a Studio run is byte-identical to the quick path for equal options, and a probed file's defaults reach the engine") {
            let h = StudioHarness(); defer { h.cleanup() }
            let (f1, f2, f3, f4) = (try h.file("one.stud"), try h.file("two.stud"), try h.file("three.stud"), try h.file("four.stud"))
            let opB = h.opB
            // Equal options: the wheel's own run and the Studio's run write the same bytes.
            let quick = h.runner.submit(operation: opB, items: [f1], overrides: OptionValues(), origin: .wheel, mode: .quick)
            let plain = h.session(files: [f2], target: "test.studio.b")
            let plainJobs = plain.start()
            await h.runner.waitUntilIdle()
            try expectEqual(quick.state, .done); try expectEqual(plainJobs.count, 1); try expectEqual(plainJobs[0].state, .done)
            try expectEqual(try text(plainJobs[0].outputs[0]), try text(quick.outputs[0]), "no edits: identical bytes")
            // Edits: what the engine wrote is exactly what the wheel resolves for those overrides.
            let edited = h.session(files: [f3], target: "test.studio.b")
            edited.set(FixtureKeys.quality, 31); edited.set(FixtureKeys.title, "Привет"); edited.set(FixtureKeys.trimStart, 2.5); edited.set(FixtureKeys.fast, false)
            let jobs = edited.start()
            await h.runner.waitUntilIdle()
            let expected = FixtureConvertOp.dump(QuickRecipes.resolve(opB, items: [f3], settings: h.settings.data,
                                                                       extra: [[FixtureKeys.quality: 31, FixtureKeys.title: "Привет", FixtureKeys.trimStart: 2.5, FixtureKeys.fast: false]], mode: .quick).values)
            try expectEqual(try text(try unwrap(jobs.first?.outputs.first)), expected)
            try expect(expected.contains("\"quality\":31") && expected.contains("\"container\":\"mov\""))
            // A probed 4K file: the engine gets the resolution limit and the audio rows the person saw.
            let probed = h.probedSession(files: [f4], operationID: "test.studio.b")
            let shown = nonOutput(try unwrap(probed.resolved).values)
            let pj = probed.start()
            await h.runner.waitUntilIdle()
            let written = try text(try unwrap(pj.first?.outputs.first))
            try expectEqual(written, FixtureConvertOp.dump(shown), "what you see is what the engine receives")
            try expect(written.contains("\"size.limit\":\"2160\""))
        }

        t.register("studio-core", "Add to Queue holds one job per file (one for batch operations, one per link); nothing runs until started") {
            let h = StudioHarness(); defer { h.cleanup() }
            let files = try (1...3).map { try h.file("q\($0).stud") }
            let s = h.session(files: files, target: StudioFixture.schemaID)
            s.set(FixtureKeys.quality, 27)
            let jobs = s.addToQueue()
            try expectEqual(jobs.count, 3)
            try expect(jobs.allSatisfy { $0.held && $0.state == .waiting && $0.origin == .studio && $0.mode == .studio && $0.items.count == 1 })
            try expectEqual(Set(jobs.map(\.batchID)).count, 1, "one batch")
            try expect(jobs.allSatisfy { $0.overrides.int(FixtureKeys.quality) == 27 })
            try await Task.sleep(nanoseconds: 120_000_000)
            try expect(jobs.allSatisfy { $0.state == .waiting }, "held jobs wait for Start Queue")
            try expectEqual(h.runner.jobs.count, 3)
            // Batch operation: one job with all files.
            let merge = h.session(files: Array(files.prefix(2)), target: "test.studio.merge")
            let mj = merge.addToQueue()
            try expectEqual(mj.count, 1); try expectEqual(mj[0].items.count, 2); try expectEqual(mj[0].operationID, "test.studio.merge")
            // Links: one job per link, through the link overloads.
            let links = [LinkItem(url: URL(string: "https://example.com/watch?v=aaa111")!, title: "One"), LinkItem(url: URL(string: "https://example.com/watch?v=bbb222")!, title: "Two")]
            let ls = h.session(links: links, target: "test.studio.dl")
            let lj = ls.addToQueue()
            try expectEqual(lj.count, 2); try expect(lj.allSatisfy { $0.isLinkJob && $0.held && $0.operationID == "test.studio.dl" })
            try expectEqual(lj.map { $0.links[0].url.absoluteString }, links.map { $0.url.absoluteString })
            // Start runs now: only these jobs.
            h.runner.cancelAll(); for j in h.runner.jobs { h.runner.remove(j) }
            let one = h.session(files: [files[0]], target: StudioFixture.schemaID)
            let started = one.start()
            try expect(started.allSatisfy { !$0.held })
            await h.runner.waitUntilIdle()
            try expectEqual(started[0].state, .done)
            // Nothing can start when the options have an error.
            one.set(FixtureKeys.trimStart, 9.0); one.set(FixtureKeys.trimEnd, 3.0)
            try expect(!one.canStart && one.start().isEmpty && one.addToQueue().isEmpty)
            // The destination chosen in the Output page is applied.
            one.revertAll()
            one.set("out.dirMode", "subfolder"); one.set("out.subfolder", "Done")
            let outJob = one.start()
            await h.runner.waitUntilIdle()
            try expectEqual(outJob[0].outputRules?.dirMode, .subfolder)
            try expectEqual(try unwrap(outJob[0].outputs.first).deletingLastPathComponent().lastPathComponent, "Done")
            try expect(!outJob[0].overrides.keys.contains { $0.hasPrefix("out.") }, "the destination travels as rules, not as options")
        }

        t.register("studio-core", "a queued job loads back into a session; edits write to that job only, live, until it starts") {
            let h = StudioHarness(); defer { h.cleanup() }
            let files = try (1...3).map { try h.file("e\($0).stud") }
            let jobs = h.session(files: files, target: StudioFixture.schemaID).addToQueue()
            let editor = h.session()
            editor.load(job: jobs[1])
            try expectEqual(editor.sources.count, 1); try expectEqual(editor.sources[0].input.file?.url, files[1].url)
            try expectEqual(editor.targetID, StudioFixture.schemaID); try expectEqual(editor.operationID, "test.studio.a"); try expect(editor.editingJob === jobs[1])
            editor.set(FixtureKeys.quality, 31)
            try expectEqual(jobs[1].overrides.int(FixtureKeys.quality), 31, "live write-back")
            try expect(jobs[0].overrides.isEmpty && jobs[2].overrides.isEmpty, "other items are untouched")
            editor.set("out.dirMode", "subfolder")
            try expectEqual(jobs[1].outputRules?.dirMode, .subfolder)
            editor.revert(key: FixtureKeys.quality)
            try expect(!jobs[1].overrides.has(FixtureKeys.quality))
            editor.set(FixtureKeys.quality, 29)
            h.runner.start(jobs[1])
            await h.runner.waitUntilIdle()
            try expectEqual(jobs[1].state, .done)
            try expect(try text(try unwrap(jobs[1].outputs.first)).contains("\"quality\":29"))
            try expect(jobs[0].state == .waiting && jobs[2].state == .waiting)
            editor.set(FixtureKeys.quality, 12)
            try expect(editor.editingJobLocked, "a started job can't be changed any more")
            try expectEqual(jobs[1].overrides.int(FixtureKeys.quality), 29)
            // Loading a job restores its values as the person's layer.
            let again = h.session()
            again.load(job: jobs[2])
            try expect(again.editingJob === jobs[2] && !again.editingJobLocked && !again.canUndo)
            again.set(FixtureKeys.container, "mov")
            try expectEqual(jobs[2].overrides.string(FixtureKeys.container), "mov")
            again.undo()
            try expect(!jobs[2].overrides.has(FixtureKeys.container), "undo writes back too")
        }

        t.register("studio-core", "views lay out at inspector width in English and Russian: every field kind, the capsule, the inspector header, the track editor, the preset bar") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            s.set(FixtureKeys.quality, 45)
            let schema = try unwrap(s.schema)
            for lang in [LanguageSetting.english, .russian] {
                try T.withLanguage(lang) {
                    for f in schema.allFields {
                        let v = OptionFieldView(field: f, value: s.binding(for: f), context: s.context(for: f), onRevert: {}, onFix: { _ in })
                        let size = try fit(v, width: 340)
                        try expect(size.height >= 14 && size.height < 2000, "\(f.key) height \(size.height) (\(lang))")
                        try expect(size.width <= 340.5, "\(f.key) width \(size.width) (\(lang))")
                    }
                    for (name, view) in [("capsule", AnyView(SummaryCapsule(session: s))), ("preset bar", AnyView(PresetBar(session: s))),
                                         ("source", AnyView(SourceInspectorView(source: s.sources[0]))),
                                         ("tracks", AnyView(TrackListEditor(field: schema.field(FixtureKeys.tracks)!, spec: TrackSpec(columns: []), rows: .constant([["a": 1]]), source: nil)))] {
                        let size = try fit(view, width: 340)
                        try expect(size.height >= 10 && size.width <= 340.5, "\(name) \(size) (\(lang))")
                    }
                }
            }
        }
    }

    /// The size a view takes at `width` (ideal height).
    @MainActor
    static func fit<V: View>(_ v: V, width: CGFloat) throws -> CGSize {
        let host = NSHostingView(rootView: v.frame(width: width).environment(\.a11y, A11y()))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
