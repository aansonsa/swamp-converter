import Foundation
import AppKit
import SwiftUI

// Self-tests of the studio-core module (suite "studio-core"). Three files:
//   StudioCoreTests          this file: registration + helpers + the renderer logic (fields, conditions, gating, search, density, tracks, formatting)
//   StudioCoreSessionTests   StudioSession flows: targets, values, undo, messages, presets, derived work, inputs
//   StudioCoreRunTests       recipe equals the quick path, byte-identical runs, queueing, per-item edits, views lay out

enum StudioCoreTests {
    static func register() {
        registerRenderer()
        StudioCoreSessionTests.register()
        StudioCoreRunTests.register()
    }

    // MARK: Helpers

    /// Polls `condition` every 10 ms until it holds (the work under test is event-driven, so this only bridges to the assertion).
    @MainActor
    static func waitUntil(timeout: TimeInterval = 4, _ what: String = "condition", file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { throw TestFailure(message: "timed out waiting for \(what)", file: "\(file)", line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    static func withLanguage<T>(_ lang: LanguageSetting, _ body: () throws -> T) rethrows -> T {
        let old = Loc.shared.setting
        Loc.shared.set(lang)
        defer { Loc.shared.set(old) }
        return try body()
    }

    static func env(_ values: OptionValues, source: SourceInfo? = nil) -> ExprEnvironment { ExprEnvironment(values: values, source: source) }

    // MARK: Renderer logic

    private static func registerRenderer() {
        let t = SelfTestRegistry.shared

        t.register("studio-core", "the fixture schema holds every FieldKind, unique keys and an oracle id on every field") {
            let schema = StudioFixture.schema()
            let kinds = Set(schema.allFields.map { StudioFixture.kindName($0.kind) })
            try expectEqual(kinds, StudioFixture.allKindNames, "every FieldKind must appear")
            let keys = schema.allFields.map(\.key)
            try expectEqual(Set(keys).count, keys.count, "keys are unique")
            try expect(schema.allFields.allSatisfy { !$0.oracle.isEmpty }, "every field needs an oracle")
        }

        t.register("studio-core", "defaults are shown: nothing is marked changed and the resolved values equal the schema defaults") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            let schema = try unwrap(s.schema)
            let defaults = schema.defaults(source: s.activeSource?.info)
            for f in schema.allFields where f.key != FixtureKeys.gated {
                try expect(s.isDefault(f.key), "\(f.key) should be default")
                try expect(s.context(for: f).isDefault, "\(f.key) context")
                try expect(OptionValues([f.key: s.resolved!.values[f.key]!]).diff(against: OptionValues([f.key: defaults[f.key]!])).isEmpty, "\(f.key) equals its default")
            }
            try expect(!s.isModified); try expect(s.changes.isEmpty)
        }

        t.register("studio-core", "conditions enable and disable fields, and a disabled field carries its reason") {
            let schema = StudioFixture.schema()
            let bitrate = try unwrap(schema.field(FixtureKeys.bitrate)), fast = try unwrap(schema.field(FixtureKeys.fast))
            let cq = OptionValues([FixtureKeys.rc: "cq", FixtureKeys.container: "mp4"])
            let st = OptionFormLogic.state(of: bitrate, group: nil, page: nil, env: env(cq))
            try expect(!st.enabled && st.visible); try expect(st.reason == bitrate.disabledReason, "uses the schema's reason")
            try expect(OptionFormLogic.state(of: bitrate, group: nil, page: nil, env: env(OptionValues([FixtureKeys.rc: "abr"]))).enabled)
            let mkv = OptionFormLogic.state(of: fast, group: nil, page: nil, env: env(OptionValues([FixtureKeys.container: "mkv"])))
            try expect(!mkv.visible, "visibleWhen hides the streaming toggle for MKV")
            let locked = OptionFormLogic.state(of: bitrate, group: nil, page: nil, env: env(OptionValues([FixtureKeys.rc: "abr"])), lockedKeys: [FixtureKeys.bitrate], lockedBy: L10n("Web"))
            try expect(!locked.enabled && locked.isLocked && locked.reason != nil)
            let generic = OptionFormLogic.state(of: OptionField.toggle("x", L10n("x")).enabled(.never), group: nil, page: nil, env: env(OptionValues()))
            try expect(generic.reason == OptionFormLogic.conditionReason, "a condition without a reason gets the generic one")
        }

        t.register("studio-core", "capability gaps disable controls with the calm reason: a field, one picker option, and a whole page") {
            let schema = StudioFixture.schema()
            let gated = try unwrap(schema.field(FixtureKeys.gated))
            let st = OptionFormLogic.state(of: gated, group: nil, page: nil, env: env(OptionValues()))
            try expect(!st.enabled && st.isCapabilityGap); try expect(st.reason == gated.disabledReason)
            guard case .picker(let opts) = try unwrap(schema.field(FixtureKeys.container)).kind else { throw TestFailure(message: "not a picker", file: #fileID, line: #line) }
            let mkv = try unwrap(opts.first { $0.value == "mkv" })
            let av = OptionFormLogic.availability(of: mkv, env: nil)
            try expect(!av.enabled); try expect(av.hint?.en.isEmpty == false, "a hint explains the gap")
            try expect(OptionFormLogic.availability(of: opts[0], env: nil).enabled)
            let page = try unwrap(schema.pages.first { $0.id == "needs" })
            let pst = OptionFormLogic.state(of: page.groups[0].fields[0], group: page.groups[0], page: page, env: env(OptionValues()))
            try expect(!pst.enabled && pst.isCapabilityGap && pst.reason != nil)
            // The resolver never keeps a gated choice.
            let r = schema.resolve(layers: [[FixtureKeys.container: "mkv", FixtureKeys.gated: true]])
            try expectEqual(r.values.string(FixtureKeys.container), "mp4"); try expectEqual(r.values.bool(FixtureKeys.gated), false)
        }

        t.register("studio-core", "search finds label, help, key and aliases in BOTH languages and flags expert hits") {
            let schema = StudioFixture.schema()
            let e = env(schema.defaults())
            func keys(_ q: String, density: DensitySetting = .advanced, expert: Bool = false) -> [String] {
                OptionFormLogic.search(schema, query: q, env: e, density: density, showExpert: expert).sections.flatMap { $0.fields.map(\.key) }
            }
            try expect(keys("bitrate").contains(FixtureKeys.bitrate), "EN label / alias")
            try expect(keys("битрейт").contains(FixtureKeys.bitrate), "RU alias")
            try expect(keys("BITRATE").contains(FixtureKeys.maxrate), "case-insensitive, finds the peak bitrate too")
            try expect(keys("crf").contains(FixtureKeys.quality), "alias")
            try expect(keys("качество").contains(FixtureKeys.quality), "RU label")
            try expect(keys("index at the start").contains(FixtureKeys.fast), "help text")
            try expect(keys("индекс").contains(FixtureKeys.fast), "RU help text")
            try expect(keys("video.crf").isEmpty, "unknown key text finds nothing")
            try expect(keys("trim.start").contains(FixtureKeys.trimStart), "the key itself")
            let x = OptionFormLogic.search(schema, query: "x264", env: e, density: .simple, showExpert: false)
            try expect(x.hitCount == 1 && x.includesExpert, "an expert hit is found even in Simple and is flagged")
            try expect(!OptionFormLogic.search(schema, query: "x264", env: e, density: .advanced, showExpert: true).includesExpert, "nothing to flag when expert is shown")
            // A field hidden by its own condition does not appear.
            let mkvEnv = env(OptionValues([FixtureKeys.container: "mkv"]))
            try expect(!OptionFormLogic.search(schema, query: "streaming", env: mkvEnv, density: .advanced, showExpert: false).sections.flatMap { $0.fields.map(\.key) }.contains(FixtureKeys.fast))
            try expectEqual(OptionFormLogic.search(schema, query: "   ", env: e, density: .simple, showExpert: false).hitCount, 0)
        }

        t.register("studio-core", "density: Simple shows basic fields only, caps a group at six, collapses groups after the first two; Advanced adds standard; expert needs its switch") {
            let schema = StudioFixture.schema()
            let e = env(schema.defaults())
            let main = try unwrap(schema.pages.first { $0.id == "main" })
            let simple = OptionFormLogic.layout(page: main, density: .simple, showExpert: false, env: e)
            let simpleKeys = simple.groups.flatMap { $0.fields.map(\.key) }
            try expect(simpleKeys.contains(FixtureKeys.quality) && simpleKeys.contains(FixtureKeys.container))
            try expect(!simpleKeys.contains(FixtureKeys.bitrate) && !simpleKeys.contains(FixtureKeys.refs), "standard and expert hidden in Simple")
            try expect(simple.advancedHidden > 0 && simple.expertHidden > 0)
            let adv = OptionFormLogic.layout(page: main, density: .advanced, showExpert: false, env: e)
            let advKeys = adv.groups.flatMap { $0.fields.map(\.key) }
            try expect(advKeys.contains(FixtureKeys.bitrate) && !advKeys.contains(FixtureKeys.refs), "Advanced adds standard, expert stays behind the switch")
            try expectEqual(adv.expertHidden, 2, "refs and the multiline comment")
            let exp = OptionFormLogic.layout(page: main, density: .advanced, showExpert: true, env: e)
            try expect(exp.groups.flatMap { $0.fields.map(\.key) }.contains(FixtureKeys.refs) && exp.expertHidden == 0)
            // The group with more than six fields.
            let extra = try unwrap(schema.pages.first { $0.id == "extra" })
            let ex = OptionFormLogic.layout(page: extra, density: .simple, showExpert: false, env: e)
            let many = try unwrap(ex.groups.first { $0.group.id == "many" })
            try expectEqual(many.fields.count, OptionFormLogic.simpleFieldCap); try expectEqual(many.overflow, 2)
            try expect(!many.collapsedByDefault || many.group.title != nil)
            let opened = OptionFormLogic.layout(page: extra, density: .simple, showExpert: false, env: e, expandedOverflow: ["many"])
            try expectEqual(opened.groups.first { $0.group.id == "many" }?.fields.count, 8)
            // Groups beyond the first two start collapsed in Simple (the third visible one), not in Advanced.
            let collapsed = ex.groups.map(\.collapsedByDefault)
            try expectEqual(collapsed, [false, false, true], "first two open, third collapsed")
            try expect(!OptionFormLogic.layout(page: extra, density: .advanced, showExpert: false, env: e).groups.contains { $0.collapsedByDefault })
            // The metadata group is declared collapsed.
            try expect(adv.groups.first { $0.group.id == "meta" }?.collapsedByDefault == true)
            // The expert-only group is invisible until the switch.
            try expect(!ex.groups.contains { $0.group.id == "expert" })
            try expect(OptionFormLogic.layout(page: extra, density: .advanced, showExpert: true, env: e).groups.contains { $0.group.id == "expert" })
        }

        t.register("studio-core", "tracks: rows are filled from probed streams, can be removed and reordered, and respect the maximum") {
            let schema = StudioFixture.schema()
            let field = try unwrap(schema.field(FixtureKeys.tracks))
            guard case .tracks(let spec) = field.kind else { throw TestFailure(message: "not tracks", file: #fileID, line: #line) }
            let info = StudioFixture.sourceInfo(for: URL(fileURLWithPath: "/tmp/x.stud"))
            try expectEqual(TrackRows.streamKind(forFieldKey: field.key), .audio)
            var rows: [TrackRows.Row] = []
            var addable = TrackRows.addableStreams(field: field, spec: spec, rows: rows, source: info)
            try expectEqual(addable.map(\.index), [1, 2], "audio streams only")
            let first = TrackRows.row(from: addable[0], spec: spec, source: info)
            try expectEqual(first["source"], .int(1)); try expectEqual(first["lang"], .string("en")); try expectEqual(first["title"], .string("English")); try expectEqual(first["codec"], .string("aac"))
            rows.append(first)
            addable = TrackRows.addableStreams(field: field, spec: spec, rows: rows, source: info)
            try expectEqual(addable.map(\.index), [2], "a stream already added is not offered again")
            rows.append(TrackRows.row(from: addable[0], spec: spec, source: info))
            rows.append(TrackRows.emptyRow(spec, source: info))
            try expectEqual(rows.count, 3)
            let moved = TrackRows.moved(rows, from: 2, to: 0)
            try expectEqual(moved[0], rows[2]); try expectEqual(moved[1], rows[0])
            try expectEqual(TrackRows.moved(rows, from: 0, to: 9), rows, "out of range does nothing")
            let removed = TrackRows.removed(rows, at: 1)
            try expectEqual(removed.count, 2); try expectEqual(removed[1], rows[2])
            try expect(TrackRows.canAdd(rows, spec: spec)); rows.append(TrackRows.emptyRow(spec, source: nil))
            try expect(!TrackRows.canAdd(rows, spec: spec), "maxRows is 4")
            let sum = TrackRows.summary(of: first, spec: spec, index: 0)
            try expectEqual(sum.title, "English"); try expect(sum.detail.contains("AAC"))
            // Through the resolver: rows keep every column, new rows get defaults.
            let r = schema.resolve(layers: [[FixtureKeys.tracks: .rows([["source": 1]])]])
            try expectEqual(r.values.rows(FixtureKeys.tracks).first?["codec"], .string("aac"))
            // The default rows come from the probed source.
            try expectEqual(schema.defaults(source: info).rows(FixtureKeys.tracks).count, 2, "one default row per audio stream")
        }

        t.register("studio-core", "slider mapping: log scale round-trips, values snap to the step, the stored type follows the schema, VoiceOver gets value + unit + direction") {
            let schema = StudioFixture.schema()
            guard case .slider(let log) = try unwrap(schema.field(FixtureKeys.bitrate)).kind, case .slider(let lin) = try unwrap(schema.field(FixtureKeys.quality)).kind else {
                throw TestFailure(message: "sliders expected", file: #fileID, line: #line)
            }
            for v in [100.0, 450, 4000, 20000] {
                let p = OptionSlider.position(of: v, spec: log)
                try expect(p >= 0 && p <= 1)
                try expectClose(OptionSlider.value(atPosition: p, spec: log), v, tolerance: 50, "log round trip \(v)")
            }
            try expect(OptionSlider.position(of: 1000, spec: log) > 0.3 && OptionSlider.position(of: 1000, spec: log) < 0.6, "a log slider spends more track on small values")
            try expectClose(OptionSlider.position(of: 25.5, spec: lin), 0.5)
            try expectEqual(OptionSlider.snap(22.4, spec: lin), 22); try expectEqual(OptionSlider.snap(99, spec: lin), 51); try expectEqual(OptionSlider.snap(-4, spec: lin), 0)
            try expectEqual(OptionSlider.stored(22, spec: lin), .int(22))
            var coarse = lin; coarse.min = 0; coarse.max = 100; coarse.step = 5
            try expectEqual(OptionSlider.nudged(snapped: 40, raw: 41, current: 40, dragging: false, spec: coarse), 45, "an arrow key moves one step even when 1% is less than half a step")
            try expectEqual(OptionSlider.nudged(snapped: 40, raw: 39, current: 40, dragging: false, spec: coarse), 35)
            try expectEqual(OptionSlider.nudged(snapped: 40, raw: 41, current: 40, dragging: true, spec: coarse), 40, "a slow drag keeps plain snapping")
            try expectEqual(OptionSlider.nudged(snapped: 45, raw: 44, current: 40, dragging: false, spec: coarse), 45)
            var fractional = lin; fractional.decimals = 1; fractional.step = 0.5
            try expectEqual(OptionSlider.stored(22.5, spec: fractional), .double(22.5)); try expectEqual(OptionSlider.snap(22.3, spec: fractional), 22.5)
            let spoken = withLanguage(.english) { OptionSlider.spoken(value: 22, spec: lin, fallbackUnit: nil) }
            try expectEqual(spoken, "22 CRF")
            let dir = withLanguage(.english) { OptionSlider.direction(spec: lin) }
            try expectEqual(dir, "Left: Smaller file. Right: Better quality.")
            let ru = withLanguage(.russian) { OptionSlider.direction(spec: lin) }
            try expect(ru?.contains("Меньше файл") == true && ru?.contains("Лучше качество") == true)
        }

        t.register("studio-core", "time, number and colour text: parse and format round-trip, both decimal separators, bad input is rejected") {
            try expectEqual(OptionFormat.timeString(90.5), "0:01:30.500"); try expectEqual(OptionFormat.timeString(3723.007), "1:02:03.007")
            try expectEqual(Util.parseTime(OptionFormat.timeString(3723.007)), 3723.007)
            try expectEqual(OptionFormat.timeText(.double(61)), "0:01:01.000"); try expectEqual(OptionFormat.timeText(.string("")), ""); try expectEqual(OptionFormat.timeText(.string("1:30")), "0:01:30.000")
            try expect(Util.parseTime("1:2:3:4") == nil && Util.parseTime("abc") == nil && Util.parseTime("-5") == nil)
            try expectEqual(OptionFormat.parseNumber("1,5"), 1.5); try expectEqual(OptionFormat.parseNumber(" 1.5 "), 1.5); try expect(OptionFormat.parseNumber("1.2.3") == nil && OptionFormat.parseNumber("") == nil)
            try withLanguage(.russian) { try expectEqual(OptionFormat.number(1.5, decimals: 2), "1,5") }
            try withLanguage(.english) { try expectEqual(OptionFormat.number(1.5, decimals: 2), "1.5"); try expectEqual(OptionFormat.number(22, decimals: 0), "22") }
            let c = try unwrap(OptionFormat.rgb(fromHex: "#FF72D9"))
            try expectEqual(c.r, 255); try expectEqual(c.g, 114); try expectEqual(c.b, 217)
            try expectEqual(OptionFormat.hex(r: c.r, g: c.g, b: c.b), "#FF72D9")
            try expect(OptionFormat.rgb(fromHex: "FF72D9") == nil && OptionFormat.rgb(fromHex: "#FFF") == nil && OptionFormat.rgb(fromHex: "#GG72D9") == nil)
            try expectEqual(OptionFormat.hex(r: 300, g: -4, b: 0), "#FF0000", "clamped")
        }

        t.register("studio-core", "values read as people read them: option labels, on / off, units, times, rows, secrets masked") {
            let schema = StudioFixture.schema()
            try withLanguage(.english) {
                func d(_ key: String, _ v: OptionValue?) -> String { OptionFormat.display(v, for: schema.field(key)!) }
                try expectEqual(d(FixtureKeys.container, "mov"), "MOV"); try expectEqual(d(FixtureKeys.mode, "best"), "Best for Apple")
                try expectEqual(d(FixtureKeys.fast, true), "on"); try expectEqual(d(FixtureKeys.quality, .int(22)), "22 CRF")
                try expectEqual(d(FixtureKeys.trimStart, .string("")), "not set"); try expectEqual(d(FixtureKeys.trimStart, .double(5)), "0:00:05.000")
                try expectEqual(d(FixtureKeys.password, "secret"), "\u{2022}\u{2022}\u{2022}\u{2022}"); try expectEqual(d(FixtureKeys.tracks, .rows([["title": "English"], [:]])), "English, Track 2")
                try expectEqual(d(FixtureKeys.maxrate, .int(1500)), "1500 kbit/s"); try expectEqual(d(FixtureKeys.refs, .int(3)), "3")
            }
            try withLanguage(.russian) { try expectEqual(OptionFormat.display(true, for: schema.field(FixtureKeys.fast)!), "вкл.") }
        }

        t.register("studio-core", "summary wording: size, saving, time and problem counts in English and Russian with correct plurals") {
            let e = OperationEstimate(bytes: 412_000_000, seconds: 360, confidence: .rough)
            try withLanguage(.english) {
                let line = try unwrap(SummaryText.estimateLine(e, sourceBytes: 1_300_000_000))
                try expect(line.hasPrefix("About 412") && line.contains("68% smaller") && line.contains("about 6 min"), line)
                try expect(try unwrap(SummaryText.estimateLine(OperationEstimate(bytes: 2_000_000), sourceBytes: 1_000_000)).contains("100% larger"))
                try expect(try unwrap(SummaryText.estimateLine(OperationEstimate(bytes: 1_000_000), sourceBytes: 1_000_000)).contains("about the same"))
                try expect(try unwrap(SummaryText.estimateLine(OperationEstimate(bytes: 5_000_000, confidence: .measured), sourceBytes: nil)).hasPrefix("Measured"))
                try expect(SummaryText.estimateLine(nil, sourceBytes: 1) == nil && SummaryText.estimateLine(OperationEstimate(), sourceBytes: 1) == nil)
                try expectEqual(SummaryText.problemsTitle(errors: 1, warnings: 0), "1 error"); try expectEqual(SummaryText.problemsTitle(errors: 0, warnings: 3), "3 warnings")
                try expectEqual(SummaryText.problemsTitle(errors: 2, warnings: 1), "2 errors, 1 warning")
            }
            try withLanguage(.russian) {
                let line = try unwrap(SummaryText.estimateLine(e, sourceBytes: 1_300_000_000))
                try expect(line.hasPrefix("Около") && line.contains("на 68 % меньше") && line.contains("около 6 мин"), line)
                try expectEqual(SummaryText.problemsTitle(errors: 0, warnings: 1), "1 предупреждение"); try expectEqual(SummaryText.problemsTitle(errors: 0, warnings: 2), "2 предупреждения")
                try expectEqual(SummaryText.problemsTitle(errors: 5, warnings: 0), "5 ошибок"); try expectEqual(SummaryText.problemsTitle(errors: 21, warnings: 0), "21 ошибка")
            }
        }
    }
}
