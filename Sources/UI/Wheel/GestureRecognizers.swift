import Foundation
import CoreGraphics

// Pure recognisers behind the drag gesture (table-tested in WheelTestsGestures): no AppKit, no clocks, no globals. The watcher samples the system
// (mouse button, cursor, modifier flags, drag pasteboard) and feeds the samples in; everything the wheel reacts to comes out as `DragWatcher.Event`s.

extension DragWatcher {
    /// Pure tap recogniser (table-tested): feed modifier snapshots, get the tapped wheel once on release. Stricter than the original: any chord or second modifier
    /// cancels (a letter key cannot be seen without Accessibility).
    ///
    /// Rules:
    ///  * a tap is `none -> exactly one modifier -> none`; it fires on RELEASE (no minimum or maximum duration);
    ///  * a second modifier at any moment (Shift + Command, Shift then Control) cancels it, as does swapping one for another without letting go;
    ///  * a modifier that was already held when the recogniser first saw the keyboard (the drag began with Option down, for the Finder "copy" meaning)
    ///    never fires; the keyboard must first be released;
    ///  * a modifier that maps to no wheel (Command, or one set to "off") never fires;
    ///  * after firing, holding the key down again does not re-fire.
    struct TapRecognizer: Sendable {
        var wheelKeys: [ModifierKey: WheelKind]
        private var seeded = false
        private var candidate: ModifierKey?
        private var tainted = false

        init(wheelKeys: [ModifierKey: WheelKind]) { self.wheelKeys = wheelKeys }

        /// The modifiers the recogniser looks at (the `none` case never appears in a snapshot).
        static let watched: [ModifierKey] = [.shift, .control, .option, .command]

        mutating func feed(flags: [ModifierKey]) -> WheelKind? {
            let down = Set(flags.filter { $0 != .none })
            if !seeded {
                seeded = true
                tainted = !down.isEmpty           // something was already held: wait for a clean keyboard
                candidate = nil
                return nil
            }
            if down.isEmpty {
                defer { candidate = nil; tainted = false }
                guard let key = candidate, !tainted else { return nil }
                return wheelKeys[key]
            }
            if down.count > 1 { tainted = true; return nil }
            let only = down.first!
            if candidate == nil && !tainted { candidate = only; return nil }
            if let c = candidate, c != only { tainted = true }
            return nil
        }

        /// Forget the history (a new drag begins).
        mutating func reset() { seeded = false; candidate = nil; tainted = false }
    }

    /// Pure shake recogniser: feed cursor positions with timestamps, returns true when direction reversals within the window exceed the sensitivity.
    ///
    /// A reversal is counted when the cursor travels back at least `minimumTravel` points against the direction it was going, on either axis. Five
    /// reversals of at least 47 pt within 0.8 s at the default sensitivity (0.5: 4.5 rounds up) fire; sensitivity 1 needs three short reversals, sensitivity 0 needs six long ones.
    /// After a shake the recogniser stays quiet for a second so one wave does not open the wheel twice.
    struct ShakeRecognizer: Sendable {
        var sensitivity: Double
        static let window: TimeInterval = 0.8
        static let cooldown: TimeInterval = 1.0

        private struct Axis: Sendable {
            var direction: CGFloat = 0
            var extreme: CGFloat = 0
            var times: [TimeInterval] = []
            mutating func reset(at value: CGFloat) { direction = 0; extreme = value; times.removeAll(keepingCapacity: true) }
        }
        private var x = Axis()
        private var y = Axis()
        private var started = false
        private var quietUntil: TimeInterval = 0

        init(sensitivity: Double) {
            self.sensitivity = sensitivity
            x.times.reserveCapacity(12); y.times.reserveCapacity(12)
        }

        /// Reversals needed and the travel that counts as a reversal, for a sensitivity in 0...1.
        var requiredReversals: Int { Int((6 - 3 * min(max(sensitivity, 0), 1)).rounded()) }
        var minimumTravel: CGFloat { CGFloat(70 - 46 * min(max(sensitivity, 0), 1)) }

        mutating func feed(point: CGPoint, time: TimeInterval) -> Bool {
            if !started { started = true; x.reset(at: point.x); y.reset(at: point.y); return false }
            if time < quietUntil { x.reset(at: point.x); y.reset(at: point.y); return false }
            let need = requiredReversals, travel = minimumTravel
            let fired = Self.step(&x, value: point.x, time: time, need: need, travel: travel) || Self.step(&y, value: point.y, time: time, need: need, travel: travel)
            if fired { quietUntil = time + Self.cooldown; x.reset(at: point.x); y.reset(at: point.y) }
            return fired
        }

        mutating func reset() { started = false; quietUntil = 0; x.reset(at: 0); y.reset(at: 0) }

        private static func step(_ a: inout Axis, value: CGFloat, time: TimeInterval, need: Int, travel: CGFloat) -> Bool {
            if a.direction == 0 {
                if abs(value - a.extreme) >= 2 { a.direction = value > a.extreme ? 1 : -1; a.extreme = value }
                return false
            }
            if (value - a.extreme) * a.direction > 0 {
                a.extreme = value                                   // still going the same way: the extreme moves on
            } else if abs(value - a.extreme) >= travel {
                a.direction = -a.direction                           // came back far enough: a reversal
                a.extreme = value
                a.times.append(time)
                if a.times.count > 12 { a.times.removeFirst(a.times.count - 12) }
            }
            while let first = a.times.first, time - first > window { a.times.removeFirst() }
            return a.times.count >= need
        }
    }
}

// MARK: - The drag session state machine

/// One poll of the system while a button is (or just was) down.
struct DragSample: Equatable, Sendable {
    var time: TimeInterval
    var leftDown: Bool
    var location: CGPoint
    /// `NSPasteboard(name: .drag).changeCount`.
    var pasteboardChangeCount: Int
    /// Does the drag pasteboard (at this change count) hold files, promises, an image or a link?
    var hasPayload: Bool
    var modifiers: [ModifierKey]
    var escapeDown: Bool
}

/// What turns raw samples into wheel events (spec/wheel.md 20.1, platform.md 6.2). Pure and table-tested; `DragWatcher` owns the clock and the system calls.
///
///     idle --mouseDown--> armed --(moved > 8 pt AND pasteboard changed AND it holds a payload)--> dragging --button up--> idle
///
/// A plain click, a window drag, a rubber-band selection and a text drag never reach `dragging`: the drag pasteboard does not change for them (it is never
/// cleared, so stale content is always present; only the change count against the value at mouse-down proves a NEW drag session started).
struct DragSession: Sendable {
    struct Configuration: Equatable, Sendable {
        var modifierTap = true
        var shake = true
        var shakeSensitivity = 0.5
        var wheelKeys: [ModifierKey: WheelKind] = [.shift: .convert, .control: .tools, .option: .actions]
    }

    enum Phase: Equatable, Sendable { case idle, armed, dragging }

    private(set) var phase: Phase = .idle
    var configuration: Configuration
    private var changeCountAtDown = 0
    private var originAtDown = CGPoint.zero
    private var armedAt: TimeInterval = 0
    private var lastMovement: TimeInterval = 0
    private var lastLocation = CGPoint.zero
    private var escWasDown = false
    private var tap: DragWatcher.TapRecognizer
    private var shake: DragWatcher.ShakeRecognizer

    /// Drag distance that separates a click from a drag (twice the system drag metric of 4 pt).
    static let dragThreshold: CGFloat = 8
    /// A button held for this long without a drag session is not one (window move, text selection): stop sampling.
    static let armedTimeout: TimeInterval = 20
    /// A drag with no cursor movement at all for this long is treated as abandoned (guards against a missed release).
    static let stallTimeout: TimeInterval = 60

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        tap = DragWatcher.TapRecognizer(wheelKeys: configuration.wheelKeys)
        shake = DragWatcher.ShakeRecognizer(sensitivity: configuration.shakeSensitivity)
    }

    /// The left button went down at `location` with the drag pasteboard at `changeCount`.
    mutating func mouseDown(at location: CGPoint, changeCount: Int, time: TimeInterval) {
        phase = .armed
        changeCountAtDown = changeCount
        originAtDown = location
        armedAt = time; lastMovement = time; lastLocation = location
        escWasDown = false
    }

    /// Back to idle without events (the watcher stopped, the wheel was paused).
    mutating func cancel() { phase = .idle }

    /// How often the watcher should sample in this phase (seconds): relaxed while only waiting to see whether a drag session begins, display-rate once it has.
    var suggestedInterval: TimeInterval {
        switch phase {
        case .idle: return 0
        case .armed: return 1.0 / 20
        case .dragging: return 1.0 / 60
        }
    }

    mutating func feed(_ s: DragSample) -> [DragWatcher.Event] {
        switch phase {
        case .idle:
            return []
        case .armed:
            if !s.leftDown { phase = .idle; return [] }
            if s.time - armedAt > Self.armedTimeout { phase = .idle; return [] }
            let moved = hypot(s.location.x - originAtDown.x, s.location.y - originAtDown.y)
            guard moved > Self.dragThreshold, s.pasteboardChangeCount != changeCountAtDown, s.hasPayload else { return [] }
            phase = .dragging
            lastMovement = s.time; lastLocation = s.location
            escWasDown = s.escapeDown
            tap = DragWatcher.TapRecognizer(wheelKeys: configuration.wheelKeys)
            _ = tap.feed(flags: s.modifiers)                // seeds the recogniser with what is already held
            shake = DragWatcher.ShakeRecognizer(sensitivity: configuration.shakeSensitivity)
            _ = shake.feed(point: s.location, time: s.time)
            return [.dragBegan]
        case .dragging:
            if !s.leftDown { phase = .idle; return [.dragEnded] }
            if s.location != lastLocation { lastMovement = s.time; lastLocation = s.location }
            if s.time - lastMovement > Self.stallTimeout { phase = .idle; return [.dragEnded] }
            var events: [DragWatcher.Event] = []
            if s.escapeDown && !escWasDown { events.append(.escape) }
            escWasDown = s.escapeDown
            if configuration.modifierTap, let wheel = tap.feed(flags: s.modifiers) { events.append(.modifierTap(wheel)) }
            if configuration.shake, shake.feed(point: s.location, time: s.time) { events.append(.shake) }
            return events
        }
    }
}
