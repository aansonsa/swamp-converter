import SwiftUI

/// One toast. Equality is by id (the action closure is not comparable).
struct ToastItem: Identifiable {
    let id: UUID
    var text: String
    var symbol: String?
    var severity: UserMessage.Severity
    var actionTitle: String?
    var handler: (@MainActor () -> Void)?

    init(text: String, symbol: String? = nil, severity: UserMessage.Severity = .info, action: (title: String, handler: @MainActor () -> Void)? = nil) {
        self.id = UUID(); self.text = text; self.symbol = symbol; self.severity = severity
        self.actionTitle = action?.title; self.handler = action?.handler
    }

    init(_ message: UserMessage) { self.init(text: message.text, symbol: message.symbol, severity: message.severity) }

    var tone: StatusTone { StatusTone(severity) }
    /// The glyph: the sender's own symbol, else the tone's.
    var effectiveSymbol: String { symbol ?? tone.symbol }
    /// What VoiceOver says: "Warning, <text>" (an info toast is just its text).
    var spoken: String { severity == .info ? text : tone.spokenName.text + ", " + text }
}

/// How long a toast stays: three seconds for a confirmation; a warning or an error (or a toast with a button) needs a moment more to be read and used.
enum ToastTiming {
    static let confirmation: TimeInterval = 3
    static let attention: TimeInterval = 5
    static let fadeOut: TimeInterval = 0.25
    static let fadeOutReduced: TimeInterval = 0.12

    static func duration(_ item: ToastItem) -> TimeInterval {
        item.severity == .info && item.handler == nil ? confirmation : attention
    }
}

/// FIFO queue of toasts: one is on screen, the rest wait. An identical toast that arrives while the same text is showing (or last in the queue) is folded into it
/// instead of repeating; when the queue is full the oldest waiting confirmation is dropped before anything else.
struct ToastQueue {
    static let maxPending = 6

    enum Outcome: Equatable { case startNow, queued, merged }

    private(set) var current: ToastItem?
    private(set) var pending: [ToastItem] = []

    var isEmpty: Bool { current == nil && pending.isEmpty }

    mutating func enqueue(_ item: ToastItem) -> Outcome {
        if let cur = current, cur.text == item.text, cur.severity == item.severity, cur.actionTitle == item.actionTitle { return .merged }
        if let last = pending.last, last.text == item.text, last.severity == item.severity, last.actionTitle == item.actionTitle { return .merged }
        guard current != nil else { current = item; return .startNow }
        pending.append(item)
        if pending.count > Self.maxPending {
            if let i = pending.firstIndex(where: { $0.severity == .info && $0.handler == nil }) { pending.remove(at: i) } else { pending.removeFirst() }
        }
        return .queued
    }

    /// The shown toast is gone: the next one (if any) becomes current.
    @discardableResult
    mutating func advance() -> ToastItem? {
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }
}

/// The remaining time of the toast on screen, with pause (the pointer is over it) and resume. Pure: the caller passes the clock.
struct ToastClock: Equatable {
    private(set) var remaining: TimeInterval
    private var startedAt: TimeInterval?

    init(duration: TimeInterval) { remaining = duration }

    var isRunning: Bool { startedAt != nil }

    /// Starts (or resumes) counting down; returns how long to wait from `now`.
    mutating func start(now: TimeInterval) -> TimeInterval {
        startedAt = now
        return remaining
    }

    mutating func pause(now: TimeInterval) {
        guard let s = startedAt else { return }
        remaining = max(0, remaining - (now - s))
        startedAt = nil
    }

    /// Back to a full duration (a duplicate toast arrived).
    mutating func restart(duration: TimeInterval) { remaining = duration; startedAt = nil }
}

/// The observable state of the toast panel's content.
@MainActor
final class ToastModel: ObservableObject {
    @Published var item: ToastItem?
    /// Drives the in/out transition; the item stays in place while it fades.
    @Published var shown = false
    var onTap: (() -> Void)?
    var onAction: (() -> Void)?
}
