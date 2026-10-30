import Foundation
import SwiftUI
import AppKit

/// What the person asked for with a pointer release or a key press; the controller turns it into work.
enum WheelAction: Equatable {
    case run(WheelSector)
    /// Command held (or the Customise button): open the Studio for this sector's target.
    case customise(WheelSector)
    /// Open the Studio with the last highlighted sector's target (the "Customise..." capsule).
    case customiseLast(WheelSector?)
    case switchPage(Int)
    case cancel
}

/// The text of the hub for the current state (plain strings in the active language).
struct WheelHubContent: Equatable {
    var title: String
    var detail: String
    /// A symbol that replaces the fanned file icons (link wheel, repeat view, an unavailable sector).
    var symbol: String?
    var showsFanIcons: Bool
    var detailIsHint: Bool = false
}

/// All state of ONE wheel presentation. Main-actor, `ObservableObject`: the view only reads it, the panel's AppKit view and the keyboard write it.
/// Pure decisions (hit testing, the hub text, paging, keyboard navigation) live here so the self-tests drive them without a window.
@MainActor
final class WheelModel: ObservableObject {
    @Published private(set) var content: WheelContent
    @Published private(set) var pageIndex = 0
    /// The sector under the pointer / keyboard, or -1.
    @Published private(set) var highlight = -1
    @Published var presentation: WheelPresentation
    /// Command (or, in click mode, Option) is down: releasing on a sector customises.
    @Published var customiseHeld = false
    /// The pointer is over the hub.
    @Published private(set) var hubHot = false
    /// The pointer is over the hub's "Customise..." capsule.
    @Published private(set) var capsuleHot = false
    /// A drag is inside the disc (drop-target glow).
    @Published var dropActive = false
    /// 0...1 progress ring on the "More..." sector while the dwell runs (the view animates it linearly over `dwellSeconds`).
    @Published private(set) var dwelling = false
    /// Which file wheels the person can reach (the chips in the hub); empty for the link wheel and the clipboard wheel.
    @Published var reachableWheels: [WheelKind] = []
    /// Clipboard source only: put the finished result back on the clipboard ("Paste as file").
    @Published var pasteBackAvailable = false
    @Published var pasteBack = true
    /// Bumped whenever the ring is rebuilt, so the view replays its grow animation.
    @Published private(set) var buildToken = 0

    var summary: WheelInputSummary
    /// Skip the open animation (snapshots show the final state).
    var isStatic = false
    var scale: Double
    /// Drag mode with no items readable yet ("Drag a file here").
    var waitingForItems = false
    /// When the wheel opened, for the "ignore a drop within 150 ms of opening on a sector" guard.
    var openedAt: TimeInterval = 0
    /// The sector the pointer visited last (target of the "Customise..." capsule).
    private(set) var lastHighlighted: WheelSector?

    /// Time the pointer must rest on "More..." before the ring turns the page.
    var dwellSeconds: TimeInterval
    private var dwellStart: TimeInterval?
    private var dwellTarget = -1
    /// Called when a dwell completes (the controller schedules `checkDwell` with a one-shot timer).
    var scheduleDwellCheck: ((TimeInterval) -> Void)?
    /// Called for every alignment tick (tests count them; the default plays the haptic).
    var tick: (() -> Void)? = { Haptics.tick(.alignment) }

    init(content: WheelContent, presentation: WheelPresentation, summary: WheelInputSummary = .empty, scale: Double = 1, dwellSeconds: TimeInterval = 0.45) {
        self.content = content
        self.presentation = presentation
        self.summary = summary
        self.scale = scale
        self.dwellSeconds = dwellSeconds
    }

    // MARK: Derived

    var sectors: [WheelSector] { pageIndex < content.pages.count ? content.pages[pageIndex] : [] }
    var geometry: WheelGeometry { .scaled(scale, sectorCount: sectors.count) }
    var highlightedSector: WheelSector? { sectors.indices.contains(highlight) ? sectors[highlight] : nil }
    var wheel: WheelKind { content.wheel }
    var isLinkWheel: Bool { content.wheel == .link }

    /// The capsule inside the lower hub ("Customise..."): centre offset (y up) and size.
    var capsuleRect: CGRect {
        let g = geometry
        let w = g.hubRadius * 1.05, h = max(g.hubRadius * 0.30, 18)
        return CGRect(x: -w / 2, y: -g.hubRadius * 0.74, width: w, height: h)
    }

    // MARK: Content changes

    func setContent(_ new: WheelContent, keepHighlight: Bool = false) {
        content = new
        pageIndex = 0
        if !keepHighlight { highlight = -1 }
        cancelDwell()
        buildToken += 1
    }

    func setPage(_ index: Int, highlightFirst: Bool = false) {
        guard index >= 0, index < content.pages.count, index != pageIndex else { return }
        pageIndex = index
        highlight = highlightFirst && !sectors.isEmpty ? 0 : -1
        cancelDwell()
        buildToken += 1
    }

    // MARK: Pointer

    /// Where a point (relative to the wheel centre, y up) lands.
    enum Zone: Equatable { case sector(Int), hub, capsule, outside }

    func zone(at point: CGPoint) -> Zone {
        let g = geometry
        let hit = g.hitTest(point)
        if hit >= 0 { return .sector(hit) }
        if g.inHub(point) { return capsuleRect.contains(point) ? .capsule : .hub }
        return .outside
    }

    /// Pointer (or drag) moved to `point`. Updates the highlight, plays the alignment tick when the sector changes and manages the "More..." dwell.
    func pointerMoved(to point: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Published properties fire on every assignment, equal or not: only write what changed (a drag reports its position at display rate).
        switch zone(at: point) {
        case .sector(let i):
            setHot(hub: false, capsule: false)
            setHighlight(i, now: now)
        case .hub:
            setHot(hub: true, capsule: false)
            setHighlight(-1, now: now)
        case .capsule:
            setHot(hub: true, capsule: true)
            setHighlight(-1, now: now)
        case .outside:
            setHot(hub: false, capsule: false)
            // Click mode keeps the last sector highlighted when the pointer leaves; a drag clears it.
            if presentation == .drag { setHighlight(-1, now: now) }
        }
    }

    func pointerLeft() {
        setHot(hub: false, capsule: false)
        if presentation == .drag { setHighlight(-1) }
    }

    private func setHot(hub: Bool, capsule: Bool) {
        if hubHot != hub { hubHot = hub }
        if capsuleHot != capsule { capsuleHot = capsule }
    }

    /// Drop-target glow and modifier state written by the AppKit view at display rate: no-ops when nothing changed.
    func setDropActive(_ on: Bool) { if dropActive != on { dropActive = on } }
    func setCustomiseHeld(_ on: Bool) { if customiseHeld != on { customiseHeld = on } }

    func setHighlight(_ i: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let valid = sectors.indices.contains(i) ? i : -1
        guard valid != highlight else { return }
        highlight = valid
        if valid >= 0 {
            lastHighlighted = sectors[valid]
            if sectors[valid].enabled || sectors[valid].isPaging { tick?() }
        }
        updateDwell(now: now)
    }

    // MARK: Dwell on "More..."

    private func updateDwell(now: TimeInterval) {
        guard presentation == .drag, let s = highlightedSector, s.isPaging else { cancelDwell(); return }
        guard dwellTarget != highlight else { return }
        dwellTarget = highlight
        dwellStart = now
        dwelling = true
        scheduleDwellCheck?(now + dwellSeconds)
    }

    private func cancelDwell() { dwellStart = nil; dwellTarget = -1; dwelling = false }

    /// Called when the dwell timer fires (or by a test with a manual clock): turns the page if the pointer rested on "More..." / "Back" long enough.
    @discardableResult
    func checkDwell(now: TimeInterval) -> Bool {
        guard let start = dwellStart, now - start >= dwellSeconds - 0.0005, let s = highlightedSector, s.isPaging, highlight == dwellTarget else { return false }
        let target = s.role == .more ? pageIndex + 1 : pageIndex - 1
        cancelDwell()
        pageIndex = max(0, min(target, content.pages.count - 1))
        highlight = -1
        buildToken += 1
        tick?()
        return true
    }

    // MARK: Decisions

    /// A drop (drag mode) or a click (click mode) at `point`. Dropping on the hub, on "More..." / "Back", on a dimmed sector or outside the disc cancels.
    func decide(at point: CGPoint, customise: Bool) -> WheelAction {
        switch zone(at: point) {
        case .sector(let i):
            guard let s = sectors[safe: i] else { return .cancel }
            return decide(sector: s, customise: customise)
        case .capsule: return .customiseLast(lastHighlighted)
        case .hub, .outside: return .cancel
        }
    }

    func decide(sector s: WheelSector, customise: Bool) -> WheelAction {
        if s.isPaging {
            // In click mode the paging sectors work like buttons; in drag mode a drop on them is a cancel (the drag session is over).
            guard presentation == .click else { return .cancel }
            return .switchPage(s.role == .more ? pageIndex + 1 : pageIndex - 1)
        }
        guard s.enabled else { return .cancel }
        if s.role == .studio { return .customise(s) }
        return customise ? .customise(s) : .run(s)
    }

    // MARK: Keyboard (click mode, spec 7.2)

    /// Arrow keys: left / up = previous, right / down = next, wrap-around; from nothing the first key lands on sector 0 (or the last for "previous").
    func move(by delta: Int) {
        let n = sectors.count
        guard n > 0 else { return }
        if highlight < 0 { setHighlight(delta >= 0 ? 0 : n - 1); return }
        setHighlight(((highlight + delta) % n + n) % n)
    }

    /// Digit key 1...9: the sector at that position, if it exists.
    func sector(forDigit d: Int) -> WheelSector? { d >= 1 ? sectors[safe: d - 1] : nil }

    // MARK: Hub text

    func hubContent() -> WheelHubContent {
        if let s = highlightedSector {
            if !s.enabled {
                return WheelHubContent(title: s.title.text, detail: s.hint?.text ?? L("Not available on this Mac", "Недоступно на этом Mac"), symbol: "exclamationmark.triangle",
                                       showsFanIcons: false, detailIsHint: true)
            }
            if customiseHeld && s.role != .studio {
                return WheelHubContent(title: s.title.text, detail: L("Customize…", "Настроить…"), symbol: "slider.horizontal.3", showsFanIcons: false)
            }
            if content.wheel == .link, let page = content.linkTitle, !page.isEmpty {
                // The page title stays in the hub while a download mode is hovered (click mode pre-highlights the first one): the mode goes to the detail line.
                let mode = [s.title.text, s.subtitle?.text].compactMap { $0 }.joined(separator: " · ")
                return WheelHubContent(title: page, detail: mode, symbol: s.symbol, showsFanIcons: false)
            }
            return WheelHubContent(title: s.title.text, detail: s.subtitle?.text ?? summary.text, symbol: s.symbol, showsFanIcons: false)
        }
        if capsuleHot {
            return WheelHubContent(title: L("Customize…", "Настроить…"), detail: L("Opens the Studio", "Откроет Студию"), symbol: "slider.horizontal.3", showsFanIcons: false)
        }
        if content.isRepeatView {
            if let s = content.first.first {
                return WheelHubContent(title: L("Repeat", "Повторить"), detail: s.title.text, symbol: "arrow.trianglehead.counterclockwise", showsFanIcons: false)
            }
            return WheelHubContent(title: L("Repeat", "Повторить"), detail: (content.emptyMessage ?? L10n("Last action doesn’t fit", "Последнее действие не подходит")).text,
                                   symbol: "arrow.trianglehead.counterclockwise", showsFanIcons: false)
        }
        if content.wheel == .link {
            let host = content.linkHost ?? summary.text
            if let title = content.linkTitle, !title.isEmpty {
                return WheelHubContent(title: title, detail: host, symbol: "arrow.down.circle", showsFanIcons: false)
            }
            return WheelHubContent(title: host, detail: WheelKind.link.title.text, symbol: "arrow.down.circle", showsFanIcons: false)
        }
        if waitingForItems && summary.count == 0 {
            return WheelHubContent(title: content.wheel.title.text, detail: L("Drag a file here", "Перетащите файл сюда"), symbol: "tray.and.arrow.down", showsFanIcons: false)
        }
        if content.isEmpty {
            return WheelHubContent(title: content.wheel.title.text, detail: (content.emptyMessage ?? L10n("Nothing for this selection", "Нет действий для выбранных файлов")).text,
                                   symbol: "circle.slash", showsFanIcons: summary.count > 0)
        }
        return WheelHubContent(title: content.wheel.title.text, detail: summary.text, symbol: summary.icons.isEmpty ? content.wheel.symbol : nil, showsFanIcons: !summary.icons.isEmpty)
    }

    // MARK: Accessibility

    func accessibilityLabel(for index: Int) -> String {
        guard let s = sectors[safe: index] else { return "" }
        var parts = [s.title.text]
        if let sub = s.subtitle?.text, !sub.isEmpty { parts.append(sub) }
        if !s.enabled, let hint = s.hint?.text { parts.append(hint) }
        parts.append(L("\(index + 1) of \(sectors.count)", "\(index + 1) из \(sectors.count)"))
        return parts.joined(separator: ", ")
    }
}
