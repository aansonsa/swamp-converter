import Foundation
import CoreGraphics
import AppKit

// The model's decisions without a window: pointer, drop, keyboard, paging dwell on a manual clock, hub text, the key map and the drop policy.

extension WheelTests {
    @MainActor
    static func sampleModel(_ pages: [[WheelSector]] = WheelSnapshotData.eight, mode: WheelPresentation = .drag, summary: WheelInputSummary = WheelSnapshotData.imageSummary) -> WheelModel {
        let m = WheelModel(content: WheelContent(wheel: .convert, pages: pages), presentation: mode, summary: summary)
        m.tick = nil
        return m
    }

    /// The point at the middle of sector `i` of `m`'s current page.
    @MainActor
    static func middle(of i: Int, in m: WheelModel) -> CGPoint { m.geometry.labelCenter(of: i) }

    static func registerModel() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "pointer: moving over sectors highlights them and ticks once per change; the hub and the outside clear a drag, the outside keeps a click") {
            let m = sampleModel()
            var ticks = 0
            m.tick = { ticks += 1 }
            m.pointerMoved(to: middle(of: 2, in: m)); m.pointerMoved(to: middle(of: 2, in: m))
            try expectEqual(m.highlight, 2); try expectEqual(ticks, 1, "same sector twice ticks once")
            m.pointerMoved(to: middle(of: 4, in: m))
            try expectEqual(m.highlight, 4); try expectEqual(ticks, 2)
            m.pointerMoved(to: .zero)
            try expectEqual(m.highlight, -1, "the hub clears the highlight"); try expect(m.hubHot)
            m.pointerMoved(to: CGPoint(x: 0, y: -35))
            try expect(m.capsuleHot, "the lower hub is the Customise capsule")
            m.pointerMoved(to: middle(of: 1, in: m)); m.pointerMoved(to: CGPoint(x: 900, y: 900))
            try expectEqual(m.highlight, -1, "a drag leaving the disc clears the highlight")
            let click = sampleModel(mode: .click)
            click.pointerMoved(to: middle(of: 3, in: click)); click.pointerMoved(to: CGPoint(x: 900, y: 900))
            try expectEqual(click.highlight, 3, "click mode keeps the last sector")
            let dim = sampleModel(WheelSnapshotData.eight, mode: .drag)
            var dimTicks = 0
            dim.tick = { dimTicks += 1 }
            dim.setPage(1)
            dim.pointerMoved(to: middle(of: 5, in: dim))                                       // the dimmed "Extract text"
            try expectEqual(dimTicks, 0, "a dimmed sector gives no alignment tick")
        }
        t.register("wheel", "decide: run, customise, cancel and paging follow the rules of the drop and of the click") {
            let m = sampleModel()
            try expectEqual(m.decide(at: middle(of: 0, in: m), customise: false), .run(m.sectors[0]))
            try expectEqual(m.decide(at: middle(of: 0, in: m), customise: true), .customise(m.sectors[0]))
            try expectEqual(m.decide(at: .zero, customise: false), .cancel, "the hub cancels")
            try expectEqual(m.decide(at: CGPoint(x: 900, y: 0), customise: false), .cancel, "outside cancels")
            try expectEqual(m.decide(at: middle(of: 7, in: m), customise: false), .cancel, "a drop on More... cancels (the drag is over)")
            m.setHighlight(2)
            try expectEqual(m.decide(at: CGPoint(x: 0, y: -35), customise: false), .customiseLast(m.sectors[2]), "the capsule opens the Studio for the last sector")
            m.setPage(1)
            let ocr = m.sectors[5]
            try expect(!ocr.enabled)
            try expectEqual(m.decide(at: middle(of: 5, in: m), customise: false), .cancel, "a dimmed sector never runs")
            let click = sampleModel(mode: .click)
            try expectEqual(click.decide(at: middle(of: 7, in: click), customise: false), .switchPage(1), "a click on More... turns the page")
            click.setPage(1)
            try expectEqual(click.decide(at: middle(of: 7, in: click), customise: false), .switchPage(0), "Back returns")
            let link = WheelContent(wheel: .link, pages: [[WheelSnapshotData.sector("link.best", "Best", "Лучшее", symbol: "arrow.down.circle"), WheelContentBuilder.studioSector]])
            let lm = WheelModel(content: link, presentation: .click)
            try expectEqual(lm.decide(sector: lm.sectors[1], customise: false), .customise(lm.sectors[1]), "Choose in Studio... always opens the Studio")
        }
        t.register("wheel", "dwell on More...: the page turns only after the dwell time on a manual clock, and leaving cancels it") {
            let m = sampleModel()
            var scheduled: [TimeInterval] = []
            m.scheduleDwellCheck = { scheduled.append($0) }
            m.dwellSeconds = 0.25
            m.setHighlight(7, now: 100)
            try expectEqual(scheduled, [100.25], "the controller is asked for one check at start + dwell")
            try expect(m.dwelling)
            try expect(!m.checkDwell(now: 100.1), "too early")
            try expectEqual(m.pageIndex, 0)
            try expect(m.checkDwell(now: 100.26), "dwell complete")
            try expectEqual(m.pageIndex, 1); try expect(!m.dwelling); try expectEqual(m.highlight, -1)
            m.setHighlight(7, now: 200)                                                          // "Back" now
            m.setHighlight(3, now: 200.1)
            try expect(!m.checkDwell(now: 200.5), "moving away cancels the dwell")
            try expectEqual(m.pageIndex, 1)
            let click = sampleModel(mode: .click)
            var asked = 0
            click.scheduleDwellCheck = { _ in asked += 1 }
            click.setHighlight(7, now: 1)
            try expectEqual(asked, 0, "click mode never dwells")
        }
        t.register("wheel", "keyboard: arrows wrap around, digits pick a sector, Tab and Esc map to commands") {
            let m = sampleModel(mode: .click)
            m.move(by: 1); try expectEqual(m.highlight, 0, "the first key lands on sector 0")
            m.move(by: -1); try expectEqual(m.highlight, 7, "wraps backwards")
            m.move(by: 1); try expectEqual(m.highlight, 0, "wraps forwards")
            try expectEqual(m.sector(forDigit: 3)?.id, m.sectors[2].id)
            try expect(m.sector(forDigit: 0) == nil && m.sector(forDigit: 9) == nil, "no sector 0, and 9 does not exist on a ring of eight")
            try expectEqual(WheelKeyCommand.command(keyCode: 53, characters: nil, shift: false), .close)
            try expectEqual(WheelKeyCommand.command(keyCode: 124, characters: nil, shift: false), .next)
            try expectEqual(WheelKeyCommand.command(keyCode: 123, characters: nil, shift: false), .previous)
            try expectEqual(WheelKeyCommand.command(keyCode: 36, characters: "\r", shift: false), .activate)
            try expectEqual(WheelKeyCommand.command(keyCode: 48, characters: "\t", shift: true), .tab(backwards: true))
            try expectEqual(WheelKeyCommand.command(keyCode: 18, characters: "1", shift: false), .digit(1))
            try expectEqual(WheelKeyCommand.command(keyCode: 15, characters: "R", shift: false), .repeatView)
            try expectEqual(WheelKeyCommand.command(keyCode: 0, characters: "0", shift: false), .none, "0 is not a sector")
            try expectEqual(WheelKeyCommand.command(keyCode: 6, characters: "z", shift: false), .none)
        }
        t.register("wheel", "hub text: waiting, summary, hovered sector, dimmed hint, link header and repeat view") {
            Loc.shared.set(.english)
            let waiting = sampleModel(summary: .empty)
            waiting.waitingForItems = true
            try expectEqual(waiting.hubContent().detail, "Drag a file here")
            let idle = sampleModel()
            try expectEqual(idle.hubContent().title, "Convert"); try expectEqual(idle.hubContent().detail, WheelSnapshotData.imageSummary.text)
            idle.setHighlight(3)
            try expectEqual(idle.hubContent().title, "PDF"); try expectEqual(idle.hubContent().detail, "document")
            idle.setPage(1); idle.setHighlight(5)
            let hint = idle.hubContent()
            try expect(hint.detailIsHint && hint.symbol == "exclamationmark.triangle" && hint.detail.contains("Vision"), "a dimmed sector explains itself in the hub")
            let content = WheelContentBuilder().linkContent(links: [LinkItem(url: URL(string: "https://www.youtube.com/watch?v=abc")!, title: "Short title")], pageTitle: "A page")
            let link = WheelModel(content: content, presentation: .click)
            try expectEqual(link.hubContent().title, "A page"); try expectEqual(link.hubContent().detail, "youtube.com")
            link.setHighlight(0)
            let hovered = link.hubContent()
            try expectEqual(hovered.title, "A page")
            try expect(hovered.detail.contains(link.sectors[0].title.text), "a hovered download mode goes to the detail line while the page title stays")
            let rep = WheelModel(content: WheelContentBuilder().repeatContent(last: nil, wheel: .convert), presentation: .click)
            try expectEqual(rep.hubContent().title, "Repeat"); try expect(rep.hubContent().detail.contains("doesn’t fit"))
            Loc.shared.set(.russian)
            try expectEqual(waiting.hubContent().detail, "Перетащите файл сюда")
            Loc.shared.set(.english)
            try expect(!idle.accessibilityLabel(for: 0).isEmpty && idle.accessibilityLabel(for: 0).contains("of 8"), "VoiceOver labels carry the position")
        }
        t.register("wheel", "drop policy: a copy effect over enabled sectors and the capsule, nothing over the hub, dimmed sectors, More... and outside; never move") {
            let m = sampleModel()
            let sectors = m.sectors
            let all: NSDragOperation = [.copy, .move, .link, .generic]
            try expectEqual(WheelDropPolicy.operation(zone: .sector(0), sectors: sectors, sourceMask: all), .copy)
            try expectEqual(WheelDropPolicy.operation(zone: .capsule, sectors: sectors, sourceMask: all), .copy)
            try expectEqual(WheelDropPolicy.operation(zone: .hub, sectors: sectors, sourceMask: all), [])
            try expectEqual(WheelDropPolicy.operation(zone: .outside, sectors: sectors, sourceMask: all), [])
            try expectEqual(WheelDropPolicy.operation(zone: .sector(7), sectors: sectors, sourceMask: all), [], "More...")
            try expectEqual(WheelDropPolicy.operation(zone: .sector(99), sectors: sectors, sourceMask: all), [])
            m.setPage(1)
            try expectEqual(WheelDropPolicy.operation(zone: .sector(5), sectors: m.sectors, sourceMask: all), [], "dimmed")
            try expectEqual(WheelDropPolicy.safeEffect(sourceMask: [.move]), [], "a move-only source is refused instead of deleting the original")
            try expectEqual(WheelDropPolicy.safeEffect(sourceMask: [.move, .generic]), .generic)
            try expectEqual(WheelDropPolicy.safeEffect(sourceMask: [.move, .link]), .link)
            for mask in [NSDragOperation.copy, [.copy, .move], .every, .generic] { try expect(!WheelDropPolicy.safeEffect(sourceMask: mask).contains(.move), "never move") }
        }
    }
}
