import Foundation
import CoreGraphics

// The layout rules of the labels: word-safe font fitting, the crowded-wheel placement, and that every real label of the catalogue fits its box in both languages.

extension WheelTests {
    static func registerLayout() {
        let t = SelfTestRegistry.shared

        t.register("wheel", "label fitting: wraps between words only, shrinks to the floor, gives up (nil) instead of breaking a word") {
            // "Объединить" is one word: a box that holds it keeps the text; a box that cannot hold it at the smallest size reports nil.
            let wide = WheelLabelFit.size(for: "Объединить PDF", width: 64, base: 11, minimum: 8.5, maxLines: 2)
            try expect(wide != nil, "fits two lines at 64 pt")
            let words = ["Объединить", "PDF"]
            try expect(WheelLabelFit.lineCount(words, width: 64, size: wide!, weight: .semibold) <= 2)
            try expect(WheelLabelFit.size(for: "Объединить PDF", width: 30, base: 11, minimum: 8.5, maxLines: 2) == nil, "a word wider than the box is never broken")
            try expectEqual(WheelLabelFit.size(for: "PDF", width: 120, base: 12, minimum: 9, maxLines: 2), 12, "short text keeps the full size")
            try expect(WheelLabelFit.size(for: "Без метаданных", width: 100, base: 14, minimum: 11, maxLines: 1) != nil, "a hub title shrinks to one line")
            try expect(WheelLabelFit.size(for: "Без метаданных", width: 60, base: 14, minimum: 11, maxLines: 1) == nil, "...and says so when it cannot")
            try expectEqual(WheelLabelFit.lineCount(["aaa", "bbb", "ccc"], width: 40, size: 12, weight: .semibold) > 1, true)
        }

        t.register("wheel", "a crowded wheel (9 or more sectors) moves its labels outwards so neighbouring labels clear each other; a normal wheel is unchanged") {
            let normal = WheelGeometry(sectorCount: 8), crowded = WheelGeometry(sectorCount: 12)
            try expect(!normal.isCrowded && crowded.isCrowded && !WheelGeometry(sectorCount: 8).isCrowded && WheelGeometry(sectorCount: 9).isCrowded)
            try expectClose(Double(normal.labelRadius), 120, tolerance: 0.001, "eight sectors keep the middle of the ring")
            try expect(crowded.labelRadius > 130, "twelve sectors sit further out: \(crowded.labelRadius)")
            // A crowded label is an icon (20 pt) and two lines (about 24 pt) plus the 7 pt pop of the hovered one: its neighbour must be further away than that.
            let a = crowded.labelCenter(of: 0), b = crowded.labelCenter(of: 1)
            let apart = hypot(a.x - b.x, a.y - b.y)
            try expect(apart >= 66, "neighbouring labels are \(apart) pt apart")
            for n in 9...13 { let g = WheelGeometry(sectorCount: n); try expect(g.labelWidth >= 48, "n=\(n) label width \(g.labelWidth)") }
        }

        t.register("wheel", "every operation label of the catalogue fits its box in English and Russian: crowded and normal wheels, without a broken word") {
            let crowded = WheelGeometry(sectorCount: 12), normal = WheelGeometry(sectorCount: 8)
            var bad: [String] = []
            for op in OperationRegistry.shared.allOperations() where !op.meta.studioOnly && op.meta.targetFormat == nil && op.meta.wheel != .link {
                for (lang, text) in [("en", op.meta.label.en), ("ru", op.meta.label.ru)] {
                    if WheelLabelFit.size(for: text, width: crowded.labelWidth, base: 11, minimum: 8.5, maxLines: 2) == nil { bad.append("\(op.meta.id) [\(lang)] \"\(text)\" at 12 sectors (\(Int(crowded.labelWidth)) pt)") }
                    if WheelLabelFit.size(for: text, width: normal.labelWidth, base: 12, minimum: 9, maxLines: 2) == nil { bad.append("\(op.meta.id) [\(lang)] \"\(text)\" at 8 sectors (\(Int(normal.labelWidth)) pt)") }
                }
            }
            try expect(bad.isEmpty, "\(bad.count) labels do not fit: " + bad.prefix(8).joined(separator: "; "))
        }
    }
}
