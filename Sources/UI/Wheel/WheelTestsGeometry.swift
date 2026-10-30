import Foundation
import CoreGraphics
import AppKit

// Acceptance tests of the wheel's geometry and its model (spec/wheel.md 19): hit testing for every ring size, sector order, placement clamping, slots, pointer / drop / keyboard
// decisions, hub text, paging dwell with a manual clock. No window is created.

extension WheelTests {
    static func registerGeometry() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "hit test: every sector is hit on its centre line and just inside both edges, n = 1...13") {
            for n in 1...13 {
                let g = WheelGeometry(sectorCount: n)
                let r = g.labelRadius
                for i in 0..<n {
                    let mid = g.centerAngle(of: i)
                    for delta in [0, g.step / 2 - 0.01, -(g.step / 2 - 0.01)] {
                        if n == 1 && delta != 0 { continue }
                        let hit = g.hitTest(WheelGeometry.polar(r, mid + delta))
                        try expectEqual(hit, i, "n=\(n) sector \(i) delta \(delta)")
                    }
                }
                if n == 1 { for a in stride(from: 0.0, to: 6.2, by: 0.7) { try expectEqual(g.hitTest(WheelGeometry.polar(r, CGFloat(a))), 0, "n=1 any angle") } }
            }
        }
        t.register("wheel", "hit test: hub, outside the rim and an empty wheel are -1; the rim still counts") {
            let g = WheelGeometry(sectorCount: 6)
            try expectEqual(g.hitTest(.zero), -1, "centre")
            try expectEqual(g.hitTest(CGPoint(x: 0, y: g.hubRadius - 1)), -1, "inside the hub")
            try expectEqual(g.hitTest(CGPoint(x: 0, y: g.hubRadius + 1)), 0, "just outside the hub")
            try expectEqual(g.hitTest(CGPoint(x: 0, y: g.outerRadius + g.rim - 0.5)), 0, "on the rim")
            try expectEqual(g.hitTest(CGPoint(x: 0, y: g.outerRadius + g.rim + 1)), -1, "beyond the rim")
            try expectEqual(g.hitTest(CGPoint(x: 300, y: 300)), -1, "panel corner")
            try expectEqual(WheelGeometry(sectorCount: 0).hitTest(CGPoint(x: 0, y: 100)), -1, "n = 0")
            try expect(g.containsDisc(CGPoint(x: 0, y: g.outerRadius)) && !g.containsDisc(CGPoint(x: 0, y: g.outerRadius + 20)), "disc test")
            try expect(g.inHub(.zero) && !g.inHub(CGPoint(x: 0, y: 100)), "hub test")
        }
        t.register("wheel", "sector 0 is centred at 12 o'clock and the sectors run clockwise") {
            let g = WheelGeometry(sectorCount: 4)
            let p0 = g.labelCenter(of: 0), p1 = g.labelCenter(of: 1), p2 = g.labelCenter(of: 2), p3 = g.labelCenter(of: 3)
            try expectClose(Double(p0.x), 0, tolerance: 1e-6); try expect(p0.y > 100, "sector 0 above the centre (y up)")
            try expect(p1.x > 100 && abs(p1.y) < 1e-6, "sector 1 at 3 o'clock")
            try expect(p2.y < -100, "sector 2 at 6 o'clock")
            try expect(p3.x < -100, "sector 3 at 9 o'clock")
            let single = WheelGeometry(sectorCount: 1).labelCenter(of: 0)
            try expect(single.y > 100 && abs(single.x) < 1e-6, "a single sector keeps its label on the ring at 12 o'clock, never in the hub")
            let dir = g.popDirection(of: 1)
            try expect(dir.width > 0.99 && abs(dir.height) < 1e-6, "the pop of the 3 o'clock sector points right")
        }
        t.register("wheel", "sector paths cover the label point, exclude the hub and stay inside the outer radius, n = 1...13") {
            for n in 1...13 {
                let g = WheelGeometry(sectorCount: n)
                for i in 0..<n {
                    let path = g.sectorPath(i)
                    try expect(!path.isEmpty, "n=\(n) i=\(i) path")
                    try expect(path.contains(g.labelCenter(of: i)), "n=\(n) i=\(i) contains its label centre")
                    try expect(!path.contains(.zero), "n=\(n) i=\(i) excludes the hub centre")
                    let box = path.boundingBoxOfPath
                    try expect(max(abs(box.minX), abs(box.maxX), abs(box.minY), abs(box.maxY)) <= g.outerRadius + 0.5, "n=\(n) i=\(i) inside the outer radius")
                }
            }
            try expect(WheelGeometry(sectorCount: 0).sectorPath(0).isEmpty, "n = 0 has no path")
        }
        t.register("wheel", "placement keeps the whole disc 16 pt inside the visible frame, on any screen position") {
            let g = WheelGeometry.scaled(1, sectorCount: 8)
            let screens = [CGRect(x: 0, y: 0, width: 1512, height: 944), CGRect(x: -3840, y: -831, width: 3840, height: 2160), CGRect(x: 1512, y: 100, width: 1920, height: 1000)]
            for vf in screens {
                let anchors = [CGPoint(x: vf.midX, y: vf.midY), CGPoint(x: vf.minX, y: vf.minY), CGPoint(x: vf.maxX, y: vf.maxY), CGPoint(x: vf.minX + 3, y: vf.maxY - 2),
                               CGPoint(x: vf.maxX + 500, y: vf.midY), CGPoint(x: vf.midX, y: vf.minY - 500)]
                for a in anchors {
                    let frame = WheelGeometry.placement(anchor: a, panelSize: g.panelSide, visibleFrame: vf, margin: 16, discInset: WheelGeometry.pad)
                    try expectClose(Double(frame.width), Double(g.panelSide), tolerance: 0.001, "panel size kept")
                    let disc = frame.insetBy(dx: WheelGeometry.pad, dy: WheelGeometry.pad)
                    try expect(disc.minX >= vf.minX + 16 - 0.001 && disc.maxX <= vf.maxX - 16 + 0.001, "x inside for \(a) in \(vf)")
                    try expect(disc.minY >= vf.minY + 16 - 0.001 && disc.maxY <= vf.maxY - 16 + 0.001, "y inside for \(a) in \(vf)")
                }
                // A wheel anchored well inside the screen is centred exactly under the anchor.
                let inside = WheelGeometry.placement(anchor: CGPoint(x: vf.midX, y: vf.midY), panelSize: g.panelSide, visibleFrame: vf, margin: 16, discInset: WheelGeometry.pad)
                try expectClose(Double(inside.midX), Double(vf.midX), tolerance: 0.001, "centred x")
                try expectClose(Double(inside.midY), Double(vf.midY), tolerance: 0.001, "centred y")
            }
            let tiny = WheelGeometry.placement(anchor: .zero, panelSize: g.panelSide, visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200), margin: 16, discInset: WheelGeometry.pad)
            try expectClose(Double(tiny.midX), 100, tolerance: 0.001, "a screen smaller than the disc centres the panel")
            let frame = WheelController.panelFrame(anchor: CGPoint(x: 5, y: 5), geometry: g, visibleFrame: nil)
            try expect(frame.minX + WheelGeometry.pad >= 16 - 0.001, "no screen: the fallback frame still clamps")
        }
        t.register("wheel", "scaled geometry clamps 0.8...1.2 and the panel is the disc plus the transparent pad") {
            try expectClose(Double(WheelGeometry.scaled(1, sectorCount: 8).outerRadius), 180)
            try expectClose(Double(WheelGeometry.scaled(0.1, sectorCount: 8).outerRadius), 144, tolerance: 0.001)
            try expectClose(Double(WheelGeometry.scaled(9, sectorCount: 8).outerRadius), 216, tolerance: 0.001)
            let g = WheelGeometry.scaled(1.1, sectorCount: 5)
            try expectClose(Double(g.panelSide), Double(2 * (g.outerRadius + WheelGeometry.pad)), tolerance: 0.001)
            try expectClose(Double(g.hubRadius), Double(g.outerRadius / 3), tolerance: 0.001, "hub is a third of the disc")
            try expect(g.labelWidth >= 48 && g.labelWidth <= 121 * 1.1, "label width within its clamp")
            try expectClose(Double(WheelGeometry(sectorCount: 2).labelWidth), 120, tolerance: 0.001, "two sectors use the wide label box")
        }
        t.register("wheel", "favourites take the axes of a four- or eight-slot ring and the last slot stays put") {
            let ids = ["a", "b", "c", "d", "e", "f", "g", "more"]
            let order = WheelSlotting.slotOrder(ids: ids, favorites: ["c", "e"], fixedLast: true)
            try expectEqual(order.count, 8)
            try expectEqual(order[0], "c", "first favourite at 12 o'clock")
            try expectEqual(order[2], "e", "second favourite at 3 o'clock")
            try expectEqual(order.last, "more", "More... never moves")
            try expectEqual(Set(order), Set(ids), "nothing lost")
            try expectEqual(WheelSlotting.slotOrder(ids: ["a", "b", "c"], favorites: ["b"], fixedLast: false), ["a", "b", "c"], "no axes on a three-slot ring")
        }
    }
}
