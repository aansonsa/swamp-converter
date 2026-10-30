import Foundation
import CoreGraphics

// The drag gesture's state machines as tables (spec/wheel.md 19.7, 20): tap recogniser, shake recogniser, drag session, settings mapping. Pure: no clocks, no system calls.

extension WheelTests {
    private static let keys: [ModifierKey: WheelKind] = [.shift: .convert, .control: .tools, .option: .actions]

    static func registerGestures() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "tap recogniser: a lone modifier fires once, on release; chords, other keys, unmapped keys and a held key never fire") {
            typealias Step = (flags: [ModifierKey], expect: WheelKind?)
            let tables: [(name: String, steps: [Step])] = [
                ("shift tap", [([], nil), ([.shift], nil), ([], .convert)]),
                ("control tap", [([], nil), ([.control], nil), ([], .tools)]),
                ("option tap", [([], nil), ([.option], nil), ([], .actions)]),
                ("held for a long time still fires once on release", [([], nil), ([.shift], nil), ([.shift], nil), ([.shift], nil), ([], .convert), ([], nil)]),
                ("chord of two modifiers cancels", [([], nil), ([.shift], nil), ([.shift, .control], nil), ([.shift], nil), ([], nil)]),
                ("swapping one modifier for another cancels", [([], nil), ([.shift], nil), ([.control], nil), ([], nil)]),
                ("command maps to no wheel", [([], nil), ([.command], nil), ([], nil)]),
                ("already held when the drag began: ignored until released", [([.shift], nil), ([.shift], nil), ([], nil), ([.shift], nil), ([], .convert)]),
                ("two taps fire twice", [([], nil), ([.shift], nil), ([], .convert), ([.control], nil), ([], .tools)])
            ]
            for table in tables {
                var r = DragWatcher.TapRecognizer(wheelKeys: keys)
                for (i, step) in table.steps.enumerated() {
                    try expectEqual(r.feed(flags: step.flags), step.expect, "\(table.name), step \(i)")
                }
            }
            var off = DragWatcher.TapRecognizer(wheelKeys: [.control: .tools])
            _ = off.feed(flags: [])
            _ = off.feed(flags: [.shift])
            try expectEqual(off.feed(flags: []), nil, "a key that is off maps to nothing")
            var reset = DragWatcher.TapRecognizer(wheelKeys: keys)
            _ = reset.feed(flags: [.shift]); reset.reset()
            _ = reset.feed(flags: []); _ = reset.feed(flags: [.shift])
            try expectEqual(reset.feed(flags: []), .convert, "reset forgets the history")
        }
        t.register("wheel", "shake recogniser: reversals within the window fire, a straight drag or slow wobble never does, then a cooldown") {
            func run(_ sensitivity: Double, _ points: [(Double, Double, Double)]) -> Int {
                var s = DragWatcher.ShakeRecognizer(sensitivity: sensitivity)
                var fired = 0
                for (t, x, y) in points where s.feed(point: CGPoint(x: x, y: y), time: t) { fired += 1 }
                return fired
            }
            // Left-right shaking: 160 pt travel every 0.08 s.
            var shake: [(Double, Double, Double)] = []
            for i in 0..<14 { shake.append((Double(i) * 0.08, i % 2 == 0 ? 100 : 260, 300)) }
            try expect(run(0.5, shake) >= 1, "a vigorous shake fires at the default sensitivity")
            var straight: [(Double, Double, Double)] = []
            for i in 0..<40 { straight.append((Double(i) * 0.016, 100 + Double(i) * 12, 300)) }
            try expectEqual(run(0.5, straight), 0, "a straight drag never fires")
            var slow: [(Double, Double, Double)] = []
            for i in 0..<14 { slow.append((Double(i) * 0.8, i % 2 == 0 ? 100 : 260, 300)) }
            try expectEqual(run(0.5, slow), 0, "reversals spread over many seconds do not count")
            var small: [(Double, Double, Double)] = []
            for i in 0..<30 { small.append((Double(i) * 0.03, i % 2 == 0 ? 100 : 112, 300)) }
            try expectEqual(run(0.5, small), 0, "a 12 pt jitter is not a shake")
            var long: [(Double, Double, Double)] = []
            for i in 0..<60 { long.append((Double(i) * 0.08, i % 2 == 0 ? 100 : 260, 300)) }
            let fired = run(0.5, long)
            try expect(fired >= 1 && fired <= 5, "the cooldown stops one wave from firing at every reversal (fired \(fired))")
            let easy = DragWatcher.ShakeRecognizer(sensitivity: 1), hard = DragWatcher.ShakeRecognizer(sensitivity: 0)
            try expect(easy.requiredReversals < hard.requiredReversals && easy.minimumTravel < hard.minimumTravel, "sensitivity trades reversals and travel")
        }
        t.register("wheel", "drag session: a click, a window drag or stale pasteboard content never opens anything; a real file drag does; release and Esc end it") {
            func sample(_ t: Double, down: Bool = true, x: Double = 0, cc: Int = 5, payload: Bool = true, mods: [ModifierKey] = [], esc: Bool = false) -> DragSample {
                DragSample(time: t, leftDown: down, location: CGPoint(x: x, y: 0), pasteboardChangeCount: cc, hasPayload: payload, modifiers: mods, escapeDown: esc)
            }
            var s = DragSession()
            try expectEqual(s.phase, .idle)
            try expectEqual(s.feed(sample(0)), [], "idle ignores samples")

            s.mouseDown(at: .zero, changeCount: 5, time: 0)
            try expectEqual(s.phase, .armed)
            try expectEqual(s.feed(sample(0.05, x: 40, cc: 5)), [], "moved, but the drag pasteboard did not change: a window or text drag")
            try expectEqual(s.feed(sample(0.1, x: 80, cc: 6, payload: false)), [], "new pasteboard content without files, images or links")
            try expectEqual(s.feed(sample(0.12, x: 3, cc: 6, payload: true)), [], "files but the pointer has not moved 8 pt")
            try expectEqual(s.feed(sample(0.2, x: 60, cc: 6, payload: true, mods: [.shift])), [.dragBegan], "Shift was already down when the drag began")
            try expectEqual(s.phase, .dragging)
            try expectEqual(s.feed(sample(0.25, x: 62, cc: 6, mods: [.shift])), [], "a modifier held before the drag began never taps")
            try expectEqual(s.feed(sample(0.3, x: 64, cc: 6, mods: [])), [])
            try expectEqual(s.feed(sample(0.35, x: 66, cc: 6, mods: [.control])), [])
            try expectEqual(s.feed(sample(0.4, x: 68, cc: 6, mods: [])), [.modifierTap(.tools)], "Control tapped = the Tools wheel")
            try expectEqual(s.feed(sample(0.45, x: 70, cc: 6, esc: true)), [.escape])
            try expectEqual(s.feed(sample(0.5, x: 70, cc: 6, esc: true)), [], "Esc fires once")
            try expectEqual(s.feed(sample(0.6, down: false, x: 70, cc: 6)), [.dragEnded]); try expectEqual(s.phase, .idle)

            var click = DragSession()
            click.mouseDown(at: .zero, changeCount: 5, time: 0)
            try expectEqual(click.feed(sample(0.05, down: false)), [], "a plain click ends quietly"); try expectEqual(click.phase, .idle)
            var stuck = DragSession()
            stuck.mouseDown(at: .zero, changeCount: 5, time: 0)
            try expectEqual(stuck.feed(sample(DragSession.armedTimeout + 1)), []); try expectEqual(stuck.phase, .idle, "a held button without a drag session stops sampling")
            try expectEqual(stuck.suggestedInterval, 0, "idle needs no timer")
            var armed = DragSession(); armed.mouseDown(at: .zero, changeCount: 1, time: 0)
            try expectClose(armed.suggestedInterval, 1.0 / 20, tolerance: 1e-9)
            _ = armed.feed(sample(0.2, x: 90, cc: 2))
            try expectClose(armed.suggestedInterval, 1.0 / 60, tolerance: 1e-9, "a real drag samples at display rate")
            var stalled = DragSession(); stalled.mouseDown(at: .zero, changeCount: 1, time: 0)
            _ = stalled.feed(sample(0.2, x: 90, cc: 2))
            try expectEqual(stalled.feed(sample(0.3 + DragSession.stallTimeout, x: 90, cc: 2)), [.dragEnded], "a missed release is caught by the watchdog")
        }
        t.register("wheel", "drag session: shake and tap can be switched off, and the settings map to one wheel per key") {
            var quiet = DragSession(configuration: .init(modifierTap: false, shake: false, shakeSensitivity: 0.5, wheelKeys: keys))
            quiet.mouseDown(at: .zero, changeCount: 1, time: 0)
            _ = quiet.feed(DragSample(time: 0.1, leftDown: true, location: CGPoint(x: 50, y: 0), pasteboardChangeCount: 2, hasPayload: true, modifiers: [], escapeDown: false))
            _ = quiet.feed(DragSample(time: 0.2, leftDown: true, location: CGPoint(x: 50, y: 0), pasteboardChangeCount: 2, hasPayload: true, modifiers: [.shift], escapeDown: false))
            try expectEqual(quiet.feed(DragSample(time: 0.3, leftDown: true, location: CGPoint(x: 50, y: 0), pasteboardChangeCount: 2, hasPayload: true, modifiers: [], escapeDown: false)), [])

            var s = SettingsData()
            var c = DragWatcher.configuration(from: s)
            try expectEqual(c.wheelKeys[.shift], .convert); try expectEqual(c.wheelKeys[.control], .tools); try expectEqual(c.wheelKeys[.option], .actions)
            s.actionsKey = .shift                                                                 // two wheels on one key: the first wheel wins
            c = DragWatcher.configuration(from: s)
            try expectEqual(c.wheelKeys[.shift], .convert); try expectEqual(c.wheelKeys.count, 2)
            s.convertKey = .none
            c = DragWatcher.configuration(from: s)
            try expectEqual(c.wheelKeys[.shift], .actions, "with Convert off the next wheel takes the key")
            s.gestures.shake = false; s.gestures.shakeSensitivity = 0.9
            c = DragWatcher.configuration(from: s)
            try expect(!c.shake && c.shakeSensitivity == 0.9 && c.modifierTap)
        }
    }
}
